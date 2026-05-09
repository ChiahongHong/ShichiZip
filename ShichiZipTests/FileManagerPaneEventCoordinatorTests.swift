import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneEventCoordinatorTests: XCTestCase {
    func testColumnLayoutNotificationsUseObservedTableViewOnly() {
        let notificationCenter = NotificationCenter()
        let tableView = NSTableView()
        let otherTableView = NSTableView()
        let scrollView = NSScrollView()
        var columnLayoutChangeCount = 0
        let coordinator = makeCoordinator(tableView: tableView,
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter,
                                          columnLayoutDidChange: { columnLayoutChangeCount += 1 })

        notificationCenter.post(name: NSTableView.columnDidMoveNotification,
                                object: tableView)
        notificationCenter.post(name: NSTableView.columnDidResizeNotification,
                                object: otherTableView)
        notificationCenter.post(name: NSTableView.columnDidResizeNotification,
                                object: tableView)

        XCTAssertEqual(columnLayoutChangeCount, 2)

        coordinator.tearDown()
        notificationCenter.post(name: NSTableView.columnDidMoveNotification,
                                object: tableView)

        XCTAssertEqual(columnLayoutChangeCount, 2)
    }

    func testAutoRefreshDefersWhileScrollViewIsLiveScrolling() {
        let notificationCenter = NotificationCenter()
        let tableView = NSTableView()
        let scrollView = NSScrollView()
        var refreshCount = 0
        let coordinator = makeCoordinator(tableView: tableView,
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter,
                                          autoRefreshCurrentDirectoryIfNeeded: { refreshCount += 1 })

        coordinator.autoRefreshWhenPossible()
        XCTAssertEqual(refreshCount, 1)

        notificationCenter.post(name: NSScrollView.willStartLiveScrollNotification,
                                object: scrollView)
        coordinator.autoRefreshWhenPossible()
        XCTAssertEqual(refreshCount, 1)

        notificationCenter.post(name: NSScrollView.didEndLiveScrollNotification,
                                object: scrollView)
        XCTAssertEqual(refreshCount, 2)

        notificationCenter.post(name: NSScrollView.didEndLiveScrollNotification,
                                object: scrollView)
        XCTAssertEqual(refreshCount, 2)
    }

    func testModelNotificationsDispatchTypedCallbacks() {
        let notificationCenter = NotificationCenter()
        let tableView = NSTableView()
        let scrollView = NSScrollView()
        let archiveChange = FileManagerArchiveChange(archiveURL: URL(fileURLWithPath: "/tmp/payload.7z"),
                                                     targetSubdir: "nested",
                                                     selectingPaths: ["nested/file.txt"])
        var settingsKeys: [SZSettingsKey] = []
        var resetListViewPreferencesCount = 0
        var reloadPresentedValuesCount = 0
        var archiveChanges: [FileManagerArchiveChange] = []
        var languageChangeCount = 0
        let coordinator = makeCoordinator(tableView: tableView,
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter,
                                          settingsDidChange: { settingsKeys.append($0) },
                                          resetListViewPreferences: { resetListViewPreferencesCount += 1 },
                                          reloadPresentedValues: { reloadPresentedValuesCount += 1 },
                                          archiveDidChange: { archiveChanges.append($0) },
                                          languageDidChange: { languageChangeCount += 1 })

        notificationCenter.post(name: .szSettingsDidChange,
                                object: nil,
                                userInfo: ["key": SZSettingsKey.showGridLines.rawValue])
        notificationCenter.post(name: .szSettingsDidChange,
                                object: nil,
                                userInfo: ["key": "missing-setting"])
        notificationCenter.post(name: .fileManagerViewPreferencesDidChange,
                                object: nil,
                                userInfo: [FileManagerViewPreferences.listViewPreferencesResetUserInfoKey: true])
        notificationCenter.post(name: .fileManagerViewPreferencesDidChange,
                                object: nil)
        notificationCenter.post(name: .fileManagerArchiveDidChange,
                                object: nil,
                                userInfo: archiveChange.notificationUserInfo)
        notificationCenter.post(name: .fileManagerArchiveDidChange,
                                object: nil)
        notificationCenter.post(name: .szLanguageDidChange,
                                object: nil)

        XCTAssertEqual(settingsKeys, [.showGridLines])
        XCTAssertEqual(resetListViewPreferencesCount, 1)
        XCTAssertEqual(reloadPresentedValuesCount, 1)
        XCTAssertEqual(archiveChanges, [archiveChange])
        XCTAssertEqual(languageChangeCount, 1)
        coordinator.tearDown()
    }

    private func makeCoordinator(tableView: NSTableView,
                                 scrollView: NSScrollView,
                                 notificationCenter: NotificationCenter,
                                 columnLayoutDidChange: @escaping () -> Void = {},
                                 settingsDidChange: @escaping (SZSettingsKey) -> Void = { _ in },
                                 resetListViewPreferences: @escaping () -> Void = {},
                                 reloadPresentedValues: @escaping () -> Void = {},
                                 archiveDidChange: @escaping (FileManagerArchiveChange) -> Void = { _ in },
                                 languageDidChange: @escaping () -> Void = {},
                                 autoRefreshCurrentDirectoryIfNeeded: @escaping () -> Void = {}) -> FileManagerPaneEventCoordinator
    {
        FileManagerPaneEventCoordinator(tableView: tableView,
                                        scrollView: scrollView,
                                        notificationCenter: notificationCenter,
                                        notificationQueue: nil,
                                        columnLayoutDidChange: columnLayoutDidChange,
                                        settingsDidChange: settingsDidChange,
                                        resetListViewPreferences: resetListViewPreferences,
                                        reloadPresentedValues: reloadPresentedValues,
                                        archiveDidChange: archiveDidChange,
                                        languageDidChange: languageDidChange,
                                        autoRefreshCurrentDirectoryIfNeeded: autoRefreshCurrentDirectoryIfNeeded)
    }
}
