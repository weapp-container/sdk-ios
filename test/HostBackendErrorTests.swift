import Foundation

@main struct HostBackendErrorTests {
    static func decode(_ text: String) throws -> WeappJSON {
        try JSONDecoder().decode(WeappJSON.self, from: Data(text.utf8))
    }

    // Exercise the real SDK JSON codec with the typed error's final public fields.
    // This finite codec regression does not claim native Session or JS execution.
    static func serialized(_ error: WeappHostError) throws -> WeappJSON {
        let value: WeappJSON = .object([
            "code": .string(error.code.rawValue), "message": .string(error.message),
            "retryable": .bool(error.retryable), "details": .object(error.details),
        ])
        return try JSONDecoder().decode(WeappJSON.self, from: JSONEncoder().encode(value))
    }

    static func main() throws {
        let plain = WeappHostBackendError(try decode("""
            {"error":"invalid_app_session","message":"expired","errCode":4017,
             "errMsg":"login:fail expired","traceId":"trace-1"}
            """))
        precondition(plain.code == "invalid_app_session" && plain.message == "expired")
        let plainWire = try serialized(plain.project(api: "wx.login"))
        precondition(plainWire["code"] == .string("permission_denied"))
        precondition(plainWire["details"]["errCode"] == .number(4017))
        precondition(plainWire["details"]["errMsg"] == .string("login:fail expired"))
        precondition(plainWire["details"]["traceId"] == .string("trace-1"))
        precondition(plainWire["details"]["backendCode"] == .string("invalid_app_session"))

        let nested = WeappHostBackendError(try decode("""
            {"code":"envelope-code","message":"envelope message","errCode":10,
             "errMsg":"envelope:fail","requestId":"request-1","collision":"envelope","fromEnvelopeDetails":0,
             "details":{"collision":"envelope-details","envelopeDetails":true,"fromEnvelopeDetails":1,"detailsCollision":"envelope-details"},
             "error":{"code":"consent_required","message":"consent required","errCode":4017,
                "errMsg":"login:fail custom backend message","collision":"nested","nullKeeps":null,
                "backendCode":"provider-backend","vendor":{"retryAfter":20,"items":[1,false,"public"]},
                "details":{"collision":"nested-details","provider":"identity-provider","errCode":12,
                    "fromEnvelopeDetails":null,"nullKeeps":"kept","fromNestedDetails":true,"detailsCollision":"nested-details"}}}
            """))
        precondition(nested.code == "consent_required" && nested.message == "consent required")
        let projected = nested.project(api: "wx.login")
        let nestedWire = try serialized(projected)
        precondition(nestedWire["code"] == .string("permission_denied"))
        precondition(nestedWire["message"] == .string("consent required"))
        precondition(nestedWire["details"]["errCode"] == .number(4017))
        precondition(nestedWire["details"]["errMsg"] == .string("login:fail custom backend message"))
        precondition(nestedWire["details"]["collision"] == .string("nested"))
        precondition(nestedWire["details"]["requestId"] == .string("request-1"))
        precondition(nestedWire["details"]["provider"] == .string("identity-provider"))
        precondition(nestedWire["details"]["envelopeDetails"] == .bool(true))
        precondition(nestedWire["details"]["fromEnvelopeDetails"] == .number(1))
        precondition(nestedWire["details"]["detailsCollision"] == .string("nested-details"))
        precondition(nestedWire["details"]["fromNestedDetails"] == .bool(true))
        precondition(nestedWire["details"]["nullKeeps"] == .string("kept"))
        precondition(nestedWire["details"]["backendCode"] == .string("provider-backend"))
        precondition(nestedWire["details"]["vendor"]["items"] == .array([.number(1), .bool(false), .string("public")]))
        for key in ["code", "message", "error", "details"] { precondition(projected.details[key] == nil) }
        var receiver = projected.details; receiver["provider"] = .string("changed")
        precondition(nested.details["provider"] == .string("identity-provider"))

        let detailsOnly = WeappHostBackendError(try decode("""
            {"error":{"details":{"errCode":4017,"errMsg":"checkSession:fail provider"}}}
            """))
        precondition(detailsOnly.code == "ERR_HOST_SERVICES")
        precondition(detailsOnly.message == "checkSession:fail provider")
        let detailsWire = try serialized(detailsOnly.project(api: "wx.checkSession"))
        precondition(detailsWire["code"] == .string("invalid_request"))
        precondition(detailsWire["details"]["errCode"] == .number(4017))
        precondition(detailsWire["details"]["errMsg"] == .string("checkSession:fail provider"))

        for wire in ["invalid_request", "permission_denied", "timeout", "cancelled", "unsupported"] {
            for code in [wire, "ERR_" + wire.uppercased()] {
                let payload: WeappJSON = .object(["error": .object([
                    "code": .string(code), "message": .string("classified backend failure"),
                    "errCode": .number(4017), "errMsg": .string("login:fail provider original"),
                    "providerId": .string("identity-provider"),
                ])])
                let backend = WeappHostBackendError(try JSONDecoder().decode(WeappJSON.self, from: JSONEncoder().encode(payload)))
                let error = try serialized(backend.project(api: "wx.login"))
                precondition(error["code"] == .string(wire), "\(code) lost its container classification")
                precondition(error["details"]["errCode"] == .number(4017))
                precondition(error["details"]["errMsg"] == .string("login:fail provider original"))
                precondition(error["details"]["providerId"] == .string("identity-provider"))
            }
        }
        for code in ["unsupported_capability", "ERR_UNSUPPORTED_CAPABILITY"] {
            let backend = WeappHostBackendError(try decode("""
                {"error":{"code":"\(code)","message":"Runtime capability unavailable",
                    "errCode":4017,"errMsg":"login:fail provider original","capability":"identity"}}
                """))
            let error = try serialized(backend.project(api: "wx.login"))
            precondition(error["code"] == .string("unsupported"), "\(code) lost the core unsupported classification")
            precondition(error["details"]["errCode"] == .number(4017))
            precondition(error["details"]["errMsg"] == .string("login:fail provider original"))
            precondition(error["details"]["capability"] == .string("identity"))
        }
        for alias in ["consent_required", "invalid_host_session", "invalid_app_session", "host_identity_mismatch", "stale_principal"] {
            for code in [alias, "ERR_" + alias.uppercased()] {
                let error = WeappHostBackendError(.object(["error": .string(code)])).project(api: "wx.login")
                precondition(error.code == .permissionDenied && error.details["errCode"] == .number(2001))
            }
        }

        for bad in [WeappJSON.object([:]), .array([]), .null, .bool(false), .number(4017), .string(""), .string(" \n\t")] {
            let backend = WeappHostBackendError(.object(["error": bad, "code": .null, "message": bad]))
            precondition(backend.code == "ERR_HOST_SERVICES" && backend.message == "Host services request failed")
            let error = try serialized(backend.project(api: "wx.login"))
            precondition(error["code"] == .string("invalid_request"))
            precondition(error["details"]["errCode"] == .number(-1))
            precondition(error["details"]["errMsg"] == .string("wx.login:fail Host services request failed"))
        }
        let unknown = WeappHostBackendError(.object(["error": .string("unknown_provider_code")])).project(api: "wx.login")
        precondition(unknown.code == .invalidRequest && unknown.details["errCode"] == .number(-1))

        let nullOverride = WeappHostBackendError(try decode("""
            {"code":"timeout","message":"fallback message","errCode":0,"errMsg":"provider:fail original",
             "error":{"code":null,"message":"  ","errCode":null,"errMsg":null}}
            """))
        let nullError = nullOverride.project(api: "wx.login")
        precondition(nullError.code == .timeout && nullError.message == "fallback message")
        precondition(nullError.details["errCode"] == .number(0))
        precondition(nullError.details["errMsg"] == .string("provider:fail original"))

        for emptyMessage in [WeappJSON.null, .string(""), .string(" \n\t"), .number(1)] {
            let error = WeappHostBackendError(.object([
                "error": .string("invalid_app_session"), "message": .string("expired"),
                "errCode": .null, "errMsg": emptyMessage,
            ])).project(api: "wx.login")
            precondition(error.code == .permissionDenied && error.details["errCode"] == .number(2001))
            precondition(error.details["errMsg"] == .string("wx.login:fail expired"))
        }
        let stringCode = WeappHostBackendError(.object([
            "error": .string("timeout"), "errCode": .string("provider-error"), "errMsg": .string("original"),
        ])).project(api: "wx.login")
        let stringCodeWire = try serialized(stringCode)
        precondition(stringCodeWire["details"]["errCode"] == .string("provider-error"))
        print("iOS backend errors preserve typed container categories, non-null extension precedence and original API fields through the real Swift JSON codec.")
    }
}
