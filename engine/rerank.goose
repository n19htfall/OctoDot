// The reranker (docs/rerank-design.md): a small character-level language
// model, trained by OctoDot on Mandarin web text (data/rerank.lock), that
// rescores the decoder's best sentences. The sentence search finds the right
// sentence among its 16 best far more often than it ranks it first (87% and
// 66% in 小鹤双拼, on the corpus); ranking them by
//     the search's score + weight × the model's log2 P(<s> text </s>)
// puts it first 73% of the time.
//
// rerank.img holds what the engine needs to use it: the model's shape, the
// size of rerank.weights (memory-mapped by rerank.h, read in place), the
// weight and the search the shortlist comes from, all tuned with the model,
// and its characters: id 3 + i is chars[i], after <unk>, <s> and </s>.
//
// Scoring takes a few milliseconds, more than a key may: the session scores
// after the key, before the host shows its candidates (session::refine), so
// only the reranked menu is ever shown.
import std;
import os;
import image;

namespace rerank;

let LAYOUT = 1;
let SECTIONS = 2;
let UNK = 0;
let BOS = 1;
let EOS = 2;
let SPECIALS = 3;
let MAX_SHORTLIST = 16;
let MAX_IDS = 1024;             // MAX_SHORTLIST sequences of up to 64 positions
let MAX_VOCAB = 1000000;

struct Meta {
    file_size: u64, dims: u16, layers: u8, heads: u8, vocab: u32, positions: u8,
    shortlist: u8, per_state: u8, beam: u16, weight: f32
}

root struct Model {
    meta: Meta[>..] = [],
    chars: u32[>..] = []        // the vocabulary after the specials, by id - SPECIALS
}

var live = Model {};
var mapped = false;             // rerank.weights is mapped and matches live
var on = true;                  // octo_set_rerank: the user's choice
var ids = dictionary<u32, i32> {};

extern fn octo_rerank_open(path: const u8[:], size: u64, dims: i32, layers: i32, heads: i32, vocab: i32,
                           positions: i32) -> i32;
extern fn octo_rerank_close();
extern fn octo_rerank_score(ids: const i32[:], starts: const i32[:], bits: f64[:]) -> i32;

fn active() -> bool { on && mapped }
fn set_on(v: bool) { on = v; }

// The size rerank.weights must have: the header and every tensor, as the
// released model lays them out and rerank.h reads them.
fn weights_size(dims: i64, layers: i64, vocab: i64, positions: i64) -> u64 {
    let floats = vocab * dims + positions * dims + layers * (12 * dims * dims + 13 * dims) + 2 * dims;
    return (24 + 4 * floats) as u64;
}

fn valid(m: Model&) -> bool {
    guard m.meta.len == 1 else { return false; }
    let x = m.meta[0];
    let dims: i64 = x.dims;
    guard dims >= 8 && dims <= 4096 && x.heads >= 1 && dims % (x.heads as i64) == 0 && x.layers >= 1 &&
          x.layers <= 16 && x.positions >= 3 && x.positions <= 64 && x.shortlist >= 2 &&
          x.shortlist <= MAX_SHORTLIST && x.per_state >= 1 && x.per_state <= 64 && x.beam >= 1 && x.beam <= 4096 &&
          x.weight == x.weight && x.weight >= 0.0 && x.weight <= 100.0 else { return false; }
    guard (x.vocab as i64) == m.chars.len + SPECIALS && x.vocab <= MAX_VOCAB else { return false; }
    guard x.file_size == weights_size(dims, x.layers, x.vocab, x.positions) else { return false; }
    var seen = dictionary<u32, bool> {};
    for cp in m.chars {
        if cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) || seen.contains(cp) { return false; }
        seen.insert(cp, true);
    }
    return true;
}

// Verifies `img` into `m`; false, with `m` empty, on any failure. Never
// aborts on its input.
fn load_into(m: Model&, img: const u8[:]) -> bool {
    m.meta.clear();
    m.chars.clear();
    let s, opened = image::open(img, image::KIND_RERANK, LAYOUT);
    guard opened && s.count == SECTIONS else { return false; }
    var ok0 = false; var ok1 = false;
    m.meta, ok0 = from_bytes<Meta[>..]>(image::section(img, s, 0));
    m.chars, ok1 = from_bytes<u32[>..]>(image::section(img, s, 1));
    let good = ok0 && ok1 && valid(m);
    if !good { m.meta.clear(); m.chars.clear(); }
    return good;
}

fn write(m: Model&, out: u8[>..]&) {
    var w = image::begin(out, image::KIND_RERANK, LAYOUT, 0, SECTIONS);
    image::add(out, w, m.meta);
    image::add(out, w, m.chars);
    image::finish(out, w);
}

// Puts the model in `directory` in use: rerank.img, then rerank.weights,
// which must be the model it describes. 0; 1 if there is no rerank.img (no
// model: the reranker stays off); 2 if it does not verify; 3 if
// rerank.weights cannot be mapped or is not that model.
fn open(directory: const u8[:]) -> i32 {
    close();
    var img: u8[>..] = [];
    if !read_file(str(directory, "/rerank.img"), img) { return 1; }
    var m = Model {};
    if !load_into(m, img) { return 2; }
    let x = m.meta[0];
    if octo_rerank_open(str(directory, "/rerank.weights"), x.file_size, x.dims as i32, x.layers as i32,
                        x.heads as i32, x.vocab as i32, x.positions as i32) != 0 { return 3; }
    live.meta.append(m.meta);
    live.chars.append(m.chars);
    for i in live.chars.len { ids.insert(live.chars[i], (i + SPECIALS) as i32); }
    mapped = true;
    return 0;
}

