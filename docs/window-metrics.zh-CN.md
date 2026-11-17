<a id="uikit-window-information-usage"></a>
# UIKit 窗口信息用法

**简体中文** · [English](window-metrics.zh-CN.en.md)


把 `WeappContainerView` 挂载到实际渲染窗口。背景可以铺满 View；安全区用于保护内容和控件。不要根据机型、屏幕宽高比例或方向猜测侧栏位置，也不要将整张画布裁到安全区。

```swift
// 在主线程读取；未挂载、布局无效、正在解绑或已经关闭时返回 nil。
if let metrics = view.captureWindowMetrics() {
    let localLayout = metrics["hostLayout"]
    // 几何证据只用于核对；它不替代 owner / observation / frame 权限校验。
    print(localLayout)
}
```

快照中的旧字段 `safeArea` 仍处于所属屏幕的固定坐标空间，不是当前 View 的 padding。新增容器扩展 `hostLayout` 使用当前渲染 View 局部逻辑坐标：

```js
const layout = wx.getWindowInfo().hostLayout
// version: 1
// safeInsets: { top, right, bottom, left }
// verticalBarEdge: 'left' | 'right' | 'none'
// reservedRegions: [{ id, kind: 'occlusion' | 'division', x, y, width, height }]
```

iOS 27.1+ 依据 `traitCollection.verticalBarEdge` 和有效布局方向解析物理侧边；渲染倍率取 View 的 `traitCollection.displayScale`。保留区域仅包含 UIKit 当前活动的遮挡和折叠区域，裁到 View bounds 后相对画布原点表达。区域 frame 已含系统留白，不要重复扣除 margins。`id` 是当前快照中的稳定排序标识，不代表硬件 ID。完全展开时无效折叠区域不会永久占用空隙。旧系统保留局部安全边距，侧栏为 `none`，区域列表为空；最低支持版本仍为 iOS 16。

页面应让导航、滚动内容和表单遵守局部安全边距；按物理侧栏边缘排列工具，在活动折叠区域两侧安排内容列，并将弹窗放到未被遮挡的可用区域。业务返回和关闭可放在小程序工具区，通过消息通道请求宿主关闭；宿主失败或关闭 UI 在停止交互后替换容器。

```js
const updateLayout = () => {
  const { windowWidth, windowHeight, hostLayout } = wx.getWindowInfo()
  // 用当前完整快照更新页面布局；不要重建会话或清空业务状态。
}
wx.onHostLayoutChange(updateLayout)
// 页面销毁时：wx.offHostLayoutChange(updateLayout)
```

`hostLayout` 与 `onHostLayoutChange/offHostLayoutChange` 是容器扩展。`onResize` 仍只表示窗口尺寸变化。同尺寸下的侧栏、遮挡或折叠区域变化也会使旧触摸和呈现回执失效：先原子更新同步查询快照，再发布局事件，待新画面确认后恢复交互。缺失可选扩展会清除旧布局，不能沿用旧区域。

`captureWindowMetrics()` 与正常更新使用同一个 UIKit 采集器；读取不会触发布局、创建引擎、推进观测身份、确认画面或延长测量期限。Flutter iOS 使用此接口并继续校验完整 owner、surface、observation、布局版本及取消边界。

旋转期间，UIKit 可能先更新窗口尺寸，再更新场景方向。每份完整观测都会刷新同步 API；`onResize` 只在窗口尺寸改变时执行。独立消费者先验证 resize 的窗口尺寸，再在画面呈现后读取新的 JS 快照，与稳定后的 UIKit witness 逐字段比较，包括方向。排队送达的 resize 消息不能代表 UIKit 后续状态。

运行 `npm run test:window-metrics` 可验证数值、缺省及拒绝边界。UIKit 转换、实际事件送达、折叠姿态、RTL 和嵌入窗口需使用独立模拟器 witness 核对。最终 App 需要链接 iOS 27.1+ SDK 才能获得 Duo 全屏系统行为；签名和真机验证分别记录。

依据：[Apple 适配指南](https://developer.apple.com/iphone-duo/prepare/) · [Duo 设计规范](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)。
