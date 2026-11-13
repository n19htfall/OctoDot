// The menu for the letters still to convert: built by the decoder on every
// key, then the English words placed in it, the preedit split by the best
// reading, and the reranker asked for (session.goose has the composition).
import std;
import lexicon;
import spelling;
import lattice;
import decoder;
import decoder_english;
import decoder_sentence;
import decoder_mixed;
import decoder_menu;
import userdb;
import sets;
import english;
import rerank;
import session;

namespace session;

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
    if caps.len == input.len { decoder::set_case(caps[..]); } else { decoder::set_case(""); }
    decoder::search(words, g, lexicon::live, input);
    let reach = decoder::chinese_reach(words, input);
    readable = decoder::assemble(menu, words, input);
    decoder::place_mixed(menu, words, input);
    for i in reach..input.len {
        if input[i] >= 'a' && input[i] <= 'z' { letters_unread = true; }
    }
    chinese_bits = 0.0;
    for i in menu.path { chinese_bits += words.list[i].score; }
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

// Moves whenever the data the menu's words point into changes.
fn data_version() -> u64 { userdb::changes + sets::generation }

// The menu's words refer to the user dictionary by position: if it changed
// since the menu was built (a forget, an unlearn), build the menu again
// before any of its words is used.
fn fresh_menu() {
    if input.len > 0 && menu_changes != data_version() { rebuild(); }
}

// ---- the preedit ---------------------------------------------------------------------

// The input as the preedit shows it: the keys typed, split into the best
// reading's syllables and English words: "zhong guo", "z g r" in full
// pinyin, "wo ui vs go rf" in 小鹤双拼 (the keys pressed, which is what the
// user reads back, not each syllable's pinyin spelled out). A tone or a
// shape code stays with its syllable; what the best reading does not cover
// stays as typed.
fn show_input(w: decoder::Words&, g: lattice::Graph&) {
    shown.clear();
    var segs: decoder::Segment[>..] = [];
    decoder::segments(menu, w, g, input, true, segs);
    var full = segs.len > 0;
    var at: i64 = 0;
    for seg in segs {
        let from: i64 = seg.from;
        let to: i64 = seg.to;
        if from < at { continue; }
        for p in at..from { if input[p] != '\'' { full = false; } }        // a key no syllable read
        if w.list[seg.word].source == decoder::ENGLISH || g.edges[seg.edge].kind > spelling::FUZZY { full = false; }
        // Keys outside the best reading stay as typed.
        var g0 = at;
        while g0 < from && input[g0] == '\'' { g0++; }
        if g0 < from {
            var g1 = from;
            while g1 > g0 && input[g1 - 1] == '\'' { g1--; }
            if shown.len > 0 { shown.push(if find(input[at..g0], "'") >= 0 { '\'' } else { ' ' }); }
            typed_part(g0, g1);
            at = g1;
        }
        if shown.len > 0 {          // between spans: the ' typed there, or a space
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

// The pair at depth k of entry i's word (the accuracy harness's --export-segments).
fn pair_at(lex: lexicon::Lexicon&, i: i64, k: i64) -> lexicon::Pair {
    lex.pairs[lex.runs[lex.entries[i].run + k]]
}

// ---- English words (engine/english.goose) --------------------------------------------

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

// Puts the English word `text`, typed as `code`, at place `at` of the menu:
// 1, or 0 if the menu has that text already or is full up to there.
fn insert_english(at: i64, text: const u8[:], code: const u8[:]) -> i64 {
    guard text.len > 0 && text.len <= 65535 && code.len > 0 && code.len <= 255 else { return 0; }
    if decoder::find_candidate(menu, text) >= 0 { return 0; }
    if menu.candidates.len >= decoder::MAX_CANDIDATES && at >= menu.candidates.len { return 0; }
    var c = decoder::text_candidate(menu, text, input.len);
    c.code = menu.pool.len as u32;
    c.code_len = code.len as u8;
    menu.pool.append(code);
    decoder::insert_candidate(menu, at, c);
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
    if menu.candidates.len > 0 { barrier = userdb::chosen(code, decoder::candidate_text(menu, menu.candidates[0])); }
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

// ---- the reranker (engine/rerank.goose) ----------------------------------------------

// Whether the menu's first candidate is a sentence the reranker may replace:
// the decoder's own, of more than one word, reading the whole input in
// Chinese, and not one the user chose for these keys before (their choice
// stands). English placed first, a custom phrase or a whole-input word
// leaves the menu as it is.
fn rerankable() -> bool {
    guard menu.candidates.len > 0 && readable == input.len && !letters_unread else { return false; }
    let c = menu.candidates[0];
    guard c.count > 1 && c.code_len == 0 && c.to == input.len else { return false; }
    let text = decoder::candidate_text(menu, c);
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

// Whether candidate `c` is a sentence with an English word in it.
fn candidate_mixed(c: decoder::Candidate) -> bool {
    for r in c.refs..c.refs + c.count {
        if menu.refs[r].source == decoder::ENGLISH { return true; }
    }
    return false;
}

// The first candidate is a mixed sentence or a standalone English word.
fn first_has_english() -> bool {
    guard menu.candidates.len > 0 else { return false; }
    let c = menu.candidates[0];
    if c.code_len > 0 { return true; }
    return candidate_mixed(c);
}

// The word make_room would commit is an English word.
fn lead_is_english() -> bool {
    guard menu.path.len > 0 else { return false; }
    let i: i64 = menu.path[0];
    return i >= 0 && i < words.list.len && words.list[i].source == decoder::ENGLISH;
}

// Reranks the menu being shown: the shortlist from its words, scored, and
// the best put first. The decoder's sentence stays, second. The reranker
// reads Chinese, so the mixed sentences step aside and go back to their
// places. True if the menu changed.
fn rerank_now() -> bool {
    rerank_due = 0;
    var places: i64[>..] = [];
    var mixed: decoder::Candidate[>..] = [];
    for i in menu.candidates.len {
        if candidate_mixed(menu.candidates[i]) {
            places.push(i);
            mixed.push(menu.candidates[i]);
        }
    }
    retain(menu.candidates) { c => !candidate_mixed(c) };
    let changed = rerank_chinese();
    for k in mixed.len { decoder::insert_candidate(menu, places[k], mixed[k]); }
    return changed;
}

fn rerank_chinese() -> bool {
    let m = rerank::live.meta[0];
    let n = decoder::shortlist(words, input, readable, m.beam, m.per_state, m.shortlist, shortlist);
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
    guard decoder::candidate_text(menu, menu.candidates[0]) != text else { return false; }
    var i = menu.candidates.len - 1;
    while i > 0 {                               // the same text further down goes: it moves up
        if decoder::candidate_text(menu, menu.candidates[i]) == text { remove_at(menu.candidates, i); }
        i--;
    }
    var c = decoder::text_candidate(menu, text, input.len);
    for r in shortlist.ref_at[k]..shortlist.ref_at[k + 1] { menu.refs.push(shortlist.refs[r]); }
    c.count = (shortlist.ref_at[k + 1] - shortlist.ref_at[k]) as u16;
    decoder::insert_candidate(menu, 0, c);
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
