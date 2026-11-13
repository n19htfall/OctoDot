// Fuzz targets for the image loaders; driver.c feeds them bytes. A failed
// check, a sanitizer report or a broken invariant (an assert here) is a
// bug: in the IME, a loader runs on the main thread, where any of them
// would end the process.
//
//   octo_fuzz_lexicon    the bytes are a lexicon image: load it, and if
//                        validation accepts it, look things up in it
//   octo_fuzz_spellings  the bytes are a spelling image: the same
//   octo_fuzz_aux        the bytes are an auxiliary-code image: the same
//   octo_fuzz_keys       the bytes are keystrokes, typed into a session over
//                        the real images (OCTO_FUZZ_IMAGES): after every key
//                        the session's invariants must hold
//   octo_fuzz_userdb     the bytes are a saved user dictionary: restoring it
//                        never aborts, and what it saves restores to the same
//   octo_fuzz_phrases    the bytes are a custom phrase list: compiling it never
//                        aborts, and the images it makes load and verify
//   octo_fuzz_gram       the bytes are a grammar model (.gram): mapping it
//                        refuses it, or every query stays inside it (the
//                        mapping in gram.h, under ASan; the walk in Goose)
//                        and answers within the settings' bounds
//   octo_fuzz_rerank     the bytes are a reranker image (rerank.img): the same
//                        as the other images
//   octo_fuzz_rerank_weights  the bytes are reranker weights (rerank.weights)
//                        for a tiny model: mapping them refuses them, or
//                        scoring stays inside them (rerank.h, C, under ASan),
//                        for ids both valid and cut from the bytes
import std;
import os;
import binary;
import octo from "..";

// The real images, loaded once per process, for the session targets.
var opened = false;
var session_handle: u64 = 0;

fn ensure_images() {
    if opened { return; }
    var dir: u8[>..] = [];
    if !env("OCTO_FUZZ_IMAGES", dir) {
        write_stderr("octo-fuzz: set OCTO_FUZZ_IMAGES to the images directory\n");
        exit(2);
    }
    if session::open(dir) != 0 {
        write_stderr("octo-fuzz: cannot open the images in OCTO_FUZZ_IMAGES\n");
        exit(2);
    }
    session_handle = session::new_session();
    opened = true;
}

fn event(key: i64, c: i64, modifiers: i64, flags: i64) -> session::KeyEvent {
    session::KeyEvent { key: key as u16, flags: flags as u16, modifiers: modifiers as u32, codepoint: c as u32,
                        time_ms: 0 }
}

// The invariants that hold after any key.
fn check_session() {
    assert(session::input.len <= 64 && session::consumed.len <= 64);
    let n = session::menu.candidates.len;
    assert(n <= decoder::MAX_CANDIDATES);
    assert(if n == 0 { session::highlight == 0 } else { session::highlight >= 0 && session::highlight < n });
    assert(session::page * session::PAGE_SIZE <= (if n == 0 { 0 } else { n - 1 }));
    assert(session::caps.len == session::input.len);
    for c in session::menu.candidates {
        assert(c.text + c.len <= session::menu.pool.len && c.refs + c.count <= session::menu.refs.len);
        assert(c.code_len == 0 || (c.code as i64) + (c.code_len as i64) <= session::menu.pool.len);
        assert(c.to as i64 <= session::input.len);
    }
    let snap = session::snapshot(session_handle);
    let magic, ok = binary::read_u32le(snap, 0);
    assert(ok && magic == session::SNAP_MAGIC);
    let preedit, ok2 = binary::read_u32le(snap, 8);
    assert(ok2 && (session::composing() || preedit == 0));     // nothing shown once a composition is over
}

