# Weapp Container iOS SDK

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

## 4. 通信与导航

所有会话和视图 API 在 `MainActor` 上使用：

```swift
try session.sendMessage(.object(["type": .string("refresh")]))
try session.navigate(route: "pages/detail/index", query: ["id": .string("42")])
try session.back()
```

小程序侧使用 `weappContainer.invoke` 调用宿主方法，使用 `postMessage` / `onMessage` 交换消息，类型见 [weapp-container.d.ts](types/weapp-container.d.ts)。宿主方法应在首次 `load` 前注册，参数和结果使用 `WeappJSON`。处理器可以使用 `async throws`；拒绝请求时抛出 `WeappHostError`，异步任务需配合 Swift 任务取消。

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

## 验证与更多用法

```sh
npm test
npm run test:input
node tools/simulator-smoke.mjs --distribution artifacts/ios/WeappContainer --pack /absolute/verified-portable-pack --simulator YOUR_BOOTED_UDID --simulator-only --rotation scene
```

`npm test` 检查封装层输入契约，`test:input` 使用 macOS Swift 编译器检查输入队列，不需要私有运行库。模拟器测试需要已构建的完整分发包、显式 pack 和已启动的模拟器；工具清理自己的测试应用，保留模拟器。`--compile-only` 用于单独编译/链接检查，不能视为设备运行通过。

- [嵌入、窗口尺寸、触摸与生命周期](docs/EMBEDDING.md)
- [宿主服务：设备能力、身份、支付与权限](HOST-SERVICES.md)
- [宿主服务接入示例](examples/host-services/README.md)
- [独立 consumer 工程](examples/consumer/README.md)
- [跨端会话契约](CONTRACT.md)
- [源文件清单](SOURCE-INVENTORY.json) 与 [历史导出记录](ORIGIN.json)

运行能力取决于配套运行库及其分发策略；`restricted-showcase` 只允许编译时授权的演示包与 API，不能通过宿主配置重新开启禁用能力。真机运行、GPU 和性能验收需绑定实际产物独立验证。原生输入法、无障碍与复杂手势的支持范围见嵌入文档。分发应用时保留 SDK `LICENSE`、运行库 `RUNTIME-LICENSE` 和第三方声明。
