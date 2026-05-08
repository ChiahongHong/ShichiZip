import Cocoa

/// Dual-pane file manager window replicating 7-Zip File Manager
@MainActor
class FileManagerWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations, NSMenuItemValidation {
    private var splitView: NSSplitView!
    private var leftPane: FileManagerPaneController!
    private var rightPane: FileManagerPaneController!
    private var toolbar: NSToolbar!
    private var isDualPane = FileManagerPanePreferences.showsDualPane
    private weak var trackedActivePane: FileManagerPaneController?
    private var viewPreferencesObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var autoRefreshTimer: Timer?
    private var foldersHistoryWindowController: FoldersHistoryWindowController?
    private var pendingEvenSplitLayout = false
    let quickLookPanelController = FileManagerQuickLookPanelController()
    private let windowCoordinator: any FileManagerWindowCoordinating

    var onWindowWillClose: ((FileManagerWindowController) -> Void)?

    private var archiveCoordinationPaneControllers: [FileManagerPaneController] {
        isDualPane ? [leftPane, rightPane] : [leftPane]
    }

    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot] {
        archiveCoordinationPaneControllers.flatMap { $0.archiveCoordinationSnapshots() }
    }

    init(windowCoordinator: any FileManagerWindowCoordinating) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = AppBuildInfo.appDisplayName()
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        self.windowCoordinator = windowCoordinator
        super.init(window: window)
        window.delegate = self
        setupUI()
        setupToolbar()
        observeViewPreferences()
        configureAutoRefreshTimer()
        trackedActivePane = leftPane
        self.window?.initialFirstResponder = leftPane.preferredInitialFirstResponder
        self.window?.makeFirstResponder(leftPane.preferredInitialFirstResponder)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        if let viewPreferencesObserver {
            NotificationCenter.default.removeObserver(viewPreferencesObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        autoRefreshTimer?.invalidate()
        quickLookPanelController.cancelAndClear()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyPendingEvenSplitLayoutIfNeeded()
        activePane.focusFileList()
    }

    @discardableResult
    func prepareForClose(showError: Bool = true) -> Bool {
        let panes = isDualPane ? [leftPane, rightPane] : [leftPane]
        for pane in panes {
            guard pane?.prepareForClose(showError: showError) != false else {
                return false
            }
        }
        return true
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        prepareForClose(showError: true)
    }

    func windowWillClose(_: Notification) {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        quickLookPanelController.closePreview()
        onWindowWillClose?(self)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.setAccessibilityIdentifier("fileManager.splitView")

        leftPane = FileManagerPaneController()
        leftPane.delegate = self
        leftPane.archiveCoordinationProvider = windowCoordinator
        leftPane.view.setAccessibilityIdentifier("fileManager.leftPane")

        rightPane = FileManagerPaneController()
        rightPane.delegate = self
        rightPane.archiveCoordinationProvider = windowCoordinator
        rightPane.view.setAccessibilityIdentifier("fileManager.rightPane")

        splitView.addArrangedSubview(leftPane.view)
        if isDualPane {
            splitView.addArrangedSubview(rightPane.view)
            pendingEvenSplitLayout = true
        } else {
            rightPane.prepareForDeactivation(showError: false)
        }

        contentView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func setupToolbar() {
        guard FileManagerToolbarPreferences.showsArchiveToolbar || FileManagerToolbarPreferences.showsStandardToolbar else {
            toolbar = nil
            window?.toolbar = nil
            return
        }

        let newToolbar = NSToolbar(identifier: "FileManagerToolbar")
        newToolbar.delegate = self
        toolbar = newToolbar
        window?.toolbarStyle = FileManagerToolbarPreferences.style.toolbarStyle
        window?.toolbar = newToolbar
        applyToolbarPresentation()
    }

    private func applyToolbarPresentation() {
        guard let toolbar else { return }
        toolbar.displayMode = FileManagerToolbarPreferences.showsButtonText ? .iconAndLabel : .iconOnly
        window?.toolbarStyle = FileManagerToolbarPreferences.style.toolbarStyle
        refreshToolbarItemPresentation()
        toolbar.validateVisibleItems()
    }

    private func refreshToolbarItemPresentation() {
        toolbar?.items.forEach(configureToolbarItem(_:))
    }

    private func observeViewPreferences() {
        viewPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .fileManagerViewPreferencesDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleViewPreferencesDidChange()
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: .szLanguageDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshToolbarItemPresentation()
            }
        }
    }

    private func handleViewPreferencesDidChange() {
        configureAutoRefreshTimer()
        MainMenu.refreshDynamicMenuState()
        leftPane.reloadPresentedValues()
        rightPane.reloadPresentedValues()
        if FileManagerViewPreferences.autoRefreshEnabled {
            performAutoRefreshTick()
        }
    }

    private func configureAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil

        guard FileManagerViewPreferences.autoRefreshEnabled else { return }

        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performAutoRefreshTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    private func performAutoRefreshTick() {
        guard window?.isVisible == true else { return }
        leftPane.autoRefreshIfPossible()
        if isDualPane {
            rightPane.autoRefreshIfPossible()
        }
    }

    @objc func openSelectedItem(_: Any?) {
        activePane.openSelection()
    }

    @objc func toggleQuickLook(_: Any?) {
        quickLookPanelController.togglePreview(for: activePane,
                                               currentController: self,
                                               showError: quickLookErrorReporter())
    }

    private func quickLookErrorReporter() -> @MainActor (Error) -> Void {
        { [weak self] error in
            self?.showErrorAlert(error)
        }
    }

    private func performShortcutCommand(_ command: FileManagerShortcutCommand,
                                        from pane: FileManagerPaneController) -> Bool
    {
        setActivePane(pane)
        return NSApp.sendAction(command.fileManagerWindowAction,
                                to: self,
                                from: nil)
    }

    // MARK: - Actions

    /// Navigate the active pane to show an archive's contents
    @discardableResult
    func navigateToArchive(_ url: URL, revealWindow: Bool = true) -> Bool {
        let opened = activePane.showArchive(at: url)
        if opened, revealWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        return opened
    }

    @discardableResult
    func revealFileSystemItems(_ urls: [URL], revealWindow: Bool = true) -> Bool {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return false }

        let targetPane = paneRoutingContext.targetPaneForRevealingFileSystemItems(standardizedURLs)

        let revealed = targetPane.revealFileSystemItemURLs(standardizedURLs)
        if revealed, revealWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        return revealed
    }

    @discardableResult
    func openFileSystemItem(_ url: URL, revealWindow: Bool = true) -> Bool {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            return false
        }

        let targetPane = paneRoutingContext.targetPaneForOpeningFileSystemItem(standardizedURL,
                                                                               isDirectory: isDirectory.boolValue)

        let opened = targetPane.openFileSystemItemURL(standardizedURL)
        if opened, revealWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        return opened
    }

    @objc func toggleDualPane(_: Any?) {
        if isDualPane {
            let wasRightPaneActive = activePane === rightPane
            guard rightPane.prepareForDeactivation(showError: true) else {
                return
            }

            isDualPane = false
            FileManagerPanePreferences.setShowsDualPane(false)
            rightPane.view.removeFromSuperview()
            pendingEvenSplitLayout = false
            if wasRightPaneActive {
                leftPane.focusFileList()
            }
        } else {
            isDualPane = true
            FileManagerPanePreferences.setShowsDualPane(true)
            splitView.addArrangedSubview(rightPane.view)
            rightPane.reactivateIfSuspended()
            scheduleEvenSplitLayout()
        }
    }

    private func scheduleEvenSplitLayout() {
        guard isDualPane else {
            pendingEvenSplitLayout = false
            return
        }

        pendingEvenSplitLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingEvenSplitLayoutIfNeeded()
        }
    }

    private func applyPendingEvenSplitLayoutIfNeeded() {
        guard pendingEvenSplitLayout, isDualPane else { return }
        guard splitView.arrangedSubviews.count > 1 else { return }

        window?.contentView?.layoutSubtreeIfNeeded()
        splitView.layoutSubtreeIfNeeded()

        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        guard availableWidth > 0 else { return }

        splitView.setPosition(floor(availableWidth / 2.0), ofDividerAt: 0)
        pendingEvenSplitLayout = false
    }

    @objc func addToArchive(_: Any?) {
        let activePane = activePane
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canAddSelectedItemsToArchive else {
            if snapshot.isVirtualLocation, !snapshot.acceptsFilePaste {
                activePane.showReadOnlyArchiveMutationAlert(action: "Adding files to archive")
            }
            return
        }

        if snapshot.isVirtualLocation {
            guard let target = activePane.currentArchiveMutationTarget() else {
                activePane.showReadOnlyArchiveMutationAlert(action: "Adding files to archive")
                return
            }

            FileManagerArchiveCommandSupport.promptForFilesToAddToOpenArchive(from: activePane,
                                                                              target: target,
                                                                              suggestedDirectory: suggestedArchiveAddSourceDirectory(for: activePane),
                                                                              parentWindow: window)
            return
        }

        let selectedURLs = snapshot.selection.fileURLs
        guard !selectedURLs.isEmpty else { return }

        let baseDirectory = snapshot.currentDirectoryURL
        let parentWindow = window

        Task { @MainActor [weak self, weak activePane] in
            guard let self,
                  let activePane
            else {
                return
            }

            let compressDialog = CompressDialogController(sourceURLs: selectedURLs,
                                                          baseDirectory: baseDirectory)
            guard let result = await compressDialog.runModal(for: parentWindow),
                  let parentWindow
            else {
                return
            }

            do {
                try await FileManagerArchiveCommandSupport.createArchive(from: selectedURLs,
                                                                         result: result,
                                                                         parentWindow: parentWindow)
                activePane.refresh()
                refreshPaneDisplayingDirectory(result.archiveURL.deletingLastPathComponent())
            } catch {
                showErrorAlert(error)
            }
        }
    }

    @objc func extractArchive(_: Any?) {
        let activePane = activePane
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canExtractSelectionOrArchive else { return }

        Task { @MainActor [weak self, weak activePane] in
            guard let self,
                  let activePane,
                  let extractResult = await promptForArchiveDestination(from: activePane),
                  let parentWindow = window
            else {
                return
            }

            let sourceArchiveURL = snapshot.sourceArchiveURLForPostProcessing
            let isVirtualLocation = snapshot.isVirtualLocation
            let archiveCandidateURL = isVirtualLocation ? nil : snapshot.selectedArchiveCandidateURL

            do {
                if isVirtualLocation {
                    let prepared = try activePane.prepareExtraction(to: extractResult.destinationURL,
                                                                    overwriteMode: extractResult.overwriteMode,
                                                                    pathMode: extractResult.pathMode,
                                                                    password: extractResult.password,
                                                                    preserveNtSecurityInfo: extractResult.preserveNtSecurityInfo,
                                                                    eliminateDuplicates: extractResult.eliminateDuplicates,
                                                                    inheritDownloadedFileQuarantine: extractResult.inheritDownloadedFileQuarantine)
                    try await FileManagerArchiveCommandSupport.extractPreparedArchiveItems(prepared,
                                                                                           parentWindow: parentWindow)
                } else {
                    try await FileManagerArchiveCommandSupport.extractArchiveCandidate(archiveCandidateURL,
                                                                                       result: extractResult,
                                                                                       parentWindow: parentWindow)
                }

                let postProcessResult: ArchiveExtractionPostProcessResult
                let postProcessError: Error?
                do {
                    postProcessResult = try ArchiveExtractionPostProcessor.finalizeExtraction(sourceArchiveURL: sourceArchiveURL,
                                                                                              moveSourceArchiveToTrash: extractResult.moveArchiveToTrashAfterExtraction)
                    postProcessError = nil
                } catch {
                    postProcessResult = ArchiveExtractionPostProcessResult(movedSourceArchiveToTrash: false)
                    postProcessError = error
                }
                refreshPaneDisplayingDirectory(extractResult.destinationURL)
                if postProcessResult.movedSourceArchiveToTrash,
                   let sourceArchiveURL
                {
                    refreshPaneDisplayingDirectory(sourceArchiveURL.deletingLastPathComponent())
                }
                NSWorkspace.shared.open(extractResult.destinationURL)
                if let postProcessError {
                    showErrorAlert(postProcessError)
                }
            } catch {
                showErrorAlert(error)
            }
        }
    }

    @objc func testArchive(_: Any?) {
        let activePane = activePane
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canTestArchiveSelection else { return }

        let isVirtualLocation = snapshot.isVirtualLocation
        let archiveCandidateURL = isVirtualLocation ? nil : snapshot.selectedArchiveCandidateURL

        Task { @MainActor [weak self] in
            guard let self, let parentWindow = window else { return }
            do {
                if isVirtualLocation {
                    let archive = try activePane.currentArchiveForTest()
                    try await FileManagerArchiveCommandSupport.testPreparedArchive(archive,
                                                                                   parentWindow: parentWindow)
                } else {
                    try await FileManagerArchiveCommandSupport.testArchiveCandidate(archiveCandidateURL,
                                                                                    parentWindow: parentWindow)
                }
                szPresentMessage(title: SZL10n.string("app.fileManager.testOK"),
                                 message: SZL10n.string("archive.noErrors"),
                                 for: window)
            } catch {
                showErrorAlert(error)
            }
        }
    }

    @objc func openSelectedItemInside(_: Any?) {
        activePane.openSelectionInside(.defaultBehavior)
    }

    @objc func openSelectedItemInsideWildcard(_: Any?) {
        activePane.openSelectionInside(.wildcard)
    }

    @objc func openSelectedItemInsideParser(_: Any?) {
        activePane.openSelectionInside(.parser)
    }

    @objc func openSelectedItemOutside(_: Any?) {
        activePane.openSelectionOutside()
    }

    @objc func goUpOneLevel(_: Any?) {
        activePane.goUpOneLevel()
    }

    @objc func renameSelection(_: Any?) {
        activePane.renameSelection()
    }

    @objc func showProperties(_: Any?) {
        activePane.showSelectedItemProperties()
    }

    @objc func extractHere(_: Any?) {
        activePane.extractSelectionHere()
    }

    @objc func refreshActivePane(_: Any?) {
        activePane.refresh()
    }

    @objc func closeDirectory(_: Any?) {
        activePane.closeDirectory()
    }

    @objc func showCRC32Hash(_: Any?) {
        presentSelectionHash(.crc32)
    }

    @objc func showAllHashes(_: Any?) {
        presentSelectionHash(.all)
    }

    @objc func showCRC64Hash(_: Any?) {
        presentSelectionHash(.crc64)
    }

    @objc func showXXH64Hash(_: Any?) {
        presentSelectionHash(.xxh64)
    }

    @objc func showMD5Hash(_: Any?) {
        presentSelectionHash(.md5)
    }

    @objc func showSHA1Hash(_: Any?) {
        presentSelectionHash(.sha1)
    }

    @objc func showSHA256Hash(_: Any?) {
        presentSelectionHash(.sha256)
    }

    @objc func showSHA384Hash(_: Any?) {
        presentSelectionHash(.sha384)
    }

    @objc func showSHA512Hash(_: Any?) {
        presentSelectionHash(.sha512)
    }

    @objc func showSHA3256Hash(_: Any?) {
        presentSelectionHash(.sha3256)
    }

    @objc func showBLAKE2spHash(_: Any?) {
        presentSelectionHash(.blake2sp)
    }

    @objc func copy(_ sender: Any?) {
        if FileManagerTextEditingActionDispatcher.dispatchIfPossible(#selector(NSText.copy(_:)),
                                                                     sender: sender,
                                                                     window: window)
        {
            return
        }

        FileManagerClipboardSupport.copySelection(from: activePane.snapshot)
    }

    @objc func paste(_ sender: Any?) {
        if FileManagerTextEditingActionDispatcher.dispatchIfPossible(#selector(NSText.paste(_:)),
                                                                     sender: sender,
                                                                     window: window)
        {
            return
        }

        let pane = activePane
        FileManagerClipboardSupport.pasteFiles(FileManagerClipboard.fileURLs(),
                                               into: pane,
                                               parentWindow: window,
                                               refreshAfterFilesystemTransfer: { [weak self] pane, destinationURL, operation in
                                                   self?.refreshAfterFilesystemTransfer(from: pane,
                                                                                        to: destinationURL,
                                                                                        operation: operation)
                                               },
                                               showError: { [weak self] error in
                                                   self?.showErrorAlert(error)
                                               })
    }

    override func selectAll(_ sender: Any?) {
        if FileManagerTextEditingActionDispatcher.dispatchIfPossible(#selector(NSText.selectAll(_:)),
                                                                     sender: sender,
                                                                     window: window)
        {
            return
        }
        activePane.selectAllItems()
    }

    @objc func deselectAllItems(_: Any?) {
        activePane.deselectAllItems()
    }

    @objc func invertSelection(_: Any?) {
        activePane.invertSelection()
    }

    @objc func sortByName(_: Any?) {
        activePane.sortByName()
    }

    @objc func sortBySize(_: Any?) {
        activePane.sortBySize()
    }

    @objc func sortByType(_: Any?) {
        activePane.sortByType()
    }

    @objc func sortByModifiedDate(_: Any?) {
        activePane.sortByModifiedDate()
    }

    @objc func sortByCreatedDate(_: Any?) {
        activePane.sortByCreatedDate()
    }

    @objc func showTimestampDay(_: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.day)
    }

    @objc func showTimestampMinute(_: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.minute)
    }

    @objc func showTimestampSecond(_: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.second)
    }

    @objc func showTimestampNTFS(_: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.ntfs)
    }

    @objc func showTimestampNanoseconds(_: Any?) {
        FileManagerViewPreferences.setTimestampDisplayLevel(.nanoseconds)
    }

    @objc func toggleTimestampUTC(_: Any?) {
        FileManagerViewPreferences.setUsesUTCTimestamps(!FileManagerViewPreferences.usesUTCTimestamps)
    }

    @objc func toggleAutoRefresh(_: Any?) {
        FileManagerViewPreferences.setAutoRefreshEnabled(!FileManagerViewPreferences.autoRefreshEnabled)
    }

    @objc func openRootFolder(_: Any?) {
        activePane.openRootFolder()
    }

    @objc func showFoldersHistory(_: Any?) {
        let pane = activePane
        let entries = pane.snapshot.recentDirectoryHistory
        guard !entries.isEmpty, let window else { return }

        let controller = FoldersHistoryWindowController(entries: entries)
        foldersHistoryWindowController = controller
        controller.beginSheetModal(for: window) { [weak self, weak pane] result in
            self?.foldersHistoryWindowController = nil
            guard let pane, let result else { return }

            pane.setRecentDirectoryHistory(result.updatedEntries)
            if let selectedURL = result.selectedURL {
                pane.openRecentDirectory(selectedURL)
            }
        }
    }

    @objc func toggleArchiveToolbar(_: Any?) {
        FileManagerToolbarPreferences.setShowsArchiveToolbar(!FileManagerToolbarPreferences.showsArchiveToolbar)
        setupToolbar()
    }

    @objc func toggleStandardToolbar(_: Any?) {
        FileManagerToolbarPreferences.setShowsStandardToolbar(!FileManagerToolbarPreferences.showsStandardToolbar)
        setupToolbar()
    }

    @objc func toggleToolbarButtonText(_: Any?) {
        FileManagerToolbarPreferences.setShowsButtonText(!FileManagerToolbarPreferences.showsButtonText)
        applyToolbarPresentation()
    }

    @objc func toggleUnifiedToolbarStyle(_: Any?) {
        FileManagerToolbarPreferences.setStyle(FileManagerToolbarPreferences.style == .unified ? .expanded : .unified)
        applyToolbarPresentation()
    }

    @objc func openFavoriteSlot(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let url = FileManagerFavoriteStore.url(for: menuItem.tag)
        else {
            return
        }

        activePane.openRecentDirectory(url)
    }

    @objc func saveFavoriteSlot(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        FileManagerFavoriteStore.set(url: activePane.snapshot.currentDirectoryURL, for: menuItem.tag)
    }

    @objc func switchPanes(_: Any?) {
        inactivePane?.focusFileList()
    }

    private var paneRoutingContext: FileManagerPaneRoutingContext {
        FileManagerPaneRoutingContext(leftPane: leftPane,
                                      rightPane: rightPane,
                                      isDualPane: isDualPane,
                                      trackedActivePane: trackedActivePane,
                                      firstResponderView: window?.firstResponder as? NSView)
    }

    private var activePane: FileManagerPaneController {
        paneRoutingContext.activePane
    }

    private var inactivePane: FileManagerPaneController? {
        paneRoutingContext.inactivePane
    }

    private func setActivePane(_ pane: FileManagerPaneController) {
        trackedActivePane = paneRoutingContext.normalizedTrackedPane(for: pane)
    }

    // MARK: - Copy/Move (PanelCopy.cpp pattern)

    @objc func copyFiles(_: Any?) {
        performFileOperation(move: false)
    }

    @objc func moveFiles(_: Any?) {
        performFileOperation(move: true)
    }

    private func performFileOperation(move: Bool) {
        let pane = activePane
        let snapshot = pane.snapshot

        if snapshot.isVirtualLocation {
            if move {
                showUnsupportedOperationAlert("Moving items from an open archive is not implemented yet. Use Copy to extract them out first.")
                return
            }

            guard snapshot.capabilities.canCopySelection else { return }
            guard let unresolvedDestinationTarget = promptForFileOperationDestination(forMove: false, sourcePane: pane) else { return }

            let destinationTarget: FileOperationDestinationTarget
            do {
                destinationTarget = try FileOperationDestinationResolver.prepare(unresolvedDestinationTarget)
            } catch {
                showErrorAlert(error)
                return
            }

            switch destinationTarget {
            case let .directory(destURL):
                Task { @MainActor [weak self] in
                    guard let self, let parentWindow = window else { return }
                    do {
                        let prepared = try pane.prepareSelectedItemExtraction(to: destURL,
                                                                              overwriteMode: .ask)
                        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("fileop.copying"),
                                                             parentWindow: parentWindow)
                        { session in
                            try prepared.perform(session: session)
                        }
                        refreshPaneDisplayingDirectory(destURL)
                    } catch {
                        showErrorAlert(error)
                    }
                }
            case .archive:
                showUnsupportedOperationAlert("Copying items from an open archive directly into another archive is not implemented yet.")
            }
            return
        }

        let sourceURLs = snapshot.selection.fileURLs
        guard !sourceURLs.isEmpty else { return }

        guard let destinationTarget = promptForFileOperationDestination(forMove: move, sourcePane: pane) else { return }
        guard validateTransferDestination(destinationTarget,
                                          sourceURLs: sourceURLs,
                                          for: pane,
                                          move: move)
        else {
            return
        }

        let preparedDestinationTarget: FileOperationDestinationTarget
        do {
            preparedDestinationTarget = try FileOperationDestinationResolver.prepare(destinationTarget)
        } catch {
            showErrorAlert(error)
            return
        }

        switch preparedDestinationTarget {
        case let .directory(destURL):
            let dragOperation: NSDragOperation = move ? .move : .copy
            let operationTitle = SZL10n.string(move ? "fileop.moving" : "fileop.copying")
            Task { @MainActor [weak self] in
                guard let self, let parentWindow = window else { return }
                do {
                    try await ArchiveOperationRunner.run(operationTitle: operationTitle,
                                                         parentWindow: parentWindow)
                    { session in
                        try pane.transferFileSystemItemURLs(sourceURLs,
                                                            to: destURL,
                                                            operation: dragOperation,
                                                            session: session)
                    }
                    refreshAfterFilesystemTransfer(from: pane,
                                                   to: destURL,
                                                   operation: dragOperation)
                } catch {
                    showErrorAlert(error)
                }
            }
        case let .archive(archiveURL, subdir):
            performArchiveDestinationTransfer(sourceURLs,
                                              from: pane,
                                              toArchiveURL: archiveURL,
                                              subdir: subdir,
                                              move: move)
        }
    }

    @objc func createFolder(_: Any?) {
        let activePane = activePane
        let snapshot = activePane.snapshot
        guard snapshot.capabilities.canCreateFolderHere else {
            if snapshot.isVirtualLocation, !snapshot.acceptsFilePaste {
                activePane.showReadOnlyArchiveMutationAlert(action: "Creating folders")
            }
            return
        }

        guard let window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("create.folder"),
                         message: SZL10n.string("app.fileManager.enterFolderName"),
                         placeholder: SZL10n.string("create.newFolder"),
                         confirmTitle: SZL10n.string("create.folder"))
        { [weak self] value in
            guard let name = value, !name.isEmpty else { return }
            self?.activePane.createFolder(named: name)
        }
    }

    @objc func createFile(_: Any?) {
        guard activePane.snapshot.capabilities.canCreateFileHere else {
            showUnsupportedOperationAlert("Creating files inside an open archive is not implemented yet.")
            return
        }

        guard let window else { return }
        szBeginTextInput(on: window,
                         title: SZL10n.string("create.file"),
                         message: SZL10n.string("app.fileManager.enterFileName"),
                         placeholder: SZL10n.string("create.newFile"),
                         confirmTitle: SZL10n.string("create.file"))
        { [weak self] value in
            guard let name = value, !name.isEmpty else { return }
            self?.activePane.createFile(named: name)
        }
    }

    @objc func deleteFiles(_: Any?) {
        let activePane = activePane
        guard activePane.snapshot.capabilities.canDeleteSelection else { return }
        activePane.deleteSelection()
    }

    private func presentSelectionHash(_ algorithm: FileManagerHashAlgorithm) {
        let snapshot = activePane.snapshot
        guard let item = snapshot.selectedSingleFileSystemFile else { return }

        let itemName = item.name
        let itemPath = item.url.path

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let hashValues = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("checksum.calculating"),
                                                                      initialFileName: itemPath,
                                                                      parentWindow: window,
                                                                      deferredDisplay: true)
                { session in
                    try SZArchive.calculateHash(forPath: itemPath, session: session)
                }
                let details = algorithm.details(hashValues: hashValues)
                szShowDetailsDialog(title: itemName,
                                    summary: itemPath,
                                    details: details,
                                    for: window)
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private var commandValidationContext: FileManagerCommandValidationContext {
        FileManagerCommandValidationContext(activePaneSnapshot: activePane.snapshot,
                                            isDualPane: isDualPane,
                                            window: window)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        FileManagerCommandValidator.validate(item,
                                             context: commandValidationContext)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FileManagerCommandValidator.validate(menuItem,
                                             context: commandValidationContext)
    }

    private func suggestedArchiveAddSourceDirectory(for targetPane: FileManagerPaneController) -> URL {
        if let otherSnapshot = inactivePane?.snapshot,
           !otherSnapshot.isVirtualLocation
        {
            return otherSnapshot.currentDirectoryURL.standardizedFileURL
        }

        return targetPane.snapshot.currentDirectoryURL.standardizedFileURL
    }

    private func suggestedDestinationPath(for sourcePane: FileManagerPaneController) -> String {
        if let otherSnapshot = inactivePane?.snapshot {
            if let archivePath = otherSnapshot.currentArchiveDestinationDisplayPath {
                return szNormalizedDestinationDisplayPath(archivePath)
            }

            if !otherSnapshot.isVirtualLocation {
                return szNormalizedDestinationDisplayPath(otherSnapshot.currentDirectoryURL.standardizedFileURL.path)
            }
        }

        return szNormalizedDestinationDisplayPath(sourcePane.snapshot.currentDirectoryURL.standardizedFileURL.path)
    }

    private func promptForArchiveDestination(from sourcePane: FileManagerPaneController) async -> ExtractDialogResult? {
        let snapshot = sourcePane.snapshot
        let dialog = ExtractDialogController(suggestedDestinationURL: snapshot.currentDirectoryURL,
                                             baseDirectory: snapshot.currentDirectoryURL,
                                             message: snapshot.extractDialogInfoText,
                                             defaultPathMode: snapshot.isVirtualLocation ? .currentPaths : .fullPaths,
                                             showsCurrentPathsOption: snapshot.isVirtualLocation,
                                             suggestedSplitDestinationName: snapshot.suggestedExtractDestinationName,
                                             sourceArchiveAvailableForMoveToTrash: snapshot.sourceArchiveURLForPostProcessing != nil,
                                             sourceArchiveAvailableForQuarantineInheritance: snapshot.quarantineSourceArchiveURLForExtraction != nil)
        return await dialog.runModal(for: window)
    }

    private func promptForFileOperationDestination(forMove move: Bool,
                                                   sourcePane: FileManagerPaneController) -> FileOperationDestinationTarget?
    {
        let sourceSnapshot = sourcePane.snapshot
        let defaultPath = suggestedDestinationPath(for: sourcePane)
        let infoText = sourceSnapshot.fileOperationInfoText

        let prompt = FileOperationDestinationPrompt(move: move,
                                                    sourcePane: sourcePane,
                                                    defaultPath: defaultPath,
                                                    infoText: infoText)
        { [weak self] destinationTarget in
            guard let self else { return false }
            return validateTransferDestination(destinationTarget,
                                               sourceURLs: sourceSnapshot.selection.fileURLs,
                                               for: sourcePane,
                                               move: move)
        }

        return prompt.run()
    }

    private func validateTransferDestination(_ destinationTarget: FileOperationDestinationTarget,
                                             sourceURLs: [URL],
                                             for _: FileManagerPaneController,
                                             move: Bool) -> Bool
    {
        switch destinationTarget {
        case let .archive(archiveURL, _):
            let selectedURLs = Set(sourceURLs.map(\.standardizedFileURL))
            guard !selectedURLs.contains(archiveURL.standardizedFileURL) else {
                szPresentTransferArchiveSelfConflict(move: move,
                                                     for: window)
                return false
            }

            if let conflict = FileManagerTransferPathValidation.ancestryConflict(sourceURLs: sourceURLs,
                                                                                 destinationURL: archiveURL)
            {
                szPresentTransferAncestryConflict(conflict,
                                                  move: move,
                                                  for: window)
                return false
            }

            return true
        case let .directory(destinationURL):
            let standardizedDestination = destinationURL.standardizedFileURL

            if let conflict = FileManagerTransferPathValidation.ancestryConflict(sourceURLs: sourceURLs,
                                                                                 destinationURL: standardizedDestination)
            {
                szPresentTransferAncestryConflict(conflict,
                                                  move: move,
                                                  for: window)
                return false
            }

            return true
        }
    }

    private func performArchiveDestinationTransfer(_ sourceURLs: [URL],
                                                   from sourcePane: FileManagerPaneController,
                                                   toArchiveURL archiveURL: URL,
                                                   subdir: String,
                                                   move: Bool)
    {
        FileOperationArchiveDestinationTransfer.perform(sourceURLs,
                                                        from: sourcePane,
                                                        toArchiveURL: archiveURL,
                                                        subdir: subdir,
                                                        move: move,
                                                        candidatePanes: archiveCoordinationPaneControllers,
                                                        parentWindow: window)
        { [weak self] error in
            self?.showErrorAlert(error)
        }
    }

    private func refreshPaneDisplayingDirectory(_ directoryURL: URL) {
        paneRoutingContext.refreshPaneDisplayingDirectory(directoryURL)
    }

    private func refreshAfterFilesystemTransfer(from sourcePane: FileManagerPaneController,
                                                to destinationURL: URL,
                                                operation: NSDragOperation)
    {
        refreshPaneDisplayingDirectory(destinationURL)

        if operation == .move {
            sourcePane.refresh()
        }
    }

    private func showErrorAlert(_ error: Error) {
        szPresentError(error, for: window)
    }

    private func showUnsupportedOperationAlert(_ message: String) {
        szPresentMessage(title: SZL10n.string("app.fileManager.operationNotAvailable"),
                         message: message,
                         for: window)
    }
}

