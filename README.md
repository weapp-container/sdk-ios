# Weapp Container iOS SDK

**简体中文** · [English](README.en.md)

<a id="public-distribution-candidate-preview7"></a>
## 公开发行候选：preview.7

当前核心构建器与本页源码示例均使用 preview.7。核心运行库、iOS、Desktop 及公开 CocoaPods Specs 已提供下载；npm、Maven Central 和 pub.dev 尚未全部发布。使用安装命令前先核对[发布状态](https://github.com/weapp-container/weapp-container/blob/main/docs/public-sdk-release.md)，不要混用不同版本的包装层与运行库。源码公开、包发布、编译通过和设备验收分别记录。

首次公开发布正在准备；安装命令须在对应注册源出现本版本后使用。历史私有归档及其锁文件保持原样。

版本 `0.1.0-preview.7.0`；iOS 16+，Xcode 27.2+（Swift 5.9 语言模式）；包含 arm64 真机和 arm64/x86_64 模拟器。

Swift Package Manager 使用固定版本标签；二进制归档由 Package.swift 的 URL 与 checksum 锁定：

```swift
.package(url: "https://github.com/weapp-container/sdk-ios.git", exact: "0.1.0-preview.7.0")
```

CocoaPods 在 Podfile 添加组织公开 Specs 源和官方源：

```ruby
source 'https://github.com/weapp-container/Specs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '16.0'
pod 'WeappContainer', '0.1.0-preview.7.0'
```

Pod 使用包含 Swift 层、XCFramework 和许可的固定 HTTP 归档，验证 SHA-256。普通安装无需 Node.js、Rust 或本地运行库目录。Trunk 投稿状态以 [Specs 发布记录](https://github.com/weapp-container/Specs) 为准。

<a id="reviewed-source-build-checkout"></a>
### 已复核的源码构建版本

```sh
git clone https://github.com/weapp-container/sdk-ios.git sdk-ios-source
cd sdk-ios-source
git checkout a5c9d76b8e8068efbcedbf7af073a138b69f54f2
```



[开发文档](https://container.weapp.dev/docs/) · [源码构建](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md) · [API 与协议](https://github.com/weapp-container/sdk-contract/blob/main/README.md)

在 iOS 应用中嵌入小程序页面。SDK 提供 Swift 会话、UIKit / SwiftUI 视图、宿主消息通道和本地持久化，使用 QuickJS 执行 JavaScript、Skia Metal 渲染页面。

已复核源码示例版本：**0.1.0-preview.7.0**。SDK 封装源码采用 [Apache-2.0](LICENSE)；运行时源码在主仓库按 Apache-2.0 提供。本仓库包含 SDK 包装层源码，运行库单独构建或安装。

<a id="starting-from-source-code"></a>
## 从当前源码开始

首次接入优先使用公开的核心仓库及其固定 SDK 提交，不需要历史归档的下载 token：

```sh
git clone --recurse-submodules https://github.com/weapp-container/weapp-container.git
cd weapp-container
corepack enable
pnpm install --frozen-lockfile
node sdk/contract/fixtures/make-acceptance-pack.mjs --out artifacts/hello-pack
```

随后按[源码构建说明](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)准备目标平台的运行库和 notices，再用本仓库的构建工具生成接入包。平台工具链仍是必要依赖；源码公开不表示公共包仓库已有可下载的二进制。已有原生小程序或框架构建产物可以由独立 portable pack 工具打包，不要求 weapp-vite。

下面保留独立 SDK 的安装、视图与生命周期说明。涉及 `prepare-runtime` / `prepare-native` 的命令属于显式归档路径，必须使用核验过的配套 manifest；历史默认锁可能无法下载，详见文末说明。

<a id="environment-setup"></a>
## 准备环境

| 项目 | 要求 |
| --- | --- |
| 应用系统 | iOS 16+ |
| 原生架构 | arm64 真机、arm64 / x86_64 模拟器 |
| 构建环境 | macOS、Xcode / Apple SDK、Swift 5.9+ |
| 辅助工具 | Node.js 24+、Python 3；使用 CocoaPods 时需安装 CocoaPods |

宿主应用消费已构建的 XCFramework 和 Swift 封装，不需要 Rust。下一节从源码生成运行库时，需要 Rust 和公开核心仓库。

<a id="1-obtain-runtime-library"></a>
## 1. 获取运行库

在公开核心仓库的干净 checkout 根目录执行：

```sh
pnpm sdk:build:ios -- --install-framework
```

该命令从当前源码构建运行库，收集 notices，并调用固定的 SDK 包装层生成接入包。输出在 `artifacts/sdk/ios/`。完整工具链和输入检查见[源码构建](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)。历史归档安装属于文末的可选兼容路径。

<a id="2-build-and-integrate"></a>
## 2. 构建并接入

上一节的源码构建已在 `artifacts/sdk/ios/` 生成本地接入包。独立 SDK checkout 的包装层构建命令见历史归档章节。

输出目录为 `artifacts/sdk/ios/WeappContainer`，包含 Swift 源码、XCFramework、SwiftPM / CocoaPods 配置、许可证和构建记录。`--install-framework` 同时安装到本仓库忽略的 `Frameworks/` 目录，供根 `Package.swift` 使用。

Swift Package Manager：在 Xcode 中把生成的 `artifacts/sdk/ios/WeappContainer` 目录添加为本地 package，并把 **WeappContainer** product 加到应用 target。也可在安装框架后运行 `swift build` 检查本仓库 package。

CocoaPods：将生成目录放到应用旁边，并按实际位置配置：

```ruby
platform :ios, '16.0'
target 'YourApp' do
  pod 'WeappContainer', :path => '../WeappContainer'
end
```

上述方式消费本地生成的完整分发包，不要求 SDK 已发布到公共包服务。应用签名由宿主工程管理。

<a id="3-embed-uikit-view"></a>
## 3. 嵌入 UIKit 页面

把完整 portable pack 作为目录资源加入应用，保留其目录结构。下面的工厂返回一个普通子控制器；调用方把它加入父控制器并设置布局：

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

`packURL` 指向经过校验的本地 pack 目录。下载和解包由宿主负责。初次 `load` 等待视图挂载到窗口并取得真实尺寸，因此应先完成子控制器挂载，再等待加载结果。`route` 和 `options` 可指定初始路由及启动参数。

SwiftUI：创建并持有一个 `WeappContainerView(session:)`，使用 `WeappContainerRepresentable(view:)` 放入界面，宿主继续负责会话生命周期。完整挂载和重绑行为见 [嵌入说明](docs/EMBEDDING.md)。

`view.captureWindowMetrics()` 在主线程同步读取完整窗口快照，包含实际 View 尺寸、trait DPR、屏幕固定坐标 `safeArea`、scene 方向，以及 View 局部坐标的 `hostLayout`。未取得有效布局或视图正在解绑、已解绑/关闭时返回 `nil`；读取不创建运行时、不推进布局身份，也不授予呈现或输入权限。

让容器 View 铺满需要渲染的实际窗口，背景可延伸到边缘。小程序通过 `wx.getWindowInfo().hostLayout` 独立避让安全边距、遮挡和有效折叠区域；`verticalBarEdge` 是系统 trait 解析后的物理 `left` / `right` / `none`。iOS 27.1+ 使用 UIKit 的活动保留区域，旧系统使用安全边距兼容路径，最低版本仍为 iOS 16。业务导航、返回和关闭可以放在小程序的安全工具区，由消息通道请求宿主关闭；宿主错误页则在停止交互后替换容器。避免把整张渲染 View 再裁到安全区。

折叠、旋转及同尺寸布局区域变化都提交完整快照，保留会话并等待新画面确认后恢复交互。小程序可用容器扩展 `wx.onHostLayoutChange/offHostLayoutChange` 监听布局区域变化，`wx.onResize` 继续只表示尺寸变化。详见[窗口信息用法](docs/window-metrics.zh-CN.md)。

<a id="4-communication-and-navigation"></a>
## 4. 通信与导航

所有会话和视图 API 在 `MainActor` 上使用：

```swift
try session.sendMessage(.object(["type": .string("refresh")]))
try session.navigate(route: "pages/detail/index", query: ["id": .string("42")])
try session.back()
```

小程序侧使用 `weappContainer.invoke` 调用宿主方法，使用 `postMessage` / `onMessage` 交换消息，类型见 [weapp-container.d.ts](types/weapp-container.d.ts)。宿主方法应在首次 `load` 前注册，参数和结果使用 `WeappJSON`。处理器可以使用 `async throws`；拒绝请求时抛出 `WeappHostError`，异步任务需配合 Swift 任务取消。

<a id="5-lifecycle-and-storage"></a>
## 5. 生命周期与存储

- 宿主主动暂停、恢复功能时调用 `try session.setForeground(false)` / `try session.setForeground(true)`；视图隐藏、离开窗口和场景状态也会影响渲染。
- 持久化使用稳定的业务/账号 `storageKey`，同一 key 同时只允许一个写入者；`.init(storage: .memoryOnly)` 使用内存存储。
- 替换视图前等待 `try await view.detach()`；解绑会保留运行会话。
- 业务结束时等待 `try await session.close()` 或 `try await view.close()`，完成持久化、GPU 资源清理和原生状态释放。

```swift
try await session.flushStorage() // 按需建立持久化点
try await session.close()
```

一个会话同时绑定一个视图。默认持久化根目录为应用的 `Application Support/WeappContainer`；不要使用随机会话 ID 或 pack 版本作为持久化 key。将关闭操作纳入宿主退出流程，以便处理失败并在需要时重试。

<a id="validation-and-further-usage"></a>
## 验证与更多用法

```sh
npm test
npm run test:input
node tools/simulator-smoke.mjs --distribution artifacts/sdk/ios/WeappContainer --pack /absolute/verified-portable-pack --simulator YOUR_BOOTED_UDID --simulator-only --rotation scene
```

`npm test` 检查封装层输入契约，`test:input` 使用 macOS Swift 编译器检查输入队列，不需要私有运行库。模拟器测试需要已构建的完整分发包、显式 pack 和已启动的模拟器；工具清理自己的测试应用，保留模拟器。`--compile-only` 用于单独编译/链接检查，不能视为设备运行通过。

- [嵌入、窗口尺寸、触摸与生命周期](docs/EMBEDDING.md)
- [宿主服务：设备能力、身份、支付与权限](HOST-SERVICES.md)
- [宿主服务接入示例](examples/host-services/README.md)
- [独立 consumer 工程](examples/consumer/README.md)
- [跨端会话契约](CONTRACT.md)
- [源文件清单](SOURCE-INVENTORY.json) 与 [历史导出记录](ORIGIN.json)

运行能力取决于配套运行库及其分发策略；`restricted-showcase` 只允许编译时授权的演示包与 API，不能通过宿主配置重新开启禁用能力。真机运行、GPU 和性能验收需绑定实际产物独立验证。原生输入法、无障碍与复杂手势的支持范围见嵌入文档。分发应用时保留 SDK `LICENSE`、运行库 `RUNTIME-LICENSE` 和第三方声明。

<a id="historical-archives-and-migration"></a>
## 历史归档与迁移

运行库发行工具已迁入 [核心仓库](https://github.com/weapp-container/weapp-container/tree/main/tools/runtime-artifacts)。新清单使用核心仓库的精确版本 Release；用 `--manifest` 显式选取。更新后的下载器把旧锁中的 `runtime-artifacts` 标识定向到私有的 `weapp-container/runtime-artifacts-private-archive`，仅允许九个冻结版本，保留原版本、哈希及随附许可，回执记录实际存储库。旧版下载器需升级；同名新仓库只保留停更工具源码。无跨仓库回退，私有档案仍需读取权限，源码许可不代表历史发行物公开可用。

核心运行时与 SDK 自有源码采用 Apache-2.0，可按[主仓库源码构建说明](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)构建当前运行库。现有预编译归档保留原许可、访问要求及精确版本和哈希锁；本次源码更新不发布替代二进制。

<a id="optional-install-reviewed-historical-archives"></a>
### 可选：安装已审核的历史归档


```sh
git clone https://github.com/weapp-container/sdk-ios.git
cd sdk-ios
git checkout a5c9d76b8e8068efbcedbf7af073a138b69f54f2
```

获得运行库访问授权后，通过凭据环境提供 `WEAPP_CONTAINER_RUNTIME_TOKEN`，权限限定为私有产物仓库的 **Contents: read**。不要把凭据写进源码或命令参数。

```sh
node tools/prepare-runtime.mjs
```

使用已获授权的离线归档：

```sh
node tools/prepare-runtime.mjs --artifact-dir /absolute/runtime-archives
```

工具按 [当前公开锁](runtime-artifacts.0.1.0-preview.7.0.lock.json) 校验 **0.1.0-preview.7.0**、ABI 1、架构、大小和 SHA-256，安装到 `.runtime/install/native` 和 `.runtime/install/licenses`。缺少归档、无下载权限或校验不符时会失败；已有安装在失败时保留。锁文件中的 pin 不代表运行库可公开下载。

自定义归档清单使用 `--manifest /absolute/reviewed-lock.json`。慢速网络可通过 `WEAPP_CONTAINER_RUNTIME_TIMEOUT_MS` 调整下载超时，范围为 `1`–`3600000` 毫秒，默认 15 分钟。


归档安装完成后，可在独立 SDK checkout 执行包装层构建：

```sh
node tools/build.mjs --native-root .runtime/install/native --licenses-root .runtime/install/licenses --install-framework
```

源码候选版 `0.1.0-preview.7.1` 用于核心运行库草稿自动化。公开下载及不可变锁仍指向 `0.1.0-preview.7.0`；本次源码更新不代表新 SDK 包已发布。
