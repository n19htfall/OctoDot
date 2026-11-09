// OctoDot M0, spike 03: build a 1M-entry lexicon image, load it, time
// lookups, and try to replace it with bad images. Prints what it measures.
//   bench                  the full run (writes build/lexicon.img)
//   bench --seed PATH N    write a small N-entry image (seeds for spike 04)
import std;
import os;
import binary;
import lexicon;

extern fn octo_phys_footprint() -> u64;     // metrics.c
extern fn octo_now_ns() -> u64;             // metrics.c: Goose's clock_ns is only µs-grained on macOS

let ENTRIES = 1000000;

// Synthetic pinyin-like codes: an initial plus a final per syllable. Some
// pairs are not real syllables, which does not matter for the measurements.
let INITIALS = ["", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
                "j", "q", "x", "zh", "ch", "sh", "r", "z", "c", "s", "y", "w"];
let FINALS = ["a", "o", "e", "i", "u", "ai", "ei", "ao", "ou", "an", "en",
              "ang", "eng", "ong", "ia", "ie", "iao", "iu", "ian", "in",
              "iang", "ing", "ua", "uo", "ui", "uan", "un", "uang"];

var failures: i64 = 0;

fn fmt1(v: f64) -> u8[>..] {
    var s: u8[>..] = [];
    format_flt(s, v, 1);
    return s;
}
fn mib(bytes: i64) -> u8[>..] { fmt1(bytes / 1048576.0) }
fn ms(ns: i64) -> u8[>..] { fmt1(ns / 1000000.0) }
fn footprint() -> i64 { octo_phys_footprint() as i64 }
fn now_ns() -> i64 { octo_now_ns() as i64 }
fn pct(sorted: i64[:], p: i64) -> i64 { sorted[(sorted.len - 1) * p / 100] }

fn report(ok: bool, what: const u8[:]) {
    print(if ok { "ok    " } else { "FAIL  " }, what);
    if !ok { failures += 1; }
}

// 1 to 4 syllables per entry, the same number of CJK characters as text.
fn generate(n: i64, seed: u64, es: lexicon::Entry[>..]&, pool: u8[>..]&) {
    var r = rng { seed };
    for i in n {
        let syllables = 1 + r.rand_int(4);
        let code_off = pool.len;
        for s in syllables {
            pool.append(INITIALS[r.rand_int(INITIALS.len)]);
            pool.append(FINALS[r.rand_int(FINALS.len)]);
        }
        let code_len = pool.len - code_off;
        let text_off = pool.len;
        for s in syllables { push_utf8(pool, 0x4E00 + r.rand_int(0x9FA5 - 0x4E00)); }
        let text_len = pool.len - text_off;
        es.push(lexicon::Entry { code_off: code_off as u32, text_off: text_off as u32,
                                 weight: (1 + r.rand_int(1000000)) as u32,
                                 code_len: code_len as u8, text_len: text_len as u8 });
    }
}

// Builds an n-entry image and writes it atomically; returns its size.
fn write_image(path: const u8[:], n: i64, seed: u64) -> i64 {
    var es: lexicon::Entry[>..] = [];
    var pool: u8[>..] = [];
    generate(n, seed, es, pool);
    var img: u8[>..] = [];
    lexicon::build_image(es, pool, img);
    if !write_file_atomic(path, img) { abort("cannot write the image"); }
    return img.len;
}

fn new_stats() -> lexicon::LoadStats {
    lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0, install_ns: 0 }
}

fn lookups() {
    var r = rng { 99 };
    var exact: i64[>..] = [];
    var prefix: i64[>..] = [];
    var found: i64 = 0;
    var completions: i64 = 0;
    var key: u8[..32] = [];
    let rounds = 200000;
    for i in rounds {
        let k = r.rand_int(lexicon::entries.len);
        key.clear();
        key.append(lexicon::code_of(lexicon::strings, lexicon::entries[k]));
        var t = now_ns();
        let lo, hi = lexicon::find(key);
        exact.push(now_ns() - t);
        if lo <= k && k < hi { found += 1; }
        let plen = 1 + r.rand_int(if key.len < 3 { key.len } else { 3 });
        t = now_ns();
        let plo, phi = lexicon::prefix_range(key[..plen]);
        prefix.push(now_ns() - t);
        completions += phi - plo;
    }
    sort(exact);
    sort(prefix);
    print("lookup   exact code, ", rounds, " random keys: p50 ", pct(exact, 50), " ns, p99 ",
          pct(exact, 99), " ns, max ", pct(exact, 100), " ns");
    print("lookup   prefix range of 1-3 letters: p50 ", pct(prefix, 50), " ns, p99 ",
          pct(prefix, 99), " ns (", completions / rounds, " completions on average)");
    report(found == rounds, "every looked-up entry is inside its code's range");
}

