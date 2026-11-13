// The English words over the letters typed: decoder::search adds them to the
// words it found, for the mixed sentence (decoder_mixed.goose). They are
// scored in a Chinese word's log2 units. The Chinese searches never read
// them, so their paths stay as they were. docs/mixed-input-design.md.
import std;
import lattice;
import spelling;
import english;
import decoder;

namespace decoder;

let EN_ALPHA = 1.0;          // english::bits, already a log2 probability
let EN_BETA = 1.15;          // per typed letter, against the Chinese words it replaces
let EN_GAMMA = 24.0;         // the span has a capital the user typed
let EN_BIAS = -10.0;
let EN_PREFIX_PENALTY = 12.0;   // an unfinished word, completed
let EN_THREE = 100;          // a lowercase 3-letter word must be at least this common
let MAX_EN_EDGES = 48;       // English words one search keeps
var en_quota: i64 = 0;       // 1 when the last search found more than that and cut them

// Capitals parallel to the input, set by the session before a search. Empty
// means every letter was lowercase.
var typed_case: u8[>..] = [];

fn set_case(c: const u8[:]) {
    typed_case.clear();
    typed_case.append(c);
}

fn span_capital(from: i64, len: i64) -> bool {
    guard typed_case.len > from + len - 1 else { return false; }
    for i in from..from + len { if typed_case[i] != 0 { return true; } }
    return false;
}

// A 小鹤 key pair that this start cuts in two, so the syllable before it
// would be left as a single key.
fn cuts_pair(g: lattice::Graph&, input: const u8[:], from: i64) -> bool {
    guard spelling::live.meta.len == 1 && spelling::live.meta[0].preedit == spelling::PREEDIT_SYLLABLES else { return false; }
    guard from > 0 && from < input.len && lattice::is_letter(input[from - 1]) && lattice::is_letter(input[from]) else { return false; }
    let p = from - 1;
    guard p + 1 < g.first_edge.len else { return false; }
    for k in g.first_edge[p]..g.first_edge[p + 1] {
        let e = g.edges[k];
        if e.kind > spelling::FUZZY { continue; }
        var letters: i64 = 0;
        var i: i64 = e.from;
        while i < e.to && i < input.len && lattice::is_letter(input[i]) {
            letters++;
            i++;
        }
        if letters >= 2 && e.from < from && i > from { return true; }
    }
    return false;
}

// Nothing but a ' or the input's edge on either side of input[from..end].
fn isolated_span(input: const u8[:], from: i64, end: i64) -> bool {
    let left = from == 0 || input[from - 1] == '\'';
    let right = end == input.len || (end < input.len && input[end] == '\'');
    return left && right;
}

// The two-letter words that may join a sentence in lowercase.
fn short_listed(code: const u8[:]) -> bool {
    code == "ai" || code == "ok" || code == "ui" || code == "pc" || code == "tv"
}

// An English word's score over `len` typed letters, in a Chinese word's
// units: `capital` if one was typed in it, `prefix` if it is unfinished.
fn en_local(dict: i64, len: i64, capital: bool, prefix: bool) -> f64 {
    var s = EN_ALPHA * english::bits(dict) + EN_BETA * len + EN_BIAS;
    if capital { s += EN_GAMMA; }
    if prefix { s -= EN_PREFIX_PENALTY; }
    return s;
}

// input[from..end] with the capitals that were typed.
fn cased_letters(input: const u8[:], from: i64, end: i64, out: u8[>..]&) {
    out.clear();
    let marked = typed_case.len == input.len;
    for p in from..end {
        let c = input[p];
        out.push(if marked && typed_case[p] != 0 && lattice::is_letter(c) { c - 32 } else { c });
    }
}

// How many letters the input has from `from` on, counting no more than `most`.
fn letters_from(input: const u8[:], from: i64, most: i64) -> i64 {
    var n: i64 = 0;
    while from + n < input.len && n < most && lattice::is_letter(input[from + n]) { n++; }
    return n;
}

// An English word found over input[from..end]; `to` is past a ' after it,
// `spell` its text (english::note).
struct EnCand { from: u8, end: u8, to: u8, spell: u32, score: f32 }

// Whether dictionary word `dict`, spelled by `len` letters from `from`, may
// join a sentence: four letters or more always; three if it is common or has
// a capital; two with a capital, standing alone, or from the short list. A
// start that cuts a 小鹤 key pair (`cut`) needs four letters or a capital.
fn admit_english(input: const u8[:], from: i64, len: i64, dict: i64, cut: bool) -> bool {
    let capital = span_capital(from, len);
    if cut && len < 4 && !capital { return false; }
    if len >= 4 { return true; }
    if len == 3 { return capital || english::entry_at(dict).weight >= EN_THREE; }
    if capital || isolated_span(input, from, from + len) { return true; }
    return short_listed(english::entry_at(dict).code);
}

