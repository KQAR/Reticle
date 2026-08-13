import Darwin
import ReticleHostCore

// `@main` with an async `main()` rather than top-level `await`: the whole command
// surface is async now (see `HostBackend`), and this is the one place the process
// enters that world. Everything below the entry point stays structured — a command
// that is cancelled tears down its device work with it.
@main
struct ReticleHostMain {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        exit(await ReticleCLI.run(argv))
    }
}