export fn octo_fuzz_lexicon(data: const u8[:]) -> i32 {
    var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
    if !lexicon::load(data, stats) {
        assert(lexicon::live.entries.len == 0 && lexicon::live.plain.len == 0);    // nothing half-loaded
        return 0;
    }
    // Lookups over what validation accepted, with codes taken from the input.
    let np = lexicon::live.plain.len;
    var code: u16[>..] = [];
    for i in (if data.len < 8 { data.len } else { 8 }) {
        code.push((data[data.len - 1 - i] % np) as u16);
    }
    for d in 1..code.len + 1 {
        let lo, hi = lexicon::prefix_range(lexicon::live, code[..d]);
        assert(lo >= 0 && lo <= hi && hi <= lexicon::live.entries.len);
        let elo, ehi = lexicon::exact(lexicon::live, code[..d]);
        assert(elo == lo && ehi <= hi);
        for i in elo..ehi {
            var text: u8[>..] = [];
            lexicon::text(lexicon::live, i, text);
        }
        let nlo, nhi = lexicon::narrow(lexicon::live, lo, hi, d, 0, np - 1);
        assert(nlo >= lo && nhi <= hi);
    }
    for mark in lexicon::live.marks {           // the text of every entry with a mark
        var text: u8[>..] = [];
        lexicon::text(lexicon::live, mark.entry, text);
        assert(text.len > 0);
    }
    return 1;
}

export fn octo_fuzz_spellings(data: const u8[:]) -> i32 {
    let digest, ok = binary::read_u64le(data, 24);      // whichever syllabary the image names
    if !spelling::load(data, digest, 65535) {
        assert(spelling::live.spellings.len == 0 && spelling::live.rows.len == 0);
        return 0;
    }
    for i in spelling::live.spellings.len {
        assert(spelling::find(spelling::live, spelling::live.spellings[i].text) == i);
    }
    let at = spelling::find(spelling::live, data[..(if data.len < 15 { data.len } else { 15 })]);
    assert(at >= -1 && at < spelling::live.spellings.len);
    return 1;
}

export fn octo_fuzz_english(data: const u8[:]) -> i32 {
    if !english::load(data) {
        assert(english::entry_count() == 0 && english::live.forms.len == 0);
        return 0;
    }
    let n = english::entry_count();
    let step = if n > 64 { n / 64 } else { 1 };
    var i: i64 = 0;
    while i < n {
        assert(english::exact(english::entry_at(i).code) == i);
        var form: u8[>..] = [];
        english::top_form(i, form);
        assert(form.len > 0);
        i += step;
    }
    let prefix = data[..(if data.len < 4 { data.len } else { 4 })];
    var ids: i64[>..] = [];
    english::completions(prefix, 2, ids);
    assert(ids.len <= 2);
    for id in ids { assert(id >= 0 && id < n); }
    english::exact(prefix);
    return 1;
}

export fn octo_fuzz_aux(data: const u8[:]) -> i32 {
    if !auxcode::load(data) {
        assert(auxcode::live.chars.len == 0 && auxcode::live.codes.len == 0);
        return 0;
    }
    let n = auxcode::live.chars.len;
    for i in n {
        let k: i64 = auxcode::live.first[i];
        assert(auxcode::fits(auxcode::live, auxcode::live.chars[i], auxcode::live.codes[k].text));
        assert(auxcode::fits(auxcode::live, auxcode::live.chars[i], ""));
    }
    let probe = data[..(if data.len < 2 { data.len } else { 2 })];
    let cp = if data.len >= 4 { (data[data.len - 1] as u32) | ((data[data.len - 2] as u32) << 8) } else { 0 };
    auxcode::fits(auxcode::live, cp, probe);
    return 1;
}

// Keystrokes. Readable bytes type themselves, so seeds are plain text:
// letters, digits, ' ` , . ; - = and space. Control bytes are the other keys:
//   8 backspace   27 escape   10, 13 return   1-4 arrows   5, 6 page down, up
//   7 shift alone   14 control-g   15 shift-backspace   16 switch scheme
//   17 no-learn on or off for what follows   18 save and restore the user
//   dictionary   19 forget the last 15 minutes   20 地名 on or off
//   21 shape codes 自然码 or 万象
// Any other byte is a letter.
let MAX_KEYS = 512;                 // keystrokes per input: each run stays bounded

