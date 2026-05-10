import Foundation

struct FileManagerArchiveExtractionContext {
    let archive: SZArchive
    let allEntries: [ArchiveItem]
    let currentSubdir: String
    let quarantineSourceArchivePath: String?
}

/// Prepared extraction work is handed to ArchiveOperationRunner; archive/session access is coordinated by the caller.
struct FileManagerPreparedExtraction: @unchecked Sendable {
    let archive: SZArchive
    let entryIndices: [NSNumber]
    let destinationPath: String
    let settings: SZExtractionSettings

    nonisolated func perform(session: SZOperationSession?) throws {
        try archive.extractEntries(entryIndices,
                                   toPath: destinationPath,
                                   settings: settings,
                                   session: session)
    }
}

enum FileManagerArchiveExtraction {
    static func prepare(items: [ArchiveItem],
                        context: FileManagerArchiveExtractionContext,
                        destinationURL: URL,
                        overwriteMode: SZOverwriteMode,
                        pathMode: SZPathMode,
                        password: String?,
                        preserveNtSecurityInfo: Bool,
                        eliminateDuplicates: Bool,
                        inheritDownloadedFileQuarantine: Bool) -> FileManagerPreparedExtraction?
    {
        let indices = entryIndices(for: items,
                                   allEntries: context.allEntries)
        guard !indices.isEmpty else { return nil }

        let settings = extractionSettings(context: context,
                                          overwriteMode: overwriteMode,
                                          pathMode: pathMode,
                                          password: password,
                                          inheritDownloadedFileQuarantine: inheritDownloadedFileQuarantine)
        settings.pathPrefixToStrip = pathPrefixToStrip(for: items,
                                                       context: context,
                                                       destinationURL: destinationURL,
                                                       pathMode: pathMode,
                                                       eliminateDuplicates: eliminateDuplicates)
        settings.preserveNtSecurityInfo = preserveNtSecurityInfo

        return FileManagerPreparedExtraction(archive: context.archive,
                                             entryIndices: indices,
                                             destinationPath: destinationURL.path,
                                             settings: settings)
    }

    static func pathPrefixToStrip(for items: [ArchiveItem],
                                  context: FileManagerArchiveExtractionContext,
                                  destinationURL: URL,
                                  pathMode: SZPathMode,
                                  eliminateDuplicates: Bool) -> String?
    {
        let basePrefix: String? = if pathMode == .currentPaths,
                                     !context.currentSubdir.isEmpty
        {
            context.currentSubdir
        } else {
            nil
        }

        guard eliminateDuplicates,
              pathMode != .absolutePaths,
              pathMode != .noPaths,
              let duplicatePrefix = ArchiveItem.duplicateRootPrefixToStrip(for: items,
                                                                           destinationLeafName: destinationURL.lastPathComponent,
                                                                           removingPrefix: basePrefix)
        else {
            return basePrefix
        }

        return duplicatePrefix
    }

    static func entryIndices(for selectedItems: [ArchiveItem],
                             allEntries: [ArchiveItem]) -> [NSNumber]
    {
        var indices = Set<Int>()

        for item in selectedItems {
            if item.index >= 0 {
                indices.insert(item.index)
            }

            if item.isDirectory || item.index < 0 {
                let directoryPath = normalizeArchivePath(item.path)
                let prefix = directoryPath.isEmpty ? "" : directoryPath + "/"

                for entry in allEntries where entry.index >= 0 {
                    let entryPath = normalizeArchivePath(entry.path)
                    if entryPath == directoryPath || (!prefix.isEmpty && entryPath.hasPrefix(prefix)) {
                        indices.insert(entry.index)
                    }
                }
            }
        }

        return indices.sorted().map { NSNumber(value: $0) }
    }

    private static func extractionSettings(context: FileManagerArchiveExtractionContext,
                                           overwriteMode: SZOverwriteMode,
                                           pathMode: SZPathMode,
                                           password: String?,
                                           inheritDownloadedFileQuarantine: Bool) -> SZExtractionSettings
    {
        let settings = SZExtractionSettings()
        settings.overwriteMode = overwriteMode
        settings.pathMode = pathMode
        if let password, !password.isEmpty {
            settings.password = password
        }
        if inheritDownloadedFileQuarantine {
            settings.sourceArchivePathForQuarantine = context.quarantineSourceArchivePath
        }
        if pathMode == .currentPaths,
           !context.currentSubdir.isEmpty
        {
            settings.pathPrefixToStrip = context.currentSubdir
        }
        return settings
    }

    private static func normalizeArchivePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
