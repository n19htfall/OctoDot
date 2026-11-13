// What a composition teaches the user dictionary (engine/userdb.goose) when
// it commits, what is taken back when a commit turns out to be a mistake, and
// the dictionary's way to and from the host, which stores it.
import std;
import lexicon;
import decoder;
import decoder_menu;
import userdb;
import session;

namespace session;

// ---- the last few commits ------------------------------------------------------------

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

// ---- learning ------------------------------------------------------------------------

// Copies candidate c's words into the picks. False if they do not fit.
fn take_words(c: decoder::Candidate) -> bool {
    guard picked_ends.len + c.count <= picked_ends.cap else { return false; }
    for r in c.refs..c.refs + c.count {
        if menu.refs[r].source == decoder::ENGLISH {
            picked_ends.push(-2);
            continue;
        }
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
                if ends[k] < 0 {
                    if ends[k] == -2 {
                        chain_prev = 0;
                        chain_ant = 0;
                    }
                    continue;
                }
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
    let text = decoder::candidate_text(menu, c);
    var forgot = false;
    if c.code_len > 0 {                     // an English word: its use for these letters
        forgot = userdb::unlearn_english(menu.pool[c.code..c.code + c.code_len], text);
    } else if candidate_mixed(c) {          // a mixed sentence: the choice of it for these keys
        var span: u8[>..] = [];
        decoder::typed_span(input, decoder::skip_separators(input, 0), c.to, span);
        forgot = userdb::forget_choice(span, text);
    } else {                                // Chinese: the word or phrase itself
        var pairs: lexicon::Pair[>..] = [];
        for r in c.refs..c.refs + c.count {
            if !word_pairs(menu.refs[r], pairs) { return false; }
        }
        forgot = userdb::unlearn(pairs);
    }
    guard forgot else { return false; }
    rebuild();
    move_highlight(h);
    return true;
}

// ---- saving and restoring ------------------------------------------------------------

// The user dictionary for the host to encrypt and store, lent until the
// next call into the engine.
fn user_save() -> const u8[:] {
    user_saved.clear();
    userdb::save(user_saved);
    return user_saved;
}

var journal_saved: u8[>..] = [];

// The last 15 minutes of learning, for the next build of the engine in the
// process (userdb::journal_save). Lent until the next call.
fn journal_save() -> const u8[:] {
    journal_saved.clear();
    userdb::journal_save(journal_saved);
    return journal_saved;
}

// Replaces the user dictionary with one the host stored: 0, or 1 if `data`
// is not one (the dictionary is then empty).
fn user_restore(data: const u8[:]) -> i32 {
    clear_composition();
    return if userdb::restore(data) { 0 } else { 1 };
}
