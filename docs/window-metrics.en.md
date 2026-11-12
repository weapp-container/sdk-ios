<a id="uikit-窗口度量"></a>
# UIKit window metrics

[简体中文](window-metrics.md) · **English**


The semantic baseline is WeChat 3.17.3 with `miniprogram-api-typings@5.2.3`.
Its `types/wx/lib.wx.api.d.ts` SHA-256 is
`25e9e6fdab1b4282ee5231d8f8de7a31a177d2edc690ec834e0da479cc166245`;
the `WindowInfo.safeArea` declaration says the rectangle is in the portrait-up
direction and some devices omit it. The public declaration does not establish a
universal origin. This SDK explicitly uses the owning screen's fixed coordinate
space, whose origin and transformations UIKit supplies.

`WindowMetricsObservation` takes the actual `UIWindowScene.screen`. It rounds the
container viewport and current screen extents independently, preserving all
other observations in logical pixels. It converts the owning
`UIWindow.safeAreaLayoutGuide.layoutFrame` into `screen.fixedCoordinateSpace`.
The container's bounds, parent content insets, scroll position and fractional
render quantization cannot clip, rebase or scale this safe region. A partial
window reports that window's observed safe region in the same screen space;
the SDK does not invent a full-device region outside it. A missing or invalid
safe observation is omitted, with no viewport-based substitute.

`screenTop` is the container bounds' upper edge in the current screen coordinate
space, including an offscreen negative value when actually observed. It is not
an input transform. Orientation comes from the scene's resolved interface
orientation, including both landscape directions and upside-down portrait;
neither the container nor screen aspect ratio supplies a fallback.
The scene's status-bar manager reports the actual height (zero when hidden).
A scene with no associated manager has no scene status bar and contributes zero.
A missing scene, unknown interface orientation or invalid mandatory observation
cannot seed a runtime owner or resume its surface.

`WeappContainerView.captureWindowMetrics()` synchronously reads this same UIKit
geometry on the main actor. It returns `nil` until a complete valid measurement
is available, and while detaching or after detach/close. It neither lays out the
view nor creates or updates a runtime, advances an observation, drains events,
acknowledges a frame, or extends a measurement lease. Its result is geometry
evidence, not authorization to apply a layout or enable input. Framework adapters
must still validate the current owner, page, surface and observation identities.
Flutter uses this API rather than deriving a second safe-area or orientation
algorithm. Its paired iOS SDK archive must include this additive Swift API.

Window changes invalidate the wrapper's retained metrics before a new load or
owner can use them. Scene geometry KVO, native safe-area and trait changes,
layout, scene activity, and the existing independent session pump retry actual
observations. The pump also observes parent scrolling while display links are
paused. Input and presentation wait for fresh complete observations. A running
native runtime retains its last accepted synchronous snapshot while paused;
this SDK does not claim that the core currently exposes a snapshot-revocation
operation. Moving between external displays, interactive multiwindow sessions,
status-bar-less scenes and real upside-down devices requires separate acceptance.

The UIKit sources checked on 2026-11-03 were:

- [UIScreen.fixedCoordinateSpace](https://developer.apple.com/documentation/uikit/uiscreen/fixedcoordinatespace): bounds always reflect portrait-up dimensions.
- [UIScreen.coordinateSpace](https://developer.apple.com/documentation/uikit/uiscreen/coordinatespace): current orientation, matching screen bounds.
- [UIStatusBarManager.statusBarFrame](https://developer.apple.com/documentation/uikit/uistatusbarmanager/statusbarframe): scene coordinates; hidden bar returns CGRectZero.
- [UIWindowScene.effectiveGeometry](https://developer.apple.com/documentation/uikit/uiwindowscene/effectivegeometry): KVO-compliant resolved scene geometry.
- Xcode 27.2 (27B52) public UIKit headers for the iPhoneSimulator SDK, including `UIView.h`, `UIScreen.h`, `UIWindowScene.h` and `UIStatusBarManager.h`. The SDK minimum remains iOS 16.

Run `npm run test:window-metrics` for executable Swift numeric/rejection checks.
These checks cover fractional portrait coordinates, independently rounded narrow
viewports, current landscape extents, negative screenTop, absent safe areas,
invalid observations, unknown orientation and screen aspect independence. They
do not certify UIKit conversion or JS transport.

The [independent consumer](../examples/consumer/README.en.md) compares real
`wx.getWindowInfo` delivery against a separate UIKit witness based on window
insets and inverse coordinate-space conversion. Both embedded sessions have
fractional frames. Assertions run on startup, both landscape directions, return
to portrait, persistent reopen and nested scrolling. It also verifies that an
unattached view cannot create an owner from fabricated metrics and that its
pending preflight can be cancelled. A new SDK distribution and executed XCTest
receipt are required; historical artifacts and receipts remain bound to their
original SDK source/native producer commits.


<a id="表面本地布局扩展"></a>
## Surface-local layout extension

`hostLayout` is an optional, versioned container extension in the same atomic
window snapshot. It never changes the fixed-screen semantics of `safeArea`:

```js
const { hostLayout } = wx.getWindowInfo()
// { version: 1,
//   safeInsets: { top, right, bottom, left },
//   verticalBarEdge: 'left' | 'right' | 'none',
//   reservedRegions: [{ id, kind: 'occlusion' | 'division', x, y, width, height }] }
```

Coordinates use the rendering View's local logical points, rebased to its
surface origin. Insets come from that View, not the screen. On iOS 27.1+ the
physical bar edge resolves `verticalBarEdge` against the effective layout
direction; it is never inferred from model names, idiom, or orientation. The
sampler uses the View's trait `displayScale` and actual bounds. Active UIKit
occlusion/division frames are clipped to the View, sorted by kind and geometry,
and assigned snapshot-local IDs. UIKit frames already include margins, so do
not deduct them again. IDs identify regions within the snapshot, not hardware.
Inactive fold regions are absent when completely open. Older OS versions emit
local safe insets with `none` and an empty region list.

Use local safe areas for controls, allow backgrounds to fill the surface, and
split columns or move dialogs away from active division/occlusion frames.
Navigation layout follows the observed physical edge; a horizontal layout uses
`none`. Removing the optional extension clears the prior layout. A change to
only these regions still retires old touches and presentation receipts, installs
the complete synchronous query snapshot, then emits
`wx.onHostLayoutChange(listener)`; unregister with
`wx.offHostLayoutChange(listener)`. `wx.onResize` is reserved for size changes.
These event names and `hostLayout` are container extensions, not standard
WeChat API promises.

The View observes traits affecting the vertical bar edge in addition to native
safe-area callbacks and its independent geometry pump. The read-only capture
uses exactly the same collector without layout, observation, owner, or render
side effects. Link the final application with iOS 27.1+ SDK to receive Duo's
full-display system behavior. Compilation with that SDK does not establish
physical-device, signing, or reserved-region acceptance by itself.

References: [Duo preparation](https://developer.apple.com/iphone-duo/prepare/)
and [Duo design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo).
