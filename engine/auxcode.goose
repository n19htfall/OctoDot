// Auxiliary (shape) codes: the short codes one shape scheme gives each
// character, from octo-prep's aux.tsv, which holds 万象's nine schemes.
// Typed after a syllable behind the ` key, a code limits that syllable to
// the characters it fits: "shi`o" is 是 (日人, "or" in 万象's scheme).
//
// Codes belong to characters, not readings, so a table is keyed by code
// point and works with any lexicon; switching schemes loads another table
// and rebuilds nothing.
import std;
import os;
import image;

namespace auxcode;

let LAYOUT = 2;
let SECTIONS = 4;
let MAX_CODE = 7;
let MAX_NAME = 31;

struct Code { text: u8[..7] }
struct Meta { scheme: u8[..31], name: u8[..31] }   // scheme: the id in file names

root struct Table {
    chars: u32[>..] = [],       // code points, ascending
    first: u32[>..] = [],       // character i's codes: codes[first[i]..first[i + 1]]
    codes: Code[>..] = [],
    meta: Meta[>..] = []
}

// The table the engine uses; empty when none is loaded, and then ` is not
// accepted as input.
var live = Table {};

fn loaded() -> bool { live.chars.len > 0 }

// Does character `cp` have a code that starts with `typed`? A half-typed
// code fits every code it begins.
fn fits(t: Table&, cp: u32, typed: const u8[:]) -> bool {
    var a: i64 = 0;
    var b = t.chars.len;
    while a < b {
        let m = a + (b - a) / 2;
        if t.chars[m] < cp { a = m + 1; } else { b = m; }
    }
    guard a < t.chars.len && t.chars[a] == cp else { return false; }
    for k in t.first[a]..t.first[a + 1] {
        let code = t.codes[k].text;
        if code.len >= typed.len && compare(code[..typed.len], typed) == 0 { return true; }
    }
    return false;
}

fn is_code(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= MAX_CODE else { return false; }
    for c in text { if c < 'a' || c > 'z' { return false; } }
    return true;
}

// Characters ascending and the index monotone from 0 to the codes' end:
// after this no lookup can fail a bounds check.
fn valid(t: Table&) -> bool {
    let n = t.chars.len;
    guard t.meta.len == 1 && n < 0xFFFFFFFF && t.codes.len < 0xFFFFFFFF && t.first.len == n + 1 else {
        return false;
    }
    guard t.first[0] == 0 && t.first[n] == t.codes.len else { return false; }
    for i in n {
        if t.first[i] >= t.first[i + 1] { return false; }      // every character listed has a code
        if i > 0 && t.chars[i - 1] >= t.chars[i] { return false; }
    }
    for c in t.codes { if !is_code(c.text) { return false; } }
    return true;
}

fn clear(t: Table&) {
    t.chars.clear();
    t.first.clear();
    t.codes.clear();
    t.meta.clear();
}

// Verifies `img` and makes it the live table. On any failure the live table
// is left empty and false comes back; it never aborts on its input.
fn load(img: const u8[:]) -> bool { load_into(live, img) }

// The same into `t`, so a table can be checked before it replaces the live one.
fn load_into(t: Table&, img: const u8[:]) -> bool {
    let s, opened = image::open(img, image::KIND_AUX, LAYOUT);
    clear(t);
    guard opened && s.count == SECTIONS else { return false; }
    var ok0 = false; var ok1 = false; var ok2 = false; var ok3 = false;
    t.chars, ok0 = from_bytes<u32[>..]>(image::section(img, s, 0));
    t.first, ok1 = from_bytes<u32[>..]>(image::section(img, s, 1));
    t.codes, ok2 = from_bytes<Code[>..]>(image::section(img, s, 2));
    t.meta, ok3 = from_bytes<Meta[>..]>(image::section(img, s, 3));
    let good = ok0 && ok1 && ok2 && ok3 && valid(t);
    if !good { clear(t); }
    return good;
}

