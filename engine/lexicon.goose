// The lexicon image: every word of the default lexicon, verified before use,
// with an index for common-prefix search over toneless pinyin.
//
// A word is a run of pair ids, one per character. A pair is a character and
// the toned syllable it is read with, so one run carries the text, the code
// and the tones. Entries are sorted by their toneless syllable sequence,
// then by weight, highest first. Toneless syllable ids follow alphabetical
// order, so the syllables a typed prefix such as "zh" stands for have
// contiguous ids, and inside a block their entries are contiguous as well.
//
// Each pair also carries its character's sets, from Unicode's Unihan
// database (octo-prep's charsets.tsv), so a filter on them costs one load.
//
// A word may contain marks with no syllable, such as the dot in 李·卡斯利.
// They live in a side table that only text() reads, so the syllable index
// and the search never see them.
import std;
import os;
import math;
import dictionary;
import image;

namespace lexicon;

let LAYOUT = 4;
let SECTIONS = 11;
let MAX_PAIRS = 65536;
let MAX_LENGTH = 255;
let WEIGHT_SCALE = 2048.0;      // a weight w is stored as log2(w + 1) × WEIGHT_SCALE

// A pair's character sets (Lexicon.flags).
let HAN = 1;        // an ideograph
let TGH = 2;        // in 通用规范汉字表, the 8,105 characters of standard modern use
let GB2312 = 4;
let BIG5 = 8;
let EXTRA = 16;     // OctoDot's additions to the daily set (data/daily-extra.txt)
let ALL_SETS = 31;

struct Plain { text: u8[..7] }                         // a syllable as typed: "zhuang"
struct Toned { plain: u16, tone: u8, text: u8[..15] }  // as written: "zhuāng"; tone 1-4, 0 neutral
struct Pair { cp: u32, toned: u16 }                    // a character and its reading
struct Entry { run: u32, weight: u16, len: u8 }       // the word is runs[run..run + len]
struct Node { syl: u16, start: u32 }                   // where a first syllable's entries with second syllable `syl` start
// What the image is: the core ("core", always on) or a set the user can
// switch (地名), and whether that set is on unless the user turns it off.
struct Meta { total_weight: f64, entries: u32, id: u8[..15], name: u8[..31], on: bool }
struct Mark { entry: u32, at: u8, cp: u32 }            // entry's text has cp before its character `at`

root struct Lexicon {
    plain: Plain[>..] = [],
    toned: Toned[>..] = [],
    pairs: Pair[>..] = [],
    runs: u16[>..] = [],
    entries: Entry[>..] = [],
    first: u32[>..] = [],       // entries with first syllable s: [first[s], first[s + 1])
    second_at: u32[>..] = [],   // their second-syllable nodes: nodes[second_at[s]..second_at[s + 1]]
    nodes: Node[>..] = [],
    meta: Meta[>..] = [],
    flags: u8[>..] = [],        // pair p's character sets: HAN, TGH, GB2312, BIG5, EXTRA
    marks: Mark[>..] = []       // by entry, then position
}

// The lexicon the engine uses, and the digest of its syllabary.
var live = Lexicon {};
var live_digest: u64 = 0;

struct LoadStats { check_ns: i64, verify_ns: i64, validate_ns: i64 }

// The toneless syllable of entry e's character k.
fn syl(lex: Lexicon&, e: Entry, k: i64) -> i64 {
    lex.toned[lex.pairs[lex.runs[e.run + k]].toned].plain
}

// Entry i's sort key at depth d: its syllable there, or -1 if it is shorter.
fn key(lex: Lexicon&, i: i64, d: i64) -> i64 {
    let e = lex.entries[i];
    if d >= e.len { -1 } else { syl(lex, e, d) }
}

// Entries i and j by toneless syllable sequence: -1, 0 or 1.
fn compare_entries(lex: Lexicon&, i: i64, j: i64) -> i64 {
    let a = lex.entries[i];
    let b = lex.entries[j];
    let n: i64 = if a.len < b.len { a.len } else { b.len };
    for k in n {
        let x = syl(lex, a, k);
        let y = syl(lex, b, k);
        if x != y { return if x < y { -1 } else { 1 }; }
    }
    return if a.len < b.len { -1 } else if a.len > b.len { 1 } else { 0 };
}

