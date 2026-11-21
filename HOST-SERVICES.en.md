<a id="ios-host-ability"></a>
# iOS Host Capabilities

[简体中文](HOST-SERVICES.md) · **English**

The adapters require a native runtime that matches the current host-services protocol. Before loading a pack, the host configures trusted runtime context and installs the native capabilities it needs. APIs without an installed implementation remain unsupported.

```swift
let toolkit = try WeappNativeDeviceServices(presenter: presenter,
    networkOrigins: ["https://api.example.com", "wss://api.example.com"],
    allowedMediaOrigins: ["https://media.example.com"])
try session.configureHostServices(trustedConfiguration)
try toolkit.install(in: session)
```

Load the pack afterward and keep the toolkit alive until the session closes.

The host connects operating-system permissions. App-level authorization and operating-system permissions are checked separately. APIs that are unimplemented or unavailable on the device are not registered and do not report success.

Native capabilities can be installed as needed, including managed files, HTTP/WebSocket, location and sensors, Bluetooth and beacons, camera and media, recording, NFC, Wi-Fi, clipboard, battery, window controls and system UI. Recording uses a host-provided audio-session broker so the SDK does not take over shared application audio unconditionally.

Files use a managed virtual path; guest code never receives a host filesystem path. Network access is limited by host-configured origins, request sizes and redirect policy. Device work belongs to the active session owner. Hiding, cancellation, close or owner changes stop the relevant work and wait for native resources to finish releasing before cleanup completes.

Standard mini-program APIs and business extensions share the generic registration boundary: `registerApiHandler` receives API calls and `registerHostMethod` registers host business methods. The SDK leaves application services to the host.

Validate devices, system permissions and hardware behavior on target devices. Source compilation and local simulation do not replace runtime acceptance.
