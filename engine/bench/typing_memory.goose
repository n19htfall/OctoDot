// Per-keystroke typing and memory benchmark; see `make bench-typing-memory`.
import std;
import os;
import octo from "..";

extern fn octo_phys_footprint() -> u64;
extern fn octo_now_ns() -> u64;

var keys: i64 = 0;
var refined: i64 = 0;

fn text(i: i64) -> const u8[:] {
    let n = i % 12;
    if n == 0 { return "nihao"; }
    if n == 1 { return "zhongguoren"; }
    if n == 2 { return "jintiantianqibucuo"; }
    if n == 3 { return "womenyiqiqukankan"; }
    if n == 4 { return "woshiyigezhongguoren"; }
    if n == 5 { return "yijiasankouhoubuchepiao"; }
    if n == 6 { return "xiexie"; }
    if n == 7 { return "github"; }
    if n == 8 { return "xi'an"; }
    if n == 9 { return "shurufa"; }
    if n == 10 { return "woyongdiannao"; }
    return "zaijian";
}

// The host requests a snapshot for a changed key, then refines a pending
// menu before showing it. Exercise the same path, including the snapshot of
// a reranked menu when it changed.
fn key(s: u64, k: i64, c: i64, no_learn: bool) {
    let result = session::key(s, session::KeyEvent { key: k as u16, flags: if no_learn { 1 } else { 0 },
                                                    modifiers: 0, codepoint: c as u32, time_ms: 0 });
    keys++;
    if (result & (session::DIRTY | session::HAS_COMMIT)) != 0 { let snapshot = session::snapshot(s); }
    if (result & session::PENDING) != 0 {
        refined++;
        if (session::refine(s) & session::DIRTY) != 0 { let snapshot = session::snapshot(s); }
    }
}

fn batch(s: u64&, start: i64, count: i64, no_learn: bool) {
    for j in count {
        let i = start + j;
        if i > 0 && i % 29 == 0 {          // focus moves to another client
            session::free_session(s);
            s = session::new_session();
        }
        let t = text(i);
        for p in t.len {
            key(s, session::KEY_OTHER, t[p], no_learn);
            if p == t.len / 2 && i % 9 == 0 { // a typo corrected while composing
                key(s, session::KEY_OTHER, 'z', no_learn);
                key(s, session::KEY_BACKSPACE, 0, no_learn);
            }
        }
        if i % 11 == 0 { key(s, session::KEY_DOWN, 0, no_learn); }
        if i % 17 == 0 { key(s, session::KEY_ESCAPE, 0, no_learn); }
        else if i % 13 == 0 { key(s, session::KEY_OTHER, '.', no_learn); }
        else { key(s, session::KEY_SPACE, 0, no_learn); }
        // A real host saves after learning; include repeated serialization.
        if !no_learn && i % 75 == 0 { let saved = session::user_save(); }
        userdb::clock_override++;
    }
}

fn report(label: const u8[:], baseline: i64) -> i64 {
    let untrimmed = octo_phys_footprint() as i64;
    trim_memory();
    let memory = octo_phys_footprint() as i64;
    print(label, ": footprint ", (memory / 1048576), " MiB (delta ", ((memory - baseline) / 1024),
          " KiB; before trim ", (untrimmed / 1024), " KiB),",
          " learned ", userdb::lex.entries.len, " words, ", userdb::live_choices, " choices, ",
          userdb::live_english, " English, journal ", userdb::journal.len, ", keys ", keys, ", refinements ", refined);
    return memory;
}

// A large established dictionary makes retained serialization bytes and
// expired entries visible without waiting a year in real time. The entries
// are inserted directly as if restored; the typing phases above use keys.
fn retention(s: u64, baseline: i64) -> bool {
    userdb::reset();
    let day = userdb::today();
    for i in 12000 {
        var code: u8[>..] = [];
        code.append("word");
        var n = i;
        for _ in 4 {
            code.push(('a' + n % 26) as u8);
            n /= 26;
        }
        userdb::set_english(code, "ExampleProductNameWithSeveralWords", 1.0, day);
    }
    report("large dictionary", baseline);
    let size = session::user_save().len;
    report("after save", baseline);
    key(s, session::KEY_ESCAPE, 0, true);
    report("after next key", baseline);
    let released = session::user_saved.len == 0;
    userdb::clock_override += 365 * 86400;
    let expired_size = session::user_save().len;
    report("after expiry and save", baseline);
    let expired = userdb::english.len == 0 && userdb::live_english == 0 && userdb::pool_en.len == 0;
    print(if released && expired { "ok    " } else { "FAIL  " }, "saved ", size,
          " bytes; next key releases the copy, expiry frees dictionary slots (remaining save ", expired_size, " bytes)");
    return released && expired;
}

fn main() {
    let argv = args();
    if argv.len != 2 { write_stderr("usage: typing-memory IMAGES\n"); exit(2); }
    if session::open(argv[1]) != 0 { write_stderr("typing-memory: cannot open images\n"); exit(2); }
    var s = session::new_session();
    userdb::clock_override = 1700000000;
    let base = report("loaded", 0);
    let started = octo_now_ns();
    var warm: i64 = 0;
    var quiet: i64 = 0;
    var steady: i64 = 0;
    var last: i64 = 0;
    for round in 4 {
        batch(s, round * 300, 300, true);
        let current = report(str("no learning ", round + 1), base);
        // Give the OS allocator and model's matrix code two batches to warm.
        if round == 1 { warm = current; }
        if round == 3 { quiet = current; }
    }
    for round in 6 {
        batch(s, round * 300, 300, false);
        let current = report(str("learning ", round + 1), base);
        if round == 2 { steady = current; }
        if round == 5 { last = current; }
    }
    let flat = base > 0 && quiet - warm < 4 * 1048576 && last - steady < 4 * 1048576 && refined > 0;
    print(if flat { "ok    " } else { "FAIL  " }, "repeated typing stays within 4 MiB after warmup");
    print("elapsed ", (octo_now_ns() - started) / 1000000000, " s");
    let reclaimed = retention(s, base);
    session::free_session(s);
    session::close();
    if !flat || !reclaimed { exit(1); }
}
