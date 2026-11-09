// OctoDot M0, spike 01: a toy engine behind the C ABI the IME host calls.
//
// Everything the Swift host calls is an `export fn` in this file, and
// nothing else crosses the boundary. The rules here are the ones the real
// engine will keep:
//   * No export may abort on anything the host passes in. Bad session
//     handles, unknown keys and full buffers are handled, never asserted:
//     a failed check on the host thread ends the whole IME process.
//   * State that outlives a call lives in globals. Scratch lives in locals
//     and is freed when the call returns.
//   * Typed text never reaches print, stderr or an abort message.
import std;
import binary;
import slot_pool;

let ABI_VERSION = 1;

// A key event as the host sends it. Every field sits at its natural C
// offset, so Goose's packed layout and the C layout agree (16 bytes).
struct KeyEvent { key: u16, flags: u16, modifiers: u32, codepoint: u32, time_ms: u32 }

// KeyEvent.key: the keys the engine treats specially. KEY_OTHER means the
// key is described by its codepoint alone.
let KEY_OTHER = 0;
let KEY_BACKSPACE = 1;
let KEY_ESCAPE = 2;
let KEY_RETURN = 3;
let KEY_SPACE = 4;

// KeyEvent.modifiers
let MOD_SHIFT = 1;
let MOD_CONTROL = 2;
let MOD_OPTION = 4;
let MOD_COMMAND = 8;

// octo_key's result bits
let HANDLED = 1;
let DIRTY = 2;
let HAS_COMMIT = 4;

// The snapshot's header (little-endian "OSNP", then the format version).
let SNAP_MAGIC = 0x504E534F;
let SNAP_VERSION = 1;

// The toy lexicon: compiled into the binary, parsed once at goose_init.
struct Entry { code: u8[..16], text: u8[..24] }

let TABLE_TSV = embed_file("toy_table.tsv");
var table: Entry[>..] = load_table(TABLE_TSV);

fn load_table(tsv: const u8[:]) -> Entry[>..] {
    var t: Entry[>..] = [];
    each_split(tsv, '\n') { line =>
        let code, text, ok = split_once(line, '\t');
        // Rows that would not fit are skipped rather than aborting.
        if ok && code.len > 0 && code.len <= 16 && text.len > 0 && text.len <= 24 {
            t.push(Entry { code: code, text: text });
        }
    };
    return t;
}

// Sessions: one per IMK input controller. A handle is the slot index in
// the low 32 bits and a generation in the high 32, because the pool hands
// a freed slot to the next session and a stale handle must not alias it.
struct Session { generation: u32, live: bool }

var sessions = slot_pool<Session> {};
var next_generation: u32 = 1;

// The one composition in progress. Only one text field has focus at a
// time, so it belongs to whichever session typed last.
var active: u64 = 0;
var input: u8[..32];        // the letters typed so far
var commit: u8[..96];       // the text the last octo_key call committed
var cands: i64[..9];        // table indices of the current candidates
var snap: u8[>..];          // the snapshot buffer, lent to the host

fn session_index(handle: u64) -> i64 {
    let index = (handle & 0xFFFFFFFF) as i64;
    let generation = (handle >> 32) as u32;
    guard index < sessions.items.len else { return -1; }
    guard sessions.items[index].live && sessions.items[index].generation == generation else { return -1; }
    return index;
}

fn clear_composition() {
    input.clear();
    cands.clear();
}

fn refresh_candidates() {
    cands.clear();
    guard input.len > 0 else { return; }
    // Exact matches first, then completions, each in table order.
    for i in table.len {
        if cands.len < cands.cap && compare(table[i].code, input) == 0 { cands.push(i); }
    }
    for i in table.len {
        let code_len = table[i].code.len;
        if cands.len < cands.cap && code_len > input.len &&
           compare(table[i].code[..input.len], input) == 0 {
            cands.push(i);
        }
    }
}

