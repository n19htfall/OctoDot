// A spelling table: the syllables each typed spelling stands for, from
// octo-prep's spellings.<scheme>.tsv, where librime's spelling algebra was
// evaluated ahead of time. Spellings are sorted bytewise for binary search,
// and each one's rows hold toned syllable ids of the lexicon it was built
// against, which the image's digest names.
//
// A table is a whole input scheme: full pinyin, 小鹤双拼 and the rest differ
// only here. Everything after it (the graph, the search, learning) works on
// syllables, so switching schemes is loading another table. The image says
// which scheme it is and how its preedit shows input (PREEDIT_*).
//
// Fuzzy pinyin (模糊音, docs/fuzzy-pinyin.md): the table holds the fuzzy
// spellings too, each row tagged with the groups (z = zh, en = eng, ...) its
// derivation needed, as bits of `fuzzy`; the image names the groups. A row
// counts only while every group it needs is on (fuzzy_on, the user's
// choice, none by default), so turning one on or off rebuilds nothing.
import std;
import os;
import dictionary;
import image;
import lexicon;

namespace spelling;

let LAYOUT = 3;
let SECTIONS = 4;
let MAX_LENGTH = 15;
let MAX_FUZZY = 16;

// How a scheme's preedit shows what was typed.
let PREEDIT_TYPED = 0;          // the keys, split by syllable: "zhong guo"
let PREEDIT_SYLLABLES = 1;      // keys standing for syllables, spelling no pinyin (shuangpin); shown as typed too

// librime's SpellingType, in its order: a smaller type is a better spelling.
let NORMAL = 0;
let FUZZY = 1;
let ABBREVIATION = 2;
let COMPLETION = 3;
let AMBIGUOUS = 4;
let INVALID = 5;

struct Spelling { text: u8[..15], rows: u32, count: u16 }        // its rows: rows[rows..rows + count]
// credibility: a log probability, ≤ 0; fuzzy: the fuzzy groups the spelling needs, as bits (0: exact)
struct Row { toned: u16, kind: u8, correction: u8, fuzzy: u16, credibility: f32 }
struct Meta { longest: u16, preedit: u8, id: u8[..15], name: u8[..31] }
struct Group { id: u8[..15] }                                   // a fuzzy group: "z_zh" is z = zh

root struct Table {
    spellings: Spelling[>..] = [],
    rows: Row[>..] = [],
    meta: Meta[>..] = [],
    groups: Group[>..] = []     // bit i of a row's fuzzy is groups[i]
}

// The spelling table the engine uses.
var live = Table {};

// The fuzzy groups the user has on, as bits of the live table's groups.
var fuzzy_on: u32 = 0;

// Whether `row` counts: every fuzzy group it needs is on.
fn usable(row: Row) -> bool { ((row.fuzzy as u32) & ~fuzzy_on) == 0 }

fn kind_code(name: const u8[:]) -> i64 {
    if name == "normal" { return NORMAL; }
    if name == "fuzzy" { return FUZZY; }
    if name == "abbrev" { return ABBREVIATION; }
    if name == "completion" { return COMPLETION; }
    if name == "ambiguous" { return AMBIGUOUS; }
    if name == "invalid" { return INVALID; }
    return -1;
}

// The index of spelling `text`, or -1.
fn find(t: Table&, text: const u8[:]) -> i64 {
    var a: i64 = 0;
    var b = t.spellings.len;
    while a < b {
        let m = a + (b - a) / 2;
        if compare(t.spellings[m].text, text) < 0 { a = m + 1; } else { b = m; }
    }
    return if a < t.spellings.len && compare(t.spellings[a].text, text) == 0 { a } else { -1 };
}

fn starts_with(text: const u8[:], prefix: const u8[:]) -> bool {
    text.len >= prefix.len && compare(text[..prefix.len], prefix) == 0
}

// The spellings that start with `prefix`: [lo, hi). A half-typed last
// syllable is completed from these.
fn prefixed(t: Table&, prefix: const u8[:]) -> i64, i64 {
    var a: i64 = 0;
    var b = t.spellings.len;
    while a < b {
        let m = a + (b - a) / 2;
        if compare(t.spellings[m].text, prefix) < 0 { a = m + 1; } else { b = m; }
    }
    let lo = a;
    b = t.spellings.len;
    while a < b {
        let m = a + (b - a) / 2;
        if starts_with(t.spellings[m].text, prefix) { a = m + 1; } else { b = m; }
    }
    return lo, a;
}

