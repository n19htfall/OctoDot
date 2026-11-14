// Composing text: keys in, a snapshot of what to show out. One session per
// client text field, one composition at a time (only one field has focus).
// The session is one namespace in four files:
//
//   session.goose            the composition and its keys, picks and snapshot
//   session_menu.goose       the menu for the letters still to convert
//   session_learning.goose   what a composition teaches the user dictionary
//   session_data.goose       the data that is loaded, and the host's switches
//   session_context.goose    what sits before the caret, for the next composition
//
// Nothing a host passes in may abort: bad handles, unknown keys and full
// buffers are handled, never asserted. A failed check on the IME's main
// thread would end the process.
import std;
import os;
import binary;
import slot_pool;
import lexicon;
import auxcode;
import lattice;
import decoder;
import decoder_menu;
import decoder_sentence;
import userdb;
import phrases;
import english;
import rerank;
import grammar;
import session_menu;
import session_learning;
import session_data;
import session_context;

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
// character readings they have (in picked_pairs); `led` if it was first
// because of what came before the composition (session_context.goose).
struct Pick { letters: u8, bytes: u16, words: u8, pairs: u8, english: u8, foreign: u8, led: u8 }

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
// The best reading's last syllable is not typed out yet: its keys are the
// start of a spelling ("i" of "ig" in 小鹤双拼), or carry a shape code.
var half_typed = false;
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

// ---- sessions ---------------------------------------------------------------------

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
    tail_clear();
    last_was_digit = false;
}

// ---- the composition ----------------------------------------------------------------

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
    tail_read = true;                       // what follows, follows what this just committed
    var keys: u8[>..] = [];
    decoder::typed_span(input, 0, lead_to, keys);
    remember(keys, lead_text, 0);
    let read = lead_to;
    clear_picks();
    clear_menu();
    drop_keys(read);
}

// Forgets the first `count` keys of the input, and any ' after them: what is
// left stays to convert.
fn drop_keys(count: i64) {
    var n = count;
    while n < input.len && input[n] == '\'' { n++; }
    let marked = caps.len == input.len;
    for i in n..input.len {
        input[i - n] = input[i];
        if marked { caps[i - n] = caps[i]; }
    }
    input.pop_n(n);
    if marked { caps.pop_n(n); } else { caps.clear(); }
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
    clear_picks();
    clear_menu();
}

// The selections made so far.
fn clear_picks() {
    consumed.clear();
    confirmed.clear();
    picks.clear();
    picked_pairs.clear();
    picked_ends.clear();
}

