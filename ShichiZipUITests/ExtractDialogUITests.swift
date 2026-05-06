import XCTest

/// Tests for the extract dialog workflow — the flow that previously caused a crash.
final class ExtractDialogUITests: ShichiZipUITestCase {
    func testOpenArchiveAndNavigate() throws {
        let (archiveURL, _) = try makeTestArchive(named: "navigate",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

        // Navigate to the directory containing the archive
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)

        // Wait for the table to show the archive file
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5),
                      "Archive file should appear in file list")

        // Double-click to open the archive (inline navigation)
        archiveCell.doubleClick()

        // After opening, the path field should reflect the archive path
        let pathField = leftPanePathField
        let predicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pathField)
        wait(for: [expectation], timeout: 10)
    }

    func testExtractDialogAppears() throws {
        let (archiveURL, _) = try makeTestArchive(named: "dialog",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

        // Navigate to the directory and open the archive
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        // Wait for archive to open (path field updates)
        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Trigger Extract via menu
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

        // The extract dialog should appear with our accessibility-tagged controls
        let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5),
                      "Extract dialog destination field should appear")

        let pathModePopup = app.popUpButtons.matching(identifier: "extract.pathMode").firstMatch
        XCTAssertTrue(pathModePopup.exists, "Path mode popup should exist in extract dialog")

        let overwritePopup = app.popUpButtons.matching(identifier: "extract.overwriteMode").firstMatch
        XCTAssertTrue(overwritePopup.exists, "Overwrite mode popup should exist in extract dialog")

        // Cancel the dialog
        let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
        XCTAssertTrue(cancelButton.exists, "Cancel button should exist")
        cancelButton.click()
    }

    func testExtractDialogCancelDoesNotCrash() throws {
        let (archiveURL, _) = try makeTestArchive(named: "cancel",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Open and cancel extract dialog multiple times to check stability
        for _ in 0 ..< 3 {
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

            let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
            XCTAssertTrue(destinationField.waitForExistence(timeout: 5))

            let cancelButton = app.buttons.matching(identifier: "modal.button.0").firstMatch
            cancelButton.click()

            // Small delay to ensure the dialog fully dismisses
            usleep(300_000)
        }

        // App should still be running
        XCTAssertTrue(app.state == .runningForeground, "App should still be running after cancelling extract 3 times")
    }

    func testExtractPerformsExtraction() throws {
        let (archiveURL, _) = try makeTestArchive(named: "extract",
                                                  payloads: ["payload.txt": "This is test content for extraction."])

        // Navigate to archive directory and open it
        navigateLeftPane(to: archiveURL.deletingLastPathComponent().path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        // Open extract dialog
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

        let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))

        // Read the prefilled destination path — it should be the archive's containing directory
        let prefilledPath = destinationField.value as? String ?? ""
        XCTAssertFalse(prefilledPath.isEmpty, "Destination field should have a prefilled path")

        // Uncheck "separate folder" to extract directly into the prefilled destination
        let splitCheckbox = app.checkBoxes.matching(identifier: "extract.splitDestination").firstMatch
        if splitCheckbox.exists, splitCheckbox.value as? Int == 1 {
            splitCheckbox.click()
        }

        // Click Extract button
        let extractButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(extractButton.exists, "Extract button should exist")
        extractButton.click()

        // Wait for extraction to complete — poll for output files
        let extractDir = URL(fileURLWithPath: prefilledPath)
        let deadline = Date().addingTimeInterval(15)
        var extractedFiles: [String] = []
        while Date() < deadline {
            extractedFiles = (try? FileManager.default.contentsOfDirectory(atPath: extractDir.path)) ?? []
            // Filter out the archive itself if it's in the same directory
            extractedFiles = extractedFiles.filter { $0 != archiveURL.lastPathComponent }
            if !extractedFiles.isEmpty { break }
            usleep(500_000)
        }

        XCTAssertFalse(extractedFiles.isEmpty,
                       "Extracted output directory should contain files. Got: \(extractedFiles)")
    }

    func testPasswordPromptAcceptsCommandSelectAllAndPaste() throws {
        let password = "shichizip-password"
        let payloadName = "secret.txt"
        let payloadContent = "encrypted payload"
        let (archiveURL, directoryURL) = try makeTestArchive(named: "password-shortcuts",
                                                             payloads: [payloadName: payloadContent],
                                                             password: password)

        navigateLeftPane(to: directoryURL.path)
        let table = leftPaneTable
        XCTAssertTrue(table.waitForExistence(timeout: 10))

        let archiveCell = table.cells.staticTexts[archiveURL.lastPathComponent]
        XCTAssertTrue(archiveCell.waitForExistence(timeout: 5))
        archiveCell.doubleClick()

        let pathField = leftPanePathField
        let openPredicate = NSPredicate(format: "value CONTAINS %@", archiveURL.lastPathComponent)
        let openExpectation = XCTNSPredicateExpectation(predicate: openPredicate, object: pathField)
        wait(for: [openExpectation], timeout: 10)

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuBarItems["File"].menus.menuItems["Extract…"].click()

        let destinationField = app.comboBoxes.matching(identifier: "extract.destinationPath").firstMatch
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))
        let destinationPath = destinationField.value as? String ?? ""
        XCTAssertFalse(destinationPath.isEmpty)

        let splitCheckbox = app.checkBoxes.matching(identifier: "extract.splitDestination").firstMatch
        if splitCheckbox.exists, splitCheckbox.value as? Int == 1 {
            splitCheckbox.click()
        }

        let extractButton = app.buttons.matching(identifier: "modal.button.1").firstMatch
        XCTAssertTrue(extractButton.exists)
        extractButton.click()

        let passwordField = waitForPasswordPromptField()
        XCTAssertTrue(passwordField.exists,
                      "Password prompt should appear for encrypted archive extraction")
        passwordField.click()
        passwordField.typeText("wrong-password")
        passwordField.selectAll()
        passwordField.pasteText(password)

        app.buttons.matching(identifier: "modal.button.1").firstMatch.click()

        let extractedURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(payloadName)
        XCTAssertTrue(waitForFile(at: extractedURL),
                      "Extraction should succeed when the pasted password replaces the selected wrong password")
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), payloadContent)
    }

    private func waitForPasswordPromptField(timeout: TimeInterval = 10) -> XCUIElement {
        let secureField = app.secureTextFields.matching(identifier: "passwordPrompt.password").firstMatch
        let plainField = app.textFields.matching(identifier: "passwordPrompt.passwordPlain").firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if secureField.exists {
                return secureField
            }
            if plainField.exists {
                return plainField
            }
            usleep(100_000)
        }

        return secureField
    }
}
