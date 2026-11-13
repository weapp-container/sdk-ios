Pod::Spec.new do |s|
  s.name = 'WeappContainer'
  s.version = '0.1.0-preview.7.1'
  s.summary = 'Native mini-program SDK with QuickJS and Skia Metal rendering.'
  s.homepage = 'https://github.com/weapp-container/sdk-ios'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author = 'Weapp Container contributors'
  s.source = { :http => 'https://github.com/weapp-container/sdk-ios/releases/download/v0.1.0-preview.7.1/WeappContainer-0.1.0-preview.7.1.zip', :sha256 => '2675a4da84570ca6e38eb7ba400faa72fbe23b5fdef6f03ec85bb9a778a01ce7', :flatten => true }
  s.platform = :ios, '16.0'
  s.swift_version = '5.9'
  s.module_name = 'WeappContainer'
  s.static_framework = true
  s.source_files = 'Sources/WeappContainer/**/*.swift'
  s.vendored_frameworks = 'Frameworks/WeappContainerNative.xcframework'
  s.libraries = 'c++', 'z', 'iconv'
  s.frameworks = 'UIKit', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'CoreFoundation', 'Security', 'SystemConfiguration', 'AVFoundation', 'CoreImage', 'CoreBluetooth', 'CoreLocation', 'CoreMotion', 'Network', 'AudioToolbox', 'CryptoKit', 'Contacts', 'ContactsUI', 'EventKit', 'EventKitUI', 'VisionKit', 'Vision', 'PhotosUI', 'CoreNFC', 'LocalAuthentication'
end
