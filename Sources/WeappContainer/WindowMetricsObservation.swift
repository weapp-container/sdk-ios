import Foundation
import CoreGraphics

/// Keeps integer render extents separate from unscaled display observations.
/// `safeAreaInPortrait` must already be in the screen's portrait-up space.
struct WindowMetricsObservation {
    enum Orientation: String { case portrait, landscape }
    let viewport: CGSize
    let pixelRatio: CGFloat
    let payload: WeappJSON

    init?(viewport: CGSize, pixelRatio: CGFloat, screen: CGSize, statusBarHeight: CGFloat,
          screenTop: CGFloat, safeAreaInPortrait: CGRect?, orientation: Orientation?) {
        func extent(_ value: CGFloat) -> CGFloat? {
            guard value.isFinite, value > 0 else { return nil }
            let rounded = max(1, value.rounded())
            return rounded <= CGFloat(UInt32.max) ? rounded : nil
        }
        guard let width = extent(viewport.width), let height = extent(viewport.height),
              let screenWidth = extent(screen.width), let screenHeight = extent(screen.height),
              pixelRatio.isFinite, pixelRatio > 0, screenTop.isFinite,
              statusBarHeight.isFinite, statusBarHeight >= 0, statusBarHeight <= screenHeight + 0.5,
              let orientation else { return nil }
        self.viewport = CGSize(width: width, height: height)
        self.pixelRatio = pixelRatio
        var fields: [String: WeappJSON] = [
            "windowWidth": .number(Double(width)), "windowHeight": .number(Double(height)),
            "pixelRatio": .number(Double(pixelRatio)),
            "screenWidth": .number(Double(screenWidth)), "screenHeight": .number(Double(screenHeight)),
            "statusBarHeight": .number(Double(statusBarHeight)), "screenTop": .number(Double(screenTop)),
            "deviceOrientation": .string(orientation.rawValue)
        ]
        // An unavailable/invalid safe rectangle is optional. Never synthesize
        // it from a viewport, device aspect ratio or rounded render extents.
        if let safe = safeAreaInPortrait,
           !safe.isNull, !safe.isInfinite,
           [safe.minX, safe.maxX, safe.minY, safe.maxY].allSatisfy(\.isFinite),
           safe.size.width > 0, safe.size.height > 0,
           safe.width <= max(screenWidth, screenHeight) + 0.5,
           safe.height <= max(screenWidth, screenHeight) + 0.5 {
            fields["safeArea"] = .object([
                "left": .number(Double(safe.minX)), "right": .number(Double(safe.maxX)),
                "top": .number(Double(safe.minY)), "bottom": .number(Double(safe.maxY)),
                "width": .number(Double(safe.width)), "height": .number(Double(safe.height))
            ])
        }
        payload = .object(fields)
    }
}

#if canImport(UIKit)
import UIKit

extension WindowMetricsObservation {
    @MainActor init?(view: UIView) {
        guard let window = view.window, let scene = window.windowScene else { return nil }
        let orientation: Orientation?
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait, .portraitUpsideDown: orientation = .portrait
        case .landscapeLeft, .landscapeRight: orientation = .landscape
        default: orientation = nil
        }
        let screen = scene.screen
        // UIWindow describes the host's unobscured region. A nested or inset
        // container's safeAreaInsets would instead clip/rebase that region.
        let safe = window.convert(window.safeAreaLayoutGuide.layoutFrame, to: screen.fixedCoordinateSpace)
        self.init(viewport: view.bounds.size, pixelRatio: screen.scale,
                  screen: screen.coordinateSpace.bounds.size,
                  // A scene without an associated status-bar manager has no
                  // scene status bar. A hidden bar reports CGRect.zero.
                  statusBarHeight: scene.statusBarManager?.statusBarFrame.height ?? 0,
                  screenTop: view.convert(view.bounds, to: screen.coordinateSpace).minY,
                  safeAreaInPortrait: safe, orientation: orientation)
    }
}
#endif
