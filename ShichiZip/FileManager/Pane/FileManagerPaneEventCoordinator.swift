import Cocoa

@MainActor
final class FileManagerPaneEventCoordinator {
    private let notificationCenter: NotificationCenter
    private let columnLayoutDidChange: () -> Void
    private let settingsDidChange: (SZSettingsKey) -> Void
    private let resetListViewPreferences: () -> Void
    private let reloadPresentedValues: () -> Void
    private let archiveDidChange: (FileManagerArchiveChange) -> Void
    private let languageDidChange: () -> Void
    private let autoRefreshCurrentDirectoryIfNeeded: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var pendingAutoRefresh = false

    init(tableView: NSTableView,
         scrollView: NSScrollView,
         notificationCenter: NotificationCenter = .default,
         notificationQueue: OperationQueue? = .main,
         columnLayoutDidChange: @escaping () -> Void,
         settingsDidChange: @escaping (SZSettingsKey) -> Void,
         resetListViewPreferences: @escaping () -> Void,
         reloadPresentedValues: @escaping () -> Void,
         archiveDidChange: @escaping (FileManagerArchiveChange) -> Void,
         languageDidChange: @escaping () -> Void,
         autoRefreshCurrentDirectoryIfNeeded: @escaping () -> Void)
    {
        self.notificationCenter = notificationCenter
        self.columnLayoutDidChange = columnLayoutDidChange
        self.settingsDidChange = settingsDidChange
        self.resetListViewPreferences = resetListViewPreferences
        self.reloadPresentedValues = reloadPresentedValues
        self.archiveDidChange = archiveDidChange
        self.languageDidChange = languageDidChange
        self.autoRefreshCurrentDirectoryIfNeeded = autoRefreshCurrentDirectoryIfNeeded

        observers = [
            notificationCenter.addObserver(forName: NSTableView.columnDidMoveNotification,
                                           object: tableView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.columnLayoutDidChange()
                }
            },
            notificationCenter.addObserver(forName: NSTableView.columnDidResizeNotification,
                                           object: tableView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.columnLayoutDidChange()
                }
            },
            notificationCenter.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                           object: scrollView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = true
                }
            },
            notificationCenter.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                           object: scrollView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = false

                    guard self.pendingAutoRefresh else { return }
                    self.pendingAutoRefresh = false
                    self.autoRefreshCurrentDirectoryIfNeeded()
                }
            },
            notificationCenter.addObserver(forName: .szSettingsDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] notification in
                let settingsKey = (notification.userInfo?["key"] as? String)
                    .flatMap(SZSettingsKey.init(rawValue:))
                MainActor.assumeIsolated {
                    guard let settingsKey else { return }
                    self?.settingsDidChange(settingsKey)
                }
            },
            notificationCenter.addObserver(forName: .fileManagerViewPreferencesDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] notification in
                let shouldResetListViewPreferences = notification.userInfo?[FileManagerViewPreferences.listViewPreferencesResetUserInfoKey] as? Bool == true
                MainActor.assumeIsolated {
                    if shouldResetListViewPreferences {
                        self?.resetListViewPreferences()
                    } else {
                        self?.reloadPresentedValues()
                    }
                }
            },
            notificationCenter.addObserver(forName: .fileManagerArchiveDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] notification in
                let change = FileManagerArchiveChange(notification: notification)
                MainActor.assumeIsolated {
                    guard let change else { return }
                    self?.archiveDidChange(change)
                }
            },
            notificationCenter.addObserver(forName: .szLanguageDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.languageDidChange()
                }
            },
        ]
    }

    isolated deinit {
        tearDown()
    }

    func tearDown() {
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        pendingAutoRefresh = false
        isLiveScrolling = false
    }

    func autoRefreshWhenPossible() {
        guard !isLiveScrolling else {
            pendingAutoRefresh = true
            return
        }

        pendingAutoRefresh = false
        autoRefreshCurrentDirectoryIfNeeded()
    }
}
