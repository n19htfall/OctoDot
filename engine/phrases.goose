// Custom phrases: the user's own list, a text file compiled in the background
// into images that mount like a lexicon set (docs/hotswap-architecture.md).
// The format is 万象's and Rime's custom_phrase.txt, one entry per line:
//
//   text <Tab> code [<Tab> weight]          # and comment lines
//
// Spaces work instead of the tabs: then the text is up to the first space, a
// final number is the weight, and the code is what lies between.
//
//   - A code in pinyin makes a WORD: 雾凇奇观 <Tab> wu song qi guan, or
//     wusongqiguan, or with tone marks, or in the keys of the scheme in use
//     (小鹤双拼: wussqigr). Its readings come from the core lexicon where it
//     knows the characters, so 多音字 read right. Words join sentences and
//     abbreviations in every scheme, being syllables.
//   - Any other code, letters only, is a SHORTCUT: 我的邮箱 <Tab> yx. It is
//     offered first when exactly those keys are typed.
//
// Compiling runs in a contained worker, started by a supervisor thread that
// waits for it (a contained worker cannot report its own abort); the main
// thread only ever loads the result through the verified loaders. The
// worker code touches no globals: a worker gets copies taken at spawn.
import std;
import os;
import math;
import dictionary;
import image;
import lexicon;
import spelling;

namespace phrases;

let MAX_BYTES = 4194304;        // the source file
let MAX_LINES = 100000;
let MAX_CODE = 32;              // a shortcut's keys
let MAX_TEXT = 1024;            // a phrase's text, in bytes
let MAX_SYLLABLES = 16;         // a word's
let LAYOUT = 1;
let SECTIONS = 3;
let DEFAULT_SHORTCUT_WEIGHT = 1000000.0;

// ---- shortcuts ---------------------------------------------------------------------

// A shortcut: code chose pool[text..text + len]; several per code, best first.
struct Shortcut { code: u8[..32], text: u32, len: u16, weight: f32 }
struct Meta { entries: u32 }

root struct Shortcuts {
    list: Shortcut[>..] = [],       // by code, then weight, highest first
    pool: u8[>..] = [],
    meta: Meta[>..] = []
}

var live = Shortcuts {};

fn is_code(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= MAX_CODE else { return false; }
    for c in text { if c < 'a' || c > 'z' { return false; } }
    return true;
}

fn valid(t: Shortcuts&) -> bool {
    guard t.meta.len == 1 && t.meta[0].entries == t.list.len && t.pool.len < 0xFFFFFFFF else { return false; }
    for i in t.list.len {
        let s = t.list[i];
        if !is_code(s.code) || (s.text as i64) + s.len > t.pool.len || s.len == 0 || !(s.weight >= 0.0) { return false; }
        if i > 0 && compare(t.list[i - 1].code, s.code) > 0 { return false; }
    }
    return true;
}

fn clear(t: Shortcuts&) {
    t.list.clear();
    t.pool.clear();
    t.meta.clear();
}

fn load_into(t: Shortcuts&, img: const u8[:]) -> bool {
    let s, opened = image::open(img, image::KIND_SHORTCUTS, LAYOUT);
    clear(t);
    guard opened && s.count == SECTIONS else { return false; }
    var ok0 = false; var ok1 = false; var ok2 = false;
    t.list, ok0 = from_bytes<Shortcut[>..]>(image::section(img, s, 0));
    t.pool, ok1 = from_bytes<u8[>..]>(image::section(img, s, 1));
    t.meta, ok2 = from_bytes<Meta[>..]>(image::section(img, s, 2));
    let good = ok0 && ok1 && ok2 && valid(t);
    if !good { clear(t); }
    return good;
}

fn write(t: Shortcuts&, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_SHORTCUTS, LAYOUT, 0, SECTIONS);
    image::add(out, w, t.list);
    image::add(out, w, t.pool);
    image::add(out, w, t.meta);
    image::finish(out, w);
}

// The shortcuts for exactly `code`: [lo, hi) of t.list.
fn lookup(t: Shortcuts&, code: const u8[:]) -> i64, i64 {
    var a: i64 = 0;
    var b = t.list.len;
    while a < b {
        let m = a + (b - a) / 2;
        if compare(t.list[m].code, code) < 0 { a = m + 1; } else { b = m; }
    }
    var e = a;
    while e < t.list.len && compare(t.list[e].code, code) == 0 { e++; }
    return a, e;
}

// ---- compiling -------------------------------------------------------------------------