// Within [lo, hi), where every entry shares its first d syllables: the
// entries whose syllable at depth d lies in [low, high].
fn narrow(lex: Lexicon&, lo: i64, hi: i64, d: i64, low: i64, high: i64) -> i64, i64 {
    var a = lo;
    var b = hi;
    while a < b {
        let m = a + (b - a) / 2;
        if key(lex, m, d) < low { a = m + 1; } else { b = m; }
    }
    let start = a;
    b = hi;
    while a < b {
        let m = a + (b - a) / 2;
        if key(lex, m, d) <= high { a = m + 1; } else { b = m; }
    }
    return start, a;
}

// The entries whose toneless syllables start with `prefix`: [lo, hi).
fn prefix_range(lex: Lexicon&, prefix: const u16[:]) -> i64, i64 {
    guard prefix.len > 0 else { return 0, lex.entries.len; }
    let s1: i64 = prefix[0];
    guard s1 < lex.plain.len else { return 0, 0; }
    var lo: i64 = lex.first[s1];
    var hi: i64 = lex.first[s1 + 1];
    if prefix.len == 1 { return lo, hi; }
    let s2: i64 = prefix[1];
    var a: i64 = lex.second_at[s1];
    var b: i64 = lex.second_at[s1 + 1];
    let end = b;
    while a < b {
        let m = a + (b - a) / 2;
        if lex.nodes[m].syl < s2 { a = m + 1; } else { b = m; }
    }
    guard a < end && lex.nodes[a].syl == s2 else { return 0, 0; }
    lo = lex.nodes[a].start;
    hi = if a + 1 < end { lex.nodes[a + 1].start } else { lex.first[s1 + 1] };
    for d in 2..prefix.len {
        lo, hi = narrow(lex, lo, hi, d, prefix[d], prefix[d]);
        if lo == hi { break; }
    }
    return lo, hi;
}

// The entries whose toneless syllables are exactly `code`, highest weight first.
fn exact(lex: Lexicon&, code: const u16[:]) -> i64, i64 {
    let lo, hi = prefix_range(lex, code);
    var a = lo;
    var b = hi;
    while a < b {                // a block's exact matches come first: they are its shortest
        let m = a + (b - a) / 2;
        if lex.entries[m].len <= code.len { a = m + 1; } else { b = m; }
    }
    return lo, a;
}

// The first mark of entry i or a later one: lex.marks.len if none.
fn first_mark(lex: Lexicon&, i: i64) -> i64 {
    var a: i64 = 0;
    var b = lex.marks.len;
    while a < b {
        let m = a + (b - a) / 2;
        if lex.marks[m].entry < i { a = m + 1; } else { b = m; }
    }
    return a;
}

// Entry i's text, appended as UTF-8, marks included.
fn text(lex: Lexicon&, i: i64, out: u8[>..]&) {
    let e = lex.entries[i];
    var m: i64 = if lex.marks.len == 0 { 0 } else { first_mark(lex, i) };
    for k in e.len {
        while m < lex.marks.len && lex.marks[m].entry == i && lex.marks[m].at == k {
            push_utf8(out, lex.marks[m].cp);
            m++;
        }
        push_utf8(out, lex.pairs[lex.runs[e.run + k]].cp);
    }
    while m < lex.marks.len && lex.marks[m].entry == i {      // after the last character
        push_utf8(out, lex.marks[m].cp);
        m++;
    }
}

fn is_scalar(cp: u32) -> bool { cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) }

