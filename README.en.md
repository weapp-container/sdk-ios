# Weapp Container iOS SDK

First public publication is being prepared. Use these commands once this version is visible in its registry. Historical private archives and locks retain their original identities.

Version `0.1.0-preview.7.0` requires iOS 16+ and Xcode / Swift 5.9+. It covers arm64 devices and arm64/x86_64 simulators.

Use the exact SwiftPM version; Package.swift pins the binary URL and checksum:

```swift
.package(url: "https://github.com/weapp-container/sdk-ios.git", exact: "0.1.0-preview.7.0")
```

For CocoaPods, add the public organization Specs repository alongside the official source:

```ruby
source 'https://github.com/weapp-container/Specs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '16.0'
pod 'WeappContainer', '0.1.0-preview.7.0'
```

The Pod downloads a fixed HTTP archive containing Swift sources, the XCFramework and licenses, verified by SHA-256. Installation needs no Node.js, Rust or local runtime checkout. Check the [Specs publication record](https://github.com/weapp-container/Specs) for Trunk availability.

## 3. Embed a UIKit page

Add the complete portable pack as a directory resource, preserving its structure. This factory returns a normal child controller; its caller mounts it in a parent controller and supplies layout constraints:

```swift
import UIKit
import WeappContainer

@MainActor
func makeContainer(packURL: URL) throws -> WeappContainerViewController {
    let session = WeappContainerSession(
        configuration: .init(storageKey: "catalog:account-42")
    )
    try session.registerHostMethod("host.profile") { _ in
        .object(["name": .string("Ada")])
    }
    session.onEvent = { event in
        if case .message(let message) = event { print(message) }
        if case .error(let error) = event { print(error) }
    }
    let controller = try WeappContainerViewController(session: session)
    Task { @MainActor in
        do { try await session.load(packURL: packURL) }
        catch { print("Load failed:", error) }
    }
    return controller
}
```

`packURL` points to a verified local pack directory; downloading and unpacking belong to the host. Initial `load` waits for a view attached to a window with real measured bounds, so mount the child controller before awaiting completion. Set `route` and `options` to choose the initial route and launch parameters.

SwiftUI: create and retain a `WeappContainerView(session:)` and display it through `WeappContainerRepresentable(view:)`. The host owns the session lifetime. See the [embedding guide](docs/EMBEDDING.md) for mounting and reattachment details.

`view.captureWindowMetrics()` synchronously reads a complete snapshot on the main actor: actual View bounds, trait DPR, fixed-screen `safeArea`, resolved scene orientation, and surface-local `hostLayout`. It returns `nil` without valid layout or while detaching/after detach or close. Reading neither creates a runtime nor advances layout identity, and grants no presentation or input authority.

Let the rendering View fill the actual window. The mini-program reads `wx.getWindowInfo().hostLayout` to protect controls against safe margins, occlusions, and active fold regions while its background reaches the edges. `verticalBarEdge` resolves the system trait into physical `left` / `right` / `none`. iOS 27.1+ uses active UIKit reserved regions; older systems retain safe-inset fallback and the minimum stays iOS 16. Business navigation, back, and close can live in the guest safe tool area, with a message requesting host closure; host error UI replaces the inactive guest. Avoid cropping the whole rendering View to its safe area.

Folding, rotation, and same-size region changes submit complete snapshots, preserving the session and waiting for the new frame before interaction resumes. The container extensions `wx.onHostLayoutChange/offHostLayoutChange` report local layout changes; `wx.onResize` continues to report size changes only. See the [window metrics contract](docs/window-metrics.md).

## 4. Messaging and navigation

Use all session and view APIs on the `MainActor`:

```swift
try session.sendMessage(.object(["type": .string("refresh")]))
try session.navigate(route: "pages/detail/index", query: ["id": .string("42")])
try session.back()
```

Mini-program code calls host methods through `weappContainer.invoke` and exchanges messages through `postMessage` / `onMessage`. See [weapp-container.d.ts](types/weapp-container.d.ts). Register methods before the first `load`; parameters and results use `WeappJSON`. Handlers are `async throws`: throw `WeappHostError` for structured rejection and cooperate with Swift task cancellation.

## 5. Lifetime and storage

- Explicitly suspend/resume a feature with `try session.setForeground(false)` / `try session.setForeground(true)`. View visibility, window attachment, and scene state also affect presentation.
- Use a stable application/account `storageKey` for persistence. Each key admits one writer; `.init(storage: .memoryOnly)` uses memory storage.
- Await `try await view.detach()` before replacing a view; detaching preserves the live session.
- Await `try await session.close()` or `try await view.close()` when the feature ends to persist data, retire GPU work, and release native state.

```swift
try await session.flushStorage() // Optional explicit durability point
try await session.close()
```

One session binds to one view at a time. Persistent data defaults to the app's `Application Support/WeappContainer` directory. Do not derive storage keys from random session IDs or pack versions. Include asynchronous closure in the host's exit flow so failures can be handled and retried when appropriate.

## Validation and further reading

```sh
npm test
npm run test:input
node tools/simulator-smoke.mjs --distribution artifacts/ios/WeappContainer --pack /absolute/verified-portable-pack --simulator YOUR_BOOTED_UDID --simulator-only --rotation scene
```

`npm test` checks wrapper input contracts. `test:input` uses the macOS Swift compiler to check the input queue without a private runtime. Simulator tests need a complete built distribution, an explicit pack, and a booted simulator. The tool removes its own test apps and preserves the simulator. `--compile-only` performs separate compile/link checks and does not establish device execution.

- [Embedding, window metrics, touch, and lifetime](docs/EMBEDDING.md)
- [Host services: devices, identity, payments, and permissions](HOST-SERVICES.md)
- [Host service integration example](examples/host-services/README.md)
- [Independent consumer project](examples/consumer/README.md)
- [Cross-platform session contract](CONTRACT.md)
- [Source inventory](SOURCE-INVENTORY.json) and [historical extraction receipt](ORIGIN.json)

Capabilities depend on the paired runtime and its distribution policy. `restricted-showcase` admits only compiled-in demo packs and APIs; host configuration cannot re-enable disabled capabilities. Physical-device, GPU, and performance acceptance must be validated against actual artifacts. See the embedding guide for native IME, accessibility, and advanced gesture limitations. Retain the SDK `LICENSE`, runtime `RUNTIME-LICENSE`, and third-party notices when distributing an application.
