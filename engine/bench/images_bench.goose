// The images against M1's gates (lexicon image ≤ 32 MiB, verified load
// ≤ 50 ms), plus memory and lookup latency for the record.
//
//   images-bench IMAGES
import std;
import os;
import octo from "..";

extern fn octo_phys_footprint() -> u64;    // metrics.c
extern fn octo_now_ns() -> u64;            // metrics.c: Goose's clock_ns is only µs-grained on macOS

let MAX_IMAGE = 32 * 1048576;
let MAX_LOAD_NS = 50 * 1000000;
let SAMPLES = 200000;

var failures: i64 = 0;

fn now() -> i64 { octo_now_ns() as i64 }

fn mib(bytes: i64) -> u8[>..] {
    var s: u8[>..] = [];
    format_flt(s, bytes / 1048576.0, 1);
    return s;
}

fn ms(ns: i64) -> u8[>..] {
    var s: u8[>..] = [];
    format_flt(s, ns / 1000000.0, 1);
    return s;
}

fn gate(ok: bool, what: const u8[:]) {
    print(if ok { "ok    " } else { "FAIL  " }, what);
    if !ok { failures++; }
}

fn report(name: const u8[:], samples: i64[>..]&) {
    sort(samples);
    let n = samples.len - 1;
    print("lookup   ", name, ": p50 ", samples[n / 2], " ns, p99 ", samples[n * 99 / 100], " ns, max ",
          samples[n], " ns");
}

fn main() {
    let argv = args();
    if argv.len != 2 {
        write_stderr("usage: images-bench IMAGES\n");
        exit(2);
    }
    let directory = argv[1];
    let base = octo_phys_footprint() as i64;

    var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
    var loads: i64[>..] = [];
    var size: i64 = 0;
    for round in 5 {
        lexicon::clear(lexicon::live);
        trim_memory();
        let started = now();
        var img: u8[>..] = [];
        if !read_file(str(directory, "/lexicon.img"), img) {
            write_stderr("images-bench: cannot read lexicon.img\n");
            exit(2);
        }
        let read_ns = now() - started;
        let ok = lexicon::load(img, stats);
        loads.push(now() - started);
        size = img.len;
        if !ok {
            gate(false, "the lexicon image loads");
            exit(1);
        }
        if round == 4 {
            print("load     read ", ms(read_ns), " ms, header and checksum ", ms(stats.check_ns),
                  " ms, from_bytes ", ms(stats.verify_ns), " ms, validation ", ms(stats.validate_ns), " ms");
        }
    }
    sort(loads);
    gate(size <= MAX_IMAGE, str("lexicon image: ", mib(size), " MiB (gate: 32 MiB)"));
    gate(loads[2] <= MAX_LOAD_NS, str("read and verified load, median of 5: ", ms(loads[2]), " ms (gate: 50 ms)"));
    trim_memory();
    let loaded = octo_phys_footprint() as i64;
    print("memory   ", mib(loaded - base), " MiB resident for the loaded lexicon");

    // Lexicon sets mounted and unmounted again and again: memory stays flat.
    {
        sets::reset();
        sets::survey(directory);
        var first: i64 = 0;
        var mount_ns: i64[>..] = [];
        var mounted_ok = true;
        for round in 21 {
            let t = now();
            mounted_ok = mounted_ok && sets::mount(directory, "diming") == 0 && sets::mount(directory, "mingren") == 0 &&
                         sets::mount(directory, "yiren") == 0;
            mount_ns.push(now() - t);
            sets::unmount("diming");
            sets::unmount("mingren");
            sets::unmount("yiren");
            trim_memory();
            if round == 0 { first = octo_phys_footprint() as i64; }
        }
        let last = octo_phys_footprint() as i64;
        sort(mount_ns);
        gate(mounted_ok && last - first < 2 * 1048576,
             str("sets: 地名, 名人 and 艺人 mounted in ", ms(mount_ns[10]), " ms (median); after 20 more rounds, memory ",
                 if last >= first { "+" } else { "" }, mib(last - first), " MiB (gate: flat, within 2 MiB)"));
    }

    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/spellings.fullpinyin.img"), img) {
            write_stderr("images-bench: cannot read spellings.fullpinyin.img\n");
            exit(2);
        }
        let started = now();
        let ok = spelling::load(img, lexicon::live_digest, lexicon::live.toned.len);
        gate(ok, str("spelling table: ", img.len, " bytes, verified load ", ms(now() - started), " ms"));
    }

    // The syllable ids that start with each letter: what an abbreviated
    // syllable such as "z" stands for.
    var letter_low: i64[26] = [-1; 26];
    var letter_high: i64[26] = [-1; 26];
    for s in lexicon::live.plain.len {
        let c = lexicon::live.plain[s].text[0] - 'a';
        if letter_low[c] < 0 { letter_low[c] = s; }
        letter_high[c] = s;
    }

    var r = rng { 7 };
    let n = lexicon::live.entries.len;
    var exact_ns: i64[>..] = [];
    var prefix_ns: i64[>..] = [];
    var range_ns: i64[>..] = [];
    var spelling_ns: i64[>..] = [];
    var found: i64 = 0;
    var spelled: i64 = 0;
    for i in SAMPLES {
        let k = r.rand_int(n);
        let e = lexicon::live.entries[k];
        var code: u16[>..] = [];
        for d in e.len { code.push(lexicon::syl(lexicon::live, e, d) as u16); }

        var t = now();
        let lo, hi = lexicon::exact(lexicon::live, code);
        exact_ns.push(now() - t);
        if lo <= k && k < hi { found++; }

        let depth = 1 + r.rand_int(if code.len < 3 { code.len } else { 3 });
        t = now();
        let plo, phi = lexicon::prefix_range(lexicon::live, code[..depth]);
        prefix_ns.push(now() - t);

        if code.len >= 2 {
            let s1: i64 = code[0];
            let c = lexicon::live.plain[code[1]].text[0] - 'a';
            t = now();
            let alo, ahi = lexicon::narrow(lexicon::live, lexicon::live.first[s1], lexicon::live.first[s1 + 1], 1,
                                           letter_low[c], letter_high[c]);
            range_ns.push(now() - t);
        }

        let s = r.rand_int(spelling::live.spellings.len);
        t = now();
        let at = spelling::find(spelling::live, spelling::live.spellings[s].text);
        spelling_ns.push(now() - t);
        if at == s { spelled++; }
    }
    gate(found == SAMPLES && spelled == SAMPLES, str("every sampled entry and spelling is found where it should be"));
    report("exact code", exact_ns);
    report("prefix of 1-3 syllables", prefix_ns);
    report("abbreviated second syllable (a letter's range)", range_ns);
    report("spelling", spelling_ns);
    day_of_typing(directory);
    if failures > 0 { exit(1); }
}