// Adds dictionary word `dict` over the `len` letters from `from`, in the form
// that fits what was typed; an unfinished one (`prefix`) in its commonest
// form, with the typed capitals. False if it has no such form.
fn push_english(input: const u8[:], from: i64, len: i64, dict: i64, prefix: bool, out: EnCand[>..]&) -> bool {
    guard from + len <= input.len && out.len + 8 < MAX_WORDS else { return false; }
    let capital = span_capital(from, len);
    var typed: u8[>..] = [];
    cased_letters(input, from, from + len, typed);
    var text: u8[>..] = [];
    if !prefix {
        english::prefer(dict, typed, text);
    } else if capital {
        var form: u8[>..] = [];
        english::top_form(dict, form);
        if form.len > 0 { english::apply_case(form, typed, text); }
    } else {
        english::top_form(dict, text);
    }
    guard text.len > 0 && text.len <= 65535 else { return false; }
    let end = from + len;
    out.push(EnCand { from: from as u8, end: end as u8, to: skip_separators(input, end) as u8,
                      spell: english::note(text) as u32, score: en_local(dict, len, capital, prefix) as f32 });
    return true;
}

// The English words spelled out over the input's letters, into `found`: from
// the start of the input, from where a Chinese word ends, and from where an
// English word found here ends, so that words in a row are read (research
// proposal). In 小鹤 a start may also fall inside a key pair, and then only
// a longer word or a capital is kept. `tried` marks the positions scanned.
fn scan_english_words(w: Words&, g: lattice::Graph&, input: const u8[:], found: EnCand[>..]&, tried: bool[:]) {
    var starts: bool[lattice::MAX_INPUT + 1] = [false; lattice::MAX_INPUT + 1];
    starts[skip_separators(input, 0)] = true;
    for word in w.list { starts[word.to] = true; }          // Chinese words only, so far
    for p in 1..input.len { if cuts_pair(g, input, p) { starts[p] = true; } }
    for from in input.len {
        if !starts[from] || !lattice::is_letter(input[from]) { continue; }
        tried[from] = true;
        let run = letters_from(input, from, english::MAX_CODE);
        if run < 2 { continue; }
        let cut = cuts_pair(g, input, from);
        let letters = input[from..from + run];
        for len in 2..run + 1 {
            if len >= 3 && !english::head_has(letters[0], letters[1], letters[2]) { break; }
            if found.len >= MAX_EN_EDGES * 4 { break; }
            let dict = english::exact(letters[..len]);
            if dict < 0 || !admit_english(input, from, len, dict, cut) { continue; }
            if push_english(input, from, len, dict, false, found) { starts[found[found.len - 1].to] = true; }
        }
    }
}

// The tail being typed may be an unfinished English word: at most one
// completion, the best by its score, so the first candidate does not
// flicker while the last letters of a word are still missing. Added to
// `found`; returns its place there, or -1 for none.
fn scan_english_tail(g: lattice::Graph&, input: const u8[:], tried: const bool[:], found: EnCand[>..]&) -> i64 {
    var best = NONE;
    var best_from: i64 = -1;
    var best_dict: i64 = -1;
    var ids: i64[>..] = [];
    for from in input.len {
        if !tried[from] { continue; }
        let run = letters_from(input, from, english::MAX_CODE + 1);
        if from + run != input.len || run < 4 || run > english::MAX_CODE { continue; }
        let letters = input[from..];
        if english::exact(letters) >= 0 || !english::head_has(letters[0], letters[1], letters[2]) { continue; }
        ids.clear();
        english::completions(letters, 1, ids);
        if ids.len == 0 { continue; }
        let capital = span_capital(from, run);
        if cuts_pair(g, input, from) && !capital { continue; }
        let score = en_local(ids[0], run, capital, true);
        if score > best {
            best = score;
            best_from = from;
            best_dict = ids[0];
        }
    }
    guard best_dict >= 0 && push_english(input, best_from, input.len - best_from, best_dict, true, found) else {
        return -1;
    }
    return found.len - 1;
}

// More English words than the sentence searches should weigh: the
// MAX_EN_EDGES best stay, the unfinished tail (found[tail]) among them.
fn cut_english(found: EnCand[>..]&, tail: i64) {
    var order: i64[>..] = [];
    for i in found.len { if i != tail { order.push(i); } }
    sort(order) { a, b => found[a].score > found[b].score || (found[a].score == found[b].score && a < b) };
    let room: i64 = if tail >= 0 { MAX_EN_EDGES - 1 } else { MAX_EN_EDGES };
    var kept: EnCand[>..] = [];
    for i in order {
        if kept.len == room { break; }
        kept.push(found[i]);
    }
    if tail >= 0 { kept.push(found[tail]); }
    found.clear();
    found.append(kept);
}

// Adds the English words over the input's letters to the list of Chinese
// words, which stays in order of where its words start.
fn add_english_edges(w: Words&, g: lattice::Graph&, input: const u8[:]) {
    guard input.len > 0 && input.len <= lattice::MAX_INPUT else { return; }
    var found: EnCand[>..] = [];
    var tried: bool[lattice::MAX_INPUT + 1] = [false; lattice::MAX_INPUT + 1];
    scan_english_words(w, g, input, found, tried[..]);
    let tail = scan_english_tail(g, input, tried[..], found);
    guard found.len > 0 else { return; }
    if found.len > MAX_EN_EDGES {
        en_quota++;
        cut_english(found, tail);
    }
    stable_sort(found) { a, b => a.from < b.from };
    var merged: Word[>..] = [];
    var i: i64 = 0;
    for e in found {
        while i < w.list.len && w.list[i].from <= e.from {
            merged.push(w.list[i]);
            i++;
        }
        merged.push(Word { from: e.from, end: e.end, to: e.to, source: ENGLISH, entry: e.spell, score: e.score });
    }
    merged.append(w.list[i..]);
    w.list.clear();
    w.list.append(merged);
}
