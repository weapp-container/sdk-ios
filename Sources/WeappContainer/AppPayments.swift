import Foundation
import UIKit
#if canImport(WechatOpenSDK)
import WechatOpenSDK
#endif
#if canImport(AlipaySDK)
import AlipaySDK
#endif

@MainActor public protocol WeappNativeAppPayChannel: AnyObject {
    var channel: String { get }
    var isAvailable: Bool { get }
    func pay(_ launch: WeappJSON, call: WeappHostApiCall) async throws
}

/// Only backend-owned APP launch parameters are passed to official native channels.
@MainActor public final class WeappAppPayments {
    private let backend: WeappHostServicesClient
    private let channels: [String: WeappNativeAppPayChannel]
    private var busy = false
    public init(backend: WeappHostServicesClient, channels: [WeappNativeAppPayChannel]) throws {
        guard Set(channels.map(\.channel)).count == channels.count else { throw WeappHostError(code: .invalidRequest, message: "Duplicate native payment channel") }
        self.backend = backend; self.channels = Dictionary(uniqueKeysWithValues: channels.map { ($0.channel, $0) })
    }
    public func install(in session: WeappContainerSession) throws {
        for api in ["wx.requestPayment", "weappContainer.payment.request"] { try session.registerApiHandler(api) { [weak self] call in
            guard let self else { throw WeappHostError(code: .cancelled, message: "Payment adapter retired") }
            guard let orderID = call.payload["orderId"].string,
                  ["appId", "prepayId", "paySign", "package", "orderString", "signType"].allSatisfy({ call.payload[$0] == .null }) else {
                throw WeappHostError(code: .invalidRequest, message: "Pass a backend orderId; JSAPI signatures cannot be used for native APP Pay")
            }
            guard !self.busy else { throw WeappHostError(code: .invalidRequest, message: "Another payment UI is active") }
            self.busy = true; defer { self.busy = false }
            let order = try await self.backend.launch(call, orderID: orderID)
            guard order["orderId"].string == orderID, order["product"].string == "app" else { throw WeappHostError(code: .invalidRequest, message: "Backend order is not APP Pay") }
            if order["status"].string != "paid" {
                guard let channel = self.channels[order["channel"].string ?? ""], channel.isAvailable else { throw WeappHostError(code: .unsupported, message: "Official native payment SDK is not configured") }
                try await channel.pay(order["launch"], call: call)
                var confirmed = false
                for attempt in 0...20 {
                    try Task.checkCancellation()
                    let result = try await self.backend.launch(call, orderID: orderID)
                    if result["status"].string == "paid" { confirmed = true; break }
                    if ["closed", "refunded"].contains(result["status"].string ?? "") { throw WeappHostError(code: .invalidRequest, message: "Backend reports a closed or refunded order") }
                    if attempt < 20 { try await Task.sleep(nanoseconds: 500000000) }
                }
                guard confirmed else { throw WeappHostError(code: .timeout, message: "Awaiting verified server payment confirmation", retryable: true, details: ["orderId": .string(orderID), "errMsg": .string("requestPayment:fail server confirmation pending")]) }
            }
            return .object(["orderId": .string(orderID), "serverConfirmed": .bool(true), "errMsg": .string("requestPayment:ok")])
        } }
    }
}

