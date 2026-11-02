import Foundation
import UIKit
import CryptoKit

/// Persistent app consent is separate from the process-wide OS permission state.
@MainActor final class WeappAppPermissionConsent {
    private let presenter: () -> UIViewController?
    private let auxiliaryRoot: (WeappJSON) throws -> URL
    private var pending: [String: () -> Void] = [:]
    init(presenter: @escaping () -> UIViewController?, auxiliaryRoot: @escaping (WeappJSON) throws -> URL) { self.presenter = presenter; self.auxiliaryRoot = auxiliaryRoot }
    private func key(_ call: WeappHostApiCall, _ scope: String) throws -> String {
        let app = call.context["application"], account = call.context["account"]
        let fields = ["hostAppId", "tenantId", "publisherId", "appId", "environment"].map { app[$0] }
        guard fields.allSatisfy({ $0.string?.isEmpty == false }), account["epoch"] != .null else { throw WeappHostError(code: .permissionDenied, message: "Trusted native permission scope required") }
        let owner = fields + [account["principalId"], account["epoch"], .string(scope)] + (account["principalId"] == .null ? [call.context["sessionId"]] : [])
        return "consent-" + SHA256.hash(data: try JSONEncoder().encode(WeappJSON.array(owner))).map { String(format: "%02x", $0) }.joined()
    }
    private func record(_ call: WeappHostApiCall, _ scope: String) throws -> URL {
        let root = try auxiliaryRoot(call.context).resolvingSymlinksInPath()
        let file = root.appendingPathComponent(try key(call, scope) + ".json").resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == root else { throw WeappHostError(code: .permissionDenied, message: "Consent record escaped native scope") }; return file
    }
    private func read(_ record: URL) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: record.path) else { return nil }
        let text = try String(contentsOf: record, encoding: .utf8)
        guard text == "true" || text == "false" else { throw WeappHostError(code: .invalidRequest, message: "Invalid native consent record") }; return text == "true"
    }
    private func write(_ record: URL, _ granted: Bool) throws {
        try Data((granted ? "true" : "false").utf8).write(to: record, options: .atomic)
        let handle = try FileHandle(forWritingTo: record); defer { try? handle.close() }; try handle.synchronize()
    }
    func setting(_ call: WeappHostApiCall, _ scope: String, osGranted: Bool) -> Bool? {
        guard let record = try? record(call, scope), let granted = try? read(record) else { return nil }
        return granted && osGranted
    }
    func request(_ call: WeappHostApiCall, _ scope: String) async throws -> Bool {
        try Task.checkCancellation()
        guard !call.cancellation.isCancelled else { throw CancellationError() }
        let record = try record(call, scope)
        if try read(record) == true { return true }
        guard let presenter = presenter(), presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw WeappHostError(code: .permissionDenied, message: "Visible idle presenter required for app permission") }
        return try await withCheckedThrowingContinuation { continuation in
            var settled = false
            let app = call.context["application"]
            let alert = UIAlertController(title: "小程序权限申请", message: "\(app["appId"].string ?? "")（\(app["publisherId"].string ?? "")）申请使用 \(scope)。此授权仅适用于当前账号和此小程序。", preferredStyle: .alert)
            let finish: (Result<Bool, Error>, Bool) -> Void = { [weak self] result, remember in
                guard !settled else { return }; settled = true; self?.pending.removeValue(forKey: call.id)
                alert.dismiss(animated: false)
                if remember, case .success(let granted) = result {
                    do { guard let self else { throw CancellationError() }; try self.write(record, granted) }
                    catch { continuation.resume(throwing: error); return }
                }
                continuation.resume(with: result)
            }
            alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in finish(.success(true), true) })
            alert.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in finish(.success(false), true) })
            pending[call.id] = { finish(.failure(CancellationError()), false) }
            call.cancellation.onCancel { finish(.failure(CancellationError()), false) }
            presenter.present(alert, animated: true)
        }
    }
    func reset() { let actions = Array(pending.values); pending.removeAll(); for action in actions { action() } }
}
