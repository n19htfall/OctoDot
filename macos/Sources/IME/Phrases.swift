import AppKit
import Foundation

/// The user's custom phrase list (engine/phrases.goose): a text file in the
/// IME's container, compiled in the background a moment after every save.
/// Typing never waits for it: the engine compiles in a contained worker, and
/// this polls octo_pump only while a job is pending.
@MainActor
enum Phrases {
    /// Where the list lives: the IME's container, or a scratch folder for the self-test.
    static var directory: URL?
    private static var base: URL { directory ?? Learning.directory }
    static var file: URL { base.appendingPathComponent("custom_phrases.txt") }
    static var cache: URL { base.appendingPathComponent("phrases", isDirectory: true) }

    private static var compiledStamp: Date?     // the file's modification date when last compiled
    private static var timer: Timer?
    private static var folderWatch: DispatchSourceFileSystemObject?
    private static var fileWatch: DispatchSourceFileSystemObject?
    private static var settling: DispatchWorkItem?

    static let template = """
        # OctoDot 自定义短语 · custom phrases
        # One entry per line: text <Tab> code [<Tab> weight]. Lines starting with # are notes.
        #
        # A code in pinyin makes a word. It works in sentences, in abbreviations and in every
        # scheme (全拼 and 小鹤双拼 alike), with spaces between syllables or without:
        #   雾凇奇观\twu song qi guan
        #
        # Any other code, letters a-z only, is a shortcut, offered first when you type exactly it:
        #   我的邮箱地址\tyx
        #
        # A tab or spaces between text and code both work. A code may also be typed in the keys
        # of the scheme in use (小鹤双拼: 雾凇奇观 wussqigr).
        #
        # Save the file; OctoDot picks it up a moment later.

        """

    /// At launch: the last result is in use at once. It is compiled again only
    /// if the file or the IME itself is newer than it, so a result from an
    /// older build never lingers, and an ordinary launch never runs the
    /// compiler (whose worker holds a second copy of the core while it runs).
    static func start() {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        watch()
        guard let stamp = modified(file) else { return }
        let mounted = Engine.shared.mountPhrases(from: cache.path)
        if mounted, let built = modified(cache.appendingPathComponent("shortcuts.custom.img")), built >= stamp,
           let binary = Core.imageURL.flatMap(modified), built >= binary {
            compiledStamp = stamp
            return
        }
        compile()
    }

    /// Watches the folder (an editor that saves by replacing the file changes
    /// it) and the file (one that writes in place changes only the file).
    /// Either way, a quarter second after the last change, a compile.
    private static func watch() {
        if folderWatch == nil { folderWatch = watcher(base) }
        fileWatch?.cancel()
        fileWatch = watcher(file)
    }

    private static func watcher(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib, .link], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { changed() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Stops watching and polling: the self-test when it is done, and the core when it stops.
    static func stop() {
        timer?.invalidate()
        timer = nil
        settling?.cancel()
        folderWatch?.cancel()
        fileWatch?.cancel()
        folderWatch = nil
        fileWatch = nil
        compiledStamp = nil
    }

    private static func changed() {
        settling?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if fileWatch == nil || !FileManager.default.fileExists(atPath: file.path) || replaced() { watch() }
                refreshIfChanged()
            }
        }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The file was replaced (saved by renaming a new copy over it): the
    /// watch on the old one hears nothing more.
    private static func replaced() -> Bool {
        guard let source = fileWatch else { return true }
        var info = stat()
        return fstat(Int32(source.handle), &info) != 0 || info.st_nlink == 0
    }

    /// After a save, and when the input method is activated: compile again if the file changed.
    static func refreshIfChanged() {
        guard let stamp = modified(file), stamp != compiledStamp else { return }
        compile()
    }

    static func compile() {
        compiledStamp = modified(file)
        guard Engine.shared.compilePhrases(source: file.path, into: cache.path) != 0 else { return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !Engine.shared.pump().contains(.pending) else { return }
                timer?.invalidate()
                timer = nil
                let status = Engine.shared.phrasesStatus
                if status.state == .failed { log.error("custom phrases did not compile") }     // no user text in logs
            }
        }
    }

    /// Opens the list in the user's text editor, creating it from the template first.
    static func edit() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? Data(template.utf8).write(to: file, options: .atomic)
            watch()
        }
        NSWorkspace.shared.open(file)
    }

    /// One line for the input menu.
    static var statusLine: String {
        let s = Engine.shared.phrasesStatus
        switch s.state {
        case .idle: return "No custom phrases yet"
        case .compiling: return "Custom phrases: compiling…"
        case .ready:
            var line = "Custom phrases: \(s.words) words, \(s.shortcuts) shortcuts"
            if s.skipped > 0 { line += "; \(s.skipped) lines skipped, first line \(s.firstBadLine): \(s.why)" }
            return line
        case .failed: return "Custom phrases did not compile: \(s.why)"
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
