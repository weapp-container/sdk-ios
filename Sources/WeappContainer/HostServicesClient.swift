import Foundation
import UIKit

private final class HostServicesNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Native-only HTTP transport; never pass its token provider or returned host bearer through JS.
@MainActor public final class WeappHostServicesClient {
    private let endpoint: URL
    private let token: (WeappHostApiCall) throws -> String
    private let transport: URLSession
    public init(endpoint: URL, allowLoopbackHTTP: Bool = false, hostToken: @escaping (WeappHostApiCall) throws -> String) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              parts.scheme == "https" || allowLoopbackHTTP && parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(parts.host ?? "") else {
            throw WeappHostError(code: .invalidRequest, message: "Use HTTPS; loopback HTTP requires explicit development opt-in")
        }
        self.endpoint = endpoint; self.token = hostToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        transport = URLSession(configuration: configuration, delegate: HostServicesNoRedirect(), delegateQueue: nil)
    }
    public func selection(_ call: WeappHostApiCall) throws -> [String: WeappJSON] {
        let application = call.context["application"]
        guard let app = application["appId"].string, let root = application["packRoot"].string, root.count == 64 else {
            throw WeappHostError(code: .permissionDenied, message: "Verified native installation identity required")
        }
        return ["miniAppId": .string(app), "packRoot": .string(root), "expectedPrincipalId": call.context["account"]["principalId"], "expectedPrincipalEpoch": call.context["account"]["epoch"]]
    }
    public func request(_ call: WeappHostApiCall, path: String, body: [String: WeappJSON]) async throws -> WeappJSON {
        try Task.checkCancellation()
        guard !call.cancellation.isCancelled, path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { throw WeappHostError(code: .invalidRequest, message: "Invalid native backend request") }
        let bearer = try token(call)
        guard !bearer.isEmpty, !bearer.contains("\r"), !bearer.contains("\n") else { throw WeappHostError(code: .permissionDenied, message: "Host login required") }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(WeappJSON.object(body))
        let (bytes, response) = try await transport.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262144 else { throw WeappHostError(code: .invalidRequest, message: "Backend response exceeds limit") }
            data.append(byte)
        }
        let value = try JSONDecoder().decode(WeappJSON.self, from: data)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let reason = value["error"].string ?? "host_services_error"
            throw WeappHostError(code: ["consent_required", "invalid_host_session", "invalid_app_session", "host_identity_mismatch", "stale_principal"].contains(reason) ? .permissionDenied : .invalidRequest,
                message: value["message"].string ?? "Host services request failed", details: ["backendCode": .string(reason)])
        }
        try Task.checkCancellation(); return value
    }
    public func launch(_ call: WeappHostApiCall, orderID: String) async throws -> WeappJSON {
        guard orderID.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil else { throw WeappHostError(code: .invalidRequest, message: "Invalid server order ID") }
        return try await request(call, path: "/v1/payments/orders/\(orderID)/launch", body: selection(call))
    }
    public func close() { transport.invalidateAndCancel() }
}

