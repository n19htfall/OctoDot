// 万象's grammar model: how well a word follows the text before it, which
// the sentence search adds to each word's own weight (M2).
//
// The model is librime-octagram's .gram file, about 63.7 million character
// n-grams in a double-array trie (418 MB for 万象's). Almost every n-gram can
// change some result under 万象's settings, and no smaller set gives the
// same scores (docs/M2-grammar.md), so it is used whole: memory-mapped by
// gram.h, read in place, never copied into the heap. Goose cannot hold a
// slice into that mapping, so gram.h keeps the mapping and a checked unit
// read, and the walk below reads one unit at a time.
//
// The walk, the key encoding and the query are librime-octagram's
// (BSD-3-Clause, by the RIME developers), ported from gram_encoding.cc and
// octagram.cc, over darts-clone's double array (BSD-2-Clause, Susumu Yata).
// A malformed or truncated UTF-8 sequence ends the text there. Overlong
// forms and surrogates stay accepted: the port decodes the bytes the C
// reader decoded.
//
// grammar.img holds what the engine needs to use it: the .gram file's name
// and size, which bind the two, and 万象's settings from its schema:
//   max_length, min_length   how much context and word a query reads
//   penalties                librime-octagram's GrammarConfig, in natural log units
//   homophones               words kept per span inside the input, where the
//                            model chooses among them (万象's max_homophones)
import std;
import os;
import image;

namespace grammar;

let LAYOUT = 1;
let SECTIONS = 1;
let MAX_LANGUAGE = 63;

struct Meta {
    language: u8[..63], file_size: u64, max_length: u8, min_length: u8, homophones: u8,
    collocation: f32, non_collocation: f32, weak_collocation: f32, rear: f32
}

root struct Settings {
    meta: Meta[>..] = []
}

// The settings in use, and whether a model is mapped and on.
var live = Settings {};
var on = false;

// Where else the .gram file may be when it is not beside grammar.img: the
// IME keeps the model in a folder outside its signed bundle, so that an
// update need not carry 400 MB it already has (docs/M2-grammar.md). Empty:
// only beside grammar.img.
var elsewhere: u8[>..] = [];

// The mapping stays in gram.h: Goose cannot hold a slice into it. A unit
// past the array reads as 0, so a walk fails closed instead of reading
// outside the file.
extern fn octo_gram_open(path: const u8[:], size: u64) -> i32;
extern fn octo_gram_close();
extern fn octo_gram_unit(i: u64) -> u32;
extern fn octo_gram_count() -> u64;
extern fn octo_gram_loaded() -> bool;

// How many code points a query reads. A key is at most 6 bytes a code
// point, so the encoded keys below fit in 48 bytes and the query allocates
// nothing.
let SPAN_MAX: i32 = 8;
let RESULTS: i32 = 8;

struct Gram {
    span: i32 = 1, min_length: i32 = 0,
    collocation: f64 = 0.0, non_collocation: f64 = 0.0, weak_collocation: f64 = 0.0, rear: f64 = 0.0
}

var gram = Gram {};

// span is max_length - 1, clamped to 1..8.
fn octo_gram_settings(max_length: i32, min_length: i32, collocation: f64, non_collocation: f64,
                      weak_collocation: f64, rear: f64) {
    let raw = max_length - 1;
    gram.span = if raw < 1 { 1 } else if raw > SPAN_MAX { SPAN_MAX } else { raw };
    gram.min_length = min_length;
    gram.collocation = collocation;
    gram.non_collocation = non_collocation;
    gram.weak_collocation = weak_collocation;
    gram.rear = rear;
}

// darts-clone's unit. The label keeps bit 31, so a unit with that bit set
// matches no key byte. The offset's shift is 0 or 8, taken from bit 9, and
// the base is widened before that shift.
inline fn label(u: u32) -> u32 { u & 0x800000FF }
inline fn has_leaf(u: u32) -> bool { ((u >> 8) & 1) == 1 }
inline fn offset(u: u32) -> u64 {
    let base: u64 = u >> 10;
    let sh = (u & (1 << 9)) >> 6;
    return base << sh;
}

