import Cocoa

@MainActor
final class FileManagerPaneListViewCoordinator {
    private let tableView: NSTableView
    private var currentFolderTypeID: String?

    private(set) var currentColumns: [FileManagerColumn] = []
    private(set) var isApplyingPreferences = false

    init(tableView: NSTableView) {
        self.tableView = tableView
    }

    func configure(columns: [FileManagerColumn],
                   folderTypeID: String,
                   preferSavedState: Bool = true)
    {
        let listViewInfo = preferSavedState
            ? FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID)
            : nil
        let resolvedColumns = FileManagerViewPreferences.resolvedListViewColumns(columns,
                                                                                 using: listViewInfo)
        let resolvedColumnsByID = Dictionary(uniqueKeysWithValues: resolvedColumns.map { ($0.column.id, $0.column) })
        let currentIDs = Set(currentColumns.map(\.id))
        let newIDs = Set(resolvedColumns.map(\.column.id))

        if preferSavedState,
           currentFolderTypeID == folderTypeID,
           currentIDs == newIDs
        {
            currentColumns = tableView.tableColumns.compactMap { tableColumn in
                resolvedColumnsByID[FileManagerColumnID(rawValue: tableColumn.identifier.rawValue)]
            }
            refreshExistingTableColumns(using: resolvedColumnsByID)
            currentFolderTypeID = folderTypeID
            return
        }