// Every cross-reference in range and every structure in order. After this
// no lookup can fail a bounds check, so a loaded lexicon cannot make the
// keystroke path abort, and the binary searches find what they should.
fn valid(lex: Lexicon&) -> bool {
    let np = lex.plain.len;
    let nt = lex.toned.len;
    let npairs = lex.pairs.len;
    let nr = lex.runs.len;
    let ne = lex.entries.len;
    guard np > 0 && np < 65536 && nt < 65536 && npairs <= MAX_PAIRS && nr < 0xFFFFFFFF && ne < 0xFFFFFFFF else {
        return false;
    }
    guard lex.meta.len == 1 && lex.first.len == np + 1 && lex.second_at.len == np + 1 &&
          lex.flags.len == npairs && is_id(lex.meta[0].id) else { return false; }
    for f in lex.flags { if f > ALL_SETS { return false; } }
    var last: i64 = 0;
    for t in lex.toned {
        if t.plain >= np || t.plain < last || t.tone > 4 { return false; }
        last = t.plain;
    }
    for p in lex.pairs { if p.toned >= nt || !is_scalar(p.cp) { return false; } }
    for r in lex.runs { if r >= npairs { return false; } }
    for e in lex.entries { if e.len == 0 || (e.run as i64) + e.len > nr { return false; } }
    for m in lex.marks.len {
        let mark = lex.marks[m];
        if mark.entry >= ne || mark.at > lex.entries[mark.entry].len || !is_scalar(mark.cp) { return false; }
        if m > 0 {
            let prev = lex.marks[m - 1];
            if prev.entry > mark.entry || (prev.entry == mark.entry && prev.at > mark.at) { return false; }
        }
    }

    // The index arrays as a whole first: each must run monotonically from 0
    // to its end, so that every value in it is in bounds before anything is
    // indexed with it. (Checking each step as it is used is not enough:
    // [0, 500, 300] passes its first step and then reads past 300 entries.)
    guard lex.first[0] == 0 && lex.first[np] == ne && lex.second_at[0] == 0 &&
          lex.second_at[np] == lex.nodes.len else { return false; }
    for s in np {
        if lex.first[s] > lex.first[s + 1] || lex.second_at[s] > lex.second_at[s + 1] { return false; }
    }

    for s in np {
        let lo: i64 = lex.first[s];
        let hi: i64 = lex.first[s + 1];
        for i in lo..hi { if syl(lex, lex.entries[i], 0) != s { return false; } }
    }
    for i in 1..ne { if compare_entries(lex, i - 1, i) > 0 { return false; } }

    for s in np {
        let a: i64 = lex.second_at[s];
        let b: i64 = lex.second_at[s + 1];
        let lo: i64 = lex.first[s];
        let hi: i64 = lex.first[s + 1];
        var prev: i64 = -1;
        for n in a..b {
            let node = lex.nodes[n];
            let start: i64 = node.start;
            if node.syl >= np || node.syl <= prev || start < lo || start >= hi { return false; }
            let e = lex.entries[start];
            if e.len < 2 || syl(lex, e, 1) != node.syl { return false; }
            if start > lo && key(lex, start - 1, 1) == node.syl { return false; }   // it marks the first one
            prev = node.syl;
        }
        var distinct: i64 = 0;                    // and there is a node for every second syllable
        var seen: i64 = -1;
        for i in lo..hi {
            let k = key(lex, i, 1);
            if k >= 0 && k != seen { distinct++; seen = k; }
        }
        if distinct != b - a { return false; }
    }
    return true;
}

