import Foundation

/// Cancellation revokes an operation, while its real hook terminal owns the tail.
@MainActor final class AccountCleanupQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ cleanup: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            if let previous { await previous.value }
            await cleanup()
        }
        tail = task
        return task
    }

    func drain() async {
        if let tail { await tail.value }
    }
}
