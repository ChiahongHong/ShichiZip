import Foundation

struct FileManagerPaneCapabilities {
    let canOpenSelection: Bool
    let canOpenArchiveInViewer: Bool
    let canOpenSelectionInside: Bool
    let canOpenSelectionOutside: Bool
    let canAddSelectedItemsToArchive: Bool
    let canExtractSelectionOrArchive: Bool
    let canTestArchiveSelection: Bool
    let canCopySelection: Bool
    let canMoveSelection: Bool
    let canRenameSelection: Bool
    let canCreateFolderHere: Bool
    let canCreateFileHere: Bool
    let canDeleteSelection: Bool
    let canShowSelectedItemProperties: Bool
    let canCalculateSelectionHashes: Bool
    let canGoUp: Bool
    let canSelectVisibleItems: Bool
    let canDeselectSelection: Bool
    let canShowFoldersHistory: Bool
}

enum FileManagerPaneCommand {
    case openSelection
    case openArchiveInViewer
    case addSelectedItemsToArchive
    case extractSelectionOrArchive
    case renameSelection
    case deleteSelection
    case createFolderHere
    case showSelectedItemProperties
}

extension FileManagerPaneCapabilities {
    func allows(_ command: FileManagerPaneCommand) -> Bool {
        switch command {
        case .openSelection:
            canOpenSelection
        case .openArchiveInViewer:
            canOpenArchiveInViewer
        case .addSelectedItemsToArchive:
            canAddSelectedItemsToArchive
        case .extractSelectionOrArchive:
            canExtractSelectionOrArchive
        case .renameSelection:
            canRenameSelection
        case .deleteSelection:
            canDeleteSelection
        case .createFolderHere:
            canCreateFolderHere
        case .showSelectedItemProperties:
            canShowSelectedItemProperties
        }
    }
}

struct FileManagerPaneSelectionSnapshot {
    let fileURLs: [URL]
    let displayedNames: [String]
    let realItemCount: Int

    var hasHiddenDisplayedNames: Bool {
        realItemCount > displayedNames.count
    }
}

struct FileManagerPaneSelectedFileSnapshot {
    let url: URL
    let name: String
}

struct FileManagerPaneSnapshot {
    let currentDirectoryURL: URL
    let currentLocationDisplayPath: String
    let isVirtualLocation: Bool
    let isSuspended: Bool
    let primarySortKey: String?
    let currentArchiveDestinationDisplayPath: String?
    let recentDirectoryHistory: [URL]
    let acceptsFilePaste: Bool
    let selectedArchiveCandidateURL: URL?
    let selection: FileManagerPaneSelectionSnapshot
    let selectedSingleFileSystemFile: FileManagerPaneSelectedFileSnapshot?
    let suggestedExtractDestinationName: String?
    let extractDialogInfoText: String
    let sourceArchiveURLForPostProcessing: URL?
    let quarantineSourceArchiveURLForExtraction: URL?
    let capabilities: FileManagerPaneCapabilities

    var fileOperationInfoText: String {
        var lines = [currentLocationDisplayPath]
        lines.append(contentsOf: selection.displayedNames.map { "  \($0)" })

        if selection.hasHiddenDisplayedNames {
            lines.append("  ...")
        }

        return lines.joined(separator: "\n")
    }
}

@MainActor
extension FileManagerPaneController {
    var paneCapabilities: FileManagerPaneCapabilities {
        makePaneCapabilities(selectedSingleFileSystemFile: selectedSingleFileSystemFile())
    }

    var snapshot: FileManagerPaneSnapshot {
        let selectedSingleFileSystemFile = selectedSingleFileSystemFile()
        let capabilities = makePaneCapabilities(selectedSingleFileSystemFile: selectedSingleFileSystemFile)

        return FileManagerPaneSnapshot(
            currentDirectoryURL: currentDirectoryURL,
            currentLocationDisplayPath: currentLocationDisplayPath,
            isVirtualLocation: isVirtualLocation,
            isSuspended: isSuspended,
            primarySortKey: primarySortKey,
            currentArchiveDestinationDisplayPath: currentArchiveDestinationDisplayPath(),
            recentDirectoryHistory: recentDirectoryHistory(),
            acceptsFilePaste: !isVirtualLocation || supportsInPlaceArchiveMutation,
            selectedArchiveCandidateURL: selectedArchiveCandidateURL(),
            selection: FileManagerPaneSelectionSnapshot(fileURLs: selectedFileURLs(),
                                                        displayedNames: selectedItemNames(limit: 5),
                                                        realItemCount: selectedRealItemCount),
            selectedSingleFileSystemFile: selectedSingleFileSystemFile.map {
                FileManagerPaneSelectedFileSnapshot(url: $0.url,
                                                    name: $0.name)
            },
            suggestedExtractDestinationName: suggestedExtractDestinationName,
            extractDialogInfoText: extractDialogInfoText(),
            sourceArchiveURLForPostProcessing: sourceArchiveURLForPostProcessing(),
            quarantineSourceArchiveURLForExtraction: quarantineSourceArchiveURLForExtraction(),
            capabilities: capabilities,
        )
    }

    private func makePaneCapabilities(selectedSingleFileSystemFile: FileSystemItem?) -> FileManagerPaneCapabilities {
        FileManagerPaneCapabilities(canOpenSelection: canOpenSelection(),
                                    canOpenArchiveInViewer: selectedArchiveCandidateURL() != nil,
                                    canOpenSelectionInside: canOpenSelectionInside(),
                                    canOpenSelectionOutside: canOpenSelectionOutside(),
                                    canAddSelectedItemsToArchive: canAddSelectedItemsToArchive(),
                                    canExtractSelectionOrArchive: canExtractSelectionOrArchive(),
                                    canTestArchiveSelection: canTestArchiveSelection(),
                                    canCopySelection: canCopySelection(),
                                    canMoveSelection: canMoveSelection(),
                                    canRenameSelection: canRenameSelection(),
                                    canCreateFolderHere: canCreateFolderHere(),
                                    canCreateFileHere: canCreateFileHere(),
                                    canDeleteSelection: canDeleteSelection(),
                                    canShowSelectedItemProperties: canShowSelectedItemProperties(),
                                    canCalculateSelectionHashes: selectedSingleFileSystemFile != nil,
                                    canGoUp: canGoUp(),
                                    canSelectVisibleItems: canSelectVisibleItems(),
                                    canDeselectSelection: canDeselectSelection(),
                                    canShowFoldersHistory: canShowFoldersHistory())
    }
}
