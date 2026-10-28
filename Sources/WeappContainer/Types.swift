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
    public init(code: Code, message: String, retryable: Bool = false) { self.code = code; self.message = message; self.retryable = retryable }
}

public enum WeappContainerEvent: Sendable {
    case ready(WeappJSON), navigation(WeappJSON), message(WeappJSON)
    case error(WeappContainerError), closed(WeappContainerError?)
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
    public init(storageKey: String, storageRoot: URL? = nil, sessionID: String = UUID().uuidString, gpuRequired: Bool? = nil, devDiagnostics: Bool = false) {
        self.storage = .persistent(key: storageKey, root: storageRoot); self.sessionID = sessionID; self.gpuRequired = gpuRequired; self.devDiagnostics = devDiagnostics
    }
    public init(storage: Storage, sessionID: String = UUID().uuidString, gpuRequired: Bool? = nil, devDiagnostics: Bool = false) {
        self.storage = storage; self.sessionID = sessionID; self.gpuRequired = gpuRequired; self.devDiagnostics = devDiagnostics
    }
}