// A lexicon id: 1 to 15 lowercase letters, digits or '-': it names files.
fn is_id(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= 15 else { return false; }
    for c in text { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') { return false; } }
    return true;
}

fn clear(lex: Lexicon&) {
    lex.plain.clear();
    lex.toned.clear();
    lex.pairs.clear();
    lex.runs.clear();
    lex.entries.clear();
    lex.first.clear();
    lex.second_at.clear();
    lex.nodes.clear();
    lex.meta.clear();
    lex.flags.clear();
    lex.marks.clear();
}

// Verifies `img` and makes it the live lexicon. Anything malformed,
// truncated, corrupted or hostile leaves the live lexicon empty and returns
// false; it never aborts on its input.
fn load(img: const u8[:], stats: LoadStats&) -> bool {
    live_digest = 0;
    let ok, digest = load_into(live, img, stats);
    if ok { live_digest = digest; }
    return ok;
}

// The same into `lex` (a set's slot), returning the syllabary digest the
// image was built against. On failure `lex` is left empty.
fn load_into(lex: Lexicon&, img: const u8[:], stats: LoadStats&) -> bool, u64 {
    var t = clock_ns();
    let s, opened = image::open(img, image::KIND_LEXICON, LAYOUT);
    stats.check_ns = clock_ns() - t;
    clear(lex);
    guard opened && s.count == SECTIONS else { return false, 0; }

    t = clock_ns();
    var ok0 = false; var ok1 = false; var ok2 = false; var ok3 = false; var ok4 = false;
    var ok5 = false; var ok6 = false; var ok7 = false; var ok8 = false; var ok9 = false;
    var ok10 = false;
    lex.plain, ok0 = from_bytes<Plain[>..]>(image::section(img, s, 0));
    lex.toned, ok1 = from_bytes<Toned[>..]>(image::section(img, s, 1));
    lex.pairs, ok2 = from_bytes<Pair[>..]>(image::section(img, s, 2));
    lex.runs, ok3 = from_bytes<u16[>..]>(image::section(img, s, 3));
    lex.entries, ok4 = from_bytes<Entry[>..]>(image::section(img, s, 4));
    lex.first, ok5 = from_bytes<u32[>..]>(image::section(img, s, 5));
    lex.second_at, ok6 = from_bytes<u32[>..]>(image::section(img, s, 6));
    lex.nodes, ok7 = from_bytes<Node[>..]>(image::section(img, s, 7));
    lex.meta, ok8 = from_bytes<Meta[>..]>(image::section(img, s, 8));
    lex.flags, ok9 = from_bytes<u8[>..]>(image::section(img, s, 9));
    lex.marks, ok10 = from_bytes<Mark[>..]>(image::section(img, s, 10));
    stats.verify_ns = clock_ns() - t;

    t = clock_ns();
    let good = ok0 && ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8 && ok9 && ok10 && valid(lex);
    stats.validate_ns = clock_ns() - t;
    if !good {
        clear(lex);
        return false, 0;
    }
    return true, s.digest;
}

fn write(lex: Lexicon&, digest: u64, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_LEXICON, LAYOUT, digest, SECTIONS);
    image::add(out, w, lex.plain);
    image::add(out, w, lex.toned);
    image::add(out, w, lex.pairs);
    image::add(out, w, lex.runs);
    image::add(out, w, lex.entries);
    image::add(out, w, lex.first);
    image::add(out, w, lex.second_at);
    image::add(out, w, lex.nodes);
    image::add(out, w, lex.meta);
    image::add(out, w, lex.flags);
    image::add(out, w, lex.marks);
    image::finish(out, w);
}

// The next line of `text` from `pos`, which moves past it.
fn next_line(text: const u8[:], pos: i64&) -> const u8[:] {
    let start = pos;
    let at = find(text[start..], "\n");
    if at < 0 {
        pos = text.len;
        return text[start..];
    }
    pos = start + at + 1;
    return text[start..start + at];
}

// Toned syllable → id, from octo-prep's syllables.tsv: the line order.
// The keys are views of `tsv`, which the caller keeps.
fn toned_ids(tsv: const u8[:], ids: dictionary<const u8[:], i64>&) {
    var pos: i64 = 0;
    var next: i64 = 0;
    while pos < tsv.len {
        let line = next_line(tsv, pos);
        if line.len == 0 || line[0] == '#' { continue; }
        let toned, rest, ok = split_once(line, '\t');
        if ok {
            ids.insert(toned, next);
            next++;
        }
    }
}

// The set bit a name in charsets.tsv stands for, or 0.
fn set_bit(name: const u8[:]) -> i64 {
    if name == "han" { return HAN; }
    if name == "tgh" { return TGH; }
    if name == "gb2312" { return GB2312; }
    if name == "big5" { return BIG5; }
    if name == "extra" { return EXTRA; }
    return 0;
}

