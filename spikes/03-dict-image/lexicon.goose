// OctoDot M0, spike 03: a compiled lexicon image, verified before it is used.
//
// Goose verifies that serialized bytes are *safe* (from_bytes checks
// framing, lengths and links) but leaves magic, versions and checksums to
// the program, and cannot know what our offsets mean. So an image is our
// header, then two framed Goose images: the entries, then the string pool
// they index. All header numbers are little-endian u32.
//
//   offset  field
//   0       magic "ODIC"
//   4       format version
//   8       layout id: bumped whenever Entry changes
//   12      entry count
//   16, 20  entries image: offset, length   (framed, from to_bytes)
//   24, 28  strings image: offset, length
//   32      checksum of everything after the header (std hash, low 32 bits)
//   36..63  reserved, zero
//
// Loading verifies into scratch first and replaces the live lexicon only
// when every check passes, so a bad image never disturbs the current one.
import std;
import binary;
import os;          // clock_ns, for LoadStats

namespace lexicon;

let MAGIC = 0x4349444F;     // "ODIC"
let FORMAT = 1;
let LAYOUT = 1;
let HEADER_SIZE = 64;

// 14 bytes. code and text are byte ranges in the string pool. Codes are
// sorted, and entries with equal codes run from the highest weight down.
struct Entry { code_off: u32, text_off: u32, weight: u32, code_len: u8, text_len: u8 }

// The live lexicon.
var entries: Entry[>..];
var strings: u8[>..];

fn code_of(pool: const u8[:], e: Entry) -> const u8[:] { pool[e.code_off..e.code_off + e.code_len] }
fn text_of(pool: const u8[:], e: Entry) -> const u8[:] { pool[e.text_off..e.text_off + e.text_len] }

fn put_u32_at(out: u8[>..]&, at: i64, v: u32) {
    for i in 4 { out[at + i] = ((v >> (8 * i)) & 0xFF) as u8; }
}

// Sorts a lexicon under construction and appends its image to `out`.
fn build_image(es: Entry[>..]&, pool: u8[>..]&, out: u8[>..]&) {
    sort(es) { a, b =>
        let c = compare(code_of(pool, a), code_of(pool, b));
        c < 0 || (c == 0 && a.weight > b.weight)
    };
    let start = out.len;
    for i in HEADER_SIZE { out.push(0); }
    let entries_off = out.len;
    to_bytes(es, out);
    let strings_off = out.len;
    to_bytes(pool, out);
    let end = out.len;

    put_u32_at(out, start + 0, MAGIC);
    put_u32_at(out, start + 4, FORMAT);
    put_u32_at(out, start + 8, LAYOUT);
    put_u32_at(out, start + 12, es.len as u32);
    put_u32_at(out, start + 16, (entries_off - start) as u32);
    put_u32_at(out, start + 20, (strings_off - entries_off) as u32);
    put_u32_at(out, start + 24, (strings_off - start) as u32);
    put_u32_at(out, start + 28, (end - strings_off) as u32);
    put_u32_at(out, start + 32, checksum(out[start + HEADER_SIZE..end]));
}

fn checksum(payload: const u8[:]) -> u32 { (hash(payload) & 0xFFFFFFFF) as u32 }

// Every offset in range: after this, slicing the pool cannot fail, so the
// keystroke path can never abort on a loaded lexicon.
fn offsets_valid(es: Entry[:], pool: const u8[:]) -> bool {
    for e in es {
        if e.code_len == 0 { return false; }
        // Widen before adding: in u32, a hostile 0xFFFFFFF0 + len would wrap.
        if (e.code_off as i64) + e.code_len > pool.len { return false; }
        if (e.text_off as i64) + e.text_len > pool.len { return false; }
    }
    return true;
}

struct LoadStats { check_ns: i64, verify_ns: i64, validate_ns: i64, install_ns: i64 }

