<a id="uikit-window-metrics"></a>
# UIKit 窗口度量

**简体中文** · [English](window-metrics.en.md)

旋转期间，UIKit 可能先更新窗口尺寸，再更新场景方向。每份完整观测都会刷新同步 API；`onResize` 只在窗口尺寸改变时执行。独立消费者先验证 resize 的窗口尺寸，再在画面呈现后读取新的 JS 快照，与稳定后的 UIKit witness 逐字段比较，包括方向。排队送达的 resize 消息不能代表 UIKit 后续状态。


语义基线为 WeChat 3.17.3，带有 `miniprogram-api-typings@5.2.3`。
其 `types/wx/lib.wx.api.d.ts` 的 SHA-256 值为
`25e9e6fdab1b4282ee5231d8f8de7a31a177d2edc690ec834e0da479cc166245`；
`WindowInfo.safeArea` 声明表示矩形位于竖屏向上方向，部分设备会省略该信息。公共声明并未建立通用原点。本 SDK 明确使用所属屏幕的固定坐标空间，其原点和变换由 UIKit 提供。

`WindowMetricsObservation` 采用实际的 `UIWindowScene.screen`。它独立对容器视口和当前屏幕范围进行四舍五入，保留其他所有观察值以逻辑像素表示。它将所属的 `UIWindow.safeAreaLayoutGuide.layoutFrame` 转换为 `screen.fixedCoordinateSpace`。
容器的边界、父内容内边距、滚动位置和分数渲染量化值均不能裁剪、重基或缩放该安全区域。部分窗口会报告该窗口在相同屏幕空间中的观察到的安全区域；SDK 不会在此基础上虚构超出其范围的全设备区域。若缺少或无效的安全区域观察，则会被忽略，且不会提供基于视口的替代值。

`screenTop` 是容器边界在当前屏幕坐标空间中的上边缘，实际观察时可能为负值（即屏幕外）。它并非输入变换。方向来自场景解析的界面方向，包括横屏方向和倒置竖屏方向；容器或屏幕长宽比均不提供回退值。场景的状态栏管理器报告实际高度（隐藏时为零）。无关联管理器的场景没有状态栏，其贡献值为零。缺少场景、未知界面方向或无效的强制观察均无法初始化运行时所有者或恢复其表面。

`WeappContainerView.captureWindowMetrics()` 在主线程上同步读取相同的 UIKit 几何信息。它在完整有效测量可用前返回 `nil`，且在脱离或脱离/关闭后仍返回。它既不布局视图，也不创建或更新运行时，不推进观察，不消耗事件，不确认帧，也不延长测量租约。其结果仅为几何证据，而非授权进行布局或启用输入的依据。框架适配器仍需验证当前所有者、页面、表面和观察身份。Flutter 采用此 API 而非推导第二个安全区域或方向算法。其配套的 iOS SDK 归档必须包含此附加的 Swift API。

窗口变更会使其包装器保留的度量值失效，在新加载或新拥有者使用前必须重新获取。场景几何 KVO、原生安全区域和特性变更、布局、场景活动以及现有独立会话泵的重试均会实际更新该值。
观测。泵在显示链接暂停时也会观察父级滚动。输入和呈现会等待新的完整观测。正在运行的原生运行时在暂停时保留其最后一次接受的同步快照；本SDK并未声称核心当前暴露了快照撤销操作。在不同外部显示器之间切换、交互式多窗口会话、无状态栏场景以及实际倒置的设备场景均需单独接受。

2026-11-03 检查的 UIKit 源码包括：

