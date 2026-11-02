import Foundation

/// Query partialInfo on iOS includes BSSID; the partial connection event is SSID-only.
enum WeappWifiPayloads {
    static func partialNetwork(ssid: String, bssid: String) throws -> WeappJSON {
        let normalized = bssid.lowercased()
        guard !ssid.isEmpty, (1...32).contains(ssid.utf8.count), !ssid.contains("\0"),
              normalized.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil,
              !["00:00:00:00:00:00", "02:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"].contains(normalized) else {
            throw WeappHostError(code: .permissionDenied, message: "OS current Wi-Fi identifiers are unavailable or redacted", details: ["errMsg": .string("wx.getConnectedWifi:fail OS current Wi-Fi identifiers are unavailable or redacted"), "errCode": .number(12007)])
        }
        return .object(["SSID": .string(ssid), "BSSID": .string(bssid)])
    }
}
