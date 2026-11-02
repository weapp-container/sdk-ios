import Foundation

@main struct HostIdentitySnapshotTests {
    static func context(_ principal: WeappJSON, epoch: WeappJSON = .string("1")) -> WeappJSON {
        .object(["account": .object(["principalId": principal, "epoch": epoch])])
    }
    static func rejects(_ value: WeappJSON) {
        do { _ = try WeappHostIdentitySnapshot.signedOut(value); fatalError("Invalid trusted account was accepted") }
        catch { precondition(error is WeappHostError) }
    }
    static func main() throws {
        let state = try WeappHostIdentitySnapshot.signedOut(context(.null, epoch: .string("18446744073709551615")))
        precondition(state == .object(["hostLoggedIn": .bool(false), "appLoggedIn": .bool(false), "profileAuthorized": .bool(false), "phoneAuthorized": .bool(false), "authorizationVersion": .string("0")]))
        let defaultSignedOut = try WeappHostIdentitySnapshot.signedOut(context(.null, epoch: .string("0")))
        precondition(defaultSignedOut == state)
        let signedIn = try WeappHostIdentitySnapshot.signedOut(context(.string("user-A")))
        precondition(signedIn == nil)
        rejects(.null)
        rejects(.object(["account": .object(["epoch": .string("1")])]))
        for principal in [WeappJSON.string(""), .number(1), .bool(false), .object([:])] { rejects(context(principal)) }
        for epoch in [WeappJSON.string("00"), .string("01"), .string("-1"), .string("18446744073709551616"), .number(1)] { rejects(context(.null, epoch: epoch)) }
        print("Native logout snapshots preserve exact account epochs and reject missing/malformed identity. Signed-in accounts still require the backend.")
    }
}
