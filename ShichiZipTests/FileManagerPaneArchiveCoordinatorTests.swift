import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneArchiveCoordinatorTests: XCTestCase {
    func testPublishMutationUsesCurrentTopLevelArchiveAndNormalizesPaths() throws {
        let archiveURL = try makeArchiveURL(named: "publish-normalized-mutation")
        let session = makeArchiveSession(archiveURL: archiveURL)
        let observer = NSObject()
        let coordinator = makeCoordinator(session: session,
                                          observerIdentifier: ObjectIdentifier(observer))
        let publishedChange = UncheckedSendableBox<FileManagerArchiveChange>()
        let published = expectation(description: "archive mutation published")

        let token = NotificationCenter.default.addObserver(forName: .fileManagerArchiveDidChange,
                                                           object: nil,
                                                           queue: nil)
        { notification in
            publishedChange.value = FileManagerArchiveChange(notification: notification)
            published.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.publishMutationIfNeeded(targetSubdir: "/folder/",
                                            selectingPaths: ["/folder/file.txt/"])

        wait(for: [published], timeout: 1)
        XCTAssertEqual(publishedChange.value,
                       FileManagerArchiveChange(archiveURL: archiveURL,
                                                targetSubdir: "folder",
                                                selectingPaths: ["folder/file.txt"],
                                                sourceIdentifier: ObjectIdentifier(observer)))
    }

    func testPublishMutationSkipsTemporaryArchiveCopies() throws {
        let archiveURL = try makeArchiveURL(named: "skip-temporary-copy-mutation")
        let session = try makeArchiveSession(archiveURL: archiveURL,
                                             temporaryDirectory: makeTemporaryDirectory(named: "temporary-copy"))
        let coordinator = makeCoordinator(session: session)
        let unexpectedPublish = expectation(description: "temporary archive mutation should not publish")
        unexpectedPublish.isInverted = true

        let token = NotificationCenter.default.addObserver(forName: .fileManagerArchiveDidChange,
                                                           object: nil,
                                                           queue: nil)
        { notification in
            guard FileManagerArchiveChange(notification: notification)?.archiveURL == archiveURL.standardizedFileURL else { return }
            unexpectedPublish.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.publishMutationIfNeeded(targetSubdir: "folder",
                                            selectingPaths: ["folder/file.txt"])

        wait(for: [unexpectedPublish], timeout: 0.1)
    }

    func testCloseAllArchivesClearsSessionAndRunsRefreshCallbacks() throws {
        let session = FileManagerArchiveSession()
        try session.appendPreparedArchive(makePreparedArchive(named: "close-all"))
        var didUpdateTableColumns = false
        let coordinator = makeCoordinator(session: session,
                                          updateTableColumns: { didUpdateTableColumns = true })

        XCTAssertTrue(coordinator.closeAll(showError: true))

        XCTAssertFalse(session.isInsideArchive)
        XCTAssertTrue(session.displayItems.isEmpty)
        XCTAssertTrue(didUpdateTableColumns)
    }

    func testFinishArchiveOpenCommitsPreparedArchiveAndPresentsSubdir() throws {
        let session = FileManagerArchiveSession()
        let prepared = try makePreparedArchive(named: "finish-open-commit",
                                               entries: [
                                                   makeArchiveItem(path: "folder/", isDirectory: true),
                                                   makeArchiveItem(path: "folder/payload.txt"),
                                               ])
        var currentDirectory = FileManager.default.homeDirectoryForCurrentUser
        var preparedDirectory: URL?
        var didUpdateTableColumns = false
        var didReloadTableData = false
        let coordinator = makeCoordinator(session: session,
                                          currentDirectory: { currentDirectory },
                                          prepareDirectoryForArchivePresentation: { hostDirectory in
                                              preparedDirectory = hostDirectory
                                              currentDirectory = hostDirectory
                                          },
                                          updateTableColumns: { didUpdateTableColumns = true },
                                          reloadTableData: { didReloadTableData = true })
        defer { _ = coordinator.closeAll(showError: false) }

        let result = coordinator.finishArchiveOpen(.opened(prepared),
                                                   temporaryDirectory: nil,
                                                   preserveTemporaryDirectoryOnUnsupported: false,
                                                   replaceCurrentState: false,
                                                   showError: true)

        guard case .opened = result else {
            XCTFail("Expected archive open to commit")
            return
        }

        XCTAssertEqual(session.currentLevel?.archivePath, prepared.archivePath)
        XCTAssertEqual(session.displayItems.map(\.path), ["folder/"])
        XCTAssertEqual(currentDirectory, prepared.hostDirectory)
        XCTAssertEqual(preparedDirectory, prepared.hostDirectory)
        XCTAssertTrue(didUpdateTableColumns)
        XCTAssertTrue(didReloadTableData)
    }

    func testCloseNestedArchiveRestoresParentSubdirWhenViewIsLoaded() throws {
        let session = FileManagerArchiveSession()
        let parent = try makePreparedArchive(named: "parent",
                                             entries: [
                                                 makeArchiveItem(path: "folder/", isDirectory: true),
                                                 makeArchiveItem(path: "folder/payload.txt"),
                                             ])
        session.appendPreparedArchive(parent)
        XCTAssertTrue(session.navigateSubdir("folder"))
        try session.appendPreparedArchive(makePreparedArchive(named: "nested"))
        let nestedLevel = try XCTUnwrap(session.currentLevel)
        var didPresentParentSubdir = false
        let coordinator = makeCoordinator(session: session,
                                          isViewLoaded: { true },
                                          reloadTableData: { didPresentParentSubdir = true })
        defer { _ = coordinator.closeAll(showError: false) }

        XCTAssertTrue(coordinator.closeLevel(nestedLevel,
                                             showError: true))

        XCTAssertEqual(session.currentLevel?.archivePath, parent.archivePath)
        XCTAssertEqual(session.currentLevel?.currentSubdir, "folder")
        XCTAssertEqual(session.displayItems.map(\.path), ["folder/payload.txt"])
        XCTAssertTrue(didPresentParentSubdir)
    }

    private func makeCoordinator(session: FileManagerArchiveSession,
                                 observerIdentifier: ObjectIdentifier = ObjectIdentifier(NSObject()),
                                 isViewLoaded: @escaping () -> Bool = { false },
                                 currentDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
                                 prepareDirectoryForArchivePresentation: @escaping (URL) -> Void = { _ in },
                                 updateTableColumns: @escaping () -> Void = {},
                                 reloadTableData: @escaping () -> Void = {},
                                 selectArchivePaths: @escaping ([String]) -> Void = { _ in }) -> FileManagerPaneArchiveCoordinator
    {
        FileManagerPaneArchiveCoordinator(archiveSession: session,
                                          observerIdentifier: observerIdentifier,
                                          parentWindow: { nil },
                                          isViewLoaded: isViewLoaded,
                                          updateTableColumns: updateTableColumns,
                                          currentDirectory: currentDirectory,
                                          prepareDirectoryForArchivePresentation: prepareDirectoryForArchivePresentation,
                                          reloadTableData: reloadTableData,
                                          selectArchivePaths: selectArchivePaths,
                                          showError: { error in
                                              XCTFail("Unexpected archive coordinator error: \(error)")
                                          })
    }

    private func makeArchiveURL(named name: String) throws -> URL {
        try makeTemporaryDirectory(named: name,
                                   prefix: "ShichiZipArchiveCoordinatorTests")
            .appendingPathComponent("source.7z")
    }

    private func makeArchiveSession(archiveURL: URL,
                                    temporaryDirectory: URL? = nil) -> FileManagerArchiveSession
    {
        let session = FileManagerArchiveSession()
        session.appendPreparedArchive(FileManagerPreparedArchiveOpen(hostDirectory: archiveURL.deletingLastPathComponent(),
                                                                     archivePath: archiveURL.path,
                                                                     displayPathPrefix: archiveURL.path,
                                                                     archive: SZArchive(),
                                                                     entries: [],
                                                                     temporaryDirectory: temporaryDirectory,
                                                                     nestedWriteBackInfo: nil))
        return session
    }

    private func makePreparedArchive(named name: String,
                                     entries: [ArchiveItem]? = nil) throws -> FileManagerPreparedArchiveOpen
    {
        let archiveURL = try makeArchive(named: name,
                                         prefix: "ShichiZipArchiveCoordinatorTests")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         session: SZOperationSession())
        let archiveEntries = try entries ?? FileManagerArchiveListing.items(from: archive,
                                                                            session: SZOperationSession())
        return FileManagerPreparedArchiveOpen(hostDirectory: archiveURL.deletingLastPathComponent(),
                                              archivePath: archiveURL.path,
                                              displayPathPrefix: archiveURL.path,
                                              archive: archive,
                                              entries: archiveEntries,
                                              temporaryDirectory: nil,
                                              nestedWriteBackInfo: nil)
    }

    private func makeArchiveItem(path: String,
                                 isDirectory: Bool = false) -> ArchiveItem
    {
        ArchiveItem(index: 0,
                    path: path,
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    size: 0,
                    packedSize: 0,
                    modifiedDate: nil,
                    createdDate: nil,
                    accessedDate: nil,
                    crc: 0,
                    isDirectory: isDirectory,
                    isEncrypted: false,
                    isAnti: false,
                    method: "",
                    attributes: 0,
                    position: 0,
                    block: 0,
                    comment: "")
    }
}
