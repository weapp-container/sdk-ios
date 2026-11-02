import Foundation

/// A signed-out owner has no credential to send to the backend. This is a
/// projection of the trusted native account, never a fallback for HTTP failure.
enum WeappHostIdentitySnapshot {
    /// Freeze the actual incarnation before awaiting the backend, never after it returns.
    static func refreshContext(_ trusted: WeappJSON, nativeState: WeappJSON) throws -> [String: WeappJSON] {
        let current = nativeState["hostServicesState"]
        guard !current["application"].dictionary.isEmpty, !current["account"].dictionary.isEmpty,
              current["application"] == trusted["application"], current["account"] == trusted["account"],
              let incarnation = nativeState["sessionId"].string, !incarnation.isEmpty else {
            throw WeappHostError(code: .cancelled, message: "A current native snapshot owner is required")
        }
        return current.dictionary.merging(["sessionId": .string(incarnation)]) { _, value in value }
    }

    static func signedOut(_ context: WeappJSON) throws -> WeappJSON? {
        let account = context["account"].dictionary
        guard let principal = account["principalId"], let epoch = account["epoch"]?.string,
              let exactEpoch = UInt64(epoch), String(exactEpoch) == epoch else {
            throw WeappHostError(code: .invalidRequest, message: "Trusted account principal and exact epoch required")
        }
        if case .string(let value) = principal, !value.isEmpty { return nil }
        guard principal == .null else { throw WeappHostError(code: .invalidRequest, message: "Invalid trusted account principal") }
        return .object(["hostLoggedIn": .bool(false), "appLoggedIn": .bool(false),
                        "profileAuthorized": .bool(false), "phoneAuthorized": .bool(false),
                        "authorizationVersion": .string("0")])
    }
}