export fn octo_fuzz_keys(data: const u8[:]) -> i32 {
    ensure_images();
    userdb::reset();
    userdb::clock_override = 1794000000;
    let s = session_handle;
    session::key(s, event(session::KEY_ESCAPE, 0, 0, 0));
    var flags: i64 = 0;
    for b in data[..(if data.len < MAX_KEYS { data.len } else { MAX_KEYS })] {
        let c: i64 = b;
        if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '\'' || c == '`' || c == ',' || c == '.' ||
           c == ';' || c == '-' || c == '=' {
            session::key(s, event(session::KEY_OTHER, c, 0, flags));
        } else if c == ' ' { session::key(s, event(session::KEY_SPACE, 0, 0, flags)); }
        else if c == 8 { session::key(s, event(session::KEY_BACKSPACE, 0, 0, flags)); }
        else if c == 27 { session::key(s, event(session::KEY_ESCAPE, 0, 0, flags)); }
        else if c == 10 || c == 13 { session::key(s, event(session::KEY_RETURN, 0, 0, flags)); }
        else if c >= 1 && c <= 4 { session::key(s, event(session::KEY_LEFT + c - 1, 0, 0, flags)); }
        else if c == 5 { session::key(s, event(session::KEY_PAGE_DOWN, 0, 0, flags)); }
        else if c == 6 { session::key(s, event(session::KEY_PAGE_UP, 0, 0, flags)); }
        else if c == 14 { session::key(s, event(session::KEY_OTHER, 'g', session::MOD_CONTROL, flags)); }
        else if c == 15 { session::key(s, event(session::KEY_BACKSPACE, 0, session::MOD_SHIFT, flags)); }
        else if c == 16 { session::set_scheme(if session::scheme == "flypy" { "fullpinyin" } else { "flypy" }); }
        else if c == 17 { flags = flags ^ session::KEYFLAG_NO_LEARN; }
        else if c == 18 {
            var saved: u8[>..] = [];
            saved.append(session::user_save());
            assert(session::user_restore(saved) == 0);
        }
        else if c == 19 { userdb::forget(userdb::RECENT); }
        else if c == 20 { session::use_set("diming", !sets::mounted("diming")); }   // mid-composition, too
        else if c == 21 { session::set_aux_scheme(if session::aux_scheme == "zrm" { "wanxiang" } else { "zrm" }); }
        else { session::key(s, event(session::KEY_OTHER, 'a' + c % 26, 0, flags)); }
        check_session();
    }
    session::key(s, event(session::KEY_ESCAPE, 0, 0, 0));
    if session::scheme != "fullpinyin" { session::set_scheme("fullpinyin"); }
    if !sets::mounted("diming") { session::use_set("diming", true); }
    if session::aux_scheme != "wanxiang" { session::set_aux_scheme("wanxiang"); }
    decoder::full_charset = false;
    return 1;
}

// A saved user dictionary, as the host would hand back a file it decrypted.
export fn octo_fuzz_userdb(data: const u8[:]) -> i32 {
    ensure_images();
    userdb::clock_override = 1794000000;
    if !userdb::restore(data) {
        assert(userdb::lex.entries.len == 0 && userdb::live_choices == 0);    // refused: empty, not half-loaded
        return 0;
    }
    var first: u8[>..] = [];
    userdb::save(first);
    assert(userdb::restore(first));
    var second: u8[>..] = [];
    userdb::save(second);
    assert(compare(first, second) == 0);       // what it saves restores to the same
    session::input.clear();
    session::input.append("xian");             // and ranking still works over it
    session::rebuild();
    session::clear_composition();
    userdb::reset();
    return 1;
}

// A custom phrase list, compiled as the worker would, against the real core.
var phrase_syllables: u8[>..] = [];

