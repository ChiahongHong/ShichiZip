import Foundation

@MainActor
protocol FileManagerArchiveCoordinationProviding: AnyObject {
    func archiveCoordinationSnapshots() -> [FileManagerNestedArchiveOpenSnapshot]
}

@MainActor
protocol FileManagerWindowCoordinating: FileManagerArchiveCoordinationProviding {
    func openArchiveInNewFileManager(_ url: URL)
}
