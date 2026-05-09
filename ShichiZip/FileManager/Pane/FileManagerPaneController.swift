import Cocoa
import os

/// Single pane of the file manager — displays file system contents
class FileManagerPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSMenuItemValidation, FileManagerPaneTransferHost {
    // MARK: - Types

    private static let addressBarIconSize: CGFloat = 14
    private static var directorySnapshotQueueLabel: String {
        "\(Bundle.main.bundleIdentifier ?? "ShichiZip").file-manager.directory-snapshot"
    }

    // MARK: - Properties

    weak var delegate: FileManagerPaneDelegate?
    weak var archiveCoordinationProvider: (any FileManagerArchiveCoordinationProviding)?

    private var locationIconView: NSImageView!
    private var pathField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var listViewCoordinator: FileManagerPaneListViewCoordinator!
    private var menuCoordinator: FileManagerPaneMenuCoordinator!
    private var settingsObserver: NSObjectProtocol?
    private var viewPreferencesObserver: NSObjectProtocol?
    private var archiveChangeObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var liveScrollStartObserver: NSObjectProtocol?
    private var liveScrollEndObserver: NSObjectProtocol?
    private var columnDidMoveObserver: NSObjectProtocol?
    private var columnDidResizeObserver: NSObjectProtocol?
    private var recentDirectories: [URL] = []
    private var isLiveScrolling = false
    private var pendingAutoRefresh = false
    private var directorySnapshotGeneration = 0
    private let directorySnapshotQueue = DispatchQueue(label: FileManagerPaneController.directorySnapshotQueueLabel,
                                                       qos: .userInitiated)
    private var directoryWatcher: DirectoryWatcher?
    private let iconProvider = FileManagerPaneIconProvider(iconSize: NSSize(width: 16, height: 16))
    private let transferCoordinator = FileManagerPaneTransferCoordinator()
    private var iconSize: NSSize {
        iconProvider.iconSize
    }

    private let listRowHeight: CGFloat = 22
    private var currentDirectoryFingerprint: [FileManagerDirectorySnapshot.EntryFingerprint] = []
    private(set) var isSuspended = false
    private var suspendedOverlay: NSView?

    private(set) var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var currentDirectoryURL: URL {
        currentDirectory
    }

    private var items: [FileSystemItem] = []

    private let archiveSession = FileManagerArchiveSession()
    private var archiveCoordinatorStorage: FileManagerPaneArchiveCoordinator?
    private var isInsideArchive: Bool {
        archiveSession.isInsideArchive
    }

    private var archiveCoordinator: FileManagerPaneArchiveCoordinator {
        if let archiveCoordinatorStorage {
            return archiveCoordinatorStorage
        }

        let coordinator = FileManagerPaneArchiveCoordinator(
            archiveSession: archiveSession,
            observerIdentifier: ObjectIdentifier(self),
            parentWindow: { [weak self] in
                guard let self, isViewLoaded else { return nil }
                return view.window
            },
            isViewLoaded: { [weak self] in
                self?.isViewLoaded == true
            },
            presentCurrentArchiveSubdir: { [weak self] in
                self?.presentCurrentArchiveSubdir()
            },
            updateTableColumns: { [weak self] in
                self?.updateTableColumnsForCurrentLocation()
            },
            selectArchivePaths: { [weak self] paths in
                self?.selectArchivePaths(paths)
            },
            showError: { [weak self] error in
                self?.showErrorAlert(error)
            },
        )
        archiveCoordinatorStorage = coordinator
        return coordinator
    }

    var supportsInPlaceArchiveMutation: Bool {
        archiveSession.supportsInPlaceMutation(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance(for:))
    }

    private var showsRealFileIcons: Bool {
        SZSettings.bool(.showRealFileIcons)
    }

    private var showsParentRow: Bool {
        guard SZSettings.bool(.showDots) else {
            return false
        }
        if isInsideArchive {
            return true
        }
        return currentDirectory.path != currentDirectory.deletingLastPathComponent().path
    }

    private var tableModel: FileManagerPaneTableModel {
        if isInsideArchive {
            return FileManagerPaneTableModel(archiveItems: archiveSession.displayItems,
                                             showsParentRow: showsParentRow)
        }
        return FileManagerPaneTableModel(fileSystemItems: items,
                                         showsParentRow: showsParentRow)
    }

    // MARK: - Lifecycle