export fn octo_fuzz_phrases(data: const u8[:]) -> i32 {
    ensure_images();
    if phrase_syllables.len == 0 {
        var dir: u8[>..] = [];
        env("OCTO_FUZZ_IMAGES", dir);
        read_file(str(dir, "/syllables.tsv"), phrase_syllables);
    }
    var words: u8[>..] = [];
    var shortcuts: u8[>..] = [];
    var report = phrases::Report { words: 0, shortcuts: 0, skipped: 0, first_bad: 0, why: [] };
    var keys = dictionary<const u8[:], i64> {};
    let ok = phrases::compile(data, lexicon::live, phrase_syllables, keys, words, shortcuts, report);
    var table = phrases::Shortcuts {};
    assert(phrases::load_into(table, shortcuts) && table.list.len == report.shortcuts);
    if words.len > 0 {
        var lex = lexicon::Lexicon {};
        var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
        let loaded, digest = lexicon::load_into(lex, words, stats);
        assert(ok && loaded && digest == lexicon::live_digest && lex.entries.len <= report.words);
    }
    return 1;
}

// A grammar model file. The mapping is C, so AddressSanitizer covers it;
// the walk is Goose. Contexts and words are fixed strings and slices of
// the bytes themselves, malformed UTF-8 included. A file is refused, or
// every query stays inside it.
export fn octo_fuzz_gram(data: const u8[:]) -> i32 {
    if !write_file("fuzz-gram.gram", data) { return 0; }
    grammar::octo_gram_settings(6, 2, -14.0, -6.0, -100.0, -18.0);
    if grammar::octo_gram_open("fuzz-gram.gram", 0) == 0 {
        let fixed = ["我们", "一起", "冰川", "萎缩", "的", "上海人", "a", "$"];
        for c in fixed {
            for w in fixed {
                for rear in [false, true] {
                    let q = grammar::octo_gram_query(c, w, rear);
                    assert(q >= -6.0 && q <= 214749.0);
                }
            }
        }
        var at: i64 = 44;
        while at + 16 <= data.len {
            let q = grammar::octo_gram_query(data[at..at + 9], data[at + 9..at + 16], (data[at] & 1) == 1);
            assert(q >= -6.0 && q <= 214749.0);
            at += 97;
        }
    }
    grammar::octo_gram_close();
    return 1;
}

export fn octo_fuzz_rerank(data: const u8[:]) -> i32 {
    var m = rerank::Model {};
    if !rerank::load_into(m, data) {
        assert(m.meta.len == 0 && m.chars.len == 0);
        return 0;
    }
    assert(rerank::valid(m) && (m.meta[0].vocab as i64) == m.chars.len + rerank::SPECIALS);
    var again: u8[>..] = [];
    rerank::write(m, again);
    var back = rerank::Model {};
    assert(rerank::load_into(back, again) && back.chars.len == m.chars.len);
    return 1;
}

// The shape the weights target maps: 8 wide, 1 layer of 2 heads, 8 ids, 6
// positions (rerank.weights of 4,024 bytes; seeds/rerank-weights holds one).
let FUZZ_DIMS = 8;
let FUZZ_VOCAB = 8;
let FUZZ_POSITIONS = 6;

