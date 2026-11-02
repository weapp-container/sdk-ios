import Foundation

@main struct WifiPayloadTests {
    static func main() throws {
        let valid = try WeappWifiPayloads.partialNetwork(ssid: "网络", bssid: "AA:13:10:85:FE:01")
        precondition(valid == .object(["SSID": .string("网络"), "BSSID": .string("AA:13:10:85:FE:01")]))
        for (ssid, bssid) in [("", "aa:13:10:85:fe:01"), ("wifi", ""), ("wifi", "not-a-mac"), ("wifi", "02:00:00:00:00:00"), ("wifi", "00:00:00:00:00:00"), ("wifi", "FF:FF:FF:FF:FF:FF"), (String(repeating: "a", count: 33), "aa:13:10:85:fe:01")] {
            do { _ = try WeappWifiPayloads.partialNetwork(ssid: ssid, bssid: bssid); preconditionFailure("Invalid or redacted native identifier escaped") }
            catch let error as WeappHostError { precondition(error.code == .permissionDenied && error.details["errCode"] == .number(12007)) }
        }
        print("iOS partial query preserves real SSID+BSSID and rejects absent, malformed or privacy-redacted identifiers")
    }
}
