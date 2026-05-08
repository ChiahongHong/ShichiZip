import AppKit

@MainActor
enum FileManagerArchiveCommandSupport {
    static func promptForFilesToAddToOpenArchive(from sourcePane: FileManagerPaneController,
                                                 target: (archive: SZArchive, subdir: String),
                                                 suggestedDirectory: URL,
                                                 parentWindow: NSWindow?)
    {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.resolvesAliases = true
        openPanel.prompt = SZL10n.string("toolbar.add")
        openPanel.message = SZL10n.string("app.fileManager.selectFilesToAdd")
        openPanel.directoryURL = suggestedDirectory

        let handleSelection = {
            let selectedURLs = openPanel.urls.map(\.standardizedFileURL)
            guard !selectedURLs.isEmpty else { return }
            sourcePane.beginConfirmedArchiveTransfer(selectedURLs,
                                                     to: target,
                                                     operation: .copy,
                                                     sourcePane: nil,
                                                     parentWindow: parentWindow)
        }

        if let parentWindow {
            openPanel.beginSheetModal(for: parentWindow) { response in
                guard response == .OK else { return }
                handleSelection()
            }
        } else if openPanel.runModal() == .OK {
            handleSelection()
        }
    }

    static func createArchive(from sourceURLs: [URL],
                              result: CompressDialogResult,
                              parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.compressing"),
                                             parentWindow: parentWindow)
        { session in
            try SZArchive.create(atPath: result.archiveURL.path,
                                 fromPaths: sourceURLs.map(\.path),
                                 settings: result.settings,
                                 session: session)
        }
    }

    static func extractPreparedArchiveItems(_ prepared: FileManagerPaneController.PreparedExtraction,
                                            parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                             parentWindow: parentWindow)
        { session in
            try FileManagerPaneController.performPreparedExtraction(prepared, session: session)
        }
    }

    static func extractArchiveCandidate(_ archiveCandidateURL: URL?,
                                        result: ExtractDialogResult,
                                        parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                             parentWindow: parentWindow)
        { session in
            guard let archiveURL = archiveCandidateURL else {
                throw NSError(domain: SZArchiveErrorDomain,
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.selectArchiveToExtract")])
            }

            let archive = SZArchive()
            try archive.open(atPath: archiveURL.path,
                             password: result.password,
                             session: session)
            defer {
                archive.close()
            }

            let archiveItems = try archive.entries(with: session).map(ArchiveItem.init)
            let settings = extractionSettings(for: result,
                                              archiveURL: archiveURL,
                                              archiveItems: archiveItems)
            try archive.extract(toPath: result.destinationURL.path,
                                settings: settings,
                                session: session)
        }
    }

    static func testPreparedArchive(_ archive: SZArchive,
                                    parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.testing"),
                                             parentWindow: parentWindow)
        { session in
            try archive.test(with: session)
        }
    }

    static func testArchiveCandidate(_ archiveCandidateURL: URL?,
                                     parentWindow: NSWindow) async throws
    {
        try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.testing"),
                                             parentWindow: parentWindow)
        { session in
            guard let archiveURL = archiveCandidateURL else {
                throw NSError(domain: SZArchiveErrorDomain,
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.selectArchiveToTest")])
            }

            let archive = SZArchive()
            try archive.open(atPath: archiveURL.path, session: session)
            defer {
                archive.close()
            }
            try archive.test(with: session)
        }
    }

    private static func extractionSettings(for result: ExtractDialogResult,
                                           archiveURL: URL,
                                           archiveItems: [ArchiveItem]) -> SZExtractionSettings
    {
        let settings = SZExtractionSettings()
        settings.overwriteMode = result.overwriteMode
        settings.pathMode = result.pathMode
        settings.password = result.password
        settings.preserveNtSecurityInfo = result.preserveNtSecurityInfo
        settings.pathPrefixToStrip = archiveExtractionPathPrefixToStrip(for: archiveItems,
                                                                        destinationURL: result.destinationURL,
                                                                        pathMode: result.pathMode,
                                                                        eliminateDuplicates: result.eliminateDuplicates)
        if result.inheritDownloadedFileQuarantine {
            settings.sourceArchivePathForQuarantine = archiveURL.path
        }
        return settings
    }

    private static func archiveExtractionPathPrefixToStrip(for items: [ArchiveItem],
                                                           destinationURL: URL,
                                                           pathMode: SZPathMode,
                                                           eliminateDuplicates: Bool) -> String?
    {
        guard eliminateDuplicates,
              pathMode != .absolutePaths,
              pathMode != .noPaths
        else {
            return nil
        }

        return ArchiveItem.duplicateRootPrefixToStrip(for: items,
                                                      destinationLeafName: destinationURL.lastPathComponent)
    }
}
