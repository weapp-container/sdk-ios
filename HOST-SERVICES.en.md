<a id="ios-宿主能力"></a>
# iOS Host ability

[简体中文](HOST-SERVICES.md) · **English**


The adapter requires a native runtime that matches the current host-services protocol. All configuration, installation, cleanup and
Host callbacks are executed on MainActor; the old preview framework does not include the new protocol.

```swift
let toolkit = try WeappNativeDeviceServices(presenter: presenter,
    networkOrigins: ["https://api.example.com", "wss://api.example.com"],
    allowedMediaOrigins: ["https://media.example.com"],
    recordingAudioSession: hostRecordingAudioBroker)
try session.configureHostServices(trustedConfiguration)
try toolkit.install(in: session)
// 此后才 load pack；宿主持有 toolkit 直至 session 关闭。
```

Trusted configuration must come from the host's verified installation and account, including the publisher, application, actual pack root,
Environment, principal and decimal epoch. Use registerHostMethod for business methods; use registerHostMethod for WeChat methods
registerApiHandler. Uninstalled methods remain unsupported.

`WeappHostServicesClient.identityState` is clearly `principalId: null` in the trusted account and epoch
is an exact decimal u64 (snapshot assist layer accepts `"0"`, public owner configuration still requires a positive number) when preparing unlogged snapshots, the revoked host bearer is no longer read. initial preparation,
The same entrance is used for number change cleaning preparation and front-end refresh; the logged-in principal must still query the real backend.
Network, permission or credential failures will continue to be passed and will not fall back to success. The snapshot does not contain old user information or phone number authorization.

`readHostApiResource(context:offset:length:)` transparently transmits the original trusted context of the resource setter,
Returns `{bytes,totalBytes}`; single block maximum 1 MiB. Check the runtime first
`hostServices.apiResourceChunks == "1.0"`, retain decimal epoch and deadline in context
and session/call ID, do not replace with transport ID. Read-only commands are still subject to runtime account, expiration and invocation
Survival check; rejected after number change, settlement, cancellation or timeout, the old runtime explicitly does not support it. it will not create
owner, enter JS or trigger surface rendering, nor grant read permission to any path.

Mini-program authorization and operating system permissions are checked separately. Even if the host has system authorization, each application and account must still
After independent native prompts; persistent records are isolated by trusted applications, issuers, accounts and epochs.
`getSetting` Do not disguise unasked scopes as authorized. The host is configured according to actual capabilities
NSCameraUsageDescription、NSMicrophoneUsageDescription、
NSLocationWhenInUseUsageDescription, NSBluetoothAlwaysUsageDescription, etc.
Info.plist entry. CoreBluetooth does not open any undiscovered peripherals and cannot be set
System MTU; unimplemented methods are not registered.

Real system services include clipboard, network status, battery, brightness, always on, vibration, native UI, and WGS84 positioning
and sensors. The sensor supports normal sampling; GCJ-02, background positioning and unimplemented system capabilities cannot be impersonated successfully.
The front-end continuous positioning uses the same CLLocationManager, providing start/stopLocationUpdate,
on/offLocationChange and on/offLocationChangeError; the mini-program is hidden or the application enters the background and is paused.
Return to the front desk and press the original owner to restore, change the number and close the subscription to delete it. A single positioning is completed and continues to be valid without stopping.
Positioning, native callbacks retain only the latest location/error, serial delivery bounded subscription.
The

toolkit has files, devices, BLE, media, network, recording and system adapters in one place, and can also be installed independently.
`try await session.close()` Wait for native cleanup before releasing the core and file lease; concurrent close
Sharing the same operation, you can try again after failure. If the asynchronous cleanup of deinit fails, the owner will be retained, which can be passed
`WeappContainerSession.failedFinalResourceCleanups` View and call
`await WeappContainerSession.retryFinalResourceCleanups()` Retry and release after success.

Network uses independent ephemeral URLSession, supports HTTP, managed multipart uploads/downloads,
response-header/chunk/progress events and WebSocket. Host listed exact HTTPS/WSS origin; no shared hosts
Cookie/cache, does not follow redirects, explicit development options only allow loopback HTTP/WS. HTTP response with
Ordinary request body 1 MiB, upload/download files 8 MiB, socket message 1 MiB. serial delegate pair
Bounded data is delivered to the main thread event synchronously; cancel waiting for the real didComplete, the socket must also receive the coroutine
ends before completing the cleanup ACK of number change or shutdown.

Recordings are only registered if the host provides `WeappRecordingAudioSession`. audio broker decision
How to coexist with the host’s existing AVAudioSession; only select it when it is clear that there is no other audio owner
`WeappExclusiveRecordingAudioSession()`. Default nil does not take over host shared audio.
RecorderManager uses real AVAudioRecorder, separate mini-program/OS authorization, supports AAC m4a,
100–60000ms, up to 4 MiB, default 8000Hz, two-channel, 48000bps, 60000ms. Support official nine gears
8000–48000Hz, verify the official encoding bit rate range according to each sampling rate; only accept auto audioSource,
default audioMode, other input sources, modes and frameSize are explicitly rejected. After completion
Import managed files. hiding, backgrounding, and account changes stop recording; when audio lease recovery or staging deletion fails
Reserve resources for retry.
Check the requested sampling rate and channel in the real format of AVAudioFile before importing, when the native encoder is downgraded
Issue an Error and refuse to deliver the file to avoid treating a recording in a different format as a successful result.

