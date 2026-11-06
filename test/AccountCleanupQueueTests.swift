import Foundation

@MainActor private final class Gate {
    var waiters: [CheckedContinuation<Void, Never>] = []
    var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

@main struct AccountCleanupQueueTests {
    @MainActor static func turn() async { for _ in 0..<8 { await Task.yield() } }
    @MainActor static func main() async {
        let queue = AccountCleanupQueue(), old = Gate(), latest = Gate()
        var started: [String] = [], acknowledgements: [String] = []
        let first = queue.enqueue {
            started.append("old"); await old.wait()
            if !Task.isCancelled { acknowledgements.append("old") }
        }
        await turn(); precondition(started == ["old"])
        let skipped = queue.enqueue {
            guard !Task.isCancelled else { return }
            started.append("skipped")
        }
        first.cancel(); skipped.cancel()
        let current = queue.enqueue {
            guard !Task.isCancelled else { return }
            started.append("latest"); await latest.wait(); acknowledgements.append("latest")
        }
        latest.release(); var closed = false
        let closing = Task { @MainActor in await queue.drain(); closed = true }
        await turn(); precondition(started == ["old"] && acknowledgements.isEmpty && !closed)
        old.release(); await current.value; await closing.value
        precondition(started == ["old", "latest"] && acknowledgements == ["latest"] && closed)

        let pending = Gate(); var failureEnded = false, retryStarted = false
        enum CleanupError: Error { case busy }
        _ = queue.enqueue {
            do { await pending.wait(); throw CleanupError.busy } catch { failureEnded = true }
        }
        let retry = queue.enqueue { precondition(failureEnded); retryStarted = true }
        await turn(); precondition(!retryStarted); pending.release(); await retry.value
        precondition(failureEnded && retryStarted)
        print("Account cleanup waits actual old terminals before latest retry and close, including cancelled tasks")
    }
}
