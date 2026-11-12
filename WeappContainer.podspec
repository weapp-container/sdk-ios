Pod::Spec.new do |s|
  s.name = 'WeappContainer'
  s.version = '0.1.0-preview.7.0'
  s.summary = 'Native mini-program SDK with QuickJS and Skia Metal rendering.'
  s.homepage = 'https://github.com/weapp-container/sdk-ios'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author = 'Weapp Container contributors'
  s.source = { :http => 'https://github.com/weapp-container/sdk-ios/releases/download/v0.1.0-preview.7.0/WeappContainer-0.1.0-preview.7.0.zip', :sha256 => '61a385ffb59f34e0317609a905c08215086db2b4dd8f5a57034a6e0f443834a0' }
  s.platform = :ios, '16.0'
  s.swift_version = '5.9'
  s.module_name = 'WeappContainer'
  s.static_framework = true
  s.source_files = 'Sources/WeappContainer/**/*.swift'
  s.vendored_frameworks = 'Frameworks/WeappContainerNative.xcframework'
  s.libraries = 'c++', 'z', 'iconv'
  s.frameworks = 'UIKit', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'CoreFoundation', 'Security', 'SystemConfiguration', 'AVFoundation', 'CoreImage', 'CoreBluetooth', 'CoreLocation', 'CoreMotion', 'Network', 'AudioToolbox', 'CryptoKit', 'Contacts', 'ContactsUI', 'EventKit', 'EventKitUI', 'VisionKit', 'Vision', 'PhotosUI', 'CoreNFC', 'LocalAuthentication'
end
