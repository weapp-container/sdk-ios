// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "WeappContainer",
    platforms: [.iOS(.v16)],
    products: [.library(name: "WeappContainer", targets: ["WeappContainer"])],
    targets: [
        .binaryTarget(name: "WeappContainerNative", url: "https://github.com/weapp-container/sdk-ios/releases/download/v0.1.0-preview.7.1/WeappContainerNative-0.1.0-preview.7.1.xcframework.zip", checksum: "e078d84930dd75723c9d61835c4d53adf0034deba2636c11bc66e718f6b47910"),
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
