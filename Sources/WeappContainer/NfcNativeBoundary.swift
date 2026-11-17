import Foundation

/// Caller cancellation and native terminal acknowledgment are separate events.
@MainActor final class WeappNfcNativeBoundary<Value> {
    private var settle: ((Result<Value, Error>) -> Void)?
    private var terminal: (() -> Void)?
    private(set) var nativeFinished = false
    init(settle: @escaping (Result<Value, Error>) -> Void, terminal: @escaping () -> Void) {
        self.settle = settle; self.terminal = terminal
    }
    func cancel(_ error: Error) { let reply = settle; settle = nil; reply?(.failure(error)) }
    func finish(_ result: Result<Value, Error>) {
        guard !nativeFinished else { return }; nativeFinished = true
        let release = terminal; terminal = nil; release?()
        let reply = settle; settle = nil; reply?(result)
    }
}

enum WeappNfcFrames {
    static func felicaCommand(_ frame: Data) throws -> Data {
        guard (2...255).contains(frame.count), Int(frame.first!) == frame.count else { throw invalid("FeliCa wire frame requires its exact LEN byte and 1...254 packet bytes") }
        return frame.dropFirst()
    }
    static func felicaResponse(_ packet: Data) throws -> Data {
        guard (1...254).contains(packet.count) else { throw invalid("FeliCa native response requires 1...254 packet bytes") }
        return Data([UInt8(packet.count + 1)]) + packet
    }
    static func vicinityCommand(_ frame: Data) throws -> (UInt8, UInt8, Data) {
        guard (2...256).contains(frame.count) else { throw invalid("ISO15693 frame requires flag, command and at most 256 bytes") }
        return (frame[frame.startIndex], frame[frame.startIndex + 1], frame.dropFirst(2))
    }
    private static func invalid(_ message: String) -> WeappHostError { .init(code: .invalidRequest, message: message) }
}
