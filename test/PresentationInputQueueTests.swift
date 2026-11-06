import Foundation

@main struct PresentationInputQueueTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ body: () throws -> Void) rethrows {
            try body(); passed += 1; print("PASS \(name)")
        }
        let context: WeappJSON = .object(["generation": .number(1), "page": .string("home")])
        let nextPage: WeappJSON = .object(["generation": .number(1), "page": .string("detail")])
        func event(_ type: String, _ x: Double = 0) -> WeappJSON { .object(["type": .string(type), "x": .number(x)]) }
        func expectError(_ code: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected \(code)") }
            catch let error as WeappContainerError { precondition(error.code == code, "Unexpected \(error)") }
            catch { preconditionFailure("Unexpected \(error)") }
        }
        try check("cancel while a newly accepted frame is unpresented waits for ACK and terminates exactly once") {
            var queue = PresentationInputQueue(), enabled = true, delivered: [String] = []
            func sendOne() throws {
                if let batch = try queue.next(context: context, inputEnabled: enabled, now: 0.1) {
                    precondition(enabled)
                    delivered += batch.events.compactMap { $0["type"].string }
                    enabled = false; queue.didDispatch(batch)
                }
            }
            try queue.enqueue([event("touchstart")], context: context, now: 0)
            try sendOne()
            try queue.enqueue([event("touchmove", 1)], context: context, now: 0.01)
            try queue.enqueue([event("touchmove", 9)], context: context, now: 0.02)
            try queue.enqueue([event("touchcancel")], context: context, now: 0.03)
            try sendOne(); precondition(delivered == ["touchstart"])
            enabled = true; try sendOne(); precondition(delivered == ["touchstart", "touchmove"])
            try sendOne(); precondition(queue.batches.count == 1)
            enabled = true; try sendOne(); try sendOne()
            precondition(delivered == ["touchstart", "touchmove", "touchcancel"] && queue.batches.isEmpty)
        }
        try check("end and tap remain ordered and adjacent move coalescing never crosses a terminal event") {
            var queue = PresentationInputQueue()
            for events in [[event("touchstart")], [event("touchmove", 1)], [event("touchmove", 2)], [event("touchend"), event("tap")], [event("touchstart")], [event("touchmove", 3)], [event("touchcancel")]] {
                try queue.enqueue(events, context: context, now: 0)
            }
            precondition(queue.batches.count == 6)
            precondition(queue.batches[1].events[0]["x"].number == 2)
            precondition(queue.batches[2].events.map { $0["type"].string! } == ["touchend", "tap"])
            precondition(queue.batches.last?.events[0]["type"].string == "touchcancel")
        }
        try check("page navigation rejects old gesture phases and cancellation") {
            var queue = PresentationInputQueue()
            try queue.enqueue([event("touchcancel")], context: context, now: 0)
            let stale = try queue.next(context: nextPage, inputEnabled: true, now: 0.1)
            precondition(stale == nil)
            precondition(queue.batches.isEmpty && queue.context == nil)
        }
        try check("surface retirement clears pending cancellation and cannot replay it after reattach") {
            var queue = PresentationInputQueue()
            try queue.enqueue([event("touchcancel")], context: context, now: 0)
            queue.clear()
            let retired = try queue.next(context: context, inputEnabled: true, now: 0.1)
            precondition(retired == nil)
        }
        try check("a restarted session cannot receive a prior generation's pending cancellation") {
            var queue = PresentationInputQueue()
            try queue.enqueue([event("touchcancel")], context: context, now: 0)
            let newGeneration: WeappJSON = .object(["generation": .number(2), "page": .string("home")])
            let retired = try queue.next(context: newGeneration, inputEnabled: true, now: 0.1)
            precondition(retired == nil && queue.batches.isEmpty)
        }
        try check("a reentrant retirement and new gesture cannot be consumed by an old dispatch receipt") {
            var queue = PresentationInputQueue()
            try queue.enqueue([event("touchstart")], context: context, now: 0)
            let old = try queue.next(context: context, inputEnabled: true, now: 0.1)!
            queue.clear(); try queue.enqueue([event("touchstart", 8)], context: nextPage, now: 0.1)
            queue.didDispatch(old)
            precondition(queue.batches.count == 1 && queue.batches[0].events[0]["x"].number == 8)
        }
        try check("a rejected dispatch remains queued until a later valid presentation") {
            var queue = PresentationInputQueue()
            try queue.enqueue([event("touchcancel")], context: context, now: 0)
            let rejected = try queue.next(context: context, inputEnabled: true, now: 0.1)!
            let waiting = try queue.next(context: context, inputEnabled: false, now: 0.2)
            precondition(waiting == nil)
            let retry = try queue.next(context: context, inputEnabled: true, now: 0.3)!
            precondition(retry.id == rejected.id); queue.didDispatch(retry)
            precondition(queue.batches.isEmpty)
        }
        try check("a stalled presentation times out even while newer moves arrive") {
            var queue = PresentationInputQueue()
            try queue.enqueue([event("touchmove", 1)], context: context, now: 0)
            try queue.enqueue([event("touchmove", 2)], context: context, now: 1.9)
            expectError("ERR_TIMEOUT") { _ = try queue.next(context: context, inputEnabled: false, now: 2.01) }
        }
        try check("capacity exhaustion reports an explicit error and never overwrites terminal phases") {
            var queue = PresentationInputQueue(capacity: 2)
            try queue.enqueue([event("touchstart")], context: context, now: 0)
            try queue.enqueue([event("touchcancel")], context: context, now: 0.1)
            expectError("ERR_INPUT_OVERFLOW") { try queue.enqueue([event("touchstart")], context: context, now: 0.2) }
            precondition(queue.batches.count == 2 && queue.batches.last?.events[0]["type"].string == "touchcancel")
        }
        print("\(passed) presentation input state-machine cases passed")
    }
}
