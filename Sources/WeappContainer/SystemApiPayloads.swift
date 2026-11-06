import Foundation

/// Validation shared by the native system adapters. No UI, filesystem or
/// platform authorization is performed by these pure conversions.
enum WeappSystemApiPayloads {
    static func binary(_ value: WeappJSON, limit: Int = 1024 * 1024) throws -> Data {
        guard value["__weappBinary"]["type"].string == "ArrayBuffer", let values = value["__weappBinary"]["bytes"].array, values.count <= limit else { throw invalid("bounded ArrayBuffer required") }
        var bytes = Data(); bytes.reserveCapacity(values.count)
        for value in values { guard let n = value.number, n.isFinite, (0...255).contains(n), n.rounded() == n else { throw invalid("invalid binary byte") }; bytes.append(UInt8(n)) }
        return bytes
    }
    static func calendarTimes(_ value: WeappJSON) throws -> (start: Double, end: Double) {
        guard let start = value["startTime"].number else { throw invalid("startTime required") }
        let end: Double
        if value["endTime"] == .null { end = start }
        else if let n = value["endTime"].number { end = n }
        else if let s = value["endTime"].string, let n = Double(s) { end = n }
        else { throw invalid("invalid endTime") }
        guard start.isFinite, end.isFinite, (-62135596800...253402300799).contains(start), (-62135596800...253402300799).contains(end), end >= start else { throw invalid("calendar dates out of range or reversed") }
        return (start, end)
    }
    static func attestation(resultJSON: String, signature: String, challenge: String) throws {
        guard !challenge.isEmpty, challenge.utf8.count <= 4096, resultJSON.utf8.count <= 65536, signature.utf8.count <= 16384,
              let bytes = resultJSON.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], json["raw"] as? String == challenge,
              let signatureBytes = Data(base64Encoded: signature), !signatureBytes.isEmpty else { throw invalid("signer returned an invalid or mismatched attestation") }
    }
    private static func invalid(_ reason: String) -> WeappHostError { WeappHostError(code: .invalidRequest, message: reason) }
}