// Our header: the two framed images and the entry count, or false. Checks
// the magic, versions and checksum; never aborts on its input.
fn sections(img: const u8[:]) -> const u8[:], const u8[:], i64, bool {
    let magic, ok1 = binary::read_u32le(img, 0);
    let format, ok2 = binary::read_u32le(img, 4);
    let layout, ok3 = binary::read_u32le(img, 8);
    let count, ok4 = binary::read_u32le(img, 12);
    let e_off, ok5 = binary::read_u32le(img, 16);
    let e_len, ok6 = binary::read_u32le(img, 20);
    let s_off, ok7 = binary::read_u32le(img, 24);
    let s_len, ok8 = binary::read_u32le(img, 28);
    let sum, ok9 = binary::read_u32le(img, 32);
    let payload, p_ok = binary::read_bytes(img, HEADER_SIZE, img.len - HEADER_SIZE);
    let e_img, e_ok = binary::read_bytes(img, e_off, e_len);
    let s_img, s_ok = binary::read_bytes(img, s_off, s_len);
    let ok = ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8 && ok9 && p_ok && e_ok && s_ok &&
             magic == MAGIC && format == FORMAT && layout == LAYOUT && checksum(payload) == sum;
    return e_img, s_img, count, ok;
}

// Verifies `img` completely in scratch and only then copies it over the
// live lexicon. Returns false, with the live lexicon untouched, for anything
// malformed, truncated, corrupted or hostile. Peak memory: the image plus
// two copies of the lexicon.
fn load(img: const u8[:], stats: LoadStats&) -> bool {
    var t = clock_ns();
    let e_img, s_img, count, ok = sections(img);
    stats.check_ns = clock_ns() - t;
    guard ok else { return false; }

    t = clock_ns();
    var es, es_ok = from_bytes<Entry[>..]>(e_img);
    var pool, pool_ok = from_bytes<u8[>..]>(s_img);
    stats.verify_ns = clock_ns() - t;
    guard es_ok && pool_ok && es.len == count else { return false; }

    t = clock_ns();
    let valid = offsets_valid(es, pool);
    stats.validate_ns = clock_ns() - t;
    guard valid else { return false; }

    t = clock_ns();
    entries.clear();
    entries.append(es);
    strings.clear();
    strings.append(pool);
    stats.install_ns = clock_ns() - t;
    return true;
}

// The same checks, but from_bytes builds straight into the live arrays, so
// the peak is one lexicon copy lower. The price: a refused image leaves the
// lexicon empty, and the caller must reload its last good image from disk.
fn load_direct(img: const u8[:], stats: LoadStats&) -> bool {
    var t = clock_ns();
    let e_img, s_img, count, ok = sections(img);
    stats.check_ns = clock_ns() - t;
    guard ok else { return false; }

    t = clock_ns();
    var es_ok = false;
    var pool_ok = false;
    entries, es_ok = from_bytes<Entry[>..]>(e_img);
    strings, pool_ok = from_bytes<u8[>..]>(s_img);
    stats.verify_ns = clock_ns() - t;

    t = clock_ns();
    let valid = es_ok && pool_ok && entries.len == count && offsets_valid(entries, strings);
    stats.validate_ns = clock_ns() - t;
    stats.install_ns = 0;
    if !valid {
        entries.clear();
        strings.clear();
    }
    return valid;
}

// The first entry whose code is >= key, or > key when `past_equal`.
fn lower_bound(key: const u8[:], past_equal: bool) -> i64 {
    var lo: i64 = 0;
    var hi = entries.len;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let c = compare(code_of(strings, entries[mid]), key);
        if c < 0 || (past_equal && c == 0) { lo = mid + 1; } else { hi = mid; }
    }
    return lo;
}

// The entries whose code is exactly `code`, highest weight first: [lo, hi).
fn find(code: const u8[:]) -> i64, i64 {
    return lower_bound(code, false), lower_bound(code, true);
}

fn has_prefix(s: const u8[:], prefix: const u8[:]) -> bool {
    s.len >= prefix.len && compare(s[..prefix.len], prefix) == 0
}

// The entries whose code starts with `prefix` (completions): [lo, hi).
fn prefix_range(prefix: const u8[:]) -> i64, i64 {
    let lo = lower_bound(prefix, false);
    var a = lo;
    var b = entries.len;
    while a < b {
        let mid = a + (b - a) / 2;
        if has_prefix(code_of(strings, entries[mid]), prefix) { a = mid + 1; } else { b = mid; }
    }
    return lo, a;
}