// Every row in place and in range of `syllables` toned syllables, every
// spelling in order: after this no lookup can fail a bounds check.
fn valid(t: Table&, syllables: i64) -> bool {
    guard t.meta.len == 1 && t.meta[0].longest <= MAX_LENGTH && t.meta[0].preedit <= PREEDIT_SYLLABLES &&
          is_id(t.meta[0].id) else { return false; }
    var next: i64 = 0;
    for i in t.spellings.len {
        let s = t.spellings[i];
        if s.text.len == 0 || s.text.len > t.meta[0].longest || s.count == 0 || s.rows != next { return false; }
        if i > 0 && compare(t.spellings[i - 1].text, s.text) >= 0 { return false; }
        next += s.count;
    }
    guard next == t.rows.len && t.groups.len <= MAX_FUZZY else { return false; }
    for g in t.groups { if !is_group(g.id) { return false; } }
    let known: u32 = ((1 << t.groups.len) - 1) as u32;
    for r in t.rows {
        // NaN fails both comparisons
        if r.toned >= syllables || r.kind > INVALID || r.correction > 1 || !(r.credibility <= 0.0) ||
           !(r.credibility > -1000.0) || ((r.fuzzy as u32) & ~known) != 0 {
            return false;
        }
    }
    return true;
}

// A fuzzy group's id: 1 to 15 lowercase letters or '_' ("z_zh", "en_eng").
fn is_group(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= 15 else { return false; }
    for c in text { if !((c >= 'a' && c <= 'z') || c == '_') { return false; } }
    return true;
}

// A scheme id: 1 to 15 lowercase letters, digits or '-': it names files.
fn is_id(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= 15 else { return false; }
    for c in text { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') { return false; } }
    return true;
}

// The keys a typist presses for each toneless syllable of `lex` in scheme
// `t`, by syllable id: its shortest spelling that stands for that syllable
// alone, or, for a syllable the scheme spells only together with another
// (小鹤's "lo" is lo and luo), that shared spelling. In full pinyin the keys
// are the syllable itself. For tests and evaluation: they type as people do.
struct Keys { text: u8[..15] }

fn syllable_keys(t: Table&, lex: lexicon::Lexicon&, keys: Keys[>..]&) {
    keys.clear();
    for p in lex.plain.len { keys.push(Keys { text: lex.plain[p].text }); }
    if t.meta.len == 0 || t.meta[0].id == "fullpinyin" { return; }
    var found: bool[>..] = [];
    for p in lex.plain.len { found.push(false); }
    for s in t.spellings {
        if toned_spelling(s.text) { continue; }
        var plain: i64 = -1;
        var one = true;
        for r in s.rows..s.rows + s.count {
            if t.rows[r].fuzzy != 0 { continue; }        // what a typist presses: exact spellings only
            let p: i64 = lex.toned[t.rows[r].toned].plain;
            if plain < 0 { plain = p; } else if p != plain { one = false; }
        }
        if one && plain >= 0 && (!found[plain] || s.text.len < keys[plain].text.len) {
            keys[plain] = Keys { text: s.text };
            found[plain] = true;
        }
    }
    for s in t.spellings {
        if toned_spelling(s.text) { continue; }
        for r in s.rows..s.rows + s.count {
            if t.rows[r].fuzzy != 0 { continue; }
            let p: i64 = lex.toned[t.rows[r].toned].plain;
            if !found[p] {
                keys[p] = Keys { text: s.text };
                found[p] = true;
            }
        }
    }
}

fn toned_spelling(text: const u8[:]) -> bool {
    for c in text { if c >= '0' && c <= '9' { return true; } }
    return false;
}

fn clear(t: Table&) {
    t.spellings.clear();
    t.rows.clear();
    t.meta.clear();
    t.groups.clear();
}

// Verifies `img` and makes it the live table, if it was built for the
// syllabary `digest` names (which has `syllables` toned syllables). On any
// failure the live table is left empty and false comes back; it never
// aborts on its input.
fn load(img: const u8[:], digest: u64, syllables: i64) -> bool { load_into(live, img, digest, syllables) }

// The same into `t`, so a table can be checked before it replaces the live one.
fn load_into(t: Table&, img: const u8[:], digest: u64, syllables: i64) -> bool {
    let s, opened = image::open(img, image::KIND_SPELLINGS, LAYOUT);
    clear(t);
    guard opened && s.count == SECTIONS && s.digest == digest else { return false; }
    var ok0 = false; var ok1 = false; var ok2 = false; var ok3 = false;
    t.spellings, ok0 = from_bytes<Spelling[>..]>(image::section(img, s, 0));
    t.rows, ok1 = from_bytes<Row[>..]>(image::section(img, s, 1));
    t.meta, ok2 = from_bytes<Meta[>..]>(image::section(img, s, 2));
    t.groups, ok3 = from_bytes<Group[>..]>(image::section(img, s, 3));
    let good = ok0 && ok1 && ok2 && ok3 && valid(t, syllables);
    if !good { clear(t); }
    return good;
}

fn write(t: Table&, digest: u64, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_SPELLINGS, LAYOUT, digest, SECTIONS);
    image::add(out, w, t.spellings);
    image::add(out, w, t.rows);
    image::add(out, w, t.meta);
    image::add(out, w, t.groups);
    image::finish(out, w);
}

