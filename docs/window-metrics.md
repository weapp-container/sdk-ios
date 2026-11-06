# UIKit window metrics

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

The [independent consumer](../examples/consumer/README.md) compares real
`wx.getWindowInfo` delivery against a separate UIKit witness based on window
insets and inverse coordinate-space conversion. Both embedded sessions have
fractional frames. Assertions run on startup, both landscape directions, return
to portrait, persistent reopen and nested scrolling. It also verifies that an
unattached view cannot create an owner from fabricated metrics and that its
pending preflight can be cancelled. A new SDK distribution and executed XCTest
receipt are required; historical artifacts and receipts remain bound to their
original SDK source/native producer commits.