fn select(n: i64) -> u32 {
    if cands.len == 0 && n == 0 {           // nothing matches: commit the letters
        commit.append(input);
        clear_composition();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    guard n < cands.len else { return HANDLED; }
    commit.append(table[cands[n]].text);
    clear_composition();
    return HANDLED | DIRTY | HAS_COMMIT;
}

export fn octo_abi_version() -> u32 { ABI_VERSION }

// client_app is the client's bundle identifier. M0 only proves that a
// string crosses; per-app privacy rules key off it later.
export fn octo_session_new(client_app: const u8[:]) -> u64 {
    let generation = next_generation;
    next_generation += 1;
    if next_generation == 0 { next_generation = 1; }
    let index = sessions.alloc_index(Session { generation: generation, live: true });
    return ((generation as u64) << 32) | (index as u64);
}

export fn octo_session_free(session: u64) {
    let index = session_index(session);
    guard index >= 0 else { return; }
    sessions.items[index].live = false;
    sessions.free(index);
    if active == session {
        clear_composition();
        active = 0;
    }
}

// Drops the composition, as when the client loses focus.
export fn octo_reset(session: u64) {
    if session == active { clear_composition(); }
}

export fn octo_key(session: u64, ev: KeyEvent) -> u32 {
    commit.clear();
    guard session_index(session) >= 0 else { return 0; }
    if active != session {
        clear_composition();
        active = session;
    }
    if (ev.modifiers & (MOD_COMMAND | MOD_CONTROL | MOD_OPTION)) != 0 { return 0; }

    let c = ev.codepoint;
    if ev.key == KEY_OTHER && c >= 'a' && c <= 'z' && (ev.modifiers & MOD_SHIFT) == 0 {
        guard input.len < input.cap else { return HANDLED; }    // full: swallow, never abort
        input.push(c as u8);
        refresh_candidates();
        return HANDLED | DIRTY;
    }
    guard input.len > 0 else { return 0; }      // not composing: the app gets the key

    if ev.key == KEY_BACKSPACE {
        input.pop();
        refresh_candidates();
        return HANDLED | DIRTY;
    }
    if ev.key == KEY_ESCAPE {
        clear_composition();
        return HANDLED | DIRTY;
    }
    if ev.key == KEY_RETURN {
        commit.append(input);
        clear_composition();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    if ev.key == KEY_SPACE { return select(0); }
    if ev.key == KEY_OTHER && c >= '1' && c <= '9' { return select(c - '1'); }
    return HANDLED;                             // swallow other keys while composing
}

fn put_text(out: u8[>..]&, s: const u8[:]) {
    binary::write_u32le(out, s.len as u32);
    out.append(s);
}

// The UI state as versioned little-endian bytes (see Snapshot.swift):
//   u32 magic, u16 version, u16 flags (bit 0: composing),
//   u32 len + preedit, u32 caret (byte offset), u32 len + commit,
//   u16 count, u16 highlighted, count x (u32 len + candidate text).
// The bytes are lent to the host until its next call into the engine.
export fn octo_snapshot(session: u64) -> const u8[:] {
    snap.clear();
    let mine = session_index(session) >= 0 && session == active;
    binary::write_u32le(snap, SNAP_MAGIC);
    binary::write_u16le(snap, SNAP_VERSION);
    if mine {
        binary::write_u16le(snap, if input.len > 0 { 1 } else { 0 });
        put_text(snap, input);
        binary::write_u32le(snap, input.len as u32);
        put_text(snap, commit);
        binary::write_u16le(snap, cands.len as u16);
        binary::write_u16le(snap, 0);
        for i in cands.len { put_text(snap, table[cands[i]].text); }
    } else {
        binary::write_u16le(snap, 0);
        put_text(snap, "");
        binary::write_u32le(snap, 0);
        put_text(snap, "");
        binary::write_u16le(snap, 0);
        binary::write_u16le(snap, 0);
    }
    return snap;
}

// Spike only, never in the real ABI: a deliberate out-of-bounds read, so
// the smoke test can watch what a failed check does to the host process.
export fn octo_debug_oob(i: i64) -> i64 { table[i].code.len }
