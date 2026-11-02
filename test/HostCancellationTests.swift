import Foundation

@MainActor private final class Capture {
    let cancellation: WeappHostApiCancellation
    init(_ cancellation: WeappHostApiCancellation) { self.cancellation = cancellation }
}
@main struct HostCancellationTests {
    @MainActor static func main() {
        let completed = WeappHostApiCancellation()
        weak var completedCapture: Capture?
        do { let capture = Capture(completed); completedCapture = capture; completed.onCancel { _ = capture.cancellation } }
        precondition(completedCapture != nil)
        completed.finishSetup(failed: false)
        precondition(completedCapture == nil && !completed.isCancelled)

        let retained = WeappHostApiCancellation(); retained.retainUntilCancelled()
        weak var retainedCapture: Capture?
        do { let capture = Capture(retained); retainedCapture = capture; retained.onCancel { _ = capture.cancellation } }
        retained.finishSetup(failed: false)
        precondition(retainedCapture != nil && !retained.isCancelled)
        retained.cancel(); precondition(retainedCapture == nil && retained.isCancelled)

        let failed = WeappHostApiCancellation(); failed.retainUntilCancelled(); var cleaned = 0
        failed.onCancel { cleaned += 1 }; failed.finishSetup(failed: true); failed.cancel()
        precondition(failed.isCancelled && cleaned == 1)
        print("Completed setup releases capture cycles; retained resources survive until cancellation; failures clean exactly once")
    }
}
