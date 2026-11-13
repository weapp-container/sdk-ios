<a id="ios-端小程序容器预览版"></a>
# Weapp Container for iOS (preview)

[简体中文](EMBEDDING.md) · **English**


Native QuickJS + Skia Metal SDK, iOS 16+, arm64 devices and arm64/x86_64 simulators.
The application consumes Swift source and a prebuilt C XCFramework. It does not
compile Rust, include this repository's crates, or embed a WebView.

<a id="构建发行版"></a>
## Build the distribution

Follow the standalone [root README](../README.en.md): download authenticated, version-locked private runtime archives, then run `node tools/build.mjs --native-root .runtime/install/native --licenses-root .runtime/install/licenses --install-framework`. The wrapper assembles an XCFramework from those inputs; it never compiles the runtime or reads a parent checkout. Output is `artifacts/ios/WeappContainer` with its build receipt and hashes.

<a id="安装"></a>
## Install

Add the generated `WeappContainer` directory as a local Swift package, and add
its `WeappContainer` product to the application target. Alternatively:

```ruby
pod 'WeappContainer', :path => '../WeappContainer'
```

The generated directory contains its podspec, Swift sources, XCFramework,
license, dependency lock and build receipt. A Rust toolchain is unnecessary in
the consuming application. Do not point CocoaPods at the repository template.

<a id="嵌入"></a>
## Embed

```swift
import WeappContainer

@MainActor
func makeContainer(packURL: URL) throws -> WeappContainerViewController {
    let session = WeappContainerSession(configuration:
        .init(storageKey: "my-feature/account-123"))
    try session.registerHostMethod("account.profile") { payload in
        .object(["name": .string("Ada")])
    }
    session.onEvent = { event in
        if case .message(let message) = event { print(message) }
    }
    let controller = try WeappContainerViewController(session: session)
    Task { try await session.load(packURL: packURL) }
    return controller
}
```

Add the controller as a normal child controller and give its view constraints.
`load` waits for the view's first real window layout; the module's synchronous
window/system APIs see those measured metrics during initialization. Cancelling
that task before layout cancels the wait. Packs are verified local directories;
remote downloads and pack updates belong to the host application.

Development clients can await `session.prepareView()` after mounting the view
to inspect capabilities before startup. It waits for those same real metrics
and creates an empty runtime without executing App/Page JS or acknowledging a
frame. Cancelling the task or closing the session settles the wait. Keep an
accepted view mounted until a staged candidate has prepared and loaded; use
`load` for initial startup and `applyDevPack` only for an already loaded session.
This is an additive Swift wrapper method; the C ABI is unchanged.

For SwiftUI, create a `WeappContainerView` once and pass it to
`WeappContainerRepresentable(view:)`. The caller owns the session lifetime.
Flutter and React Native wrappers embed this same UIKit view.

Use `sendMessage`, `navigate`, `back` and async host methods for application
integration. JSON values use the Codable `WeappJSON` enum; runtime envelopes
remain private. Host methods are registered before loading. Throw
`WeappHostError` for a structured provider rejection. Native cancellation
cancels the associated Swift Task; handlers should cooperate with cancellation.

<a id="生命周期和渲染"></a>
## Lifetime and rendering

All session/view API and callbacks are main-actor isolated. Exactly one view can
claim a session. Removing it from the window, hiding it or hiding an ancestor pauses rendering
and JavaScript timers. `try session.setForeground(false)` also suspends a feature
that remains mounted; `true` resumes only when its view and scene are visible.
View polling cannot override an explicit host suspension. An independent completion timer continues HTTP, host-call,
expiry and persistence progress while iOS permits process execution. It does not
request background execution or extend the app's background lifetime.

Call `try await view.detach()` before creating a replacement view for the same
session. Detach preserves the runtime. `load` also replaces a running pack: it
asynchronously drains the Metal queue, detaches, loads transactionally and
reattaches after success or failure. Failed candidates preserve the previous app.

The normal view path renders Skia directly into a CAMetalLayer drawable, with no
CPU snapshot/readback or image upload. `onPresented` is fired after a completion
barrier on the same Metal queue, not on submission. Rendering tracks SDK frame
revisions, including repaints that reuse an application frame ID. Touches use
logical points and drawables use actual screen scale; safe areas are measured in
the view's coordinate space. One contact is supported; additional contacts cancel
it explicitly.

Touches that begin inside the native view belong to the mini-program. Its own
gesture recognizer prevents ancestor `UIScrollView` pans from stealing that
sequence; gestures that begin in the host's surrounding area still scroll the
host normally. The SDK does not change a host scroll view's delegate or enabled
state. Host navigation and operating-system interruptions can still cancel the
touch, and cancellation never synthesizes a tap.

Await `session.flushStorage()` when an explicit durability point is needed, and
`session.close()` (or `view.close()`) before releasing the feature. Close drains
GPU work and awaits persistence before destroying native state. A stable
application/account storage key is required for persistence and has one writer;
keys must not be generated from session UUIDs or pack versions. The default root
is the app's Application Support/WeappContainer directory. Explicit
`.init(storage: .memoryOnly)` selects nonpersistent storage. Deinitialization is
only a final cleanup safety net and cannot report persistence errors to callers.

`wx.request` uses the shared reqwest/rustls HTTP(S) transport rather than
URLSession. App Transport Security settings do not configure this transport.
Host methods implemented with URLSession follow that API's ATS policy. The preview supports
`wx.request`, storage, window/system information and the shared contract's mini-
program subset. Upload/download/WebSocket are not implemented; inspect
`session.capabilities()` after loading for actual compiled support.

<a id="独立的消费者验证"></a>
## Independent consumer validation

`node tools/simulator-smoke.mjs --distribution /absolute/WeappContainer` builds
and runs the isolated example using only the distribution. The script borrows a
booted simulator, installs a uniquely identified test application, records
completed Metal frames, messages, reload recovery, storage and lifecycle evidence,
and removes its own application at the end. It never shuts down the simulator.
`node scripts/sdk-ios-pod-smoke.mjs` separately verifies CocoaPods install and
consumer linking from the same distribution.

Device and Intel simulator compile checks are recorded separately from real
arm64 simulator execution; a simulator run is not device execution evidence.

Use `--compile-only` for arm64-device and x86_64-simulator consumer linking
without interacting with a simulator; use `--simulator-only` for the arm64
simulator interaction gate. Both modes validate the distribution checksums.
