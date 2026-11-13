<a id="原生系统-api"></a>
# Native System API

[简体中文](SYSTEM-APIS.md) · **English**


`WeappSystemApis` is installed uniformly by `WeappNativeDeviceServices`, and may also be installed independently after a trusted host is configured and prior to loading a mini-program. Contact management, calendar, camera scanning, and NFC functions all utilize system UI or native frameworks; passing compilation does not constitute validation on actual devices.

| Capability | Native Implementation and Configuration | Boundary |
| --------- | ---------------------------------------- | -------- |
| `wx.addPhoneContact` | ContactsUI new contact editor; `NSContactsUsageDescription`; image access via shared `WeappManagedFiles` using virtual paths of the current account | Successful only after user saves; cancellation returns cancellation. Custom notes/WeChat-specific fields are explicitly denied. |
| `wx.addPhoneCalendar` / `wx.addPhoneRepeatCalendar` | EventKitUI editor; iOS 17+ uses write authorization and `NSCalendarsWriteOnlyAccessUsageDescription`, iOS 16 uses `NSCalendarsUsageDescription` | Supports daily, weekly, monthly, and yearly recurrence and reminders; WeChat signature URL redirection requires additional host URL adapter configuration. |
| `wx.scanCode` | VisionKit for camera recognition, PhotosUI for image selection passed to Vision; camera requires `NSCameraUsageDescription`, system authorization, and supported hardware | QR codes, common barcodes, Data Matrix, PDF417; WeChat mini-program QR codes require official decoder; spoofing as QR is not permitted. |
| NFC / NDEF Object | `enableNfc: true`, physical hardware, `NFCReaderUsageDescription`, NFC TAG entitlement configured in signature settings; CoreNFC read/write | ISO14443/15693; ISO18092 enabled only after FeliCa system codes are configured. Raw, unimplemented transmission methods are not registered. |
| SOTER Support and Registration Query | LocalAuthentication in conjunction with optional real `WeappSoterAttestationProvider` for negotiation | Returns empty support list and unregistered status when no signature integration is provided; authentication entry point is not registered. |
| `wx.startSoterAuthentication` | Triggers real Face ID/Touch ID to invoke the host signature provider; Face ID requires `NSFaceIDUsageDescription` | Challenge and result must match `raw`; result and signature are bounded; signature trust, RSA/PSS, and server-side verification are managed by real SOTER integration. |

The SOTER provider receives a complete trusted `WeappHostApiCall`, authentication method, and already-verified `LAContext`. It must use a key/session bound to the app, user, and account epoch. Random strings, local authentication success, or self-issued certificates cannot be used to impersonate a WeChat SOTER result. Backend systems must validate the provider's trust chain, signature, anti-replay counter, and challenge ownership.

CoreNFC allows only one active reader at a time. NDEF connection, read/write, and discovery listening are managed by native object identity. Before writing, query the actual tag capacity and write status. Raw records must use controlled ArrayBuffer channels. Operations are stopped on cancellation or timeout; no guarantees are made that tag writes are rolled back. On exit, account change, or hide, the reader is stopped, authorization/editors are terminated, and old objects become invalid. On shutdown, the system waits for CoreNFC failure callback and editor destruction. Resources are retained and cleanup failures are logged within five seconds; retries are allowed, but resources cannot be prematurely released, and account storage leases are not prematurely terminated.

Running `node sdk/ios/tools/test-system-api-payloads.mjs` can reproduce the local Swift binary, calendar parameters, and cross-challenge proof rejection tests. Actual contact save/cancel, calendar permission/save, camera and image recognition, NFC read/write/move tag/background operations, and Face ID/Touch ID with real signature backend still require a physically configured iOS device for validation and must record version, hardware, and authorization status.