// One code point at byte i, and the index past it. A malformed or truncated
// sequence fails and leaves the index where it was. Overlong forms and
// surrogates stay accepted.
inline fn next_utf8(s: const u8[:], i: i64) -> i32, i64 {
    var c: i32 = -1;
    var ni = i;
    if i < s.len {
        let b = s[i];
        let extra: i32 = if b < 0x80 { 0 } else if (b & 0xE0) == 0xC0 { 1 } else if (b & 0xF0) == 0xE0 { 2 } else if (b & 0xF8) == 0xF0 { 3 } else { -1 };
        if extra >= 0 && i + extra < s.len {
            c = if extra == 0 { b } else if extra == 1 { b & 0x1F } else if extra == 2 { b & 0x0F } else { b & 0x07 };
            var ok = true;
            for k: i32 in 1..(extra + 1) {
                let x = s[i + k];
                if (x & 0xC0) != 0x80 { ok = false; break; }
                c = (c << 6) | (x & 0x3F);
            }
            if ok { ni = i + extra + 1; } else { c = -1; }
        }
    }
    return c, ni;
}

// The code point's key, written at out[n], the way gram_encoding.cc writes
// it. 0 is 0xE0, so a key never holds a 0 byte. U+4000..U+9FFF are two
// bytes, and a low byte of 0 is 0xE1 then the high byte. Anything else is
// a 7-bit varint after 0xE0 plus its length. The shifts wrap in 32 bits.
inline fn encode_key(u: u32, out: u8[:], n: i32) -> i32 {
    var at = n;
    if u < 0x80 {
        out[at] = if u == 0 { 0xE0 } else { u as u8 };
        at += 1;
    } else if u >= 0x4000 && u < 0xA000 {
        if (u & 0xFF) == 0 {
            out[at] = 0xE1;
            out[at + 1] = ((u >> 8) + 0x40) as u8;
        } else {
            out[at] = ((u >> 8) + 0x40) as u8;
            out[at + 1] = (u & 0xFF) as u8;
        }
        at += 2;
    } else {
        var bits: i32 = 32;
        var v = u;
        while bits > 0 && (v & 0xFE000000) == 0 {
            bits -= 7;
            v <<= 7;
        }
        var bytes = (bits + 6) / 7;
        out[at] = (0xE0 | bytes) as u8;
        at += 1;
        while bytes > 0 {
            bytes -= 1;
            out[at] = (((v >> 25) & 0x7F) | 0x80) as u8;
            at += 1;
            v <<= 7;
        }
    }
    return at;
}

// The node reached by key, or -1 where a byte's label does not match.
inline fn walk(start: u64, key: const u8[:]) -> i64 {
    var node = start;
    var unit = octo_gram_unit(node);
    for i in key.len {
        let next = node ^ offset(unit) ^ key[i];
        unit = octo_gram_unit(next);
        if label(unit) != key[i] { return -1; }
        node = next;
    }
    return node as i64;
}

// The keys the node has that start with `key`, at most 8 of them. A leaf's
// value is read only when its node lies inside the array, and the high bit
// is clear, so it fits in an i32.
inline fn prefixes(start: u64, key: const u8[:], lengths: i32[:], values: i32[:]) -> i32 {
    var found: i32 = 0;
    var node = start;
    var unit = octo_gram_unit(node);
    node = node ^ offset(unit);
    for i in key.len {
        if found >= RESULTS { break; }
        node = node ^ key[i];
        unit = octo_gram_unit(node);
        if label(unit) != key[i] { break; }
        node = node ^ offset(unit);
        if has_leaf(unit) && node < octo_gram_count() {
            lengths[found] = (i + 1) as i32;
            values[found] = (octo_gram_unit(node) & 0x7FFFFFFF) as i32;
            found += 1;
        }
    }
    return found;
}

