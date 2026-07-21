import Foundation

/// `reticle replay gif <trace-dir>` — stitches an `act --trace-output` flow
/// into a device-framed animated GIF (A4 in the roadmap's evidence-workflow
/// lane). Host-local like `mock`: it reads evidence already on disk and never
/// touches a device.
func cmdReplay(_ args: Args) throws {
    switch args.positional(1) {
    case "gif":
        try cmdReplayGif(args)
    default:
        throw HelperError("unknown replay subcommand: \(args.positional(1) ?? "<none>") (expected: gif)")
    }
}

private func cmdReplayGif(_ args: Args) throws {
    guard let tracePath = args.positional(2) ?? args.option("trace") else {
        throw HelperError("usage: reticle replay gif <trace-dir> [--output <file.gif>] [--width <px>] [--frame-ms <ms>]")
    }
    let root = URL(fileURLWithPath: tracePath)
    let steps = try ReplayTraceDiscovery.steps(at: root)

    var options = ReplayRenderer.Options()
    if let width = args.option("width") {
        guard let value = Int(width), value >= 80 else {
            throw HelperError("--width must be an integer ≥ 80")
        }
        options.screenWidth = value
    }
    if let frameMs = args.option("frame-ms") {
        guard let value = Int(frameMs), value >= 100 else {
            throw HelperError("--frame-ms must be an integer ≥ 100")
        }
        options.frameMs = value
    }

    let output = args.option("output").map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("replay.gif")
    let result = try ReplayRenderer.renderGIF(steps: steps, to: output, options: options)

    for actionId in result.skippedSteps {
        FileHandle.standardError.write(Data("replay: skipped \(actionId) (no screenshots)\n".utf8))
    }
    print("replay gif: \(result.outputURL.path) steps=\(result.stepCount) frames=\(result.frameCount) size=\(result.canvasWidth)x\(result.canvasHeight)")
}
