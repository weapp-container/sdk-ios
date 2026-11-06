import Foundation

/// Core owns the account lease and directory selection; native adapters only consume its descriptor.
@MainActor final class WeappManagedFileScopes {
    private weak var session: WeappContainerSession?
    func bind(_ target: WeappContainerSession) { precondition(session == nil); session = target }
    func descriptor(_ context: WeappJSON) throws -> WeappJSON {
        guard let session else { throw WeappHostError(code: .permissionDenied, message: "Managed file owner unavailable") }
        let scope = try session.hostServicesCommand("managedFileScope")
        guard scope["application"] == context["application"], scope["account"] == context["account"],
              scope["scopeId"].string?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let root = scope["root"].string, let auxiliary = scope["auxiliaryRoot"].string else {
            throw WeappHostError(code: .permissionDenied, message: "Stale managed file owner")
        }
        let user = URL(fileURLWithPath: root).resolvingSymlinksInPath(), native = URL(fileURLWithPath: auxiliary).resolvingSymlinksInPath()
        guard user.lastPathComponent == "user", native.lastPathComponent == "native", user.deletingLastPathComponent() == native.deletingLastPathComponent() else {
            throw WeappHostError(code: .permissionDenied, message: "Invalid core-managed file scope")
        }
        return scope
    }
    func root(_ context: WeappJSON) throws -> URL { URL(fileURLWithPath: try descriptor(context)["root"].string!, isDirectory: true) }
    func auxiliaryRoot(_ context: WeappJSON) throws -> URL { URL(fileURLWithPath: try descriptor(context)["auxiliaryRoot"].string!, isDirectory: true) }
}
