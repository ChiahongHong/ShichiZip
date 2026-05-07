import AppKit

@MainActor
enum FileManagerTextEditingActionDispatcher {
    static func firstResponder(in window: NSWindow?, supports action: Selector) -> Bool {
        guard let firstResponder = window?.firstResponder as? NSResponder,
              firstResponder is NSTextView
        else {
            return false
        }

        return firstResponder.responds(to: action)
    }

    @discardableResult
    static func dispatchIfPossible(_ action: Selector,
                                   sender: Any?,
                                   window: NSWindow?) -> Bool
    {
        guard firstResponder(in: window, supports: action) else {
            return false
        }

        return NSApp.sendAction(action, to: nil, from: sender)
    }
}

@MainActor
enum FileManagerClipboard {
    static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: options) as? [URL]
        else {
            return []
        }

        return urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
    }

    static func writeFileURLs(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}

@MainActor
enum FileManagerClipboardSupport {
    static func canCopySelection(from pane: FileManagerPaneController) -> Bool {
        !pane.isVirtualLocation && !pane.selectedFileURLs().isEmpty
    }

    static func canPasteFiles(_ sourceURLs: [URL], into pane: FileManagerPaneController) -> Bool {
        guard !sourceURLs.isEmpty else { return false }

        if pane.isVirtualLocation {
            return pane.currentArchiveMutationTarget() != nil
        }

        return true
    }

    static func copySelection(from pane: FileManagerPaneController) {
        let urls = pane.selectedFileURLs()
        guard !pane.isVirtualLocation, !urls.isEmpty else { return }
        FileManagerClipboard.writeFileURLs(urls)
    }

    static func pasteFiles(_ sourceURLs: [URL],
                           into pane: FileManagerPaneController,
                           parentWindow: NSWindow?,
                           refreshAfterFilesystemTransfer: @escaping @MainActor (FileManagerPaneController, URL, NSDragOperation) -> Void,
                           showError: @escaping @MainActor (Error) -> Void)
    {
        guard !sourceURLs.isEmpty else { return }

        if pane.isVirtualLocation {
            guard let target = pane.currentArchiveMutationTarget() else {
                pane.showReadOnlyArchiveMutationAlert(action: SZL10n.string("app.fileManager.action.addingFilesToArchive"))
                return
            }

            pane.beginConfirmedArchiveTransfer(sourceURLs,
                                               to: target,
                                               operation: .copy,
                                               sourcePane: nil,
                                               parentWindow: parentWindow,
                                               operationTitle: SZL10n.string("app.progress.pasting"))
            return
        }

        let destinationURL = pane.currentDirectoryURL.standardizedFileURL
        guard pane.canTransferFileSystemItemURLs(sourceURLs,
                                                 to: destinationURL,
                                                 operation: .copy,
                                                 presentingIn: parentWindow)
        else {
            return
        }
        guard let parentWindow else { return }

        Task { @MainActor [weak pane, weak parentWindow] in
            guard let pane, let parentWindow else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("app.progress.pasting"),
                                                     parentWindow: parentWindow)
                { session in
                    try pane.transferFileSystemItemURLs(sourceURLs,
                                                        to: destinationURL,
                                                        operation: .copy,
                                                        session: session)
                }
                refreshAfterFilesystemTransfer(pane, destinationURL, .copy)
            } catch {
                showError(error)
            }
        }
    }
}
