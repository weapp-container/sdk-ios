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
        precondition(WeappHostIdentitySnapshot.supportsOwnerContext(.object(["hostServices": .object(["snapshotOwnerContext": .string("1.0")])])))
        for flag in [WeappJSON.null, .string(""), .string("0.9"), .string("2.0"), .number(1)] {
            precondition(!WeappHostIdentitySnapshot.supportsOwnerContext(.object(["hostServices": .object(["snapshotOwnerContext": flag])])))
        }
        precondition(!WeappHostIdentitySnapshot.supportsOwnerContext(.object([:])))
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
        let application: WeappJSON = .object(["hostAppId": .string("host"), "tenantId": .string("tenant"), "publisherId": .string("publisher"), "appId": .string("app"), "environment": .string("develop"), "version": .string("1"), "packRoot": .string(String(repeating: "a", count: 64))])
        let owner: WeappJSON = .object(["application": application, "account": context(.string("user-A"))["account"]])
        let trusted: WeappJSON = .object(owner.dictionary.merging(["sessionId": .string("native-demo")]) { _, value in value })
        let nativeState: WeappJSON = .object(["status": .string("ready"), "hostServicesState": owner, "sessionId": .string("runtime-A-1")])
        let frozen = try WeappHostIdentitySnapshot.refreshContext(trusted, nativeState: nativeState)
        precondition(frozen["sessionId"] == .string("runtime-A-1") && trusted["sessionId"] == .string("native-demo"))
        func rejectsRefresh(_ changed: WeappJSON) {
            do { _ = try WeappHostIdentitySnapshot.refreshContext(trusted, nativeState: changed); fatalError("Stale refresh owner was accepted") }
            catch { precondition(error is WeappHostError) }
        }
        for status in ["identitySwitching", "empty", "closed"] {
            rejectsRefresh(.object(nativeState.dictionary.merging(["status": .string(status)]) { _, value in value }))
        }
        let nextOwner: WeappJSON = .object(["application": application, "account": context(.string("user-B"), epoch: .string("2"))["account"]])
        rejectsRefresh(.object(["status": .string("ready"), "hostServicesState": nextOwner, "sessionId": .string("runtime-B-2")]))
        precondition(frozen["account"] == owner["account"] && frozen["sessionId"] == .string("runtime-A-1"))
        for field in ["hostAppId", "tenantId", "publisherId", "appId", "environment", "version", "packRoot"] {
            let changedApplication: WeappJSON = .object(application.dictionary.merging([field: .string("changed")]) { _, value in value })
            rejectsRefresh(.object(["status": .string("ready"), "sessionId": .string("runtime-A-1"), "hostServicesState": .object(owner.dictionary.merging(["application": changedApplication]) { _, value in value })]))
        }
        for invalid in [WeappJSON.null, .string(""), .number(1)] {
            rejectsRefresh(.object(["status": .string("ready"), "hostServicesState": owner, "sessionId": invalid]))
        }
        print("Native identity snapshots preserve exact epochs; refresh freezes the real incarnation before I/O and rejects stale application/account ownership.")
    }
}
