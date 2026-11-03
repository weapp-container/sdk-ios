# Weapp Container Ios SDK

Source version **0.1.0-preview.6.0** (private, unpublished source preparation) · [weapp-container organization](https://github.com/weapp-container) · [SDK contract](https://github.com/weapp-container/sdk-contract)

Current source requires a newly built **0.1.0-preview.6.0** runtime and matching SDK bundles. Production, exact archive pins, private publication and consumer validation for this version are pending. The checked-in `runtime-artifacts.lock.json` retains the historical **0.1.0-preview.5.3** archive set (SHA-256 `ee393000b5726172755b24a31812f9b55051e710c2714edadb9b3ac287b95388`); it does not satisfy this source version. Preparation must reject that mismatch. Old native producer, archive and device evidence remains unchanged; new binaries require independent source and artifact bindings.

This independent repository contains the **Apache-2.0 host wrapper and consumer source**. The runtime implementation remains closed source. Its separately licensed binaries are obtained only from the private [`weapp-container/runtime-artifacts`](https://github.com/weapp-container/runtime-artifacts) repository. SDK source licensing does not grant a runtime binary license. Distributions retain `RUNTIME-LICENSE` and all third-party notices alongside the wrapper's `LICENSE`.

A fresh clone needs Node.js 24+, Python 3 and the platform toolchain below. It does **not** need a parent monorepo, Rust, Cargo, a git submodule or private implementation source.

Historical preview.5.2 distribution (preserved evidence): its historical lock identified the **0.1.0-preview.5.2** QuickJS + Skia GPU
distribution set by exact size and SHA-256: seven runtime slices and Android,
iOS and macOS universal SDK packages. The native code retains its original
**0.1.0-preview.5.1** production identity,
`747d0b02131d7f67b3adbdd7127abcd5e21ffdbe`. The iOS wrapper archive was produced
from `f8af959868b009b6b627c370c28983c410be7e9e`; the other wrapper producer
commits remain separately recorded in archive provenance. Later pin-only commits
do not change those producer identities. Windows/Linux runtime distributions remain blocked.
Archive validation, private publication and actual Player/GPU/device acceptance
are separate gates. No older-runtime fallback is allowed.

The historical preview.5.2 iOS wrapper package retained both native static archives, C headers and
module maps byte for byte. Reassembling its XCFramework changed only the
`Info.plist` `AvailableLibraries` array order; its parsed contents are otherwise
equal. The strict whole-XCFramework byte gate remains **failed**. A separate
qualification records unchanged native code bytes and this metadata difference;
it does not turn the strict gate into a pass or establish publication, App
linking, simulator, device, GPU or performance acceptance for preview.5.2.

Historical preview.5 native production remains bound to
`05aec6c4056a124a9c399c75b34d081cffbdaa5d`. All earlier release bytes, reports
and source identities keep their original bindings.

## Obtain the native runtime

Use the reviewed `runtime-artifacts.lock.json` shipped with the matching SDK release. It locks the exact runtime version, platform, architecture, ABI **1**, artifact size and SHA-256. An absent pin, missing architecture, hash/version mismatch or unavailable engine is an error; there is no download of `latest`, software substitution or silent fallback.

The commands below use the committed preview.5.3 lock by default. Use an authorized offline archive directory until the matching private release is published and available to your credential. Historical preview.5.2 inputs remain preserved evidence and do not satisfy this source.

Set `WEAPP_CONTAINER_RUNTIME_TOKEN` in your credential environment with read access to the private artifact repository. Do not place credentials in source files or CLI arguments. Then run:

Network artifact transfers have a single 15-minute deadline covering headers,
redirects and the complete body; release metadata has a separate 30-second
deadline. For slower connections, set `WEAPP_CONTAINER_RUNTIME_TIMEOUT_MS` to a
positive base-10 integer in milliseconds, up to `3600000` (one hour). Invalid
values return `ERR_RUNTIME_OPTIONS`; transfer failures and timeouts return
sanitized `ERR_RUNTIME_NETWORK`. Explicit API/CLI overrides are documented in the
[shared SDK contract](https://github.com/weapp-container/sdk-contract).

```sh
node tools/prepare-runtime.mjs
```

For an authorized offline copy use `--artifact-dir /absolute/runtime-archives`, or `WEAPP_CONTAINER_RUNTIME_ARTIFACT_DIR`. Files still undergo the same committed pin, hash, version and ABI checks. `--manifest /absolute/reviewed-lock.json` explicitly selects another reviewed lock; `--version` overrides are intentionally unavailable in this wrapper.

Preparation atomically installs verified inputs under `.runtime/install/native` and `.runtime/install/licenses`. It preserves the prior installation on failure. Generated archives, binaries, caches and credentials are excluded from Git. `--native-root` below also accepts an explicitly supplied local distribution with matching per-target `build.json`, SHA-256, the reviewed C header and runtime license; local input does not imply private-release authentication.

Exact runtime distributions retain the producer's original `build.json` and bind its bytes with `runtime-distribution.json`. The selection accounts for every producer artifact and can omit only the unused iOS dynamic library or Android static archive. Required libraries, the reviewed header and platform notices remain mandatory. Inputs without this selection receipt continue to verify the full producer inventory.

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

## Host services

Native identity, APP payments, device APIs, BLE, managed files and camera/video integration are documented in [HOST-SERVICES.md](HOST-SERVICES.md), including account cleanup and current acceptance limits.

## Validation and provenance

```sh
npm test
npm run test:input # macOS Swift compiler; no private runtime required
```

These are wrapper input-contract and presentation queue tests, not runtime, GPU, device, performance or WeChat parity results. The queue tests use the production Swift state machine and a changing ACK gate to cover cancellation while a frame is pending, phase ordering, retirement, bounds and timeouts. Lifecycle retirement clears queued input; UIKit gesture cancellation waits for the current frame acknowledgement. This split starts with a new version: historical preview.1 results are not attributed to preview.2. Platform build/UI reports must be regenerated against the exact pinned runtime before claiming that scope passed. Native IME, complete accessibility and advanced gestures remain separate limitations.

The 2026-10-27 preview.2 report for wrapper source `58977df` records nine production input-queue cases and one complete UI test on an arm64 iOS 27 simulator using completed Metal frames. The UI test covers two sessions, OS touch and continuous scrolling, nested host scrolling, pinch recovery, navigation, background/foreground, device rotation and durable reopening. Device arm64 and simulator x86_64 were compiled and linked; physical-device and x86_64 execution, performance and WeChat parity remain unmeasured. The runtime archive identity is fixed by the release lock, and the independent-consumer reports retain their exact source commits.

`ORIGIN.json` lists the allowlisted source paths, original source SHA-256, transformed destination SHA-256 and reviewed C-header contract hash. This repository includes no core implementation, Git history from the original repository, binary runtime, cache or credentials.

### Reviewing later SDK source changes

`ORIGIN.json` stays as the historical extraction receipt. `SOURCE-INVENTORY.json` records the current reviewed wrapper source paths, SHA-256, sizes and executable modes, including the historical receipt's unchanged hash. The origin check and package build verify this exact inventory in the standalone SDK checkout and reject untracked or unreviewed paths, modified bytes, symlinks, core sources, binaries and caches. This source review is separate from build, artifact and device acceptance evidence.

After reviewing an update, stage all intended new source files, refresh explicitly, then stage the inventory:

```sh
git add <reviewed-files>
node tools/source-inventory.mjs --write --version 0.1.0-preview.5.3 --reason "Describe the reviewed changes"
git add SOURCE-INVENTORY.json
node tools/check-origin.mjs
npm test
```

Commit source and inventory together before building distributable packages. `sourceBaseCommit` identifies the checkout used to prepare the source review; it does not bind subsequent build evidence to that earlier commit. Never rewrite historical receipts or fabricate runtime archive lock hashes to make this check pass.

## Native dependency lock

`runtime-artifacts.lock.json` pins only this SDK's native runtime slices. Wrapper archives are build outputs and are kept in the delivery manifest, so the SDK never depends on the hash of its own archive. Other platforms use their own SDK locks. Historical `ORIGIN.json` records remain unchanged.

The `0.1.0-preview.6.0` generation is an unpublished local preview. Prepare it with the exact reviewed offline archive directory (`npm run runtime:prepare -- --artifact-dir <archives>`); a version pin does not imply that a release has been published.

### System tab bar presenter admission

`systemTabBar` is a trusted host configuration option. It defaults to `false`, and
`false` is omitted from the wire configuration for compatibility. Set it to `true`
with a paired runtime/SDK and an installed system tab chrome consumer, such as the
dev Player Flutter tabs or its Windows/Gtk overlays.

The runtime supports bounded `setTabBarBadge`, `removeTabBarBadge`,
`showTabBarRedDot`, `hideTabBarRedDot`, and `setTabBarStyle` transactions with a
Partial capability ceiling. Custom tab bars remain Unsupported. `showTabBar`,
`hideTabBar`, and `setTabBarItem` are not implemented by this option. The flag
admits the host consumer; it does not establish WeChat visual/parameter parity
or platform acceptance.
