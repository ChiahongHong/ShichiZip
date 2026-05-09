import Foundation

struct FileManagerFileSystemSelectionState {
    let selectedPaths: Set<String>
    let focusedPath: String?

    static let empty = FileManagerFileSystemSelectionState(selectedPaths: [],
                                                           focusedPath: nil)
}

@MainActor
final class FileManagerPaneDirectoryCoordinator {
    private enum SnapshotPurpose {
        case refresh(selectionState: FileManagerFileSystemSelectionState)
        case autoRefresh(selectionState: FileManagerFileSystemSelectionState)
    }

    private static var snapshotQueueLabel: String {
        "\(Bundle.main.bundleIdentifier ?? "ShichiZip").file-manager.directory-snapshot"
    }

    private let snapshotQueue: DispatchQueue
    private let isViewLoaded: () -> Bool
    private let isInsideArchive: () -> Bool
    private let showsParentRow: () -> Bool
    private let selectedFileSystemItems: () -> [FileSystemItem]
    private let focusedFileSystemItemPath: () -> String?
    private let clearSuspendedState: () -> Void
    private let updatePathField: () -> Void
    private let updateStatusBar: () -> Void
    private let updateTableColumns: () -> Void
    private let sortCurrentItems: () -> Void
    private let reloadTableData: () -> Void
    private let focusFileList: () -> Void
    private let selectRows: (IndexSet) -> Void
    private let deselectRows: () -> Void
    private let scrollRowToVisible: (Int) -> Void
    private let showError: (Error) -> Void
    private let directoryDidChange: () -> Void

    private var snapshotGeneration = 0
    private var directoryWatcher: DirectoryWatcher?
    private var currentDirectoryFingerprint: [FileManagerDirectorySnapshot.EntryFingerprint] = []
    private var recentDirectories: [URL] = []

    private(set) var currentDirectory: URL
    private(set) var items: [FileSystemItem] = []

    init(initialDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         snapshotQueue: DispatchQueue = DispatchQueue(label: FileManagerPaneDirectoryCoordinator.snapshotQueueLabel,
                                                      qos: .userInitiated),
         isViewLoaded: @escaping () -> Bool,
         isInsideArchive: @escaping () -> Bool,
         showsParentRow: @escaping () -> Bool,
         selectedFileSystemItems: @escaping () -> [FileSystemItem],
         focusedFileSystemItemPath: @escaping () -> String?,
         clearSuspendedState: @escaping () -> Void,
         updatePathField: @escaping () -> Void,
         updateStatusBar: @escaping () -> Void,
         updateTableColumns: @escaping () -> Void,
         sortCurrentItems: @escaping () -> Void,
         reloadTableData: @escaping () -> Void,
         focusFileList: @escaping () -> Void,
         selectRows: @escaping (IndexSet) -> Void,
         deselectRows: @escaping () -> Void,
         scrollRowToVisible: @escaping (Int) -> Void,
         showError: @escaping (Error) -> Void,
         directoryDidChange: @escaping () -> Void)
    {
        currentDirectory = initialDirectory
        self.snapshotQueue = snapshotQueue
        self.isViewLoaded = isViewLoaded
        self.isInsideArchive = isInsideArchive
        self.showsParentRow = showsParentRow
        self.selectedFileSystemItems = selectedFileSystemItems
        self.focusedFileSystemItemPath = focusedFileSystemItemPath
        self.clearSuspendedState = clearSuspendedState
        self.updatePathField = updatePathField
        self.updateStatusBar = updateStatusBar
        self.updateTableColumns = updateTableColumns
        self.sortCurrentItems = sortCurrentItems
        self.reloadTableData = reloadTableData
        self.focusFileList = focusFileList
        self.selectRows = selectRows
        self.deselectRows = deselectRows
        self.scrollRowToVisible = scrollRowToVisible
        self.showError = showError
        self.directoryDidChange = directoryDidChange
    }

    var hasRecentDirectoryHistory: Bool {
        !recentDirectories.isEmpty
    }

    func recentDirectoryHistory() -> [URL] {
        recentDirectories
    }

    func setRecentDirectoryHistory(_ entries: [URL]) {
        recentDirectories = FileManagerRecentDirectoryHistory.normalized(entries)
    }

    func sortItems(by descriptors: [NSSortDescriptor]) {
        FileManagerItemSorting.sort(&items,
                                    by: descriptors)
    }

    @discardableResult
    func loadDirectory(_ url: URL,
                       showError: Bool = true) -> Bool
    {
        navigateToDirectory(url,
                            showError: showError)
    }

    @discardableResult
    func navigateToDirectory(_ url: URL,
                             showError: Bool,
                             selectionState: FileManagerFileSystemSelectionState? = nil,
                             focusAfterLoad: Bool = false) -> Bool
    {
        cancelPendingSnapshot()

        do {
            let snapshot = try FileManagerDirectorySnapshot.make(for: url.standardizedFileURL,
                                                                 options: directoryEnumerationOptions())
            applyDirectorySnapshot(snapshot)
            clearSuspendedState()
            if let selectionState {
                restoreSelectionState(selectionState)
            }
            if focusAfterLoad {
                focusFileList()
            }
            return true
        } catch {
            if showError {
                self.showError(error)
            }
            return false
        }
    }

