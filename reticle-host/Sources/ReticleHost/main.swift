import Darwin
import ReticleHostCore

let argv = Array(CommandLine.arguments.dropFirst())
exit(ReticleCLI.run(argv))