/// Existing host login is reused, while profile and phone disclosures use separate visible prompts.
@MainActor public final class WeappHostIdentity {
    private weak var presenter: UIViewController?
    private let backend: WeappHostServicesClient
    private var subscriptions: [String: WeappHostApiCall] = [:]
    private var sequences: [String: UInt64] = [:]
    public init(presenter: UIViewController, backend: WeappHostServicesClient) { self.presenter = presenter; self.backend = backend }
    /// Await before configure/load: guest getState must start from a live backend result.
    public func prepareConfiguration(_ configuration: [String: WeappJSON]) async throws -> [String: WeappJSON] {
        var configuration = configuration
        let call = nativeCall(["application": configuration["application"] ?? .null, "account": configuration["account"] ?? .null, "sessionId": .string("native-preflight")])
        let state = try await backend.request(call, path: "/v1/host/identity-state", body: backend.selection(call))
        configuration["syncValues"] = .object((configuration["syncValues"]?.dictionary ?? [:]).merging(["weappContainer.identity.getState": state]) { _, value in value })
        var apis = configuration["apis"]?.array ?? []
        if !apis.contains(.string("weappContainer.identity.getState")) { apis.append(.string("weappContainer.identity.getState")) }
        configuration["apis"] = .array(apis); return configuration
    }
    /// Refresh after server code redemption, revocation, token refresh and foreground resume.
    @discardableResult public func refreshState(in session: WeappContainerSession, trustedContext: [String: WeappJSON]) async throws -> WeappJSON {
        try await refresh(session, nativeCall(trustedContext))
    }
    /// Run inside onAccountCleanup after installing the new native host token, before cleanup ACK.
    @discardableResult public func prepareAccountState(in session: WeappContainerSession, operationID: String, trustedContext: [String: WeappJSON]) async throws -> WeappJSON {
        let call = nativeCall(trustedContext)
        let state = try await backend.request(call, path: "/v1/host/identity-state", body: backend.selection(call))
        _ = try session.hostServicesCommand("prepareAccountHostServiceSnapshots", ["operationId": .string(operationID), "values": .object(["weappContainer.identity.getState": state])])
        return state
    }
    private func nativeCall(_ context: [String: WeappJSON]) -> WeappHostApiCall {
        WeappHostApiCall(event: .object(["callId": .string("native-identity-\(UUID().uuidString)"), "method": .string("weappContainer.identity.getState"), "payload": .object([:]), "context": .object(context)]), cancellation: WeappHostApiCancellation())
    }
    private func refresh(_ session: WeappContainerSession, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let state = try await backend.request(call, path: "/v1/host/identity-state", body: backend.selection(call))
        try Task.checkCancellation(); guard !call.cancellation.isCancelled else { throw CancellationError() }
        _ = try session.hostServicesCommand("updateHostServiceSnapshots", ["context": call.context, "values": .object(["weappContainer.identity.getState": state])])
        for (id, subscription) in subscriptions where !subscription.cancellation.isCancelled && subscription.context["application"] == call.context["application"] && subscription.context["account"] == call.context["account"] {
            let next = (sequences[id] ?? 0) + 1; sequences[id] = next
            _ = try session.emitHostApiEvent(["sessionId": subscription.context["sessionId"], "accountEpoch": subscription.context["account"]["epoch"], "subscriptionId": .string(id), "sequence": .string(String(next)), "value": state])
        }
        return state
    }
    public func install(in session: WeappContainerSession) throws {
        try session.registerHostResourceCleanup("identity-\(UUID().uuidString)") { [weak self] in self?.subscriptions.removeAll(); self?.sequences.removeAll() }
        for api in ["wx.login", "wx.checkSession", "wx.getUserInfo", "wx.getUserProfile", "component:button.open-type.getPhoneNumber", "weappContainer.identity.authorizePhone", "weappContainer.identity.logout", "weappContainer.identity.getState", "weappContainer.identity.onChange", "weappContainer.identity.offChange"] {
            try session.registerApiHandler(api) { [weak self, weak session] call in
                guard let self else { throw WeappHostError(code: .cancelled, message: "Host identity adapter retired") }
                guard let session else { throw CancellationError() }
                var selection = try self.backend.selection(call)
                var result: WeappJSON
                switch api {
                case "wx.login": result = try await self.backend.request(call, path: "/v1/host/login-codes", body: selection)
                case "wx.checkSession":
                    do { result = try await self.backend.request(call, path: "/v1/host/check-session", body: selection) }
                    catch { _ = try? await self.refresh(session, call); throw error }
                case "weappContainer.identity.getState": throw WeappHostError(code: .unsupported, message: "Read identity state from the prepared synchronous snapshot")
                case "component:button.open-type.getPhoneNumber": throw WeappHostError(code: .unsupported, message: "Phone authorization is dispatched from the bound native button gesture")
                case "weappContainer.identity.onChange", "weappContainer.identity.offChange":
                    guard let id = call.payload["subscriptionId"].string else { throw WeappHostError(code: .invalidRequest, message: "Subscription identity required") }
                    if api.hasSuffix(".offChange") { self.subscriptions.removeValue(forKey: id); self.sequences.removeValue(forKey: id) }
                    else {
                        self.subscriptions[id] = call; call.cancellation.retainUntilCancelled()
                        call.cancellation.onCancel { [weak self] in self?.subscriptions.removeValue(forKey: id); self?.sequences.removeValue(forKey: id) }
                    }
                    return .object(["errMsg": .string("\(api):ok")])
                case "wx.getUserInfo": result = .object(["userInfo": try await self.backend.request(call, path: "/v1/host/profile", body: selection)])
                case "weappContainer.identity.logout": result = try await self.backend.request(call, path: "/v1/host/app-logout", body: selection)
                default:
                    let phone = api == "weappContainer.identity.authorizePhone"
                    try await self.confirm(call, phone: phone)
                    selection["kind"] = .string(phone ? "phone" : "profile"); selection["granted"] = .bool(true)
                    _ = try await self.backend.request(call, path: "/v1/host/consents", body: selection)
                    let app = try self.backend.selection(call)
                    if phone { result = try await self.backend.request(call, path: "/v1/host/phone-codes", body: app) }
                    else { result = .object(["userInfo": try await self.backend.request(call, path: "/v1/host/profile", body: app)]) }
                }
                _ = try await self.refresh(session, call)
                return .object(result.dictionary.merging(["errMsg": .string("\(api):ok")]) { _, value in value })
            }
        }
    }
    private func confirm(_ call: WeappHostApiCall, phone: Bool) async throws {
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw WeappHostError(code: .invalidRequest, message: "Visible idle presenter required for consent") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var settled = false
            let alert = UIAlertController(title: phone ? "授权手机号" : "授权昵称和头像", message: phone ? "允许此小程序获取宿主账号已验证的手机号？" : "允许此小程序获取宿主账号的昵称和头像？", preferredStyle: .alert)
            let finish: (Result<Void, Error>) -> Void = { result in guard !settled else { return }; settled = true; continuation.resume(with: result) }
            alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in finish(.success(())) })
            alert.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in finish(.failure(WeappHostError(code: .permissionDenied, message: "User denied consent", details: ["errMsg": .string("\(call.method):fail auth deny"), "errCode": .number(2001)]))) })
            call.cancellation.onCancel { alert.dismiss(animated: false); finish(.failure(CancellationError())) }
            presenter.present(alert, animated: true)
        }
    }
}