// A day of typing, as the IME runs it: 20,000 words of varied pinyin typed
// and committed through the session, each teaching the user dictionary.
// Memory may grow by what the dictionary holds, and no more.
fn day_of_typing(directory: const u8[:]) {
    guard session::open(directory) == 0 else {
        gate(false, "the session opens the images");
        return;
    }
    userdb::reset();
    trim_memory();
    let before = octo_phys_footprint() as i64;
    var r = rng { 2026 };
    let n = lexicon::live.entries.len;
    var commits: i64 = 0;
    var keys: i64 = 0;
    let started = now();
    while commits < 20000 {
        let e = lexicon::live.entries[r.rand_int(n)];
        if e.len < 1 || e.len > 4 { continue; }
        session::clear_composition();
        session::commit.clear();
        for k in e.len { session::input.append(lexicon::live.plain[lexicon::syl(lexicon::live, e, k)].text); }
        keys += session::input.len;
        session::rebuild();
        session::select(r.rand_int(3));         // the first candidate mostly, sometimes another
        if session::composing() { session::select(0); }
        commits++;
    }
    let took = now() - started;
    var saved: u8[>..] = [];
    saved.append(session::user_save());
    trim_memory();
    let after = octo_phys_footprint() as i64;
    gate(after - before < 32 * 1048576,
         str("a day of typing: ", commits, " commits (", keys, " letters, ", ms(took / commits), " ms each) taught ",
             userdb::lex.entries.len, " words; memory +", mib(after - before), " MiB (saved: ", mib(saved.len),
             " MiB) (gate: under 32 MiB)"));
}
