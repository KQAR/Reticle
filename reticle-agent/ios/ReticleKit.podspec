Pod::Spec.new do |s|
  s.name             = 'ReticleKit'
  s.version          = '0.9.3'
  s.summary          = 'Reticle in-process iOS agent — the linked path.'
  s.description      = 'Link this into an app and call `Reticle.start()` to expose the ' \
                       'loopback inspection/drive server (the analogue of the Android AAR). ' \
                       'This CocoaPods wrapper around the reticle-agent/ios SwiftPM package ' \
                       'lets CocoaPods-based apps (e.g. KMP iOS apps) take the linked path ' \
                       'on a real device, where DYLD injection is unavailable. Pure Swift, no resources.'
  s.homepage         = 'https://github.com/KQAR/Reticle'
  s.license          = { :type => 'MIT' }
  s.author           = 'Reticle'
  s.source           = { :http => '' }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.0']
  s.source_files     = 'Sources/ReticleKit/**/*.swift'
  s.frameworks       = 'UIKit', 'WebKit', 'Network'
  s.dependency 'ReticleProtocol'
end
