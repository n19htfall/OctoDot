// Composing text: keys in, a snapshot of what to show out. One session per
// client text field, one composition at a time (only one field has focus).
//
// Nothing a host passes in may abort: bad handles, unknown keys and full
// buffers are handled, never asserted. A failed check on the IME's main
// thread would end the process.
import std;
import os;
import binary;
import slot_pool;
import lexicon;
import spelling;
import auxcode;
import image;
import lattice;
import decoder;
import userdb;
import sets;
import phrases;
import english;
import rerank;

namespace session;

let PAGE_SIZE = 6;          // so 1-6 pick and 7 8 9 0 are free for tones, as in 万象
let GRID_ROWS = 5;          // the candidate grid Down opens: this many rows at a time

// A key as the host sends it. Every field sits at its natural C offset, so
// Goose's packed layout and C's agree (16 bytes).
struct KeyEvent { key: u16, flags: u16, modifiers: u32, codepoint: u32, time_ms: u32 }

// KeyEvent.key. KEY_OTHER: the codepoint alone describes the key.
let KEY_OTHER = 0;
let KEY_BACKSPACE = 1;
let KEY_ESCAPE = 2;
let KEY_RETURN = 3;
let KEY_SPACE = 4;
let KEY_LEFT = 5;
let KEY_RIGHT = 6;
let KEY_UP = 7;
let KEY_DOWN = 8;
let KEY_PAGE_UP = 9;
let KEY_PAGE_DOWN = 10;
let KEY_HOME = 11;
let KEY_END = 12;

// KeyEvent.flags, set by the host from its privacy policy: a key that must
// not teach the user dictionary (a secure field, a no-learn app, incognito).
let KEYFLAG_NO_LEARN = 1;
let KEYFLAG_PICK = 2;       // codepoint is a candidate index to commit (a click in the window)
let KEYFLAG_HALFWIDTH_PUNCT = 4; // punctuation is committed as the key's own character

// KeyEvent.modifiers
let MOD_SHIFT = 1;
let MOD_CONTROL = 2;
let MOD_OPTION = 4;
let MOD_COMMAND = 8;

// key()'s result bits
let HANDLED = 1;
let DIRTY = 2;
let HAS_COMMIT = 4;
let PENDING = 8;            // the reranker may change the menu: call refine before showing the candidates

// The snapshot: little-endian "OSNP", version 2 (see Snapshot.swift).
let SNAP_MAGIC = 0x504E534F;
let SNAP_VERSION = 2;
let FLAG_COMPOSING = 1;
// 2 was English mode (FLAG_ASCII), removed: no key leaves Chinese input.
let FLAG_PREVIOUS_PAGE = 4;
let FLAG_NEXT_PAGE = 8;
let FLAG_FULL_CHARSET = 16;   // rare characters are shown too (Control-g)
let FLAG_EXPANDED = 32;       // the candidate grid is open (Down); the bar shows one row otherwise

struct Session { generation: u32, live: bool }

// A selection made inside a composition: the letters it read, the bytes of
// its text, how many words it was made of (in picked_ends) and how many
// character readings they have (in picked_pairs).
struct Pick { letters: u8, bytes: u16, words: u8, pairs: u8, english: u8, foreign: u8 }

var sessions = slot_pool<Session> {};
var next_generation: u32 = 1;
var ready = false;          // the lexicon and spelling table are loaded

// The composition, owned by whichever session typed last.
var active: u64 = 0;
var input: u8[..lattice::MAX_INPUT];        // not yet converted: letters, ' separators, tones, ` shape codes
var caps: u8[..lattice::MAX_INPUT];         // 1 where that input byte was typed as a capital
var consumed: u8[..lattice::MAX_INPUT];     // letters the selections so far have read
var confirmed: u8[..phrases::MAX_TEXT];     // the selections' text; a compiled phrase fits
var pick_text: u8[..phrases::MAX_TEXT];
var pick_for: u64 = 0;
var picks: Pick[..lattice::MAX_INPUT];
// The picks' words, copied when picked, so the composition learns what was
// chosen even if the user dictionary changes before it commits: the words'
// readings back to back, and where each word ends (-1 for a word the
// dictionary does not keep, such as one with marks).
var picked_pairs: lexicon::Pair[..lattice::MAX_INPUT];
var picked_ends: i16[..lattice::MAX_INPUT];
// The best reading's first word, kept when the menu is built: committed to
// make room when the input is full (make_room).
var lead_to: i64 = 0;                   // where it ends in the input; 0 for none
var lead_text: u8[>..];
var menu_changes: u64 = 0;              // userdb::changes when the menu was built
var learning_allowed = true;            // for the key being handled (KEYFLAG_NO_LEARN)
var refreshed_day: u32 = 0;             // when the user dictionary's weights were last aged
var user_saved: u8[>..];                // the bytes octo_user_save lends

// The last few commits, so that one the user deletes right away (Backspace
// passing through to the app, character by character) and then types again
// differently can be taken back from the user dictionary: its learning was
// a mistake. A commit that taught nothing is kept too, with commit 0, so the
// deleted characters are counted against the right commit.
struct Recent { input: u8[..lattice::MAX_INPUT], chars: u16, erased: u16, commit: u32, text: u64 }
let RECENT_COMMITS = 4;
var recent: Recent[..4];
var commits: u32 = 0;                   // commit ids for the user dictionary's journal
// One key can commit two phrases: the picks that filled the buffer, then the
// selection that did not fit, and a punctuation mark after either.
var commit: u8[..2064];
var page: i64 = 0;
var highlight: i64 = 0;     // within the whole menu
var expanded = false;       // Down opened the candidate grid
var grid_row: i64 = 0;      // first visible row of that grid
var last_was_digit = false;  // so "3.14" keeps its period
var double_open = false;
var single_open = false;
var menu = decoder::Menu {};
var readable: i64 = 0;      // how much of the input the menu reads
var letters_unread = false; // a letter the Chinese reading does not cover (English rule 1)
// The best reading covers every key with full syllables (no abbreviation,
// no half-typed syllable): the keys are plainly Chinese, so English does not
// push in ahead of its candidates (rules 4 and 5). "he", "long", "chang" in
// full pinyin, and most key pairs in 小鹤双拼, read this way.
var chinese_full = false;
// log2 of the best reading's probability: its words' scores summed. A
// reading of real words scores far above one pieced together from rare
// characters (的这螺片蒽酮 for development).
var chinese_bits = 0.0;
var weak_chinese = false;   // the exact English match came first over that reading (place_english)
var builds: u64 = 0;        // menus built: a late score applies only to the menu it was for
var words = decoder::Words {};          // the words the menu being shown was built from
var shortlist = decoder::Shortlist {};  // what the reranker scores for it
var rerank_due: u64 = 0;    // the menu (builds) still to be reranked, at refine; 0 for none
var rerank_sync = false;    // tests and the accuracy harness: score at once, on this thread
var shown: u8[>..];         // the input as the preedit shows it: the keys typed, by syllable
var snap: u8[>..];
var aux_scheme: u8[>..];        // which aux.<scheme>.img open() loads; "none" disables shape codes
var scheme: u8[>..];            // the input scheme: spellings.<scheme>.img
var data_dir: u8[>..];          // where open() found the images
var scheme_list: u8[>..];       // "id \t name \t preedit" per scheme found there, for the host
var use_grammar = true;         // map the grammar model, if the images have one

// Loads the images from `directory`: 0, or what failed. The auxiliary codes
// and the grammar model are optional: without them ` is simply not
// accepted, and sentences are made without context.
fn open(directory: const u8[:]) -> i32 {
    ready = false;
    var kept: u8[>..] = [];         // the user dictionary, by text, across a reload
    if userdb::lex.entries.len > 0 || userdb::dormant.len > 0 || userdb::live_choices > 0 || userdb::live_english > 0 {
        userdb::save(kept);
    }
    userdb::reset();
    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/lexicon.img"), img) { return 1; }
        var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
        if !lexicon::load(img, stats) { return 2; }
    }
    data_dir.clear();
    data_dir.append(directory);
    sets::reset();
    sets::survey(directory);
    mount_defaults();
    list_schemes();
    if scheme.len == 0 { scheme.append("fullpinyin"); }
    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/spellings.", scheme, ".img"), img) { return 3; }
        if !spelling::load(img, lexicon::live_digest, lexicon::live.toned.len) { return 4; }
        apply_fuzzy();
    }
    userdb::scope.clear();
    userdb::scope.append(scheme);
    if aux_scheme.len == 0 { aux_scheme.append("none"); }
    if aux_scheme == "none" {
        auxcode::clear(auxcode::live);
    } else {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/aux.", aux_scheme, ".img"), img) || !auxcode::load(img) {
            auxcode::clear(auxcode::live);
        }
    }
    if use_grammar { grammar::open(directory); } else { grammar::close(); }
    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/english.img"), img) || !english::load(img) { english::clear_live(); }
    }
    rerank::open(directory);        // no model in the images: the reranker stays off
    decoder::forget_fits();
    userdb::reset();                // now bound to this lexicon's syllables
    if kept.len > 0 { userdb::restore(kept); }
    trim_memory();
    ready = true;
    return 0;
}

