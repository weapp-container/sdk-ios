<a id="independent-uikit-consumer"></a>
# 独立的 UIKit 消费者

**简体中文** · [English](README.en.md)


烟雾运行者将准备好的 Swift 包和显式提供的可移植测试 fixture 复制到一个新的消费者目录中。它编译了设备 arm64 和模拟器 x86_64 目标，然后在现有的借来的 arm64 模拟器上运行一个 XCTest。它从不创建或关闭模拟器。

```sh
node tools/simulator-smoke.mjs \
  --distribution /absolute/path/to/WeappContainer \
  --pack /absolute/verified-portable-pack \
  --simulator EXISTING_SIMULATOR_UDID \
  --out artifacts/ios/validation
```

默认的 `--rotation device` 使用 `XCUIDevice.orientation`。`--rotation scene` 分别测试宿主的旋转按钮、`setNeedsUpdateOfSupportedInterfaceOrientations()` 和 `UIWindowScene.requestGeometryUpdate`。两种模式都需要实际的界面方向和原生绘制表面尺寸发生改变并返回到纵向。场景模式的通过并不能证明设备方向注入；每条回执都会记录其模式。

两种模式均保留相同的双会话、异步宿主调用、原生触摸/滚动、导航、后台运行、持久重开、父级/嵌套滚动以及多点触摸门控。两种横屏方向及其返回竖屏时，均通过独立的 UIKit 窗口/屏幕见证器对 `wx.getWindowInfo` 进行比对，包括未缩放的竖屏安全区域边缘、状态栏、小数屏幕顶部、特性显示缩放、绘制表面本地安全内边距/物理垂直条边缘/活动遮挡及分割区域。该独立见证器在不依赖 SDK 辅助工具的情况下，独立对活动区域几何进行归一化处理，并检查只读捕获是否保持观察身份不变。启动、重开和嵌套滚动快照均接受相同的检查。未附加的视图必须等待真实的观察结果，而不能创建原生拥有者，且取消操作必须完成其待定的预检流程。这些是执行的门控，而非从源构建中推断得出；参见 [窗口指标](../../docs/window-metrics.md)。

`--compile-only` 验证设备和 x86_64 的编译/链接，而不使用模拟器；`--simulator-only` 仅构建和运行 arm64 模拟器客户端，跳过其他两个架构的检查。

回执包括分发库存摘要、可执行文件和消费者/测试源代码的哈希值、执行的测试数量以及已验证的应用程序清理。如果 XCTest 失败，运行器会在删除其应用和运行器之前保留 `last-consumer-result.json`。截图和 xcresult 会与回执一同保留。

生成的项目还提供了一个发布归档配置。从导出的消费者运行 `xcodebuild -project SDKConsumer.xcodeproj -scheme SDKConsumer -configuration Release -sdk iphoneos -destination generic/platform=iOS -archivePath /absolute/path/SDKConsumer.xcarchive CODE_SIGNING_ALLOWED=NO archive` 以生成未签名的归档文件。分发签名和真实设备执行是独立的步骤。
