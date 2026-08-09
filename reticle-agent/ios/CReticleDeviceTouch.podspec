Pod::Spec.new do |s|
  s.name             = 'CReticleDeviceTouch'
  s.version          = '0.14.0'
  s.summary          = 'In-process UITouch synthesis for a real iOS device (ObjC).'
  s.description      = 'The ObjC half of the Reticle iOS agent: dlsym + objc_msgSend touch ' \
                       'synthesis used on a real device, where no host HID surface exists. ' \
                       'Split out as its own pod because ReticleKit imports it as a module ' \
                       '(`import CReticleDeviceTouch`), matching the SwiftPM target layout.'
  s.homepage         = 'https://github.com/KQAR/Reticle'
  s.license          = { :type => 'MIT' }
  s.author           = 'Reticle'
  s.source           = { :http => '' }
  s.ios.deployment_target = '15.0'
  s.source_files     = 'Sources/CReticleDeviceTouch/**/*.{h,m}'
  s.public_header_files = 'Sources/CReticleDeviceTouch/include/*.h'
  s.frameworks       = 'UIKit'
end
