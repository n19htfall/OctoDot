// OctoDot M0, spike 04: fuzz targets over the code of spikes 01 and 03. The
// C driver (driver.c) feeds them bytes. A failed check, a sanitizer report
// or a broken invariant (an assert below) is a bug: on the IME's main thread
// any of them would end the process.
//
//   octo_fuzz_lexicon  the bytes are a lexicon image. An odd length goes to
//                      lexicon::load_direct, an even one to lexicon::load.
//                      Bad images must be refused, and the live lexicon must
//                      always be one that passed validation.
//   octo_fuzz_keys     each byte is a key event or a session operation on
//                      the toy engine. No sequence may abort it.
import std;
import binary;
import engine from "../01-ime-host/engine";
import lexicon from "../03-dict-image";

export fn octo_fuzz_lexicon(data: const u8[:]) -> i32 {
    var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0, install_ns: 0 };
    let direct = (data.len & 1) == 1;
    let ok = if direct { lexicon::load_direct(data, stats) } else { lexicon::load(data, stats) };
    assert(lexicon::offsets_valid(lexicon::entries, lexicon::strings));
    if ok {
        // Lookups over data the fuzzer shaped but validation accepted, with
        // keys taken from the input itself.
        let key = if data.len > 24 { data[data.len - 24..] } else { data };
        let lo, hi = lexicon::find(key);
        assert(lo >= 0 && lo <= hi && hi <= lexicon::entries.len);
        let plo, phi = lexicon::prefix_range(key[..key.len / 2]);
        assert(plo >= 0 && plo <= phi && phi <= lexicon::entries.len);
        var bytes: i64 = 0;
        for e in lexicon::entries {
            bytes += lexicon::code_of(lexicon::strings, e).len + lexicon::text_of(lexicon::strings, e).len;
        }
        assert(bytes >= 0);
    }
    return if ok { 1 } else { 0 };
}

// Fuzzing aid: rewrites an image's header checksum to match its payload.
// Without it nearly every mutation would stop at the checksum, and
// from_bytes and the offset validation behind it would go unexercised.
export fn octo_fuzz_fix_checksum(img: u8[:]) {
    guard img.len >= lexicon::HEADER_SIZE else { return; }
    let sum = lexicon::checksum(img[lexicon::HEADER_SIZE..]);
    for i in 4 { img[32 + i] = ((sum >> (8 * i)) & 0xFF) as u8; }
}

fn key_event(key: u16, modifiers: u32, codepoint: u32) -> KeyEvent {
    KeyEvent { key: key, flags: 0, modifiers: modifiers, codepoint: codepoint, time_ms: 0 }
}

fn check_snapshot(session: u64) {
    let snap = octo_snapshot(session);
    let magic, ok = binary::read_u32le(snap, 0);
    assert(ok && magic == SNAP_MAGIC && snap.len >= 22);
}

export fn octo_fuzz_keys(data: const u8[:]) -> i32 {
    var live: u64[..4] = [];
    var dead: u64 = 0;              // a freed handle, to try again later
    var current: i64 = 0;
    live.push(octo_session_new("fuzz"));
    for b in data {
        let op = b % 64;
        let s = live[current];
        if op < 26 {
            octo_key(s, key_event(KEY_OTHER, 0, 'a' + op));
        } else if op < 36 {
            octo_key(s, key_event(KEY_OTHER, 0, '0' + (op - 26)));
        } else if op < 40 {
            octo_key(s, key_event(KEY_BACKSPACE + (op - 36), 0, 0));
        } else if op < 44 {
            octo_key(s, key_event(KEY_OTHER, (b >> 4) & 15, 'a' + (b & 15)));
        } else if op == 44 {
            if live.len < live.cap { live.push(octo_session_new("fuzz")); }
        } else if op == 45 {
            if live.len > 1 {
                dead = live[current];
                octo_session_free(dead);
                live[current] = live[live.len - 1];
                live.pop();
                current = 0;
            }
        } else if op == 46 {
            octo_key(dead, key_event(KEY_OTHER, 0, 'n'));
            check_snapshot(dead);
        } else if op == 47 {
            current = (current + 1) % live.len;
        } else if op == 48 {
            octo_reset(s);
        } else {
            octo_key(s, key_event(KEY_OTHER, 0, (b as u32) * 977));   // other codepoints
        }
        check_snapshot(live[current]);
    }
    for h in live { octo_session_free(h); }
    return 0;
}
