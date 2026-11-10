// English words beside the Chinese, from 万象's dictionary (docs/english-design.md).
//
// One entry per code: the letters, lowercased, spaces and punctuation dropped.
// Codes are sorted, so an exact match and a prefix's range are binary searches.
// A code's forms are in weight order (in, In, IN) and its score is log2 of
// their summed weight. The same letters are Chinese and English at once;
// where a word is placed is decided in the session, not here.
import std;
import math;
import image;

namespace english;

let LAYOUT = 1;
let SECTIONS = 4;
let MAX_CODE = 32;
let MAX_FORMS = 4;
let MIN_SPAN = 3;               // a word in the sentence graph, phase 2
let MAX_ENTRIES = 200000;
// The 2,000th code in the pinned en.dict (weight 3,871). A word at least
// this common goes second when the first candidate stays Chinese.
let COMMON_WEIGHT = 3871;
// Phase 2: an English word's score, less this, weighed against Chinese
// readings of the same keys. Large enough that a corpus sentence stays
// Chinese (section 6); small enough that a span with no Chinese reading
// (github in 我用GitHub) still completes the sentence.
let SWITCH_PENALTY = 80.0;
// An exact match comes first when the best Chinese reading of the same
// keys is this many bits less likely than it (2^25 times): the Chinese is
// then pieced together from rare characters (的这螺片蒽酮 for development
// in 小鹤双拼; 和来咯 for hello in full pinyin). Measured 2026-11-09 on
// every lexicon word whose keys spell an English word: none, of any
// weight, falls this far behind the English, in either scheme; the
// farthest common one is 忘恩 for when in 小鹤双拼, at 21.4. 2,003 of the
// 2,816 English words of weight 300 or more come first in 小鹤双拼, 215
// of 548 in full pinyin (where most have no complete Chinese reading).
let WEAK_CHINESE_BITS = 25.0;
let COMPLETION_SCAN = 1024;     // codes examined for one prefix
// The median weight in the pinned dictionary. A rarer completion is left
// out, so typing a Chinese syllable (biang) keeps its characters on the page.
let COMPLETION_WEIGHT = 32;

struct Form { text: u32, len: u16 }
struct Entry { code: u8[..32], score: f32, weight: u32, form: u32, count: u16 }
struct Meta { entries: u32, forms: u32 }

root struct Dict {
    entries: Entry[>..] = [],
    forms: Form[>..] = [],
    pool: u8[>..] = [],
    meta: Meta[>..] = []
}

var live = Dict {};
var on = true;                  // octo_set_english: candidates and mixed sentences

// Which 3-letter prefixes exist, so a key pays a lookup only when one does.
var head3: u8[17576] = [0; 17576];

// log2 of all entries' summed weight: an entry's probability is its weight
// over that, as a Chinese word's is over its lexicon's total.
var total_bits = 0.0;

// Forms noted while the word graph is built, so a sentence can show them.
var spell_pool: u8[>..] = [];
var spell_at: u32[>..] = [];
var spell_len: u16[>..] = [];

fn active() -> bool { on && live.entries.len > 0 }
fn set_on(v: bool) { on = v; }

fn head_index(a: u8, b: u8, c: u8) -> i64 {
    if a < 'a' || a > 'z' || b < 'a' || b > 'z' || c < 'a' || c > 'z' { return -1; }
    return ((a - 'a') as i64) * 676 + ((b - 'a') as i64) * 26 + ((c - 'a') as i64);
}

fn reindex() {
    for i in 17576 { head3[i] = 0; }
    var total = 0.0;
    for e in live.entries { total += e.weight as f64; }
    total_bits = if total > 0.0 { log2(total) } else { 0.0 };
    for e in live.entries {
        if e.code.len < 3 { continue; }
        let i = head_index(e.code[0], e.code[1], e.code[2]);
        if i >= 0 { head3[i] = 1; }
    }
}

