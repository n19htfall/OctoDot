import AppKit
import Foundation

// OctoDot.app's entry point: the app, or, with a command, the same installer
// from a terminal (make install, make uninstall, the tests), through the same
// XPC service, so development installs take the users' path.
//   --facts      what the installer sees, and the setup state, as JSON
//   --install    install or update the input method (reloading it in place
//                when it can), removing the old com.example install if it is
//                there, after putting its grammar model in the shared folder
//   --enable     add it to the input sources
//   --preflight  the input method's own check, in its sandbox
//   --uninstall  remove it (keeping the user's data) and move this app to the Trash

@MainActor
enum CLI {
    static func run(_ command: String) -> Int32 {
        var status: Int32 = 2
        var done = false
        Task { @MainActor in
            status = await perform(command)
            done = true
        }
        while !done { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return status
    }

    private static func perform(_ command: String) async -> Int32 {
        let installer = InstallerClient.shared
        switch command {
        case "--facts":
            guard let facts = await installer.facts() else { return say(false, Outcome.unreachable.message) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: (try? encoder.encode(facts)) ?? Data(), as: UTF8.self))
            print("state: \(SetupState.of(facts))")
            return 0
        case "--install":
            // The grammar model first, as the app does (GrammarStore), from this app's own copy.
            do {
                if try await GrammarStore.ensure() { print("语法模型已就位。") }
            } catch {
                print("语法模型未能就位（\(error)）；输入法在没有它的情况下继续工作。")
            }
            let (ok, message) = await installer.installIME()
            if ok {
                GrammarStore.prune()
                IMELink.grammarReady()
            }
            return say(ok, message)
        case "--enable":
            let ok = await installer.enableIME()
            return say(ok, ok ? "OctoDot is among your input sources." :
                       "Not enabled yet: System Settings → Keyboard → Input Sources.")
        case "--preflight":
            guard let preflight = await installer.preflight() else { return say(false, "The check did not run.") }
            print(preflight)
            return preflight.ok ? 0 : 1
        case "--uninstall":
            let (ok, message) = await installer.uninstall(wipe: false)
            if ok { GrammarStore.removeAll() }
            return say(ok, message)
        default:
            print("usage: OctoDot [--facts | --install | --enable | --preflight | --uninstall]")
            return 2
        }
    }

    private static func say(_ ok: Bool, _ message: String) -> Int32 {
        print(message)
        return ok ? 0 : 1
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
    exit(CLI.run(CommandLine.arguments[1]))
}
CompanionApp.main()
