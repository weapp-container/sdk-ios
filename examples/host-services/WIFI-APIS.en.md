<a id="ios-wi-fi-公共能力范围"></a>
# iOS Wi-Fi public capability range

[简体中文](WIFI-APIS.md) · **English**


SDK Wi-Fi is not installed by default. The host needs to be configured explicitly:

```swift
let wifi = WeappWifiConfiguration(connectToNetworks: true, readCurrentNetwork: true)
let toolkit = try WeappNativeDeviceServices(presenter: presenter, wifiConfiguration: wifi)
```

Host target requires Access Wi-Fi Information with real signature
(`com.apple.developer.networking.wifi-info`); Hotspot Configuration is also required for connection.
(`com.apple.developer.networking.HotspotConfiguration`). The configuration Boolean value only determines the SDK range selected by the host and does not participate in entitlement verification. The actual `NEHotspotConfigurationManager / fetchCurrent` is executed by the OS for signature and qualification checking. If missing, it will fail or return nil, and authorization will not be disguised.

`Info.plist` must declare `NSLocationWhenInUseUsageDescription`; the location consent of the independent applet is independently verified with the precise location authorization of the OS front desk. The current network and other qualification conditions that the system allows the app to configure cannot replace the SDK authorization boundary for the mini-program.

| API | Public implementation and limitations |
| --- | --- |
| startWifi / stopWifi | Initialize/stop the service of the current owner; do not turn off the system switch. stop retains independently registered subscriptions. |
| getConnectedWifi | Required `partialInfo:true`, returns the real SSID, BSSID of `fetchCurrent`. Explicit failure on nil, null, or privacy placeholder BSSID. |
| onWifiConnectedWithPartialInfo / offWifiConnectedWithPartialInfo | `NWPathMonitor` Triggers a bounded query, reporting real SSID changes to the frontend; up to 32 subscriptions. |
| connectWifi | After each native confirmation, the open/WPA/WPA2 configuration is actually applied and `joinOnce=true` is fixed. Actual SSID must be confirmed by `fetchCurrent` for association to succeed; wait up to 10 seconds for association. Successful configuration itself does not equal successful connection. |

BSSID directional connection, manual jump system Wi-Fi settings, WEP/enterprise are not within the scope of this adapter. Does not overwrite the host's existing configuration. When canceled or failed, the newly created configuration of this adapter will be deleted; number change and shutdown wait for the real apply callback that is still in progress, and then remove its own configuration. It cannot ACK in advance to avoid the late connection of the old owner being accessed by the new owner. The life cycle of system `joinOnce` is still managed by the OS.

The following methods or complete data are not applicable within the scope of the general iOS container, and the corresponding false implementation is not registered:

- `getWifiList`, `onGetWifiList`, `offGetWifiList`, `setWifiList`: No universal Wi-Fi scanning API.
HotspotHelper requires Apple entitlement and only allows hotspot integration; cannot be used with ordinary accessories, locations, or any scanning scenarios.
- `onWifiConnected`, `offWifiConnected` and complete `getConnectedWifi` data: public `fetchCurrent` is only guaranteed to be valid for SSID, BSSID, securityType; frequency has no public field, signalStrength belongs to the HotspotHelper category, and its default value on the `fetchCurrent` object cannot be considered a real measurement. Currently uses the `partialInfo` contract, which does not speculate on signals or frequencies.

Official source:

- [Apple TN3111: iOS Wi-Fi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview): No general scanning API; HotspotHelper usage restrictions; temporary addition to use `joinOnce`.
- [NEHotspotNetwork.fetchCurrent](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:): Signature entitlement and calling qualification.
- [NEHotspotConfiguration.joinOnce](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce): Temporary configuration.

Development records also retain read Xcode official header SHA, TN3111 original JSON SHA and complete module compilation evidence. The iOS app with real signature entitlements, system connection confirmation, AP association, SSID reading, front-end and back-end recovery, or number change cleanup have not yet been run, and the source code/compilation cannot be regarded as acceptance of these operations.
