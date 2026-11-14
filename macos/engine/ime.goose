// The IME's C ABI (ABI_VERSION below): what the Swift host calls, and nothing else.
// Every export runs on the thread that called goose_init (the main thread),
// and none may abort on anything the host passes in.
import std;
import octo from "../../engine";

let ABI_VERSION = 18;

export fn octo_abi_version() -> u32 { ABI_VERSION }

// Loads the images from the app's data directory. 0, or what failed:
// 1 lexicon.img unreadable, 2 invalid; 3 spellings unreadable, 4 invalid.
export fn octo_open(directory: const u8[:]) -> i32 { session::open(directory) }

// client_app is unused. Per-app behavior arrives as a flag on each key.
export fn octo_session_new(client_app: const u8[:]) -> u64 { session::new_session() }

export fn octo_session_free(handle: u64) { session::free_session(handle); }

// Drops the composition, as when the client loses focus.
export fn octo_reset(handle: u64) { session::reset(handle); }

// A key: session::KEY_* (0 when the codepoint alone describes it),
// session::MOD_* bits, the character it types, and session::KEYFLAG_* bits
// from the host's privacy policy (KEYFLAG_NO_LEARN: a secure field, a
// no-learn app, incognito; KEYFLAG_HALFWIDTH_PUNCT: this client's
// punctuation is committed as the key's own character). Plain scalars, so no generated struct name
// becomes part of the ABI. The result's bits: 1 handled, 2 dirty (call
// octo_snapshot), 4 the snapshot holds a commit, 8 pending (the reranker may
// change the menu: call octo_refine before showing the candidates).
export fn octo_key(handle: u64, key: u32, modifiers: u32, codepoint: u32, flags: u32) -> u32 {
    session::key(handle, session::KeyEvent { key: (key & 0xFFFF) as u16, flags: (flags & 0xFFFF) as u16,
                                             modifiers: modifiers, codepoint: codepoint, time_ms: 0 })
}

// UTF-8 to commit in place of the next selected candidate. Empty, or longer
// than the composition can hold, keeps the candidate. The next key consumes it.
export fn octo_set_pick_text(handle: u64, text: const u8[:]) { session::set_pick_text(handle, text); }

// The UI state (format in engine/session.goose), lent until the next call.
export fn octo_snapshot(handle: u64) -> const u8[:] { session::snapshot(handle) }

// The user dictionary as text (format in engine/userdb.goose), for the host
// to encrypt and store; lent until the next call.
export fn octo_user_save() -> const u8[:] { session::user_save() }

// Replaces the user dictionary with one the host stored: 0, or 1 if the
// bytes are not one (it is then empty). Call after octo_open.
export fn octo_user_restore(data: const u8[:]) -> i32 { session::user_restore(data) }

// The last 15 minutes of learning, named by what changed, for the next build
// of the engine the host loads in this process, so "forget the last 15
// minutes" still covers them. Lent until the next call.
export fn octo_journal_save() -> const u8[:] { session::journal_save() }

// Takes over what octo_journal_save handed over, after octo_user_restore of
// the dictionary it belongs to: the number of changes taken over.
export fn octo_journal_restore(data: const u8[:]) -> i64 { userdb::journal_restore(data) }

// Bumped on every change to the user dictionary: save when it moves.
export fn octo_user_changes() -> u64 { userdb::changes }

// Takes back learning: 0 the last 15 minutes, 1 today, 2 everything.
// Returns how many words and choices were removed or restored.
export fn octo_forget(scope: u32) -> u32 {
    if scope > 2 { return 0; }
    let n = userdb::forget(scope);
    return if n > 0xFFFFFFFF { 0xFFFFFFFF } else { n as u32 };
}

// The local time zone, seconds east of UTC: learning is kept by local day.
export fn octo_set_utc_offset(seconds: i32) {
    if seconds >= -86400 && seconds <= 86400 { userdb::utc_offset = seconds; }
}

// The input schemes the data directory holds, one per line:
// "id \t name \t preedit" (preedit: typed or syllables). Lent until the next call.
export fn octo_schemes() -> const u8[:] { session::scheme_list }

// Switches the input scheme (an id from octo_schemes): 0, or 1 if it is not
// there or does not verify, leaving the current one in place.
export fn octo_set_scheme(id: const u8[:]) -> i32 { session::set_scheme(id) }

// Lexicon sets beside the core (docs/hotswap-architecture.md), one per line:
// "id \t name \t on|off (by default) \t mounted|off". Lent until the next call.
export fn octo_sets() -> const u8[:] { session::sets_list() }

