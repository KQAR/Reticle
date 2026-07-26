// The shared foundation and the network lane were split out of ReticleHostCore
// so the proxy/mock engine builds and tests without the daemon. Re-export them
// so every existing `import ReticleHostCore` (the executable, other host files,
// the test target) keeps seeing JSONValue, the event models, and the network
// types unchanged — the split is an internal boundary, not an API break.
@_exported import ReticleHostShared
@_exported import ReticleNetworkLane
// Same reasoning for the iOS platform backend, split out so the daemon cannot
// reach into platform code and the backend cannot reach up into the CLI.
@_exported import ReticleHostIos