// What a compile found: counts, and the first line it could not use.
struct Report { words: u32, shortcuts: u32, skipped: u32, first_bad: u32, why: u8[..120] }

// A word read from a line: its readings back to back in `pairs` of the
// compile, its text in `texts`.
struct Row { pairs: u32, count: u8, text: u32, len: u16, weight: f64 }

fn note_bad(report: Report&, line: i64, why: const u8[:]) {
    report.skipped += 1;
    if report.first_bad == 0 {
        report.first_bad = line as u32;
        report.why.clear();
        report.why.append(if why.len > 120 { why[..120] } else { why });
    }
}

// The first toned syllable of plain syllable p (the table is in plain order).
fn first_toned(core: lexicon::Lexicon&, p: i64) -> i64 {
    var a: i64 = 0;
    var b = core.toned.len;
    while a < b {
        let m = a + (b - a) / 2;
        if (core.toned[m].plain as i64) < p { a = m + 1; } else { b = m; }
    }
    return a;
}

// The reading of character cp as plain syllable p: the core's own, most
// frequent first; else that syllable's first tone.
fn reading(core: lexicon::Lexicon&, cp: u32, p: i64) -> i64 {
    var code: u16[1] = [p as u16];
    let lo, hi = lexicon::exact(core, code[..]);
    for i in lo..hi {
        let pair = core.pairs[core.runs[core.entries[i].run]];
        if pair.cp == cp { return pair.toned; }
    }
    return first_toned(core, p);
}

// Splits letters into exactly n plain syllables, longest first where that
// still leaves a way through; false if there is none.
fn segment(letters: const u8[:], n: i64, plain: dictionary<const u8[:], i64>&, out: i64[>..]&) -> bool {
    out.clear();
    guard n > 0 && n <= MAX_SYLLABLES && letters.len <= 64 else { return false; }
    // can[p][k]: letters[p..] can be read as exactly k syllables
    var can: bool[>..] = [];
    for i in (letters.len + 1) * (n + 1) { can.push(false); }
    can[letters.len * (n + 1) + 0] = true;
    var p = letters.len - 1;
    while p >= 0 {
        for len in 1..9 {
            if p + len > letters.len { break; }
            if !plain.contains(letters[p..p + len]) { continue; }
            for k in 1..n + 1 { if can[(p + len) * (n + 1) + k - 1] { can[p * (n + 1) + k] = true; } }
        }
        p--;
    }
    guard can[0 * (n + 1) + n] else { return false; }
    var at: i64 = 0;
    var left = n;
    while left > 0 {
        var taken = false;
        var len: i64 = 8;
        while len >= 1 && !taken {
            if at + len <= letters.len && can[(at + len) * (n + 1) + left - 1] {
                let id = plain.get(letters[at..at + len]);
                if id {
                    out.push(id);
                    at += len;
                    left--;
                    taken = true;
                }
            }
            len--;
        }
        guard taken else { return false; }
    }
    return true;
}

// The keys of a scheme's spellings that stand for one syllable each (小鹤:
// "vs" for zhong), for reading codes typed in that scheme.
fn scheme_keys(t: spelling::Table&, core: lexicon::Lexicon&, keys: dictionary<const u8[:], i64>&) {
    for s in t.spellings.len {
        let sp = t.spellings[s];
        var digit = false;
        for c in sp.text { if c >= '0' && c <= '9' { digit = true; } }
        if digit { continue; }
        var plain: i64 = -1;
        var one = true;
        for r in sp.rows..sp.rows + sp.count {
            if t.rows[r].fuzzy != 0 { continue; }        // a phrase's code is typed exactly
            let p: i64 = core.toned[t.rows[r].toned].plain;
            if plain < 0 { plain = p; } else if p != plain { one = false; }
        }
        if one && plain >= 0 { keys.insert(t.spellings[s].text, plain); }
    }
}