// Turns a set on (1) or off (0) at once: 0, or 1 if it cannot be done (no
// such set, its image does not verify, or no slot is free).
export fn octo_mount(id: const u8[:], on: u32) -> i32 { session::use_set(id, on != 0) }

// The shape-code schemes, one per line: "id \t name". Lent until the next call.
export fn octo_aux_schemes() -> const u8[:] { session::aux_list() }

// Switches the shape-code scheme: 0, or 1 if it is not there (the current one stays).
export fn octo_set_aux_scheme(id: const u8[:]) -> i32 { session::set_aux_scheme(id) }

// Custom phrases (engine/phrases.goose). Starts compiling the phrase file
// `source` into images in `out`, in a contained worker; returns the job id,
// or 0 if it cannot start. The result arrives through octo_pump.
export fn octo_compile_phrases(source: const u8[:], out: const u8[:]) -> u64 { session::compile_phrases(source, out) }

// Call on the main thread while a job may be pending: 1 if something
// changed (a job finished, or its result was put in use), 2 if a job is still
// running or its result waits for the composition to end.
export fn octo_pump() -> u32 { session::pump() }

// "state \t words \t shortcuts \t skipped \t first bad line \t why", state
// one of idle, compiling, ready, failed. Lent until the next call.
export fn octo_phrases_status() -> const u8[:] { session::phrases_status() }

// Puts phrases compiled before into use from `directory`, without compiling:
// 0, or 1 if an image there does not verify.
export fn octo_mount_phrases(directory: const u8[:]) -> i32 { session::mount_phrases(directory) }

// Returns memory the engine no longer uses to the system: on memory pressure.
export fn octo_trim() { session::trim(); }

// Releases what the engine holds outside the Goose runtime, before the host
// calls goose_exit (to load a new build of the engine, or to quit).
export fn octo_close() { session::close(); }

// The grammar model: -1 if the images have none (or its file is not there), 0 off, 1 on.
export fn octo_grammar() -> i32 { session::grammar_state() }

// Where else the grammar model's .gram file may be, when it is not beside
// grammar.img: the IME's shared folder, where it lives outside the bundle.
// Before octo_open.
export fn octo_set_grammar_folder(directory: const u8[:]) { session::set_grammar_folder(directory); }

// Turns the grammar model on (1) or off (0) at once: 0, or 1 if it cannot be turned on.
export fn octo_set_grammar(on: u32) -> i32 { session::set_grammar(on != 0) }

// English words beside the Chinese (docs/english-design.md). On by default.
// 1 while candidates are offered, 0 while they are not.
export fn octo_english() -> i32 { if english::on { 1 } else { 0 } }

export fn octo_set_english(on: u32) { session::set_english(on != 0); }

// The reranker (engine/rerank.goose), which may put a better sentence first.
// After a key whose result has 8 (pending), call before showing the
// candidates (a few milliseconds): 2 (dirty) if the menu changed (call
// octo_snapshot), else 0.
export fn octo_refine(handle: u64) -> u32 { session::refine(handle) }

// -1 if the images hold no reranker, else 1 while it is on and 0 while off.
export fn octo_rerank() -> i32 { session::rerank_state() }

// Turns the reranker on (1) or off (0).
export fn octo_set_rerank(on: u32) { session::set_rerank(on != 0); }

// What was committed just before a composition, read for its candidates
// (engine/session_context.goose). On by default; off (0), every menu is made
// as if nothing came before it. 1 while on.
export fn octo_context() -> i32 { if session::context_on { 1 } else { 0 } }
export fn octo_set_context(on: u32) { session::set_context(on != 0); }

// The full character set (1) or 万象's daily one (0): the default that
// Control-g switches from while composing. 1 while the full one is in use.
export fn octo_full_charset() -> i32 { if decoder::full_charset { 1 } else { 0 } }
export fn octo_set_full_charset(on: u32) { session::set_full_charset(on != 0); }

// Fuzzy pinyin (docs/fuzzy-pinyin.md). The scheme's fuzzy groups, one per
// line, "id \t 1" for on and "id \t 0" for off ("z_zh" is z = zh); lent
// until the next call. Turning them on: their ids, space-separated (none by
// default; empty turns all off).
export fn octo_fuzzy_groups() -> const u8[:] { session::fuzzy_groups() }
export fn octo_set_fuzzy(ids: const u8[:]) { session::set_fuzzy(ids); }
