import Foundation

extension Notification.Name {
    static let fileManagerArchiveDidChange = Notification.Name("FileManagerArchiveDidChange")
}

struct FileManagerCoordinatedArchiveLocation: Equatable {
    let archiveURL: URL
    let currentSubdir: String

    init(archiveURL: URL, currentSubdir: String) {
        self.archiveURL = archiveURL.standardizedFileURL
        self.currentSubdir = FileManagerArchiveChange.normalizeArchivePath(currentSubdir)
    }
}

struct FileManagerNestedArchiveIdentity: Hashable {
    let displayPath: String

    init(displayPath: String) {
        self.displayPath = NSString(string: displayPath).standardizingPath
    }
}

struct FileManagerNestedArchiveOpenSnapshot: Equatable {
    let archiveIdentifier: ObjectIdentifier
    let identity: FileManagerNestedArchiveIdentity?
    let isDirty: Bool
}

enum FileManagerNestedArchiveConflictDetector {
    static func hasConflictingOpenInstance(for identity: FileManagerNestedArchiveIdentity,
                                           in snapshots: [FileManagerNestedArchiveOpenSnapshot]) -> Bool
    {
        var matchingArchiveIdentifiers = Set<ObjectIdentifier>()

        for snapshot in snapshots where snapshot.identity == identity {
            matchingArchiveIdentifiers.insert(snapshot.archiveIdentifier)
            if matchingArchiveIdentifiers.count > 1 {
                return true
            }
        }

        return false
    }

    static func hasDirtyOpenInstance(for identity: FileManagerNestedArchiveIdentity,
                                     in snapshots: [FileManagerNestedArchiveOpenSnapshot]) -> Bool
    {
        for snapshot in snapshots where snapshot.identity == identity {
            if snapshot.isDirty {
                return true
            }
        }

        return false
    }
}

struct FileManagerArchiveChange: Equatable {
    let archiveURL: URL
    let targetSubdir: String
    let selectingPaths: [String]
    let sourceIdentifier: ObjectIdentifier?

    init(archiveURL: URL,
         targetSubdir: String = "",
         selectingPaths: [String] = [],
         sourceIdentifier: ObjectIdentifier? = nil)
    {
        self.archiveURL = archiveURL.standardizedFileURL
        self.targetSubdir = FileManagerArchiveChange.normalizeArchivePath(targetSubdir)
        self.selectingPaths = selectingPaths.map(FileManagerArchiveChange.normalizeArchivePath)
        self.sourceIdentifier = sourceIdentifier
    }

    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let archiveURL = userInfo[FileManagerArchiveChangeCoordinator.archiveURLUserInfoKey] as? URL
        else {
            return nil
        }

        self.init(archiveURL: archiveURL,
                  targetSubdir: userInfo[FileManagerArchiveChangeCoordinator.targetSubdirUserInfoKey] as? String ?? "",
                  selectingPaths: userInfo[FileManagerArchiveChangeCoordinator.selectingPathsUserInfoKey] as? [String] ?? [],
                  sourceIdentifier: userInfo[FileManagerArchiveChangeCoordinator.sourceIdentifierUserInfoKey] as? ObjectIdentifier)
    }

    var notificationUserInfo: [AnyHashable: Any] {
        [
            FileManagerArchiveChangeCoordinator.archiveURLUserInfoKey: archiveURL,
            FileManagerArchiveChangeCoordinator.targetSubdirUserInfoKey: targetSubdir,
            FileManagerArchiveChangeCoordinator.selectingPathsUserInfoKey: selectingPaths,
            FileManagerArchiveChangeCoordinator.sourceIdentifierUserInfoKey: sourceIdentifier as Any,
        ]
    }

    static func normalizeArchivePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum FileManagerArchiveChangeHandlingDecision: Equatable {
    case ignore
    case reload(selectingPaths: [String])
}

enum FileManagerArchiveChangeCoordinator {
    static let archiveURLUserInfoKey = "archiveURL"
    static let targetSubdirUserInfoKey = "targetSubdir"
    static let selectingPathsUserInfoKey = "selectingPaths"
    static let sourceIdentifierUserInfoKey = "sourceIdentifier"

    static func handlingDecision(for change: FileManagerArchiveChange,
                                 currentLocation: FileManagerCoordinatedArchiveLocation?,
                                 observerIdentifier: ObjectIdentifier) -> FileManagerArchiveChangeHandlingDecision
    {
        guard let currentLocation,
              currentLocation.archiveURL == change.archiveURL,
              change.sourceIdentifier != observerIdentifier
        else {
            return .ignore
        }

        let selectingPaths = currentLocation.currentSubdir == change.targetSubdir
            ? change.selectingPaths
            : []
        return .reload(selectingPaths: selectingPaths)
    }

    static func publish(_ change: FileManagerArchiveChange) {
        NotificationCenter.default.post(name: .fileManagerArchiveDidChange,
                                        object: nil,
                                        userInfo: change.notificationUserInfo)
    }
}
