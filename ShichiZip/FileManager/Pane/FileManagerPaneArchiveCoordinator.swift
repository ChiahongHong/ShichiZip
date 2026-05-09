import Cocoa

@MainActor
final class FileManagerPaneArchiveCoordinator {
    private let archiveSession: FileManagerArchiveSession
    private let observerIdentifier: ObjectIdentifier
    private let parentWindow: () -> NSWindow?
    private let isViewLoaded: () -> Bool
    private let presentCurrentArchiveSubdir: () -> Void
    private let updateTableColumns: () -> Void
    private let selectArchivePaths: ([String]) -> Void
    private let showError: (Error) -> Void

    private var archiveRefreshGeneration = 0
    private var archiveRefreshTask: Task<Void, Never>?

    init(archiveSession: FileManagerArchiveSession,
         observerIdentifier: ObjectIdentifier,
         parentWindow: @escaping () -> NSWindow?,
         isViewLoaded: @escaping () -> Bool,
         presentCurrentArchiveSubdir: @escaping () -> Void,
         updateTableColumns: @escaping () -> Void,
         selectArchivePaths: @escaping ([String]) -> Void,
         showError: @escaping (Error) -> Void)
    {
        self.archiveSession = archiveSession
        self.observerIdentifier = observerIdentifier
        self.parentWindow = parentWindow
        self.isViewLoaded = isViewLoaded
        self.presentCurrentArchiveSubdir = presentCurrentArchiveSubdir
        self.updateTableColumns = updateTableColumns
        self.selectArchivePaths = selectArchivePaths
        self.showError = showError
    }

    // MARK: - Reloads And Change Propagation