        applyPreferences {
            for tableColumn in tableView.tableColumns.reversed() {
                tableView.removeTableColumn(tableColumn)
            }

            currentColumns = resolvedColumns.map(\.column)
            for resolvedColumn in resolvedColumns {
                let tableColumn = resolvedColumn.column.makeTableColumn()
                tableColumn.width = resolvedColumn.width
                tableView.addTableColumn(tableColumn)
            }

            currentFolderTypeID = folderTypeID

            let sortDescriptor = FileManagerViewPreferences.resolvedListViewSortDescriptor(using: listViewInfo,
                                                                                           columns: columns)
            tableView.sortDescriptors = sortDescriptor.map { [$0] } ?? []
            updateHighlightedColumn(for: tableView.sortDescriptors.first?.key)
        }
    }

    func refreshColumnTitles(columns: [FileManagerColumn],
                             fallbackFolderTypeID: String)
    {
        configure(columns: columns,
                  folderTypeID: currentFolderTypeID ?? fallbackFolderTypeID)
    }

    func handleColumnLayoutDidChange(availableColumns: [FileManagerColumn]) {
        guard !isApplyingPreferences else { return }
        currentColumns = FileManagerColumn.visibleColumns(inTableOrder: tableView.tableColumns,
                                                          availableColumns: availableColumns)
        persistCurrentInfo(availableColumns: availableColumns)
    }

    func persistCurrentInfo(availableColumns: [FileManagerColumn]) {
        guard !isApplyingPreferences,
              !FileManagerViewPreferences.isListViewInfoPersistenceDisabled,
              let folderTypeID = currentFolderTypeID
        else {
            return
        }

        let existingInfo = FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID)
        let visibleTableColumns = tableView.tableColumns.map { tableColumn in
            FileManagerViewPreferences.ListViewColumnInfo(id: FileManagerColumnID(rawValue: tableColumn.identifier.rawValue),
                                                          isVisible: true,
                                                          width: tableColumn.width)
        }
        let columnInfos = FileManagerViewPreferences.listViewColumnInfosPreservingHiddenColumns(
            availableColumns: availableColumns,
            visibleColumns: visibleTableColumns,
            previousInfo: existingInfo,
        )
        let sortDescriptor = tableView.sortDescriptors.first
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: sortDescriptor?.key ?? FileManagerColumnID.name.rawValue,
            ascending: sortDescriptor?.ascending ?? true,
            columns: columnInfos,
        )

        guard FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID) != info else { return }
        FileManagerViewPreferences.setListViewInfo(info, forFolderTypeID: folderTypeID)
    }

    func reset(columns: [FileManagerColumn],
               folderTypeID: String)
    {
        configure(columns: columns,
                  folderTypeID: folderTypeID,
                  preferSavedState: false)
    }

    func updateHighlightedColumn(for sortKey: String?) {
        guard let sortKey,
              let columnID = FileManagerViewPreferences.highlightedColumnID(for: sortKey,
                                                                            columns: currentColumns)
        else {
            tableView.highlightedTableColumn = nil
            return
        }

        tableView.highlightedTableColumn = tableView.tableColumns.first { $0.identifier.rawValue == columnID.rawValue }
    }

    func applySortDescriptor(columnIdentifier: String,
                             key: String,
                             ascending: Bool,
                             selector: Selector?,
                             availableColumns: [FileManagerColumn])
    {
        let descriptor = NSSortDescriptor(key: key,
                                          ascending: ascending,
                                          selector: selector)
        tableView.sortDescriptors = [descriptor]
        tableView.highlightedTableColumn = tableView.tableColumns.first { $0.identifier.rawValue == columnIdentifier }
        persistCurrentInfo(availableColumns: availableColumns)
    }

    func populateColumnHeaderMenu(_ menu: NSMenu,
                                  availableColumns: [FileManagerColumn],
                                  target: AnyObject,
                                  action: Selector)
    {
        menu.removeAllItems()

        let visibleIDs = Set(tableView.tableColumns.map { FileManagerColumnID(rawValue: $0.identifier.rawValue) })
        for column in availableColumns {
            let item = NSMenuItem(title: column.title,
                                  action: action,
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = column.id.rawValue
            item.state = visibleIDs.contains(column.id) ? .on : .off
            item.isEnabled = column.id != .name
            menu.addItem(item)
        }
    }

    @discardableResult
    func toggleColumnVisibility(_ columnID: FileManagerColumnID,
                                availableColumns: [FileManagerColumn],
                                folderTypeID: String) -> Bool
    {
        guard columnID != .name,
              let column = availableColumns.first(where: { $0.id == columnID })
        else {
            return false
        }

        let isHidingColumn = tableView.tableColumns.contains { $0.identifier.rawValue == column.id.rawValue }
        if isHidingColumn {
            persistCurrentInfo(availableColumns: availableColumns)
        }

        applyPreferences {
            if let tableColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == column.id.rawValue }) {
                tableView.removeTableColumn(tableColumn)
            } else {
                let tableColumn = column.makeTableColumn()
                tableColumn.width = FileManagerViewPreferences.storedListViewColumnWidth(for: column,
                                                                                         folderTypeID: folderTypeID)
                tableView.addTableColumn(tableColumn)
                restoreColumnPosition(columnID,
                                      folderTypeID: folderTypeID,
                                      availableColumns: availableColumns)
            }

            currentColumns = FileManagerColumn.visibleColumns(inTableOrder: tableView.tableColumns,
                                                              availableColumns: availableColumns)
            let visibleIDs = Set(currentColumns.map(\.id))
            tableView.sortDescriptors = FileManagerViewPreferences.sortDescriptorsByResettingUnavailableColumn(tableView.sortDescriptors,
                                                                                                               visibleColumnIDs: visibleIDs,
                                                                                                               availableColumns: availableColumns)
        }

        updateHighlightedColumn(for: tableView.sortDescriptors.first?.key)
        persistCurrentInfo(availableColumns: availableColumns)
        return true
    }

    private func applyPreferences(_ updates: () -> Void) {
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }
        updates()
    }

    private func refreshExistingTableColumns(using resolvedColumnsByID: [FileManagerColumnID: FileManagerColumn]) {
        for tableColumn in tableView.tableColumns {
            let id = FileManagerColumnID(rawValue: tableColumn.identifier.rawValue)
            guard let column = resolvedColumnsByID[id]
            else {
                continue
            }
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = column.sortDescriptorPrototype
        }
    }

    private func restoreColumnPosition(_ columnID: FileManagerColumnID,
                                       folderTypeID: String,
                                       availableColumns: [FileManagerColumn])
    {
        let currentColumnIDs = tableView.tableColumns.map { FileManagerColumnID(rawValue: $0.identifier.rawValue) }
        guard let move = FileManagerViewPreferences.restoredListViewColumnMove(for: columnID,
                                                                               currentColumnIDs: currentColumnIDs,
                                                                               folderTypeID: folderTypeID,
                                                                               availableColumns: availableColumns)
        else {
            return
        }

        tableView.moveColumn(move.from, toColumn: move.to)
    }
}
