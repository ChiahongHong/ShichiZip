import XCTest

/// UI coverage for filesystem copy/move destination dialogs.
final class FileManagerTransferUITests: ShichiZipUITestCase {
    func testCopyToAndMoveToDialogsTransferFileSystemItems() throws {
        let tempDir = try makeTemporaryDirectory(named: "copy-move-dialog")
        let sourceDir = tempDir.appendingPathComponent("source", isDirectory: true)
        let copyDestinationDir = tempDir.appendingPathComponent("copy-destination", isDirectory: true)
        let moveDestinationDir = tempDir.appendingPathComponent("move-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copyDestinationDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moveDestinationDir, withIntermediateDirectories: true)

        let copySourceURL = sourceDir.appendingPathComponent("copy-source.txt")
        let moveSourceURL = sourceDir.appendingPathComponent("move-source.txt")
        try createTextFile(at: copySourceURL, content: "copied by paste")
        try createTextFile(at: moveSourceURL, content: "moved by dialog")

        navigateLeftPane(to: sourceDir.path)
        XCTAssertTrue(leftPaneTable.waitForExistence(timeout: 10))

        let copyCell = leftTable.cells.staticTexts[copySourceURL.lastPathComponent]
        XCTAssertTrue(copyCell.waitForExistence(timeout: 5),
                      "Copy source should be visible before opening Copy To")
        copyCell.click()
        runFileOperationDialog(menuItemTitle: "Copy To...", destinationPath: copyDestinationDir.path)

        let copiedURL = copyDestinationDir.appendingPathComponent(copySourceURL.lastPathComponent)
        XCTAssertTrue(waitForFile(at: copiedURL),
                      "Copy To should copy the selected file into the chosen destination")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copySourceURL.path),
                      "Copy To should keep the source file")
        XCTAssertEqual(try String(contentsOf: copiedURL, encoding: .utf8), "copied by paste")

        let moveCell = leftTable.cells.staticTexts[moveSourceURL.lastPathComponent]
        XCTAssertTrue(moveCell.waitForExistence(timeout: 5),
                      "Move source should be visible before opening Move To")
        moveCell.click()
        runFileOperationDialog(menuItemTitle: "Move To...", destinationPath: moveDestinationDir.path)

        let movedURL = moveDestinationDir.appendingPathComponent(moveSourceURL.lastPathComponent)
        XCTAssertTrue(waitForFile(at: movedURL),
                      "Move To should move the selected file into the chosen destination")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveSourceURL.path),
                       "Move To should remove the source file")
        XCTAssertEqual(try String(contentsOf: movedURL, encoding: .utf8), "moved by dialog")
    }

    private var leftTable: XCUIElement {
        leftPaneTable
    }

    private func runFileOperationDialog(menuItemTitle: String, destinationPath: String) {
        app.menuBars.menuBarItems["File"].click()
        let menuItem = app.menuBars.menuBarItems["File"].menus.menuItems[menuItemTitle]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5),
                      "\(menuItemTitle) menu item should be available")
        menuItem.click()

        let destinationField = app.comboBoxes.matching(identifier: "fileOperation.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5),
                      "File operation destination field should appear")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5),
                      "File operation destination dialog should be presented as a sheet")
        destinationField.click()
        destinationField.selectAll()
        destinationField.pasteText(destinationPath)

        let actionButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(actionButton.waitForExistence(timeout: 5),
                      "File operation confirmation button should appear")
        actionButton.click()
    }
}