// Compiles a custom phrase list against the core lexicon and its syllabary
// text: the words into a lexicon image (empty if there are none) and the
// shortcuts into a shortcut image. `keys` reads codes typed in the scheme in
// use (empty for full pinyin). Lines it cannot use are counted, never fatal.
// False only if the words, once read, fail to compile.
fn compile(text: const u8[:], core: lexicon::Lexicon&, syllables: const u8[:], keys: dictionary<const u8[:], i64>&,
           words_img: u8[>..]&, shortcuts_img: u8[>..]&, report: Report&) -> bool {
    var plain = dictionary<const u8[:], i64> {};
    for p in core.plain.len { plain.insert(core.plain[p].text, p); }
    var toned = dictionary<const u8[:], i64> {};
    for t in core.toned.len { toned.insert(core.toned[t].text, t); }

    var rows: Row[>..] = [];
    var pairs: lexicon::Pair[>..] = [];
    var texts: u8[>..] = [];
    var shortcuts = Shortcuts {};
    var order: f64[>..] = [];           // a shortcut's line, to keep file order among equals

    var pos: i64 = 0;
    var line_no: i64 = 0;
    let body = if text.len > MAX_BYTES { text[..MAX_BYTES] } else { text };
    while pos < body.len && line_no < MAX_LINES {
        var line = lexicon::next_line(body, pos);
        line_no++;
        if line.len > 0 && line[line.len - 1] == '\r' { line = line[..line.len - 1]; }
        if line.len == 0 || line[0] == '#' { continue; }
        // Fields by tabs, as in Rime; with no tab, by spaces (a full-width one
        // counts): the text is the first, a final number the weight, the
        // code what lies between.
        let tabbed = find(line, "\t") >= 0;
        var fields: u8[>..] = [];               // the line, a full-width space made plain where tabs are absent
        var i: i64 = 0;
        while i < line.len {
            if !tabbed && i + 2 < line.len && line[i] == 0xE3 && line[i + 1] == 0x80 && line[i + 2] == 0x80 {
                fields.push(' ');
                i += 3;
            } else {
                fields.push(line[i]);
                i++;
            }
        }
        var phrase: const u8[:] = fields[..0];
        var code_field: const u8[:] = fields[..0];
        var weight_text: const u8[:] = fields[..0];
        var has_weight = false;
        if tabbed {
            let p, rest, ok1 = split_once(fields, '\t');
            let c, w, hw = split_once(rest, '\t');
            phrase = p;
            code_field = if hw { c } else { rest };
            weight_text = w;
            has_weight = hw;
        } else {
            let first = find(fields, " ");
            if first > 0 {
                phrase = fields[..first];
                var a = first;
                var b = fields.len;
                while a < b && fields[a] == ' ' { a++; }
                while b > a && fields[b - 1] == ' ' { b--; }
                let middle = fields[a..b];
                let last = rfind(middle, " ");
                var numeric = last >= 0 && last + 1 < middle.len;
                if numeric { for c in middle[last + 1..] { if !((c >= '0' && c <= '9') || c == '.') { numeric = false; } } }
                if numeric {
                    var e = last;
                    while e > 0 && middle[e - 1] == ' ' { e--; }
                    code_field = middle[..e];
                    weight_text = middle[last + 1..];
                    has_weight = true;
                } else {
                    code_field = middle;
                }
            }
        }
        guard phrase.len > 0 && phrase.len <= MAX_TEXT && code_field.len > 0 else {
            note_bad(report, line_no, "expected text, then a tab or space, then a code");
            continue;
        }
        var weight = -1.0;
        if has_weight {
            let w, okw = parse_flt(weight_text);
            if !okw || !(w >= 0.0) || w > 1.0e12 {
                note_bad(report, line_no, "the weight is not a number of 0 or more");
                continue;
            }
            weight = w;
        }
        var cps: u32[>..] = [];
        var scalars = true;
        each_utf8(phrase) { cp => if lexicon::is_scalar(cp as u32) && cp != '\t' { cps.push(cp as u32); } else { scalars = false; } };
        guard scalars && cps.len > 0 else {
            note_bad(report, line_no, "the text is not valid UTF-8");
            continue;
        }

        // A word: the code reads as one syllable per character.
        var ids: i64[>..] = [];         // plain syllables
        var tones: i64[>..] = [];       // toned syllables, -1 where only the plain one was given
        var word = false;
        if cps.len <= MAX_SYLLABLES {
            var spaced = false;
            for c in code_field { if c == ' ' || c == '\'' { spaced = true; } }
            if spaced {
                var fine = true;
                var from: i64 = 0;
                while from <= code_field.len {
                    var end = from;
                    while end < code_field.len && code_field[end] != ' ' && code_field[end] != '\'' { end++; }
                    let token = code_field[from..end];
                    if token.len > 0 {
                        let t = toned.get(token);
                        let p = plain.get(token);
                        if t { ids.push(core.toned[t].plain); tones.push(t); }
                        else if p { ids.push(p); tones.push(-1); }
                        else { fine = false; }
                    }
                    from = end + 1;
                }
                word = fine && ids.len == cps.len;
            } else if segment(code_field, cps.len, plain, ids) ||
                      (keys.count > 0 && segment(code_field, cps.len, keys, ids)) {   // full pinyin, or the scheme's keys
                for i in ids.len { tones.push(-1); }
                word = true;
            } else {
                let t = toned.get(code_field);          // one character, tone mark typed
                if t && cps.len == 1 {
                    ids.push(core.toned[t].plain);
                    tones.push(t);
                    word = true;
                }
            }
        }
        if word {
            // The core's own readings if it has this very word, else each character's.
            var code16: u16[>..] = [];
            for p in ids { code16.push(p as u16); }
            let lo, hi = lexicon::exact(core, code16);
            var same: i64 = -1;
            for i in lo..hi {
                let e = core.entries[i];
                var alike = e.len == cps.len;
                for k in (if alike { e.len } else { 0 }) {
                    if core.pairs[core.runs[e.run + k]].cp != cps[k] { alike = false; break; }
                }
                if alike { same = i; break; }
            }
            let start = pairs.len;
            for k in cps.len {
                var t: i64 = tones[k];
                if t < 0 && same >= 0 { t = core.pairs[core.runs[core.entries[same].run + k]].toned; }
                if t < 0 { t = reading(core, cps[k], ids[k]); }
                pairs.push(lexicon::Pair { cp: cps[k], toned: t as u16 });
            }
            if weight < 0.0 {               // above the core's best word for the same syllables
                weight = 1000.0;
                if lo < hi {
                    let best = exp2(core.entries[lo].weight / lexicon::WEIGHT_SCALE) - 1.0;
                    if 2.0 * best + 1.0 > weight { weight = 2.0 * best + 1.0; }
                }
            }
            rows.push(Row { pairs: start as u32, count: cps.len as u8, text: texts.len as u32, len: phrase.len as u16,
                            weight: weight });
            texts.append(phrase);
            report.words += 1;
            continue;
        }
        if is_code(code_field) {
            shortcuts.list.push(Shortcut { code: code_field, text: shortcuts.pool.len as u32, len: phrase.len as u16,
                                           weight: (if weight >= 0.0 { weight } else { DEFAULT_SHORTCUT_WEIGHT }) as f32 });
            shortcuts.pool.append(phrase);
            order.push(line_no as f64);
            report.shortcuts += 1;
            continue;
        }
        note_bad(report, line_no, "the code is neither pinyin for each character nor a shortcut of letters a-z");
    }

    // Shortcuts by code, then weight, then their order in the file.
    var index: i64[>..] = [];
    for i in shortcuts.list.len { index.push(i); }
    sort(index) { a, b =>
        let x = shortcuts.list[a];
        let y = shortcuts.list[b];
        let c = compare(x.code, y.code);
        c < 0 || (c == 0 && (x.weight > y.weight || (x.weight == y.weight && order[a] < order[b])))
    };
    var sorted = Shortcuts {};
    for i in index { sorted.list.push(shortcuts.list[i]); }
    sorted.pool.append(shortcuts.pool);
    sorted.meta.push(Meta { entries: sorted.list.len as u32 });
    write(sorted, shortcuts_img);

    // Words, in the lexicon's order (syllables, then weight, highest first),
    // as the lexicon compiler reads them.
    guard rows.len > 0 else { return true; }
    sort(rows) { a, b => row_before(a, b, pairs, core, texts) };
    var tsv: u8[>..] = [];
    tsv.append("#lexicon\tcustom\t自定义短语\ton\n");
    var prev = -1;
    for i in rows.len {
        let r = rows[i];
        if prev >= 0 && same_word(rows[prev], r, pairs, texts) { continue; }   // a repeated line: the first, heaviest
        prev = i;
        tsv.append(texts[r.text..r.text + r.len]);
        tsv.push('\t');
        for k in r.count {
            if k > 0 { tsv.push(' '); }
            tsv.append(core.toned[pairs[r.pairs + k].toned].text);
        }
        tsv.push('\t');
        format_flt(tsv, r.weight, 1);
        tsv.append("\tcustom\n");
    }
    var lex = lexicon::Lexicon {};
    var err: u8[>..] = [];
    let digest, ok = lexicon::compile(lex, syllables, tsv, "", 0, err);
    if !ok {
        note_bad(report, 0, err);
        return false;
    }
    lexicon::write(lex, digest, words_img);
    return true;
}

