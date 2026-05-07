import Cocoa
import os

/// SZOperationSession synchronizes its mutable state internally and routes UI callbacks to the main thread.
extension SZOperationSession: @unchecked Sendable {}

/// SZArchive access is coordinated by callers before being handed to background archive workers.
extension SZArchive: @unchecked Sendable {}

private struct ArchiveOperationStoredResult<Value>: @unchecked Sendable {
    let result: Result<Value, Error>
}

private final class ArchiveOperationResultBox<Value>: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: nil as ArchiveOperationStoredResult<Value>?)

    func store(_ result: Result<Value, Error>) {
        let storedResult = ArchiveOperationStoredResult(result: result)
        state.withLock { $0 = storedResult }
    }

    func load() -> ArchiveOperationStoredResult<Value>? {
        state.withLock { $0 }
    }

    @MainActor
    func waitPumpingMainRunLoop(interval: TimeInterval) -> Result<Value, Error> {
        while true {
            if let storedResult = load() {
                return storedResult.result
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
        }
    }
}

private struct ArchiveOperationWork<Value>: @unchecked Sendable {
    let body: (SZOperationSession) throws -> Value

    func callAsFunction(_ session: SZOperationSession) throws -> Value {
        try body(session)
    }
}

enum ArchiveOperationRunner {
    private static let synchronousRunLoopPollingInterval: TimeInterval = 0.05

    private static func performBackgroundWork<T>(session: SZOperationSession,
                                                 work: @escaping (SZOperationSession) throws -> T,
                                                 completion: @escaping @Sendable (Result<T, Error>) -> Void)
    {
        let operation = ArchiveOperationWork(body: work)
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Result { try operation(session) })
        }
    }

    /// Compatibility bridge for synchronous FileManager navigation and nested archive write-back.
    ///
    /// The main run loop is intentionally pumped while archive work runs on a background queue so
    /// progress, cancellation, password, and choice prompts can continue to be delivered. Prefer
    /// `run(...)` for new operations that do not need a synchronous result contract.
    @MainActor
    static func runSynchronously<T>(operationTitle: String,
                                    initialFileName: String? = nil,
                                    parentWindow: NSWindow? = nil,
                                    deferredDisplay: Bool = false,
                                    work: @escaping (SZOperationSession) throws -> T) throws -> T
    {
        let coordinator = ArchiveOperationCoordinator(operationTitle: operationTitle,
                                                      initialFileName: initialFileName,
                                                      parentWindow: parentWindow,
                                                      deferredDisplay: deferredDisplay)
        coordinator.start()
        defer { coordinator.finish() }

        let resultBox = ArchiveOperationResultBox<T>()
        let session = coordinator.session
        performBackgroundWork(session: session, work: work) { result in
            resultBox.store(result)
        }

        return try resultBox.waitPumpingMainRunLoop(interval: synchronousRunLoopPollingInterval).get()
    }

    @MainActor
    static func run<T>(operationTitle: String,
                       initialFileName: String? = nil,
                       parentWindow: NSWindow? = nil,
                       deferredDisplay: Bool = false,
                       work: @escaping (SZOperationSession) throws -> T) async throws -> T
    {
        let coordinator = ArchiveOperationCoordinator(operationTitle: operationTitle,
                                                      initialFileName: initialFileName,
                                                      parentWindow: parentWindow,
                                                      deferredDisplay: deferredDisplay)
        coordinator.start()
        defer { coordinator.finish() }
        let session = coordinator.session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    session.requestCancel()
                }

                let operation = ArchiveOperationWork(body: work)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try operation(session)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            session.requestCancel()
        }
    }
}
