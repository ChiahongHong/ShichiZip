import AppKit

@MainActor
struct FileManagerCommandValidationContext {
    let activePane: FileManagerPaneController
    let isDualPane: Bool
    let window: NSWindow?
}

@MainActor
enum FileManagerCommandValidator {
    static func validate(_ item: any NSValidatedUserInterfaceItem,
                         context: FileManagerCommandValidationContext) -> Bool
    {
        let activePane = context.activePane

        switch item.action {
        case #selector(FileManagerWindowController.openSelectedItem(_:)):
            return activePane.canOpenSelection()
        case #selector(FileManagerWindowController.openSelectedItemInside(_:)),
             #selector(FileManagerWindowController.openSelectedItemInsideWildcard(_:)),
             #selector(FileManagerWindowController.openSelectedItemInsideParser(_:)):
            return activePane.canOpenSelectionInside()
        case #selector(FileManagerWindowController.openSelectedItemOutside(_:)):
            return activePane.canOpenSelectionOutside()
        case #selector(FileManagerWindowController.addToArchive(_:)):
            return activePane.canAddSelectedItemsToArchive()
        case #selector(FileManagerWindowController.extractArchive(_:)):
            return activePane.canExtractSelectionOrArchive()
        case #selector(FileManagerWindowController.extractHere(_:)):
            return activePane.canExtractSelectionOrArchive()
        case #selector(FileManagerWindowController.testArchive(_:)):
            return activePane.canTestArchiveSelection()
        case #selector(FileManagerWindowController.copyFiles(_:)):
            return activePane.canCopySelection()
        case #selector(FileManagerWindowController.moveFiles(_:)):
            return activePane.canMoveSelection()
        case #selector(FileManagerWindowController.renameSelection(_:)):
            return activePane.canRenameSelection()
        case #selector(FileManagerWindowController.createFolder(_:)):
            return activePane.canCreateFolderHere()
        case #selector(FileManagerWindowController.createFile(_:)):
            return activePane.canCreateFileHere()
        case #selector(FileManagerWindowController.deleteFiles(_:)):
            return activePane.canDeleteSelection()
        case #selector(FileManagerWindowController.showProperties(_:)):
            return activePane.canShowSelectedItemProperties()
        case #selector(FileManagerWindowController.showCRC32Hash(_:)),
             #selector(FileManagerWindowController.showAllHashes(_:)),
             #selector(FileManagerWindowController.showCRC64Hash(_:)),
             #selector(FileManagerWindowController.showXXH64Hash(_:)),
             #selector(FileManagerWindowController.showMD5Hash(_:)),
             #selector(FileManagerWindowController.showSHA1Hash(_:)),
             #selector(FileManagerWindowController.showSHA256Hash(_:)),
             #selector(FileManagerWindowController.showSHA384Hash(_:)),
             #selector(FileManagerWindowController.showSHA512Hash(_:)),
             #selector(FileManagerWindowController.showSHA3256Hash(_:)),
             #selector(FileManagerWindowController.showBLAKE2spHash(_:)):
            return activePane.canCalculateSelectionHashes()
        case #selector(FileManagerWindowController.goUpOneLevel(_:)):
            return activePane.canGoUp()
        case #selector(NSText.copy(_:)):
            return FileManagerTextEditingActionDispatcher.firstResponder(in: context.window,
                                                                         supports: #selector(NSText.copy(_:))) ||
                FileManagerClipboardSupport.canCopySelection(from: activePane)
        case #selector(NSText.paste(_:)):
            return FileManagerTextEditingActionDispatcher.firstResponder(in: context.window,
                                                                         supports: #selector(NSText.paste(_:))) ||
                FileManagerClipboardSupport.canPasteFiles(FileManagerClipboard.fileURLs(),
                                                          into: activePane)
        case #selector(NSText.selectAll(_:)):
            return FileManagerTextEditingActionDispatcher.firstResponder(in: context.window,
                                                                         supports: #selector(NSText.selectAll(_:))) ||
                activePane.canSelectVisibleItems()
        case #selector(FileManagerWindowController.invertSelection(_:)):
            return activePane.canSelectVisibleItems()
        case #selector(FileManagerWindowController.deselectAllItems(_:)):
            return activePane.canDeselectSelection()
        case #selector(FileManagerWindowController.refreshActivePane(_:)),
             #selector(FileManagerWindowController.sortByName(_:)),
             #selector(FileManagerWindowController.sortByType(_:)),
             #selector(FileManagerWindowController.sortBySize(_:)),
             #selector(FileManagerWindowController.sortByModifiedDate(_:)),
             #selector(FileManagerWindowController.sortByCreatedDate(_:)):
            return true
        case #selector(FileManagerWindowController.closeDirectory(_:)):
            return !activePane.isSuspended
        case #selector(FileManagerWindowController.showTimestampDay(_:)),
             #selector(FileManagerWindowController.showTimestampMinute(_:)),
             #selector(FileManagerWindowController.showTimestampSecond(_:)),
             #selector(FileManagerWindowController.showTimestampNTFS(_:)),
             #selector(FileManagerWindowController.showTimestampNanoseconds(_:)),
             #selector(FileManagerWindowController.toggleTimestampUTC(_:)),
             #selector(FileManagerWindowController.toggleAutoRefresh(_:)):
            return true
        case #selector(FileManagerWindowController.openRootFolder(_:)):
            return true
        case #selector(FileManagerWindowController.showFoldersHistory(_:)):
            return activePane.canShowFoldersHistory()
        case #selector(FileManagerWindowController.toggleArchiveToolbar(_:)),
             #selector(FileManagerWindowController.toggleStandardToolbar(_:)),
             #selector(FileManagerWindowController.toggleToolbarButtonText(_:)),
             #selector(FileManagerWindowController.toggleUnifiedToolbarStyle(_:)):
            return true
        case #selector(FileManagerWindowController.openFavoriteSlot(_:)):
            guard let menuItem = item as? NSMenuItem else { return false }
            return FileManagerFavoriteStore.url(for: menuItem.tag) != nil
        case #selector(FileManagerWindowController.saveFavoriteSlot(_:)):
            return true
        case #selector(FileManagerWindowController.toggleDualPane(_:)):
            return true
        case #selector(FileManagerWindowController.switchPanes(_:)):
            return context.isDualPane
        default:
            return true
        }
    }

    static func validate(_ menuItem: NSMenuItem,
                         context: FileManagerCommandValidationContext) -> Bool
    {
        let isEnabled = validate(menuItem as any NSValidatedUserInterfaceItem,
                                 context: context)
        let activePane = context.activePane

        switch menuItem.action {
        case #selector(FileManagerWindowController.toggleDualPane(_:)):
            menuItem.state = context.isDualPane ? .on : .off
        case #selector(FileManagerWindowController.sortByName(_:)):
            menuItem.state = activePane.primarySortKey == "name" ? .on : .off
        case #selector(FileManagerWindowController.sortByType(_:)):
            menuItem.state = activePane.primarySortKey == "type" ? .on : .off
        case #selector(FileManagerWindowController.sortBySize(_:)):
            menuItem.state = activePane.primarySortKey == "size" ? .on : .off
        case #selector(FileManagerWindowController.sortByModifiedDate(_:)):
            menuItem.state = activePane.primarySortKey == "modified" ? .on : .off
        case #selector(FileManagerWindowController.sortByCreatedDate(_:)):
            menuItem.state = activePane.primarySortKey == "created" ? .on : .off
        case #selector(FileManagerWindowController.showTimestampDay(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .day ? .on : .off
        case #selector(FileManagerWindowController.showTimestampMinute(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .minute ? .on : .off
        case #selector(FileManagerWindowController.showTimestampSecond(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .second ? .on : .off
        case #selector(FileManagerWindowController.showTimestampNTFS(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .ntfs ? .on : .off
        case #selector(FileManagerWindowController.showTimestampNanoseconds(_:)):
            menuItem.state = FileManagerViewPreferences.timestampDisplayLevel == .nanoseconds ? .on : .off
        case #selector(FileManagerWindowController.toggleTimestampUTC(_:)):
            menuItem.state = FileManagerViewPreferences.usesUTCTimestamps ? .on : .off
        case #selector(FileManagerWindowController.toggleAutoRefresh(_:)):
            menuItem.state = FileManagerViewPreferences.autoRefreshEnabled ? .on : .off
        case #selector(FileManagerWindowController.toggleArchiveToolbar(_:)):
            menuItem.state = FileManagerToolbarPreferences.showsArchiveToolbar ? .on : .off
        case #selector(FileManagerWindowController.toggleStandardToolbar(_:)):
            menuItem.state = FileManagerToolbarPreferences.showsStandardToolbar ? .on : .off
        case #selector(FileManagerWindowController.toggleToolbarButtonText(_:)):
            menuItem.state = FileManagerToolbarPreferences.showsButtonText ? .on : .off
        case #selector(FileManagerWindowController.toggleUnifiedToolbarStyle(_:)):
            menuItem.state = FileManagerToolbarPreferences.style == .unified ? .on : .off
        default:
            menuItem.state = .off
        }

        return isEnabled
    }
}