fn head_has(a: u8, b: u8, c: u8) -> bool {
    let i = head_index(a, b, c);
    return i >= 0 && head3[i] != 0;
}

fn is_code(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= MAX_CODE else { return false; }
    for c in text { if c < 'a' || c > 'z' { return false; } }
    return true;
}

fn is_form(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= 1024 else { return false; }
    for c in text { if c < 0x20 || c == 0x7F { return false; } }
    return true;
}

fn clear(d: Dict&) {
    d.entries.clear();
    d.forms.clear();
    d.pool.clear();
    d.meta.clear();
}

fn clear_live() {
    clear(live);
    reindex();
}

fn valid(d: Dict&) -> bool {
    let n = d.entries.len;
    guard d.meta.len == 1 && d.meta[0].entries == n && d.meta[0].forms == d.forms.len else { return false; }
    guard n <= MAX_ENTRIES && d.forms.len <= MAX_ENTRIES * MAX_FORMS && d.pool.len <= 8000000 else { return false; }
    var next: i64 = 0;
    for i in n {
        let e = d.entries[i];
        if !is_code(e.code) || !(e.score >= 0.0) || e.weight == 0 { return false; }
        if e.count == 0 || e.count > MAX_FORMS { return false; }
        if (e.form as i64) != next { return false; }
        // The rows are read below. A count past the array is refused here.
        if next + e.count > d.forms.len { return false; }
        next += e.count;
        if i > 0 && compare(d.entries[i - 1].code, e.code) >= 0 { return false; }
        for k in e.count {
            let f = d.forms[e.form + k];
            if (f.text as i64) + f.len > d.pool.len || !is_form(d.pool[f.text..f.text + f.len]) { return false; }
        }
    }
    return next == d.forms.len;
}

fn load_into(d: Dict&, img: const u8[:]) -> bool {
    let s, opened = image::open(img, image::KIND_ENGLISH, LAYOUT);
    clear(d);
    guard opened && s.count == SECTIONS else { return false; }
    var ok0 = false; var ok1 = false; var ok2 = false; var ok3 = false;
    d.entries, ok0 = from_bytes<Entry[>..]>(image::section(img, s, 0));
    d.forms, ok1 = from_bytes<Form[>..]>(image::section(img, s, 1));
    d.pool, ok2 = from_bytes<u8[>..]>(image::section(img, s, 2));
    d.meta, ok3 = from_bytes<Meta[>..]>(image::section(img, s, 3));
    let good = ok0 && ok1 && ok2 && ok3 && valid(d);
    if !good { clear(d); }
    return good;
}

fn load(img: const u8[:]) -> bool {
    let good = load_into(live, img);
    reindex();
    return good;
}

fn write(d: Dict&, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_ENGLISH, LAYOUT, 0, SECTIONS);
    image::add(out, w, d.entries);
    image::add(out, w, d.forms);
    image::add(out, w, d.pool);
    image::add(out, w, d.meta);
    image::finish(out, w);
}

// The first entry whose code is >= `code`.
fn lower_bound(code: const u8[:]) -> i64 {
    var a: i64 = 0;
    var b = live.entries.len;
    while a < b {
        let m = a + (b - a) / 2;
        if compare(live.entries[m].code, code) < 0 { a = m + 1; } else { b = m; }
    }
    return a;
}

fn has_prefix(code: const u8[:], prefix: const u8[:]) -> bool {
    prefix.len <= code.len && compare(code[..prefix.len], prefix) == 0
}

// The entry for exactly `code`, or -1.
fn exact(code: const u8[:]) -> i64 {
    guard is_code(code) && live.entries.len > 0 else { return -1; }
    let a = lower_bound(code);
    guard a < live.entries.len && compare(live.entries[a].code, code) == 0 else { return -1; }
    return a;
}

fn score_of(i: i64) -> f64 { live.entries[i].score as f64 }

// log2 of entry i's probability among the English words (≤ 0).
fn bits(i: i64) -> f64 { live.entries[i].score as f64 - total_bits }

