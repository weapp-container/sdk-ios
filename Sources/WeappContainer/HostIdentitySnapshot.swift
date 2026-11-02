import Foundation

/// A signed-out owner has no credential to send to the backend. This is a
/// projection of the trusted native account, never a fallback for HTTP failure.
enum WeappHostIdentitySnapshot {
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
