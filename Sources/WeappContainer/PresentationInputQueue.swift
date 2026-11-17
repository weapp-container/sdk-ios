import Foundation

/// Main-actor-owned input staging. A completed presentation grants one batch;
/// dispatch may accept another frame and therefore consumes that grant.
struct PresentationInputQueue {
    struct Batch {
        let id: UInt64
        var events: [WeappJSON]
        let deadline: TimeInterval
    }
    private(set) var batches: [Batch] = []
    private(set) var context: WeappJSON?
    private var sequence: UInt64 = 0
    let capacity: Int
    let timeout: TimeInterval

    init(capacity: Int = 64, timeout: TimeInterval = 2) {
        precondition(capacity > 0 && timeout > 0)
        self.capacity = capacity; self.timeout = timeout
    }
    mutating func clear() { batches.removeAll(); context = nil }
    mutating func enqueue(_ events: [WeappJSON], context: WeappJSON, now: TimeInterval) throws {
        guard !events.isEmpty else { return }
        if self.context != context { clear(); self.context = context }
        if events.count == 1, events[0]["type"].string == "touchmove",
           let previous = batches.last, previous.events.count == 1,
           previous.events[0]["type"].string == "touchmove" {
            // Keep the first move's deadline: continuous replacement must not
            // hide a presenter which has stopped completing frames.
            batches[batches.count - 1].events = events
        } else {
            guard batches.count < capacity else {
                throw WeappContainerError(code: "ERR_INPUT_OVERFLOW", message: "Input exceeded the bounded presentation queue")
            }
            sequence &+= 1
            batches.append(Batch(id: sequence, events: events, deadline: now + timeout))
        }
    }
    mutating func next(context: WeappJSON, inputEnabled: Bool, now: TimeInterval) throws -> Batch? {
        guard self.context == context else { clear(); return nil }
        guard let first = batches.first else { return nil }
        guard first.deadline > now else {
            throw WeappContainerError(code: "ERR_TIMEOUT", message: "Input awaited GPU presentation for more than two seconds")
        }
        return inputEnabled ? first : nil
    }
    mutating func didDispatch(_ batch: Batch) {
        // Dispatch may reenter lifecycle/navigation handlers and retire the
        // queue. An old completion must not consume a newly queued gesture.
        if batches.first?.id == batch.id { batches.removeFirst() }
    }
}
