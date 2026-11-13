<a id="weapp-container-for-ios-preview"></a>
# iOS 端小程序容器（预览版）

**简体中文** · [English](EMBEDDING.en.md)


Native QuickJS + Skia Metal SDK，iOS 16 及以上版本，arm64 设备以及 arm64/x86_64 模拟器。
该应用消耗 Swift 源代码和一个预构建的 C XCFramework。它不编译 Rust，不包含本仓库的 crates，也不嵌入 WebView。

<a id="build-the-distribution"></a>
## 构建发行版

按照独立的 [根级 README](../README.md)：下载已认证、版本锁定的私有运行时归档文件，然后运行 `node tools/build.mjs --native-root .runtime/install/native --licenses-root .runtime/install/licenses --install-framework`。包装器会从这些输入中组装出一个 XCFramework；它从不编译运行时或读取父仓库的检出内容。输出为 `artifacts/ios/WeappContainer`，包含其构建回执和哈希值。

<a id="install"></a>
## 安装

将生成的 `WeappContainer` 目录作为本地 Swift 包添加，并将其中的 `WeappContainer` 产品添加到应用程序目标中。 alternatively:

```ruby
pod 'WeappContainer', :path => '../WeappContainer'
```

生成的目录包含其 podspec、Swift 源代码、XCFramework、许可证、依赖项锁定文件和构建回执。消费应用程序中不需要 Rust 工具链。请勿将 CocoaPods 指向仓库模板。

<a id="embed"></a>
## 嵌入

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

将控制器作为正常的子控制器添加，并为其视图设置约束。
`load` 等待视图的第一次实际窗口布局；模块的同步窗口/系统 API 在初始化期间看到这些测量指标。在布局之前取消该任务将取消等待。包是已验证的本地目录；远程下载和包更新属于宿主应用程序。

开发客户端可以在挂载视图后等待 `session.prepareView()`，在启动前检查能力。它会等待相同的实际指标，并创建一个空的运行时，而不会执行 App/Page JS 代码或确认帧。取消任务或关闭会话将结束等待。在阶段候选视图已准备并加载前，保持已接受的视图挂载；启动时使用 `load`，仅在已加载的会话中使用 `applyDevPack`。这是一个附加的 Swift 封装方法；C ABI 保持不变。

对于 SwiftUI，创建一个 `WeappContainerView` 实例，并将其传递给 `WeappContainerRepresentable(view:)`。调用方拥有会话的生命周期。Flutter 和 React Native 封装器嵌入了相同的 UIKit 视图。

使用 `sendMessage`、`navigate`、`back` 和异步宿主方法进行应用集成。
JSON 值使用 Codable `WeappJSON` 枚举；运行时信封保持私有。宿主方法在加载前注册。对结构化提供者拒绝抛出 `WeappHostError`。原生取消会取消关联的 Swift 任务；处理器应与取消协同操作。

<a id="lifetime-and-rendering"></a>
## 生命周期和渲染

所有会话/视图 API 和回调都是主作用域隔离的。恰好一个视图可以声明一个会话。从窗口中移除它、隐藏它或隐藏其父级会暂停渲染和 JavaScript 定时器。`try session.setForeground(false)` 也会暂停一个仍被挂载的特性；当其视图和场景可见时，才恢复为 `true`。视图轮询无法覆盖显式主机暂停。一个独立的完成定时器在 iOS 允许进程执行的同时，会持续进行 HTTP、主机调用、过期和持久性进度。它不会请求后台执行，也不会延长应用的后台生命周期。

调用 `try await view.detach()` 之后再为同一会话创建替换视图。detach 会保留运行时。`load` 也会替换正在运行的包：它异步地 draining Metal 队列，detach，事务性地加载，成功或失败后重新附加。失败的候选者会保留之前的 App。

正常视图路径将 Skia 直接渲染到 CAMetalLayer 可绘制表面，无需 CPU 快照/读回或图像上传。`onPresented` 在同一 Metal 队列的完成屏障之后触发，而不是在提交时触发。渲染跟踪 SDK 帧修订，包括重绘操作，这些重绘操作会复用应用程序的帧 ID。触摸操作使用逻辑点，绘制操作使用实际屏幕缩放；安全区域以视图的坐标空间进行测量。仅支持一个接触点；额外的接触点会明确取消该操作。

在原生视图内部开始的触摸属于小程序。其自身的手势识别器会阻止祖先 `UIScrollView` 的滑动操作窃取该触摸序列；在宿主周围区域开始的手势仍会正常滚动宿主。SDK 不会更改宿主滚动视图的委托或启用状态。宿主导航和操作系统中断仍可以取消触摸，且取消操作永远不会合成一次点击。

等待需要明确持久性时调用 `session.flushStorage()`，并在释放功能前调用 `session.close()`（或 `view.close()`）。关闭会消耗 GPU 工作，并在持久化之前销毁原生状态。持久化需要稳定的应用/账户存储密钥，且该密钥只有一个写入者；密钥不得从会话 UUID 或包版本生成。默认根目录为应用的 Application Support/WeappContainer 目录。明确调用 `.init(storage: .memoryOnly)` 会选择非持久化存储。去初始化仅是最终清理的安全保障，无法向调用者报告持久化错误。

`wx.request` 使用共享的 reqwest/rustls HTTP(S) 传输层，而不是 URLSession。应用传输安全（ATS）设置不会配置此传输层。使用 URLSession 实现的主机方法遵循该 API 的 ATS 策略。预览版本支持 `wx.request`、存储、窗口/系统信息以及共享合约的小程序子集。暂不支持上传/下载/WebSocket；加载后请查看 `session.capabilities()` 以获取实际编译支持情况。

<a id="independent-consumer-validation"></a>
## 独立的消费者验证

`node tools/simulator-smoke.mjs --distribution /absolute/WeappContainer` 构建并运行仅使用分发的独立示例。该脚本借用了已启动的模拟器，安装了唯一标识的测试应用，记录完成的 Metal 帧、消息、重新加载恢复、存储和生命周期证据，并在结束时移除其自身应用。它从不关闭模拟器。`node scripts/sdk-ios-pod-smoke.mjs` 分别验证 CocoaPods 的安装和消费者链接，使用相同的分发。

设备和英特尔模拟器编译检查与真实的 arm64 模拟器执行分开记录；模拟器运行不能作为设备执行的证据。

使用 `--compile-only` 进行 arm64-device 和 x86_64-simulator 消费者链接，且不与模拟器交互；使用 `--simulator-only` 进行 arm64 模拟器交互门控。两种模式都会验证分发的校验和。