Configuration and actual injection of address book, calendar, VisionKit/photo-based scanning, CoreNFC NDEF and trusted SOTER
For support range, see [System Capabilities](examples/host-services/SYSTEM-APIS.en.md). NFC explicit only
Installed when `enableNfc: true` is configured with device, Info.plist and entitlement; SOTER signer
Always injected by the native host.

iBeacon is actually provided by the independent CLLocationManager ranging from start/stopBeaconDiscovery,
getBeacons, on/offBeaconUpdate and on/offBeaconServiceChange. Only if the device supports ranging,
Installed when declaring location and Bluetooth usage at the same time; operations also require separate mini-program location/Bluetooth authorization, precise location at the front desk
OS permissions and available Bluetooth status. ignoreBluetoothAvailable is only allowed to be ignored according to the official contract
poweredOff, does not bypass the system to deny authorization. Up to 20 UUIDs, 64 latest readings per UUID, for guest
Maximum of 64 results and 32 subscriptions. proximity/accuracy/rssi from CLBeacon, unknown
accuracy is -1. hiding/backgrounding stops its own ranging, foreground recovery; create an independent manager for each recovery,
Late callbacks cannot enter the new generation or new accounts. getBeacons explicitly reports 11004 when the search is not started.

Wi-Fi is not installed by default. The host passes in `wifiConfiguration` according to the real signature capabilities, public
See joinOnce/current SSID subset, partial message contracts, and iOS scan restrictions
[Wi-Fi Access](examples/host-services/WIFI-APIS.en.md).

`WeappManagedFiles` provides basic asynchronous file methods and the managed `wxfile://user/` path. sync
The FileSystemManager method is executed directly by the core, and both parties use the same directory and real flock operation lock. The maximum read and write block size is 1 MiB, a single file is 8 MiB, and a single account application is 32 MiB. write wait
Atomic replacement and file synchronization; guest rejects and hides `.weapp-*` internal lock file; guest never gets the native path of Application Support.
SDK always sets app-private `managedFilesRoot` when creating native session, independent of key-value storage
Configuration. Files and authorization records only use core `managedFileScope` returned by the runtime and verified against the application/account identity
`root` and `auxiliaryRoot`; retain the shared lease until resource cleanup is complete. Account deletion calls core uniformly
`deleteAccountData`, removes files and authorization records after cleaning up ACK and surface detach.

The camera obtains real frames through AVCaptureVideoDataOutput, and the video passes AVPlayerItemVideoOutput
Decoding. 320×240, up to 5 fps RGBA preview enters the original Skia PaintPlan corresponding node and continues to be used
Realistic cropping, transformations, levels and transparency, using bounded latest frame queue, no floating players or overlays created
The entire container. Video only accepts managed files and explicitly allowed HTTPS origins. Context creation requires runtime
Issued componentTarget. Taking photos saves the current captured frame and does not provide independent high-resolution still shooting.
Live broadcast, DRM, recording, full screen, barrage and camera-by-camera original frame subscription have not been implemented yet, and the corresponding APIs are not registered.
Background, node unloading, number change and close stop the stream, player and old objects.

Reference identity service reads the host’s existing security credentials through native closure:

```swift
let backend = try WeappHostServicesClient(endpoint: URL(string: "https://accounts.example.com")!) {
    call in try secureHostSession.token(for: call.context)
}
let identity = WeappHostIdentity(presenter: presenter, backend: backend)
let prepared = try await identity.prepareConfiguration(trustedConfiguration)
try session.configureHostServices(prepared)
try identity.install(in: session)
// 配置和安装完成后再 load。
```

Backend error handling container classification `code/message` separately from public API fields. `code/message`
Only accepts non-empty strings; public fields are envelope, envelope.details, error.details, error
The order of
is merged, with subsequent non-null values overwriting the previous values, excluding the structure key `code/message/error/details`.
Original `errCode/errMsg` and extended fields retained to `WeappHostError.details`; missing errCode
and missing, blank or non-string errMsg only use the adapter default value. Five canonical classifications and correspondences
Uppercase `ERR_*` retains the typed category; consent/session misidentifies as permission_denied,
core’s `ERR_UNSUPPORTED_CAPABILITY` and `unsupported_capability` are both classified as unsupported.
Unknown error classified as invalid_request. iOS If the existing `backendCode` field is still missing, fill in the original
Classification string, does not cover the public fields returned by the service. Run `npm run test:host-backend-error`
May actually perform Swift parsing and JSON codec regression; it does not represent native Session/JS or device acceptance.