fn copy_form(i: i64, k: i64, out: u8[>..]&) {
    out.clear();
    guard i >= 0 && i < live.entries.len else { return; }
    let e = live.entries[i];
    guard k >= 0 && k < e.count else { return; }
    let f = live.forms[e.form + k];
    out.append(live.pool[f.text..f.text + f.len]);
}

fn top_form(i: i64, out: u8[>..]&) { copy_form(i, 0, out); }

fn form_count(i: i64) -> i64 {
    guard i >= 0 && i < live.entries.len else { return 0; }
    return live.entries[i].count;
}

fn common(i: i64) -> bool {
    i >= 0 && i < live.entries.len && live.entries[i].weight >= COMMON_WEIGHT
}

// 1: `form`'s letters are `typed` in the same case. 0: the same letters,
// different case. -1: not the same letters. Punctuation in the form is skipped.
fn match_case(form: const u8[:], typed: const u8[:]) -> i64 {
    var ti: i64 = 0;
    var same = true;
    for b in form {
        let letter = (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z');
        if !letter { continue; }
        if ti >= typed.len { return -1; }
        let tb = typed[ti];
        ti++;
        let fl: u8 = if b >= 'A' && b <= 'Z' { b + 32 } else { b };
        let tl: u8 = if tb >= 'A' && tb <= 'Z' { tb + 32 } else { tb };
        if fl != tl { return -1; }
        if b != tb { same = false; }
    }
    if ti != typed.len { return -1; }
    return if same { 1 } else { 0 };
}

fn has_capital(text: const u8[:]) -> bool {
    for c in text { if c >= 'A' && c <= 'Z' { return true; } }
    return false;
}

fn apply_case(form: const u8[:], typed: const u8[:], out: u8[>..]&) {
    out.clear();
    var ti: i64 = 0;
    for b in form {
        let letter = (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z');
        if !letter || ti >= typed.len {
            out.push(b);
            continue;
        }
        let tb = typed[ti];
        ti++;
        let lower: u8 = if b >= 'A' && b <= 'Z' { b + 32 } else { b };
        out.push(if tb >= 'A' && tb <= 'Z' { lower - 32 } else { lower });
    }
}

// The form to show for `typed` (the code, in the case the user typed).
// Typed case wins when the dictionary form is plain lowercase (Hello).
// A form that already has capitals wins over all-lowercase typing
// (iphone → iPhone, nasa → NASA), and an exact case match wins over both (In).
fn prefer(i: i64, typed: const u8[:], out: u8[>..]&) {
    out.clear();
    guard form_count(i) > 0 else { return; }
    if has_capital(typed) {
        for k in form_count(i) {
            var form: u8[>..] = [];
            copy_form(i, k, form);
            if match_case(form, typed) == 1 {
                out.append(form);
                return;
            }
        }
    }
    top_form(i, out);
    if has_capital(typed) && !has_capital(out) && match_case(out, typed) == 0 {
        var cased: u8[>..] = [];
        apply_case(out, typed, cased);
        out.clear();
        out.append(cased);
    }
}

// `a` should be offered before `b`: higher score, then the shorter code.
fn better(a: i64, b: i64) -> bool {
    let sa = live.entries[a].score;
    let sb = live.entries[b].score;
    if sa != sb { return sa > sb; }
    if live.entries[a].code.len != live.entries[b].code.len { return live.entries[a].code.len < live.entries[b].code.len; }
    return compare(live.entries[a].code, live.entries[b].code) < 0;
}

// The n best codes that start with `prefix`, exact match excluded, best first.
fn completions(prefix: const u8[:], n: i64, out: i64[>..]&) {
    out.clear();
    guard n > 0 && prefix.len > 0 && prefix.len <= MAX_CODE && live.entries.len > 0 else { return; }
    var a = lower_bound(prefix);
    var seen: i64 = 0;
    while a < live.entries.len && seen < COMPLETION_SCAN && has_prefix(live.entries[a].code, prefix) {
        seen++;
        if compare(live.entries[a].code, prefix) != 0 && live.entries[a].weight >= COMPLETION_WEIGHT {
            var at = 0;
            while at < out.len && !better(a, out[at]) { at++; }
            if at < n {
                var next: i64[>..] = [];
                next.append(out[..at]);
                next.push(a);
                next.append(out[at..]);
                if next.len > n { next.pop(); }
                out.clear();
                out.append(next);
            }
        }
        a++;
    }
}

// ---- phase 2: the text of an English word in the graph --------------------------

fn begin_spellings() {
    spell_pool.clear();
    spell_at.clear();
    spell_len.clear();
}

fn note(text: const u8[:]) -> i64 {
    let id = spell_at.len;
    spell_at.push(spell_pool.len as u32);
    spell_len.push(text.len as u16);
    spell_pool.append(text);
    return id;
}

fn spelling(id: i64, out: u8[>..]&) {
    guard id >= 0 && id < spell_at.len else { return; }
    let at: i64 = spell_at[id];
    let n: i64 = spell_len[id];
    guard at + n <= spell_pool.len else { return; }
    out.append(spell_pool[at..at + n]);
}

// ---- compiling english.tsv -------------------------------------------------------

fn compile(d: Dict&, tsv: const u8[:], limit: i64, err: u8[>..]&) -> bool {
    clear(d);
    var pos: i64 = 0;
    var row: i64 = 0;
    while pos < tsv.len {
        let line = next_line(tsv, pos);
        row++;
        if line.len == 0 || line[0] == '#' { continue; }
        if limit > 0 && d.entries.len >= limit { break; }
        let code, rest1, ok1 = split_once(line, '\t');
        let weight_text, rest, ok2 = split_once(rest1, '\t');
        let weight, ok3 = parse_int(weight_text);
        guard ok1 && ok2 && ok3 && is_code(code) && weight >= 1 && weight <= 0xFFFFFFFF else {
            format(err, "english.tsv:", row, ": expected a code of letters, a weight, and its forms\n");
            return false;
        }
        if d.entries.len > 0 && compare(d.entries[d.entries.len - 1].code, code) >= 0 {
            format(err, "english.tsv:", row, ": codes are not in order\n");
            return false;
        }
        var forms: u8[>..] = [];
        var left = rest;
        var more = true;
        while more && forms.len < MAX_FORMS {
            let head, tail, ok = split_once(left, '\t');
            let form = if ok { head } else { left };
            more = ok;
            left = tail;
            if form.len == 0 { continue; }
            guard is_form(form) else {
                format(err, "english.tsv:", row, ": a form is empty or has a control character\n");
                return false;
            }
            forms.append(form);
            forms.push(0);
        }
        guard forms.len > 0 else {
            format(err, "english.tsv:", row, ": a code needs a form\n");
            return false;
        }
        let form_at = d.forms.len;
        var from: i64 = 0;
        while from < forms.len {
            var end = from;
            while forms[end] != 0 { end++; }
            d.forms.push(Form { text: d.pool.len as u32, len: (end - from) as u16 });
            d.pool.append(forms[from..end]);
            from = end + 1;
        }
        let score = log2(weight as f64);
        d.entries.push(Entry { code: code, score: score as f32, weight: weight as u32, form: form_at as u32,
                               count: (d.forms.len - form_at) as u16 });
    }
    guard d.entries.len > 0 else {
        format(err, "english.tsv: no words\n");
        return false;
    }
    d.meta.push(Meta { entries: d.entries.len as u32, forms: d.forms.len as u32 });
    return true;
}

fn next_line(text: const u8[:], pos: i64&) -> const u8[:] {
    let start = pos;
    let at = find(text[start..], "\n");
    pos = if at < 0 { text.len } else { start + at + 1 };
    let line = if at < 0 { text[start..] } else { text[start..start + at] };
    return if line.len > 0 && line[line.len - 1] == '\r' { line[..line.len - 1] } else { line };
}
