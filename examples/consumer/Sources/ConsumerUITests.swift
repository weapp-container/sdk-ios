import UIKit
import XCTest

@MainActor final class ConsumerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var original: UIDeviceOrientation?
    override func tearDown() { if let original { XCUIDevice.shared.orientation = original }; app?.terminate() }
    func testIndependentSDK() throws {
        continueAfterFailure = false
        original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "__SDK_BUNDLE_ID__")
        app.launch()
        let initial = try wait { $0["loaded"] as? Bool == true && ($0["completedFrames"] as? Int ?? 0) > 0 && $0["hostResult"] != nil && $0["geometry"] != nil && $0["secondLoaded"] as? Bool == true && ($0["secondCompletedFrames"] as? Int ?? 0) > 0 }
        XCTAssertEqual(initial["singleViewRejected"] as? Bool, true)
        XCTAssertEqual(initial["unmeasuredObservationRejected"] as? Bool, true)
        XCTAssertEqual(initial["capturePreservedState"] as? Bool, true)
        XCTAssertEqual((initial["stateAfterPresentation"] as? [String: Any])?["presentationRequired"] as? Bool, true)
        XCTAssertEqual((initial["stateAfterPresentation"] as? [String: Any])?["inputEnabled"] as? Bool, true)
        XCTAssertEqual((initial["secondStateAfterPresentation"] as? [String: Any])?["inputEnabled"] as? Bool, true)
        XCTAssertEqual((initial["capabilitiesAfterPresentation"] as? [String: Any])?["runtime"] as? [String: Any] != nil, true)
        XCTAssertEqual(((initial["capabilitiesAfterPresentation"] as? [String: Any])?["runtime"] as? [String: Any])?["gpuSurface"] as? Bool, true)
        let launched = try XCTUnwrap(initial["initial"] as? [String: Any])
        XCTAssertEqual(launched["windowWidth"] as? Double, initial["surfaceWidth"] as? Double)
        XCTAssertEqual(launched["windowHeight"] as? Double, initial["surfaceHeight"] as? Double)
        XCTAssertGreaterThan(launched["pixelRatio"] as? Double ?? 0, 1)
        try assertWindowMetrics(initial, snapshot: "initial")
        try assertWindowMetrics(initial, snapshot: "geometry")
        try assertWindowMetrics(initial, snapshot: "secondInitial")
        let safe = try XCTUnwrap(launched["safeArea"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(safe["width"] as? Double), try XCTUnwrap(launched["windowWidth"] as? Double), "The embedded view must not clip the public screen safe area")
        capture("initial")
        let surface = app.otherElements["sdk-surface"]
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 80)).tap()
        _ = try wait { ($0["tap"] as? [String: Any])?["count"] as? Int == 1 && $0["timer"] != nil }
        let second = app.otherElements["sdk-second-surface"]
        second.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 80)).tap()
        second.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 80)).tap()
        let isolated = try wait { ($0["secondTap"] as? [String: Any])?["count"] as? Int == 2 }
        XCTAssertEqual((isolated["tap"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertEqual((isolated["secondInitial"] as? [String: Any])?["stored"] as? Int, 0)
        let geometry = try XCTUnwrap(initial["geometry"] as? [String: Any])
        let scroll = try XCTUnwrap(geometry["scroll"] as? [String: Any])
        let x = try XCTUnwrap(scroll["left"] as? Double) + (try XCTUnwrap(scroll["width"] as? Double)) / 2
        let top = try XCTUnwrap(scroll["top"] as? Double), height = try XCTUnwrap(scroll["height"] as? Double)
        let start = surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: top + height * 0.8))
        let end = surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: top + height * 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = try wait { (($0["scroll"] as? [String: Any])?["scrollTop"] as? Double ?? 0) > 0 }
        app.buttons["Next"].tap()
        _ = try wait { $0["currentRoute"] as? String == "pages/detail/index" }
        app.buttons["Back"].tap()
        let returned = try wait { $0["currentRoute"] as? String == "pages/home/index" }
        let showCount = (returned["show"] as? [String: Any])?["shows"] as? Int ?? 0
        capture("tap-and-timer")
        app.buttons["Hidden call"].tap()
        _ = try wait { $0["hiddenCompletionWhileAttached"] as? Bool == true && $0["hiddenPresentationStopped"] as? Bool == true }
        app.buttons["Pause"].tap()
        _ = try wait { $0["hostPausePreserved"] as? Bool == true && $0["hostPausePresentationStopped"] as? Bool == true && $0["foreground"] as? Bool == true }
        XCUIDevice.shared.press(.home)
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed)
        app.activate()
        _ = try wait { (($0["show"] as? [String: Any])?["shows"] as? Int ?? 0) > showCount }
        let sceneRotation = "__SDK_ROTATION_MODE__" == "scene"
        if sceneRotation { app.buttons["Rotate"].tap() } else { XCUIDevice.shared.orientation = .landscapeLeft }
        let rotated = try wait { ($0["surfaceWidth"] as? Double) != (initial["surfaceWidth"] as? Double) && ($0["resize"] as? [String: Any])?["deviceOrientation"] as? String == "landscape" && [3, 4].contains($0["interfaceOrientation"] as? Int ?? 0) }
        try assertWindowMetrics(rotated, snapshot: "resize")
        capture("rotation")
        if sceneRotation { app.buttons["Rotate"].tap() } else { XCUIDevice.shared.orientation = .portrait }
        let upright = try wait { ($0["surfaceWidth"] as? Double) == (initial["surfaceWidth"] as? Double) && ($0["resize"] as? [String: Any])?["deviceOrientation"] as? String == "portrait" && $0["interfaceOrientation"] as? Int == 1 }
        try assertWindowMetrics(upright, snapshot: "resize")
        if sceneRotation { app.buttons["Rotate"].tap() } else { XCUIDevice.shared.orientation = .landscapeRight }
        let otherLandscape = try wait { [3, 4].contains($0["interfaceOrientation"] as? Int ?? 0) && ($0["interfaceOrientation"] as? Int) != (rotated["interfaceOrientation"] as? Int) && ($0["resize"] as? [String: Any])?["deviceOrientation"] as? String == "landscape" }
        try assertWindowMetrics(otherLandscape, snapshot: "resize")
        capture("opposite-landscape")
        if sceneRotation { app.buttons["Rotate"].tap() } else { XCUIDevice.shared.orientation = .portrait }
        let restored = try wait { $0["interfaceOrientation"] as? Int == 1 && ($0["resize"] as? [String: Any])?["deviceOrientation"] as? String == "portrait" }
        try assertWindowMetrics(restored, snapshot: "resize")
        app.buttons["Reload"].tap()
        let reload = try wait { $0["reloaded"] as? Bool == true && ($0["completedFrames"] as? Int ?? 0) > 1 }
        XCTAssertEqual(reload["failedLoadPreservedGeneration"] as? Bool, true)
        XCTAssertEqual(reload["flushed"] as? Bool, true)
        app.buttons["Reopen"].tap()
        let reopened = try wait { $0["reopened"] as? Bool == true && $0["durableClose"] as? Bool == true && ($0["initial"] as? [String: Any])?["stored"] as? Int == 1 && ($0["completedFrames"] as? Int ?? 0) > 0 }
        XCTAssertNil(reopened["failure"])
        try assertWindowMetrics(reopened, snapshot: "initial")
        capture("reopened-persistent")
        app.buttons["Embed"].tap()
        _ = try wait { $0["nested"] as? Bool == true && $0["geometry"] != nil }
        let hostArea = app.otherElements["parent-drag-area"].coordinate(withNormalizedOffset: .zero)
        hostArea.withOffset(CGVector(dx: 180, dy: 100)).press(forDuration: 0.05, thenDragTo: hostArea.withOffset(CGVector(dx: 180, dy: 15)))
        _ = try wait { ($0["parentOffset"] as? Double ?? 0) > 30 }
        app.buttons["Reset"].tap()
        let reset = try wait { abs($0["parentOffset"] as? Double ?? 0) < 1 }
        try assertWindowMetrics(reset, snapshot: "geometry")
        let nestedGeometry = try XCTUnwrap((reset["geometry"] as? [String: Any])?["scroll"] as? [String: Any])
        let nestedX = try XCTUnwrap(nestedGeometry["left"] as? Double) + 50
        let nestedY = try XCTUnwrap(nestedGeometry["top"] as? Double) + 130
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: nestedX, dy: nestedY)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: nestedX, dy: nestedY - 100)))
        let scrolled = try wait { (($0["scroll"] as? [String: Any])?["scrollTop"] as? Double ?? 0) > 30 }
        XCTAssertLessThan(abs(scrolled["parentOffset"] as? Double ?? 0), 1)
        surface.pinch(withScale: 0.6, velocity: -1)
        let afterMultiTouch = try wait { $0["foreground"] as? Bool == true }
        XCTAssertEqual((afterMultiTouch["tap"] as? [String: Any])?["count"] as? Int, 1, "Multi-touch cannot become a tap")
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 80)).tap()
        _ = try wait { ($0["tap"] as? [String: Any])?["count"] as? Int == 2 }
        capture("native-nested-scroll-and-multitouch")
        app.buttons["Close"].tap()
        _ = try wait { $0["pairClosed"] as? Bool == true }
    }
    private func assertWindowMetrics(_ facts: [String: Any], snapshot: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let observed = try XCTUnwrap(facts[snapshot] as? [String: Any], file: file, line: line)
        let native = try XCTUnwrap(facts[snapshot + "NativeWindow"] as? [String: Any], file: file, line: line)
        let captured = try XCTUnwrap(facts[snapshot + "CapturedWindow"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(captured as NSDictionary, native as NSDictionary, "Passive capture must match the independent UIKit witness", file: file, line: line)
        for field in ["windowWidth", "windowHeight", "pixelRatio", "screenWidth", "screenHeight", "screenTop", "statusBarHeight"] {
            XCTAssertEqual(try XCTUnwrap(observed[field] as? Double), try XCTUnwrap(native[field] as? Double), accuracy: 0.000001, "\(snapshot).\(field)", file: file, line: line)
        }
        XCTAssertEqual(observed["deviceOrientation"] as? String, native["deviceOrientation"] as? String, file: file, line: line)
        let safe = try XCTUnwrap(observed["safeArea"] as? [String: Any], file: file, line: line)
        let nativeSafe = try XCTUnwrap(native["safeArea"] as? [String: Any], file: file, line: line)
        for field in ["left", "right", "top", "bottom", "width", "height"] {
            XCTAssertEqual(try XCTUnwrap(safe[field] as? Double), try XCTUnwrap(nativeSafe[field] as? Double), accuracy: 0.000001, "\(snapshot).safeArea.\(field)", file: file, line: line)
        }
    }
    private func wait(_ condition: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        var value: [String: Any] = [:]
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let element = self.app.staticTexts["sdk-observation"]
            guard element.exists, let text = element.value as? String, let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            value = json
            return json["failure"] != nil || condition(json)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 20), .completed, "Last observation: \(value)")
        XCTAssertNil(value["failure"], "\(value)")
        return value
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