// The menu, what it was built from, and where the user is in it.
fn clear_menu() {
    decoder::clear(menu);
    decoder::clear_words(words);
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

// ---- picking and committing ---------------------------------------------------------

fn append_commit(text: const u8[:]) {
    guard commit.len + text.len <= commit.cap else {
        tail_clear();                       // the text is lost, and so is the place
        return;
    }
    commit.append(text);
    tail_take(text);
}

// Commits the selections and the letters still to convert, as typed.
fn commit_raw() {
    let from = commit.len;
    append_commit(confirmed);
    let keys = commit.len;
    for p in input.len { if input[p] != '\'' && commit.len < commit.cap { commit.push(as_typed(p)); } }
    if commit.len > keys || input.len > 0 { tail_clear(); }     // letters as typed end the clause
    remember("", commit[from..], 0);
    clear_composition();
}

// The first candidate that reads the whole input, or -1.
fn first_whole() -> i64 {
    for i in menu.candidates.len {
        if menu.candidates[i].to == input.len { return i; }
    }
    return -1;
}

// A Command chord while composing: the composition commits (the highlighted
// candidate if it reads the whole input, else the first that does, else the
// keys as typed) and the chord passes on to the app.
fn commit_passing() -> u32 {
    fresh_menu();
    var i = first_whole();
    if highlight >= 0 && highlight < menu.candidates.len && menu.candidates[highlight].to == input.len { i = highlight; }
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
    tail_read = true;
    clear_picks();
    return text_len <= confirmed.cap;
}

// Makes candidate `c` the composition's next pick, as `text`: its own, or
// what the host put in its place (`foreign`). The text is confirmed, the
// letters it read are consumed, and its words are kept to learn from. False,
// with nothing taken, if it does not fit.
fn take(c: decoder::Candidate, text: const u8[:], foreign: bool, led: bool) -> bool {
    let to: i64 = c.to;
    guard to > 0 && to <= input.len && picks.len < picks.cap && consumed.len + to <= consumed.cap &&
          picked_ends.len + c.count <= picked_ends.cap && room_for_text(text.len) else { return false; }
    confirmed.append(text);
    consumed.append(input[..to]);
    let before = picked_pairs.len;
    take_words(c);
    picks.push(Pick { letters: to as u8, bytes: text.len as u16, words: c.count as u8,
                      pairs: (picked_pairs.len - before) as u8, english: if c.code_len > 0 { 1 } else { 0 },
                      foreign: if foreign { 1 } else { 0 }, led: if led { 1 } else { 0 } });
    return true;
}

// The composition ends as the text of its picks, which it learns from.
fn commit_picks() {
    learn_composition();
    append_commit(confirmed);
    clear_composition();
}

// Picks candidate i: it commits if it reads the rest of the input, and the
// rest stays to convert otherwise. A selection that cannot be taken commits
// what there is, as typed.
fn select(i: i64) -> u32 {
    fresh_menu();
    var replacement: u8[..phrases::MAX_TEXT] = [];     // the host's text for this pick (set_pick_text), if any
    if pick_for == active { replacement.append(pick_text[..]); }
    pick_text.clear();
    pick_for = 0;
    if menu.candidates.len == 0 {                  // nothing to choose from: the letters
        commit_raw();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    guard i >= 0 && i < menu.candidates.len else { return HANDLED; }
    let c = menu.candidates[i];
    let replace = replacement.len > 0 && confirmed.len + replacement.len <= confirmed.cap;
    if !take(c, if replace { replacement[..] } else { decoder::candidate_text(menu, c) }, replace, i == 0 && promoted) {
        commit_raw();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    drop_keys(c.to);
    if input.len == 0 {
        commit_picks();
        return HANDLED | DIRTY | HAS_COMMIT;
    }
    rebuild();
    return with_commit(HANDLED | DIRTY);
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

// ---- moving through the menu --------------------------------------------------------

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

// ---- keys ----------------------------------------------------------------------------

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
    if composing() && (ev.modifiers & MOD_COMMAND) != 0 {
        let done = commit_passing();
        tail_clear();                       // the shortcut that follows may move the caret or change the text
        return done;
    }
    if chord != 0 {
        if !composing() {
            recent.clear();
            tail_clear();
        }
        return 0;
    }

    let lower, capital = latin_letter(c);
    let shifted = capital || (ev.modifiers & MOD_SHIFT) != 0;
    // A capital is English when English words are on (Github). Otherwise it
    // goes to the app, as any other key that is not part of the composition.
    let letter = ev.key == KEY_OTHER && lower != 0 && !shifted;
    let capital_letter = ev.key == KEY_OTHER && lower != 0 && shifted && english::on;
    if letter || capital_letter {
        if !composing() { begin_composition(); }
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
            tail_backspace();
            return 0;
        }
        if ev.key == KEY_OTHER && c >= '0' && c <= '9' {
            last_was_digit = true;
            recent.clear();
            tail_clear();
            return 0;
        }
        let after_digit = last_was_digit && (c == '.' || c == ',' || c == ':');
        last_was_digit = false;
        if ev.key != KEY_OTHER || after_digit {
            // Escape leaves the app text and its learning context intact.
            if ev.key != KEY_ESCAPE {
                recent.clear();
                tail_clear();
            }
            return 0;
        }
        let mark = punctuation(c, halfwidth_punct);
        if mark.len == 0 {
            recent.clear();
            tail_clear();
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
            let whole = first_whole();              // that reading is the composition's last pick
            if whole >= 0 && take(menu.candidates[whole], decoder::candidate_text(menu, menu.candidates[whole]), false,
                                  whole == 0 && promoted) {
                commit_picks();
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

// ---- what the host shows -------------------------------------------------------------

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
        put_text(snap, decoder::candidate_text(menu, menu.candidates[i]));
        put_text(snap, "");
    }
    return snap;
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
