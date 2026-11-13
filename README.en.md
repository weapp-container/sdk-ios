# Weapp Container iOS SDK

[简体中文](README.md) · **English**

<a id="公开发行候选preview7"></a>
## Public distribution candidate: preview.7

The current core builder and these source examples use preview.7. Core runtime, iOS, Desktop and public CocoaPods Specs downloads are available; npm, Maven Central and pub.dev publication is incomplete. Check the [release status](https://github.com/weapp-container/weapp-container/blob/main/docs/public-sdk-release.en.md) before using installation commands. Match wrapper and runtime versions. Source availability, package publication, compilation and device acceptance are recorded separately.

First public publication is being prepared. Use these commands once this version is visible in its registry. Historical private archives and locks retain their original identities.

Version `0.1.0-preview.7.0` requires iOS 16+ and Xcode 27.2+ (Swift 5.9 language mode). It covers arm64 devices and arm64/x86_64 simulators.

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

<a id="已复核的源码构建版本"></a>
### Reviewed source-build checkout

```sh
git clone https://github.com/weapp-container/sdk-ios.git sdk-ios-source
cd sdk-ios-source
git checkout a5c9d76b8e8068efbcedbf7af073a138b69f54f2
```



[Documentation](https://container.weapp.dev/en/docs/) · [Build from source](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md) · [APIs and contracts](https://github.com/weapp-container/sdk-contract/blob/main/README.en.md)

Embed mini-program pages within iOS applications. The SDK provides Swift session management, UIKit / SwiftUI view integration, host messaging channels, and local persistence, with JavaScript execution via QuickJS and page rendering through Skia Metal.

Reviewed source example version: **0.1.0-preview.7.0**. The SDK wrapper source is licensed under [Apache-2.0](LICENSE); the runtime source is provided in the main repository under Apache-2.0. This repository contains the SDK wrapper layer source, while the runtime is built or installed separately.

<a id="从当前源码开始"></a>
## Starting from Source Code

For initial integration, prefer using the public core repository and its fixed SDK commit—no download token is required for historical archives:

```sh
git clone --recurse-submodules https://github.com/weapp-container/weapp-container.git
cd weapp-container
corepack enable
pnpm install --frozen-lockfile
node sdk/contract/fixtures/make-acceptance-pack.mjs --out artifacts/hello-pack
```

Then prepare the platform-specific runtime and notices according to the [source build instructions](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md), and use the build tool from this repository to generate the integration package. The platform toolchain remains a required dependency; public source availability does not imply that binary packages are available in public package repositories. Existing native mini-program or framework build artifacts can be packaged independently using a portable pack tool; the weapp-vite tool is not required.

The following sections retain detailed instructions for installing the SDK, view integration, and lifecycle management. Commands involving `prepare-runtime` / `prepare-native` belong to explicit archiving paths and must use a verified manifest; historical default locks may not be downloadable, see end-of-documentation notes for details.

<a id="准备环境"></a>
## Environment Setup

| Item | Requirement |
|------|-------------|
| Application OS | iOS 16+ |
| Native Architecture | arm64 on real devices, arm64 / x86_64 on simulators |
| Build Environment | macOS, Xcode / Apple SDK, Swift 5.9+ |
| Auxiliary Tools | Node.js 24+, Python 3; CocoaPods requires installation |

The host application consumes the built XCFramework and Swift wrapper without Rust. Building the runtime from source in the next section requires Rust and the public core repository.

<a id="1-获取运行库"></a>
## 1. Obtain Runtime Library

Execute the following command in the root directory of a clean checkout of the public core repository:

```sh
pnpm sdk:build:ios -- --install-framework
```

This command builds the runtime, collects notices, and invokes the fixed SDK wrapper to generate the integration package. Output is generated at `artifacts/sdk/ios/`. Full toolchain and input validation are detailed in [Source Build](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md). Historical archive installation is an optional compatibility path mentioned at the end.

<a id="2-构建并接入"></a>
## 2. Build and Integrate

The source build above produces the local integration package in `artifacts/sdk/ios/`. Wrapper-only build commands for a standalone SDK checkout are in the historical archive section.

Output directory is at `artifacts/sdk/ios/WeappContainer`, containing Swift source code, XCFramework, SwiftPM / CocoaPods configuration, license files, and build records. `--install-framework` is also installed into the directory ignored by this repository at `Frameworks/` for use by the root `Package.swift`.

**Swift Package Manager**: In Xcode, add the generated `artifacts/sdk/ios/WeappContainer` directory as a local package and include the **WeappContainer** product in your app target. Alternatively, after installing the framework, run `swift build` to verify the package in this repository.

**CocoaPods**: Place the generated directory alongside your app and configure it at the actual location:

```ruby
platform :ios, '16.0'
target 'YourApp' do
  pod 'WeappContainer', :path => '../WeappContainer'
end
```

This method consumes the fully built distribution package without requiring the SDK to be published to a public package service. App signing is managed by the host project.

<a id="3-嵌入-uikit-页面"></a>
## 3. Embed UIKit View

Integrate the complete portable pack as a directory resource within the app, preserving its directory structure. The following factory returns a standard child controller; the caller adds it to a parent controller and sets layout:

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
        catch { print("加载失败:", error) }
    }
    return controller
}
```

`packURL` points to a verified local pack directory. Download and unpack operations are handled by the host. Initial ``load`` waits for the view to be mounted to the window and obtain actual dimensions, so the child controller must be mounted first, then the loading result can be awaited. ``route`` and ``options`` can specify initial route and launch parameters.

**SwiftUI**: Create and maintain a ``WeappContainerView(session:)``, and use ``WeappContainerRepresentable(view:)`` to embed it into the interface. The host continues to manage the session lifecycle. Full mounting and re-binding behavior is detailed in [Embedding Guide](docs/EMBEDDING.en.md).

``view.captureWindowMetrics()`` synchronously reads a full window snapshot on the main thread, including actual view dimensions, trait DPR, fixed screen coordinates ``safeArea``, scene orientation, and local view coordinates ``hostLayout``. When no valid layout is available or the view is being unbound, has been unbound, or closed, it returns ``nil``. Reading does not create runtime, advance layout identity, nor grant presentation or input permissions.

To make the container view fill the actual rendering window, with background extending to the edges. Mini-programs independently avoid safe margins, occlusion, and effective fold areas via ``wx.getWindowInfo().hostLayout``; ``verticalBarEdge`` represents the physical ``left`` / ``right`` / ``none`` resolved from system traits. iOS 27.1+ uses UIKit's active retention area; older systems use safe margin compatibility paths, with minimum supported version remaining iOS 16. Business navigation, back, and close actions can be placed in the mini-program's safe tool area, requested via messaging channel to close the host; host error pages replace the container after interaction stops. Avoid cropping the entire rendered view back into the safe area.

Layout changes due to folding, rotation, or identical size layout region changes are submitted as full snapshots, preserving session and waiting for new screen confirmation before resuming interaction. Mini-programs can use container extension ``wx.onHostLayoutChange/offHostLayoutChange`` to listen for layout region changes, while ``wx.onResize`` continues to represent only size changes. See [Window Information Usage](docs/window-metrics.zh-CN.en.md) for details.

<a id="4-通信与导航"></a>
## 4. Communication and Navigation

All session and view APIs are accessed via ``MainActor``:

```swift
try session.sendMessage(.object(["type": .string("refresh")]))
try session.navigate(route: "pages/detail/index", query: ["id": .string("42")])
try session.back()
```

Mini-programs call host methods through `weappContainer.invoke` and exchange messages through `postMessage` / `onMessage`; see [weapp-container.d.ts](types/weapp-container.d.ts). Register methods before the first `load`. Arguments and results use `WeappJSON`. Handlers may use `async throws`; reject requests with `WeappHostError` and cooperate with Swift task cancellation.

<a id="5-生命周期与存储"></a>
## 5. Lifecycle and storage

- Call `try session.setForeground(false)` / `try session.setForeground(true)` when pausing or resuming the feature. View visibility, window attachment, and scene state also affect rendering.
- Use a stable application/account `storageKey` for persistence. A key permits only one writer at a time; `.init(storage: .memoryOnly)` selects memory storage.
- Await `try await view.detach()` before replacing a view. Detaching preserves the session.
- Await `try await session.close()` or `try await view.close()` when finished, allowing persistence, GPU cleanup, and native resource release to complete.

```swift
try await session.flushStorage() // 按需建立持久化点
try await session.close()
```

One session binds to one view at a time. The default persistence root is the application's `Application Support/WeappContainer` directory. Do not use random session IDs or pack versions as persistence keys. Include asynchronous closing in the host's exit flow so failures can be handled and retried.

<a id="验证与更多用法"></a>
## Validation and further usage

```sh
npm test
npm run test:input
node tools/simulator-smoke.mjs --distribution artifacts/sdk/ios/WeappContainer --pack /absolute/verified-portable-pack --simulator YOUR_BOOTED_UDID --simulator-only --rotation scene
```

`npm test` checks wrapper input contracts. `test:input` uses the macOS Swift compiler to check input queues without a private runtime. Simulator tests require a complete built distribution, an explicit pack, and a booted simulator. The tool removes its own test application and preserves the simulator. `--compile-only` checks compilation and linking; it does not establish device execution.

- [Embedding, window metrics, touch, and lifecycle](docs/EMBEDDING.en.md)
- [Host services: device capabilities, identity, payments, and permissions](HOST-SERVICES.en.md)
- [Host service examples](examples/host-services/README.en.md)
- [Independent consumer project](examples/consumer/README.en.md)
- [Cross-platform session contracts](CONTRACT.en.md)
- [Source inventory](SOURCE-INVENTORY.json) and [historical extraction receipt](ORIGIN.json)

Capabilities depend on the matching runtime and its distribution policy. `restricted-showcase` permits only demo packs and APIs authorized at compile time; host configuration cannot enable disabled capabilities. Validate device execution, GPUs, and performance against the actual artifacts. See the embedding guide for native input, accessibility, and complex gesture limitations. Distributions must retain the SDK `LICENSE`, runtime `RUNTIME-LICENSE`, and third-party notices.

<a id="历史归档与迁移"></a>
## Historical archives and migration

Runtime release tools now live in the [core repository](https://github.com/weapp-container/weapp-container/tree/main/tools/runtime-artifacts). New manifests select exact core releases through `--manifest`. Updated downloaders map legacy `runtime-artifacts` identities to the private `weapp-container/runtime-artifacts-private-archive` for nine frozen versions, preserving their versions, hashes, and licenses and recording the resolved repository. Older downloaders must upgrade. The repository at the old name contains retired tooling only. There is no cross-repository fallback; private archives require read access, and public source licensing does not imply historical binary availability.

Repository-authored runtime and SDK source uses Apache-2.0. Build the current runtime using the [core source guide](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md). Existing archives retain their original licenses, access requirements, versions, and hashes. This source update does not publish replacement binaries.

<a id="可选安装已审核的历史归档"></a>
### Optional: install reviewed historical archives

```sh
git clone https://github.com/weapp-container/sdk-ios.git
cd sdk-ios
git checkout a5c9d76b8e8068efbcedbf7af073a138b69f54f2
```

Once runtime access is authorized, provide `WEAPP_CONTAINER_RUNTIME_TOKEN` through the credential environment with **Contents: read** for the private artifact repository. Keep credentials out of source and command arguments.

```sh
node tools/prepare-runtime.mjs
```

To use authorized offline archives:

```sh
node tools/prepare-runtime.mjs --artifact-dir /absolute/runtime-archives
```

The tool validates **0.1.0-preview.7.0**, ABI 1, architectures, sizes, and SHA-256 against the [current public lock](runtime-artifacts.0.1.0-preview.7.0.lock.json), then installs under `.runtime/install/native` and `.runtime/install/licenses`. Missing archives, denied access, or integrity mismatches fail while preserving an existing installation. A lock pin does not imply public downloads.

Select a custom reviewed manifest with `--manifest /absolute/reviewed-lock.json`. `WEAPP_CONTAINER_RUNTIME_TIMEOUT_MS` adjusts download timeouts from `1` to `3600000` milliseconds; the default is 15 minutes.

After installing the archives, build the wrapper from its standalone checkout:

```sh
node tools/build.mjs --native-root .runtime/install/native --licenses-root .runtime/install/licenses --install-framework
```