    func reloadCurrentArchiveEntries(selectingPaths paths: [String] = []) {
        guard let level = archiveSession.currentLevel else { return }
        scheduleEntriesReload(at: archiveSession.count - 1,
                              selectingPaths: paths,
                              preservingSubdir: level.currentSubdir)
    }

    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange) {
        switch FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                    currentLocation: archiveSession.coordinatedLocation(),
                                                                    observerIdentifier: observerIdentifier)
        {
        case .ignore:
            return
        case let .reload(selectingPaths):
            reloadCoordinatedArchive(selectingPaths: selectingPaths)
        }
    }

    func publishMutationIfNeeded(targetSubdir: String? = nil,
                                 selectingPaths paths: [String] = [])
    {
        guard let level = archiveSession.currentLevel,
              let archiveURL = level.topLevelArchiveURL
        else {
            return
        }

        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir ?? level.currentSubdir)
        let normalizedPaths = paths.map(normalizeArchivePath)

        FileManagerArchiveChangeCoordinator.publish(
            FileManagerArchiveChange(archiveURL: archiveURL,
                                     targetSubdir: normalizedTargetSubdir,
                                     selectingPaths: normalizedPaths,
                                     sourceIdentifier: observerIdentifier),
        )
    }

    func refreshAfterMutation(targetSubdir: String? = nil,
                              selectingPaths paths: [String] = [])
    {
        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir ?? archiveSession.currentLevel?.currentSubdir ?? "")
        let normalizedCurrentSubdir = normalizeArchivePath(archiveSession.currentLevel?.currentSubdir ?? "")
        let selectionPaths = normalizedTargetSubdir == normalizedCurrentSubdir
            ? paths.map(normalizeArchivePath)
            : []
        reloadCurrentArchiveEntries(selectingPaths: selectionPaths)
    }

    func refreshAfterMutation(selectingPath path: String? = nil) {
        refreshAfterMutation(selectingPaths: path.map { [$0] } ?? [])
    }

    func cancelPendingReload() {
        archiveRefreshGeneration += 1
        archiveRefreshTask?.cancel()
        archiveRefreshTask = nil
    }

    // MARK: - Closing And Temporary Directories

    @discardableResult
    func closeLevel(_ level: FileManagerArchiveLevel,
                    showError: Bool = false) -> Bool
    {
        cancelPendingReload()
        level.operationGate.beginClosingAndWaitForLeases()

        do {
            let nestedWriteBackResult = try writeBackNestedArchiveChangesIfNeeded(for: level)
            level.archive.close()
            archiveSession.cleanupTemporaryDirectory(level.temporaryDirectory)

            archiveSession.removeCurrentLevelIfMatching(level)

            if let refreshedParent = nestedWriteBackResult.refreshedParent {
                archiveSession.replaceEntries(at: refreshedParent.index,
                                              with: refreshedParent.entries)
            }

            if let publishedChange = nestedWriteBackResult.publishedChange {
                FileManagerArchiveChangeCoordinator.publish(publishedChange)
            }

            if !archiveSession.isInsideArchive {
                archiveSession.clearDisplayItems()
            } else if isViewLoaded(), let currentLevel = archiveSession.currentLevel {
                archiveSession.navigateSubdir(currentLevel.currentSubdir)
                presentCurrentArchiveSubdir()
            }
            updateTableColumns()

            return true
        } catch {
            level.operationGate.cancelClosing()
            if showError {
                self.showError(error)
            }
            return false
        }
    }

    @discardableResult
    func closeAll(showError: Bool = false) -> Bool {
        while let level = archiveSession.currentLevel {
            guard closeLevel(level, showError: showError) else {
                return false
            }
        }
        archiveSession.clearDisplayItems()
        updateTableColumns()
        return true
    }

    func preserveNestedTemporaryDirectories() -> [URL] {
        archiveSession.preserveNestedTemporaryDirectories()
    }

    func preserveRemainingTemporaryDirectories(_ urls: [URL]) {
        archiveSession.preserveRemainingTemporaryDirectories(urls)
    }

    func cleanupAllTemporaryDirectories() {
        archiveSession.cleanupAllTemporaryDirectories()
    }

    // MARK: - Reload Implementation

    private func reloadCoordinatedArchive(selectingPaths paths: [String]) {
        guard let level = archiveSession.currentLevel,
              level.temporaryDirectory == nil,
              level.nestedWriteBackInfo == nil
        else {
            return
        }

        scheduleEntriesReload(at: archiveSession.count - 1,
                              selectingPaths: paths,
                              preservingSubdir: level.currentSubdir,
                              reopenBeforeListing: true)
    }

    private func scheduleEntriesReload(at index: Int,
                                       selectingPaths paths: [String],
                                       preservingSubdir subdir: String,
                                       reopenBeforeListing: Bool = false)
    {
        guard archiveSession.containsLevel(at: index) else { return }

        cancelPendingReload()

        guard let level = archiveSession.currentLevel else { return }
        guard index == archiveSession.count - 1 else { return }
        guard let lease = level.operationGate.acquireLease() else { return }

        archiveRefreshGeneration += 1
        let generation = archiveRefreshGeneration
        let archive = level.archive
        let archivePath = level.archivePath
        let normalizedPaths = paths.map(normalizeArchivePath)
        let session = SZOperationSession()

        archiveRefreshTask = Task { @MainActor [weak self] in
            defer { withExtendedLifetime(lease) {} }

            do {
                let refreshedEntries = try await FileManagerArchiveListing.itemsAsync(from: archive,
                                                                                      session: session,
                                                                                      reopenBeforeListing: reopenBeforeListing)
                guard !Task.isCancelled else { return }
                self?.finishEntriesReload(refreshedEntries,
                                          generation: generation,
                                          index: index,
                                          archive: archive,
                                          archivePath: archivePath,
                                          subdir: subdir,
                                          selectingPaths: normalizedPaths)
            } catch {
                guard !Task.isCancelled else { return }
                guard !szIsUserCancellation(error) else { return }
                guard self?.archiveRefreshGeneration == generation else { return }
                self?.showError(error)
            }
        }
    }

    private func finishEntriesReload(_ entries: [ArchiveItem],
                                     generation: Int,
                                     index: Int,
                                     archive: SZArchive,
                                     archivePath: String,
                                     subdir: String,
                                     selectingPaths paths: [String])
    {
        guard archiveRefreshGeneration == generation else { return }
        guard let level = archiveSession.level(at: index) else { return }

        guard level.archive === archive,
              level.archivePath == archivePath
        else {
            return
        }

        archiveSession.replaceEntries(at: index,
                                      with: entries,
                                      preservingSubdir: subdir)
        guard archiveSession.navigateSubdir(subdir) else { return }
        presentCurrentArchiveSubdir()
        selectArchivePaths(paths)
    }

    // MARK: - Close Implementation

    private func writeBackNestedArchiveChangesIfNeeded(for level: FileManagerArchiveLevel) throws -> (refreshedParent: (index: Int, entries: [ArchiveItem])?, publishedChange: FileManagerArchiveChange?) {
        guard let writeBackInfo = level.nestedWriteBackInfo else {
            return (nil, nil)
        }

        let temporaryArchiveURL = URL(fileURLWithPath: level.archivePath).standardizedFileURL
        guard let currentFingerprint = FileManagerArchiveFileFingerprint.captureIfPossible(for: temporaryArchiveURL) else {
            throw operationError(SZL10n.string("app.fileManager.error.nestedArchiveSyncFailed"))
        }

        guard currentFingerprint != writeBackInfo.initialFingerprint else {
            return (nil, nil)
        }

        let refreshedParentEntries = try ArchiveOperationRunner.runSynchronously(operationTitle: SZL10n.string("progress.updating"),
                                                                                 initialFileName: (writeBackInfo.parentItemPath as NSString).lastPathComponent,
                                                                                 parentWindow: parentWindow(),
                                                                                 deferredDisplay: true)
        { session -> [ArchiveItem] in
            try writeBackInfo.parentTarget.archive.replaceItem(atPath: writeBackInfo.parentItemPath,
                                                               inArchiveSubdir: writeBackInfo.parentTarget.subdir,
                                                               withFileAtPath: temporaryArchiveURL.path,
                                                               session: session)
            return try FileManagerArchiveListing.items(from: writeBackInfo.parentTarget.archive,
                                                       session: session)
        }

        let publishedChange = writeBackInfo.parentTarget.topLevelArchiveURL.map {
            FileManagerArchiveChange(archiveURL: $0,
                                     targetSubdir: writeBackInfo.parentTarget.subdir,
                                     selectingPaths: [writeBackInfo.parentItemPath],
                                     sourceIdentifier: observerIdentifier)
        }
        let refreshedParent = archiveSession.parentIndexForCurrentNestedArchive
            .map { (index: $0, entries: refreshedParentEntries) }
        return (refreshedParent, publishedChange)
    }

    private func normalizeArchivePath(_ path: String) -> String {
        FileManagerArchiveChange.normalizeArchivePath(path)
    }

    private func operationError(_ description: String) -> NSError {
        NSError(domain: SZArchiveErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}
