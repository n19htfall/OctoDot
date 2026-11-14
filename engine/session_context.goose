// What the engine knows sits just before the caret, and how far it trusts
// that (docs/context-design.md): the tail. It is the end of the clause the
// user is writing, as the commits put it there, and it is what the next
// composition follows: for the reranker and the grammar model
// (decoder::preceding), and for the user's own recent word pairs
// (userdb's carry).
//
// The engine sees every key while its input source is on, and nothing else:
// not a click, not what the app does to its text. So the tail is kept only
// while every key since the commit is one whose effect is known, and it is
// dropped at the first that is not:
//
//   a commit of converted text    its ideographs are added (the last TAIL_CHARS)
//   anything else committed       the clause ends there: punctuation, Latin
//                                 letters, digits, keys committed as typed
//   Backspace passed to the app   one character less; the composition after a
//                                 deletion reads no context (the context is
//                                 what it was when the deleted text was
//                                 offered, and would offer it again)
//   Backspace past what is known  dropped
//   arrows, Return, Tab, Space, a chord, a digit, another field
//                                 dropped
//   a key that must not teach     nothing is kept (KEYFLAG_NO_LEARN)
//   time                          dropped STALE_SECONDS after its last commit:
//                                 a click moves the caret without a key
//
// Kept in memory only, never saved, never handed to the next build of the
// engine, and overwritten when dropped.
import std;
import lexicon;
import grammar;
import userdb;
import decoder;
import decoder_sentence;
import session;

namespace session;

let TAIL_CHARS = 16;            // ideographs kept: more than either model's context reads
let TRUST_NONE = 0;             // nothing is known to sit before the caret
let TRUST_CORRECTED = 1;        // the user has just deleted into it
let TRUST_FULL = 2;             // every key since its last commit was a commit
let STALE_SECONDS = 15;         // a commit this old may no longer be where the caret is

var context_on = true;          // octo_set_context: off, every menu is made as if nothing came before
var tail: u8[..64];             // TAIL_CHARS code points of at most 4 bytes
var tail_trust: i64 = 0;
var tail_at: i64 = 0;           // when it was last added to (userdb::now)
// Whether the composition being typed reads the tail: set when its first
// key comes and held, so the candidates never reorder for anything but a
// key. What this composition commits itself (make_room) it always reads.
var tail_read = false;
// The first candidate is where it is because of what came before: accepting
// it teaches the link, not a choice for these keys alone.
var promoted = false;

// An ideograph, as the models' clauses are made of: the unified ideographs
// and their extensions, the compatibility ones, and 〇.
fn ideograph(cp: i64) -> bool {
    (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x20000 && cp <= 0x323AF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) || cp == 0x3007
}

// The text alone: what the user's recent word pairs follow is left as it is.
fn tail_drop() {
    fill(tail[..], 0);
    tail.clear();
    tail_trust = TRUST_NONE;
}

// Nothing is known to sit before the caret.
fn tail_clear() {
    tail_drop();
    userdb::set_carry(0, 0);
}

// Where the last `chars` characters of `text` start.
fn last_chars(text: const u8[:], chars: i64) -> i64 {
    var at = text.len;
    var n: i64 = 0;
    while at > 0 && n < chars {
        at--;
        if (text[at] & 0xC0) != 0x80 { n++; }
    }
    return at;
}

// `text` was committed after the tail: its ideographs join it, and anything
// else ends the clause, so that what is left is the run of ideographs the
// commit ends with.
fn tail_take(text: const u8[:]) {
    guard text.len > 0 else { return; }
    if !learning_allowed {
        tail_clear();
        return;
    }
    var all: u8[>..] = [];
    all.append(tail);
    var i: i64 = 0;
    while i < text.len {
        let cp, next = grammar::next_utf8(text, i);
        if cp < 0 || next <= i {            // not text: nothing is known
            tail_clear();
            return;
        }
        if ideograph(cp) { all.append(text[i..next]); } else { all.clear(); }
        i = next;
    }
    let from = last_chars(all, TAIL_CHARS);
    tail_drop();
    if all.len - from == 0 {
        userdb::set_carry(0, 0);
        return;
    }
    tail.append(all[from..]);
    tail_trust = TRUST_FULL;
    tail_at = userdb::now();
}

// Backspace passed through to the app: the character before the caret is
// gone. Past what is known, or so long after the commit that the caret may
// be elsewhere, the user is editing something else.
fn tail_backspace() {
    userdb::set_carry(0, 0);                // the word before the caret is no longer whole, or no longer there
    if tail.len == 0 || userdb::now() - tail_at >= STALE_SECONDS {
        tail_drop();
        return;
    }
    let from = last_chars(tail, 1);
    let gone = tail.len - from;
    fill(tail[from..], 0);
    tail.pop_n(gone);
    tail_trust = TRUST_CORRECTED;
}

// A composition's first key: whether it reads the tail. A tail gone stale
// is dropped, so that the next commit does not join text the caret may have
// left; and right after a deletion it is kept but not read.
fn begin_composition() {
    tail_read = false;
    guard tail.len > 0 else { return; }
    if userdb::now() - tail_at >= STALE_SECONDS {
        tail_drop();
        return;
    }
    tail_read = context_on && tail_trust == TRUST_FULL;
}

// The words picked so far in this composition, after the two the tail ended
// with: the last two of them, as the user dictionary hashes a word's text
// (0 for none). An English word is not one, and nothing follows across it.
fn picked_lead() -> u64, u64 {
    var ant = userdb::carry_ant;
    var prev = userdb::carry_prev;
    var from: i64 = 0;
    for e in picked_ends {
        if e == -2 {
            ant = 0;
            prev = 0;
            continue;
        }
        if e < 0 { continue; }
        if e > from {
            ant = prev;
            prev = userdb::hash_surface_pairs(picked_pairs[from..e]);
        }
        from = e;
    }
    return ant, prev;
}

// Before a menu is built: what its first word follows. The picks made in
// this composition are certain, and the tail comes before them if this
// composition reads it. Off, or with nothing known, the menu is made as it
// was before there was any of this.
fn set_lead() {
    decoder::preceding.clear();
    decoder::lead_ant = userdb::carry_ant;
    decoder::lead_prev = userdb::carry_prev;
    promoted = false;
    guard context_on else { return; }
    var own: i64 = confirmed.len;           // where the picks' last run of ideographs starts
    var i: i64 = 0;
    while i < confirmed.len {
        let cp, next = grammar::next_utf8(confirmed, i);
        if cp < 0 || next <= i { break; }
        if ideograph(cp) {
            if own == confirmed.len { own = i; }
        } else {
            own = confirmed.len;
        }
        i = next;
    }
    if i < confirmed.len { own = confirmed.len; }
    let whole = own == 0;                   // nothing but ideographs picked, or nothing picked
    if whole && tail_read && tail.len > 0 { decoder::preceding.append(tail); }
    decoder::preceding.append(confirmed[own..]);
    if confirmed.len > 0 {
        decoder::lead_ant, decoder::lead_prev = picked_lead();
    }
    guard decoder::preceding.len > 0 else { return; }
    let from = last_chars(decoder::preceding, TAIL_CHARS);
    if from > 0 {
        var kept: u8[>..] = [];
        kept.append(decoder::preceding[from..]);
        decoder::preceding.clear();
        decoder::preceding.append(kept);
    }
}

// For the tests and the accuracy harness: `text` is what was committed just
// before.
fn tail_set(text: const u8[:]) {
    tail_clear();
    learning_allowed = true;
    tail_take(text);
}