fn index(handle: u64) -> i64 {
    let i = (handle & 0xFFFFFFFF) as i64;
    let generation = (handle >> 32) as u32;
    guard i < sessions.items.len else { return -1; }
    guard sessions.items[i].live && sessions.items[i].generation == generation else { return -1; }
    return i;
}

fn new_session() -> u64 {
    let generation = next_generation;
    next_generation += 1;
    if next_generation == 0 { next_generation = 1; }
    let i = sessions.alloc_index(Session { generation: generation, live: true });
    return ((generation as u64) << 32) | (i as u64);
}

fn free_session(handle: u64) {
    let i = index(handle);
    guard i >= 0 else { return; }
    sessions.items[i].live = false;
    sessions.free(i);
    if active == handle {
        clear_client_context();
        active = 0;
    }
}

fn reset(handle: u64) {
    if handle == active { clear_client_context(); }
}

// A different caret cannot refer to the previous field's commits or text.
fn clear_client_context() {
    clear_composition();
    recent.clear();
    userdb::set_carry(0, 0);
    last_was_digit = false;
}

fn chars_in(text: const u8[:]) -> i64 {
    var n: i64 = 0;
    for c in text { if (c & 0xC0) != 0x80 { n++; } }
    return n;
}

fn remember(input: const u8[:], text: const u8[:], commit: u32) {
    let chars = chars_in(text);
    guard chars > 0 && chars < 65536 else { return; }
    if recent.len == RECENT_COMMITS {
        for i in 1..recent.len { recent[i - 1] = recent[i]; }
        recent.pop();
    }
    var r = Recent { input: [], chars: chars as u16, erased: 0, commit: commit, text: hash(text) };
    r.input.append(if input.len > r.input.cap { input[..r.input.cap] } else { input });
    recent.push(r);
}

// Backspace passed through to the app: one more character of the latest
// commit not yet wholly deleted. Deleting more than was committed means the
// user is editing something else, so nothing is remembered then.
fn note_backspace() {
    var i = recent.len - 1;
    while i >= 0 && recent[i].erased == recent[i].chars { i--; }
    if i < 0 {
        recent.clear();
        return;
    }
    recent[i].erased += 1;
}

// A commit of `input` choosing `text` is about to teach: if a recent commit
// of the same input (or one this input begins) was just deleted and chose
// something else, its learning is taken back. Deleted commits this input
// does not match were edits elsewhere and are dropped.
fn retract_mistake(input: const u8[:], text: const u8[:]) {
    var i = recent.len - 1;
    while i >= 0 {
        let r = recent[i];
        if r.erased == r.chars && input.len > 0 && r.input.len >= input.len && compare(r.input[..input.len], input) == 0 {
            if r.text != hash(text) { userdb::retract(r.commit); }
            for k in i + 1..recent.len { recent[k - 1] = recent[k]; }
            recent.pop();
            return;
        }
        i--;
    }
    var kept: Recent[..4] = [];
    for r in recent { if r.erased < r.chars { kept.push(r); } }
    recent.clear();
    recent.append(kept);
}

fn composing() -> bool { input.len > 0 || picks.len > 0 }

fn room() -> bool { input.len < input.cap && consumed.len + input.len < lattice::MAX_INPUT }

// The input is full and another key came: the selections so far and the
// best reading's first word are committed, and the rest stays to convert,
// so the key is kept rather than lost. The selections teach as usual; the
// first word teaches nothing, since no one chose it. Input with no reading
// is committed as typed. The caller adds the key and rebuilds the menu.
fn make_room() {
    fresh_menu();
    if lead_to <= 0 || lead_to > input.len {
        commit_raw();
        return;
    }
    learn_composition();
    append_commit(confirmed);
    append_commit(lead_text);
    var keys: u8[>..] = [];
    for c in input[..lead_to] { if c != '\'' { keys.push(c); } }
    remember(keys, lead_text, 0);
    var rest: u8[..lattice::MAX_INPUT] = [];
    var rest_caps: u8[..lattice::MAX_INPUT] = [];
    var from = lead_to;
    while from < input.len && input[from] == '\'' { from++; }
    rest.append(input[from..]);
    if caps.len == input.len && from <= caps.len { rest_caps.append(caps[from..]); }
    clear_composition();
    input.append(rest);
    caps.append(rest_caps);
}

// Room for a key that belongs to what is typed before it (' or a tone or
// shape code): made only if the first word leaves that behind.
fn room_after() -> bool {
    if room() { return true; }
    fresh_menu();
    if lead_to > 0 && lead_to < input.len { make_room(); }
    return room();
}

fn with_commit(result: u32) -> u32 { result | (if commit.len > 0 { HAS_COMMIT } else { 0 }) }

// Is the input's last stretch a shape code: ` and the letters after it?
fn in_shape_code() -> bool {
    var i = input.len - 1;
    while i >= 0 && input[i] >= 'a' && input[i] <= 'z' { i--; }
    return i >= 0 && input[i] == '`';
}

fn is_tone_key(c: u32) -> bool { c == '7' || c == '8' || c == '9' || c == '0' }

fn clear_composition() {
    input.clear();
    caps.clear();
    consumed.clear();
    confirmed.clear();
    picks.clear();
    picked_pairs.clear();
    picked_ends.clear();
    decoder::clear(menu);
    words.list.clear();
    words.checks.clear();
    decoder::clear_shortlist(shortlist);
    rerank_due = 0;
    shown.clear();
    readable = 0;
    page = 0;
    highlight = 0;
    expanded = false;
    grid_row = 0;
    lead_to = 0;
    lead_text.clear();
    rerank::cache_clear();
}

// Rebuilds the menu for the letters still to convert.
fn rebuild() {
    builds++;
    page = 0;
    highlight = 0;
    grid_row = 0;
    decoder::clear(menu);
    readable = 0;
    letters_unread = false;
    chinese_full = false;
    shown.clear();
    lead_to = 0;
    lead_text.clear();
    if input.len == 0 {
        expanded = false;
        rerank::cache_clear();
        return;
    }
    let day = userdb::today();
    if day != refreshed_day {
        userdb::refresh();
        refreshed_day = day;
    }
    var g = lattice::Graph {};
    lattice::build(g, input, spelling::live, lexicon::live);
    words.list.clear();
    words.checks.clear();
    decoder::search(words, g, lexicon::live, input);
    let reach = decoder::chinese_reach(words, input);
    readable = decoder::assemble(menu, words, lexicon::live, input);
    for i in reach..input.len {
        if input[i] >= 'a' && input[i] <= 'z' { letters_unread = true; }
    }
    chinese_bits = 0.0;
    for i in menu.path { chinese_bits += words.list[i].score as f64; }
    if menu.path.len > 0 {
        let first = words.list[menu.path[0]];
        lead_to = first.to;
        decoder::word_text(first, lead_text);
    }
    show_input(words, g);
    place_english();
    request_rerank();
    menu_changes = data_version();
}

// ---- the reranker (engine/rerank.goose) -----------------------------------------

// Whether the menu's first candidate is a sentence the reranker may replace:
// the decoder's own, of more than one word, reading the whole input in
// Chinese, and not one the user chose for these keys before (their choice
// stands). English placed first, a custom phrase or a whole-input word
// leaves the menu as it is.
fn rerankable() -> bool {
    guard menu.candidates.len > 0 && readable == input.len && !letters_unread else { return false; }
    let c = menu.candidates[0];
    guard c.count > 1 && c.code_len == 0 && (c.to as i64) == input.len else { return false; }
    let text = menu.pool[c.text..c.text + c.len];
    for b in text { if b < 0x80 { return false; } }
    var span: u8[>..] = [];
    decoder::typed_span(input, decoder::skip_separators(input, 0), input.len, span);
    return userdb::chosen(span, text) == 0;
}