private extension FileManagerShortcutCommand {
    var fileManagerWindowAction: Selector {
        switch self {
        case .openSelectedItem:
            #selector(FileManagerWindowController.openSelectedItem(_:))
        case .toggleQuickLook:
            #selector(FileManagerWindowController.toggleQuickLook(_:))
        case .goUpOneLevel:
            #selector(FileManagerWindowController.goUpOneLevel(_:))
        case .renameSelection:
            #selector(FileManagerWindowController.renameSelection(_:))
        case .switchPanes:
            #selector(FileManagerWindowController.switchPanes(_:))
        case .copyFiles:
            #selector(FileManagerWindowController.copyFiles(_:))
        case .moveFiles:
            #selector(FileManagerWindowController.moveFiles(_:))
        case .createFolder:
            #selector(FileManagerWindowController.createFolder(_:))
        case .deleteFiles:
            #selector(FileManagerWindowController.deleteFiles(_:))
        case .toggleDualPane:
            #selector(FileManagerWindowController.toggleDualPane(_:))
        case .refreshActivePane:
            #selector(FileManagerWindowController.refreshActivePane(_:))
        }
    }
}

// MARK: - FileManagerPaneDelegate

@MainActor
protocol FileManagerPaneDelegate: AnyObject {
    func paneDidRequestOpenArchiveInNewWindow(_ url: URL)
    func paneDidBecomeActive(_ pane: FileManagerPaneController)
    func paneSelectionDidChange(_ pane: FileManagerPaneController)
    func paneDidRequestQuickLook(_ pane: FileManagerPaneController)
    func pane(_ pane: FileManagerPaneController, didRequestShortcutCommand command: FileManagerShortcutCommand) -> Bool
}

extension FileManagerWindowController: FileManagerPaneDelegate {
    func paneDidRequestOpenArchiveInNewWindow(_ url: URL) {
        windowCoordinator.openArchiveInNewFileManager(url)
    }

    func paneDidBecomeActive(_ pane: FileManagerPaneController) {
        setActivePane(pane)
        quickLookPanelController.retargetPreviewIfVisible(to: pane,
                                                          currentController: self,
                                                          showError: quickLookErrorReporter())
    }

    func paneSelectionDidChange(_ pane: FileManagerPaneController) {
        quickLookPanelController.refreshPreviewIfVisible(for: pane,
                                                         currentController: self,
                                                         showError: quickLookErrorReporter())
    }

    func paneDidRequestQuickLook(_ pane: FileManagerPaneController) {
        quickLookPanelController.openPreview(for: pane,
                                             currentController: self,
                                             showError: quickLookErrorReporter())
    }

    func pane(_ pane: FileManagerPaneController, didRequestShortcutCommand command: FileManagerShortcutCommand) -> Bool {
        performShortcutCommand(command,
                               from: pane)
    }
}
