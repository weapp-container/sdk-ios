# Weapp Container iOS SDK

[简体中文](README.md) · **English**

Embed mini-program pages in an iOS app with Swift sessions, UIKit / SwiftUI views, host messaging, and local persistence. JavaScript runs in QuickJS; Skia Metal renders the page.

Source version: **0.1.0-preview.6.0**. The wrapper source is [Apache-2.0](LICENSE). The closed-source runtime is licensed separately and supplied through the private [runtime-artifacts](https://github.com/weapp-container/runtime-artifacts) repository. This public repository contains no runtime binaries and grants no runtime usage rights.

## Requirements

| Component | Requirement |
| --- | --- |
| Application | iOS 16+ |
| Architectures | arm64 devices, arm64 / x86_64 simulators |
| Build environment | macOS, Xcode / Apple SDKs, Swift 5.9+ |
| Supporting tools | Node.js 24+, Python 3; CocoaPods for Pod integration |

Applications consume a prebuilt XCFramework and Swift wrapper without a Rust toolchain or core source.

## 1. Obtain the runtime

```sh
git clone https://github.com/weapp-container/sdk-ios.git
cd sdk-ios
```

After obtaining runtime access, supply `WEAPP_CONTAINER_RUNTIME_TOKEN` through your credential environment, restricted to **Contents: read** on the private artifact repository. Keep credentials out of source files and command arguments.

```sh
node tools/prepare-runtime.mjs
```

For authorized offline archives:

```sh
node tools/prepare-runtime.mjs --artifact-dir /absolute/runtime-archives
```

The installer checks **0.1.0-preview.6.0**, ABI 1, architecture, size, and SHA-256 against [runtime-artifacts.lock.json](runtime-artifacts.lock.json), then installs to `.runtime/install/native` and `.runtime/install/licenses`. Missing archives, denied access, or integrity mismatches fail the operation and preserve the previous installation. A committed pin does not imply public download access.

Use `--manifest /absolute/reviewed-lock.json` for an explicitly reviewed archive manifest. `WEAPP_CONTAINER_RUNTIME_TIMEOUT_MS` adjusts the download deadline from `1` to `3600000` milliseconds; the default is 15 minutes.

## 2. Build and integrate

Assemble the distribution on macOS:

```sh
node tools/build.mjs --native-root .runtime/install/native --licenses-root .runtime/install/licenses --install-framework
```

`artifacts/ios/WeappContainer` contains Swift sources, the XCFramework, SwiftPM / CocoaPods metadata, licenses, and build receipts. `--install-framework` also installs the verified framework into this clone's ignored `Frameworks/` directory for the root `Package.swift`.

Swift Package Manager: in Xcode, add the generated `artifacts/ios/WeappContainer` directory as a local package and link its **WeappContainer** product to your app target. After installing the framework, `swift build` also checks the repository package.

CocoaPods: place the generated distribution beside your app and adjust the path:

```ruby
platform :ios, '16.0'
target 'YourApp' do
  pod 'WeappContainer', :path => '../WeappContainer'
end
```

Both approaches consume a complete local distribution and do not require a public package publication. The host project manages application signing.

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
