<a id="uikit-窗口信息用法"></a>
# UIKit Window Information Usage

[简体中文](window-metrics.zh-CN.md) · **English**


Mount `WeappContainerView` onto the actual rendering window. The background can fill the entire View; the safe area is used to protect content and controls. Do not infer sidebar positions based on device type, screen aspect ratio, or orientation. Do not crop the entire canvas to the safe area.

```swift
// 在主线程读取；未挂载、布局无效、正在解绑或已经关闭时返回 nil。
if let metrics = view.captureWindowMetrics() {
    let localLayout = metrics["hostLayout"]
    // 几何证据只用于核对；它不替代 owner / observation / frame 权限校验。
    print(localLayout)
}
```

The legacy field `safeArea` in snapshots remains in the fixed coordinate space of the original screen and is not the current View's padding. A new container extension, `hostLayout`, uses the local coordinate system of the current rendering View:

```js
const layout = wx.getWindowInfo().hostLayout
// version: 1
// safeInsets: { top, right, bottom, left }
// verticalBarEdge: 'left' | 'right' | 'none'
// reservedRegions: [{ id, kind: 'occlusion' | 'division', x, y, width, height }]
```

On iOS 27.1 and later, physical sidebars are parsed based on `traitCollection.verticalBarEdge` and the effective layout direction; the rendering scale is taken from the View's `traitCollection.displayScale`. The preserved region includes only the currently active UIKit overlay and fold regions, cropped to the View bounds and expressed relative to the canvas origin. The frame of the region already includes system padding—do not deduct margins again. `id` is a stable sort identifier in the current snapshot and does not represent a hardware ID. When fully expanded, inactive fold regions do not permanently consume empty space. Legacy systems retain local safe margins; sidebars are at `none`, and the region list is empty. Minimum supported version remains iOS 16.

Pages should ensure navigation, scroll content, and form elements respect the local safe margins. Arrange tools along the physical sidebar edges, place content columns on both sides of active fold regions, and position popups in available, unobstructed areas. Business return and close actions can be placed in the mini-tool area; request the host to close via a message channel. If the host fails or closes the UI after interaction ends, the container is replaced.

```js
const updateLayout = () => {
  const { windowWidth, windowHeight, hostLayout } = wx.getWindowInfo()
  // 用当前完整快照更新页面布局；不要重建会话或清空业务状态。
}
wx.onHostLayoutChange(updateLayout)
// 页面销毁时：wx.offHostLayoutChange(updateLayout)
```

`hostLayout` and `onHostLayoutChange/offHostLayoutChange` are container extensions. `onResize` still only reflects window size changes. Changes in sidebars, overlays, or fold regions under the same size will invalidate previous touch and presentation receipts: first perform an atomic update to sync the snapshot, then publish layout events, and restore interaction only after the new frame is confirmed. Missing optional extensions will clear the old layout and cannot reuse previous regions.

`captureWindowMetrics()` uses the same UIKit collector as normal updates. Reading operations do not trigger layout updates, engine creation, observer identity promotion, frame confirmation, or extended measurement periods. Flutter on iOS uses this interface and continues to validate full ownership, surface, observation, layout version, and cancellation boundaries.

Running `npm run test:window-metrics` can verify values, defaults, and boundary rejection. UIKit transformations, actual event delivery, fold states, RTL, and embedded window behavior must be validated using a separate simulator. The final App must link to the iOS 27.1+ SDK to access Duo full-screen behavior; signature and device verification are separately recorded.

References: [Apple Adaptation Guide](https://developer.apple.com/iphone-duo/prepare/) · [Duo Design Specifications](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo).


During rotation, UIKit can report a changed viewport before its resolved scene
orientation changes. Each complete observation updates the synchronous APIs;
`onResize` runs only when the viewport size changes. The consumer checks that
callback's viewport, then reads a fresh JS snapshot after presentation and
compares every geometry field, including orientation, with the settled UIKit
witness. A queued resize message is not evidence of UIKit's later state.
