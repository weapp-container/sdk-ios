import Foundation

@main struct SystemApiPayloadTests {
    static func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: \(label)") }
        catch { precondition(error is WeappHostError, "\(label): wrong error \(error)") }
    }
    static func buffer(_ values: [WeappJSON], type: String = "ArrayBuffer") -> WeappJSON { .object(["__weappBinary": .object(["bytes": .array(values), "type": .string(type)])]) }
    static func main() throws {
        let bytes = try WeappSystemApiPayloads.binary(buffer([.number(0), .number(255), .number(17)]))
        precondition(bytes == Data([0, 255, 17]))
        for value in [WeappJSON.number(-1), .number(256), .number(0.5), .number(.infinity), .string("7")] {
            rejects("unrepresentable NDEF byte") { _ = try WeappSystemApiPayloads.binary(buffer([value])) }
        }
        rejects("wrong native binary type") { _ = try WeappSystemApiPayloads.binary(buffer([.number(7)], type: "Uint8Array")) }
        rejects("per-operation byte budget") { _ = try WeappSystemApiPayloads.binary(buffer([.number(0), .number(1)]), limit: 1) }

        let start = 1735689600.0
        let same = try WeappSystemApiPayloads.calendarTimes(.object(["startTime": .number(start)]))
        precondition(same.start == start && same.end == start)
        let stringEnd = try WeappSystemApiPayloads.calendarTimes(.object(["startTime": .number(start), "endTime": .string(String(start + 60))]))
        precondition(stringEnd.end == start + 60)
        for end in [WeappJSON.string("invalid"), .number(start - 1), .number(.infinity), .number(253402300800)] {
            rejects("invalid calendar end must not default to success") { _ = try WeappSystemApiPayloads.calendarTimes(.object(["startTime": .number(start), "endTime": end])) }
        }

        let proof = #"{"raw":"app-order-42","counter":1}"#, signature = Data([1, 2, 3]).base64EncodedString()
        try WeappSystemApiPayloads.attestation(resultJSON: proof, signature: signature, challenge: "app-order-42")
        rejects("cross-order attestation replay") { try WeappSystemApiPayloads.attestation(resultJSON: proof, signature: signature, challenge: "app-order-43") }
        rejects("invalid signature encoding") { try WeappSystemApiPayloads.attestation(resultJSON: proof, signature: "!bad", challenge: "app-order-42") }
        rejects("non-object attestation") { try WeappSystemApiPayloads.attestation(resultJSON: "[]", signature: signature, challenge: "app-order-42") }
        rejects("over-budget challenge") { try WeappSystemApiPayloads.attestation(resultJSON: proof, signature: signature, challenge: String(repeating: "x", count: 4097)) }
        print("System API payload boundaries passed (binary, calendar, attestation). Native UI/hardware acceptance is separate.")
    }
}
