// 万象's grammar model: how well a word follows the text before it, which
// the sentence search adds to each word's own weight (M2).
//
// The model is librime-octagram's .gram file, about 63.7 million character
// n-grams in a double-array trie (418 MB for 万象's). Almost every n-gram can
// change some result under 万象's settings, and no smaller set gives the
// same scores (docs/M2-grammar.md), so it is used whole: memory-mapped by
// gram.h, read in place, never copied into the heap.
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

extern fn octo_gram_settings(max_length: i32, min_length: i32, collocation: f64, non_collocation: f64,
                             weak_collocation: f64, rear: f64);
extern fn octo_gram_open(path: const u8[:], size: u64) -> i32;
extern fn octo_gram_close();
extern fn octo_gram_query(context: const u8[:], word: const u8[:], rear: bool) -> f64;

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

// Turns the model in `directory` on: grammar.img, then the .gram file it
// names, which must have the size it records. 0; 1 if there is no
// grammar.img (no model: nothing changes); 2 if it does not verify; 3 if
// the .gram file cannot be mapped or is not the one recorded. On failure
// the model is off.
fn open(directory: const u8[:]) -> i32 {
    close();
    var img: u8[>..] = [];
    if !read_file(str(directory, "/grammar.img"), img) { return 1; }
    var s = Settings {};
    if !load_into(s, img) { return 2; }
    let m = s.meta[0];
    octo_gram_settings(m.max_length as i32, m.min_length as i32, m.collocation as f64, m.non_collocation as f64,
                       m.weak_collocation as f64, m.rear as f64);
    if octo_gram_open(str(directory, "/", m.language, ".gram"), m.file_size) != 0 { return 3; }
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