    isolated deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let viewPreferencesObserver {
            NotificationCenter.default.removeObserver(viewPreferencesObserver)
        }
        if let archiveChangeObserver {
            NotificationCenter.default.removeObserver(archiveChangeObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        if let liveScrollStartObserver {
            NotificationCenter.default.removeObserver(liveScrollStartObserver)
        }
        if let liveScrollEndObserver {
            NotificationCenter.default.removeObserver(liveScrollEndObserver)
        }
        if let columnDidMoveObserver {
            NotificationCenter.default.removeObserver(columnDidMoveObserver)
        }
        if let columnDidResizeObserver {
            NotificationCenter.default.removeObserver(columnDidResizeObserver)
        }

        tearDownDirectoryWatcher()
        cancelPendingDirectorySnapshot()
        cancelPendingArchiveRefresh()

        let preservedTemporaryDirectories = preserveNestedArchiveTemporaryDirectories()
        let didCloseAllArchives = closeAllArchives(showError: false)
        if didCloseAllArchives {
            archiveCoordinator.cleanupAllTemporaryDirectories()
        } else {
            preserveRemainingTemporaryDirectories(preservedTemporaryDirectories)
        }
    }

    // MARK: - View Setup

    override func loadView() {
        let paneView = FileManagerPaneView(currentDirectory: currentDirectory,
                                           addressBarIconSize: Self.addressBarIconSize,
                                           listRowHeight: listRowHeight)

        connectPaneView(paneView)
        installTableColumnObservers()
        installScrollObservers()
        installModelObservers()
        applyFileManagerSettings()

        view = paneView
        loadInitialDirectory(currentDirectory)
    }

    private func connectPaneView(_ paneView: FileManagerPaneView) {
        paneView.upButton.target = self
        paneView.upButton.action = #selector(goUpClicked(_:))

        locationIconView = paneView.locationIconView
        configurePathField(paneView.pathField)
        configureTableView(paneView.tableView)
        scrollView = paneView.scrollView
        statusLabel = paneView.statusLabel
    }

    private func configurePathField(_ textField: NSTextField) {
        pathField = textField
        pathField.target = self
        pathField.action = #selector(pathFieldSubmitted(_:))
        pathField.delegate = self
    }

    private func configureTableView(_ fileTableView: FileManagerTableView) {
        tableView = fileTableView
        listViewCoordinator = FileManagerPaneListViewCoordinator(tableView: tableView)
        menuCoordinator = FileManagerPaneMenuCoordinator(
            tableView: tableView,
            activatePane: { [weak self] in
                guard let self else { return }
                delegate?.paneDidBecomeActive(self)
            },
            populateColumnHeaderMenu: { [weak self] menu in
                self?.populateColumnHeaderMenu(menu)
            },
        )

        fileTableView.contextMenuPreparationHandler = { [weak self] clickedRow in
            guard let self else { return }
            menuCoordinator.prepareContextMenu(forClickedRow: clickedRow,
                                               presentationWindow: view.window)
        }
        fileTableView.quickLookPreviewHandler = { [weak self] in
            guard let self else { return }
            delegate?.paneDidRequestQuickLook(self)
        }
        fileTableView.shortcutEventHandler = { [weak self] event in
            self?.handleShortcutEvent(event) ?? false
        }
        configureTableColumns(FileManagerColumn.fileSystemColumns,
                              folderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID)
        tableView.headerView?.menu = menuCoordinator.makeColumnHeaderMenu(delegate: self)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        refreshContextMenu()
        SZLog.debug("ShichiZip", "File manager pane context menu set with \(tableView.menu?.items.count ?? 0) items")

        tableView.registerForDraggedTypes([.fileURL] + FileOperationDropResolver.promisedFilePasteboardTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    private func installTableColumnObservers() {
        columnDidMoveObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidMoveNotification,
            object: tableView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTableColumnLayoutDidChange()
            }
        }

        columnDidResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: tableView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTableColumnLayoutDidChange()
            }
        }
    }

    private func installScrollObservers() {
        liveScrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveScrolling = true
            }
        }

        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLiveScrolling = false

                guard self.pendingAutoRefresh else { return }
                self.pendingAutoRefresh = false
                self.autoRefreshCurrentDirectoryIfNeeded()
            }
        }
    }

    private func installModelObservers() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .szSettingsDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let settingsKey = (notification.userInfo?["key"] as? String)
                .flatMap(SZSettingsKey.init(rawValue:))
            MainActor.assumeIsolated {
                guard let settingsKey else { return }
                self?.handleSettingsDidChange(settingsKey)
            }
        }

        viewPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerViewPreferencesDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let shouldResetListViewPreferences = notification.userInfo?[FileManagerViewPreferences.listViewPreferencesResetUserInfoKey] as? Bool == true
            MainActor.assumeIsolated {
                if shouldResetListViewPreferences {
                    self?.resetTableColumnsForCurrentLocation()
                } else {
                    self?.reloadPresentedValues()
                }
            }
        }

        archiveChangeObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerArchiveDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let change = FileManagerArchiveChange(notification: notification)
            MainActor.assumeIsolated {
                guard let self,
                      let change
                else {
                    return
                }
                self.handlePublishedArchiveChange(change)
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: .szLanguageDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshColumnTitles()
                self?.refreshContextMenu()
                self?.updateStatusBar()
            }
        }
    }

    // MARK: - Navigation

    private struct FileSystemSelectionState {
        let selectedPaths: Set<String>
        let focusedPath: String?

        static let empty = FileSystemSelectionState(selectedPaths: [], focusedPath: nil)
    }

    private enum DirectorySnapshotPurpose {
        case refresh(selectionState: FileSystemSelectionState)
        case autoRefresh(selectionState: FileSystemSelectionState)
    }

    @discardableResult
    func loadDirectory(_ url: URL,
                       showError: Bool = true) -> Bool
    {
        navigateToDirectory(url, showError: showError)
    }

    @discardableResult
    private func navigateToDirectory(_ url: URL,
                                     showError: Bool,
                                     selectionState: FileSystemSelectionState? = nil,
                                     focusAfterLoad: Bool = false) -> Bool
    {
        cancelPendingDirectorySnapshot()

        do {
            let snapshot = try FileManagerDirectorySnapshot.make(for: url.standardizedFileURL,
                                                                 options: fileManagerDirectoryEnumerationOptions())
            applyDirectorySnapshot(snapshot)
            if isSuspended {
                clearSuspendedState()
            }
            if let selectionState {
                restoreFileSystemSelectionState(selectionState)
            }
            if focusAfterLoad {
                focusFileList()
            }
            return true
        } catch {
            if showError {
                showErrorAlert(error)
            }
            return false
        }
    }

    private func fileManagerDirectoryEnumerationOptions() -> FileManager.DirectoryEnumerationOptions {
        SZSettings.bool(.showHiddenFiles) ? [] : [.skipsHiddenFiles]
    }

    private func captureFileSystemSelectionState() -> FileSystemSelectionState {
        guard isViewLoaded, !isInsideArchive else {
            return .empty
        }

        let selectedPaths = Set(selectedFileSystemItems().map(\.url.standardizedFileURL.path))
        let focusedPath: String? = if let focusedItem = paneItem(at: tableView.selectedRow),
                                      case let .filesystem(item) = focusedItem
        {
            item.url.standardizedFileURL.path
        } else {
            selectedFileSystemItems().first?.url.standardizedFileURL.path
        }

        return FileSystemSelectionState(selectedPaths: selectedPaths, focusedPath: focusedPath)
    }

    private func restoreFileSystemSelectionState(_ selectionState: FileSystemSelectionState) {
        guard !isInsideArchive else { return }

        let baseRow = showsParentRow ? 1 : 0
        let selectedRows = IndexSet(items.enumerated().compactMap { index, item in
            selectionState.selectedPaths.contains(item.url.standardizedFileURL.path) ? baseRow + index : nil
        })

        if selectedRows.isEmpty {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)

        if let focusedPath = selectionState.focusedPath,
           let row = items.firstIndex(where: { $0.url.standardizedFileURL.path == focusedPath }).map({ baseRow + $0 })
        {
            tableView.scrollRowToVisible(row)
        } else if let firstRow = selectedRows.first {
            tableView.scrollRowToVisible(firstRow)
        }
    }

    private func reloadCurrentDirectoryPreservingSelection() {
        let selectionState = captureFileSystemSelectionState()
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .refresh(selectionState: selectionState))
    }

    private func autoRefreshCurrentDirectoryIfNeeded() {
        let selectionState = captureFileSystemSelectionState()
        scheduleDirectorySnapshot(for: currentDirectory,
                                  purpose: .autoRefresh(selectionState: selectionState))
    }

    private func scheduleDirectorySnapshot(for url: URL,
                                           purpose: DirectorySnapshotPurpose)
    {
        directorySnapshotGeneration += 1
        let generation = directorySnapshotGeneration
        let options = fileManagerDirectoryEnumerationOptions()

        directorySnapshotQueue.async {
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

    private func cancelPendingDirectorySnapshot() {
        directorySnapshotGeneration += 1
    }

    private func finishDirectorySnapshot(_ result: Result<FileManagerDirectorySnapshot, Error>,
                                         generation: Int,
                                         purpose: DirectorySnapshotPurpose)
    {
        guard generation == directorySnapshotGeneration else { return }

        switch result {
        case let .success(snapshot):
            guard !isInsideArchive else { return }

            switch purpose {
            case let .autoRefresh(selectionState):
                guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
                guard snapshot.fingerprint != currentDirectoryFingerprint else { return }
                applyDirectorySnapshot(snapshot)
                restoreFileSystemSelectionState(selectionState)

            case let .refresh(selectionState):
                guard snapshot.url.standardizedFileURL == currentDirectory.standardizedFileURL else { return }
                applyDirectorySnapshot(snapshot)
                restoreFileSystemSelectionState(selectionState)
            }

        case .failure:
            return
        }
    }

    private func loadInitialDirectory(_ url: URL) {
        do {
            let snapshot = try FileManagerDirectorySnapshot.make(for: url.standardizedFileURL,
                                                                 options: fileManagerDirectoryEnumerationOptions())
            applyDirectorySnapshot(snapshot)
        } catch {
            currentDirectory = url.standardizedFileURL
            updatePathField()
            updateStatusBar()
        }
    }

    private func applyDirectorySnapshot(_ snapshot: FileManagerDirectorySnapshot) {
        currentDirectory = snapshot.url
        recordDirectoryVisit(snapshot.url)
        updatePathField()
        currentDirectoryFingerprint = snapshot.fingerprint
        items = snapshot.items
        updateTableColumnsForCurrentLocation()
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
        updateStatusBar()
        installDirectoryWatcher(for: snapshot.url)
    }

    private func columnsForCurrentLocation() -> [FileManagerColumn] {
        if let level = archiveSession.currentLevel {
            return FileManagerColumn.archiveColumns(entryProperties: level.entryProperties)
        }
        return FileManagerColumn.fileSystemColumns
    }

    private func updateTableColumnsForCurrentLocation() {
        guard isViewLoaded else { return }
        configureTableColumns(columnsForCurrentLocation(),
                              folderTypeID: listViewFolderTypeIDForCurrentLocation())
    }

    private func configureTableColumns(_ columns: [FileManagerColumn],
                                       folderTypeID: String,
                                       preferSavedState: Bool = true)
    {
        listViewCoordinator.configure(columns: columns,
                                      folderTypeID: folderTypeID,
                                      preferSavedState: preferSavedState)
    }

    private func refreshColumnTitles() {
        listViewCoordinator.refreshColumnTitles(columns: columnsForCurrentLocation(),
                                                fallbackFolderTypeID: listViewFolderTypeIDForCurrentLocation())
    }

    private func listViewFolderTypeIDForCurrentLocation() -> String {
        if let level = archiveSession.currentLevel {
            return FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: level.archive.formatName)
        }
        return FileManagerViewPreferences.fileSystemListViewFolderTypeID
    }

    private func handleTableColumnLayoutDidChange() {
        listViewCoordinator.handleColumnLayoutDidChange(availableColumns: columnsForCurrentLocation())
    }

    private func persistCurrentListViewInfo() {
        guard isViewLoaded else { return }
        listViewCoordinator.persistCurrentInfo(availableColumns: columnsForCurrentLocation())
    }

    private func resetTableColumnsForCurrentLocation() {
        guard isViewLoaded else { return }
        listViewCoordinator.reset(columns: columnsForCurrentLocation(),
                                  folderTypeID: listViewFolderTypeIDForCurrentLocation())
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func updateHighlightedTableColumn(for sortKey: String?) {
        listViewCoordinator.updateHighlightedColumn(for: sortKey)
    }

    private func clearSuspendedState() {
        guard isSuspended else { return }
        isSuspended = false
        suspendedOverlay?.removeFromSuperview()
        suspendedOverlay = nil
    }

    private func installDirectoryWatcher(for url: URL) {
        directoryWatcher?.stop()
        let watcher = DirectoryWatcher(directory: url)
        watcher.onChange = { [weak self] in
            self?.autoRefreshIfPossible()
        }
        directoryWatcher = watcher
    }

    private func tearDownDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }

    // MARK: - Pane Refresh And Focus

    func refresh() {
        if isInsideArchive {
            let selectedPaths = selectedArchiveItems().map { normalizeArchivePath($0.path) }
            reloadCurrentArchiveEntries(selectingPaths: selectedPaths)
        } else {
            reloadCurrentDirectoryPreservingSelection()
        }
    }

    func autoRefreshIfPossible() {
        guard isViewLoaded else { return }
        guard FileManagerViewPreferences.autoRefreshEnabled else { return }
        guard !isInsideArchive else { return }
        guard directoryWatcher?.wasChanged() == true else { return }
        guard !isLiveScrolling else {
            pendingAutoRefresh = true
            return
        }

        pendingAutoRefresh = false
        autoRefreshCurrentDirectoryIfNeeded()
    }

    func reloadPresentedValues() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateStatusBar()
    }

    func focusFileList() {
        delegate?.paneDidBecomeActive(self)
        view.window?.makeFirstResponder(tableView)
    }

    var preferredInitialFirstResponder: NSView {
        tableView
    }

    var isVirtualLocation: Bool {
        isInsideArchive
    }

    // MARK: - Archive Mutation Targets

    func currentArchiveMutationTarget() -> (archive: SZArchive, subdir: String)? {
        guard let target = archiveSession.currentMutationTarget(hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance(for:)) else { return nil }
        return (target.archive, target.subdir)
    }

    func revalidatedArchiveMutationTarget(for target: (archive: SZArchive, subdir: String)) -> (archive: SZArchive, subdir: String)? {
        guard let archiveURL = archiveSession.archiveURL(for: target.archive) else {
            return nil
        }

        return currentArchiveMutationTarget(for: archiveURL,
                                            subdir: target.subdir)
    }

    func currentArchiveDestinationDisplayPath() -> String? {
        guard isInsideArchive, supportsInPlaceArchiveMutation else {
            return nil
        }
        return currentLocationDisplayPath
    }

    func currentArchiveMutationTarget(for archiveURL: URL,
                                      subdir: String) -> (archive: SZArchive, subdir: String)?
    {
        guard let level = archiveSession.currentLevel,
              URL(fileURLWithPath: level.archivePath).standardizedFileURL == archiveURL.standardizedFileURL
        else {
            return nil
        }

        guard let target = archiveSession.mutationTarget(for: level,
                                                         subdir: subdir,
                                                         hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance(for:))
        else {
            return nil
        }

        return (target.archive, target.subdir)
    }

    private func transferArchiveTarget(for archive: SZArchive,
                                       subdir: String) -> FileManagerPaneArchiveTransferTarget?
    {
        guard let archiveURL = archiveSession.archiveURL(for: archive),
              let target = currentArchiveMutationTarget(for: archiveURL,
                                                        subdir: subdir)
        else {
            return nil
        }

        return FileManagerPaneArchiveTransferTarget(archive: target.archive,
                                                    subdir: target.subdir,
                                                    archiveURL: archiveURL)
    }

    // MARK: - Command Capabilities

    var canQuickLookSelection: Bool {
        !selectedRealPaneItems().isEmpty
    }

    func canAddSelectedItemsToArchive() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation
        }
        return !selectedFileSystemItems().isEmpty
    }

    func canCreateFolderHere() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation
        }
        return true
    }

    func canCopySelection() -> Bool {
        if isInsideArchive {
            return !selectedArchiveItems().isEmpty
        }
        return !selectedFileSystemItems().isEmpty
    }

    func canMoveSelection() -> Bool {
        !isInsideArchive && !selectedFileSystemItems().isEmpty
    }

    func canDeleteSelection() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation && !selectedArchiveItems().isEmpty
        }
        return !selectedFileSystemItems().isEmpty
    }

    func canRenameSelection() -> Bool {
        if isInsideArchive {
            return supportsInPlaceArchiveMutation && selectedArchiveItems().count == 1
        }
        return selectedFileSystemItems().count == 1
    }

    func canExtractSelectionOrArchive() -> Bool {
        if isInsideArchive {
            return !archiveItemsForSelectionOrDisplayedItems().isEmpty
        }
        return selectedArchiveCandidateURL() != nil
    }

    func canTestArchiveSelection() -> Bool {
        if isInsideArchive {
            return archiveSession.currentLevel != nil
        }
        return selectedArchiveCandidateURL() != nil
    }

    func canOpenSelection() -> Bool {
        !selectedPaneItems().isEmpty
    }

    func canOpenSelectionInside() -> Bool {
        selectedRealPaneItems().count == 1
    }

    func canOpenSelectionOutside() -> Bool {
        guard let item = selectedSingleRealPaneItem() else { return false }

        switch item {
        case .parent:
            return false
        case .filesystem:
            return true
        case let .archive(archiveItem):
            return !archiveItem.isDirectory
        }
    }

    func canCreateFileHere() -> Bool {
        !isInsideArchive
    }

    func canCalculateSelectionHashes() -> Bool {
        selectedSingleFileSystemFile() != nil
    }

    func canShowSelectedItemProperties() -> Bool {
        !selectedRealPaneItems().isEmpty
    }

    func canGoUp() -> Bool {
        isInsideArchive || currentDirectory.path != currentDirectory.deletingLastPathComponent().path
    }

    func canSelectVisibleItems() -> Bool {
        let firstSelectableRow = showsParentRow ? 1 : 0
        return numberOfRows(in: tableView) > firstSelectableRow
    }

    func canDeselectSelection() -> Bool {
        !tableView.selectedRowIndexes.isEmpty
    }

    func canShowFoldersHistory() -> Bool {
        !recentDirectories.isEmpty
    }

    func selectedArchiveCandidateURL() -> URL? {
        let selectedItems = selectedFileSystemItems()
        guard selectedItems.count == 1, !selectedItems[0].isDirectory else { return nil }
        return selectedItems[0].url
    }

    func sourceArchiveURLForPostProcessing() -> URL? {
        if let level = archiveSession.currentLevel, level.temporaryDirectory == nil {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return selectedArchiveCandidateURL()?.standardizedFileURL
    }

    func quarantineSourceArchiveURLForExtraction() -> URL? {
        if let level = archiveSession.currentLevel {
            return URL(fileURLWithPath: level.archivePath).standardizedFileURL
        }

        return selectedArchiveCandidateURL()?.standardizedFileURL
    }

    // MARK: - Command Entry Points

    func openSelection() {
        openSelectedItem(nil)
    }

    func openSelectionInside(_ openMode: FileManagerArchiveOpenMode) {
        guard let item = selectedSingleRealPaneItem() else { return }

        switch item {
        case .parent:
            return

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                loadDirectory(fileSystemItem.url)
            } else {
                _ = openArchiveInline(fileSystemItem.url,
                                      hostDirectory: currentDirectory,
                                      openMode: openMode)
            }

        case let .archive(archiveItem):
            if archiveItem.isDirectory {
                navigateArchiveSubdir(archiveItem.pathParts.joined(separator: "/"))
            } else {
                openItemInArchive(archiveItem, strategy: .forceInternal(openMode))
            }
        }
    }

    func openSelectionOutside() {
        guard let item = selectedSingleRealPaneItem() else { return }

        switch item {
        case .parent:
            return

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                _ = NSWorkspace.shared.open(fileSystemItem.url)
                return
            }

            if !openExternallyIfPossible(fileSystemItem.url) {
                showErrorAlert(unavailableExternalOpenError(for: fileSystemItem.name))
            }

        case let .archive(archiveItem):
            guard !archiveItem.isDirectory,
                  let context = currentArchiveItemWorkflowContext() else { return }

            openArchiveItemExternally(archiveItem,
                                      context: context,
                                      strategy: .forceExternal)
        }
    }

    func goUpOneLevel() {
        goUp()
    }

    func renameSelection() {
        renameSelected(nil)
    }

    func deleteSelection() {
        deleteSelected(nil)
    }

    func showSelectedItemProperties() {
        showItemProperties(nil)
    }

    func extractSelectionHere() {
        FileManagerPaneMutationCommandSupport.extractHere(in: self)
    }

    func openRootFolder() {
        if isInsideArchive {
            navigateArchiveSubdir("")
            return
        }

        loadDirectory(FileManagerFileSystemNavigation.rootURL(for: currentDirectory))
    }

    // MARK: - Recent Directories

    func recentDirectoryHistory() -> [URL] {
        recentDirectories
    }

    func setRecentDirectoryHistory(_ entries: [URL]) {
        recentDirectories = FileManagerRecentDirectoryHistory.normalized(entries)
    }

    func openRecentDirectory(_ url: URL) {
        if isInsideArchive, !closeAllArchives(showError: true) {
            return
        }
        loadDirectory(url)
    }

    // MARK: - Selection Commands

    func selectAllItems() {
        let rowCount = numberOfRows(in: tableView)
        let firstSelectableRow = showsParentRow ? 1 : 0
        guard rowCount > firstSelectableRow else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integersIn: firstSelectableRow ..< rowCount),
                                   byExtendingSelection: false)
    }

    func deselectAllItems() {
        tableView.deselectAll(nil)
    }

    func invertSelection() {
        let rowCount = numberOfRows(in: tableView)
        let firstSelectableRow = showsParentRow ? 1 : 0
        guard rowCount > firstSelectableRow else { return }

        let currentSelection = tableView.selectedRowIndexes
        var inverseSelection = IndexSet()
        for row in firstSelectableRow ..< rowCount where !currentSelection.contains(row) {
            inverseSelection.insert(row)
        }
        tableView.selectRowIndexes(inverseSelection, byExtendingSelection: false)
    }

    // MARK: - Sort Commands

    func sortByName() {
        applySortDescriptor(columnIdentifier: "name",
                            key: "name",
                            ascending: true,
                            selector: #selector(NSString.localizedStandardCompare(_:)))
    }

    func sortBySize() {
        applySortDescriptor(columnIdentifier: "size",
                            key: "size",
                            ascending: false)
    }

    func sortByType() {
        applySortDescriptor(columnIdentifier: "name",
                            key: "type",
                            ascending: true,
                            selector: #selector(NSString.localizedStandardCompare(_:)))
    }

    func sortByModifiedDate() {
        applySortDescriptor(columnIdentifier: "modified",
                            key: "modified",
                            ascending: false)
    }

    func sortByCreatedDate() {
        applySortDescriptor(columnIdentifier: "created",
                            key: "created",
                            ascending: false)
    }

    var primarySortKey: String? {
        tableView.sortDescriptors.first?.key
    }

    var currentLocationDisplayPath: String {
        isInsideArchive ? currentArchiveDisplayPathPrefix() : currentDirectory.path
    }

    var selectedRealItemCount: Int {
        selectedRealPaneItems().count
    }

    // MARK: - Extraction Dialog State

    var suggestedExtractDestinationName: String? {
        if let level = archiveSession.currentLevel {
            if !level.currentSubdir.isEmpty {
                return level.currentSubdir.split(separator: "/").last.map(String.init)
            }

            let archiveURL = URL(fileURLWithPath: level.archivePath)
            return archiveURL.deletingPathExtension().lastPathComponent
        }

        guard let archiveURL = selectedArchiveCandidateURL() else {
            return nil
        }

        return archiveURL.deletingPathExtension().lastPathComponent
    }

    func selectedOrDisplayedArchiveEntriesForExtraction() -> [ArchiveItem] {
        guard let context = currentArchiveExtractionContext else { return [] }

        let indices = Set(FileManagerArchiveExtraction.entryIndices(for: archiveItemsForSelectionOrDisplayedItems(),
                                                                    allEntries: context.allEntries).map(\.intValue))
        return context.allEntries.filter { indices.contains($0.index) }
    }

    func pathPrefixToStripForCurrentExtraction(destinationURL: URL,
                                               pathMode: SZPathMode,
                                               eliminateDuplicates: Bool) -> String?
    {
        guard let context = currentArchiveExtractionContext else { return nil }

        return FileManagerArchiveExtraction.pathPrefixToStrip(for: archiveItemsForSelectionOrDisplayedItems(),
                                                              context: context,
                                                              destinationURL: destinationURL,
                                                              pathMode: pathMode,
                                                              eliminateDuplicates: eliminateDuplicates)
    }

    func selectedItemNames(limit: Int? = nil) -> [String] {
        if isInsideArchive {
            return FileManagerItemPresentation.displayNames(for: selectedArchiveItems(), limit: limit)
        }
        return FileManagerItemPresentation.displayNames(for: selectedFileSystemItems(), limit: limit)
    }

    func extractDialogInfoText(previewItemLimit: Int = 5) -> String {
        guard isInsideArchive else {
            return FileManagerItemPresentation.fileSystemItemsInfoText(location: currentLocationDisplayPath,
                                                                       items: selectedFileSystemItems(),
                                                                       previewItemLimit: previewItemLimit)
        }

        return FileManagerItemPresentation.archiveItemsInfoText(location: currentLocationDisplayPath,
                                                                items: archiveItemsForSelectionOrDisplayedItems(),
                                                                previewItemLimit: previewItemLimit,
                                                                includeSummary: true)
    }

    // MARK: - Quick Look Preparation

    func prepareQuickLookPreviewForFileSystem() throws -> FileManagerQuickLookPreparedPreview? {
        guard !isInsideArchive else { return nil }

        let selectedEntries = selectedQuickLookRowsAndItems()
        guard !selectedEntries.isEmpty else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.selectItems"))
        }

        let selection = selectedEntries.compactMap { entry -> FileManagerQuickLookFileSystemSelection? in
            guard case let .filesystem(item) = entry.item else { return nil }
            return FileManagerQuickLookFileSystemSelection(item: item,
                                                           source: quickLookSourceInfo(forRow: entry.row,
                                                                                       paneItem: entry.item))
        }
        return try FileManagerQuickLookPreparation.fileSystemPreview(for: selection)
    }

    @MainActor
    func prepareQuickLookPreview(maxArchiveItemSize: UInt64,
                                 maxArchiveCombinedSize: UInt64,
                                 maxSolidArchiveSize: UInt64) async throws -> FileManagerQuickLookPreparedPreview
    {
        if let filesystemPreview = try prepareQuickLookPreviewForFileSystem() {
            return filesystemPreview
        }

        let selectedEntries = selectedQuickLookRowsAndItems()
        guard !selectedEntries.isEmpty else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.selectItems"))
        }

        guard let level = archiveSession.currentLevel else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.cannotPreviewArchive"))
        }

        let archiveSelection = selectedEntries.compactMap { entry -> (row: Int, item: ArchiveItem)? in
            guard case let .archive(item) = entry.item else { return nil }
            return (entry.row, item)
        }
        let archiveItems = archiveSelection.map(\.item)
        try FileManagerQuickLookPreparation.validateArchiveItems(archiveItems,
                                                                 archiveHasActiveOperations: level.operationGate.hasActiveLeases,
                                                                 isSolidArchive: level.archive.isSolidArchive,
                                                                 archiveSizeProvider: {
                                                                     FileManagerQuickLookPreparation.archivePhysicalSize(reportedSize: level.archive.archivePhysicalSize,
                                                                                                                         archivePath: level.archivePath)
                                                                 },
                                                                 maxArchiveItemSize: maxArchiveItemSize,
                                                                 maxArchiveCombinedSize: maxArchiveCombinedSize,
                                                                 maxSolidArchiveSize: maxSolidArchiveSize)

        guard let context = currentArchiveItemWorkflowContext() else {
            throw FileManagerQuickLookPreparation.error(SZL10n.string("app.fileManager.quickLook.cannotPreviewArchive"))
        }

        let stagedPreview = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("app.progress.working"),
                                                                 initialFileName: archiveItems.count == 1 ? archiveItems[0].path : nil,
                                                                 parentWindow: view.window,
                                                                 deferredDisplay: true)
        { [archiveSession] session in
            try archiveSession.itemWorkflowService.stageQuickLookItems(archiveItems,
                                                                       context: context,
                                                                       session: session)
        }

        let previewSelection = archiveSelection.map { selection in
            FileManagerQuickLookArchiveSelection(item: selection.item,
                                                 source: quickLookSourceInfo(forRow: selection.row,
                                                                             paneItem: .archive(selection.item)))
        }
        let previewItems = FileManagerQuickLookPreparation.archivePreviewItems(for: previewSelection,
                                                                               stagedFileURLs: stagedPreview.fileURLs)
        return FileManagerQuickLookPreparedPreview(items: previewItems,
                                                   temporaryDirectories: [stagedPreview.temporaryDirectory])
    }

    func cleanupQuickLookTemporaryDirectories(_ temporaryDirectories: [URL]) {
        for url in temporaryDirectories {
            archiveSession.cleanupTemporaryDirectory(url)
        }
    }

    func handleQuickLookEvent(_ event: NSEvent) -> Bool {
        if handleShortcutEvent(event) {
            return true
        }

        let action = FileManagerQuickLookEventHandling.keyAction(for: event)
        guard action != .ignore else {
            return false
        }

        delegate?.paneDidBecomeActive(self)

        switch action {
        case .activateSelection:
            doubleClickRow(nil)
        case .navigateUp:
            goUp()
        case .forwardToTable:
            tableView.keyDown(with: event)
        case .ignore:
            return false
        }

        return true
    }

    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        guard let command = FileManagerShortcuts.command(for: event) else {
            return false
        }

        delegate?.paneDidBecomeActive(self)
        return delegate?.pane(self, didRequestShortcutCommand: command) ?? false
    }

    // MARK: - File System Selection

    func selectedFilePaths() -> [String] {
        selectedFileSystemItems().map(\.url.path)
    }

    func selectedFileURLs() -> [URL] {
        selectedFileSystemItems().map(\.url.standardizedFileURL)
    }

    // MARK: - File System Navigation

    @discardableResult
    func revealFileSystemItemURLs(_ urls: [URL]) -> Bool {
        guard let target = FileManagerFileSystemNavigation.revealTarget(for: urls) else { return false }

        if isInsideArchive, !closeAllArchives(showError: true) {
            return false
        }

        let selectionState = FileSystemSelectionState(selectedPaths: target.selectedPaths,
                                                      focusedPath: target.focusedPath)
        navigateToDirectory(target.parentDirectory,
                            showError: true,
                            selectionState: selectionState,
                            focusAfterLoad: true)
        return true
    }

    @discardableResult
    func openFileSystemItemURL(_ url: URL) -> Bool {
        switch FileManagerFileSystemNavigation.openTarget(for: url) {
        case let .directory(directoryURL):
            if isInsideArchive, !closeAllArchives(showError: true) {
                return false
            }

            navigateToDirectory(directoryURL,
                                showError: true,
                                focusAfterLoad: true)
            return true
        case let .file(fileURL, hostDirectory):
            return openFileSystemArchiveURL(fileURL,
                                            hostDirectory: hostDirectory)
        case nil:
            return false
        }
    }

    private func openFileSystemArchiveURL(_ fileURL: URL,
                                          hostDirectory: URL) -> Bool
    {
        switch openArchiveInline(fileURL,
                                 hostDirectory: hostDirectory,
                                 showError: false,
                                 replaceCurrentState: true)
        {
        case .opened:
            focusFileList()
            return true
        case .unsupportedArchive:
            return revealFileSystemItemURLs([fileURL])
        case .cancelled:
            return false
        case let .failed(error):
            showErrorAlert(error)
            return false
        }
    }

    // MARK: - File System Transfer Validation

    nonisolated func transferFileSystemItemURLs(_ urls: [URL],
                                                to destinationDirectory: URL,
                                                operation: NSDragOperation,
                                                session: SZOperationSession) throws
    {
        try FileOperationFileSystemTransfer.perform(urls,
                                                    to: destinationDirectory,
                                                    operation: operation,
                                                    session: session)
    }

    func canTransferFileSystemItemURLs(_ urls: [URL],
                                       to destinationURL: URL,
                                       operation: NSDragOperation,
                                       presentingIn window: NSWindow?) -> Bool
    {
        guard let conflict = FileManagerTransferPathValidation.ancestryConflict(sourceURLs: urls,
                                                                                destinationURL: destinationURL)
        else {
            return true
        }

        szPresentTransferAncestryConflict(conflict,
                                          move: operation == .move,
                                          for: window)
        return false
    }

    func canTransferFileSystemItemURLsToArchive(_ urls: [URL],
                                                archiveURL: URL?,
                                                operation: NSDragOperation,
                                                presentingIn window: NSWindow?) -> Bool
    {
        guard let archiveURL else {
            return true
        }

        let standardizedArchiveURL = archiveURL.standardizedFileURL
        let standardizedSourceURLs = Set(urls.map(\.standardizedFileURL))
        guard !standardizedSourceURLs.contains(standardizedArchiveURL) else {
            szPresentTransferArchiveSelfConflict(move: operation == .move,
                                                 for: window)
            return false
        }

        guard let conflict = FileManagerTransferPathValidation.ancestryConflict(sourceURLs: urls,
                                                                                destinationURL: standardizedArchiveURL)
        else {
            return true
        }

        szPresentTransferAncestryConflict(conflict,
                                          move: operation == .move,
                                          for: window)
        return false
    }

    // MARK: - Creation Operations

    func createFolder(named name: String) {
        FileManagerPaneMutationCommandSupport.createFolder(named: name,
                                                           in: self)
    }

    func createFile(named name: String) {
        FileManagerPaneMutationCommandSupport.createFile(named: name,
                                                         in: self)
    }

    // MARK: - Presentation State

    private func updateStatusBar() {
        let displayedSummary = if isInsideArchive {
            FileManagerItemPresentation.summary(for: archiveSession.displayItems)
        } else {
            FileManagerItemPresentation.summary(for: items)
        }

        let selectedSummary: FileManagerItemStatusSummary? = if isInsideArchive {
            FileManagerItemPresentation.summary(for: selectedArchiveItems())
        } else {
            FileManagerItemPresentation.summary(for: selectedFileSystemItems())
        }

        statusLabel.stringValue = FileManagerItemPresentation.statusBarText(displayed: displayedSummary,
                                                                            selected: selectedSummary)
    }

    private func recordDirectoryVisit(_ url: URL) {
        recentDirectories = FileManagerRecentDirectoryHistory.recordingVisit(url,
                                                                             in: recentDirectories)
    }

    // MARK: - Settings

    private func applyFileManagerSettings() {
        tableView.style = .fullWidth
        tableView.gridStyleMask = SZSettings.bool(.showGridLines)
            ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
            : []
        tableView.allowsMultipleSelection = true

        if SZSettings.bool(.singleClickOpen) {
            tableView.action = #selector(singleClickRow(_:))
            tableView.doubleAction = nil
        } else {
            tableView.action = nil
            tableView.doubleAction = #selector(doubleClickRow(_:))
        }
    }

    private func handleSettingsDidChange(_ settingsKey: SZSettingsKey) {
        switch settingsKey {
        case .showDots, .showRealFileIcons, .showGridLines, .singleClickOpen:
            if settingsKey == .showRealFileIcons {
                iconProvider.removeAllCachedImages()
            }
            applyFileManagerSettings()
        case .showHiddenFiles:
            refresh()
            return
        case .fileManagerShortcutPreset, .fileManagerCustomShortcuts:
            refreshContextMenu()
            return
        default:
            return
        }

        tableView.reloadData()
        updateStatusBar()
    }

    // MARK: - Quick Look Presentation

    private func quickLookSourceInfo(forRow row: Int,
                                     paneItem: FileManagerPaneItem) -> FileManagerQuickLookItemSource
    {
        let transitionImage = makeQuickLookTransitionImage(for: paneItem)
        return FileManagerQuickLookItemSource(frameOnScreen: FileManagerQuickLookSourceGeometry.frameOnScreen(forRow: row,
                                                                                                              in: tableView,
                                                                                                              window: view.window,
                                                                                                              iconSize: iconSize),
                                              transitionImage: transitionImage)
    }

    private func makeQuickLookTransitionImage(for paneItem: FileManagerPaneItem) -> NSImage? {
        let itemName: String
        let isDirectory: Bool
        let iconPath: String

        switch paneItem {
        case .parent:
            return nil
        case let .filesystem(item):
            itemName = item.name
            isDirectory = item.isDirectory
            iconPath = item.url.path
        case let .archive(item):
            itemName = item.name
            isDirectory = item.isDirectory
            iconPath = item.path
        }

        return iconProvider.transitionImage(for: iconSource(for: paneItem,
                                                            isDirectory: isDirectory,
                                                            iconPath: iconPath),
                                            accessibilityDescription: itemName,
                                            showsRealFileIcons: showsRealFileIcons)
    }

    private func iconImage(for paneItem: FileManagerPaneItem, isDirectory: Bool, iconPath: String) -> NSImage? {
        iconProvider.image(for: iconSource(for: paneItem,
                                           isDirectory: isDirectory,
                                           iconPath: iconPath),
                           showsRealFileIcons: showsRealFileIcons)
    }

    private func iconSource(for paneItem: FileManagerPaneItem,
                            isDirectory: Bool,
                            iconPath: String) -> FileManagerPaneIconSource
    {
        switch paneItem {
        case .parent:
            .parent
        case .archive:
            .archive(isDirectory: isDirectory,
                     iconPath: iconPath)
        case .filesystem:
            .filesystem(isDirectory: isDirectory,
                        iconPath: iconPath)
        }
    }

    // MARK: - Item Activation

    private func activatePaneItem(at row: Int) {
        guard let item = paneItem(at: row) else { return }

        switch item {
        case .parent:
            goUp()

        case let .archive(archiveItem):
            if archiveItem.isDirectory {
                navigateArchiveSubdir(archiveItem.pathParts.joined(separator: "/"))
            } else {
                openItemInArchive(archiveItem)
            }

        case let .filesystem(fileSystemItem):
            if fileSystemItem.isDirectory {
                loadDirectory(fileSystemItem.url)
            } else {
                if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(fileSystemItem.url) {
                    if !openExternallyIfPossible(fileSystemItem.url) {
                        showErrorAlert(unavailableExternalOpenError(for: fileSystemItem.name))
                    }
                    return
                }

                switch openArchiveInline(fileSystemItem.url,
                                         hostDirectory: currentDirectory,
                                         showError: false)
                {
                case .opened:
                    break
                case let .unsupportedArchive(error):
                    let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: fileSystemItem.url)
                    if shouldFallbackExternally {
                        if !openExternallyIfPossible(fileSystemItem.url) {
                            showErrorAlert(error)
                        }
                    } else {
                        showErrorAlert(error)
                    }
                case .cancelled:
                    break
                case let .failed(error):
                    showErrorAlert(error)
                }
            }
        }
    }

    // MARK: - Archive Opening

    @discardableResult
    func showArchive(at url: URL) -> Bool {
        showArchive(at: url, openMode: .defaultBehavior)
    }

    @discardableResult
    func showArchive(at url: URL,
                     openMode: FileManagerArchiveOpenMode) -> Bool
    {
        let parentDirectory = url.deletingLastPathComponent()
        let result = openArchiveInline(url,
                                       hostDirectory: parentDirectory,
                                       openMode: openMode,
                                       replaceCurrentState: true)
        if case .opened = result {
            return true
        }
        return false
    }

    // MARK: - Archive Extraction And Testing

    func extractSelectedArchiveItems(to destinationURL: URL,
                                     session: SZOperationSession? = nil,
                                     overwriteMode: SZOverwriteMode = .ask,
                                     pathMode: SZPathMode = .currentPaths,
                                     password: String? = nil,
                                     preserveNtSecurityInfo: Bool = false,
                                     eliminateDuplicates: Bool = false,
                                     inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws
    {
        let selectedItems = selectedArchiveItems()
        guard !selectedItems.isEmpty else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.selectArchiveItems"))
        }
        try extractArchiveItems(selectedItems,
                                to: destinationURL,
                                session: session,
                                overwriteMode: overwriteMode,
                                pathMode: pathMode,
                                password: password,
                                preserveNtSecurityInfo: preserveNtSecurityInfo,
                                eliminateDuplicates: eliminateDuplicates,
                                inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    func extractCurrentSelectionOrDisplayedArchiveItems(to destinationURL: URL,
                                                        session: SZOperationSession? = nil,
                                                        overwriteMode: SZOverwriteMode = .ask,
                                                        pathMode: SZPathMode = .currentPaths,
                                                        password: String? = nil,
                                                        preserveNtSecurityInfo: Bool = false,
                                                        eliminateDuplicates: Bool = false,
                                                        inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws
    {
        let itemsToExtract = archiveItemsForSelectionOrDisplayedItems()
        guard !itemsToExtract.isEmpty else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveItemsToExtract"))
        }
        try extractArchiveItems(itemsToExtract,
                                to: destinationURL,
                                session: session,
                                overwriteMode: overwriteMode,
                                pathMode: pathMode,
                                password: password,
                                preserveNtSecurityInfo: preserveNtSecurityInfo,
                                eliminateDuplicates: eliminateDuplicates,
                                inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    func prepareExtraction(to destinationURL: URL,
                           overwriteMode: SZOverwriteMode = .ask,
                           pathMode: SZPathMode = .currentPaths,
                           password: String? = nil,
                           preserveNtSecurityInfo: Bool = false,
                           eliminateDuplicates: Bool = false,
                           inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws -> FileManagerPreparedExtraction
    {
        let itemsToExtract = archiveItemsForSelectionOrDisplayedItems()
        return try prepareExtraction(of: itemsToExtract,
                                     emptySelectionMessage: SZL10n.string("app.fileManager.error.noArchiveItemsToExtract"),
                                     to: destinationURL,
                                     overwriteMode: overwriteMode,
                                     pathMode: pathMode,
                                     password: password,
                                     preserveNtSecurityInfo: preserveNtSecurityInfo,
                                     eliminateDuplicates: eliminateDuplicates,
                                     inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    func testCurrentArchive(session: SZOperationSession? = nil) throws {
        guard let level = archiveSession.currentLevel else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }
        try level.archive.test(with: session)
    }

    /// Returns the archive handle for the currently open archive, for use off the main actor.
    func currentArchiveForTest() throws -> SZArchive {
        guard let level = archiveSession.currentLevel else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }
        return level.archive
    }

    /// Prepares extraction of the selected archive items (not all displayed items)
    /// so the actual bridge call can run on a background thread.
    func prepareSelectedItemExtraction(to destinationURL: URL,
                                       overwriteMode: SZOverwriteMode = .ask,
                                       pathMode: SZPathMode = .currentPaths,
                                       password: String? = nil,
                                       preserveNtSecurityInfo: Bool = false,
                                       eliminateDuplicates: Bool = false,
                                       inheritDownloadedFileQuarantine: Bool = SZSettings.bool(.inheritDownloadedFileQuarantine)) throws -> FileManagerPreparedExtraction
    {
        let selectedItems = selectedArchiveItems()
        return try prepareExtraction(of: selectedItems,
                                     emptySelectionMessage: SZL10n.string("app.fileManager.error.selectArchiveItems"),
                                     to: destinationURL,
                                     overwriteMode: overwriteMode,
                                     pathMode: pathMode,
                                     password: password,
                                     preserveNtSecurityInfo: preserveNtSecurityInfo,
                                     eliminateDuplicates: eliminateDuplicates,
                                     inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
    }

    private var currentArchiveExtractionContext: FileManagerArchiveExtractionContext? {
        archiveSession.currentExtractionContext(quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path)
    }

    private func prepareExtraction(of itemsToExtract: [ArchiveItem],
                                   emptySelectionMessage: String,
                                   to destinationURL: URL,
                                   overwriteMode: SZOverwriteMode,
                                   pathMode: SZPathMode,
                                   password: String?,
                                   preserveNtSecurityInfo: Bool,
                                   eliminateDuplicates: Bool,
                                   inheritDownloadedFileQuarantine: Bool) throws -> FileManagerPreparedExtraction
    {
        guard !itemsToExtract.isEmpty else {
            throw paneOperationError(emptySelectionMessage)
        }

        guard let context = currentArchiveExtractionContext else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.noArchiveOpen"))
        }

        guard let preparedExtraction = FileManagerArchiveExtraction.prepare(items: itemsToExtract,
                                                                            context: context,
                                                                            destinationURL: destinationURL,
                                                                            overwriteMode: overwriteMode,
                                                                            pathMode: pathMode,
                                                                            password: password,
                                                                            preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                                            eliminateDuplicates: eliminateDuplicates,
                                                                            inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
        else {
            throw paneOperationError(SZL10n.string("app.fileManager.error.cannotExtractSelected"))
        }

        return preparedExtraction
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = Self.paneCommand(for: menuItem.action) else { return true }
        return paneCapabilities.allows(command)
    }

    private static func paneCommand(for action: Selector?) -> FileManagerPaneCommand? {
        switch action {
        case #selector(openSelectedItem(_:)):
            .openSelection
        case #selector(openInArchiveViewer(_:)):
            .openArchiveInViewer
        case #selector(compressSelected(_:)):
            .addSelectedItemsToArchive
        case #selector(extractSelected(_:)), #selector(extractHere(_:)):
            .extractSelectionOrArchive
        case #selector(renameSelected(_:)):
            .renameSelection
        case #selector(deleteSelected(_:)):
            .deleteSelection
        case #selector(createFolderFromMenu(_:)):
            .createFolderHere
        case #selector(showItemProperties(_:)):
            .showSelectedItemProperties
        default:
            nil
        }
    }

    private func paneItem(at row: Int) -> FileManagerPaneItem? {
        tableModel.item(at: row)
    }

    // MARK: - Transfer Host

    var transferLocation: FileManagerPaneTransferLocation {
        FileManagerPaneTransferLocation(isVirtualLocation: isVirtualLocation,
                                        currentDirectoryURL: currentDirectoryURL,
                                        presentationWindow: view.window)
    }

    func transferItem(at row: Int) -> FileManagerPaneItem? {
        paneItem(at: row)
    }

    func transferArchiveDragContext(acquireLease: Bool) -> FileManagerPaneArchiveDragContext? {
        guard let level = archiveSession.currentLevel,
              let context = currentArchiveItemWorkflowContext(acquireLease: acquireLease)
        else { return nil }

        return FileManagerPaneArchiveDragContext(itemWorkflowContext: context,
                                                 operationGate: level.operationGate,
                                                 workflowService: archiveSession.itemWorkflowService)
    }

    func transferCurrentArchiveMutationTarget() -> FileManagerPaneArchiveTransferTarget? {
        guard let target = currentArchiveMutationTarget() else { return nil }
        return transferArchiveTarget(for: target.archive,
                                     subdir: target.subdir)
    }

    func transferArchiveMutationTarget(for archive: SZArchive, subdir: String) -> FileManagerPaneArchiveTransferTarget? {
        transferArchiveTarget(for: archive,
                              subdir: subdir)
    }

    func transferCanMoveOrCopyFileSystemItems(_ urls: [URL],
                                              to destinationDirectory: URL,
                                              operation: NSDragOperation,
                                              presentingIn window: NSWindow?) -> Bool
    {
        canTransferFileSystemItemURLs(urls,
                                      to: destinationDirectory,
                                      operation: operation,
                                      presentingIn: window)
    }

    func transferCanMoveOrCopyFileSystemItemsToArchive(_ urls: [URL],
                                                       archiveURL: URL,
                                                       operation: NSDragOperation,
                                                       presentingIn window: NSWindow?) -> Bool
    {
        canTransferFileSystemItemURLsToArchive(urls,
                                               archiveURL: archiveURL,
                                               operation: operation,
                                               presentingIn: window)
    }

    func transferRefresh() {
        refresh()
    }

    func transferDidMutateArchive(targetSubdir: String?,
                                  selectingPaths paths: [String])
    {
        refreshArchiveAfterMutation(targetSubdir: targetSubdir,
                                    selectingPaths: paths)
        publishArchiveMutationIfNeeded(targetSubdir: targetSubdir,
                                       selectingPaths: paths)
    }

    func transferShowError(_ error: Error) {
        showErrorAlert(error)
    }

    func transferShowReadOnlyArchiveMutationAlert(action: String) {
        showReadOnlyArchiveMutationAlert(action: action)
    }

    // MARK: - Selection Queries

    private func selectedPaneItems() -> [FileManagerPaneItem] {
        tableModel.selectedItems(in: tableView.selectedRowIndexes)
    }

    private func selectedQuickLookRowsAndItems() -> [(row: Int, item: FileManagerPaneItem)] {
        tableModel.selectedRowsAndItems(in: tableView.selectedRowIndexes,
                                        excludingParent: true)
    }

    private func selectedRealPaneItems() -> [FileManagerPaneItem] {
        tableModel.selectedRealItems(in: tableView.selectedRowIndexes)
    }

    private func selectedSingleRealPaneItem() -> FileManagerPaneItem? {
        tableModel.selectedSingleRealItem(in: tableView.selectedRowIndexes)
    }

    func selectedFileSystemItems() -> [FileSystemItem] {
        tableModel.selectedFileSystemItems(in: tableView.selectedRowIndexes)
    }

    func selectedSingleFileSystemFile() -> FileSystemItem? {
        let items = selectedFileSystemItems()
        guard items.count == 1, !items[0].isDirectory else { return nil }
        return items[0]
    }

    func selectedArchiveItems() -> [ArchiveItem] {
        tableModel.selectedArchiveItems(in: tableView.selectedRowIndexes)
    }

    private func paneItemsForSelectionOrDisplayedItems() -> [FileManagerPaneItem] {
        tableModel.paneItemsForSelectionOrDisplayedArchiveItems(in: tableView.selectedRowIndexes)
    }

    private func archiveItemsForSelectionOrDisplayedItems() -> [ArchiveItem] {
        tableModel.archiveItemsForSelectionOrDisplayedItems(in: tableView.selectedRowIndexes)
    }

    // MARK: - Archive Context

    private func currentArchiveDisplayPathPrefix() -> String {
        archiveSession.currentDisplayPathPrefix ?? currentDirectory.path
    }

    func archiveHostDirectory() -> URL {
        archiveSession.currentHostDirectory ?? currentDirectory
    }

    private func currentArchiveItemWorkflowContext(acquireLease: Bool = true) -> FileManagerArchiveItemWorkflowContext? {
        archiveSession.currentItemWorkflowContext(acquireLease: acquireLease,
                                                  hostDirectory: archiveHostDirectory(),
                                                  displayPathPrefix: currentArchiveDisplayPathPrefix(),
                                                  quarantineSourceArchivePath: quarantineSourceArchiveURLForExtraction()?.path,
                                                  hasConflictingNestedArchiveInstance: hasConflictingNestedArchiveInstance(for:))
    }

    // MARK: - Archive Coordination

    private func hasConflictingNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: identity,
                                                                            in: allVisibleArchiveCoordinationSnapshots())
    }

    private func hasDirtyNestedArchiveInstance(for identity: FileManagerNestedArchiveIdentity) -> Bool {
        FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                      in: allVisibleArchiveCoordinationSnapshots())
    }

    private func allVisibleArchiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveCoordinationProvider?.archiveCoordinationSnapshots() ?? archiveCoordinationSnapshots()
    }

    private func canOpenArchive(at url: URL) -> Bool {
        let archive = SZArchive()
        do {
            try archive.open(atPath: url.path)
            archive.close()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Archive Stack Closing

    @discardableResult
    private func closeArchiveLevel(_ level: FileManagerArchiveLevel,
                                   showError: Bool = false) -> Bool
    {
        archiveCoordinator.closeLevel(level,
                                      showError: showError)
    }

    @discardableResult
    private func closeAllArchives(showError: Bool = false) -> Bool {
        archiveCoordinator.closeAll(showError: showError)
    }

    // MARK: - Pane Suspension

    @discardableResult
    func prepareForClose(showError: Bool = true) -> Bool {
        guard !isInsideArchive else {
            let didClose = closeAllArchives(showError: showError)
            if didClose, isViewLoaded {
                enterSuspendedState()
            }
            return didClose
        }
        return true
    }

    @discardableResult
    func prepareForDeactivation(showError: Bool = true) -> Bool {
        guard prepareForClose(showError: showError) else {
            return false
        }

        if isViewLoaded {
            enterSuspendedState()
        }

        return true
    }

    func reactivateIfSuspended() {
        guard isSuspended else { return }
        reactivatePane()
    }

    func closeDirectory() {
        guard !isSuspended else { return }
        if isInsideArchive {
            _ = closeAllArchives(showError: true)
        }
        if !isInsideArchive, isViewLoaded {
            enterSuspendedState()
        }
    }

    private func enterSuspendedState() {
        guard !isSuspended else { return }
        isSuspended = true

        tearDownDirectoryWatcher()
        cancelPendingDirectorySnapshot()
        cancelPendingArchiveRefresh()
        items.removeAll()
        archiveSession.clearDisplayItems()
        currentDirectoryFingerprint.removeAll()
        tableView.reloadData()
        statusLabel.stringValue = ""

        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        overlay.setAccessibilityIdentifier("fileManager.suspendedOverlay")

        let label = NSTextField(labelWithString: SZL10n.string("app.fileManager.suspendedDescription"))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overlay.addSubview(label)

        let button = NSButton(title: SZL10n.string("app.fileManager.reactivatePane"),
                              target: self,
                              action: #selector(reactivatePaneClicked(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setAccessibilityIdentifier("fileManager.reactivateButton")
        overlay.addSubview(button)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -12),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
            button.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: 12),
        ])

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        suspendedOverlay = overlay
    }

    @objc private func reactivatePaneClicked(_: Any?) {
        reactivatePane()
    }

    private func reactivatePane() {
        guard isSuspended else { return }
        loadDirectory(currentDirectory, showError: true)
    }

    private func preserveNestedArchiveTemporaryDirectories() -> [URL] {
        archiveCoordinator.preserveNestedTemporaryDirectories()
    }

    private func preserveRemainingTemporaryDirectories(_ urls: [URL]) {
        archiveCoordinator.preserveRemainingTemporaryDirectories(urls)
    }

    // MARK: - Archive Reloads And Change Propagation

    private func reloadCurrentArchiveEntries(selectingPaths paths: [String] = []) {
        archiveCoordinator.reloadCurrentArchiveEntries(selectingPaths: paths)
    }

    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange) {
        archiveCoordinator.handlePublishedArchiveChange(change)
    }

    func publishArchiveMutationIfNeeded(targetSubdir: String? = nil,
                                        selectingPaths paths: [String] = [])
    {
        archiveCoordinator.publishMutationIfNeeded(targetSubdir: targetSubdir,
                                                   selectingPaths: paths)
    }

    func refreshArchiveAfterMutation(targetSubdir: String? = nil,
                                     selectingPaths paths: [String] = [])
    {
        archiveCoordinator.refreshAfterMutation(targetSubdir: targetSubdir,
                                                selectingPaths: paths)
    }

    private func refreshArchiveAfterMutation(selectingPath path: String? = nil) {
        archiveCoordinator.refreshAfterMutation(selectingPath: path)
    }

    private func cancelPendingArchiveRefresh() {
        archiveCoordinatorStorage?.cancelPendingReload()
    }

    private func selectArchivePaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let selectedPaths = Set(paths.map(normalizeArchivePath))
        var rows = IndexSet()
        for (index, item) in archiveSession.displayItems.enumerated() {
            if selectedPaths.contains(normalizeArchivePath(item.path)) {
                rows.insert(index + (showsParentRow ? 1 : 0))
            }
        }

        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let firstRow = rows.first {
            tableView.scrollRowToVisible(firstRow)
        }
    }

    // MARK: - External Opening

    @discardableResult
    private func openExternallyIfPossible(_ url: URL,
                                          preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool
    {
        guard let applicationURL = FileManagerExternalOpenRouter.defaultExternalApplicationURL(for: url) else {
            return false
        }

        return openExternally(url,
                              withApplicationAt: applicationURL,
                              preservingTemporaryDirectory: temporaryDirectory)
    }

    @discardableResult
    private func openExternally(_ url: URL,
                                withApplicationAt applicationURL: URL,
                                preservingTemporaryDirectory temporaryDirectory: URL? = nil) -> Bool
    {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let app {
                    if let temporaryDirectory {
                        archiveSession.itemWorkflowService.scheduleCleanup(temporaryDirectory,
                                                                           when: app)
                    }
                    return
                }

                if let temporaryDirectory {
                    archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
                }

                if let error, !FileManagerExternalOpenRouter.shouldSuppressExternalOpenError(error) {
                    showErrorAlert(error)
                }
            }
        }
        return true
    }

    // MARK: - Archive Path Utilities

    private func normalizeArchivePath(_ path: String) -> String {
        FileManagerArchiveChange.normalizeArchivePath(path)
    }

    // MARK: - Sorting Support

    private func applySortDescriptor(columnIdentifier: String,
                                     key: String,
                                     ascending: Bool,
                                     selector: Selector? = nil)
    {
        listViewCoordinator.applySortDescriptor(columnIdentifier: columnIdentifier,
                                                key: key,
                                                ascending: ascending,
                                                selector: selector,
                                                availableColumns: columnsForCurrentLocation())
        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    // MARK: - Archive Extraction Execution

    private func extractArchiveItems(_ itemsToExtract: [ArchiveItem],
                                     to destinationURL: URL,
                                     session: SZOperationSession?,
                                     overwriteMode: SZOverwriteMode,
                                     pathMode: SZPathMode,
                                     password: String?,
                                     preserveNtSecurityInfo: Bool,
                                     eliminateDuplicates: Bool,
                                     inheritDownloadedFileQuarantine: Bool) throws
    {
        let preparedExtraction = try prepareExtraction(of: itemsToExtract,
                                                       emptySelectionMessage: SZL10n.string("app.fileManager.error.cannotExtractSelected"),
                                                       to: destinationURL,
                                                       overwriteMode: overwriteMode,
                                                       pathMode: pathMode,
                                                       password: password,
                                                       preserveNtSecurityInfo: preserveNtSecurityInfo,
                                                       eliminateDuplicates: eliminateDuplicates,
                                                       inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
        try preparedExtraction.perform(session: session)
    }

    // MARK: - Error Presentation

    private func paneOperationError(_ description: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func unavailableExternalOpenError(for itemName: String) -> NSError {
        paneOperationError(SZL10n.string("app.fileManager.error.noAppToOpen", itemName))
    }

    private func invalidAddressBarPathError(for path: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.error.pathNotFound", path),
                ])
    }

    private func showErrorAlert(_ error: Error) {
        szPresentError(error, for: view.window)
    }

    func showReadOnlyArchiveMutationAlert(action: String) {
        if let level = archiveSession.currentLevel,
           level.operationGate.hasActiveLeases
        {
            return
        }

        if let level = archiveSession.currentLevel,
           let nestedIdentity = level.nestedIdentity,
           hasConflictingNestedArchiveInstance(for: nestedIdentity)
        {
            szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                             message: SZL10n.string("app.fileManager.alert.nestedArchiveConflict"),
                             for: view.window)
            return
        }

        if let level = archiveSession.currentLevel,
           !level.archive.canWrite
        {
            let archiveFormat = level.archive.formatName ?? SZL10n.string("app.fileManager.alert.thisArchiveFormat")
            szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                             message: SZL10n.string("app.fileManager.alert.formatNoInPlaceUpdate", archiveFormat),
                             for: view.window)
            return
        }

        szPresentMessage(title: SZL10n.string("app.fileManager.alert.actionNotAvailableTitle", action),
                         message: SZL10n.string("app.fileManager.alert.temporaryCopyNoModification"),
                         for: view.window)
    }

    // MARK: - Item Sorting

    private func sortCurrentItems(by descriptors: [NSSortDescriptor]) {
        if isInsideArchive {
            archiveSession.sortDisplayItems(by: descriptors)
        } else {
            FileManagerItemSorting.sort(&items, by: descriptors)
        }
    }

    // MARK: - Actions

    @objc private func pathFieldSubmitted(_ sender: NSTextField) {
        delegate?.paneDidBecomeActive(self)
        let path = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return }

        switch FileManagerFileSystemNavigation.addressBarTarget(for: path) {
        case let .directory(url):
            guard closeAllArchives(showError: true) else {
                updatePathField()
                return
            }
            loadDirectory(url)
        case let .file(url, hostDirectory):
            if FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(url) {
                updatePathField()
                if !openExternallyIfPossible(url) {
                    showErrorAlert(unavailableExternalOpenError(for: url.lastPathComponent))
                }
                view.window?.makeFirstResponder(tableView)
                return
            }

            if isInsideArchive, !canOpenArchive(at: url) {
                updatePathField()
                if !openExternallyIfPossible(url) {
                    showErrorAlert(unavailableExternalOpenError(for: url.lastPathComponent))
                }
                view.window?.makeFirstResponder(tableView)
                return
            }

            guard closeAllArchives(showError: true) else {
                updatePathField()
                return
            }
            switch openArchiveInline(url,
                                     hostDirectory: hostDirectory,
                                     showError: false)
            {
            case .opened:
                break
            case let .unsupportedArchive(error):
                updatePathField()
                let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: url)
                if shouldFallbackExternally {
                    if !openExternallyIfPossible(url) {
                        showErrorAlert(error)
                    }
                } else {
                    showErrorAlert(error)
                }
            case .cancelled:
                updatePathField()
            case let .failed(error):
                updatePathField()
                showErrorAlert(error)
            }
        case nil:
            updatePathField()
            showErrorAlert(invalidAddressBarPathError(for: path))
        }
        // Resign focus back to table
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func goUpClicked(_: Any?) {
        goUp()
    }

    private func updatePathField() {
        if isInsideArchive {
            guard let level = archiveSession.currentLevel else { return }
            pathField.stringValue = level.currentSubdir.isEmpty
                ? level.displayPathPrefix
                : level.displayPathPrefix + "/" + level.currentSubdir
        } else {
            pathField.stringValue = currentDirectory.path
        }

        updateLocationIcon()
    }

    private func updateLocationIcon() {
        let image: NSImage? = if let level = archiveSession.currentLevel {
            if level.currentSubdir.isEmpty {
                NSWorkspace.shared.icon(forFile: level.archivePath)
            } else {
                NSImage(named: NSImage.folderName)
                    ?? NSWorkspace.shared.icon(forFile: level.filesystemDirectory.path)
            }
        } else {
            NSWorkspace.shared.icon(forFile: currentDirectory.path)
        }

        locationIconView.image = image
    }

    @objc private func doubleClickRow(_: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activatePaneItem(at: row)
    }

    @objc private func singleClickRow(_: Any?) {
        guard SZSettings.bool(.singleClickOpen) else { return }
        guard tableView.selectedRowIndexes.count <= 1 else { return }
        guard let event = NSApp.currentEvent else { return }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty else { return }

        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activatePaneItem(at: row)
    }

    private func openItemInArchive(_ item: ArchiveItem,
                                   strategy: FileManagerArchiveItemOpenStrategy = .automatic)
    {
        guard item.index >= 0,
              let context = currentArchiveItemWorkflowContext() else { return }

        if case .forceExternal = strategy {
            openArchiveItemExternally(item,
                                      context: context,
                                      strategy: strategy)
            return
        }

        if case .automatic = strategy,
           FileManagerExternalOpenRouter.shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath: item.path)
        {
            openArchiveItemExternally(item,
                                      context: context,
                                      strategy: strategy)
            return
        }

        let openMode: FileManagerArchiveOpenMode
        let preserveTemporaryDirectoryOnUnsupported: Bool
        switch strategy {
        case .automatic:
            openMode = .defaultBehavior
            preserveTemporaryDirectoryOnUnsupported = true
        case let .forceInternal(mode):
            openMode = mode
            preserveTemporaryDirectoryOnUnsupported = false
        case .forceExternal:
            return
        }

        openArchiveItemInternally(item,
                                  context: context,
                                  openMode: openMode,
                                  preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported)
    }

    private func openArchiveItemExternally(_ item: ArchiveItem,
                                           context: FileManagerArchiveItemWorkflowContext,
                                           strategy: FileManagerArchiveItemOpenStrategy)
    {
        let displayPath = context.displayPath(for: item)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let preparedOpen = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                                        initialFileName: displayPath,
                                                                        parentWindow: view.window,
                                                                        deferredDisplay: true)
                { [archiveSession] session in
                    try archiveSession.itemWorkflowService.prepareExternalArchiveItemOpen(for: item,
                                                                                          context: context,
                                                                                          strategy: strategy,
                                                                                          session: session)
                }

                finishExternalArchiveItemOpen(preparedOpen,
                                              itemName: item.name)
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func finishExternalArchiveItemOpen(_ preparedOpen: FileManagerPreparedArchiveItemExternalOpen,
                                               itemName: String)
    {
        if let applicationURL = preparedOpen.applicationURL {
            _ = openExternally(preparedOpen.stagedFileURL,
                               withApplicationAt: applicationURL,
                               preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
            return
        }

        if openExternallyIfPossible(preparedOpen.stagedFileURL,
                                    preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
        {
            return
        }

        archiveSession.cleanupTemporaryDirectory(preparedOpen.temporaryDirectory)
        showErrorAlert(unavailableExternalOpenError(for: itemName))
    }

    private func openArchiveItemInternally(_ item: ArchiveItem,
                                           context: FileManagerArchiveItemWorkflowContext,
                                           openMode: FileManagerArchiveOpenMode,
                                           preserveTemporaryDirectoryOnUnsupported: Bool)
    {
        let displayPath = context.displayPath(for: item)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let preparedOpen = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.opening"),
                                                                        initialFileName: displayPath,
                                                                        parentWindow: view.window,
                                                                        deferredDisplay: true)
                { [archiveSession] session in
                    try archiveSession.itemWorkflowService.prepareInternalArchiveOpen(for: item,
                                                                                      context: context,
                                                                                      openMode: openMode,
                                                                                      session: session)
                }

                let result = finishArchiveOpen(preparedOpen.preparedResult,
                                               temporaryDirectory: preparedOpen.temporaryDirectory,
                                               preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                               replaceCurrentState: false,
                                               showError: false)

                switch result {
                case .opened, .cancelled:
                    return

                case let .unsupportedArchive(error):
                    guard preserveTemporaryDirectoryOnUnsupported else {
                        showErrorAlert(error)
                        return
                    }

                    let shouldFallbackExternally = FileManagerExternalOpenRouter.shouldFallbackUnsupportedArchiveExternally(for: preparedOpen.stagedArchiveURL)
                    if shouldFallbackExternally {
                        if let applicationURL = FileManagerExternalOpenRouter.defaultExternalApplicationURL(forArchiveItemPath: item.path) {
                            _ = openExternally(preparedOpen.stagedArchiveURL,
                                               withApplicationAt: applicationURL,
                                               preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
                        } else if !openExternallyIfPossible(preparedOpen.stagedArchiveURL,
                                                            preservingTemporaryDirectory: preparedOpen.temporaryDirectory)
                        {
                            archiveSession.cleanupTemporaryDirectory(preparedOpen.temporaryDirectory)
                            showErrorAlert(error)
                        }
                    } else {
                        archiveSession.cleanupTemporaryDirectory(preparedOpen.temporaryDirectory)
                        showErrorAlert(error)
                    }

                case let .failed(error):
                    showErrorAlert(error)
                }
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func goUp() {
        if isInsideArchive {
            guard let level = archiveSession.currentLevel else { return }
            if !level.currentSubdir.isEmpty {
                let parent = if let lastSlash = level.currentSubdir.lastIndex(of: "/") {
                    String(level.currentSubdir[level.currentSubdir.startIndex ..< lastSlash])
                } else {
                    ""
                }
                navigateArchiveSubdir(parent)
            } else {
                let fsDir = level.filesystemDirectory
                guard closeArchiveLevel(level, showError: true) else {
                    return
                }
                if !isInsideArchive {
                    loadDirectory(fsDir)
                } else {
                    guard let outer = archiveSession.currentLevel else { return }
                    navigateArchiveSubdir(outer.currentSubdir)
                }
            }
        } else {
            let parent = currentDirectory.deletingLastPathComponent()
            loadDirectory(parent)
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int {
        tableModel.rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        guard let paneItem = paneItem(at: row) else { return nil }

        return FileManagerPaneTableCellRenderer.view(in: tableView,
                                                     for: paneItem,
                                                     tableColumn: tableColumn,
                                                     columns: listViewCoordinator.currentColumns,
                                                     fallbackColumns: columnsForCurrentLocation(),
                                                     dateFormatter: FileManagerViewPreferences.makeListDateFormatter(),
                                                     owner: self,
                                                     iconSize: iconSize,
                                                     showsRealFileIcons: showsRealFileIcons)
        { [self] item, isDirectory, iconPath in
            iconImage(for: item,
                      isDirectory: isDirectory,
                      iconPath: iconPath)
        }
    }

    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
        listRowHeight
    }

    // MARK: - Drag Source

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        transferCoordinator.pasteboardWriter(forRow: row,
                                             host: self)
    }

    // MARK: - Drop Destination (accept files dragged into this folder)

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        transferCoordinator.validateDrop(info,
                                         proposedRow: row,
                                         dropOperation: dropOperation,
                                         in: tableView,
                                         host: self)
    }

    func tableView(_: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        transferCoordinator.acceptDrop(info,
                                       row: row,
                                       dropOperation: dropOperation,
                                       host: self)
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateStatusBar()
        delegate?.paneDidBecomeActive(self)
        delegate?.paneSelectionDidChange(self)
    }

    func beginArchiveTransfer(_ urls: [URL],
                              to target: (archive: SZArchive, subdir: String),
                              operation: NSDragOperation,
                              sourcePane: FileManagerPaneController?,
                              cleanupDirectory: URL? = nil,
                              parentWindow: NSWindow? = nil,
                              requiresConfirmation: Bool = false,
                              operationTitle: String? = nil)
    {
        guard !urls.isEmpty else {
            cleanupArchiveTransferDirectory(cleanupDirectory)
            return
        }
        guard let transferTarget = transferArchiveTarget(for: target.archive,
                                                         subdir: target.subdir)
        else {
            cleanupArchiveTransferDirectory(cleanupDirectory)
            showUnavailableArchiveTransferAlert(operation: operation)
            return
        }

        transferCoordinator.beginArchiveTransfer(urls,
                                                 to: transferTarget,
                                                 operation: operation,
                                                 sourceHost: sourcePane,
                                                 host: self,
                                                 cleanupDirectory: cleanupDirectory,
                                                 parentWindow: parentWindow,
                                                 requiresConfirmation: requiresConfirmation,
                                                 operationTitle: operationTitle)
    }

    func beginConfirmedArchiveTransfer(_ urls: [URL],
                                       to target: (archive: SZArchive, subdir: String),
                                       operation: NSDragOperation,
                                       sourcePane: FileManagerPaneController?,
                                       cleanupDirectory: URL? = nil,
                                       parentWindow: NSWindow? = nil,
                                       operationTitle: String? = nil)
    {
        guard !urls.isEmpty else {
            cleanupArchiveTransferDirectory(cleanupDirectory)
            return
        }
        guard let transferTarget = transferArchiveTarget(for: target.archive,
                                                         subdir: target.subdir)
        else {
            cleanupArchiveTransferDirectory(cleanupDirectory)
            showUnavailableArchiveTransferAlert(operation: operation)
            return
        }

        transferCoordinator.beginArchiveTransfer(urls,
                                                 to: transferTarget,
                                                 operation: operation,
                                                 sourceHost: sourcePane,
                                                 host: self,
                                                 cleanupDirectory: cleanupDirectory,
                                                 parentWindow: parentWindow,
                                                 requiresConfirmation: true,
                                                 operationTitle: operationTitle)
    }

    private func cleanupArchiveTransferDirectory(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func showUnavailableArchiveTransferAlert(operation: NSDragOperation) {
        showReadOnlyArchiveMutationAlert(action: operation == .move
            ? SZL10n.string("app.fileManager.action.movingFilesIntoArchive")
            : SZL10n.string("app.fileManager.action.addingFilesToArchive"))
    }

    // MARK: - Sorting (matches PanelSort.cpp)

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        guard !listViewCoordinator.isApplyingPreferences else { return }
        sortCurrentItems(by: tableView.sortDescriptors)
        updateHighlightedTableColumn(for: tableView.sortDescriptors.first?.key)
        persistCurrentListViewInfo()
        tableView.reloadData()
    }
}

// MARK: - Archive Inline Navigation (matches Panel.cpp _parentFolders stack)

extension FileManagerPaneController {
    @discardableResult
    private func openArchiveInline(_ url: URL,
                                   hostDirectory: URL? = nil,
                                   temporaryDirectory: URL? = nil,
                                   displayPathPrefix: String? = nil,
                                   nestedWriteBackInfo: FileManagerNestedArchiveWriteBackInfo? = nil,
                                   openMode: FileManagerArchiveOpenMode = .defaultBehavior,
                                   showError: Bool = true,
                                   preserveTemporaryDirectoryOnUnsupported: Bool = false,
                                   replaceCurrentState: Bool = false) -> FileManagerArchiveOpenResult
    {
        let paneHostDirectory = hostDirectory ?? archiveHostDirectory()
        let resolvedDisplayPathPrefix = displayPathPrefix ?? url.path
        let progressParentWindow: NSWindow? = if let window = view.window, window.isVisible {
            window
        } else {
            nil
        }

        let preparedResult = FileManagerArchiveOpenService.openSynchronously(url: url,
                                                                             hostDirectory: paneHostDirectory,
                                                                             temporaryDirectory: temporaryDirectory,
                                                                             displayPathPrefix: resolvedDisplayPathPrefix,
                                                                             parentWindow: progressParentWindow,
                                                                             nestedWriteBackInfo: nestedWriteBackInfo,
                                                                             openMode: openMode)

        return finishArchiveOpen(preparedResult,
                                 temporaryDirectory: temporaryDirectory,
                                 preserveTemporaryDirectoryOnUnsupported: preserveTemporaryDirectoryOnUnsupported,
                                 replaceCurrentState: replaceCurrentState,
                                 showError: showError)
    }

    private func finishArchiveOpen(_ preparedResult: FileManagerPreparedArchiveOpenResult,
                                   temporaryDirectory: URL?,
                                   preserveTemporaryDirectoryOnUnsupported: Bool,
                                   replaceCurrentState: Bool,
                                   showError: Bool) -> FileManagerArchiveOpenResult
    {
        let result: FileManagerArchiveOpenResult
        switch preparedResult {
        case let .opened(prepared):
            if let nestedIdentity = prepared.nestedWriteBackInfo?.identity,
               hasDirtyNestedArchiveInstance(for: nestedIdentity)
            {
                prepared.archive.close()
                archiveSession.cleanupTemporaryDirectory(prepared.temporaryDirectory)
                result = .failed(paneOperationError(SZL10n.string("app.fileManager.error.nestedArchiveDirty")))
                break
            }

            if commitPreparedArchive(prepared, replaceCurrentState: replaceCurrentState) {
                return .opened
            }
            return .cancelled
        case let .unsupportedArchive(error):
            if !preserveTemporaryDirectoryOnUnsupported {
                archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
            }
            result = .unsupportedArchive(error)
        case .cancelled:
            archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
            result = .cancelled
        case let .failed(error):
            archiveSession.cleanupTemporaryDirectory(temporaryDirectory)
            result = .failed(error)
        }

        if showError {
            switch result {
            case let .unsupportedArchive(error), let .failed(error):
                showErrorAlert(error)
            case .opened, .cancelled:
                break
            }
        }

        return result
    }

    private func commitPreparedArchive(_ prepared: FileManagerPreparedArchiveOpen,
                                       replaceCurrentState: Bool) -> Bool
    {
        if replaceCurrentState, !closeAllArchives(showError: true) {
            prepared.archive.close()
            archiveSession.cleanupTemporaryDirectory(prepared.temporaryDirectory)
            return false
        }

        currentDirectory = prepared.hostDirectory
        recordDirectoryVisit(prepared.hostDirectory)
        cancelPendingDirectorySnapshot()
        tearDownDirectoryWatcher()
        archiveSession.appendPreparedArchive(prepared)
        presentCurrentArchiveSubdir()
        return true
    }

    func navigateArchiveSubdir(_ subdir: String) {
        guard archiveSession.navigateSubdir(subdir) else { return }
        presentCurrentArchiveSubdir()
    }

    private func presentCurrentArchiveSubdir() {
        updateTableColumnsForCurrentLocation()
        sortCurrentItems(by: tableView.sortDescriptors)
        updatePathField()
        updateStatusBar()
        tableView.reloadData()
    }
}

// MARK: - NSMenuDelegate (auto-select row on right-click)

extension FileManagerPaneController {
    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveSession.coordinationSnapshots { level in
            level.nestedWriteBackInfo.flatMap { writeBackInfo in
                FileManagerArchiveFileFingerprint.captureIfPossible(for: URL(fileURLWithPath: level.archivePath).standardizedFileURL)
                    .map { $0 != writeBackInfo.initialFingerprint }
            } ?? false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuCoordinator.menuNeedsUpdate(menu)
    }
}

// MARK: - Context Menu

extension FileManagerPaneController {
    private func populateColumnHeaderMenu(_ menu: NSMenu) {
        listViewCoordinator.populateColumnHeaderMenu(menu,
                                                     availableColumns: columnsForCurrentLocation(),
                                                     target: self,
                                                     action: #selector(toggleListViewColumnVisibility(_:)))
    }

    @objc private func toggleListViewColumnVisibility(_ sender: NSMenuItem) {
        guard let rawColumnID = sender.representedObject as? String else { return }
        let columnID = FileManagerColumnID(rawValue: rawColumnID)

        let availableColumns = columnsForCurrentLocation()
        let didChange = listViewCoordinator.toggleColumnVisibility(columnID,
                                                                   availableColumns: availableColumns,
                                                                   folderTypeID: listViewFolderTypeIDForCurrentLocation())
        guard didChange else { return }

        sortCurrentItems(by: tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func refreshContextMenu() {
        tableView.menu = menuCoordinator.makeContextMenu(windowTarget: delegate as AnyObject?,
                                                         delegate: self)
    }

    func controlTextDidBeginEditing(_: Notification) {
        delegate?.paneDidBecomeActive(self)
    }

    @objc private func openSelectedItem(_: Any?) {
        doubleClickRow(nil)
    }

    @objc private func openInArchiveViewer(_: Any?) {
        guard let url = selectedArchiveCandidateURL() else { return }
        delegate?.paneDidRequestOpenArchiveInNewWindow(url)
    }

    @objc private func compressSelected(_: Any?) {
        if isInsideArchive, !supportsInPlaceArchiveMutation {
            showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.addingFilesToArchive"))
            return
        }

        // Forward to FileManagerWindowController
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.addToArchive(nil)
        }
    }

    @objc private func extractSelected(_: Any?) {
        if let wc = view.window?.windowController as? FileManagerWindowController {
            wc.extractArchive(nil)
        }
    }

    @objc private func extractHere(_: Any?) {
        extractSelectionHere()
    }

    @objc private func renameSelected(_: Any?) {
        FileManagerPaneMutationCommandSupport.renameSelection(in: self)
    }

    @objc private func deleteSelected(_: Any?) {
        FileManagerPaneMutationCommandSupport.deleteSelection(in: self)
    }

    @objc private func createFolderFromMenu(_: Any?) {
        FileManagerPaneMutationCommandSupport.promptForFolderCreation(in: self)
    }

    @objc private func showItemProperties(_: Any?) {
        guard let item = selectedRealPaneItems().first else { return }

        switch item {
        case let .filesystem(fileSystemItem):
            let details = FileManagerItemPresentation.details(for: fileSystemItem)
            szShowDetailsDialog(title: details.title,
                                details: details.details,
                                for: view.window)

        case let .archive(archiveItem):
            let details = FileManagerItemPresentation.details(for: archiveItem,
                                                              entryProperties: archiveSession.currentLevel?.entryProperties ?? [])
            szShowDetailsDialog(title: details.title,
                                details: details.details,
                                for: view.window)

        case .parent:
            return
        }
    }
}