fn intact(count: i64, probe: const u8[:], text: const u8[:]) -> bool {
    let lo, hi = lexicon::find(probe);
    lexicon::entries.len == count && lo < hi &&
        compare(lexicon::text_of(lexicon::strings, lexicon::entries[lo]), text) == 0
}

// Bad images must be refused with the live lexicon untouched; good ones swap in.
fn rollback(path: const u8[:]) {
    var file: u8[>..] = [];
    if !read_file(path, file) { abort("cannot read the image"); }
    var stats = new_stats();
    let count = lexicon::entries.len;
    var probe: u8[..32] = [];
    probe.append(lexicon::code_of(lexicon::strings, lexicon::entries[12345]));
    let first, last = lexicon::find(probe);
    var text: u8[..16] = [];
    text.append(lexicon::text_of(lexicon::strings, lexicon::entries[first]));

    var bad: u8[>..] = [];
    bad.append(file);
    bad[bad.len / 2] ^= 0x5A;
    report(!lexicon::load(bad, stats) && intact(count, probe, text),
           "reload refuses one flipped byte (checksum), live lexicon intact");

    report(!lexicon::load(file[..file.len / 2], stats) && intact(count, probe, text),
           "reload refuses a truncated image");

    bad.clear();
    bad.append(file);
    lexicon::put_u32_at(bad, 4, 99);
    report(!lexicon::load(bad, stats) && intact(count, probe, text),
           "reload refuses an unknown format version");

    // A hostile offset under a correct checksum. To from_bytes an offset is
    // only a number, so it accepts the bytes; our own validation is what
    // keeps an out-of-range slice off the keystroke path.
    bad.clear();
    bad.append(file);
    let e_off, e_ok = binary::read_u32le(bad, 16);
    let framed, frame_len = parse_uleb(bad[e_off..]);
    lexicon::put_u32_at(bad, e_off + frame_len, 0xFFFFFFF0);
    lexicon::put_u32_at(bad, 32, lexicon::checksum(bad[lexicon::HEADER_SIZE..]));
    report(e_ok && framed > 0 && !lexicon::load(bad, stats) && intact(count, probe, text),
           "reload refuses a hostile offset that passes the checksum and from_bytes");

    write_image("build/small.img", 1000, 3);
    var small: u8[>..] = [];
    report(read_file("build/small.img", small) && lexicon::load(small, stats) &&
           lexicon::entries.len == 1000, "a valid replacement image is installed");
    report(lexicon::load(file, stats) && intact(count, probe, text), "the original comes back");
}

fn main() {
    let argv = args();
    if argv.len == 4 && argv[1] == "--seed" {
        let n, ok = parse_int(argv[3]);
        if !ok || n <= 0 { abort("usage: bench --seed PATH N"); }
        print("seed image ", argv[2], ": ", write_image(argv[2], n, 11), " bytes, ", n, " entries");
        return;
    }
    let path = "build/lexicon.img";
    print("footprint at start: ", mib(footprint()), " MiB");

    var t = clock_ns();
    let size = write_image(path, ENTRIES, 7);
    print("build    ", ENTRIES, " entries, ", mib(size), " MiB image, ", ms(clock_ns() - t),
          " ms (generate, sort, serialize, write)");
    trim_memory();
    let base = footprint();
    print("footprint after the build scratch is freed and trimmed: ", mib(base), " MiB");

    // The two install strategies, each from an empty lexicon and trimmed
    // memory, so each peak is that strategy's own.
    for direct in 2 {
        lexicon::entries.clear();
        lexicon::strings.clear();
        trim_memory();
        var file: u8[>..] = [];
        t = clock_ns();
        if !read_file(path, file) { abort("cannot read the image"); }
        let read_ns = clock_ns() - t;
        let before = footprint();
        var stats = new_stats();
        let ok = if direct == 1 { lexicon::load_direct(file, stats) } else { lexicon::load(file, stats) };
        let name = if direct == 1 { "load_direct" } else { "load (scratch)" };
        print("load     ", name, ": read ", ms(read_ns), " ms, header + checksum ", ms(stats.check_ns),
              " ms, from_bytes ", ms(stats.verify_ns), " ms, offsets ", ms(stats.validate_ns),
              " ms, install ", ms(stats.install_ns), " ms; peak ", mib(footprint() - before),
              " MiB above the file buffer");
        report(ok, if direct == 1 { "the 1M-entry image loads (direct)" } else { "the 1M-entry image loads (scratch)" });
    }
    trim_memory();
    let loaded = footprint();
    let live = bytes_of(lexicon::entries).len + lexicon::strings.len;
    print("footprint loaded, file freed and trimmed: ", mib(loaded), " MiB, ",
          mib(loaded - base), " MiB over baseline for ", mib(live), " MiB of lexicon data");

    lookups();
    rollback(path);
    trim_memory();
    print("footprint after the reload tests, trimmed: ", mib(footprint()), " MiB");
    if failures > 0 { exit(1); }
}
