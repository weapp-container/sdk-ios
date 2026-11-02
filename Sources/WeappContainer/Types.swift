import Foundation

/// JSON crossing the application boundary. No runtime bridge envelopes are exposed.
public enum WeappJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([WeappJSON]), object([String: WeappJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([WeappJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: WeappJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> WeappJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [WeappJSON]? { if case .array(let v) = self { return v }; return nil }
    var dictionary: [String: WeappJSON] { if case .object(let v) = self { return v }; return [:] }
}

public struct WeappContainerError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
    init(_ value: WeappJSON) { self.init(code: value["code"].string ?? "ERR_NATIVE", message: value["message"].string ?? "Native SDK operation failed") }
}

public struct WeappHostError: Error, Sendable {
    public enum Code: String, Sendable { case invalidRequest = "invalid_request", permissionDenied = "permission_denied", timeout, cancelled, unsupported }
    public let code: Code
    public let message: String
    public let retryable: Bool
    /// Exact API failure fields, including numeric errCode and original errMsg.
    public let details: [String: WeappJSON]
    public init(code: Code, message: String, retryable: Bool = false, details: [String: WeappJSON] = [:]) {
        self.code = code; self.message = message; self.retryable = retryable; self.details = details
    }
}

/// Native-minted call metadata, kept independently of guest payload and mapped method names.
public struct WeappHostApiCall: Sendable {
    public let id: String
    public let method: String
    public let payload: WeappJSON
    public let context: WeappJSON
    public let deadlineNs: String?
    public let cancelToken: String?
    public let cancellation: WeappHostApiCancellation
    public let keepsResourceAlive: Bool
    init(event: WeappJSON, cancellation: WeappHostApiCancellation) {
        id = event["callId"].string ?? ""; method = event["method"].string ?? ""
        payload = event["payload"]; context = event["context"]
        deadlineNs = event["deadlineNs"].string ?? event["deadlineNs"].number.flatMap { value in
            value >= 0 && value <= 9007199254740991 && value.rounded(.down) == value ? String(UInt64(value)) : nil
        }
        cancelToken = event["cancelToken"].string
        self.cancellation = cancellation
        keepsResourceAlive = event["retainUntilCancelled"].bool == true
    }
}

/// Native resource lifetime, independent of the async setup handler returning.
@MainActor public final class WeappHostApiCancellation {
    public private(set) var isCancelled = false
    private var callbacks: [() -> Void] = []
    var retained = false
    public func retainUntilCancelled() { retained = true }
    public func onCancel(_ callback: @escaping () -> Void) {
        if isCancelled { callback() } else { callbacks.append(callback) }
    }
    func cancel() {
        guard !isCancelled else { return }; isCancelled = true
        let pending = callbacks; callbacks.removeAll(); for callback in pending { callback() }
    }
}

public enum WeappContainerEvent: Sendable {
    case ready(WeappJSON), navigation(WeappJSON), chrome(WeappJSON), message(WeappJSON)
    case error(WeappContainerError), closed(WeappContainerError?)
    /// Versioned SDK events not projected into an older typed wrapper.
    case raw(WeappJSON)
}

public struct WeappContainerConfiguration: Sendable {
    public enum Storage: Sendable {
        /// A stable application/account key, independent of a pack or session ID.
        case persistent(key: String, root: URL? = nil)
        case memoryOnly
    }
    public var storage: Storage
    public var sessionID: String
    public var gpuRequired: Bool?
    public var devDiagnostics: Bool
    /// Opt in before native creation; complete host layouts become mandatory.
    public var atomicHostLayout: Bool = false
    public init(storageKey: String, storageRoot: URL? = nil, sessionID: String = UUID().uuidString, gpuRequired: Bool? = nil, devDiagnostics: Bool = false) {
        self.storage = .persistent(key: storageKey, root: storageRoot); self.sessionID = sessionID; self.gpuRequired = gpuRequired; self.devDiagnostics = devDiagnostics
    }
    public init(storage: Storage, sessionID: String = UUID().uuidString, gpuRequired: Bool? = nil, devDiagnostics: Bool = false) {
        self.storage = storage; self.sessionID = sessionID; self.gpuRequired = gpuRequired; self.devDiagnostics = devDiagnostics
    }
}