    func reloadCurrentDirectoryPreservingSelection() {
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .refresh(selectionState: captureSelectionState()))
    }

    func autoRefreshCurrentDirectoryIfNeeded() {
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .autoRefresh(selectionState: captureSelectionState()))
    }

    func loadInitialDirectory(_ url: URL) {
        do {
            let snapshot = try FileManagerDirectorySnapshot.make(for: url.standardizedFileURL,
                                                                 options: directoryEnumerationOptions())
            applyDirectorySnapshot(snapshot)
        } catch {
            currentDirectory = url.standardizedFileURL
            updatePathField()
            updateStatusBar()
        }
    }

    func consumeDirectoryChange() -> Bool {
        directoryWatcher?.wasChanged() == true
    }

    func prepareForArchivePresentation(hostDirectory: URL) {
        currentDirectory = hostDirectory
        recordDirectoryVisit(hostDirectory)
        cancelPendingSnapshot()
        tearDownDirectoryWatcher()
    }

    func prepareForSuspension() {
        tearDownDirectoryWatcher()
        cancelPendingSnapshot()
        items.removeAll()
        currentDirectoryFingerprint.removeAll()
        reloadTableData()
    }

    func tearDown() {
        tearDownDirectoryWatcher()
        cancelPendingSnapshot()
    }

    private func directoryEnumerationOptions() -> FileManager.DirectoryEnumerationOptions {
        SZSettings.bool(.showHiddenFiles) ? [] : [.skipsHiddenFiles]
    }

    private func captureSelectionState() -> FileManagerFileSystemSelectionState {
        guard isViewLoaded(), !isInsideArchive() else {
            return .empty
        }

        let selectedItems = selectedFileSystemItems()
        let selectedPaths = Set(selectedItems.map(\.url.standardizedFileURL.path))
        let focusedPath = focusedFileSystemItemPath() ?? selectedItems.first?.url.standardizedFileURL.path
        return FileManagerFileSystemSelectionState(selectedPaths: selectedPaths,
                                                   focusedPath: focusedPath)
    }

    private func restoreSelectionState(_ selectionState: FileManagerFileSystemSelectionState) {
        guard !isInsideArchive() else { return }

        let baseRow = showsParentRow() ? 1 : 0
        let selectedRows = IndexSet(items.enumerated().compactMap { index, item in
            selectionState.selectedPaths.contains(item.url.standardizedFileURL.path) ? baseRow + index : nil
        })

        if selectedRows.isEmpty {
            deselectRows()
            return
        }

        selectRows(selectedRows)

        if let focusedPath = selectionState.focusedPath,
           let row = items.firstIndex(where: { $0.url.standardizedFileURL.path == focusedPath }).map({ baseRow + $0 })
        {
            scrollRowToVisible(row)
        } else if let firstRow = selectedRows.first {
            scrollRowToVisible(firstRow)
        }
    }

    private func scheduleDirectorySnapshot(for url: URL,
                                           purpose: SnapshotPurpose)
    {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let options = directoryEnumerationOptions()

        snapshotQueue.async {
            let result = Result {
                try FileManagerDirectorySnapshot.make(for: url,
                                                      options: options)
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishDirectorySnapshot(result,
                                                  generation: generation,
                                                  purpose: purpose)
                }
            }
        }
    }

    private func cancelPendingSnapshot() {
        snapshotGeneration += 1
    }

    private func finishDirectorySnapshot(_ result: Result<FileManagerDirectorySnapshot, Error>,
                                         generation: Int,
                                         purpose: SnapshotPurpose)
    {
        guard generation == snapshotGeneration else { return }

        switch result {
        case let .success(snapshot):
            guard !isInsideArchive() else { return }

            switch purpose {
            case let .autoRefresh(selectionState):
                guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
                guard snapshot.fingerprint != currentDirectoryFingerprint else { return }
                applyDirectorySnapshot(snapshot)
                restoreSelectionState(selectionState)

            case let .refresh(selectionState):
                guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
                applyDirectorySnapshot(snapshot)
                restoreSelectionState(selectionState)
            }

        case .failure:
            return
        }
    }

    private func applyDirectorySnapshot(_ snapshot: FileManagerDirectorySnapshot) {
        currentDirectory = snapshot.url
        recordDirectoryVisit(snapshot.url)
        updatePathField()
        currentDirectoryFingerprint = snapshot.fingerprint
        items = snapshot.items
        updateTableColumns()
        sortCurrentItems()
        reloadTableData()
        updateStatusBar()
        installDirectoryWatcher(for: snapshot.url)
    }

    private func recordDirectoryVisit(_ url: URL) {
        recentDirectories = FileManagerRecentDirectoryHistory.recordingVisit(url,
                                                                             in: recentDirectories)
    }

    private func installDirectoryWatcher(for url: URL) {
        directoryWatcher?.stop()
        let watcher = DirectoryWatcher(directory: url)
        watcher.onChange = { [weak self] in
            self?.directoryDidChange()
        }
        directoryWatcher = watcher
    }

    private func tearDownDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }
}