// Character → its set bits, from octo-prep's charsets.tsv.
fn charsets(tsv: const u8[:], sets: dictionary<u32, i64>&, err: u8[>..]&) -> bool {
    var pos: i64 = 0;
    var row: i64 = 0;
    while pos < tsv.len {
        let line = next_line(tsv, pos);
        row++;
        if line.len == 0 || line[0] == '#' { continue; }
        let character, names, ok = split_once(line, '\t');
        var cps: u32[>..] = [];
        each_utf8(character) { cp => cps.push(cp as u32); };
        guard ok && cps.len == 1 && !sets.contains(cps[0]) else {
            format(err, "charsets.tsv:", row, ": expected a new character and its sets\n");
            return false;
        }
        var bits: i64 = 0;
        var at: i64 = 0;
        while at <= names.len {
            var end = find(names[at..], " ");
            end = if end < 0 { names.len } else { at + end };
            let bit = set_bit(names[at..end]);
            guard bit != 0 else {
                format(err, "charsets.tsv:", row, ": unknown set \"", names[at..end], "\"\n");
                return false;
            }
            bits = bits | bit;
            at = end + 1;
        }
        sets.insert(cps[0], bits);
    }
    return true;
}

// Builds `lex` from octo-prep's syllables.tsv, lexicon.tsv (only its first
// `limit` entries when limit > 0) and charsets.tsv. Returns the syllabary
// digest that binds spelling tables to this lexicon, and false, with the
// reason in `err`, for anything malformed: octo-prep already chose what to
// keep, so a row this cannot represent is an error rather than something to
// skip.
fn compile(lex: Lexicon&, syllables: const u8[:], lexicon: const u8[:], sets_tsv: const u8[:], limit: i64,
           err: u8[>..]&) -> u64, bool {
    let digest = hash(syllables);
    var ids = dictionary<const u8[:], i64> {};
    var pos: i64 = 0;
    var row: i64 = 0;
    while pos < syllables.len {
        let line = next_line(syllables, pos);
        row++;
        if line.len == 0 || line[0] == '#' { continue; }
        let toned, rest, ok1 = split_once(line, '\t');
        let plain, tone_text, ok2 = split_once(rest, '\t');
        let tone, ok3 = parse_int(tone_text);
        guard ok1 && ok2 && ok3 && toned.len > 0 && toned.len <= 15 && plain.len > 0 && plain.len <= 7 &&
              tone >= 0 && tone <= 4 && !ids.contains(toned) else {
            format(err, "syllables.tsv:", row, ": expected a new toned syllable, its plain form and a tone\n");
            return digest, false;
        }
        if lex.plain.len == 0 || compare(lex.plain[lex.plain.len - 1].text, plain) < 0 {
            lex.plain.push(Plain { text: plain });
        } else if compare(lex.plain[lex.plain.len - 1].text, plain) > 0 {
            format(err, "syllables.tsv:", row, ": not sorted by plain syllable\n");
            return digest, false;
        }
        ids.insert(toned, lex.toned.len);
        lex.toned.push(Toned { plain: (lex.plain.len - 1) as u16, tone: tone as u8, text: toned });
    }
    guard lex.plain.len > 0 && lex.toned.len < 65536 else {
        format(err, "syllables.tsv: no syllables, or too many\n");
        return digest, false;
    }

    var pair_ids = dictionary<u64, i64> {};
    var total = 0.0;
    var meta = Meta { total_weight: 0.0, entries: 0, id: [], name: [], on: true };
    pos = 0;
    row = 0;
    while pos < lexicon.len {
        let line = next_line(lexicon, pos);
        row++;
        if line.len > 9 && compare(line[..9], "#lexicon\t") == 0 {   // #lexicon  id  name  on|off
            let id, rest1, ok1 = split_once(line[9..], '\t');
            let name, state, ok2 = split_once(rest1, '\t');
            guard ok1 && ok2 && is_id(id) && name.len > 0 && name.len <= 31 && (state == "on" || state == "off") else {
                format(err, "lexicon.tsv:", row, ": expected #lexicon, an id, a name and on or off\n");
                return digest, false;
            }
            meta.id.append(id);
            meta.name.append(name);
            meta.on = state == "on";
            continue;
        }
        if line.len == 0 || line[0] == '#' { continue; }
        if limit > 0 && lex.entries.len >= limit { break; }
        let word, rest1, ok1 = split_once(line, '\t');
        let code, rest2, ok2 = split_once(rest1, '\t');
        let weight_text, source, ok3 = split_once(rest2, '\t');
        let weight, ok4 = parse_flt(weight_text);
        guard ok1 && ok2 && ok3 && ok4 && weight >= 0.0 else {
            format(err, "lexicon.tsv:", row, ": expected text, code, weight and source\n");
            return digest, false;
        }

        var cps: u32[>..] = [];
        each_utf8(word) { cp => cps.push(cp as u32); };
        guard cps.len > 0 && cps.len <= MAX_LENGTH else {
            format(err, "lexicon.tsv:", row, ": empty or too long\n");
            return digest, false;
        }
        let run = lex.runs.len;
        var k: i64 = 0;             // characters read
        var n: i64 = 0;             // syllables read
        var at: i64 = 0;
        while at <= code.len {
            var end = find(code[at..], " ");
            end = if end < 0 { code.len } else { at + end };
            if code[at..end] == "-" && k < cps.len {       // a mark: no syllable
                lex.marks.push(Mark { entry: lex.entries.len as u32, at: n as u8, cp: cps[k] });
                k++;
                at = end + 1;
                continue;
            }
            let id = ids.get(code[at..end]);
            guard id && k < cps.len else {
                format(err, "lexicon.tsv:", row, ": unknown syllable, or more syllables than characters\n");
                return digest, false;
            }
            let pair_key = ((cps[k] as u64) << 16) | (id as u64);
            let pair: i64 = pair_ids.get_or_insert(pair_key, lex.pairs.len);
            if pair == lex.pairs.len {
                guard lex.pairs.len < MAX_PAIRS else {
                    format(err, "lexicon.tsv:", row, ": more than ", MAX_PAIRS, " character readings\n");
                    return digest, false;
                }
                lex.pairs.push(Pair { cp: cps[k], toned: id as u16 });
            }
            lex.runs.push(pair as u16);
            k++;
            n++;
            at = end + 1;
        }
        guard k == cps.len && n > 0 else {
            format(err, "lexicon.tsv:", row, ": fewer syllables than characters\n");
            return digest, false;
        }
        total += weight;
        var q = round(log2(weight + 1.0) * WEIGHT_SCALE);
        if q > 65535.0 { q = 65535.0; }
        lex.entries.push(Entry { run: run as u32, weight: q as u16, len: n as u8 });
        if lex.entries.len > 1 && compare_entries(lex, lex.entries.len - 2, lex.entries.len - 1) > 0 {
            format(err, "lexicon.tsv:", row, ": not sorted by toneless code\n");
            return digest, false;
        }
    }
    guard lex.entries.len > 0 else {
        format(err, "lexicon.tsv: no entries\n");
        return digest, false;
    }

    let np = lex.plain.len;
    for s in np + 1 { lex.first.push(0); }
    for e in lex.entries { lex.first[syl(lex, e, 0) + 1] += 1; }
    for s in np { lex.first[s + 1] += lex.first[s]; }
    for s in np {
        lex.second_at.push(lex.nodes.len as u32);
        var prev: i64 = -1;
        let lo: i64 = lex.first[s];
        let hi: i64 = lex.first[s + 1];
        for i in lo..hi {
            let s2 = key(lex, i, 1);
            if s2 >= 0 && s2 != prev {
                lex.nodes.push(Node { syl: s2 as u16, start: i as u32 });
                prev = s2;
            }
        }
    }
    lex.second_at.push(lex.nodes.len as u32);
    guard meta.id.len > 0 else {
        format(err, "lexicon.tsv: no #lexicon line naming it\n");
        return digest, false;
    }
    meta.total_weight = total;
    meta.entries = lex.entries.len as u32;
    lex.meta.push(meta);
    var sets = dictionary<u32, i64> {};
    if !charsets(sets_tsv, sets, err) { return digest, false; }
    for p in lex.pairs { lex.flags.push(sets.get_or_insert(p.cp, 0) as u8); }

    guard valid(lex) else {
        format(err, "the compiled lexicon fails its own validation\n");
        return digest, false;
    }
    return digest, true;
}