// After a menu is built: whether the reranker may change its first
// candidate. If so, the key says PENDING and the host calls refine before it
// shows the candidates, after the key has returned (so the app typed in
// never waits for it) and its preedit is on screen: the menu is shown once,
// already reranked. With rerank_sync (the tests and the accuracy harness)
// it is reranked here.
fn request_rerank() {
    decoder::clear_shortlist(shortlist);
    rerank_due = 0;
    guard rerank::active() && rerankable() else { return; }
    if rerank_sync { rerank_now(); } else { rerank_due = builds; }
}

// Reranks the menu being shown: the shortlist from its words, scored, and
// the best put first. The decoder's sentence stays, second. True if the
// menu changed.
fn rerank_now() -> bool {
    rerank_due = 0;
    let m = rerank::live.meta[0];
    let n = decoder::shortlist(words, input, readable, m.beam as i64, m.per_state as i64, m.shortlist as i64,
                               shortlist);
    var job = rerank::Job { ids: [], starts: [] };
    rerank::clear_job(job);
    for k in n {
        if !rerank::add(job, decoder::shortlist_text(shortlist, k)) { break; }
    }
    let scored = rerank::count(job);
    guard scored >= 2 && shortlist.scores.len >= scored else { return false; }
    let k = rerank::choose(job, shortlist.scores[..scored]);
    guard k >= 0 && menu.candidates.len > 0 else { return false; }
    let text = decoder::shortlist_text(shortlist, k);
    let first = menu.candidates[0];
    guard compare(menu.pool[first.text..first.text + first.len], text) != 0 else { return false; }
    var i = menu.candidates.len - 1;
    while i > 0 {                               // the same text further down goes: it moves up
        let c = menu.candidates[i];
        if compare(menu.pool[c.text..c.text + c.len], text) == 0 { remove_at(menu.candidates, i); }
        i--;
    }
    let at = menu.pool.len;
    menu.pool.append(text);
    let refs = menu.refs.len;
    for r in shortlist.ref_at[k]..shortlist.ref_at[k + 1] { menu.refs.push(shortlist.refs[r]); }
    insert_at(menu.candidates, 0, decoder::Candidate {
        to: input.len as u8, text: at as u32, len: text.len as u16, refs: refs as u32,
        count: (shortlist.ref_at[k + 1] - shortlist.ref_at[k]) as u16, code: 0, code_len: 0 });
    while menu.candidates.len > decoder::MAX_CANDIDATES { remove_at(menu.candidates, menu.candidates.len - 1); }
    return true;
}

// Whether the menu being shown is still to be reranked.
fn reranking() -> bool { rerank_due != 0 && rerank_due == builds }

// The host's call after a key whose result said PENDING, before it shows the
// candidates: reranks the menu (DIRTY if it changed: take a new snapshot).
// Nothing once done, or once the user has moved through the menu.
fn refine(handle: u64) -> u32 {
    guard ready && index(handle) >= 0 && active == handle && reranking() else { return 0; }
    if highlight != 0 || page != 0 {
        rerank_due = 0;
        return 0;
    }
    return if rerank_now() { DIRTY } else { 0 };
}

fn set_rerank(v: bool) {
    rerank::set_on(v);
    if input.len > 0 { rebuild(); }
}

// -1 if the images have no reranker, else 1 while it is on and 0 while off.
fn rerank_state() -> i32 {
    if !rerank::mapped { return -1; }
    return if rerank::on { 1 } else { 0 };
}

// Moves whenever the data the menu's words point into changes.
fn data_version() -> u64 { userdb::changes + sets::generation }

// The menu's words refer to the user dictionary by position: if it changed
// since the menu was built (a forget, an unlearn), build the menu again
// before any of its words is used.
fn fresh_menu() {
    if input.len > 0 && menu_changes != data_version() { rebuild(); }
}

// Copies candidate c's words into the picks. False if they do not fit.
fn take_words(c: decoder::Candidate) -> bool {
    guard picked_ends.len + c.count <= picked_ends.cap else { return false; }
    for r in c.refs..c.refs + c.count {
        var pairs: lexicon::Pair[>..] = [];
        if word_pairs(menu.refs[r], pairs) && picked_pairs.len + pairs.len <= picked_pairs.cap {
            picked_pairs.append(pairs);
            picked_ends.push(picked_pairs.len as i16);
        } else {
            picked_ends.push(-1);
        }
    }
    return true;
}

// The input as the preedit shows it: the keys typed, split into the best
// reading's syllables, in every scheme: "zhong guo", "z g r" in full
// pinyin, "wo ui vs go rf" in 小鹤双拼 (the keys pressed, which is what the
// user reads back, not each syllable's pinyin spelled out). A tone or a
// shape code stays with its syllable; what the best reading does not cover
// stays as typed.
fn show_input(w: decoder::Words&, g: lattice::Graph&) {
    shown.clear();
    var segs: decoder::Segment[>..] = [];
    decoder::segments(menu, w, g, input, segs);
    var full = segs.len > 0;
    var at: i64 = 0;
    for seg in segs {
        let from: i64 = seg.from;
        let to: i64 = seg.to;
        if from < at { continue; }
        for p in at..from { if input[p] != '\'' { full = false; } }        // a key no syllable read
        if g.edges[seg.edge].kind > spelling::FUZZY { full = false; }       // an abbreviation or half a syllable
        // Keys between two syllables that no syllable reads: an English word
        // of the best sentence. They show as typed, one group of their own
        // (ni ys github zo ua), and are not dropped.
        var g0 = at;
        while g0 < from && input[g0] == '\'' { g0++; }
        if g0 < from {
            var g1 = from;
            while g1 > g0 && input[g1 - 1] == '\'' { g1--; }
            if shown.len > 0 { shown.push(if find(input[at..g0], "'") >= 0 { '\'' } else { ' ' }); }
            typed_part(g0, g1);
            at = g1;
        }
        if shown.len > 0 {          // between syllables: the ' typed there, or a space
            shown.push(if find(input[at..from], "'") >= 0 { '\'' } else { ' ' });
        }
        typed_part(from, to);
        at = to;
    }
    for p in at..input.len { if input[p] != '\'' { full = false; } }
    chinese_full = full;
    if at < input.len {
        if at > 0 && shown.len > 0 && shown[shown.len - 1] != ' ' && input[at] != '\'' { shown.push(' '); }
        typed_part(at, input.len);
    }
}

// The pair at depth k of entry i's word (the accuracy harness's --export-segments).
fn pair_at(lex: lexicon::Lexicon&, i: i64, k: i64) -> lexicon::Pair {
    lex.pairs[lex.runs[lex.entries[i].run + k]]
}

// input[from..to] as typed, capitals too; a ' only where it separates letters.
fn typed_part(from: i64, to: i64) {
    for p in from..to {
        if input[p] == '\'' && (shown.len == 0 || shown[shown.len - 1] == ' ') { continue; }
        shown.push(as_typed(p));
    }
}

// Input byte p as it was typed: input keeps letters lowercase, for the
// Chinese reading, and caps notes which were capitals.
fn as_typed(p: i64) -> u8 {
    let c = input[p];
    return if caps.len == input.len && caps[p] != 0 && c >= 'a' && c <= 'z' { c - 32 } else { c };
}

// Mounts the sets that are on unless the user turns them off.
fn mount_defaults() {
    var pos: i64 = 0;
    while pos < sets::available.len {
        let line = lexicon::next_line(sets::available, pos);
        let id, rest, ok1 = split_once(line, '\t');
        let name, state, ok2 = split_once(rest, '\t');
        if ok1 && ok2 && state == "on" { sets::mount(data_dir, id); }
    }
}

// Turns set `id` on or off: 0, or 1 if that cannot be done (no such set, its
// image does not verify, or no slot is free). The candidates change at once;
// a menu built before is rebuilt before any of its words is used.
fn use_set(id: const u8[:], on: bool) -> i32 {
    guard ready else { return 1; }
    return if on { sets::mount(data_dir, id) } else { sets::unmount(id) };
}

var sets_text: u8[>..];

// The grammar model, on or off at once (a mapping, no copying): -1 when the
// images have none, 0 off, 1 on.
fn grammar_state() -> i32 {
    if grammar::on { return 1; }
    return if ready && grammar::available(data_dir) { 0 } else { -1 };
}

// Where the grammar model's .gram file is when it is not beside grammar.img
// (the IME keeps it outside its signed bundle). Before open().
fn set_grammar_folder(directory: const u8[:]) {
    grammar::elsewhere.clear();
    grammar::elsewhere.append(directory);
}

// Turns the model on or off and remembers it for the next open: 0, or 1 if
// it cannot be turned on. A composition in progress is read again.
fn set_grammar(on: bool) -> i32 {
    guard ready else { return 1; }
    use_grammar = on;
    var result: i32 = 0;
    if on { result = if grammar::open(data_dir) == 0 { 0 } else { 1 }; } else { grammar::close(); }
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }
    return result;
}