// Builds `t` from octo-prep's syllables.tsv and spellings.<scheme>.tsv
// (only its first `limit` spellings when limit > 0). Returns the syllabary
// digest, and false with the reason in `err` for anything malformed.
fn compile(t: Table&, syllables: const u8[:], tsv: const u8[:], limit: i64, err: u8[>..]&) -> u64, bool {
    let digest = hash(syllables);
    var ids = dictionary<const u8[:], i64> {};
    lexicon::toned_ids(syllables, ids);
    var longest: i64 = 0;
    var pos: i64 = 0;
    var row: i64 = 0;
    var meta = Meta { longest: 0, preedit: 0, id: [], name: [] };
    var described = false;
    while pos < tsv.len {
        let line = lexicon::next_line(tsv, pos);
        row++;
        if line.len > 8 && compare(line[..8], "#scheme\t") == 0 {    // #scheme  id  name  preedit
            let id, rest1, ok1 = split_once(line[8..], '\t');
            let name, style, ok2 = split_once(rest1, '\t');
            guard ok1 && ok2 && is_id(id) && name.len > 0 && name.len <= 31 &&
                  (style == "typed" || style == "syllables") else {
                format(err, "spellings:", row, ": expected #scheme, an id, a name and typed or syllables\n");
                return digest, false;
            }
            meta.id.append(id);
            meta.name.append(name);
            meta.preedit = if style == "syllables" { PREEDIT_SYLLABLES } else { PREEDIT_TYPED };
            described = true;
            continue;
        }
        if line.len > 6 && compare(line[..6], "#fuzzy") == 0 {      // #fuzzy  group  group ...
            for raw in split(line[6..], '\t') {
                let group: const u8[:] = raw;
                if group.len == 0 { continue; }
                guard is_group(group) && t.groups.len < MAX_FUZZY else {
                    format(err, "spellings:", row, ": a fuzzy group id, or more than ", MAX_FUZZY, " of them\n");
                    return digest, false;
                }
                t.groups.push(Group { id: group });
            }
            continue;
        }
        if line.len == 0 || line[0] == '#' { continue; }
        let text, rest1, ok1 = split_once(line, '\t');
        let syllable, rest2, ok2 = split_once(rest1, '\t');
        let kind_text, rest3, ok3 = split_once(rest2, '\t');
        let credibility_text, rest4, ok4 = split_once(rest3, '\t');
        let correction_text, fuzzy_text, ok6 = split_once(rest4, '\t');
        let credibility, ok5 = parse_flt(credibility_text);
        let fuzzy, ok7 = parse_int(fuzzy_text);
        let kind = kind_code(kind_text);
        let id = ids.get(syllable);
        guard ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && id && kind >= 0 && text.len > 0 &&
              text.len <= MAX_LENGTH && (correction_text == "0" || correction_text == "1") &&
              fuzzy >= 0 && fuzzy < (1 << t.groups.len) else {
            format(err, "spellings:", row, ": expected spelling, known syllable, kind, credibility, correction, ",
                   "fuzzy groups (of those #fuzzy names)\n");
            return digest, false;
        }
        let n = t.spellings.len;
        if n == 0 || compare(t.spellings[n - 1].text, text) != 0 {
            if n > 0 && compare(t.spellings[n - 1].text, text) > 0 {
                format(err, "spellings:", row, ": not sorted\n");
                return digest, false;
            }
            if limit > 0 && n >= limit { break; }
            t.spellings.push(Spelling { text: text, rows: t.rows.len as u32, count: 0 });
            if text.len > longest { longest = text.len; }
        }
        let last = t.spellings.len - 1;
        guard t.spellings[last].count < 65535 else {
            format(err, "spellings:", row, ": too many syllables for one spelling\n");
            return digest, false;
        }
        t.spellings[last].count += 1;
        t.rows.push(Row { toned: id as u16, kind: kind as u8,
                          correction: if correction_text == "1" { 1 } else { 0 }, fuzzy: fuzzy as u16,
                          credibility: credibility as f32 });
    }
    guard described else {
        format(err, "spellings: no #scheme line naming the scheme\n");
        return digest, false;
    }
    meta.longest = longest as u16;
    t.meta.push(meta);
    guard t.spellings.len > 0 && valid(t, ids.count) else {
        format(err, "the compiled spelling table is empty or fails its own validation\n");
        return digest, false;
    }
    return digest, true;
}