/// Add the official WechatOpenSDK to the host target, with its reviewed app ID and Universal Link.
/// Feed URL/Universal Link callbacks here from the host App/Scene delegate.
@MainActor public final class WeappWechatAppPay: NSObject, WeappNativeAppPayChannel {
    public let channel = "wechat"
    private let appID: String
    private let universalLink: String
    private var waiting: CheckedContinuation<Void, Error>?
    private var submitted = false
    private static var active: WeappWechatAppPay?
    public var isAvailable: Bool {
        #if canImport(WechatOpenSDK)
        return true
        #else
        return false
        #endif
    }
    public init(appID: String, universalLink: String) { self.appID = appID; self.universalLink = universalLink; super.init() }
    public func pay(_ launch: WeappJSON, call: WeappHostApiCall) async throws {
        #if canImport(WechatOpenSDK)
        guard launch["kind"].string == "wechat-app", launch["appId"].string == appID, launch["packageValue"].string == "Sign=WXPay",
              let partner = launch["partnerId"].string, let prepay = launch["prepayId"].string, let nonce = launch["nonceStr"].string,
              let time = launch["timeStamp"].string.flatMap(UInt32.init), let signature = launch["sign"].string,
              URL(string: universalLink)?.scheme == "https", Self.active == nil else { throw WeappHostError(code: .invalidRequest, message: "Invalid or busy WeChat APP Pay contract") }
        guard WXApi.registerApp(appID, universalLink: universalLink) else { throw WeappHostError(code: .unsupported, message: "WeChat application registration failed") }
        let request = PayReq(); request.partnerId = partner; request.prepayId = prepay; request.nonceStr = nonce; request.timeStamp = time; request.package = "Sign=WXPay"; request.sign = signature
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.active = self; submitted = true; waiting = continuation
            call.cancellation.onCancel { [weak self] in self?.waiting?.resume(throwing: CancellationError()); self?.waiting = nil }
            WXApi.send(request) { [weak self] accepted in Task { @MainActor in
                if !accepted { self?.finish(-1, "WeChat rejected APP payment launch") }
            } }
        }
        #else
        throw WeappHostError(code: .unsupported, message: "Link the official WechatOpenSDK in the host target")
        #endif
    }
    public func handleOpenURL(_ url: URL) -> Bool {
        #if canImport(WechatOpenSDK)
        return WXApi.handleOpen(url, delegate: self)
        #else
        return false
        #endif
    }
    public func handleUniversalLink(_ activity: NSUserActivity) -> Bool {
        #if canImport(WechatOpenSDK)
        return WXApi.handleOpenUniversalLink(activity, delegate: self)
        #else
        return false
        #endif
    }
    fileprivate func finish(_ code: Int, _ message: String) {
        guard submitted, Self.active === self else { return }; submitted = false; Self.active = nil
        let continuation = waiting; waiting = nil
        if code == 0 { continuation?.resume() }
        else { continuation?.resume(throwing: WeappHostError(code: code == -2 ? .cancelled : .invalidRequest, message: message, details: ["errCode": .number(Double(code)), "errMsg": .string("requestPayment:fail \(code == -2 ? "cancel" : message)")])) }
    }
}
#if canImport(WechatOpenSDK)
extension WeappWechatAppPay: WXApiDelegate {
    nonisolated public func onResp(_ response: BaseResp) {
        guard response is PayResp else { return }
        Task { @MainActor [weak self] in self?.finish(Int(response.errCode), response.errStr) }
    }
}
#endif

/// Add the official AlipaySDK and URL Scheme to the host target; no merchant secret is stored here.
@MainActor public final class WeappAlipayAppPay: NSObject, WeappNativeAppPayChannel {
    public let channel = "alipay"
    private let scheme: String
    private var waiting: CheckedContinuation<Void, Error>?
    private var submitted = false
    private static var active: WeappAlipayAppPay?
    public var isAvailable: Bool {
        #if canImport(AlipaySDK)
        return true
        #else
        return false
        #endif
    }
    public init(urlScheme: String) { scheme = urlScheme; super.init() }
    public func pay(_ launch: WeappJSON, call: WeappHostApiCall) async throws {
        #if canImport(AlipaySDK)
        guard launch["kind"].string == "alipay-app", let order = launch["orderString"].string, !order.isEmpty, order.utf8.count <= 65536,
              !scheme.isEmpty, Self.active == nil else { throw WeappHostError(code: .invalidRequest, message: "Invalid or busy Alipay APP Pay contract") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.active = self; submitted = true; waiting = continuation
            call.cancellation.onCancel { [weak self] in self?.waiting?.resume(throwing: CancellationError()); self?.waiting = nil }
            AlipaySDK.defaultService().payOrder(order, fromScheme: scheme) { [weak self] result in Task { @MainActor in
                self?.finish(result?["resultStatus"] as? String ?? "", result?["memo"] as? String ?? "")
            } }
        }
        #else
        throw WeappHostError(code: .unsupported, message: "Link the official AlipaySDK in the host target")
        #endif
    }
    public func handleOpenURL(_ url: URL) {
        #if canImport(AlipaySDK)
        AlipaySDK.defaultService().processOrder(withPaymentResult: url) { [weak self] result in Task { @MainActor in
            self?.finish(result?["resultStatus"] as? String ?? "", result?["memo"] as? String ?? "")
        } }
        #endif
    }
    private func finish(_ status: String, _ message: String) {
        guard submitted, Self.active === self else { return }; submitted = false; Self.active = nil
        let continuation = waiting; waiting = nil
        if ["9000", "8000", "6004"].contains(status) { continuation?.resume() }
        else { continuation?.resume(throwing: WeappHostError(code: status == "6001" ? .cancelled : .invalidRequest, message: message, details: ["errCode": .number(Double(status) ?? -1), "errMsg": .string("requestPayment:fail \(status == "6001" ? "cancel" : message)")])) }
    }
}