// ---- custom phrases (engine/phrases.goose), compiled in the background ----

let PHRASES_IDLE = 0;
let PHRASES_COMPILING = 1;
let PHRASES_READY = 2;
let PHRASES_FAILED = 3;

// octo_pump's result bits
let PUMP_CHANGED = 1;           // a job finished, or its result was applied
let PUMP_PENDING = 2;           // a job is running, or a result waits for the composition to end

struct Supervisor { job: u64, thread: i64 }

var jobs: u64 = 0;                      // the last job id handed out
var supervisors: Supervisor[>..];       // started, not yet reaped
var phrases_state: i64 = PHRASES_IDLE;
var phrases_done = phrases::Done { id: 0, ok: false, words: 0, shortcuts: 0, skipped: 0, first_bad: 0, why: [] };
var phrases_dir: u8[>..];               // where the compiled images go, and are mounted from
var staged = false;                     // a compiled result waits for the composition to end
var phrases_test_abort = false;         // tests: the next job's worker aborts
var phrases_text: u8[>..];

// Starts compiling the custom phrase file `source` into images in `out`; the
// result arrives through pump(). A newer job supersedes any still running.
// Returns its id, or 0 if it cannot start.
fn compile_phrases(source: const u8[:], out: const u8[:]) -> u64 {
    guard ready && source.len > 0 && source.len < 1024 && out.len > 0 && out.len < 1024 && data_dir.len < 1024 else {
        return 0;
    }
    jobs++;
    var job = phrases::Job { id: jobs, source: source, images: data_dir[..], out: out, scheme: scheme[..],
                             abort: phrases_test_abort };
    phrases_test_abort = false;
    phrases_dir.clear();
    phrases_dir.append(out);
    supervisors.push(Supervisor { job: jobs, thread: thread_spawn(phrases::supervise, job) });
    phrases_state = PHRASES_COMPILING;
    return jobs;
}

// On the main thread, often while a job is pending: takes finished jobs,
// drops any but the latest, and applies its result once no composition is in
// progress. Returns PUMP_* bits.
fn pump() -> u32 {
    var bits: u32 = 0;
    loop {
        let d, has = qpoll<phrases::Done>();
        if !has { break; }
        for i in supervisors.len {                  // its supervisor ends right after: reap it
            if supervisors[i].job == d.id {
                thread_wait(supervisors[i].thread);
                remove_at(supervisors, i);
                break;
            }
        }
        var id: u8[>..] = [];
        format(id, d.id);
        let words = str(phrases_dir, "/lexicon.custom.", id, ".img");
        let shortcuts = str(phrases_dir, "/shortcuts.custom.", id, ".img");
        if d.id != jobs || !d.ok {                  // superseded by a newer job, or failed: its files go
            delete_file(words);
            delete_file(shortcuts);
            if d.id != jobs { continue; }
        }
        phrases_done = d;
        phrases_state = if d.ok { PHRASES_READY } else { PHRASES_FAILED };
        if d.ok {                                   // the latest result, in place for mounting
            let canonical = str(phrases_dir, "/lexicon.custom.img");
            if d.words > 0 { rename_file(words, canonical); } else { delete_file(canonical); }
            rename_file(shortcuts, str(phrases_dir, "/shortcuts.custom.img"));
            staged = true;
        }
        bits = bits | PUMP_CHANGED;
    }
    if staged && !composing() {
        mount_phrases(phrases_dir);
        staged = false;
        bits = bits | PUMP_CHANGED;
    }
    // A superseded job can still be running after the newest one finished.
    // Its supervisor must be reaped before the runtime can stop safely.
    if staged || phrases_state == PHRASES_COMPILING || supervisors.len > 0 { bits = bits | PUMP_PENDING; }
    return bits;
}

// Mounts compiled phrase images from `directory`: the words as the "custom"
// set, the shortcuts as the live shortcut table. Missing images leave none.
// 0, or 1 if an image is there but does not verify.
fn mount_phrases(directory: const u8[:]) -> i32 {
    guard ready else { return 1; }
    var bad = false;
    sets::unmount("custom");
    if file_exists(str(directory, "/lexicon.custom.img")) && sets::mount(directory, "custom") != 0 { bad = true; }
    var img: u8[>..] = [];
    phrases::clear(phrases::live);
    if read_file(str(directory, "/shortcuts.custom.img"), img) && !phrases::load_into(phrases::live, img) { bad = true; }
    sets::generation++;                             // the menu's shortcuts and words changed
    return if bad { 1 } else { 0 };
}

// The phrases' state for the host: "state \t words \t shortcuts \t skipped
// \t first bad line \t why", state one of idle, compiling, ready, failed.
fn phrases_status() -> const u8[:] {
    phrases_text.clear();
    let d = phrases_done;
    let state = if phrases_state == PHRASES_COMPILING { "compiling" } else if phrases_state == PHRASES_READY { "ready" }
                else if phrases_state == PHRASES_FAILED { "failed" } else { "idle" };
    format(phrases_text, state, "\t", d.words, "\t", d.shortcuts, "\t", d.skipped, "\t", d.first_bad, "\t", d.why[..]);
    return phrases_text;
}
var aux_text: u8[>..];

// The shape-code schemes in the data directory whose images verify, as
// "id \t name" lines.
fn aux_list() -> const u8[:] {
    aux_text.clear();
    var names: u8[>..] = [];
    guard list_dir(data_dir, names) else { return aux_text; }
    var pos: i64 = 0;
    while pos < names.len {
        let file = lexicon::next_line(names, pos);
        if file.len <= 8 || compare(file[..4], "aux.") != 0 || compare(file[file.len - 4..], ".img") != 0 { continue; }
        var img: u8[>..] = [];
        if !read_file(str(data_dir, "/", file), img) { continue; }
        let s, opened = image::open(img, image::KIND_AUX, auxcode::LAYOUT);
        if !opened || s.count != auxcode::SECTIONS { continue; }
        let meta, ok = from_bytes<auxcode::Meta[>..]>(image::section(img, s, 3));
        if !ok || meta.len != 1 || compare(file[4..file.len - 4], meta[0].scheme) != 0 { continue; }
        format(aux_text, meta[0].scheme, "\t", meta[0].name, "\n");
    }
    return aux_text;
}

// Switches the shape-code scheme: 0, or 1 if there is no such scheme or its
// image does not verify (the current one stays).
fn set_aux_scheme(id: const u8[:]) -> i32 {
    guard ready && spelling::is_id(id) else { return 1; }
    if id == "none" {
        auxcode::clear(auxcode::live);
        aux_scheme.clear();
        aux_scheme.append("none");
        decoder::forget_fits();
        if input.len > 0 { rebuild(); }
        return 0;
    }
    var img: u8[>..] = [];
    var probe = auxcode::Table {};
    guard read_file(str(data_dir, "/aux.", id, ".img"), img) && auxcode::load_into(probe, img) else { return 1; }
    auxcode::load(img);                             // verified just now
    aux_scheme.clear();
    aux_scheme.append(id);
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }                 // a code typed already now means this scheme's
    return 0;
}

fn sets_list() -> const u8[:] {
    sets_text.clear();
    sets::describe(sets_text);
    return sets_text;
}

// The schemes in the data directory whose images verify, as
// "id \t name \t preedit" lines (preedit: typed or syllables).
fn list_schemes() {
    scheme_list.clear();
    var names: u8[>..] = [];
    guard list_dir(data_dir, names) else { return; }
    var pos: i64 = 0;
    while pos < names.len {
        let file = lexicon::next_line(names, pos);
        if file.len <= 14 || compare(file[..10], "spellings.") != 0 || compare(file[file.len - 4..], ".img") != 0 {
            continue;
        }
        var img: u8[>..] = [];
        var t = spelling::Table {};
        if !read_file(str(data_dir, "/", file), img) || !spelling::load_into(t, img, lexicon::live_digest,
                                                                            lexicon::live.toned.len) {
            continue;
        }
        let meta = t.meta[0];
        if compare(file[10..file.len - 4], meta.id) != 0 { continue; }
        format(scheme_list, meta.id, "\t", meta.name, "\t",
               if meta.preedit == spelling::PREEDIT_SYLLABLES { "syllables" } else { "typed" }, "\n");
    }
}

