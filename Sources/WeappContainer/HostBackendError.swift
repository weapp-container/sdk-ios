import Foundation

/// Container classification and public API error fields use separate namespaces.
struct WeappHostBackendError {
    let code: String
    let message: String
    let details: [String: WeappJSON]

    init(_ response: WeappJSON) {
        let nested = response["error"]
        code = Self.text(nested["code"]) ?? Self.text(response["code"])
            ?? Self.text(nested) ?? "ERR_HOST_SERVICES"
        var fields: [String: WeappJSON] = [:]
        let structural = Set(["code", "message", "error", "details"])
        // Higher-priority non-null values win without flattening extension objects.
        for source in [response, response["details"], nested["details"], nested] {
            for (key, value) in source.dictionary where !structural.contains(key) && value != .null {
                fields[key] = value
            }
        }
        details = fields
        message = Self.text(nested["message"]) ?? Self.text(response["message"])
            ?? Self.text(fields["errMsg"] ?? .null) ?? "Host services request failed"
    }

    func project(api: String) -> WeappHostError {
        let normalized = (code.hasPrefix("ERR_") ? String(code.dropFirst(4)) : code).lowercased()
        let classification: WeappHostError.Code
        switch normalized {
        case "permission_denied", "consent_required", "invalid_host_session", "invalid_app_session", "host_identity_mismatch", "stale_principal":
            classification = .permissionDenied
        case "timeout": classification = .timeout
        case "cancelled": classification = .cancelled
        case "unsupported", "unsupported_capability": classification = .unsupported
        default: classification = .invalidRequest
        }
        var fields = details
        if Self.text(fields["errMsg"] ?? .null) == nil { fields["errMsg"] = .string("\(api):fail \(message)") }
        if fields["errCode"] == nil || fields["errCode"] == .null {
            fields["errCode"] = .number(classification == .permissionDenied ? 2001 : -1)
        }
        // This field was already public in the iOS adapter. Provider fields win.
        if fields["backendCode"] == nil { fields["backendCode"] = .string(code) }
        return WeappHostError(code: classification, message: message, details: fields)
    }

    private static func text(_ value: WeappJSON) -> String? {
        guard let value = value.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
