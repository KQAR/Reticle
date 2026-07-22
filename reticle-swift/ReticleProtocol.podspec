Pod::Spec.new do |s|
  s.name             = 'ReticleProtocol'
  s.version          = '0.9.2'
  s.summary          = 'Reticle iOS wire-protocol types (shared with the host).'
  s.description      = 'The Swift port of the Reticle protocol model — snapshot, ' \
                       'semantic tree, compact observation, geometry. Pure Swift, no resources. ' \
                       'A CocoaPods wrapper around the reticle-swift SwiftPM package so ' \
                       'CocoaPods-based apps (e.g. KMP iOS apps) can link the agent.'
  s.homepage         = 'https://github.com/KQAR/Reticle'
  s.license          = { :type => 'MIT' }
  s.author           = 'Reticle'
  s.source           = { :http => '' }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.0']
  s.source_files     = 'Sources/ReticleProtocol/**/*.swift'
end