fn close() {
    octo_rerank_close();
    live.meta.clear();
    live.chars.clear();
    ids.clear();
    mapped = false;
}

// ---- scoring ----------------------------------------------------------------------

// A shortlist to score: each sequence is ids[starts[k] .. starts[k + 1]],
// <s> text </s>.
struct Job { ids: i32[..1024], starts: i32[..17] }

fn clear_job(job: Job&) {
    job.ids.clear();
    job.starts.clear();
    job.starts.push(0);
}

// Adds `text` to `job` as <s> text </s>, a character the model does not
// know as <unk>. False, adding nothing, if the job is full or the text is
// longer than the model reads.
fn add(job: Job&, text: const u8[:]) -> bool {
    guard mapped && job.starts.len <= MAX_SHORTLIST else { return false; }
    var chars: i64 = 0;
    each_utf8(text) { cp => chars++; };
    guard chars >= 1 && chars <= (live.meta[0].positions as i64) - 2 && job.ids.len + chars + 2 <= job.ids.cap else {
        return false;
    }
    job.ids.push(BOS as i32);
    each_utf8(text) { cp =>
        let id = ids.get(cp as u32);
        if id { job.ids.push(id); } else { job.ids.push(UNK as i32); }
    };
    job.ids.push(EOS as i32);
    job.starts.push(job.ids.len as i32);
    return true;
}

fn count(job: Job&) -> i64 { job.starts.len - 1 }

// log2 P of each of `job`'s sequences, in order, into `bits`; false if the
// model is not mapped or cannot read the job.
fn score(job: Job&, bits: f64[>..]&) -> bool {
    bits.clear();
    for _ in count(job) { bits.push(0.0); }
    return mapped && count(job) > 0 && octo_rerank_score(job.ids[..], job.starts[..], bits[..]) == 0;
}

// The candidate to put first: the best by search score + weight × model
// score, or -1 if the scores are not usable (a damaged model gives NaN).
fn best(scores: const f64[:], bits: const f64[:]) -> i64 {
    guard bits.len == scores.len && scores.len > 0 else { return -1; }
    let weight = live.meta[0].weight as f64;
    var top: i64 = -1;
    var top_score = 0.0;
    for i in scores.len {
        let b = bits[i];
        if !(b == b) || b > 0.0 || b < -100000.0 { return -1; }
        let s = scores[i] + weight * b;
        if top < 0 || s > top_score { top = i; top_score = s; }
    }
    return top;
}

// ---- rerank.tsv -------------------------------------------------------------------

// rerank.tsv, released with the weights: "key \t value" lines, the
// characters as one string of them under "chars". False, with the reason in
// `err`, for anything missing or malformed.
fn compile(m: Model&, tsv: const u8[:], err: u8[>..]&) -> bool {
    var x = Meta { file_size: 0, dims: 0, layers: 0, heads: 0, vocab: 0, positions: 0, shortlist: 0, per_state: 0,
                   beam: 0, weight: 0.0 };
    var chars: u32[>..] = [];
    var seen: i64 = 0;
    for raw in split(tsv, '\n') {
        let line: const u8[:] = raw;
        if line.len == 0 || line[0] == '#' { continue; }
        let key, value, ok = split_once(line, '\t');
        if !ok {
            format(err, "rerank.tsv: no tab in \"", line[..if line.len > 40 { 40 } else { line.len }], "\"");
            return false;
        }
        if key == "chars" {
            each_utf8(value) { cp => chars.push(cp as u32); };
            seen |= 1;
            continue;
        }
        let number, good = parse_flt(value);
        if !good || number < 0.0 || number > 1.0e12 {
            format(err, "rerank.tsv: ", key, " is not a number: \"", value, "\"");
            return false;
        }
        if key == "file_size" { x.file_size = number as u64; seen |= 2; }
        else if key == "dims" { x.dims = number as u16; seen |= 4; }
        else if key == "layers" { x.layers = number as u8; seen |= 8; }
        else if key == "heads" { x.heads = number as u8; seen |= 16; }
        else if key == "positions" { x.positions = number as u8; seen |= 32; }
        else if key == "shortlist" { x.shortlist = number as u8; seen |= 64; }
        else if key == "per_state" { x.per_state = number as u8; seen |= 128; }
        else if key == "beam" { x.beam = number as u16; seen |= 256; }
        else if key == "weight" { x.weight = number as f32; seen |= 512; }
    }
    if seen != 1023 {
        format(err, "rerank.tsv: a setting is missing");
        return false;
    }
    x.vocab = (chars.len + SPECIALS) as u32;
    m.meta.clear();
    m.meta.push(x);
    m.chars.clear();
    m.chars.append(chars);
    if !valid(m) {
        format(err, "rerank.tsv: a setting is out of range, a character repeats, or file_size does not fit the shape");
        m.meta.clear();
        m.chars.clear();
        return false;
    }
    return true;
}