export fn octo_fuzz_rerank_weights(data: const u8[:]) -> i32 {
    if !write_file("fuzz-rerank.weights", data) { return 0; }
    if rerank::octo_rerank_open("fuzz-rerank.weights", data.len as u64, FUZZ_DIMS as i32, 1, 2, FUZZ_VOCAB as i32,
                                FUZZ_POSITIONS as i32) == 0 {
        let ids: i32[9] = [1, 3, 4, 2, 1, 5, 6, 7, 2];
        let starts: i32[3] = [0, 4, 9];
        var bits: f64[2] = [0.0, 0.0];
        assert(rerank::octo_rerank_score(ids[..], starts[..], bits[..]) == 0);
        // The same mapping, several cached calls: a shared prefix, then a
        // branch that leaves it, then ids and offsets the C must reject.
        let a_ids: i32[8] = [1, 3, 4, 2, 1, 3, 5, 2];
        let a_starts: i32[3] = [0, 4, 8];
        var abits: f64[2] = [0.0, 0.0];
        let ra = rerank::octo_rerank_cache_score(a_ids[..], a_starts[..], abits[..]);
        assert(ra == 0 || ra == 2);
        let b_ids: i32[9] = [1, 3, 4, 6, 2, 1, 3, 7, 2];
        let b_starts: i32[3] = [0, 5, 9];
        var bbits: f64[2] = [0.0, 0.0];
        let rb = rerank::octo_rerank_cache_score(b_ids[..], b_starts[..], bbits[..]);
        assert(rb == 0 || rb == 2);
        let bad_ids: i32[4] = [99, -1, 1, 2];
        let bad_starts: i32[3] = [0, 3, 2];
        var bad_bits: f64[2] = [0.0, 0.0];
        assert(rerank::octo_rerank_cache_score(bad_ids[..], bad_starts[..], bad_bits[..]) == 1);
        assert(rerank::octo_rerank_score(bad_ids[..], bad_starts[..], bad_bits[..]) == 1);
        let back_ids: i32[4] = [1, 3, 4, 2];
        let back_starts: i32[3] = [0, 5, 4];
        assert(rerank::octo_rerank_cache_score(back_ids[..], back_starts[..], bad_bits[..]) == 1);
        rerank::octo_rerank_cache_clear();
        let rclear = rerank::octo_rerank_cache_score(a_ids[..], a_starts[..], abits[..]);
        assert(rclear == 0 || rclear == 2);
        if rclear == 0 { assert(rerank::octo_rerank_cache_last_hits() == 0); }
        // Closing drops the trie. The same shape, opened again, must not
        // reuse the previous model's nodes on its first job.
        rerank::octo_rerank_close();
        if rerank::octo_rerank_open("fuzz-rerank.weights", data.len as u64, FUZZ_DIMS as i32, 1, 2, FUZZ_VOCAB as i32,
                                    FUZZ_POSITIONS as i32) == 0 {
            assert(rerank::octo_rerank_cache_live() == 0);
            let reopened = rerank::octo_rerank_cache_score(a_ids[..], a_starts[..], abits[..]);
            assert(reopened == 0 || reopened == 2);
            assert(rerank::octo_rerank_cache_last_hits() == 0);
            if reopened == 0 && rerank::octo_rerank_cache_last_fallback() == 0 {
                let again = rerank::octo_rerank_cache_score(a_ids[..], a_starts[..], abits[..]);
                if again == 0 {
                    assert(rerank::octo_rerank_cache_last_hits() == rerank::octo_rerank_cache_last_nodes());
                    assert(rerank::octo_rerank_cache_last_forward() == 0);
                }
            }
        }
        // Ids and lengths cut from the bytes: any values, which the C must
        // check (an id outside the vocabulary, a sequence too long or short).
        var cut: i32[..32] = [];
        var at: i64 = 24;
        while at < data.len && cut.len < 12 {
            cut.push((data[at] as i32) - 64);
            at += 37;
        }
        if cut.len >= 2 {
            let half = (cut.len / 2) as i32;
            let parts: i32[3] = [0, half, cut.len as i32];
            var two: f64[2] = [0.0, 0.0];
            let r = rerank::octo_rerank_score(cut[..], parts[..], two[..]);
            assert(r == 0 || r == 1);
            let rc = rerank::octo_rerank_cache_score(cut[..], parts[..], two[..]);
            assert(rc == 0 || rc == 1 || rc == 2);
        }
        rerank::octo_rerank_cache_free();
    }
    rerank::octo_rerank_close();
    return 1;
}

// Re-stamps an image's checksum, so mutations reach from_bytes and validation.
export fn octo_fuzz_restamp(img: u8[:]) { image::restamp(img); }

// A known Goose abort, so the harness can prove a crash is caught.
var canary_index: i64 = 3;
export fn octo_fuzz_canary() -> i64 {
    let xs: i64[3] = [1, 2, 3];
    return xs[canary_index];
}
