Pod::Spec.new do |s|
  s.name = 'WeappContainer'
  s.version = '0.1.0-preview.5.2'
  s.summary = 'Native mini-program SDK with QuickJS and Skia Metal rendering.'
  s.homepage = 'https://github.com/weapp-container/sdk-ios'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author = 'Weapp Container contributors'
  s.source = { :git => 'https://github.com/weapp-container/sdk-ios.git', :tag => "v#{s.version}" }
  s.platform = :ios, '16.0'
  s.swift_version = '5.9'
  s.module_name = 'WeappContainer'
  s.static_framework = true
  s.source_files = 'Sources/WeappContainer/**/*.swift'
  s.vendored_frameworks = 'Frameworks/WeappContainerNative.xcframework'
  s.libraries = 'c++', 'z', 'iconv'
  s.frameworks = 'UIKit', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'CoreFoundation', 'Security', 'SystemConfiguration'
end
