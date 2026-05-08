import AppKit

func szPresentTransferAncestryConflict(_ conflict: FileManagerTransferPathValidation.Conflict,
                                       move: Bool,
                                       for window: NSWindow?)
{
    let action = move ? "move" : "copy"

    if !conflict.sourceIsDirectory {
        szPresentMessage(title: SZL10n.string("app.fileManager.cannotActionOntoItself", action),
                         message: SZL10n.string("app.fileManager.chooseDifferentDestination"),
                         style: .warning,
                         for: window)
        return
    }

    let sourceFolderName = conflict.sourceURL.lastPathComponent.isEmpty
        ? conflict.sourceURL.path
        : conflict.sourceURL.lastPathComponent
    let title = conflict.kind == .sameDestination
        ? SZL10n.string("app.fileManager.cannotActionIntoSelf", action)
        : SZL10n.string("app.fileManager.cannotActionIntoDescendant", action)

    szPresentMessage(title: title,
                     message: SZL10n.string("app.fileManager.chooseOutside", sourceFolderName),
                     style: .warning,
                     for: window)
}

func szPresentTransferArchiveSelfConflict(move: Bool,
                                          for window: NSWindow?)
{
    let action = move ? "move" : "copy"
    szPresentMessage(title: SZL10n.string("app.fileManager.cannotActionArchiveIntoSelf", action),
                     message: SZL10n.string("app.fileManager.chooseDifferentArchive"),
                     style: .warning,
                     for: window)
}

@MainActor
final class FileOperationDestinationPicker: NSObject {
    private weak var ownerWindow: NSWindow?
    private weak var pathField: NSComboBox?
    private let baseDirectory: URL

    init(ownerWindow: NSWindow?,
         pathField: NSComboBox,
         baseDirectory: URL)
    {
        self.ownerWindow = ownerWindow
        self.pathField = pathField
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    @objc func browse(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = SZL10n.string("app.choose")
        panel.message = SZL10n.string("app.chooseDestination")
        panel.directoryURL = suggestedDirectoryURL()

        if let ownerWindow {
            panel.beginSheetModal(for: ownerWindow) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.pathField?.stringValue = szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
            }
            return
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField?.stringValue = szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
    }

    private func suggestedDirectoryURL() -> URL {
        guard let pathField else {
            return baseDirectory
        }

        let currentValue = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentValue.isEmpty else {
            return baseDirectory
        }

        let expandedPath = NSString(string: currentValue).expandingTildeInPath
        let candidateURL = if NSString(string: expandedPath).isAbsolutePath {
            URL(fileURLWithPath: expandedPath)
        } else {
            URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        var probeURL = candidateURL.standardizedFileURL

        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: probeURL.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? probeURL : probeURL.deletingLastPathComponent()
            }

            let parentURL = probeURL.deletingLastPathComponent().standardizedFileURL
            if parentURL.path == probeURL.path {
                return baseDirectory
            }

            probeURL = parentURL
        }
    }
}

func szNormalizedDestinationDisplayPath(_ path: String) -> String {
    guard !path.isEmpty, path != "/" else {
        return path.isEmpty ? "/" : path
    }
    return path.hasSuffix("/") ? path : path + "/"
}

enum FileOperationDestinationHistory {
    private static var defaults: UserDefaults {
        .standard
    }

    private static let entriesKey = "FileManager.CopyMoveDestinationHistory"
    private static let maxEntries = 20

    static func entries() -> [String] {
        defaults.stringArray(forKey: entriesKey) ?? []
    }

    static func record(_ path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let displayPath = szNormalizedDestinationDisplayPath(normalizedPath)
        var updatedEntries = entries().filter {
            URL(fileURLWithPath: $0).standardizedFileURL.path != normalizedPath
        }
        updatedEntries.insert(displayPath, at: 0)
        if updatedEntries.count > maxEntries {
            updatedEntries.removeSubrange(maxEntries ..< updatedEntries.count)
        }
        defaults.set(updatedEntries, forKey: entriesKey)
    }
}

enum FileOperationDestinationTarget {
    case directory(URL)
    case archive(archiveURL: URL, subdir: String)

