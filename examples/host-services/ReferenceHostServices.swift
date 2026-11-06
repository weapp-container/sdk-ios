import Foundation
import UIKit
import WeappContainer

/// Inject this only into native debug code. The control token never belongs in a portable pack.
public struct DemoEnvironment {
    public let origin: URL
    public let controlToken: String
    public init(origin: URL, controlToken: String) throws {
        guard origin.scheme == "http", ["127.0.0.1", "localhost"].contains(origin.host ?? ""),
              ["", "/"].contains(origin.path), origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              controlToken.count >= 32 else { throw WeappHostError(code: .invalidRequest, message: "Use an explicit native loopback demo environment") }
        self.origin = origin; self.controlToken = controlToken
    }
}

/// Share this native credential domain across controllers. Core shares host/tenant revocation as well.
@MainActor public final class DemoHostDomain {
    public let environment: DemoEnvironment
    public private(set) var configuration: [String: WeappJSON] = [:]
    private var tokens: [String: String] = [:]
    private let transport = URLSession(configuration: .ephemeral)
    public init(environment: DemoEnvironment) { self.environment = environment }
    private func key(_ account: WeappJSON) throws -> String {
        guard let principal = account["principalId"].string, let epoch = account["epoch"].string else { throw WeappHostError(code: .permissionDenied, message: "Native principal epoch required") }
        return principal + ":" + epoch
    }
    public func token(for context: WeappJSON) throws -> String {
        guard let token = tokens[try key(context["account"])] else { throw WeappHostError(code: .permissionDenied, message: "No native credential for this principal epoch") }; return token
    }
    public var context: [String: WeappJSON] { configuration.merging(["sessionId": .string("native-demo")]) { _, value in value } }
    public func selection(_ context: WeappJSON) -> [String: WeappJSON] {
        ["miniAppId": context["application"]["appId"], "packRoot": context["application"]["packRoot"], "expectedPrincipalId": context["account"]["principalId"], "expectedPrincipalEpoch": context["account"]["epoch"]]
    }
    public func bootstrap(principal: String = "demo-A", epoch: String = "1") async throws {
        let value = try await request("/demo/host", token: environment.controlToken, body: ["principalId": .string(principal), "principalEpoch": .string(epoch)])
        guard let token = value["hostAccessToken"].string else { throw WeappHostError(code: .permissionDenied, message: "Demo host bootstrap failed") }
        tokens[try key(value["account"])] = token
        configuration = ["application": value["application"], "account": value["account"]]
    }
    @discardableResult public func switchAccount(entry: WeappContainerSession, principal: String, epoch: String, launches: [String: WeappJSON] = [:]) async throws -> WeappJSON {
        try await bootstrap(principal: principal, epoch: epoch)
        return try entry.hostServicesCommand("switchAccount", ["account": configuration["account"] ?? .null, "launches": .object(launches)])
    }
    func request(_ path: String, token: String, body: [String: WeappJSON]) async throws -> WeappJSON {
        var request = URLRequest(url: URL(string: path, relativeTo: environment.origin)!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(WeappJSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (bytes, response) = try await transport.bytes(for: request)
        var data = Data(); for try await byte in bytes { guard data.count < 262144 else { throw WeappHostError(code: .invalidRequest, message: "Demo response exceeds limit") }; data.append(byte) }
        let value = try JSONDecoder().decode(WeappJSON.self, from: data)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw WeappHostError(code: .invalidRequest, message: value["message"].string ?? "Demo request failed") }
        return value
    }
    public func close() { tokens.removeAll(); transport.invalidateAndCancel() }
}

@MainActor private final class ReferencePayment: WeappNativeAppPayChannel {
    let channel = "reference", isAvailable = true
    weak var presenter: UIViewController?
    let domain: DemoHostDomain
    init(presenter: UIViewController, domain: DemoHostDomain) { self.presenter = presenter; self.domain = domain }
    func pay(_ launch: WeappJSON, call: WeappHostApiCall) async throws {
        guard launch["kind"].string == "reference", let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw WeappHostError(code: .invalidRequest, message: "Visible native demo presenter required") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var settled = false
            let alert = UIAlertController(title: "本地 reference 支付", message: "确认开发测试订单，不会调用钱包或转移真实资金。", preferredStyle: .alert)
            @MainActor func finish(_ result: Result<Void, Error>) { guard !settled else { return }; settled = true; alert.dismiss(animated: false); continuation.resume(with: result) }
            alert.addAction(UIAlertAction(title: "确认测试订单", style: .default) { [domain] _ in Task { @MainActor in
                do {
                    _ = try await domain.request("/demo/reference-confirm", token: domain.environment.controlToken, body: ["orderId": launch["orderId"], "hostAccessToken": .string(try domain.token(for: call.context)), "selection": .object(domain.selection(call.context))])
                    finish(.success(()))
                } catch { finish(.failure(error)) }
            } })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in finish(.failure(CancellationError())) })
            call.cancellation.onCancel { finish(.failure(CancellationError())) }; presenter.present(alert, animated: true)
        }
    }
}

@MainActor public final class ReferenceHostServices {
    private let domain: DemoHostDomain
    private let backend: WeappHostServicesClient
    private let identity: WeappHostIdentity
    private let payments: WeappAppPayments
    public init(presenter: UIViewController, domain: DemoHostDomain) throws {
        self.domain = domain
        backend = try WeappHostServicesClient(endpoint: domain.environment.origin, allowLoopbackHTTP: true) { [domain] in try domain.token(for: $0.context) }
        identity = WeappHostIdentity(presenter: presenter, backend: backend)
        payments = try WeappAppPayments(backend: backend, channels: [ReferencePayment(presenter: presenter, domain: domain)])
    }
    public func installAndLoad(in session: WeappContainerSession, pack: URL, options: [String: WeappJSON] = [:]) async throws {
        let prepared = try await identity.prepareConfiguration(domain.configuration)
        try session.configureHostServices(prepared)
        try identity.install(in: session); try payments.install(in: session)
        try session.registerHostMethod("demo.identity.refresh") { [weak self, weak session] _ in
            guard let self, let session else { throw CancellationError() }
            try await self.refresh(in: session)
            return .object(["refreshed": .bool(true)])
        }
        session.onAccountCleanup = { [identity, domain, weak session] operation in
            guard let session else { throw CancellationError() }
            _ = try await identity.prepareAccountState(in: session, operationID: operation, trustedContext: domain.context)
        }
        try await session.load(packURL: pack, options: options)
    }
    /// Call after /demo/login code redemption, or token/consent/foreground changes.
    public func refresh(in session: WeappContainerSession) async throws { _ = try await identity.refreshState(in: session, trustedContext: domain.context) }
    public func logoutApp(in session: WeappContainerSession) async throws {
        let context = WeappJSON.object(domain.context)
        _ = try await domain.request("/v1/host/app-logout", token: domain.token(for: context), body: domain.selection(context))
        try await refresh(in: session)
    }
    public func close() { backend.close() }
}
