import Foundation

/// Shared across UI and archive worker queues; all mutable state is guarded by `condition`.
final class FileManagerArchiveOperationGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let gate: FileManagerArchiveOperationGate

        fileprivate init(gate: FileManagerArchiveOperationGate) {
            self.gate = gate
        }

        deinit {
            gate.releaseLease()
        }
    }

    private let condition = NSCondition()
    private var activeLeaseCount = 0
    private var isClosing = false

    func acquireLease() -> Lease? {
        condition.lock()
        defer { condition.unlock() }

        guard !isClosing else {
            return nil
        }

        activeLeaseCount += 1
        return Lease(gate: self)
    }

    func beginClosing() {
        condition.lock()
        isClosing = true
        condition.unlock()
    }

    func beginClosingAndWaitForLeases() {
        beginClosing()
        waitForLeasesToDrain()
    }

    var hasActiveLeases: Bool {
        condition.lock()
        let hasActiveLeases = activeLeaseCount > 0
        condition.unlock()
        return hasActiveLeases
    }

    func waitForLeasesToDrain() {
        while true {
            condition.lock()
            if activeLeaseCount == 0 {
                condition.unlock()
                return
            }

            if Thread.isMainThread {
                condition.unlock()
                _ = RunLoop.current.run(mode: .default,
                                        before: Date().addingTimeInterval(0.05))
            } else {
                _ = condition.wait(until: Date().addingTimeInterval(0.05))
                condition.unlock()
            }
        }
    }

    func cancelClosing() {
        condition.lock()
        isClosing = false
        condition.broadcast()
        condition.unlock()
    }

    private func releaseLease() {
        condition.lock()
        activeLeaseCount -= 1
        precondition(activeLeaseCount >= 0)
        if activeLeaseCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}
