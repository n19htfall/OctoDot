// octo-prep: pinned 万象拼音 files → OctoDot's normalized sources.
//
//   octo-prep --source .data/wanxiang/<tag> --out build/data/wanxiang [--lock data/wanxiang.lock]
//             [--unihan .data/unihan/<version> [--daily-extra data/daily-extra.txt]]
//             [--grammar .data/grammar/<language>.gram]
//             [--drop-rules data/wanxiang-typo-rules.txt]
//       writes syllables.tsv, lexicon.tsv, spellings.<scheme>.tsv, aux.tsv,
//       charsets.tsv (with --unihan), grammar.tsv (with --grammar) and
//       report.json, and prints a summary
//   octo-prep grammar-stats --gram FILE.gram --schema wanxiang.schema.yaml --out DIR
//       reads every n-gram of a grammar model and says how many can change a
//       result under the schema's settings, alone and beside the others,
//       writing those to DIR/grammar-ngrams.tsv: for reviewing a new model
//   octo-prep compare OLD/report.json NEW/report.json
//       prints what changed between two reports (make relock uses it)
//   octo-prep readings --sources .data/accuracy --prepared build/data/wanxiang --in FILE --out FILE
//       reads each line of FILE as the corpus sentences are read, for other
//       tools: "text \t syllables"
//   octo-prep accuracy --sources .data/accuracy --prepared build/data/wanxiang --out DIR [--per-category N]
//       builds the accuracy set from data/accuracy.lock's sources: words.tsv,
//       sentences.tsv and review.tsv (what was set aside, and why)
import Foundation
import OctoPrep

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("octo-prep: \(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
if args.count == 4 && args[1] == "compare" {
    func load(_ path: String) -> Report {
        guard let data = FileManager.default.contents(atPath: path),
              let report = try? JSONDecoder().decode(Report.self, from: data)
        else { fail("cannot read the report \(path)") }
        return report
    }
    let lines = compare(load(args[2]), load(args[3]))
    print(lines.isEmpty ? "  no changes in the report's numbers" : lines.joined(separator: "\n"))
    exit(0)
}

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.count >= 2 && args[1] == "grammar-stats" {
    guard let gram = value("--gram"), let schema = value("--schema"), let out = value("--out") else {
        fail("usage: octo-prep grammar-stats --gram FILE.gram --schema wanxiang.schema.yaml --out DIR", code: 2)
    }
    let started = Date()
    do {
        guard let schemaData = FileManager.default.contents(atPath: schema) else { fail("cannot read \(schema)") }
        let (language, settings, _) = try GrammarModel.schema(String(decoding: schemaData, as: UTF8.self))
        let data = try Data(contentsOf: URL(fileURLWithPath: gram), options: .alwaysMapped)
        var keys = GrammarModel.Keys()
        let stats = try GrammarModel.read(data, settings: settings) { key, value in keys.add(key, value) }
        let readTime = Date().timeIntervalSince(started)
        let kept = GrammarModel.reduce(keys, span: settings.span)
        var byLength: [Int: Int] = [:]
        var rows: [(String, Int32)] = []
        rows.reserveCapacity(kept.count + keys.rear.count)
        for i in kept {
            var text = ""
            text.unicodeScalars.append(contentsOf: keys.key(i).map { Unicode.Scalar($0)! })
            rows.append((text, keys.values[i]))
            byLength[keys.key(i).count, default: 0] += 1
        }
        for (key, value) in keys.rear {
            var text = ""
            text.unicodeScalars.append(contentsOf: key)
            rows.append((text, value))
        }
        let written = try GrammarModel.writeTSV(rows, language: language, settings: settings, to: "\(out)/grammar-ngrams.tsv")
        print(String(format: "grammar %@: %d keys read in %.0f s; %d can change a result alone (%d too weak, %d too long, " +
                     "%d undecodable)", language, stats.keys, readTime, stats.kept, stats.tooWeak, stats.tooLong,
                     stats.undecodable))
        print("  \(kept.count) of \(keys.count) needed beside the others (by length " +
              byLength.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") +
              "), and \(keys.rear.count) sentence ends → \(out)/grammar-ngrams.tsv, \(written) bytes")
        print(String(format: "  done in %.1f s", Date().timeIntervalSince(started)))
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if args.count >= 2 && args[1] == "readings" {
    guard let sources = value("--sources"), let prepared = value("--prepared"), let input = value("--in"),
          let output = value("--out") else {
        fail("usage: octo-prep readings --sources .data/accuracy --prepared build/data/wanxiang --in FILE --out FILE", code: 2)
    }
    do {
        let (read, left) = try AccuracySet.readLines(sources: sources, prepared: prepared, input: input, output: output)
        print("readings → \(output): \(read) lines read, \(left) left out (a character with no reading)")
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if args.count >= 2 && args[1] == "accuracy" {
    guard let sources = value("--sources"), let prepared = value("--prepared"), let out = value("--out") else {
        fail("usage: octo-prep accuracy --sources DIR --prepared DIR --out DIR [--per-category N]", code: 2)
    }
    let perCategory = value("--per-category").flatMap { Int($0) } ?? 150
    do {
        let result = try AccuracySet.make(sources: sources, prepared: prepared, out: out, perCategory: perCategory)
        var counts: [(String, Int)] = []
        for l in result.words {
            if counts.last?.0 == l.category { counts[counts.count - 1].1 += 1 } else { counts.append((l.category, 1)) }
        }
        print("accuracy set → \(out): \(result.words.count) words (" +
              counts.map { "\($0.0) \($0.1)" }.joined(separator: ", ") +
              "), \(result.sentences.count) sentences; \(result.review.count) set aside (review.tsv)")
    } catch {
        fail("\(error)")
    }
    exit(0)
}

guard let source = value("--source"), let output = value("--out") else {
    fail("usage: octo-prep --source DIR --out DIR [--lock FILE] [--unihan DIR [--daily-extra FILE]] [--drop-rules FILE] | octo-prep compare OLD NEW", code: 2)
}

let started = Date()
do {
    var options = PrepOptions(source: source, output: output, lock: value("--lock"), unihan: value("--unihan"))
    options.dailyExtra = value("--daily-extra")
    options.grammar = value("--grammar")
    options.agid = value("--agid")
    options.droppedRules = value("--drop-rules")
    let report = try prepare(options)
    print("wanxiang \(report.upstream.tag ?? "unpinned") → \(output)")
    for s in report.sources {
        print("  \(s.file.padding(toLength: 24, withPad: " ", startingAt: 0)) " +
              "\(s.rows) rows, \(s.kept) kept, \(s.duplicates) duplicates merged")
        for issue in s.issues {
            print("      \(issue.dropped ? "dropped" : "noted  ") \(issue.count) × \(issue.reason)")
        }
    }
    print("  entries \(report.entries) (\(report.duplicatesMerged) duplicates merged), " +
          "syllables \(report.syllables) (\(report.plainSyllables) without tones)")
    for s in report.spellings {
        let types = s.rowsByType.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let dropped = s.droppedRules.map { ", \($0) rules dropped" } ?? ""
        print("  \(s.file): \(s.rules) rules → \(s.spellings) spellings, \(s.rows) rows (\(types))\(dropped)")
    }
    if let sets = report.lexicons {
        print("  lexicons: " + sets.map { "\($0.name) \($0.entries)\($0.on ? "" : " (off)")" }.joined(separator: ", "))
    }
    if let g = report.grammar {
        print("  grammar \(g.language): \(g.bytes) bytes, context \(g.maxLength - 1) characters, " +
              "penalties \(g.collocation) / \(g.nonCollocation) / \(g.weakCollocation) / rear \(g.rear), " +
              "\(g.homophones) homophones per span")
    }
    if let c = report.charsets {
        let sets = c.lexiconCharactersBySet.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        print("  charsets (Unicode \(c.unicode)): of the lexicon's \(c.lexiconCharacters) characters, " +
              sets.joined(separator: ", ") + ", in no set \(c.lexiconCharactersInNoSet)")
    }
    print(String(format: "  done in %.1f s", Date().timeIntervalSince(started)))
} catch {
    fail("\(error)")
}