fn write(t: Table&, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_AUX, LAYOUT, 0, SECTIONS);
    image::add(out, w, t.chars);
    image::add(out, w, t.first);
    image::add(out, w, t.codes);
    image::add(out, w, t.meta);
    image::finish(out, w);
}

// Field `k` of a tab-separated line, and whether it has one.
fn field(line: const u8[:], k: i64) -> const u8[:], bool {
    var rest = line;
    for i in k {
        let head, tail, ok = split_once(rest, '\t');
        if !ok { return rest[..0], false; }
        rest = tail;
    }
    let head, tail, ok = split_once(rest, '\t');
    return if ok { head } else { rest }, true;
}

// The number of schemes in aux.tsv: the header's fields after "# char".
fn schemes(tsv: const u8[:]) -> i64 {
    let at = find(tsv, "\n");
    let header = if at < 0 { tsv } else { tsv[..at] };
    guard header.len > 7 && compare(header[..7], "# char\t") == 0 else { return 0; }
    var n: i64 = 1;
    for c in header[7..] { if c == '\t' { n++; } }
    return n;
}

// Builds `t` from octo-prep's aux.tsv for its scheme `column` (0 is the
// first), naming the table after it; only its first `limit` characters
// when limit > 0. False, with the reason in `err`, for anything malformed.
fn compile(t: Table&, tsv: const u8[:], column: i64, limit: i64, err: u8[>..]&) -> bool {
    var pos: i64 = 0;
    var row: i64 = 0;
    while pos < tsv.len {
        let start = pos;
        let at = find(tsv[start..], "\n");
        let line = if at < 0 { tsv[start..] } else { tsv[start..start + at] };
        pos = if at < 0 { tsv.len } else { start + at + 1 };
        row++;
        if line.len == 0 { continue; }
        if row == 1 {
            let name, ok = field(line[7..], column);
            guard line.len > 7 && compare(line[..7], "# char\t") == 0 && ok && name.len > 0 &&
                  name.len <= MAX_NAME else {
                format(err, "aux.tsv: no scheme ", column, " in the header\n");
                return false;
            }
            t.meta.push(Meta { scheme: name, name: name });
            continue;
        }
        if line.len > 8 && compare(line[..8], "# names\t") == 0 {      // the display names, in column order
            let title, ok = field(line[8..], column);
            if ok && title.len > 0 && title.len <= MAX_NAME && t.meta.len == 1 {
                t.meta[0].name.clear();
                t.meta[0].name.append(title);
            }
            continue;
        }
        let character, rest, ok1 = split_once(line, '\t');
        var cps: u32[>..] = [];
        each_utf8(character) { cp => cps.push(cp as u32); };
        let codes, ok2 = field(rest, column);
        guard ok1 && ok2 && cps.len == 1 && (t.chars.len == 0 || t.chars[t.chars.len - 1] < cps[0]) else {
            format(err, "aux.tsv:", row, ": expected a new character, in code point order, and its codes\n");
            return false;
        }
        if codes.len == 0 { continue; }        // none in this scheme
        if limit > 0 && t.chars.len >= limit { break; }
        if t.first.len == 0 { t.first.push(0); }
        var from: i64 = 0;
        while from <= codes.len {
            var end = find(codes[from..], " ");
            end = if end < 0 { codes.len } else { from + end };
            guard is_code(codes[from..end]) else {
                format(err, "aux.tsv:", row, ": a code is 1 to ", MAX_CODE, " lowercase letters\n");
                return false;
            }
            t.codes.push(Code { text: codes[from..end] });
            from = end + 1;
        }
        t.chars.push(cps[0]);
        t.first.push(t.codes.len as u32);
    }
    if t.first.len == 0 { t.first.push(0); }
    guard t.meta.len == 1 && t.chars.len > 0 && valid(t) else {
        format(err, "aux.tsv: scheme ", column, " is empty or fails its own validation\n");
        return false;
    }
    return true;
}