fn row_before(a: Row, b: Row, pairs: lexicon::Pair[>..]&, core: lexicon::Lexicon&, texts: u8[>..]&) -> bool {
    let n: i64 = if a.count < b.count { a.count } else { b.count };
    for k in n {
        let x: i64 = core.toned[pairs[a.pairs + k].toned].plain;
        let y: i64 = core.toned[pairs[b.pairs + k].toned].plain;
        if x != y { return x < y; }
    }
    if a.count != b.count { return a.count < b.count; }
    if a.weight != b.weight { return a.weight > b.weight; }
    return compare(texts[a.text..a.text + a.len], texts[b.text..b.text + b.len]) < 0;
}

fn same_word(a: Row, b: Row, pairs: lexicon::Pair[>..]&, texts: u8[>..]&) -> bool {
    guard a.count == b.count && compare(texts[a.text..a.text + a.len], texts[b.text..b.text + b.len]) == 0 else {
        return false;
    }
    for k in a.count { if pairs[a.pairs + k].toned != pairs[b.pairs + k].toned { return false; } }
    return true;
}

// ---- the background job ----------------------------------------------------------------

// Everything that crosses threads is flat.
struct Job { id: u64, source: u8[..1024], images: u8[..1024], out: u8[..1024], scheme: u8[..15], abort: bool }
struct Done { id: u64, ok: bool, words: u32, shortcuts: u32, skipped: u32, first_bad: u32, why: u8[..200] }