    var displayPath: String {
        switch self {
        case let .directory(url):
            return szNormalizedDestinationDisplayPath(url.standardizedFileURL.path)
        case let .archive(archiveURL, subdir):
            let archivePath = archiveURL.standardizedFileURL.path
            let combinedPath = subdir.isEmpty ? archivePath : archivePath + "/" + subdir
            return szNormalizedDestinationDisplayPath(combinedPath)
        }
    }
}

enum FileOperationDestinationResolver {
    static func resolveTarget(from enteredPath: String,
                              relativeTo baseDirectory: URL,
                              createDirectoryIfNeeded: Bool = true) throws -> FileOperationDestinationTarget
    {
        guard !enteredPath.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a destination folder or archive."])
        }

        let expandedPath = NSString(string: enteredPath).expandingTildeInPath
        let candidateURL = if NSString(string: expandedPath).isAbsolutePath {
            URL(fileURLWithPath: expandedPath)
        } else {
            URL(fileURLWithPath: expandedPath, relativeTo: baseDirectory)
        }

        let standardizedURL = candidateURL.standardizedFileURL

        if let archiveTarget = try resolveArchiveTarget(from: standardizedURL) {
            return archiveTarget
        }

        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: standardizedURL.path,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder or archive.",
                              ])
            }
            return .directory(standardizedURL)
        }

        if containsArchiveLikePathComponent(standardizedURL.path) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileNoSuchFileError,
                          userInfo: [
                              NSFilePathErrorKey: standardizedURL.path,
                              NSLocalizedDescriptionKey: "The destination archive does not exist. Use Add to create a new archive.",
                          ])
        }

        guard createDirectoryIfNeeded else {
            return .directory(standardizedURL)
        }

        try FileManager.default.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
        return .directory(standardizedURL)
    }

    static func prepare(_ destinationTarget: FileOperationDestinationTarget) throws -> FileOperationDestinationTarget {
        switch destinationTarget {
        case .archive:
            return destinationTarget
        case let .directory(destinationURL):
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw NSError(domain: NSCocoaErrorDomain,
                                  code: NSFileWriteInvalidFileNameError,
                                  userInfo: [
                                      NSFilePathErrorKey: destinationURL.path,
                                      NSLocalizedDescriptionKey: "The destination path must be a folder or archive.",
                                  ])
                }
                return destinationTarget
            }

            try FileManager.default.createDirectory(at: destinationURL,
                                                    withIntermediateDirectories: true)
            return .directory(destinationURL)
        }
    }

    private static func resolveArchiveTarget(from standardizedURL: URL) throws -> FileOperationDestinationTarget? {
        let pathComponents = standardizedURL.pathComponents

        for componentCount in stride(from: pathComponents.count, through: 1, by: -1) {
            let prefixPath = NSString.path(withComponents: Array(pathComponents.prefix(componentCount)))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: prefixPath, isDirectory: &isDirectory) else {
                continue
            }

            guard !isDirectory.boolValue else {
                continue
            }

            let archiveURL = URL(fileURLWithPath: prefixPath).standardizedFileURL
            guard isArchiveFile(at: archiveURL) else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInvalidFileNameError,
                              userInfo: [
                                  NSFilePathErrorKey: prefixPath,
                                  NSLocalizedDescriptionKey: "The destination path must be a folder or archive.",
                              ])
            }

            let subdir = Array(pathComponents.dropFirst(componentCount)).joined(separator: "/")
            return .archive(archiveURL: archiveURL, subdir: subdir)
        }

        return nil
    }

    private static func isArchiveFile(at url: URL) -> Bool {
        let archive = SZArchive()

        do {
            try archive.open(atPath: url.path)
            archive.close()
            return true
        } catch {
            let nsError = error as NSError
            return nsError.domain == SZArchiveErrorDomain && nsError.code == -12
        }
    }

    private static func containsArchiveLikePathComponent(_ path: String) -> Bool {
        let supportedExtensions = Set(
            SZArchive.supportedFormats()
                .flatMap(\.extensions)
                .map { $0.lowercased() },
        )

        return URL(fileURLWithPath: path).standardizedFileURL.pathComponents.contains { component in
            let ext = URL(fileURLWithPath: component).pathExtension.lowercased()
            return !ext.isEmpty && supportedExtensions.contains(ext)
        }
    }
}

