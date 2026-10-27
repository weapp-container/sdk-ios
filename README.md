# Weapp Container Ios SDK

Version **0.1.0-preview.2** · [weapp-container organization](https://github.com/weapp-container) · [SDK contract](https://github.com/weapp-container/sdk-contract)

This independent repository contains the **Apache-2.0 host wrapper and consumer source**. The runtime implementation remains closed source. Its separately licensed binaries are obtained only from the private [`weapp-container/runtime-artifacts`](https://github.com/weapp-container/runtime-artifacts) repository. SDK source licensing does not grant a runtime binary license. Distributions retain `RUNTIME-LICENSE` and all third-party notices alongside the wrapper's `LICENSE`.

A fresh clone needs Node.js 24+, Python 3 and the platform toolchain below. It does **not** need a parent monorepo, Rust, Cargo, a git submodule or private implementation source.

## Obtain the native runtime

Use the reviewed `runtime-artifacts.lock.json` shipped with the matching SDK release. It locks the exact runtime version, platform, architecture, ABI **1**, artifact size and SHA-256. An absent pin, missing architecture, hash/version mismatch or unavailable engine is an error; there is no download of `latest`, software substitution or silent fallback.

Set `WEAPP_CONTAINER_RUNTIME_TOKEN` in your credential environment with read access to the private artifact repository. Do not place credentials in source files or CLI arguments. Then run:

```sh
node tools/prepare-runtime.mjs
```

For an authorized offline copy use `--artifact-dir /absolute/runtime-archives`, or `WEAPP_CONTAINER_RUNTIME_ARTIFACT_DIR`. Files still undergo the same committed pin, hash, version and ABI checks. `--manifest /absolute/reviewed-lock.json` explicitly selects another reviewed lock; `--version` overrides are intentionally unavailable in this wrapper.

Preparation atomically installs verified inputs under `.runtime/install/native` and `.runtime/install/licenses`. It preserves the prior installation on failure. Generated archives, binaries, caches and credentials are excluded from Git. `--native-root` below also accepts an explicitly supplied local distribution with matching per-target `build.json`, SHA-256, the reviewed C header and runtime license; local input does not imply private-release authentication.

## Build and embed

Requirements: macOS with Xcode/Apple SDKs, Swift 5.9+, deployment target iOS 16. The runtime inputs contain arm64 device, arm64 simulator and x86_64 simulator archives. The Swift product/module stays `WeappContainer`.

```sh
node tools/build.mjs --native-root .runtime/install/native --licenses-root .runtime/install/licenses --install-framework
swift build
```

The tool combines the simulator archives and assembles `artifacts/ios/WeappContainer`, a standalone SwiftPM/CocoaPods distribution. `--install-framework` also installs its verified XCFramework into this clone's ignored `Frameworks/` directory for the root Package.swift. Consumers can instead add the generated package directory or `WeappContainer` Pod. No runtime source is compiled. `WeappContainerSession` and its UIView retain main-actor ownership. [Embedding details](docs/EMBEDDING.md).

```sh
node tools/simulator-smoke.mjs --distribution artifacts/ios/WeappContainer --pack /absolute/verified-portable-pack --simulator YOUR_BOOTED_UDID --simulator-only --rotation scene
node tools/simulator-smoke.mjs --distribution artifacts/ios/WeappContainer --pack /absolute/verified-portable-pack --compile-only
node tools/pod-smoke.mjs --distribution artifacts/ios/WeappContainer --pack /absolute/verified-portable-pack
```

Consumer sources and the Xcode project generator are in `examples/consumer`. The test pack is explicit input; none is read from a parent checkout. UI tests borrow the named booted simulator, remove their apps/test runners and preserve the simulator. Device compile/link or archive checks are separate from physical-device execution.

## Validation and provenance

```sh
npm test
npm run test:input # macOS Swift compiler; no private runtime required
```

These are wrapper input-contract and presentation queue tests, not runtime, GPU, device, performance or WeChat parity results. The queue tests use the production Swift state machine and a changing ACK gate to cover cancellation while a frame is pending, phase ordering, retirement, bounds and timeouts. Lifecycle retirement clears queued input; UIKit gesture cancellation waits for the current frame acknowledgement. This split starts with a new version: historical preview.1 results are not attributed to preview.2. Platform build/UI reports must be regenerated against the exact pinned runtime before claiming that scope passed. Native IME, complete accessibility and advanced gestures remain separate limitations.

`ORIGIN.json` lists the allowlisted source paths, original source SHA-256, transformed destination SHA-256 and reviewed C-header contract hash. This repository includes no core implementation, Git history from the original repository, binary runtime, cache or credentials.