fn done(job: Job, ok: bool, report: Report&, why: const u8[:]) -> Done {
    Done { id: job.id, ok: ok, words: report.words, shortcuts: report.shortcuts, skipped: report.skipped,
           first_bad: report.first_bad, why: if why.len > 200 { why[..200] } else { why } }
}

// Reads the source and the core, compiles, writes lexicon.custom.<job>.img
// (if there are words) and shortcuts.custom.<job>.img atomically into the
// job's directory, and reports. Files named by job, so a superseded job
// finishing late overwrites nothing; the main thread renames the latest
// job's into place. A test can ask it to abort.
thread_fn work(job: Job) {
    assert(!job.abort);                 // contained: proves an abort ends here
    var report = Report { words: 0, shortcuts: 0, skipped: 0, first_bad: 0, why: [] };
    var text: u8[>..] = [];
    if !read_file(job.source, text) {
        qput(done(job, false, report, "the custom phrase file cannot be read"));
        return;
    }
    if text.len > MAX_BYTES {
        qput(done(job, false, report, "the custom phrase file is over 4 MB"));
        return;
    }
    var img: u8[>..] = [];
    var syllables: u8[>..] = [];
    var core = lexicon::Lexicon {};
    var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
    if !read_file(str(job.images, "/lexicon.img"), img) || !read_file(str(job.images, "/syllables.tsv"), syllables) {
        qput(done(job, false, report, "the core lexicon or its syllables cannot be read"));
        return;
    }
    let loaded, digest = lexicon::load_into(core, img, stats);
    img.clear();
    if !loaded || digest != hash(syllables) {
        qput(done(job, false, report, "the core lexicon does not verify against its syllables"));
        return;
    }
    var keys = dictionary<const u8[:], i64> {};    // codes typed in the scheme in use
    var table = spelling::Table {};
    var spellings: u8[>..] = [];
    if job.scheme != "fullpinyin" && read_file(str(job.images, "/spellings.", job.scheme, ".img"), spellings) &&
       spelling::load_into(table, spellings, digest, core.toned.len) {
        scheme_keys(table, core, keys);
    }
    var words: u8[>..] = [];
    var shortcuts: u8[>..] = [];
    let ok = compile(text, core, syllables, keys, words, shortcuts, report);
    var name: u8[>..] = [];
    format(name, job.id);
    let wrote = (words.len == 0 || write_file_atomic(str(job.out, "/lexicon.custom.", name, ".img"), words)) &&
                write_file_atomic(str(job.out, "/shortcuts.custom.", name, ".img"), shortcuts);
    qput(done(job, ok && wrote, report, if !wrote { "the compiled phrases cannot be written" } else { report.why[..] }));
}

// Waits for the worker, so its abort is reported: a contained worker that
// aborts sends nothing itself.
thread_fn supervise(job: Job) {
    var why: u8[>..] = [];
    if !thread_wait(thread_spawn_contained(work, job), why) {
        var report = Report { words: 0, shortcuts: 0, skipped: 0, first_bad: 0, why: [] };
        qput(done(job, false, report, why));
    }
}