- [UIScreen.fixedCoordinateSpace](https://developer.apple.com/documentation/uikit/uiscreen/fixedcoordinatespace)：边界始终反映纵向朝上的尺寸。
- [UIScreen.coordinateSpace](https://developer.apple.com/documentation/uikit/uiscreen/coordinatespace)：当前方向，与屏幕边界一致。
- [UIStatusBarManager.statusBarFrame](https://developer.apple.com/documentation/uikit/uistatusbarmanager/statusbarframe)：场景坐标；隐藏状态栏返回 CGRectZero。
- [UIWindowScene.effectiveGeometry](https://developer.apple.com/documentation/uikit/uiwindowscene/effectivegeometry)：KVO兼容的解析场景几何。
- Xcode 27.2 (27B52) 公开的 UIKit 头文件（适用于 iPhoneSimulator SDK），包括 `UIView.h`、`UIScreen.h`、`UIWindowScene.h` 和 `UIStatusBarManager.h`。SDK 最低要求仍为 iOS 16。

运行 `npm run test:window-metrics` 进行可执行 Swift 数值/拒绝检查。
这些检查涵盖纵向坐标的小数部分、独立四舍五入的窄视口、当前横向范围、负的 screenTop、无安全区域、无效观测、未知方向以及屏幕纵横比无关性。它们不保证 UIKit 转换或 JS 传输的正确性。

[独立消费者](../examples/consumer/README.md) 将实际的 `wx.getWindowInfo` 交付结果与基于窗口边距和逆坐标空间转换的独立 UIKit 证据进行对比。两个嵌入式会话均具有小数帧。启动时运行断言，测试横向两个方向、返回纵向、持续重开以及嵌套滚动。它还验证了未附加视图无法从伪造的指标中创建所有者，且其待定预飞行可被取消。需要新的 SDK 分发和执行的 XCTest 收据；历史遗留物和收据仍绑定到其原始 SDK 源码/原生生产者提交。

<a id="surface-local-layout-extension"></a>
## 表面本地布局扩展

`hostLayout` 是一个可选的、版本化的容器扩展，属于同一原子窗口快照。它从不改变 `safeArea` 的固定屏幕语义：

```js
const { hostLayout } = wx.getWindowInfo()
// { version: 1,
//   safeInsets: { top, right, bottom, left },
//   verticalBarEdge: 'left' | 'right' | 'none',
//   reservedRegions: [{ id, kind: 'occlusion' | 'division', x, y, width, height }] }
```

坐标使用渲染 View 的本地逻辑点，基于其表面原点重新定位。边距来自该 View，而非屏幕。在 iOS 27.1 及以上版本中，物理栏边缘会根据有效布局方向解析 `verticalBarEdge`；它从不会根据模型名称、设备类型或方向推断得出。
采样器使用视图的特性 `displayScale` 和实际边界。活动的 UIKit 隐藏/分割帧被裁剪到视图内，按类型和几何关系排序，并分配快照本地 ID。UIKit 帧已包含边距，因此无需再次扣除。这些 ID 识别快照内的区域，而非硬件区域。在完全展开时，非活动的折叠区域将不出现。较旧的 OS 版本会使用本地安全边距（通过 `none`）并发出空区域列表。

为控件使用本地安全区域，允许背景填充整个表面，并将列分隔或将对话框移出活动的分割/遮挡帧。导航布局遵循观察到的物理边缘；水平布局使用 `none`。移除可选扩展将清除之前的布局。仅对这些区域的更改仍会回收旧的触摸和呈现收据，安装完整的同步查询快照，然后发出 `wx.onHostLayoutChange(listener)`；通过 `wx.offHostLayoutChange(listener)` 注销。`wx.onResize` 保留用于尺寸变化。

这些事件名称和 `hostLayout` 属于容器扩展，而非标准 WeChat API 承诺。

视图观察影响垂直条边缘的特性，同时结合原生安全区域回调及其独立的几何泵。只读捕获使用完全相同的收集器，不涉及布局、观察、所有者或渲染副作用。需将最终应用程序链接到 iOS 27.1+ SDK 以获得 Duo 的全屏显示系统行为。使用该 SDK 编译本身并不能建立物理设备、签名或预留区域的接受。

参考资料：[Duo 准备](https://developer.apple.com/iphone-duo/prepare/) 和 [Duo 设计指南](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)。