The application backend uses an independent confidential client to redeem short-term, one-time codes bound to app/pack.
The applet cannot obtain the host bearer and application backend keys. The mobile phone number and nickname avatar are prompted and authorized respectively.
The native prompt first obtains the authorization policy from the trusted backend, displays the registration purpose, and binds it in the authorization and code
purpose and permissionVersion. guest desc does not determine usage; refuses to synchronize the server and refresh the status,
Cancellation is still treated as cancellation, and server-side policy changes invalidate the old authorization.
`wx.checkSession` checks the actual redeemed application session. The issuing code itself will not change appLoggedIn
Set to true. Called by the host after redemption, rights withdrawal, credential refresh and front-end recovery
`identity.refreshState(in:trustedContext:)`, updates synchronized with getState and onChange.
Refresh reads native state before backend request, checks trusted application/account and freezes actual internals
sessionId; Only ready owner can start the refresh, switching or empty owner will directly reject it.
After the response is completed, the same identity will continue to be used and will not be reposted to a new owner. API callback raw
ApiCallContext continues transparent transmission, the runtime uses the complete application/package identity, account epoch and internal sessions reject old snapshots;
Manual native refresh does not need to be disguised as a pending API call.
Before initiating asynchronous identity refresh and when submitting a snapshot with context, the SDK requires a runtime statement
`hostServices.snapshotOwnerContext == "1.0"`; if missing, report
`ERR_UNSUPPORTED_CAPABILITY`, does not allow the old runtime to silently ignore the owner check field.
The account change cleanup hook should prepare new host credentials first and then wait.
`identity.prepareAccountState(in:operationID:trustedContext:)`, finally returns cleanup success;
The old account snapshot cannot be used for the new owner.

Continuous number changes will cancel the Task of the old operation, but the next round of cleanup will still wait for the actual termination of the old Task before executing it.
Current hook and ACK. Stale operations that have not yet started are skipped; close waits for the complete queue including stale tasks.
The host hook must return after the exact device, file and background task are actually released, and the issue cannot be canceled.
The request is treated as release completed. `node tools/test-account-cleanup.mjs` in Swift's actual concurrent dispatch
Verification of old cleanup lateness, cancellation, continuous number changes, retries, and closing barriers; it does not constitute equipment acceptance.

`WeappAppPayments` registers `wx.requestPayment` and `weappContainer.payment.request` at the same time, and only accepts orderId from the server. The official channel is
WeappWechatAppPay(appID:universalLink:) and WeappAlipayAppPay(urlScheme:); Official SDK
Must be used as the actual visible dependency of the integration target. When canImport is not established, the channel is clearly unavailable. SPM host
You can also implement WeappNativeAppPayChannel in your own target; only link one in the host target
library does not automatically enable another independent target to import it. Host processing official URL/Universal Link
Callback, after server verification and order ownership, amount, merchant and transaction verification, paid is confirmed, and then the payment is reported as successful.
Cancellation of waiting does not mean refund or transaction closure.

Official public header files WechatOpenSDK 2.0.9 and AlipaySDK-iOS 15.8.30 have been used for Swift types
Check and verify the called selectors and fields. Type checking, back-end local testing, and source code listings do not mean that they have been
Link to run the official wallet or complete real merchant, camera, peripheral and account switching acceptance.
<a id="编译验证记录"></a>
## Compilation verification record

[Current development record](test/evidence/host-services-development.json) records the complete Swift module and
The source code hash of `ReferenceHostServices.swift`, as well as the actual WeChat OpenSDK 2.0.9, Alipay
15.8.30 Official package sources and hashes. This round launches the production module with `arm64-apple-ios16.0-simulator`,
Enable the `canImport` branch of the two official SDKs, and then compile examples for this module, but there is no compilation diagnosis.
This is compilation proof; actual iOS binary linking, device interaction, camera/Bluetooth, official wallet and merchant transactions are still required
Corresponding operation verification.

[Front-end positioning and authorization policy compilation record](test/evidence/host-services-location-policy-development.json)
Separately bind all the Swift source codes and samples produced in this batch, and completely launch the module when the official payment header file is visible.
Compiled example without diagnostics; actual interaction of iOS locating subscriptions with the authorization UI is still pending run acceptance.

[Beacon and recording compilation record](test/evidence/host-services-beacon-recorder-development.json)
Keep the source code hashes and zero diagnostic logs of this batch of complete modules and samples. Real Beacon, permission conversion,
Front and backend ranging and iOS microphone recording are still to be independently run and accepted.
Completed and unreserved host calls will release the capture object of the setup cancellation callback, and calls that reserve resources will still
Wait for cancellation, if failed, run a cleanup; `tools/test-host-cancellation.mjs` uses actual Swift
Weak references check these three life cycle boundaries.

Native snapshot owner validation belongs to the negotiated runtime. The SDK passes the complete captured context unchanged and preserves the runtime error, including `ERR_CANCELLED` for a retired owner; it updates its rebuild cache only after successful validation. A credential refresh cannot replace this owner check.
