// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "WeappContainer",
    platforms: [.iOS(.v16)],
    products: [.library(name: "WeappContainer", targets: ["WeappContainer"])],
    targets: [
        .binaryTarget(name: "WeappContainerNative", path: "Frameworks/WeappContainerNative.xcframework"),
        .target(name: "WeappContainer", dependencies: ["WeappContainerNative"], linkerSettings: [
            .linkedLibrary("c++"), .linkedLibrary("z"), .linkedLibrary("iconv"),
            .linkedFramework("UIKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
            .linkedFramework("CoreGraphics"), .linkedFramework("CoreText"), .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"), .linkedFramework("SystemConfiguration"),
            .linkedFramework("AVFoundation"), .linkedFramework("CoreImage"), .linkedFramework("CoreBluetooth"),
            .linkedFramework("CoreLocation"), .linkedFramework("CoreMotion"), .linkedFramework("Network"),
            .linkedFramework("AudioToolbox"), .linkedFramework("CryptoKit"),
            .linkedFramework("Contacts"), .linkedFramework("ContactsUI"), .linkedFramework("EventKit"), .linkedFramework("EventKitUI"),
            .linkedFramework("VisionKit"), .linkedFramework("Vision"), .linkedFramework("PhotosUI"), .linkedFramework("CoreNFC"), .linkedFramework("LocalAuthentication")
        ])
    ]
)
