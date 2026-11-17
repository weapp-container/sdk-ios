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
          screenTop: CGFloat, safeAreaInPortrait: CGRect?, orientation: Orientation?,
          hostLayout: HostLayoutObservation? = nil) {
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
        if let hostLayout {
            guard let layout = hostLayout.payload(viewport: self.viewport) else { return nil }
            fields["hostLayout"] = layout
        }
        payload = .object(fields)
    }
}

/// Versioned surface-local layout. This is independent of the legacy safeArea,
/// which deliberately remains in the owning screen's fixed coordinate space.
struct HostLayoutObservation {
    enum VerticalBarEdge: String { case left, right, none }
    struct Insets { let top: CGFloat; let right: CGFloat; let bottom: CGFloat; let left: CGFloat }
    struct Region { let id: String; let kind: String; let frame: CGRect }
    let safeInsets: Insets
    let verticalBarEdge: VerticalBarEdge
    let reservedRegions: [Region]

    func payload(viewport: CGSize) -> WeappJSON? {
        let insets = safeInsets
        guard [insets.top, insets.right, insets.bottom, insets.left].allSatisfy({ $0.isFinite && $0 >= 0 }),
              insets.left + insets.right < viewport.width + 0.5,
              insets.top + insets.bottom < viewport.height + 0.5,
              reservedRegions.count <= 64 else { return nil }
        var identifiers = Set<String>()
        var regions: [WeappJSON] = []
        for region in reservedRegions.sorted(by: { $0.id < $1.id }) {
            let frame = region.frame
            guard !region.id.isEmpty, region.id.utf8.count <= 256, identifiers.insert(region.id).inserted,
                  ["occlusion", "division"].contains(region.kind),
                  !frame.isNull, !frame.isInfinite,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.minX >= 0, frame.minY >= 0, frame.width > 0, frame.height > 0,
                  frame.maxX <= viewport.width + 0.5, frame.maxY <= viewport.height + 0.5 else { return nil }
            regions.append(.object([
                "id": .string(region.id), "kind": .string(region.kind),
                "x": .number(Double(frame.minX)), "y": .number(Double(frame.minY)),
                "width": .number(Double(frame.width)), "height": .number(Double(frame.height))
            ]))
        }
        return .object([
            "version": .number(1),
            "safeInsets": .object([
                "top": .number(Double(insets.top)), "right": .number(Double(insets.right)),
                "bottom": .number(Double(insets.bottom)), "left": .number(Double(insets.left))
            ]),
            "verticalBarEdge": .string(verticalBarEdge.rawValue),
            "reservedRegions": .array(regions)
        ])
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
        var edge: HostLayoutObservation.VerticalBarEdge = .none
        var regions: [HostLayoutObservation.Region] = []
        if #available(iOS 27.1, *) {
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            switch view.traitCollection.verticalBarEdge {
            case .leading: edge = rtl ? .right : .left
            case .trailing: edge = rtl ? .left : .right
            case .unspecified: edge = .none
            @unknown default: edge = .none
            }
            for (kind, name) in [(UIView.ReservedRegion.Kind.occlusion, "occlusion"), (.division, "division")] {
                // ReservedRegion.ID has equality but its public description is
                // not unique (multiple distinct IDs may describe as "ID()").
                // Normalize geometry ordering and use snapshot-local ordinals.
                let frames = view.reservedRegions(kind: kind).filter(\.isActive).compactMap { region -> CGRect? in
                    // UIKit already includes avoidance margins in frame.
                    let frame = region.frame.intersection(view.bounds)
                    guard !frame.isNull, !frame.isEmpty else { return nil }
                    return frame.offsetBy(dx: -view.bounds.minX, dy: -view.bounds.minY)
                }.sorted { a, b in
                    for (left, right) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
                        if left != right { return left < right }
                    }
                    return false
                }
                for (index, frame) in frames.enumerated() {
                    regions.append(.init(id: "\(name):\(index)", kind: name, frame: frame))
                }
            }
        }
        let insets = view.safeAreaInsets
        guard insets.left + insets.right < view.bounds.width,
              insets.top + insets.bottom < view.bounds.height else { return nil }
        let layout = HostLayoutObservation(
            safeInsets: .init(top: insets.top, right: insets.right, bottom: insets.bottom, left: insets.left),
            verticalBarEdge: edge, reservedRegions: regions)
        self.init(viewport: view.bounds.size, pixelRatio: view.traitCollection.displayScale,
                  screen: screen.coordinateSpace.bounds.size,
                  // A scene without an associated status-bar manager has no
                  // scene status bar. A hidden bar reports CGRect.zero.
                  statusBarHeight: scene.statusBarManager?.statusBarFrame.height ?? 0,
                  screenTop: view.convert(view.bounds, to: screen.coordinateSpace).minY,
                  safeAreaInPortrait: safe, orientation: orientation, hostLayout: layout)
    }
}
#endif
