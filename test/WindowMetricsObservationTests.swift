import Foundation
import CoreGraphics

@main struct WindowMetricsObservationTests {
    private static var assertions = 0
    static func check(_ value: Bool, _ message: String) {
        assertions += 1; precondition(value, message)
    }
    static func observe(viewport: CGSize = CGSize(width: 190.5, height: 646.25),
                        scale: CGFloat = 3, screen: CGSize = CGSize(width: 393.25, height: 852.375),
                        bar: CGFloat = 59.25, top: CGFloat = 83.5,
                        safe: CGRect? = CGRect(x: 0.125, y: 59.25, width: 393.125, height: 759.125),
                        orientation: WindowMetricsObservation.Orientation? = .portrait) -> WindowMetricsObservation? {
        WindowMetricsObservation(viewport: viewport, pixelRatio: scale, screen: screen,
                                 statusBarHeight: bar, screenTop: top,
                                 safeAreaInPortrait: safe, orientation: orientation)
    }
    static func main() {
        let embedded = observe()!
        check(embedded.viewport == CGSize(width: 191, height: 646), "Only render viewport rounds")
        check(embedded.payload["screenWidth"].number == 393 && embedded.payload["screenHeight"].number == 852, "Screen extents round independently")
        let safe = embedded.payload["safeArea"]
        check(safe["left"].number == 0.125 && safe["top"].number == 59.25, "Preserve fractional portrait origin")
        check(safe["right"].number == 393.25 && safe["bottom"].number == 818.375, "Preserve fractional portrait edges")
        check(safe["width"].number == 393.125 && safe["height"].number == 759.125, "Embedded viewport cannot shrink screen safe area")
        check(embedded.payload["screenTop"].number == 83.5 && embedded.payload["statusBarHeight"].number == 59.25, "Display values are never scaled to rounded viewport")
        let scrolled = observe(viewport: CGSize(width: 390.25, height: 380.5), top: -107.125)!
        check(scrolled.payload["safeArea"] == safe, "Moving/reparenting the content does not rebase portrait safe area")
        check(scrolled.payload["screenTop"].number == -107.125, "Offscreen window edge is a finite observation")
        let landscape = observe(screen: CGSize(width: 852.375, height: 393.25), bar: 0, orientation: .landscape)!
        check(landscape.payload["safeArea"] == safe, "Portrait safe coordinates survive current landscape extent")
        check(landscape.payload["deviceOrientation"].string == "landscape", "Use actual orientation, independent of viewport")
        let widePortrait = observe(screen: CGSize(width: 1200, height: 800))!
        check(widePortrait.payload["deviceOrientation"].string == "portrait", "Natural display aspect cannot infer interface orientation")
        let squareLandscape = observe(viewport: CGSize(width: 780, height: 780), scale: 2,
                                      screen: CGSize(width: 780, height: 780), bar: 0,
                                      safe: CGRect(x: 0, y: 0, width: 780, height: 760), orientation: .landscape)!
        check(squareLandscape.payload["deviceOrientation"].string == "landscape", "Square screens retain the resolved scene orientation")
        check(squareLandscape.payload["pixelRatio"].number == 2, "Changed display density is observed without scaling logical geometry")
        check(squareLandscape.payload["safeArea"]["height"].number == 760, "Current display safe region survives square viewports")
        check(observe(bar: 0) != nil, "An observed absent/hidden status bar is valid")
        check(observe(safe: nil)!.payload["safeArea"] == .null, "Omit missing safe observation")
        let offsetSafe = observe(safe: CGRect(x: -0.125, y: 10.25, width: 200.5, height: 300.75))!.payload["safeArea"]
        check(offsetSafe["left"].number == -0.125, "Do not invent a universal safe-area origin")
        check(offsetSafe["width"].number == 200.5, "Do not clamp a safe region to the embedded viewport")
        for rect in [CGRect.null, .infinite, .zero, CGRect(x: 0, y: 0, width: -3, height: 50), CGRect(x: 0, y: 0, width: 900, height: 10)] {
            check(observe(safe: rect)!.payload["safeArea"] == .null, "Do not invent an invalid/unmapped safe rectangle")
        }
        for size in [CGSize.zero, CGSize(width: -CGFloat.infinity, height: 50), CGSize(width: CGFloat.nan, height: 50), CGSize(width: 50, height: -1), CGSize(width: CGFloat(UInt32.max) + 1, height: 50)] {
            check(observe(viewport: size) == nil, "Reject invalid viewport before updating native owner")
            check(observe(screen: size) == nil, "Reject missing/unrepresentable screen dimensions")
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] { check(observe(scale: scale) == nil, "Reject invalid density") }
        for bar in [CGFloat(-1), .nan, .infinity, 853] { check(observe(bar: bar) == nil, "Reject unavailable status bar geometry") }
        check(observe(top: .infinity) == nil, "Reject unavailable screen location")
        check(observe(orientation: nil) == nil, "Unknown orientation must not be guessed from screen aspect")
        check(observe(viewport: CGSize(width: 0.1, height: 0.1))!.viewport == CGSize(width: 1, height: 1), "Positive subpixel viewport remains representable")
        print("Window metrics boundaries passed (\(assertions) assertions). UIKit conversion and JS delivery require the independent simulator consumer.")
    }
}