enum FileOperationArchiveTransferSelection {
    static func selectionPaths(for sourceURLs: [URL], targetSubdir: String) -> [String] {
        let normalizedTargetSubdir = normalizeArchivePath(targetSubdir)
        var seenPaths = Set<String>()
        var selectionPaths: [String] = []

        for url in sourceURLs {
            let leafName = url.lastPathComponent
            guard !leafName.isEmpty else { continue }

            let path = normalizedTargetSubdir.isEmpty ? leafName : normalizedTargetSubdir + "/" + leafName
            let normalizedPath = normalizeArchivePath(path)
            guard seenPaths.insert(normalizedPath).inserted else { continue }
            selectionPaths.append(normalizedPath)
        }

        return selectionPaths
    }

    private static func normalizeArchivePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

enum FileOperationDropResolver {
    static func fileSystemDropOperation(sourceMask: NSDragOperation,
                                        containsFilePromises: Bool,
                                        droppedFileURLs: [URL],
                                        destinationDirectory: URL,
                                        volumeURLProvider: (URL) -> URL? = defaultVolumeURL) -> NSDragOperation
    {
        if containsFilePromises {
            return .copy
        }

        let canCopy = sourceMask.contains(.copy)
        let canMove = sourceMask.contains(.move)

        switch (canCopy, canMove) {
        case (false, false):
            return []
        case (true, false):
            return .copy
        case (false, true):
            return .move
        case (true, true):
            guard !droppedFileURLs.isEmpty else {
                return .move
            }
            return shouldPreferMoveForDroppedURLs(droppedFileURLs,
                                                  destinationDirectory: destinationDirectory,
                                                  volumeURLProvider: volumeURLProvider) ? .move : .copy
        }
    }

    static func archiveDropOperation(sourceMask: NSDragOperation,
                                     containsFilePromises: Bool) -> NSDragOperation
    {
        if containsFilePromises {
            return .copy
        }

        let canCopy = sourceMask.contains(.copy)
        let canMove = sourceMask.contains(.move)

        switch (canCopy, canMove) {
        case (false, false):
            return []
        case (true, false):
            return .copy
        case (false, true):
            return .move
        case (true, true):
            return .copy
        }
    }

    private static func shouldPreferMoveForDroppedURLs(_ urls: [URL],
                                                       destinationDirectory: URL,
                                                       volumeURLProvider: (URL) -> URL?) -> Bool
    {
        guard let destinationVolumeURL = volumeURLProvider(destinationDirectory) else {
            return false
        }

        return urls.allSatisfy { volumeURLProvider($0) == destinationVolumeURL }
    }

    private static func defaultVolumeURL(for url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume?.standardizedFileURL
    }
}

@MainActor
enum FileOperationArchiveDestinationTransfer {
    static func perform(_ sourceURLs: [URL],
                        from sourcePane: FileManagerPaneController,
                        toArchiveURL archiveURL: URL,
                        subdir: String,
                        move: Bool,
                        candidatePanes: [FileManagerPaneController],
                        parentWindow: NSWindow?,
                        showError: @escaping @MainActor (Error) -> Void)
    {
        let operation: NSDragOperation = move ? .move : .copy

        if let (pane, target) = archiveDestinationTarget(in: candidatePanes,
                                                         archiveURL: archiveURL,
                                                         subdir: subdir)
        {
            pane.beginArchiveTransfer(sourceURLs,
                                      to: target,
                                      operation: operation,
                                      sourcePane: sourcePane,
                                      parentWindow: parentWindow,
                                      requiresConfirmation: false)
            return
        }

        let operationTitle = SZL10n.string(move ? "fileop.moving" : "fileop.copying")
        let selectionPaths = FileOperationArchiveTransferSelection.selectionPaths(for: sourceURLs,
                                                                                  targetSubdir: subdir)

        Task { @MainActor [weak sourcePane, weak parentWindow] in
            guard let parentWindow else { return }
            do {
                try await ArchiveOperationRunner.run(operationTitle: operationTitle,
                                                     parentWindow: parentWindow)
                { session in
                    let archive = SZArchive()
                    try archive.open(atPath: archiveURL.path, session: session)
                    defer { archive.close() }
                    try archive.addPaths(sourceURLs.map(\.path),
                                         toArchiveSubdir: subdir,
                                         moveMode: move,
                                         session: session)
                }

                FileManagerArchiveChangeCoordinator.publish(
                    FileManagerArchiveChange(archiveURL: archiveURL,
                                             targetSubdir: subdir,
                                             selectingPaths: selectionPaths),
                )
                if move {
                    sourcePane?.refresh()
                }
            } catch {
                showError(error)
            }
        }
    }