// The best score for `word` after `context`. The longest context is tried
// first. The penalty is the collocation one when the match reaches
// min_length, or when the whole word matched with the whole context, and
// the weak one otherwise. '$' after the word takes the rear penalty, and
// only when every code point of the word fit in span. No model, or an
// empty context or word, scores the non-collocation penalty.
inline fn octo_gram_query(context: const u8[:], word: const u8[:], rear: bool) -> f64 {
    var result = gram.non_collocation;
    if !octo_gram_loaded() || context.len <= 0 { return result; }
    let span = gram.span;

    var ctx: i32[8] = [0; 8];
    var ctx_count: i32 = 0;
    var i: i64 = 0;
    while i < context.len {
        let c, ni = next_utf8(context, i);
        if c < 0 { break; }
        i = ni;
        if ctx_count == span {
            for j: i32 in 0..(span - 1) { ctx[j] = ctx[j + 1]; }
            ctx_count -= 1;
        }
        ctx[ctx_count] = c;
        ctx_count += 1;
    }
    var w: i32[8] = [0; 8];
    var w_count: i32 = 0;
    var word_chars: i32 = 0;
    i = 0;
    while i < word.len {
        let c, ni = next_utf8(word, i);
        if c < 0 { break; }
        i = ni;
        if w_count < span {
            w[w_count] = c;
            w_count += 1;
        }
        word_chars += 1;
    }
    if ctx_count == 0 || w_count == 0 { return result; }

    var cq: u8[48] = [0; 48];
    var wq: u8[48] = [0; 48];
    var c_at: i32[9] = [0; 9];
    var w_at: i32[9] = [0; 9];
    var cn: i32 = 0;
    var wn: i32 = 0;
    for k: i32 in 0..ctx_count {
        c_at[k] = cn;
        cn = encode_key(ctx[k] as u32, cq, cn);
    }
    c_at[ctx_count] = cn;
    for k: i32 in 0..w_count {
        w_at[k] = wn;
        wn = encode_key(w[k] as u32, wq, wn);
    }
    w_at[w_count] = wn;

    var lengths: i32[8] = [0; 8];
    var values: i32[8] = [0; 8];
    for k: i32 in 0..ctx_count {
        let context_len = ctx_count - k;
        let from: i64 = c_at[k];
        let to: i64 = cn;
        let node = walk(0, cq[from..to]);
        if node < 0 { continue; }
        let wn64: i64 = wn;
        let found = prefixes(node as u64, wq[..wn64], lengths, values);
        for r: i32 in 0..found {
            var match_len: i32 = 0;
            while match_len < w_count && w_at[match_len + 1] <= lengths[r] { match_len += 1; }
            let whole = k == 0 && lengths[r] == wn;
            let penalty = if context_len + match_len >= gram.min_length || whole { gram.collocation } else { gram.weak_collocation };
            let score = values[r] / 10000.0 + penalty;
            if score > result { result = score; }
        }
    }
    if rear && w_count == word_chars {
        let wn64: i64 = wn;
        let node = walk(0, wq[..wn64]);
        let end: u8[1] = ['$'];
        if node >= 0 && prefixes(node as u64, end, lengths, values) > 0 {
            let score = values[0] / 10000.0 + gram.rear;
            if score > result { result = score; }
        }
    }
    return result;
}

// A language names a file: letters, digits, '-' and '_', 1 to 63 of them.
fn is_language(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= MAX_LANGUAGE else { return false; }
    for c in text {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            return false;
        }
    }
    return true;
}

fn finite(x: f32) -> bool { x == x && x > -1000.0 && x < 1000.0 }

fn valid(s: Settings&) -> bool {
    guard s.meta.len == 1 else { return false; }
    let m = s.meta[0];
    return is_language(m.language) && m.file_size >= 44 && m.max_length >= 2 && m.max_length <= 9 &&
           m.min_length >= 1 && m.homophones >= 1 && m.homophones <= 64 && finite(m.collocation) &&
           finite(m.non_collocation) && finite(m.weak_collocation) && finite(m.rear);
}

// Verifies `img` into `s`; false, with `s` empty, on any failure. Never
// aborts on its input.
fn load_into(s: Settings&, img: const u8[:]) -> bool {
    s.meta.clear();
    let sections, opened = image::open(img, image::KIND_GRAMMAR, LAYOUT);
    guard opened && sections.count == SECTIONS else { return false; }
    var ok = false;
    s.meta, ok = from_bytes<Meta[>..]>(image::section(img, sections, 0));
    let good = ok && valid(s);
    if !good { s.meta.clear(); }
    return good;
}

fn write(s: Settings&, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_GRAMMAR, LAYOUT, 0, SECTIONS);
    image::add(out, w, s.meta);
    image::finish(out, w);
}