// Switches the input scheme: 0, or 1 if there is no such scheme or its
// image does not verify, which leaves the current one in place.
fn set_scheme(id: const u8[:]) -> i32 {
    guard ready && spelling::is_id(id) else { return 1; }
    var img: u8[>..] = [];
    var t = spelling::Table {};
    guard read_file(str(data_dir, "/spellings.", id, ".img"), img) &&
          spelling::load_into(t, img, lexicon::live_digest, lexicon::live.toned.len) &&
          compare(t.meta[0].id, id) == 0 else { return 1; }
    spelling::load(img, lexicon::live_digest, lexicon::live.toned.len);     // verified just now
    apply_fuzzy();
    scheme.clear();
    scheme.append(id);
    userdb::scope.clear();
    userdb::scope.append(id);
    clear_composition();
    recent.clear();
    return 0;
}

fn append_commit(text: const u8[:]) {
    if commit.len + text.len <= commit.cap { commit.append(text); }
}

// Commits the selections and the letters still to convert, as typed.
fn commit_raw() {
    let from = commit.len;
    append_commit(confirmed);
    for p in input.len { if input[p] != '\'' && commit.len < commit.cap { commit.push(as_typed(p)); } }
    remember("", commit[from..], 0);
    clear_composition();
}

fn commit_passing() -> u32 {
    fresh_menu();
    var i: i64 = -1;
    if highlight >= 0 && highlight < menu.candidates.len && menu.candidates[highlight].to == input.len {
        i = highlight;
    } else {
        for k in menu.candidates.len {
            if menu.candidates[k].to == input.len { i = k; break; }
        }
    }
    if i < 0 {
        commit_raw();
        return DIRTY | HAS_COMMIT;
    }
    let done = select(i);
    if (done & HAS_COMMIT) != 0 { return done & (DIRTY | HAS_COMMIT); }
    commit_raw();
    return DIRTY | HAS_COMMIT;
}

fn set_pick_text(handle: u64, text: const u8[:]) {
    pick_text.clear();
    pick_for = 0;
    guard index(handle) >= 0 && text.len > 0 && text.len <= pick_text.cap else { return; }
    pick_text.append(text);
    pick_for = handle;
}

// Makes room for `text_len` more bytes of chosen text. Picks already made are
// committed on their own when the buffer cannot also hold this selection, so
// a long phrase is not replaced by the keys that chose it.
fn room_for_text(text_len: i64) -> bool {
    if confirmed.len + text_len <= confirmed.cap { return true; }
    if picks.len == 0 { return false; }
    learn_composition();
    append_commit(confirmed);
    confirmed.clear();
    consumed.clear();
    picks.clear();
    picked_pairs.clear();
    picked_ends.clear();
    return text_len <= confirmed.cap;
}