    private static func archiveDestinationTarget(in panes: [FileManagerPaneController],
                                                 archiveURL: URL,
                                                 subdir: String) -> (pane: FileManagerPaneController, target: (archive: SZArchive, subdir: String))?
    {
        for pane in panes {
            if let target = pane.currentArchiveMutationTarget(for: archiveURL, subdir: subdir) {
                return (pane, target)
            }
        }

        return nil
    }
}

@MainActor
final class FileOperationDestinationPrompt {
    private var destinationPicker: FileOperationDestinationPicker?
    private let move: Bool
    private let sourcePane: FileManagerPaneController
    private let defaultPath: String
    private let infoText: String
    private let validateDestination: (FileOperationDestinationTarget) -> Bool

    init(move: Bool,
         sourcePane: FileManagerPaneController,
         defaultPath: String,
         infoText: String,
         validateDestination: @escaping (FileOperationDestinationTarget) -> Bool)
    {
        self.move = move
        self.sourcePane = sourcePane
        self.defaultPath = defaultPath
        self.infoText = infoText
        self.validateDestination = validateDestination
    }

    func run() -> FileOperationDestinationTarget? {
        let title = move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.copy")
        let actionTitle = move ? SZL10n.string("toolbar.move") : SZL10n.string("toolbar.copy")
        let labelTitle = move ? SZL10n.string("fileop.moveTo") : SZL10n.string("fileop.copyTo")
        let historyEntries = FileOperationDestinationHistory.entries()

        while true {
            let pathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            pathField.isEditable = true
            pathField.usesDataSource = false
            pathField.completes = false
            pathField.addItems(withObjectValues: historyEntries)
            pathField.stringValue = defaultPath
            pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let browseButton = NSButton(title: SZL10n.string("compress.browse"), target: nil, action: nil)
            browseButton.bezelStyle = .rounded
            browseButton.setContentHuggingPriority(.required, for: .horizontal)
            browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

            let label = NSTextField(labelWithString: labelTitle)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.setContentHuggingPriority(.required, for: .vertical)

            let inputRow = NSStackView(views: [pathField, browseButton])
            inputRow.orientation = .horizontal
            inputRow.alignment = .centerY
            inputRow.spacing = 8
            inputRow.distribution = .fill

            let stack = NSStackView(views: [label, inputRow])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

            let controller = SZModalDialogController(style: .informational,
                                                     title: title,
                                                     message: infoText,
                                                     buttonTitles: [SZL10n.string("common.cancel"), actionTitle],
                                                     accessoryView: stack,
                                                     preferredFirstResponder: pathField,
                                                     cancelButtonIndex: 0)

            let windowBoundPicker = FileOperationDestinationPicker(ownerWindow: controller.window,
                                                                   pathField: pathField,
                                                                   baseDirectory: sourcePane.currentDirectoryURL)
            destinationPicker = windowBoundPicker
            browseButton.target = windowBoundPicker
            browseButton.action = #selector(FileOperationDestinationPicker.browse(_:))

            defer {
                destinationPicker = nil
            }

            guard controller.runModal() == 1 else {
                return nil
            }

            let enteredPath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let destinationTarget = try FileOperationDestinationResolver.resolveTarget(from: enteredPath,
                                                                                           relativeTo: sourcePane.currentDirectoryURL,
                                                                                           createDirectoryIfNeeded: false)
                guard validateDestination(destinationTarget) else {
                    continue
                }
                FileOperationDestinationHistory.record(destinationTarget.displayPath)
                return destinationTarget
            } catch {
                // This prompt reopens in a retry loop, so avoid stacking the error beneath it.
                szPresentError(error, for: nil)
            }
        }
    }
}
