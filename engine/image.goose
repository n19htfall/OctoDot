// The container every OctoDot image uses. Goose verifies that serialized
// arrays are safe (from_bytes) but leaves identification, versioning and
// integrity to the program, so an image is this header, a table of its
// sections, then the sections: framed arrays as to_bytes writes them.
//
//   offset  field, little-endian
//   0       magic "OCTO"
//   4       container version
//   8       kind: what the image holds
//   12      layout: bumped whenever that kind's structs change
//   16      number of sections
//   24      digest: what the image was built against (the syllabary for
//           lexicons and spelling tables, which must match; 0 for
//           auxiliary codes, which are keyed by character)
//   32      checksum: std hash of everything after the header
//   64      the section table: an offset and a length per section, u32 each
import std;
import binary;

namespace image;

let MAGIC = 0x4F54434F;     // "OCTO"
let VERSION = 1;
let HEADER = 64;
let MAX_SECTIONS = 16;

let KIND_LEXICON = 1;
let KIND_SPELLINGS = 2;
let KIND_AUX = 3;
let KIND_SHORTCUTS = 4;
let KIND_GRAMMAR = 5;          // the grammar model's settings (the model itself is its .gram file)
let KIND_ENGLISH = 6;          // English words offered beside the Chinese (docs/english-design.md)
let KIND_RERANK = 7;           // the reranker's shape and characters (its weights are rerank.weights)

struct Writer { start: i64, count: i64, next: i64 }

struct Sections { count: i64, digest: u64, offset: u32[16], length: u32[16] }

fn put_u32(out: u8[>..]&, at: i64, v: u32) {
    for i in 4 { out[at + i] = ((v >> (8 * i)) & 0xFF) as u8; }
}

fn put_u64(out: u8[>..]&, at: i64, v: u64) {
    for i in 8 { out[at + i] = ((v >> (8 * i)) & 0xFF) as u8; }
}

// Starts an image of `count` sections at the end of `out`.
fn begin(out: u8[>..]&, kind: u32, layout: u32, digest: u64, count: i64) -> Writer {
    let start = out.len;
    for i in HEADER + 8 * count { out.push(0); }
    put_u32(out, start, MAGIC);
    put_u32(out, start + 4, VERSION);
    put_u32(out, start + 8, kind);
    put_u32(out, start + 12, layout);
    put_u32(out, start + 16, count as u32);
    put_u64(out, start + 24, digest);
    return Writer { start: start, count: count, next: 0 };
}

// Appends the next section: any array, framed by to_bytes.
fn add(out: u8[>..]&, w: Writer&, a) {
    let at = out.len;
    to_bytes(a, out);
    put_u32(out, w.start + HEADER + 8 * w.next, (at - w.start) as u32);
    put_u32(out, w.start + HEADER + 8 * w.next + 4, (out.len - at) as u32);
    w.next += 1;
}

fn finish(out: u8[>..]&, w: Writer) {
    put_u64(out, w.start + 32, hash(out[w.start + HEADER..]));
}

// The header and section table of `img`, checked: magic, version, kind,
// layout and checksum, and every section inside the image. Never aborts
// on its input.
fn open(img: const u8[:], kind: u32, layout: u32) -> Sections, bool {
    var s = Sections { count: 0, digest: 0, offset: [0; 16], length: [0; 16] };
    let magic, ok1 = binary::read_u32le(img, 0);
    let version, ok2 = binary::read_u32le(img, 4);
    let k, ok3 = binary::read_u32le(img, 8);
    let l, ok4 = binary::read_u32le(img, 12);
    let count, ok5 = binary::read_u32le(img, 16);
    let digest, ok6 = binary::read_u64le(img, 24);
    let sum, ok7 = binary::read_u64le(img, 32);
    guard ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 else { return s, false; }
    guard magic == MAGIC && version == VERSION && k == kind && l == layout && count <= MAX_SECTIONS else {
        return s, false;
    }
    let payload, ok8 = binary::read_bytes(img, HEADER, img.len - HEADER);
    guard ok8 && hash(payload) == sum else { return s, false; }
    for i in count as i64 {
        let at, ok9 = binary::read_u32le(img, HEADER + 8 * i);
        let len, ok10 = binary::read_u32le(img, HEADER + 8 * i + 4);
        guard ok9 && ok10 && binary::range_ok(img, at, len) else { return s, false; }
        s.offset[i] = at;
        s.length[i] = len;
    }
    s.count = count;
    s.digest = digest;
    return s, true;
}

// Section i of an image open() accepted; empty if there is no such section.
fn section(img: const u8[:], s: Sections, i: i64) -> const u8[:] {
    guard i >= 0 && i < s.count else { return img[0..0]; }
    let start: i64 = s.offset[i];
    return img[start..start + s.length[i]];
}

// Rewrites an image's checksum to match its payload (fuzzing, and tests
// that corrupt a section on purpose).
fn restamp(img: u8[:]) {
    guard img.len >= HEADER else { return; }
    let sum = hash(img[HEADER..]);
    for i in 8 { img[32 + i] = ((sum >> (8 * i)) & 0xFF) as u8; }
}