// The .gram file named `language`: beside grammar.img in `directory` if it
// is there, else in `elsewhere` (which may not hold it either).
fn path(directory: const u8[:], language: const u8[:]) -> u8[>..] {
    let beside = str(directory, "/", language, ".gram");
    if elsewhere.len == 0 || file_exists(beside) { return beside; }
    return str(elsewhere, "/", language, ".gram");
}

// Whether `directory` has a model to turn on: its grammar.img verifies and
// the .gram file it names is there (not yet checked against it).
fn available(directory: const u8[:]) -> bool {
    var img: u8[>..] = [];
    var s = Settings {};
    return read_file(str(directory, "/grammar.img"), img) && load_into(s, img) &&
           file_exists(path(directory, s.meta[0].language));
}

// Turns the model in `directory` on: grammar.img, then the .gram file it
// names (beside it, or in `elsewhere`), which must have the size it
// records. 0; 1 if there is no grammar.img (no model: nothing changes); 2 if
// it does not verify; 3 if the .gram file cannot be mapped or is not the one
// recorded. On failure the model is off.
fn open(directory: const u8[:]) -> i32 {
    close();
    var img: u8[>..] = [];
    if !read_file(str(directory, "/grammar.img"), img) { return 1; }
    var s = Settings {};
    if !load_into(s, img) { return 2; }
    let m = s.meta[0];
    octo_gram_settings(m.max_length as i32, m.min_length as i32, m.collocation as f64, m.non_collocation as f64,
                       m.weak_collocation as f64, m.rear as f64);
    if octo_gram_open(path(directory, m.language), m.file_size) != 0 { return 3; }
    live.meta.clear();
    live.meta.append(s.meta);
    on = true;
    return 0;
}

fn close() {
    octo_gram_close();
    live.meta.clear();
    on = false;
}

// How well `word` follows `context`, in natural log units (≤ about 9): the
// non-collocation penalty without context or when off.
fn query(context: const u8[:], word: const u8[:], rear: bool) -> f64 {
    guard on else { return 0.0; }
    return octo_gram_query(context, word, rear);
}

// Words to keep per span inside the input: the model's choice when on, else
// one (the unigram's best, which is all a search without context can use).
fn homophones() -> i64 { if on { live.meta[0].homophones as i64 } else { 1 } }

// grammar.tsv from octo-prep: "key \t value" lines. False, with the reason
// in `err`, for anything missing or malformed.
fn compile(s: Settings&, tsv: const u8[:], err: u8[>..]&) -> bool {
    var m = Meta { language: "", file_size: 0, max_length: 0, min_length: 0, homophones: 0, collocation: 0.0,
                   non_collocation: 0.0, weak_collocation: 0.0, rear: 0.0 };
    var seen: i64 = 0;
    for raw in split(tsv, '\n') {
        let line: const u8[:] = raw;
        if line.len == 0 || line[0] == '#' { continue; }
        let key, value, ok = split_once(line, '\t');
        if !ok {
            format(err, "grammar.tsv: no tab in \"", line, "\"");
            return false;
        }
        if key == "language" {
            if !is_language(value) {
                format(err, "grammar.tsv: bad language \"", value, "\"");
                return false;
            }
            m.language = value;
            seen |= 1;
            continue;
        }
        let number, good = parse_flt(value);
        if !good {
            format(err, "grammar.tsv: ", key, " is not a number: \"", value, "\"");
            return false;
        }
        if key == "file_size" { m.file_size = number as u64; seen |= 2; }
        else if key == "collocation_max_length" { m.max_length = number as u8; seen |= 4; }
        else if key == "collocation_min_length" { m.min_length = number as u8; seen |= 8; }
        else if key == "collocation_penalty" { m.collocation = number as f32; seen |= 16; }
        else if key == "non_collocation_penalty" { m.non_collocation = number as f32; seen |= 32; }
        else if key == "weak_collocation_penalty" { m.weak_collocation = number as f32; seen |= 64; }
        else if key == "rear_penalty" { m.rear = number as f32; seen |= 128; }
        else if key == "max_homophones" { m.homophones = number as u8; seen |= 256; }
    }
    if seen != 511 {
        format(err, "grammar.tsv: a setting is missing");
        return false;
    }
    s.meta.clear();
    s.meta.push(m);
    if !valid(s) {
        format(err, "grammar.tsv: a setting is out of range");
        s.meta.clear();
        return false;
    }
    return true;
}
