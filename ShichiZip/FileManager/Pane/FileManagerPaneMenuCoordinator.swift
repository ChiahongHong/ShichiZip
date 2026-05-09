import Cocoa

@MainActor
final class FileManagerPaneMenuCoordinator {
    private let tableView: NSTableView
    private let activatePane: () -> Void
    private let populateColumnHeaderMenu: (NSMenu) -> Void
    private var columnHeaderMenu: NSMenu?

    init(tableView: NSTableView,
         activatePane: @escaping () -> Void,
         populateColumnHeaderMenu: @escaping (NSMenu) -> Void)
    {
        self.tableView = tableView
        self.activatePane = activatePane
        self.populateColumnHeaderMenu = populateColumnHeaderMenu
    }

    func makeColumnHeaderMenu(delegate: any NSMenuDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = delegate
        columnHeaderMenu = menu
        return menu
    }

    func makeContextMenu(windowTarget: AnyObject?,
                         delegate: any NSMenuDelegate) -> NSMenu
    {
        let menu = FileManagerMenuFactory.makeContextMenu(windowTarget: windowTarget)
        menu.delegate = delegate
        return menu
    }

    func prepareContextMenu(forClickedRow clickedRow: Int,
                            presentationWindow: NSWindow?)
    {
        activatePane()
        selectClickedRowIfNeeded(clickedRow)
        presentationWindow?.makeFirstResponder(tableView)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let columnHeaderMenu, menu === columnHeaderMenu {
            activatePane()
            populateColumnHeaderMenu(menu)
            return
        }

        activatePane()
        selectClickedRowIfNeeded(tableView.clickedRow)
    }

    private func selectClickedRowIfNeeded(_ clickedRow: Int) {
        if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
    }
}