fn select(i: i64) -> u32 {
    fresh_menu();
    var replacement: u8[..phrases::MAX_TEXT] = [];
    var replace = pick_text.len > 0 && pick_for == active;
    if replace { replacement.append(pick_text[..]); }
    pick_text.clear();
    pick_for = 0;
    if menu.candidates.len == 0 {                  // nothing to choose from: the letters
        commit_raw();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    guard i >= 0 && i < menu.candidates.len else { return HANDLED; }
    let c = menu.candidates[i];
    let to: i64 = c.to;
    var text_len: i64 = c.len;
    if replace {
        if replacement.len > 0 && confirmed.len + replacement.len <= confirmed.cap { text_len = replacement.len; }
        else { replace = false; }
    }
    guard to > 0 && to <= input.len && picks.len < picks.cap &&
          consumed.len + to <= consumed.cap && picked_ends.len + c.count <= picked_ends.cap else {
        commit_raw();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    if !room_for_text(text_len) {
        commit_raw();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    if replace { confirmed.append(replacement[..]); }
    else { confirmed.append(menu.pool[c.text..c.text + c.len]); }
    consumed.append(input[..to]);
    let before = picked_pairs.len;
    take_words(c);
    picks.push(Pick { letters: to as u8, bytes: text_len as u16, words: c.count as u8,
                      pairs: (picked_pairs.len - before) as u8, english: if c.code_len > 0 { 1 } else { 0 },
                      foreign: if replace { 1 } else { 0 } });
    var rest: u8[..lattice::MAX_INPUT] = [];
    var rest_caps: u8[..lattice::MAX_INPUT] = [];
    var from = to;
    while from < input.len && input[from] == '\'' { from++; }
    rest.append(input[from..]);
    if caps.len == input.len && from <= caps.len { rest_caps.append(caps[from..]); }
    input.clear();
    caps.clear();
    input.append(rest);
    caps.append(rest_caps);
    if input.len == 0 {
        learn_composition();
        append_commit(confirmed);
        clear_composition();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    rebuild();
    return with_commit(HANDLED | DIRTY);
}

// The pairs of a word a candidate was made of; false for a lexicon word
// with marks (李·卡斯利), which the user dictionary does not keep.
fn word_pairs(r: decoder::Ref, out: lexicon::Pair[>..]&) -> bool {
    if r.source == decoder::ENGLISH { return false; }
    return pairs_of(decoder::source_lexicon(r.source), r.entry, out);
}

fn pairs_of(lex: lexicon::Lexicon&, i: i64, out: lexicon::Pair[>..]&) -> bool {
    guard i < lex.entries.len else { return false; }       // fresh_menu keeps this from happening
    if lex.marks.len > 0 {
        let m = lexicon::first_mark(lex, i);
        if m < lex.marks.len && lex.marks[m].entry == i { return false; }
    }
    let e = lex.entries[i];
    for k in e.len { out.push(lex.pairs[lex.runs[e.run + k]]); }
    return true;
}

// Learns from a composition that is being committed as converted text:
// each word it was made of, and, when it took two words or more, the whole
// as one phrase (2 to userdb::MAX_PHRASE syllables). Never from letters
// committed as typed, and never when the host's privacy policy says not to.
//
// What it learns, per pick (a candidate chosen for some letters):
//   - the choice of its text for exactly those letters, so the same input
//     offers it first next time;
//   - each of its words, counted twice if the user picked that word itself,
//     once if it came along in a sentence the engine proposed. A pick from
//     a single letter ("g") teaches only the choice: picking from pages of a
//     one-letter abbreviation says too little to promote a word everywhere.
// And for the composition: if it took two picks or more, the whole as a
// phrase (up to userdb::MAX_PHRASE syllables), and its choice for the whole
// input; a sentence accepted in one pick becomes a phrase only up to
// userdb::MAX_SENTENCE syllables, since it was the engine's own guess.
fn learn_composition() {
    var any_english = false;
    var any_foreign = false;
    for p in picks {
        if p.english != 0 { any_english = true; }
        if p.foreign != 0 { any_foreign = true; }
    }
    // A pure English pick has no word readings, so picked_ends is empty.
    guard picks.len > 0 && (picked_ends.len > 0 || any_english) else { return; }
    var full: u8[>..] = [];                    // the whole input, without separators
    for c in consumed { if c != '\'' { full.push(c); } }
    commits++;
    if commits == 0 { commits = 1; }
    let id = commits;
    var chain_prev = userdb::carry_prev;
    var chain_ant = userdb::carry_ant;
    var saw_word = false;
    if !learning_allowed {
        remember(full, confirmed, 0);
        return;
    }
    retract_mistake(full, confirmed);

    let words = picked_pairs[..];              // copied when picked
    var ends: i64[>..] = [];
    var whole = true;
    for e in picked_ends {
        ends.push(e);
        if e < 0 { whole = false; }
    }
    var letter: i64 = 0;                       // where the pick starts in consumed
    var byte: i64 = 0;                         // and in confirmed
    var w: i64 = 0;                            // and in picked_ends
    var from: i64 = 0;                         // and in words
    for p in picks {
        var span: u8[>..] = [];
        for c in consumed[letter..letter + p.letters] { if c != '\'' { span.push(c); } }
        if p.foreign != 0 {
            for k in w..w + p.words {
                if ends[k] >= 0 { from = ends[k]; }
            }
        } else {
            if p.english != 0 {
                userdb::learn_english(span, confirmed[byte..byte + p.bytes], id);
            } else {
                userdb::choose(span, confirmed[byte..byte + p.bytes], id);
            }
            let amount = if p.words == 1 { userdb::EXPLICIT } else { userdb::INCIDENTAL };
            for k in w..w + p.words {
                if ends[k] < 0 { continue; }
                let slice = words[from..ends[k]];
                if span.len >= 2 { userdb::learn(slice, amount, id); }
                if slice.len > 0 {
                    let surface = userdb::hash_surface_pairs(slice);
                    if chain_prev != 0 { userdb::observe(chain_prev, chain_ant, userdb::hash_reading_pairs(slice), slice.len); }
                    chain_ant = chain_prev;
                    chain_prev = surface;
                    saw_word = true;
                }
                from = ends[k];
            }
        }
        letter += p.letters;
        byte += p.bytes;
        w += p.words;
    }
    let limit = if picks.len >= 2 { userdb::MAX_PHRASE } else { userdb::MAX_SENTENCE };
    if !any_foreign && whole && ends.len >= 2 && words.len <= limit && full.len >= 2 {
        userdb::learn(words, userdb::INCIDENTAL, id);
        if picks.len >= 2 { userdb::choose(full, confirmed, id); }
    }
    if any_foreign { userdb::set_carry(0, 0); }
    else if saw_word { userdb::set_carry(chain_ant, chain_prev); }
    else if any_english { userdb::set_carry(0, 0); }
    remember(full, confirmed, if any_foreign && !saw_word { 0 } else { id });
}

// Forgets the highlighted candidate if the user dictionary holds it.
fn unlearn_highlighted() -> bool {
    let h = highlight;
    fresh_menu();
    highlight = if h < menu.candidates.len { h } else { 0 };
    guard highlight >= 0 && highlight < menu.candidates.len else { return false; }
    let c = menu.candidates[highlight];
    if c.code_len > 0 {
        let code = menu.pool[c.code..c.code + c.code_len];
        let text = menu.pool[c.text..c.text + c.len];
        guard userdb::unlearn_english(code, text) else { return false; }
        rebuild();
        move_highlight(h);
        return true;
    }
    var pairs: lexicon::Pair[>..] = [];
    for r in c.refs..c.refs + c.count {
        if !word_pairs(menu.refs[r], pairs) { return false; }
    }
    guard userdb::unlearn(pairs) else { return false; }
    rebuild();
    move_highlight(h);
    return true;
}

// Backspace takes back the last letter, or, with none left, the last selection.
fn backspace() {
    if input.len > 0 {
        input.pop();
        if caps.len > 0 { caps.pop(); }
        rebuild();
        return;
    }
    guard picks.len > 0 else { return; }
    let p = picks.pop();
    picked_ends.pop_n(p.words);
    picked_pairs.pop_n(p.pairs);
    let letters: i64 = p.letters;
    let bytes: i64 = p.bytes;
    input.append(consumed[consumed.len - letters..]);
    while caps.len < input.len { caps.push(0); }
    consumed.pop_n(letters);
    confirmed.pop_n(bytes);
    rebuild();
}

fn move_highlight(delta: i64) {
    let n = menu.candidates.len;
    if n == 0 { return; }
    var h = highlight + delta;
    if h < 0 { h = 0; }
    if h >= n { h = n - 1; }
    highlight = h;
    page = h / PAGE_SIZE;
    ensure_grid();
}

// Keeps the highlighted row inside the open grid, scrolling by as few rows
// as that takes.
fn ensure_grid() {
    if !expanded { return; }
    let n = menu.candidates.len;
    if n == 0 { grid_row = 0; return; }
    let row = highlight / PAGE_SIZE;
    if row < grid_row { grid_row = row; }
    if row >= grid_row + GRID_ROWS { grid_row = row + 1 - GRID_ROWS; }
    if grid_row < 0 { grid_row = 0; }
}

fn turn_page(delta: i64) -> bool {
    let n = menu.candidates.len;
    if n == 0 { return false; }
    if expanded {
        if delta < 0 && grid_row == 0 { return false; }
        if delta > 0 && (grid_row + GRID_ROWS) * PAGE_SIZE >= n { return false; }
        move_highlight(delta * GRID_ROWS * PAGE_SIZE);
        return true;
    }
    let last = (n - 1) / PAGE_SIZE;
    var p = page + delta;
    if p < 0 { p = 0; }
    if p > last { p = last; }
    if p == page { return false; }
    page = p;
    highlight = p * PAGE_SIZE;
    return true;
}

// Chinese punctuation for a key, or the key's own character when this app
// commits punctuation at half width, or "" if it has none. Half width does
// not move the fullwidth quote pairing.
fn punctuation(c: u32, halfwidth: bool) -> const u8[:] {
    if c == ',' { return if halfwidth { "," } else { "，" }; }
    if c == '.' { return if halfwidth { "." } else { "。" }; }
    if c == '?' { return if halfwidth { "?" } else { "？" }; }
    if c == '!' { return if halfwidth { "!" } else { "！" }; }
    if c == ';' { return if halfwidth { ";" } else { "；" }; }
    if c == ':' { return if halfwidth { ":" } else { "：" }; }
    if c == '\\' { return if halfwidth { "\\" } else { "、" }; }
    if c == '(' { return if halfwidth { "(" } else { "（" }; }
    if c == ')' { return if halfwidth { ")" } else { "）" }; }
    if c == '[' { return if halfwidth { "[" } else { "【" }; }
    if c == ']' { return if halfwidth { "]" } else { "】" }; }
    if c == '<' { return if halfwidth { "<" } else { "《" }; }
    if c == '>' { return if halfwidth { ">" } else { "》" }; }
    if c == '~' { return if halfwidth { "~" } else { "～" }; }
    if c == '^' { return if halfwidth { "^" } else { "……" }; }
    if c == '_' { return if halfwidth { "_" } else { "——" }; }
    if c == '$' { return if halfwidth { "$" } else { "￥" }; }
    if c == '"' {
        if halfwidth { return "\""; }
        double_open = !double_open;
        return if double_open { "“" } else { "”" };
    }
    if c == '\'' {
        if halfwidth { return "'"; }
        single_open = !single_open;
        return if single_open { "‘" } else { "’" };
    }
    return "";
}

fn latin_letter(c: u32) -> i64, bool {
    if c >= 'a' && c <= 'z' { return c, false; }
    if c >= 'A' && c <= 'Z' { return c + 32, true; }
    return 0, false;
}

// The letters still to convert, and the same letters in the case typed.
// Empty if a tone or a shape code is among them: those are Chinese.
fn typed_code(code: u8[>..]&, cased: u8[>..]&) {
    code.clear();
    cased.clear();
    let marked = caps.len == input.len;
    for i in input.len {
        let c = input[i];
        if c == '\'' { continue; }
        if c < 'a' || c > 'z' { code.clear(); cased.clear(); return; }
        code.push(c);
        cased.push(if marked && caps[i] != 0 { c - 32 } else { c });
    }
}

fn insert_english(at: i64, text: const u8[:], code: const u8[:]) -> i64 {
    guard text.len > 0 && text.len <= 65535 && code.len > 0 && code.len <= 255 else { return 0; }
    for c in menu.candidates {
        if c.len == text.len && compare(menu.pool[c.text..c.text + c.len], text) == 0 { return 0; }
    }
    if menu.candidates.len >= decoder::MAX_CANDIDATES {
        if at >= menu.candidates.len { return 0; }
        menu.candidates.pop();
    }
    guard menu.candidates.len < decoder::MAX_CANDIDATES else { return 0; }
    var where = at;
    if where < 0 { where = 0; }
    if where > menu.candidates.len { where = menu.candidates.len; }
    let code_at = menu.pool.len;
    menu.pool.append(code);
    let text_at = menu.pool.len;
    menu.pool.append(text);
    var added = decoder::Candidate { to: input.len as u8, text: text_at as u32, len: text.len as u16,
                                     refs: menu.refs.len as u32, count: 0, code: code_at as u32,
                                     code_len: code.len as u8 };
    var next: decoder::Candidate[>..] = [];
    next.append(menu.candidates[..where]);
    next.push(added);
    next.append(menu.candidates[where..]);
    menu.candidates.clear();
    menu.candidates.append(next);
    return 1;
}

// Places English candidates into the menu the decoder just built.
// Rules, in order (docs/english-design.md): no complete Chinese reading;
// a capital; a word the user picked for this code, by its uses; otherwise
// the first candidate stays Chinese and a common exact match goes second;
// completions of 4 letters or more, at most two, after the third candidate.
// When the keys read as full Chinese syllables throughout (chinese_full),
// English waits behind the Chinese instead: an exact match takes the last
// place on the first page, and completions go after the first page, so
// typing he, long or chang keeps the first page's other places Chinese.
fn place_english() {
    weak_chinese = false;
    if !english::active() || input.len == 0 { return; }
    var code: u8[>..] = [];
    var cased: u8[>..] = [];
    typed_code(code, cased);
    if code.len == 0 || code.len > english::MAX_CODE { return; }
    let exact = english::exact(code);
    var learned: u8[>..] = [];
    let learned_uses = userdb::english_top(code, learned);
    var primary: u8[>..] = [];
    if learned_uses > 0 { primary.append(learned); }
    else if exact >= 0 { english::prefer(exact, cased, primary); }
    let capital = english::has_capital(cased);
    var barrier: i64 = 0;
    if menu.candidates.len > 0 {
        let c0 = menu.candidates[0];
        barrier = userdb::chosen(code, menu.pool[c0.text..c0.text + c0.len]);
    }
    // The Chinese is nonsense next to the English word: English is meant,
    // unless the user picked that Chinese for these letters before.
    weak_chinese = exact >= 0 && barrier == 0 && english::bits(exact) - chinese_bits >= english::WEAK_CHINESE_BITS;
    var at: i64 = -1;
    if primary.len > 0 {
        if letters_unread || capital || learned_uses > barrier || weak_chinese { at = 0; }
        else if chinese_full { at = page_place(PAGE_SIZE - 1); }
        else if exact >= 0 && english::common(exact) { at = if menu.candidates.len > 0 { 1 } else { 0 }; }
        else { at = if menu.candidates.len > 3 { 3 } else { menu.candidates.len }; }
    }
    var inserted: i64 = 0;
    if at >= 0 {
        inserted += insert_english(at, primary, code);
        if exact >= 0 {
            for k in english::form_count(exact) {
                var form: u8[>..] = [];
                english::copy_form(exact, k, form);
                if compare(form, primary) == 0 { continue; }
                inserted += insert_english(at + inserted, form, code);
            }
        }
    }
    if code.len < 4 { return; }
    var ids: i64[>..] = [];
    english::completions(code, 2, ids);
    var cat = menu.candidates.len;
    if letters_unread || weak_chinese || (capital && inserted == 0) {
        cat = if at >= 0 { at + inserted } else { 0 };
    } else {
        let after = if chinese_full { page_place(PAGE_SIZE) } else { page_place(3) };
        let group = if at >= 0 { at + inserted } else { 0 };
        cat = if after > group { after } else { group };
    }
    for id in ids {
        var text: u8[>..] = [];
        english::top_form(id, text);
        if primary.len > 0 && compare(text, primary) == 0 { continue; }
        cat += insert_english(cat, text, code);
    }
}

// Position `p` in the menu, or its end if it is shorter.
fn page_place(p: i64) -> i64 { if menu.candidates.len < p { menu.candidates.len } else { p } }

fn set_english(v: bool) {
    english::set_on(v);
    if input.len > 0 { rebuild(); }
}

// Fuzzy pinyin (docs/fuzzy-pinyin.md): the groups the user has on, by id,
// space-separated ("z_zh c_ch"); none by default. By id rather than bit, so
// a choice holds across schemes and builds.
var fuzzy_ids: u8[>..];
var fuzzy_text: u8[>..];

fn set_fuzzy(ids: const u8[:]) {
    fuzzy_ids.clear();
    if ids.len <= 256 { fuzzy_ids.append(ids); }
    apply_fuzzy();
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }
}

// The live table's bits for the groups the user has on.
fn apply_fuzzy() {
    var mask: u32 = 0;
    for i in spelling::live.groups.len {
        for raw in split(fuzzy_ids[..], ' ') {
            let id: const u8[:] = raw;
            if compare(id, spelling::live.groups[i].id) == 0 { mask = mask | ((1 << i) as u32); }
        }
    }
    spelling::fuzzy_on = mask;
}

// The live scheme's fuzzy groups, one per line: "id \t 1" if on, "id \t 0"
// if off. Lent until the next call.
fn fuzzy_groups() -> const u8[:] {
    fuzzy_text.clear();
    for i in spelling::live.groups.len {
        let on = (spelling::fuzzy_on & ((1 << i) as u32)) != 0;
        format(fuzzy_text, spelling::live.groups[i].id, "\t", if on { 1 } else { 0 }, "\n");
    }
    return fuzzy_text[..];
}

// The full character set (every character, not only 万象's daily ones), as
// a setting: the default Control-g switches from while composing.
fn set_full_charset(v: bool) {
    decoder::full_charset = v;
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }
}

// A key: what it did (HANDLED, DIRTY, HAS_COMMIT), and PENDING if the
// reranker may change the menu it left (the host calls refine first).
fn key(handle: u64, ev: KeyEvent) -> u32 {
    // The host copied the bytes lent by an earlier save before its next
    // engine call. Do not keep a second copy for the rest of the session.
    user_saved.clear();
    let result = handle_key(handle, ev);
    pick_text.clear();
    pick_for = 0;
    return if reranking() && (result & HANDLED) != 0 { result | PENDING } else { result };
}

fn handle_key(handle: u64, ev: KeyEvent) -> u32 {
    commit.clear();
    learning_allowed = (ev.flags & KEYFLAG_NO_LEARN) == 0;
    let halfwidth_punct = (ev.flags & KEYFLAG_HALFWIDTH_PUNCT) != 0;
    guard ready && index(handle) >= 0 else { return 0; }
    if active != handle {
        clear_client_context();
        active = handle;
    }
    if (ev.flags & KEYFLAG_PICK) != 0 {
        if !composing() { return 0; }
        return select(ev.codepoint);
    }
    let c = ev.codepoint;
    // Shift- or Control-Backspace while composing: forget the highlighted
    // candidate, if the user dictionary holds it.
    if composing() && ev.key == KEY_BACKSPACE && (ev.modifiers & (MOD_SHIFT | MOD_CONTROL)) != 0 &&
       (ev.modifiers & (MOD_COMMAND | MOD_OPTION)) == 0 {
        unlearn_highlighted();
        return HANDLED | DIRTY;
    }
    // Control-g while composing: the full character set, or back to the daily one.
    let chord = ev.modifiers & (MOD_COMMAND | MOD_CONTROL | MOD_OPTION);
    if composing() && chord == MOD_CONTROL && ev.key == KEY_OTHER && (c == 'g' || c == 7) {
        decoder::full_charset = !decoder::full_charset;
        rebuild();
        return HANDLED | DIRTY;
    }
    if composing() && (ev.modifiers & MOD_COMMAND) != 0 { return commit_passing(); }
    if chord != 0 {
        if !composing() { recent.clear(); }
        return 0;
    }

    let lower, capital = latin_letter(c);
    let shifted = capital || (ev.modifiers & MOD_SHIFT) != 0;
    // A capital is English when English words are on (Github). Otherwise it
    // goes to the app, as any other key that is not part of the composition.
    let letter = ev.key == KEY_OTHER && lower != 0 && !shifted;
    let capital_letter = ev.key == KEY_OTHER && lower != 0 && shifted && english::on;
    if letter || capital_letter {
        if !room() { make_room(); }
        guard room() else { return with_commit(HANDLED | DIRTY); }
        input.push(lower as u8);
        caps.push(if capital_letter { 1 } else { 0 });
        last_was_digit = false;
        rebuild();
        return with_commit(HANDLED | DIRTY);
    }

    if !composing() {
        if ev.key == KEY_BACKSPACE {
            note_backspace();               // deleting what was just committed?
            return 0;
        }
        if ev.key == KEY_OTHER && c >= '0' && c <= '9' {
            last_was_digit = true;
            recent.clear();
            return 0;
        }
        let after_digit = last_was_digit && (c == '.' || c == ',' || c == ':');
        last_was_digit = false;
        if ev.key != KEY_OTHER || after_digit {
            // Escape leaves the app text and its learning context intact.
            if ev.key != KEY_ESCAPE { recent.clear(); }
            return 0;
        }
        let mark = punctuation(c, halfwidth_punct);
        if mark.len == 0 {
            recent.clear();
            return 0;
        }
        append_commit(mark);
        remember("", mark, 0);
        return HANDLED | DIRTY | HAS_COMMIT;
    }

    if ev.key == KEY_OTHER && c == '\'' {
        if input.len > 0 && input[input.len - 1] != '\'' && room_after() {
            input.push('\'');
            caps.push(0);
            rebuild();
        }
        return with_commit(HANDLED | DIRTY);
    }
    // A tone for the syllable just typed: 7 8 9 0 are first to fourth (0 also neutral).
    if ev.key == KEY_OTHER && is_tone_key(c) {
        if input.len > 0 && input[input.len - 1] >= 'a' && input[input.len - 1] <= 'z' && !in_shape_code() &&
           room_after() {
            input.push(c as u8);
            caps.push(0);
            rebuild();
            if readable < input.len {               // no such tone for that syllable ("zh7")
                input.pop();
                if caps.len > 0 { caps.pop(); }
                rebuild();
            }
        }
        return with_commit(HANDLED | DIRTY);
    }
    // A shape code for the syllable just typed follows `.
    if ev.key == KEY_OTHER && c == '`' {
        let last: u8 = if input.len > 0 { input[input.len - 1] } else { 0 };
        let after_syllable = (last >= 'a' && last <= 'z') || is_tone_key(last);
        if auxcode::loaded() && after_syllable && !in_shape_code() && room_after() {
            input.push('`');
            caps.push(0);
            rebuild();
        }
        return with_commit(HANDLED | DIRTY);
    }
    if ev.key == KEY_BACKSPACE { backspace(); return HANDLED | DIRTY; }
    if ev.key == KEY_ESCAPE { clear_composition(); return HANDLED | DIRTY; }
    if ev.key == KEY_RETURN { commit_raw(); return HANDLED | DIRTY | HAS_COMMIT; }
    if ev.key == KEY_SPACE { return select(highlight); }
    if ev.key == KEY_OTHER && c >= '1' && c < '1' + PAGE_SIZE { return select(page * PAGE_SIZE + (c - '1')); }
    if ev.key == KEY_PAGE_DOWN || (ev.key == KEY_OTHER && c == '=') { return HANDLED | (if turn_page(1) { DIRTY } else { 0 }); }
    if ev.key == KEY_PAGE_UP || (ev.key == KEY_OTHER && c == '-') { return HANDLED | (if turn_page(-1) { DIRTY } else { 0 }); }
    if ev.key == KEY_DOWN {
        if menu.candidates.len == 0 { return HANDLED; }
        if !expanded {
            expanded = true;
            ensure_grid();
            return HANDLED | DIRTY;
        }
        move_highlight(PAGE_SIZE);
        return HANDLED | DIRTY;
    }
    if ev.key == KEY_UP {
        if menu.candidates.len == 0 { return HANDLED; }
        if expanded {
            if highlight < PAGE_SIZE {
                expanded = false;
                grid_row = 0;
                return HANDLED | DIRTY;
            }
            move_highlight(-PAGE_SIZE);
            return HANDLED | DIRTY;
        }
        move_highlight(-1);
        return HANDLED | DIRTY;
    }
    if ev.key == KEY_RIGHT { move_highlight(1); return HANDLED | DIRTY; }
    if ev.key == KEY_LEFT { move_highlight(-1); return HANDLED | DIRTY; }
    if ev.key == KEY_HOME {
        if menu.candidates.len == 0 { return HANDLED; }
        highlight = 0;
        page = 0;
        ensure_grid();
        return HANDLED | DIRTY;
    }
    if ev.key == KEY_END {
        if menu.candidates.len == 0 { return HANDLED; }
        highlight = menu.candidates.len - 1;
        page = highlight / PAGE_SIZE;
        ensure_grid();
        return HANDLED | DIRTY;
    }
    if ev.key == KEY_OTHER {
        let mark = punctuation(c, halfwidth_punct);
        if mark.len > 0 {                          // the best reading, then the mark
            fresh_menu();
            var whole = -1;
            for i in menu.candidates.len {
                if menu.candidates[i].to == input.len { whole = i; break; }
            }
            let c0: decoder::Candidate = if whole >= 0 { menu.candidates[whole] } else { decoder::Candidate {
                to: 0, text: 0, len: 0, refs: 0, count: 0, code: 0, code_len: 0 } };
            var took = false;
            if whole >= 0 && picks.len < picks.cap && picked_ends.len + c0.count <= picked_ends.cap &&
               consumed.len + input.len <= consumed.cap {
                took = room_for_text(c0.len);
            }
            if took {
                // the whole-input candidate is the last pick
                confirmed.append(menu.pool[c0.text..c0.text + c0.len]);
                consumed.append(input);
                let before = picked_pairs.len;
                take_words(c0);
                picks.push(Pick { letters: input.len as u8, bytes: c0.len, words: c0.count as u8,
                                  pairs: (picked_pairs.len - before) as u8, english: if c0.code_len > 0 { 1 } else { 0 },
                                  foreign: 0 });
                learn_composition();
                append_commit(confirmed);
                clear_composition();
            } else {
                commit_raw();
            }
            append_commit(mark);
            remember("", mark, 0);
            return HANDLED | DIRTY | HAS_COMMIT;
        }
    }
    return HANDLED;                                 // other keys are swallowed while composing
}

fn put_text(out: u8[>..]&, s: const u8[:]) {
    binary::write_u32le(out, s.len as u32);
    out.append(s);
}

// The UI state as versioned little-endian bytes:
//   u32 magic, u16 version, u16 flags (FLAG_*),
//   u32 len + preedit, u32 caret (bytes), u32 len + commit,
//   u16 count, u16 highlighted (within what this sends), u16 page, u16 total,
//   count × (u32 len + text, u32 len + comment).
// Without FLAG_EXPANDED, count is one page, page is that page's index and
// total is 0. With it, count is the visible grid, page is its first row and
// total is the whole menu.
// The bytes are lent to the host until its next call into the engine.
fn snapshot(handle: u64) -> const u8[:] {
    snap.clear();
    let mine = index(handle) >= 0 && handle == active;
    var flags: u16 = 0;
    if decoder::full_charset { flags = flags | FLAG_FULL_CHARSET; }
    var preedit: u8[>..] = [];
    var count: i64 = 0;
    var first: i64 = 0;
    var shown_page: i64 = 0;
    var total: i64 = 0;
    if mine {
        if composing() {                // nothing is shown once the composition is over
            flags = flags | FLAG_COMPOSING;
            preedit.append(confirmed);
            preedit.append(shown);
        }
        let n = menu.candidates.len;
        if expanded && n > 0 && composing() {
            flags = flags | FLAG_EXPANDED;
            ensure_grid();
            first = grid_row * PAGE_SIZE;
            if first > n { first = 0; }
            count = n - first;
            let cap = GRID_ROWS * PAGE_SIZE;
            if count > cap { count = cap; }
            shown_page = grid_row;
            total = if n > 65535 { 65535 } else { n };
            if first > 0 { flags = flags | FLAG_PREVIOUS_PAGE; }
            if first + count < n { flags = flags | FLAG_NEXT_PAGE; }
        } else {
            first = page * PAGE_SIZE;
            if first < n {
                count = n - first;
                if count > PAGE_SIZE { count = PAGE_SIZE; }
            }
            shown_page = page;
            if page > 0 { flags = flags | FLAG_PREVIOUS_PAGE; }
            if first + PAGE_SIZE < n { flags = flags | FLAG_NEXT_PAGE; }
        }
    }
    binary::write_u32le(snap, SNAP_MAGIC);
    binary::write_u16le(snap, SNAP_VERSION);
    binary::write_u16le(snap, flags);
    put_text(snap, preedit);
    binary::write_u32le(snap, preedit.len as u32);
    put_text(snap, if mine { commit[..] } else { commit[..0] });
    binary::write_u16le(snap, count as u16);
    binary::write_u16le(snap, (if count > 0 { highlight - first } else { 0 }) as u16);
    binary::write_u16le(snap, shown_page as u16);
    binary::write_u16le(snap, total as u16);
    for i in first..first + count {
        let c = menu.candidates[i];
        put_text(snap, menu.pool[c.text..c.text + c.len]);
        put_text(snap, "");
    }
    return snap;
}

// The user dictionary for the host to encrypt and store, lent until the
// next call into the engine.
fn user_save() -> const u8[:] {
    user_saved.clear();
    userdb::save(user_saved);
    return user_saved;
}

// Replaces the user dictionary with one the host stored: 0, or 1 if `data`
// is not one (the dictionary is then empty).
var journal_saved: u8[>..] = [];

// The last 15 minutes of learning, for the next build of the engine in the
// process (userdb::journal_save). Lent until the next call.
fn journal_save() -> const u8[:] {
    journal_saved.clear();
    userdb::journal_save(journal_saved);
    return journal_saved;
}

fn user_restore(data: const u8[:]) -> i32 {
    clear_composition();
    return if userdb::restore(data) { 0 } else { 1 };
}

// Returns memory the engine no longer uses to the system (on memory pressure).
fn trim() {
    // The host has copied any lent bytes before this call. Active menu and
    // search data must stay intact, including a pending rerank.
    user_saved.clear();
    journal_saved.clear();
    snap.clear();
    userdb::expire_journal();
    userdb::reclaim();
    rerank::cache_free();
    trim_memory();
}

// Before the host ends the runtime (goose_exit): what lives outside it, the
// grammar model's and the reranker's mapped files, is released here.
fn close() {
    rerank::close();
    grammar::close();
}
