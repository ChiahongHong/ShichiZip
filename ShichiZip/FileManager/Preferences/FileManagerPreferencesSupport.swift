import AppKit
import os

extension Notification.Name {
    static let fileManagerViewPreferencesDidChange = Notification.Name("FileManagerViewPreferencesDidChange")
}

enum FileManagerPreferenceStore {
    private static var defaults: UserDefaults {
        .standard
    }

    static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    static func integer(forKey key: String, defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.integer(forKey: key)
    }

    static func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    static func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    static func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    static func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

enum FileManagerPanePreferences {
    private static let dualPaneKey = "FileManager.IsDualPane"

    static var showsDualPane: Bool {
        FileManagerPreferenceStore.bool(forKey: dualPaneKey, defaultValue: false)
    }

    static func setShowsDualPane(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: dualPaneKey)
    }
}

enum FileManagerToolbarPreferences {
    enum Style: String {
        case expanded
        case unified

        var toolbarStyle: NSWindow.ToolbarStyle {
            switch self {
            case .expanded:
                .expanded
            case .unified:
                .unified
            }
        }
    }

    private static let archiveToolbarKey = "FileManager.ShowArchiveToolbar"
    private static let standardToolbarKey = "FileManager.ShowStandardToolbar"
    private static let showTextKey = "FileManager.ToolbarShowButtonText"
    private static let styleKey = "FileManager.ToolbarStyle"

    static var showsArchiveToolbar: Bool {
        FileManagerPreferenceStore.bool(forKey: archiveToolbarKey, defaultValue: true)
    }

    static var showsStandardToolbar: Bool {
        FileManagerPreferenceStore.bool(forKey: standardToolbarKey, defaultValue: true)
    }

    static var showsButtonText: Bool {
        FileManagerPreferenceStore.bool(forKey: showTextKey, defaultValue: true)
    }

    static var style: Style {
        guard let rawValue = FileManagerPreferenceStore.string(forKey: styleKey),
              let style = Style(rawValue: rawValue)
        else {
            return .expanded
        }
        return style
    }

    static func setShowsArchiveToolbar(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: archiveToolbarKey)
    }

    static func setShowsStandardToolbar(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: standardToolbarKey)
    }

    static func setShowsButtonText(_ value: Bool) {
        FileManagerPreferenceStore.set(value, forKey: showTextKey)
    }

    static func setStyle(_ style: Style) {
        FileManagerPreferenceStore.set(style.rawValue, forKey: styleKey)
    }
}

enum FileManagerViewPreferences {
    private static let fixedFormatFormatterCache = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())
    private static let styleFormatterCache = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    enum TimestampDisplayLevel: Int, CaseIterable {
        case day
        case minute
        case second
        case ntfs
        case nanoseconds

        fileprivate var dateFormat: String {
            switch self {
            case .day:
                "yyyy-MM-dd"
            case .minute:
                "yyyy-MM-dd HH:mm"
            case .second:
                "yyyy-MM-dd HH:mm:ss"
            case .ntfs:
                "yyyy-MM-dd HH:mm:ss.SSSSSSS"
            case .nanoseconds:
                "yyyy-MM-dd HH:mm:ss.SSSSSSSSS"
            }
        }
    }

    private static let timestampUTCKey = "FileManager.TimestampUTC"
    private static let timestampLevelKey = "FileManager.TimestampLevel"
    private static let autoRefreshKey = "FileManager.AutoRefresh"

    static var usesUTCTimestamps: Bool {
        FileManagerPreferenceStore.bool(forKey: timestampUTCKey, defaultValue: false)
    }

    static var timestampDisplayLevel: TimestampDisplayLevel {
        TimestampDisplayLevel(rawValue: FileManagerPreferenceStore.integer(forKey: timestampLevelKey,
                                                                           defaultValue: TimestampDisplayLevel.minute.rawValue)) ?? .minute
    }

    static var autoRefreshEnabled: Bool {
        FileManagerPreferenceStore.bool(forKey: autoRefreshKey, defaultValue: false)
    }

    static func setUsesUTCTimestamps(_ value: Bool) {
        set(value, forKey: timestampUTCKey)
    }

    static func setTimestampDisplayLevel(_ value: TimestampDisplayLevel) {
        set(value.rawValue, forKey: timestampLevelKey)
    }

    static func setAutoRefreshEnabled(_ value: Bool) {
        set(value, forKey: autoRefreshKey)
    }

    static func timeMenuPreviewTitle(for level: TimestampDisplayLevel, referenceDate: Date = Date()) -> String {
        makeFixedFormatFormatter(format: level.dateFormat).string(from: referenceDate)
    }

    static func makeListDateFormatter() -> DateFormatter {
        makeFixedFormatFormatter(format: timestampDisplayLevel.dateFormat)
    }

    static func makeDateFormatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style) -> DateFormatter
    {
        let usesUTC = usesUTCTimestamps
        let cacheKey = "\(dateStyle.rawValue)|\(timeStyle.rawValue)|\(usesUTC ? 1 : 0)"
        return cachedFormatter(forKey: cacheKey, in: styleFormatterCache) {
            let formatter = DateFormatter()
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    private static func set(_ value: Bool, forKey key: String) {
        FileManagerPreferenceStore.set(value, forKey: key)
        resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func set(_ value: Int, forKey key: String) {
        FileManagerPreferenceStore.set(value, forKey: key)
        resetFormatterCaches()
        NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange, object: nil)
    }

    private static func makeFixedFormatFormatter(format: String) -> DateFormatter {
        let usesUTC = usesUTCTimestamps
        let cacheKey = "\(format)|\(usesUTC ? 1 : 0)"
        return cachedFormatter(forKey: cacheKey, in: fixedFormatFormatterCache) {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.timeZone = usesUTC ? TimeZone(secondsFromGMT: 0) : .current
            return formatter
        }
    }

    private static func resetFormatterCaches() {
        fixedFormatFormatterCache.withLock { $0.removeAll() }
        styleFormatterCache.withLock { $0.removeAll() }
    }

    private static func cachedFormatter(forKey key: String,
                                        in cache: OSAllocatedUnfairLock<[String: DateFormatter]>,
                                        builder: @Sendable () -> DateFormatter) -> DateFormatter
    {
        // DateFormatter is mutable and not thread-safe, so the cache stores
        // prototypes and each caller gets an independent copy.
        cache.withLock { store in
            let formatter: DateFormatter
            if let cached = store[key] {
                formatter = cached
            } else {
                let created = builder()
                store[key] = created
                formatter = created
            }
            return formatter.copy() as! DateFormatter
        }
    }
}
