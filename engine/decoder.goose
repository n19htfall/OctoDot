// From a syllable graph to candidates: every dictionary word readable from
// each position, the best sentence through them, and the menu a user picks
// from.
//
// A word scores log2 of its probability (weight over the lexicon's total)
// plus the credibility of the spellings it was read through. Scores are
// negative and add up along a sentence, so fewer, likelier words win.
//
// With the grammar model on (grammar.goose), the sentence is librime's:
// a beam search in which each word also scores how well it follows the two
// words before it, in place of the word penalty, and the model chooses
// among up to grammar::homophones() words per span inside the input.
import std;
import math;
import dictionary;
import lexicon;
import lattice;
import auxcode;
import userdb;
import sets;
import phrases;
import grammar;
import english;
import spelling;
import semantic;

namespace decoder;

let MAX_DEPTH = 16;         // syllables in one word
let MAX_GROUPS = 4096;      // syllable groups visited from the start of the input
let MAX_GROUPS_INSIDE = 1024; // and from each later position: bounds abbreviated input
let MAX_WORDS = 60000;      // words found per keystroke
// Homophones kept per syllable group. Only words that start the input are
// shown as candidates, so only there are many worth keeping; elsewhere the
// sentence search can use no more than the best word for each span.
let KEEP_CHARS = 60;        // one syllable, at the start: ten pages
let KEEP_WORDS = 20;        // a longer word, at the start
let MAX_CANDIDATES = 120;
let NONE = -1.0e30;

// Charged once per word, in log2 units: a word insertion penalty, so that a
// sentence of fewer, longer words wins more often. 6 measured best with
// engine/tests/eval.goose: phrases 95.5% → 97.0% first, words 99.2% → 99.7%.
var word_penalty = 6.0;

// Charged, in log2 units (≤ 0), to an abbreviated syllable with more input
// after it: someone who types "caiken" means 才肯, not 才可能 with 能 cut to
// "n". Abbreviating every syllable ("zgr") or the last one is common;
// abbreviating one in the middle of full spellings rarely is. -4 measured
// best: phrases 97.0% → 97.5% first.
var inner_abbreviation_penalty = -4.0;

// Single characters outside 通用规范汉字表 and data/daily-extra.txt are
// left out, as in 万象's daily character set, unless the full set is on
// (Control-g while composing). Characters that are not ideographs always pass, and words are
// never filtered: a rare character in a lexicon word is there for a reason.
var full_charset = false;

fn rare(lex: lexicon::Lexicon&, i: i64) -> bool {
    let f: i64 = lex.flags[lex.runs[lex.entries[i].run]];
    (f & lexicon::HAN) != 0 && (f & (lexicon::TGH | lexicon::EXTRA)) == 0
}

// Where a word comes from: the core lexicon, the user dictionary, or a
// mounted set (SET + its slot).
let LEXICON = 0;
let USER = 1;
let SET = 2;
// A word from the English dictionary (docs/english-design.md, phase 2). Not
// 3: lexicon sets take SET + slot (2 to 7), and 3 made the second set's
// words read as English, dropping them from every sentence.
let ENGLISH = 255;

// Mixed sentences (docs/mixed-input-design.md). English edges are scored in
// the same log2 units as a Chinese word. The pure Chinese search never reads
// them, so its paths stay as they were; a separate beam weighs the mixture.
let EN_ALPHA = 1.0;          // english::bits, already a log2 probability
let EN_BETA = 1.15;          // per typed letter, against the Chinese words it replaces
let EN_GAMMA = 24.0;         // the span has a capital the user typed
let EN_BIAS = -10.0;
let EN_SWITCH = -5.0;        // once per ZH↔EN boundary, not between two English words
let EN_PREFIX_PENALTY = 12.0;
let EN_TOP1 = 18.0;          // mixed score − Chinese score, to take the first place
let EN_PAGE = 2.0;           // ...to stay on the first page, behind the Chinese
let SEM_LIFT = 8.0;          // most a Chinese sense of an English word may add over the score it already has
let SENSE_PRIOR = 0.15;      // per bit a sense is rarer than the word's commonest sense
let EN_FINAL_BA = 12.0;      // 吧 ending the input after an English word that has a Chinese sense
let EN_THREE = 100;          // a lowercase 3-letter word must be at least this common
let MAX_EN_EDGES = 48;
var mixed_beam: i64 = 4;     // states kept per position (set_mixed_beam)
var en_quota: i64 = 0;       // 1 when the last search found more English words than MAX_EN_EDGES and cut them

// Capitals parallel to the input, set by the session before a search. Empty
// means every letter was lowercase.
var typed_case: u8[>..] = [];

fn set_case(c: const u8[:]) {
    typed_case.clear();
    typed_case.append(c);
}

fn source_lexicon(source: i64) -> lexicon::Lexicon& {
    if source == USER { userdb::lex }
    else if source >= SET && source < SET + sets::SLOTS { sets::slot(source - SET) }
    else { lexicon::live }
}

// Entry `entry` of `source`, read over input[from..to]; to is past any
// separator after it.
// `end` is the letter span's end. For a Chinese word it equals `to`. For an
// English word, `to` is past a trailing ', and [from, end) is the letters.
struct Word { from: u8, end: u8, to: u8, source: u8, entry: u32, score: f32 }

// A word a candidate is made of.
struct Ref { source: u8, entry: u32 }

// A constrained edge on the path being walked: the syllable at `depth` was
// read through edges[edge], and every word found must satisfy it.
struct Check { depth: u8, edge: u32 }

// What a search found. `list` holds the words in order of where they start.
// `by_span` indexes its Chinese words for the sentence searches: those that
// start at p are by_span[span_at[p]..span_at[p + 1]], by where they end
// (index_spans); offers and best_of pick a span's best from it.
root struct Words {
    list: Word[>..] = [],
    checks: Check[>..] = [],
    by_span: u32[>..] = [],
    span_at: u32[>..] = []
}

fn clear_words(w: Words&) {
    w.list.clear();
    w.checks.clear();
    w.by_span.clear();
    w.span_at.clear();
}

// Does entry i satisfy every constraint on the path: the tone and the shape
// code typed with each of its syllables?
fn fits(w: Words&, g: lattice::Graph&, lex: lexicon::Lexicon&, input: const u8[:], i: i64) -> bool {
    let e = lex.entries[i];
    for c in w.checks {
        let pair = lex.pairs[lex.runs[e.run + c.depth]];
        let edge = g.edges[c.edge];
        if edge.tone_count > 0 && !contains(g.tones[edge.tones..edge.tones + edge.tone_count], pair.toned) {
            return false;
        }
        if edge.aux_len > 0 && !auxcode::fits(auxcode::live, pair.cp, input[edge.aux..edge.aux + edge.aux_len]) {
            return false;
        }
    }
    return true;
}

// A candidate: pool[text..text + len], reading input[..to], made of the
// words refs[refs..refs + count], so choosing it can be learned.
// An English candidate has no word refs. Its code is pool[code..code + code_len]
// (the letters typed); code_len 0 is anything else.
struct Candidate { to: u8, text: u32, len: u16, refs: u32, count: u16, code: u32, code_len: u8 }

root struct Menu {
    candidates: Candidate[>..] = [],
    pool: u8[>..] = [],
    refs: Ref[>..] = [],
    path: u32[>..] = []         // the best sentence's words (indices into Words.list), first first
}

fn clear(m: Menu&) {
    m.candidates.clear();
    m.pool.clear();
    m.refs.clear();
    m.path.clear();
}

fn candidate_text(m: Menu&, c: Candidate) -> const u8[:] { m.pool[c.text..c.text + c.len] }

// Which candidate reads `text`, or -1.
fn find_candidate(m: Menu&, text: const u8[:]) -> i64 {
    for i in m.candidates.len {
        if m.candidates[i].len == text.len && candidate_text(m, m.candidates[i]) == text { return i; }
    }
    return -1;
}

// Puts `c` at place `at` (the end, if the menu is shorter). A full menu
// drops its last candidate for it.
fn insert_candidate(m: Menu&, at: i64, c: Candidate) {
    insert_at(m.candidates, if at < 0 { 0 } else if at > m.candidates.len { m.candidates.len } else { at }, c);
    if m.candidates.len > MAX_CANDIDATES { m.candidates.pop(); }
}

// A candidate reading input[..to] as `text`, made of no words yet: the text
// goes into the menu's pool, and the caller places the candidate.
fn text_candidate(m: Menu&, text: const u8[:], to: i64) -> Candidate {
    let at = m.pool.len;
    m.pool.append(text);
    return Candidate { to: to as u8, text: at as u32, len: text.len as u16, refs: m.refs.len as u32, count: 0,
                       code: 0, code_len: 0 };
}

// The same, made of `words` (indices into w.list).
fn sentence_candidate(m: Menu&, w: Words&, words: const i64[:], text: const u8[:], to: i64) -> Candidate {
    var c = text_candidate(m, text, to);
    for i in words { m.refs.push(Ref { source: w.list[i].source, entry: w.list[i].entry }); }
    c.count = words.len as u16;
    return c;
}

fn skip_separators(input: const u8[:], at: i64) -> i64 {
    var p = at;
    while p < input.len && input[p] == '\'' { p++; }
    return p;
}

// Every word readable from every position, in order of position: the core
// lexicon's, the user dictionary's and each mounted set's, then the English
// words over the same letters, and the index of the Chinese ones by span.
fn search(w: Words&, g: lattice::Graph&, lex: lexicon::Lexicon&, input: const u8[:]) {
    clear_words(w);
    en_quota = 0;
    if sets::log_total == 0.0 { sets::retotal(); }
    let log_total = sets::log_total;
    let begin = skip_separators(input, 0);
    for start in input.len {
        if input[start] == '\'' || g.first_edge[start] == g.first_edge[start + 1] { continue; }
        let wide = start == begin;
        var budget: i64 = if wide { MAX_GROUPS } else { MAX_GROUPS_INSIDE };
        walk(w, g, lex, LEXICON, input, start, start, 0, 0, lex.entries.len, 0.0, log_total, wide, budget);
        if userdb::lex.entries.len > 0 {
            var user_budget: i64 = MAX_GROUPS_INSIDE;
            walk(w, g, userdb::lex, USER, input, start, start, 0, 0, userdb::lex.entries.len, 0.0, log_total, wide,
                 user_budget);
        }
        for k in sets::SLOTS {
            if !sets::used[k] { continue; }
            var set_budget: i64 = MAX_GROUPS_INSIDE;
            walk(w, g, sets::slot(k), SET + k, input, start, start, 0, 0, sets::slot(k).entries.len, 0.0, log_total,
                 wide, set_budget);
        }
    }
    if english::active() {
        english::begin_spellings();
        add_english_edges(w, g, input);
    }
    index_spans(w, input.len);
}

// Indexes the list's Chinese words by span, once the list is complete: the
// words from each position are dealt out by where they end, each span
// keeping the order its words were found in. One pass to count, one to place.
fn index_spans(w: Words&, positions: i64) {
    w.by_span.clear();
    w.span_at.clear();
    var at: u32[256] = [0; 256];            // per end position: its words, then where the next of them goes
    var i: i64 = 0;
    for p in positions {
        let base = w.by_span.len;
        w.span_at.push(base as u32);
        let first = i;
        fill(at[..], 0);
        while i < w.list.len && w.list[i].from == p {
            if w.list[i].source != ENGLISH { at[w.list[i].to] += 1; }
            i++;
        }
        var next = base;
        for to in at.len {
            let n: i64 = at[to];
            at[to] = next as u32;
            next += n;
        }
        push_n(w.by_span, 0, next - base);
        for x in first..i {
            if w.list[x].source == ENGLISH { continue; }
            w.by_span[at[w.list[x].to]] = x as u32;
            at[w.list[x].to] += 1;
        }
    }
    w.span_at.push(w.by_span.len as u32);
}

// The Chinese words reading input[from..to]: by_span[lo..hi], as found.
fn span(w: Words&, from: i64, to: i64) -> i64, i64 {
    guard from >= 0 && from + 1 < w.span_at.len else { return 0, 0; }
    var lo: i64 = w.span_at[from];
    let end: i64 = w.span_at[from + 1];
    var b = end;
    while lo < b {
        let m = lo + (b - lo) / 2;
        if w.list[w.by_span[m]].to < to { lo = m + 1; } else { b = m; }
    }
    var hi = lo;
    while hi < end && w.list[w.by_span[hi]].to == to { hi++; }
    return lo, hi;
}

// The `count` best words of the span by_span[lo..hi], appended to `out` best
// first: one comparison for a word that is not among them, so a span of
// thousands (abbreviations) costs a pass, not a sort. Words that score the
// same stay in the order they were found, the lexicon's own, so which of two
// equal words a search prefers never depends on how a sort breaks a tie.
fn best_of(w: Words&, lo: i64, hi: i64, count: i64, out: i64[>..]&) {
    guard count > 0 else { return; }
    let base = out.len;
    for k in lo..hi {
        let x: i64 = w.by_span[k];
        let score = w.list[x].score;
        var at = out.len;
        if at - base < count {
            out.push(x);
        } else if score > w.list[out[at - 1]].score {
            at--;                           // in place of the worst kept
        } else {
            continue;
        }
        while at > base && score > w.list[out[at - 1]].score {
            out[at] = out[at - 1];
            at--;
        }
        out[at] = x;
    }
}

// The words starting at `p` that a sentence search chooses among: each
// span's `homophones` best, as librime's EnrollEntries keeps max_homophones
// per end position. Appended to `out` by where they end, best first.
fn offers(w: Words&, p: i64, homophones: i64, out: i64[>..]&) {
    guard p >= 0 && p + 1 < w.span_at.len else { return; }
    var lo: i64 = w.span_at[p];
    let end: i64 = w.span_at[p + 1];
    while lo < end {
        var hi = lo + 1;
        while hi < end && w.list[w.by_span[hi]].to == w.list[w.by_span[lo]].to { hi++; }
        best_of(w, lo, hi, homophones, out);
        lo = hi;
    }
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
        if letters >= 2 && (e.from as i64) < from && i > from { return true; }
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

// Extends the words in [lo, hi), which share `depth` syllables read so far,
// by every edge from `at`. An edge's syllables come in runs of consecutive
// ids; each run narrows the range at once, which then splits into one group
// per syllable actually present, so an abbreviation costs what it finds.

recursive fn walk(w: Words&, g: lattice::Graph&, lex: lexicon::Lexicon&, source: i64, input: const u8[:], start: i64,
                  at: i64, depth: i64, lo: i64, hi: i64, credibility: f64, log_total: f64, wide: bool,
                  budget: i64&) {
    if depth >= MAX_DEPTH || budget <= 0 || w.list.len >= MAX_WORDS { return; }
    let p = skip_separators(input, at);
    if p >= input.len { return; }
    let e_lo: i64 = g.first_edge[p];
    let e_hi: i64 = g.first_edge[p + 1];
    // An image's two-level index (first syllable → its words; second → a
    // node per syllable) answers the first two levels without searching
    // the entries. The user dictionary, built in memory, has no index.
    let indexed = lex.first.len == lex.plain.len + 1 && lex.plain.len > 0;
    var s0: i64 = -1;                   // depth 1: the first syllable [lo, hi) shares
    var na: i64 = 0;
    var nb: i64 = 0;
    if indexed && depth == 1 && lo < hi {
        s0 = lexicon::key(lex, lo, 0);
        na = lex.second_at[s0];
        nb = lex.second_at[s0 + 1];
        if na == nb || lex.nodes[na].start != lo || lex.first[s0 + 1] != hi { s0 = -1; }   // not a whole block
    }
    for k in e_lo..e_hi {
        let edge = g.edges[k];
        let to = skip_separators(input, edge.to);
        let inner: f64 = if edge.kind == 2 && to < input.len { inner_abbreviation_penalty } else { 0.0 };
        let checked = edge.tone_count > 0 || edge.aux_len > 0;
        if checked { w.checks.push(Check { depth: depth as u8, edge: k as u32 }); }
        let j_end: i64 = edge.syls + edge.count;
        if indexed && depth == 0 && lo == 0 && hi == lex.entries.len {
            for y in edge.syls..j_end {          // the words starting with syllable s: entries[first[s]..first[s + 1]]
                if budget <= 0 || w.list.len >= MAX_WORDS { break; }
                let s: i64 = g.syls[y].plain;
                if s + 1 >= lex.first.len { continue; }
                let glo: i64 = lex.first[s];
                let ghi: i64 = lex.first[s + 1];
                if glo == ghi { continue; }
                budget--;
                group(w, g, lex, source, input, start, edge.to, to, depth, glo, ghi,
                      credibility + g.syls[y].credibility + inner, log_total, wide, budget);
            }
        } else if s0 >= 0 {
            for y in edge.syls..j_end {          // the first syllable's nodes, one per second syllable
                if budget <= 0 || w.list.len >= MAX_WORDS { break; }
                let t: i64 = g.syls[y].plain;
                var a = na;
                var b = nb;
                while a < b {
                    let m = a + (b - a) / 2;
                    if (lex.nodes[m].syl as i64) < t { a = m + 1; } else { b = m; }
                }
                if a >= nb || (lex.nodes[a].syl as i64) != t { continue; }
                let glo: i64 = lex.nodes[a].start;
                let ghi: i64 = if a + 1 < nb { lex.nodes[a + 1].start } else { hi };
                budget--;
                group(w, g, lex, source, input, start, edge.to, to, depth, glo, ghi,
                      credibility + g.syls[y].credibility + inner, log_total, wide, budget);
            }
        } else {
            var j: i64 = edge.syls;
            while j < j_end && budget > 0 {
                var r = j;
                while r + 1 < j_end && g.syls[r + 1].plain == g.syls[r].plain + 1 { r++; }
                let a, b = lexicon::narrow(lex, lo, hi, depth, g.syls[j].plain, g.syls[r].plain);
                var x = a;
                var y = j;
                while x < b && budget > 0 && w.list.len < MAX_WORDS {
                    budget--;
                    let s = lexicon::key(lex, x, depth);
                    let glo, ghi = lexicon::narrow(lex, x, b, depth, s, s);
                    while g.syls[y].plain < s { y++; }
                    group(w, g, lex, source, input, start, edge.to, to, depth, glo, ghi,
                          credibility + g.syls[y].credibility + inner, log_total, wide, budget);
                    x = ghi;
                }
                j = r + 1;
            }
        }
        if checked { w.checks.pop(); }
    }
}

// The words in [glo, ghi), which share `depth` + 1 syllables read so far:
// those that end here become words (constraints and the character set
// first, then the homophone cut), the rest are extended from `at`.
recursive fn group(w: Words&, g: lattice::Graph&, lex: lexicon::Lexicon&, source: i64, input: const u8[:], start: i64,
                   at: i64, to: i64, depth: i64, glo: i64, ghi: i64, score: f64, log_total: f64, wide: bool,
                   budget: i64&) {
    var ex = glo;                       // the words that end here: the group's shortest, first
    var ex_hi = ghi;
    while ex < ex_hi {
        let m = ex + (ex_hi - ex) / 2;
        if lex.entries[m].len <= depth + 1 { ex = m + 1; } else { ex_hi = m; }
    }
    let keep: i64 = if !wide { grammar::homophones() } else if depth == 0 { KEEP_CHARS } else { KEEP_WORDS };
    let filter = depth == 0 && !full_charset;
    var kept: i64 = 0;
    var i = glo;
    while i < ex && kept < keep {
        if (w.checks.len == 0 || fits(w, g, lex, input, i)) && !(filter && rare(lex, i)) {
            let weight = (lex.entries[i].weight as f64) / lexicon::WEIGHT_SCALE;
            var penalty = 0.0;
            if userdb::tombs.len > 0 && source != USER && source != ENGLISH && userdb::demoted(lex, i) {
                penalty = userdb::DEMOTE_BITS;
            }
            w.list.push(Word { from: start as u8, end: to as u8, to: to as u8, source: source as u8, entry: i as u32,
                               score: (weight - log_total + score - word_penalty - penalty) as f32 });
            kept++;
        }
        i++;
    }
    if ex < ghi {
        walk(w, g, lex, source, input, start, at, depth + 1, ex, ghi, score, log_total, wide, budget);
    }
}

// How far the input can be read: the furthest position some sequence of
// words reaches from its start; with `english` false, of Chinese words.
fn reach(w: Words&, input: const u8[:], english: bool) -> i64 {
    var reached: bool[lattice::MAX_INPUT + 1] = [false; lattice::MAX_INPUT + 1];
    let begin = skip_separators(input, 0);
    reached[begin] = true;
    var far = begin;
    for word in w.list {                    // words come in order of where they start
        if !reached[word.from] || (!english && word.source == ENGLISH) { continue; }
        reached[word.to] = true;
        if word.to > far { far = word.to; }
    }
    return far;
}

fn readable(w: Words&, input: const u8[:]) -> i64 { reach(w, input, true) }

// How far Chinese words alone reach. Rule 1 of English placement: no
// complete Chinese reading of the whole input.
fn chinese_reach(w: Words&, input: const u8[:]) -> i64 { reach(w, input, false) }

// ---- the user's recent text: a word after the words it lately followed ------------

// Word i's text as the user dictionary hashes it; 0 for no word (-1) or an
// English one.
fn surface_of(w: Words&, i: i64) -> u64 {
    if i < 0 { return 0; }
    let word = w.list[i];
    if word.source == ENGLISH { return 0; }
    return userdb::hash_surface_entry(source_lexicon(word.source), word.entry);
}

// What word `current` gains for having lately followed the text hashed
// `prev_h` and, before that, `ant_h` (userdb::recall).
fn recalled(w: Words&, prev_h: u64, ant_h: u64, current: i64) -> f64 {
    guard prev_h != 0 else { return 0.0; }
    let word = w.list[current];
    if word.source == ENGLISH { return 0.0; }
    let lex = source_lexicon(word.source);
    return userdb::recall(prev_h, ant_h, userdb::hash_reading_entry(lex, word.entry), lex.entries[word.entry].len);
}

// For `current` after the sentence's words `prev` and, before it, `anterior`
// (-1 for none): where the sentence has no word yet, what was committed
// last stands in.
fn context_boost(w: Words&, anterior: i64, prev: i64, current: i64) -> f64 {
    if userdb::pom.len == 0 { return 0.0; }
    if prev < 0 { return recalled(w, userdb::carry_prev, userdb::carry_ant, current); }
    return recalled(w, surface_of(w, prev), if anterior >= 0 { surface_of(w, anterior) } else { userdb::carry_prev },
                    current);
}

// The same inside a mixed sentence, which what was committed last does not
// reach into.
fn mixed_boost(w: Words&, anterior: i64, prev: i64, current: i64) -> f64 {
    if userdb::pom.len == 0 || prev < 0 { return 0.0; }
    return recalled(w, surface_of(w, prev), surface_of(w, anterior), current);
}

// ---- the Chinese front ---------------------------------------------------------------

// The best pure-Chinese score at each input position (NONE where no reading
// reaches) and the words that reach it, first first:
// front_ids[front_at[p]..front_at[p] + front_n[p]]. Recorded by whichever
// search assembled the menu; the mixed search starts from it.
var front_score: f64[>..] = [];
var front_at: i32[>..] = [];
var front_n: i32[>..] = [];
var front_ids: i32[>..] = [];

fn reset_front(n: i64) {
    front_score.clear();
    front_at.clear();
    front_n.clear();
    front_ids.clear();
    for i in n {
        front_score.push(NONE);
        front_at.push(0);
        front_n.push(0);
    }
}

// Records the reading that reaches `at`, given last word first.
fn store_front(at: i64, score: f64, last_first: const i32[:]) {
    guard at >= 0 && at < front_score.len else { return; }
    front_score[at] = score;
    front_at[at] = front_ids.len as i32;
    front_n[at] = last_first.len as i32;
    front_ids.append(last_first);
    reverse(front_ids[front_at[at]..]);
}

fn note_viterbi(w: Words&, input: const u8[:], begin: i64, best: f64[lattice::MAX_INPUT + 1], back: i64[lattice::MAX_INPUT + 1]) {
    reset_front(input.len + 1);
    front_score[begin] = 0.0;
    var chain: i32[>..] = [];
    for p in input.len + 1 {
        if p == begin || back[p] < 0 { continue; }
        chain.clear();
        var at = p;
        while at != begin {
            chain.push(back[at] as i32);
            at = w.list[back[at]].from;
        }
        store_front(p, best[p], chain);
    }
}

// The best sentence over input[..end] by the words' own scores: its words,
// last first, in `path`; false if it cannot be read through to `end`.
fn best_path(w: Words&, input: const u8[:], end: i64, path: i64[>..]&) -> bool {
    var best: f64[lattice::MAX_INPUT + 1] = [NONE; lattice::MAX_INPUT + 1];
    var back: i64[lattice::MAX_INPUT + 1] = [-1; lattice::MAX_INPUT + 1];
    let begin = skip_separators(input, 0);
    best[begin] = 0.0;
    for i in w.list.len {                    // words come in order of where they start
        let word = w.list[i];
        if word.source == ENGLISH { continue; }
        if best[word.from] <= NONE { continue; }
        let prev = back[word.from];
        let anterior = if prev >= 0 { back[w.list[prev].from] } else { -1 };
        let s = best[word.from] + word.score + context_boost(w, anterior, prev, i);
        if s > best[word.to] {
            best[word.to] = s;
            back[word.to] = i;
        }
    }
    note_viterbi(w, input, begin, best, back);
    if back[end] < 0 { return false; }
    var at = end;
    while at != begin {
        let i = back[at];
        path.push(i);
        at = w.list[i].from;
    }
    return true;
}

fn word_text(word: Word, out: u8[>..]&) {
    if word.source == ENGLISH { english::spelling(word.entry, out); return; }
    lexicon::text(source_lexicon(word.source), word.entry, out);
}

// Two English words in a row are separate tokens: research proposal. A
// Chinese word stays flush against the English word beside it.
fn append_words(w: Words&, words: const i64[:], text: u8[>..]&) {
    var prev_en = false;
    for i in words {
        let word = w.list[i];
        if prev_en && word.source == ENGLISH { text.push(' '); }
        word_text(word, text);
        prev_en = word.source == ENGLISH;
    }
}

// The text before the input, which the first word of a sentence follows:
// what was chosen earlier in the composition (the session sets it). Empty,
// the first word scores the model's non-collocation penalty, as in librime.
var preceding: u8[>..];

// Partial sentences the beam keeps, ending where their last word ends.
struct Line { prev: i32, word: i32, score: f64 }

// The front as the beam left it: at each position, the best line ending there.
fn note_beam(input: const u8[:], begin: i64, lines: Line[>..]&, next: i32[>..]&, ends: i32[>..]&, offered: i64[>..]&) {
    reset_front(input.len + 1);
    var chain: i32[>..] = [];
    for p in input.len + 1 {
        var best: i64 = -1;
        var c: i64 = ends[p];
        while c >= 0 {
            if (lines[c].word >= 0 || p == begin) && (best < 0 || lines[c].score > lines[best].score) { best = c; }
            c = next[c];
        }
        if best < 0 { continue; }
        chain.clear();
        var at = best;
        while at >= 0 && lines[at].word >= 0 {
            chain.push(offered[lines[at].word] as i32);
            at = lines[at].prev;
        }
        store_front(p, lines[best].score, chain);
    }
}

// The grammar model's answers, by the exact question (context, word, and
// whether it ends the input): a key adds one letter, so nearly every pair
// the beam scores was scored for the key before. A fixed table, one slot
// per question by its hash, a newer question taking the slot: constant
// time and size (1 MiB), never grown or emptied mid-search. A slot holds the
// question's full hash, so a different question is never answered from it;
// equal questions get equal answers, so this changes no result. Emptied
// when the model changes.
struct Fit { key: u64, value: f64 }
let FIT_SLOTS = 65536;
var fits: Fit[>..] = [];

fn forget_fits() {
    fits.clear();
    for i in FIT_SLOTS { fits.push(Fit { key: 0, value: 0.0 }); }
}

// How well `word` follows `context`, in bits; `rear` when it ends the input.
fn fit(context: const u8[:], context_hash: u64, word: const u8[:], word_hash: u64, rear: bool) -> f64 {
    var key = (context_hash * 0x100000001B3) ^ (word_hash * 0x9E3779B97F4A7C15) ^ (if rear { 1 } else { 0 });
    if key == 0 { key = 1; }                // 0 marks an empty slot
    if fits.len != FIT_SLOTS { forget_fits(); }
    let slot: i64 = (key & (FIT_SLOTS - 1)) as i64;
    if fits[slot].key == key { return fits[slot].value; }
    let f = grammar::query(context, word, rear) / lattice::LN2;
    fits[slot] = Fit { key: key, value: f };
    return f;
}

// Emissions, for the second pass's experiments (the accuracy harness's
// --emissions): per syllable of one segmentation of the input, a
// score in bits for each character an encoder considered. A word aligned
// with the segmentation adds its characters' scores, emit_floor for a
// character the encoder did not score; a word across its syllable
// boundaries adds emit_floor per character. Off unless emit_on.
var emit_on = false;
var emit_weight = 1.0;
var emit_floor = -20.0;
var emit_bounds: i64[>..];  // where each syllable starts in the input, then where the last ends
var emit_start: i64[>..];   // syllable k's scores: emit_cp and emit_bits [emit_start[k]..emit_start[k + 1]]
var emit_cp: u32[>..];
var emit_bits: f64[>..];

fn emission(input: const u8[:], from: i64, to: i64, text: const u8[:]) -> f64 {
    let a = skip_separators(input, from);
    let b = skip_separators(input, to);
    var kf: i64 = -1;
    var kt: i64 = -1;
    for k in emit_bounds.len {
        if emit_bounds[k] == a { kf = k; }
        if emit_bounds[k] == b { kt = k; }
    }
    var chars: i64 = 0;
    each_utf8(text) { cp => chars++; };
    if kf < 0 || kt < 0 || kt - kf != chars || kt >= emit_start.len { return emit_floor * (chars as f64); }
    var sum = 0.0;
    var k = kf;
    each_utf8(text) { cp =>
        var got = emit_floor;
        for i in emit_start[k]..emit_start[k + 1] {
            if emit_cp[i] == cp as u32 { got = emit_bits[i]; break; }
        }
        sum += got;
        k++;
    };
    return sum;
}

let BEAM = 7;               // lines extended from each position (librime's kMaxLineCandidates)
var fit_weight = 1.0;       // the grammar model's score, against the word scores'


// The best sentence over input[..end] with the grammar model, librime's
// beam search (Poet::MakeSentenceWithStrategy<BeamSearch>):
//   - each span (start, end) offers its grammar::homophones() best words, as
//     librime's EnrollEntries keeps max_homophones per end position;
//   - at each position the best line for each distinct last word is kept,
//     and the BEAM best of them are extended by every word starting there;
//   - a word adds its own score, word penalty included, and how well it
//     follows the line's last two words (the preceding text, for the first
//     word), with `rear` when it ends the input. librime adds the model's
//     score to ln(weight) - ln(1e8) with no word penalty; on the 3,392
//     corpus sentences that scale reads 60.0% of them right, this one 63.5%
//     (docs/M2-grammar.md);
//   - a single word over the whole input is left to the word candidates.
// Its words, last first, in `path`; false if no line reaches `end`.
fn best_line(w: Words&, input: const u8[:], end: i64, path: i64[>..]&) -> bool {
    var found: i64[>..] = [];
    guard sentences(w, input, end, BEAM, grammar::homophones(), 1, found) > 0 else { return false; }
    path.append(found[..found.len - 1]);        // without its -1
    return true;
}

// The same search with its widths given, keeping the `keep` best sentences
// that reach `end` (distinct in their last word, as librime's states are):
// each one's words, last first, followed by -1, best first, in `paths`.
// Returns how many. best_line is this with librime's widths and one
// sentence; the accuracy harness asks for more, to see what a wider search
// or a reranker could find.
fn sentences(w: Words&, input: const u8[:], end: i64, beam: i64, homophones: i64, keep: i64,
             paths: i64[>..]&) -> i64 {
    var scores: f64[>..] = [];
    return scored_sentences(w, input, end, beam, homophones, keep, paths, scores);
}

// The same, with each sentence's score (best first) in `scores`.
fn scored_sentences(w: Words&, input: const u8[:], end: i64, beam: i64, homophones: i64, keep: i64,
                    paths: i64[>..]&, scores: f64[>..]&) -> i64 {
    return kbest_sentences(w, input, end, beam, homophones, 1, keep, paths, scores);
}

// The same search keeping up to `per_state` lines for each position and
// last word, not just the best: with enough of them and a wide beam, the
// `keep` best sentences by the same scores, which the accuracy harness
// measures the right sentence's rank among. One per state is the search the
// IME runs. Sentences of the same text may come more than once.
fn kbest_sentences(w: Words&, input: const u8[:], end: i64, beam: i64, homophones: i64, per_state: i64, keep: i64,
                   paths: i64[>..]&, scores: f64[>..]&) -> i64 {
    let begin = skip_separators(input, 0);
    // The words each position offers, and their texts, made once.
    var offered: i64[>..] = [];
    var pool: u8[>..] = [];
    var text_at: u32[>..] = [];             // pool[text_at[k]..text_at[k + 1]] is offered[k]'s text
    var text_hash: u64[>..] = [];
    var group_at: i64[>..] = [];            // offered[group_at[p]..group_at[p + 1]] start at position p
    var span_words: i64[>..] = [];
    for p in input.len {
        group_at.push(offered.len);
        span_words.clear();
        offers(w, p, homophones, span_words);
        for x in span_words {
            let to: i64 = w.list[x].to;
            if to > end || (p == begin && to == end) { continue; }
            offered.push(x);
            text_at.push(pool.len as u32);
            word_text(w.list[x], pool);
        }
    }
    group_at.push(offered.len);
    text_at.push(pool.len as u32);
    for k in offered.len { text_hash.push(hash(pool[text_at[k]..text_at[k + 1]])); }

    // Lines, and per position the lines that end there; a line is found by
    // its position and its last word's text.
    var lines: Line[>..] = [Line { prev: -1, word: -1, score: 0.0 }];
    var ends: i32[>..] = [];
    var next: i32[>..] = [-1];
    for p in input.len + 1 { ends.push(-1); }
    ends[begin] = 0;
    var by_text = dictionary<u64, i32> {};
    var slots: i32[>..] = [];                // per_state > 1: per_state lines per state; by_text holds block + 1
    var context: u8[>..] = [];
    var top: i32[>..] = [];
    for b in group_at.len - 1 {
        let lo = group_at[b];
        let hi = group_at[b + 1];
        if lo == hi { continue; }
        let from: i64 = w.list[offered[lo]].from;
        top.clear();
        var k: i64 = ends[from];
        while k >= 0 {
            top.push(k as i32);
            k = next[k];
        }
        if top.len == 0 { continue; }
        sort(top) { a, c => lines[a].score > lines[c].score };
        if top.len > beam { top.resize(beam); }
        for t in top {
            let line = lines[t];
            context.clear();
            if line.word < 0 {
                context.append(preceding);
            } else {
                let lw: i64 = line.word;
                if line.prev >= 0 && lines[line.prev].word >= 0 {
                    let pw: i64 = lines[line.prev].word;
                    context.append(pool[text_at[pw]..text_at[pw + 1]]);
                }
                context.append(pool[text_at[lw]..text_at[lw + 1]]);
            }
            let context_hash = hash(context);
            for o in lo..hi {
                let word = w.list[offered[o]];
                let to: i64 = word.to;
                let text = pool[text_at[o]..text_at[o + 1]];
                var score = line.score + (word.score as f64) +
                            fit_weight * fit(context, context_hash, text, text_hash[o], to == end);
                var ant: i64 = -1;
                var prev: i64 = -1;
                if line.word >= 0 {
                    prev = offered[line.word];
                    if line.prev >= 0 && lines[line.prev].word >= 0 { ant = offered[lines[line.prev].word]; }
                }
                score += context_boost(w, ant, prev, offered[o]);
                if emit_on { score += emit_weight * emission(input, from, to, text); }
                let key = text_hash[o] ^ ((to as u64) * 0x9E3779B97F4A7C15);
                let found = by_text.get(key);
                if per_state <= 1 {
                    if found && lines[found].word >= 0 && pool[text_at[lines[found].word]..text_at[lines[found].word + 1]] == text {
                        if score > lines[found].score {
                            lines[found] = Line { prev: t, word: o as i32, score: score };
                        }
                    } else if !found {
                        lines.push(Line { prev: t, word: o as i32, score: score });
                        next.push(ends[to]);
                        ends[to] = (lines.len - 1) as i32;
                        by_text.insert(key, (lines.len - 1) as i32);
                    }
                } else if !found {
                    lines.push(Line { prev: t, word: o as i32, score: score });
                    next.push(ends[to]);
                    ends[to] = (lines.len - 1) as i32;
                    by_text.insert(key, (slots.len / per_state + 1) as i32);
                    slots.push((lines.len - 1) as i32);
                    for r in per_state - 1 { slots.push(-1); }
                } else {
                    let base = ((found as i64) - 1) * per_state;
                    let first: i64 = slots[base];
                    let fw: i64 = lines[first].word;
                    if pool[text_at[fw]..text_at[fw + 1]] == text {
                        var free: i64 = -1;
                        var worst: i64 = -1;
                        for r in per_state {
                            let sl: i64 = slots[base + r];
                            if sl < 0 {
                                if free < 0 { free = base + r; }
                            } else if worst < 0 || lines[sl].score < lines[worst].score {
                                worst = sl;
                            }
                        }
                        if free >= 0 {
                            lines.push(Line { prev: t, word: o as i32, score: score });
                            next.push(ends[to]);
                            ends[to] = (lines.len - 1) as i32;
                            slots[free] = (lines.len - 1) as i32;
                        } else if score > lines[worst].score {
                            lines[worst] = Line { prev: t, word: o as i32, score: score };
                        }
                    }
                }
            }
        }
    }
    var finals: i32[>..] = [];
    var c: i64 = ends[end];
    while c >= 0 {
        if lines[c].word >= 0 { finals.push(c as i32); }
        c = next[c];
    }
    sort(finals) { a, b => lines[a].score > lines[b].score };
    note_beam(input, begin, lines, next, ends, offered);
    var found: i64 = 0;
    for f in finals {
        if found == keep { break; }
        var at: i64 = f;
        while at >= 0 && lines[at].word >= 0 {
            paths.push(offered[lines[at].word]);
            at = lines[at].prev;
        }
        paths.push(-1);
        scores.push(lines[f].score);
        found++;
    }
    return found;
}

// The best distinct sentences of a search wider than the IME's own (more
// lines kept per state, a wider beam), for the reranker: each one's text, the
// words it is made of (first first), and its score, best first.
root struct Shortlist {
    pool: u8[>..] = [],
    text_at: u32[>..] = [],     // sentence k's text is pool[text_at[k] .. text_at[k + 1]]
    refs: Ref[>..] = [],
    ref_at: u32[>..] = [],      // and its words refs[ref_at[k] .. ref_at[k + 1]]
    scores: f64[>..] = []
}

fn clear_shortlist(s: Shortlist&) {
    s.pool.clear();
    s.text_at.clear();
    s.text_at.push(0);
    s.refs.clear();
    s.ref_at.clear();
    s.ref_at.push(0);
    s.scores.clear();
}

fn shortlist_text(s: Shortlist&, k: i64) -> const u8[:] { s.pool[s.text_at[k]..s.text_at[k + 1]] }

// Fills `s` with up to `keep` sentences reading input[..end], from a K-best
// search keeping `per_state` lines per position and last word and `beam`
// lines per position. A text the search finds more than once (segmented
// differently) is kept once, at its best. Returns how many.
fn shortlist(w: Words&, input: const u8[:], end: i64, beam: i64, per_state: i64, keep: i64, s: Shortlist&) -> i64 {
    clear_shortlist(s);
    var paths: i64[>..] = [];
    var scores: f64[>..] = [];
    let n = kbest_sentences(w, input, end, beam, grammar::homophones(), per_state, keep * 8, paths, scores);
    var seen = dictionary<u64, bool> {};
    var text: u8[>..] = [];
    var at: i64 = 0;
    for r in n {
        if s.scores.len == keep { break; }
        var e = at;
        while paths[e] >= 0 { e++; }
        text.clear();
        var j = e - 1;
        while j >= at {                         // a path lists its words last first
            word_text(w.list[paths[j]], text);
            j--;
        }
        let h = hash(text[..]);
        if !seen.contains(h) && text.len > 0 {
            seen.insert(h, true);
            s.pool.append(text);
            s.text_at.push(s.pool.len as u32);
            j = e - 1;
            while j >= at {
                let word = w.list[paths[j]];
                s.refs.push(Ref { source: word.source, entry: word.entry });
                j--;
            }
            s.ref_at.push(s.refs.len as u32);
            s.scores.push(scores[r]);
        }
        at = e + 1;
    }
    return s.scores.len;
}

// The words on some path within `delta` bits of the best, by their own
// scores (max-product forward-backward over the word graph): a word stays
// if the best path from the start to it, plus it, plus the best path from
// it to `end`, scores at least the best path less delta. Two linear passes.
// A sentence whose path scores within delta of the best keeps every word.
// Returns how many words stay, marked in `kept`.
fn prune(w: Words&, input: const u8[:], end: i64, delta: f64, kept: bool[>..]&) -> i64 {
    kept.clear();
    let begin = skip_separators(input, 0);
    var forward: f64[>..] = [];
    var backward: f64[>..] = [];
    for p in input.len + 1 {
        forward.push(NONE);
        backward.push(NONE);
    }
    forward[begin] = 0.0;
    backward[end] = 0.0;
    for word in w.list {                    // words come in order of where they start
        if word.source == ENGLISH { continue; }
        let to: i64 = word.to;
        if to > end || forward[word.from] <= NONE { continue; }
        let s = forward[word.from] + (word.score as f64);
        if s > forward[to] { forward[to] = s; }
    }
    var i = w.list.len - 1;
    while i >= 0 {
        let word = w.list[i];
        if word.source != ENGLISH {
            let to: i64 = word.to;
            if to <= end && backward[to] > NONE {
                let s = (word.score as f64) + backward[to];
                if s > backward[word.from] { backward[word.from] = s; }
            }
        }
        i--;
    }
    let floor = forward[end] - delta;
    var n: i64 = 0;
    for word in w.list {
        let to: i64 = word.to;
        let keep = word.source != ENGLISH && to <= end && forward[word.from] > NONE && backward[to] > NONE &&
                   forward[word.from] + (word.score as f64) + backward[to] >= floor;
        kept.push(keep);
        if keep { n++; }
    }
    return n;
}

// Appends a candidate made of `words` (indices into w.list) unless its text
// is already in the menu.
fn offer(m: Menu&, seen: dictionary<const u8[:], bool>&, w: Words&, words: const i64[:], to: i64) {
    guard m.candidates.len < MAX_CANDIDATES && words.len > 0 else { return; }
    var text: u8[>..] = [];
    append_words(w, words, text);
    if text.len == 0 || text.len > 65535 || seen.contains(text) { return; }
    let c = sentence_candidate(m, w, words, text, to);
    seen.insert(candidate_text(m, c), true);
    m.candidates.push(c);
}

// A candidate that is only text, made of no words: a shortcut.
fn offer_text(m: Menu&, seen: dictionary<const u8[:], bool>&, text: const u8[:], to: i64) {
    guard m.candidates.len < MAX_CANDIDATES && text.len > 0 && text.len <= 65535 && !seen.contains(text) else { return; }
    let c = text_candidate(m, text, to);
    seen.insert(candidate_text(m, c), true);
    m.candidates.push(c);
}

// input[begin..to] as typed, without separators: the key choices are kept by.
fn typed_span(input: const u8[:], begin: i64, to: i64, out: u8[>..]&) {
    for c in input[begin..to] { if c != '\'' { out.push(c); } }
}

// A word that starts the input, and how often its text was chosen for the
// input it covers.
struct Item { word: i64, chosen: i64 }

// The menu for `input`, covering as much of it as can be read: the best
// sentence first, when it is more than one word, then the words that start
// the input, longest first. Among words covering the same input, those the
// user chose for exactly that input come first (most chosen first), then
// the best scored; the sentence yields only to whole-input words chosen
// more often than it. A word is offered only if what follows it can be read
// too, so neither a stray initial ("zh" leaving "ong7") nor a word cut off
// from its tone or shape code appears. Returns how far the input can be read.
fn assemble(m: Menu&, w: Words&, lex: lexicon::Lexicon&, input: const u8[:]) -> i64 {
    clear(m);
    let end = readable(w, input);
    var rest_reads: bool[lattice::MAX_INPUT + 1] = [false; lattice::MAX_INPUT + 1];  // can input[p..end] be read?
    rest_reads[end] = true;
    var k = w.list.len - 1;
    while k >= 0 {
        let word = w.list[k];
        if word.to <= end && rest_reads[word.to] { rest_reads[word.from] = true; }
        k--;
    }
    var seen = dictionary<const u8[:], bool> {};
    let begin = skip_separators(input, 0);
    let remember = userdb::live_choices > 0;
    if phrases::live.list.len > 0 {         // a custom shortcut for exactly these keys comes first
        var keys: u8[>..] = [];
        typed_span(input, begin, input.len, keys);
        if phrases::is_code(keys) {
            let lo, hi = phrases::lookup(phrases::live, keys);
            for i in lo..hi {
                let s = phrases::live.list[i];
                offer_text(m, seen, phrases::live.pool[s.text..s.text + s.len], input.len);
            }
        }
    }
    var path: i64[>..] = [];
    var sentence: i64[>..] = [];
    var sentence_chosen: i64 = 0;
    // With the grammar model, librime makes a sentence only when no word
    // reads the whole input (ScriptTranslation::Evaluate): then the words
    // are the menu, and the path, made the plain way, only splits the
    // preedit and names the first word.
    var whole_word = false;
    for word in w.list {
        if word.source == ENGLISH { continue; }
        if word.from == begin && word.to == end { whole_word = true; break; }
    }
    let sentence_allowed = !grammar::on || !whole_word;
    let found = if grammar::on && !whole_word { best_line(w, input, end, path) } else { best_path(w, input, end, path) };
    if found {
        var k = path.len - 1;
        while k >= 0 {
            m.path.push(path[k] as u32);
            k--;
        }
    }
    if path.len > 1 && sentence_allowed {
        for i in m.path { sentence.push(i); }
        if remember {
            var span: u8[>..] = [];
            typed_span(input, begin, end, span);
            var text: u8[>..] = [];
            for i in sentence { word_text(w.list[i], text); }
            sentence_chosen = userdb::chosen(span, text);
        }
    }
    var items: Item[>..] = [];
    for i in w.list.len {
        let word = w.list[i];
        if word.source == ENGLISH || word.from != begin || word.to > end || !rest_reads[word.to] { continue; }
        var chosen: i64 = 0;
        if remember {
            var span: u8[>..] = [];
            typed_span(input, begin, word.to, span);
            var text: u8[>..] = [];
            word_text(word, text);
            chosen = userdb::chosen(span, text);
        }
        items.push(Item { word: i, chosen: chosen });
    }
    sort(items) { a, b =>
        let x = w.list[a.word];
        let y = w.list[b.word];
        x.to > y.to || (x.to == y.to && (a.chosen > b.chosen || (a.chosen == b.chosen && x.score > y.score)))
    };
    var sentence_offered = sentence.len == 0;
    for item in items {
        let word = w.list[item.word];
        if !sentence_offered && (word.to < end || item.chosen <= sentence_chosen) {
            offer(m, seen, w, sentence, end);
            sentence_offered = true;
        }
        let one: i64[1] = [item.word];
        offer(m, seen, w, one, word.to);
    }
    if !sentence_offered { offer(m, seen, w, sentence, end); }
    return end;
}

// ---- mixed sentences: Chinese and English words over the same keys ----------------
// (docs/mixed-input-design.md)

// A partial mixed sentence, ending where its last word ends. It starts at
// its first English word; the Chinese before that is the front's reading.
//   prev              the state it extends, or -1 for a first English word
//   word              its last word (an index into Words.list); last_en: English
//   zh_prev           the Chinese word before a Chinese last word, or -1
//   zh_at             the Chinese word before an English last word, or -1
//   anchor            where its first English word starts
//   saw_zh            it has a Chinese word, which a mixed sentence needs
//   tail, tail_head   the front's last syllable re-read for that first
//                     English word, and what stays before it (reread_tail)
struct Mx { prev: i32, word: i32, score: f64, last_en: u8, zh_prev: i32, zh_at: i32, anchor: i32, saw_zh: u8, tail: i32, tail_head: i32 }

// The last character of `text`.
fn last_char(text: const u8[:]) -> const u8[:] {
    var at = text.len;
    while at > 0 {
        at--;
        if (text[at] & 0xC0) != 0x80 { break; }
    }
    return text[at..];
}

// How well `head` is followed by a Chinese sense of an English word (`row`,
// its senses in the table): the best of them, each less by its prior.
fn sense_follow(row: i64, head: const u8[:]) -> f64 {
    let head_hash = hash(head);
    var best = NONE;
    for i in semantic::count(row) {
        let sense = semantic::sense(row, i);
        let g = fit(head, head_hash, sense, hash(sense), false) + SENSE_PRIOR * semantic::prior(row, i);
        if g > best { best = g; }
    }
    return best;
}

// How well `word` reads after a Chinese sense of that English word, with
// `left`, the Chinese before the English word (a blank for none), before it.
fn sense_lead(row: i64, left: const u8[:], word: const u8[:], word_hash: u64, rear: bool) -> f64 {
    var best = NONE;
    var shadow: u8[>..] = [];
    for i in semantic::count(row) {
        shadow.clear();
        if left.len > 0 && left != " " { shadow.append(left); }
        shadow.append(semantic::sense(row, i));
        let g = fit(shadow, hash(shadow), word, word_hash, rear) + SENSE_PRIOR * semantic::prior(row, i);
        if g > best { best = g; }
    }
    return best;
}

// Keeps word i among `picks` if it is one of the `cap` best so far, in place
// of the worst of them; the others stay where they are.
fn keep_best(w: Words&, picks: i64[>..]&, i: i64, cap: i64) {
    if picks.len < cap {
        picks.push(i);
        return;
    }
    var worst: i64 = 0;
    for t in 1..picks.len {
        if w.list[picks[t]].score < w.list[picks[worst]].score { worst = t; }
    }
    if w.list[i].score > w.list[picks[worst]].score { picks[worst] = i; }
}

// The syllable ending where the English word starts was chosen before that
// word was known, and a longer word such as 你和 hides it. Re-reads only that
// syllable by how well it precedes a sense of the English word: 喝咖啡, not
// how common 你和 is. A typed capital is left alone: Python and Apple keep
// their names. Returns the word to read there instead, the word that stays
// before it when the front's last word was longer than the syllable (-1 for
// none), and the bits gained; -1, -1, 0 to leave the front as it is.
fn reread_tail(w: Words&, input: const u8[:], en: Word, from: i64) -> i32, i32, f64 {
    guard from < front_n.len && front_n[from] > 0 else { return -1, -1, 0.0; }
    let en_from: i64 = en.from;
    let en_end: i64 = en.end;
    guard en_end > en_from && en_end <= input.len && !span_capital(en_from, en_end - en_from) else { return -1, -1, 0.0; }
    let row = semantic::find_row(input[en_from..en_end]);
    guard row >= 0 else { return -1, -1, 0.0; }
    let last: i64 = front_ids[front_at[from] + front_n[from] - 1];
    guard last >= 0 && last < w.list.len else { return -1, -1, 0.0; }
    let lw = w.list[last];
    guard lw.source != ENGLISH && lw.to == from else { return -1, -1, 0.0; }
    var mark: u8[>..] = [];
    word_text(lw, mark);
    let syllable = last_char(mark);
    // Where the front's last syllable starts: where a word that is just its
    // character does.
    var one: u8[>..] = [];
    var syl: i64 = lw.from;
    var found = false;
    for p in from {
        let lo, hi = span(w, p, from);
        for k in lo..hi {
            one.clear();
            word_text(w.list[w.by_span[k]], one);
            if syllable.len > 0 && one == syllable { found = true; break; }
        }
        if found {
            syl = p;
            break;
        }
    }
    // The syllable's best readings, in the order they were found, and among
    // them the one the front has: its last word, or, when that word is
    // longer than the syllable, the last of them that is its last character.
    var picks: i64[>..] = [];
    let lo, hi = span(w, syl, from);
    for k in lo..hi { keep_best(w, picks, w.by_span[k], grammar::homophones()); }
    var orig: i64 = -1;
    if lw.from == syl {
        orig = last;
        if !contains(picks, last) { picks.push(last); }
    } else {
        for pick in picks {
            one.clear();
            word_text(w.list[pick], one);
            if syllable.len > 0 && one == syllable { orig = pick; }
        }
    }
    guard orig >= 0 else { return -1, -1, 0.0; }
    one.clear();
    word_text(w.list[orig], one);
    let orig_right = sense_follow(row, one);
    var best: i64 = -1;
    var gain = 0.0;
    for pick in picks {
        one.clear();
        word_text(w.list[pick], one);
        let d = w.list[pick].score - w.list[orig].score + (sense_follow(row, one) - orig_right);
        if d > gain {
            gain = d;
            best = pick;
        }
    }
    guard best >= 0 && best != orig else { return -1, -1, 0.0; }
    if lw.from == syl { return best as i32, -1, gain; }
    // The front's last word was longer: its best reading up to the syllable stays.
    var head: i64[>..] = [];
    let head_lo, head_hi = span(w, lw.from, syl);
    best_of(w, head_lo, head_hi, 1, head);
    return best as i32, if head.len > 0 { head[0] as i32 } else { -1 }, gain;
}

fn reached_front(p: i64) -> bool { p >= 0 && p < front_score.len && front_score[p] > NONE / 2.0 }

// Two states may share a slot only when every later extension adds the same
// delta to both. The backpointer, the anchor and the substituted tail change
// the text already built, not the score of a word that has not been read yet.
fn same_future(a: Mx, b: Mx) -> bool {
    if a.last_en != b.last_en { return false; }
    if a.last_en != 0 { return a.word == b.word && a.zh_at == b.zh_at; }
    return a.word == b.word && a.zh_prev == b.zh_prev;
}

// Strict: a higher score wins, and a tie keeps the earlier word index. Equal
// scores therefore do not swap, so the survivor of a tie does not depend on
// which path was inserted last.
fn prefer_state(a: Mx, b: Mx) -> bool {
    if a.score != b.score { return a.score > b.score; }
    if a.word != b.word { return a.word < b.word; }
    let ak: i32 = if a.last_en != 0 { a.zh_at } else { a.zh_prev };
    let bk: i32 = if b.last_en != 0 { b.zh_at } else { b.zh_prev };
    return ak < bk;
}

// Adds state `st`, ending at `to`, to that position's list (heads[to], linked
// through next): in place of a state with the same future if it is better
// than that one, else as one of the position's mixed_beam best.
fn consider_mx(states: Mx[>..]&, next: i32[>..]&, heads: i32[>..]&, to: i64, st: Mx) {
    guard to >= 0 && to < heads.len else { return; }
    var c: i64 = heads[to];
    var n: i64 = 0;
    var worst: i64 = -1;
    while c >= 0 && c < states.len {
        let cur = states[c];
        if same_future(st, cur) {
            if prefer_state(st, cur) { states[c] = st; }
            return;
        }
        if worst < 0 || prefer_state(states[worst], cur) { worst = c; }
        n++;
        c = next[c];
    }
    if n >= mixed_beam {
        if worst >= 0 && prefer_state(st, states[worst]) { states[worst] = st; }
        return;
    }
    states.push(st);
    next.push(heads[to]);
    heads[to] = (states.len - 1) as i32;
}

fn set_mixed_beam(n: i64) {
    if n >= 1 { mixed_beam = n; }
}

// What the grammar model is asked about the next Chinese word of state `s`:
// after Chinese, its last two words; across an English word, the one Chinese
// word before it (so a sentence-final syllable can still be told apart; the
// word before that stays out, and the English text is not context), or a
// blank when there is none.
fn mixed_context(w: Words&, s: Mx, ctx: u8[>..]&) {
    ctx.clear();
    if s.last_en == 0 {
        if s.zh_prev >= 0 { word_text(w.list[s.zh_prev], ctx); }
        word_text(w.list[s.word], ctx);
    } else if s.zh_at >= 0 && s.zh_at < w.list.len {
        word_text(w.list[s.zh_at], ctx);
    } else {
        ctx.push(' ');
    }
}

// The best sentence over the whole input made of both Chinese and English
// words (`english`: the English ones in w.list): its words, first first, in
// `words`, and its score. False if there is none.
//
// A beam over the input's positions. A state is a sentence from its first
// English word on; before that word it is the Chinese front's best reading
// (front_*), so the Chinese search is not repeated here. Each state at a
// position is extended by the Chinese words the position offers and by the
// English words that start there, scored as the Chinese beam scores them
// plus what crossing between the two languages costs.
fn mixed_sentence(w: Words&, input: const u8[:], english: const i64[:], words: i64[>..]&) -> f64, bool {
    let n = input.len;
    let begin = skip_separators(input, 0);
    // As in the Chinese search, the model scores a sentence only when no
    // one word reads the whole input.
    let whole_lo, whole_hi = span(w, begin, n);
    let use_fit = grammar::on && whole_lo == whole_hi;
    let homophones = grammar::homophones();
    var states: Mx[>..] = [];
    var next: i32[>..] = [];
    var heads: i32[>..] = [];
    for p in n + 1 { heads.push(-1); }

    // A sentence's first English word: at the start of the input, or after
    // the front's reading up to it.
    for ei in english {
        let word = w.list[ei];
        let from: i64 = word.from;
        let to: i64 = word.to;
        if to <= from || to > n || (from == begin && to == n) { continue; }  // alone it is place_english's
        let after_chinese = from != begin;
        if after_chinese && !reached_front(from) { continue; }
        var score = (if after_chinese { front_score[from] } else { 0.0 }) + word.score;
        var zh_at: i32 = -1;
        var tail: i32 = -1;
        var tail_head: i32 = -1;
        if after_chinese {
            score += EN_SWITCH;
            if front_n[from] > 0 { zh_at = front_ids[front_at[from] + front_n[from] - 1]; }
            let reread, head, gain = reread_tail(w, input, word, from);
            if reread >= 0 { zh_at = reread; }
            tail = reread;
            tail_head = head;
            score += gain;
        }
        consider_mx(states, next, heads, to, Mx { prev: -1, word: ei as i32, score: score, last_en: 1, zh_prev: -1,
                                                   zh_at: zh_at, anchor: from as i32,
                                                   saw_zh: if after_chinese { 1 } else { 0 }, tail: tail,
                                                   tail_head: tail_head });
    }

    let blank_hash = hash(" ");
    var here: i32[>..] = [];
    var offered: i64[>..] = [];
    var pool: u8[>..] = [];                 // the offered words' texts: pool[text_at[k]..text_at[k + 1]]
    var text_at: i64[>..] = [];
    var ctx: u8[>..] = [];
    for p in n {
        here.clear();
        var c: i64 = heads[p];
        while c >= 0 {
            here.push(c as i32);
            c = next[c];
        }
        if here.len == 0 { continue; }
        offered.clear();
        pool.clear();
        text_at.clear();
        offers(w, p, homophones, offered);
        for i in offered {
            text_at.push(pool.len);
            word_text(w.list[i], pool);
        }
        text_at.push(pool.len);
        for s_i in here {
            let s = states[s_i];
            mixed_context(w, s, ctx);
            let ctx_hash = hash(ctx);
            // After an English word: its Chinese senses, if the table has any.
            var senses: i64 = -1;
            var lifts = false;
            if s.last_en != 0 {
                let en_from: i64 = w.list[s.word].from;
                let en_end: i64 = w.list[s.word].end;
                senses = semantic::find_row(input[en_from..en_end]);
                lifts = senses >= 0 && !span_capital(en_from, en_end - en_from);
            }
            var span_to: i64 = -1;
            var span_best = 0.0;
            for k in offered.len {
                let wi = offered[k];
                let word = w.list[wi];
                let to: i64 = word.to;
                if to != span_to {              // a span's words come best first
                    span_to = to;
                    span_best = word.score;
                }
                let text = pool[text_at[k]..text_at[k + 1]];
                var score = s.score + word.score;
                if s.last_en != 0 { score += EN_SWITCH; }
                if use_fit {
                    let rear = to == n;
                    let text_hash = hash(text);
                    var g = 0.0;
                    if s.last_en == 0 {
                        g = fit(ctx, ctx_hash, text, text_hash, rear);
                    } else {
                        // Across English, a collocation may break a near tie
                        // (吧 against 把) and may not overturn a clearer unigram.
                        g = fit(" ", blank_hash, text, text_hash, rear);
                        if word.score + 0.5 >= span_best && ctx.len > 0 && ctx[0] != ' ' {
                            let collocation = fit(ctx, ctx_hash, text, text_hash, rear);
                            if collocation > g { g = collocation; }
                        }
                    }
                    score += fit_weight * g;
                    // The word may read better after a Chinese sense of the
                    // English word than after the context scored above.
                    if lifts {
                        var lift = sense_lead(senses, ctx, text, text_hash, rear) - g;
                        if lift > SEM_LIFT { lift = SEM_LIFT; }
                        if lift > 0.0 { score += lift; }
                    }
                    // 吧 closing the input, after a word that has a Chinese sense,
                    // is the sentence-final particle. Bounded, and only at the end.
                    if rear && senses >= 0 && text == "吧" { score += EN_FINAL_BA; }
                    if emit_on { score += emit_weight * emission(input, word.from, to, text); }
                }
                if s.last_en == 0 { score += mixed_boost(w, s.zh_prev, s.word, wi); }
                consider_mx(states, next, heads, to, Mx { prev: s_i, word: wi as i32, score: score, last_en: 0,
                                                          zh_prev: if s.last_en == 0 { s.word } else { -1 }, zh_at: -1,
                                                          anchor: s.anchor, saw_zh: 1, tail: s.tail,
                                                          tail_head: s.tail_head });
            }
            for ei in english {
                let word = w.list[ei];
                if word.from != p { continue; }
                var score = s.score + word.score;
                if s.last_en == 0 { score += EN_SWITCH; }
                consider_mx(states, next, heads, word.to, Mx { prev: s_i, word: ei as i32, score: score, last_en: 1,
                                                               zh_prev: -1,
                                                               zh_at: if s.last_en == 0 { s.word } else { s.zh_at },
                                                               anchor: s.anchor, saw_zh: s.saw_zh, tail: s.tail,
                                                               tail_head: s.tail_head });
            }
        }
    }

    var best: i64 = -1;
    var c: i64 = heads[n];
    while c >= 0 {
        if states[c].saw_zh != 0 && (best < 0 || states[c].score > states[best].score) { best = c; }
        c = next[c];
    }
    guard best >= 0 else { return NONE, false; }
    // Its words: the front's reading up to the first English word, with its
    // last syllable re-read if that helped, then the states' words.
    let st = states[best];
    let anchor: i64 = st.anchor;
    if anchor > begin && reached_front(anchor) {
        let a: i64 = front_at[anchor];
        let count: i64 = front_n[anchor];
        if st.tail >= 0 && count > 0 {
            for k in a..a + count - 1 { words.push(front_ids[k]); }
            if st.tail_head >= 0 { words.push(st.tail_head); }
            words.push(st.tail);
        } else {
            for k in a..a + count { words.push(front_ids[k]); }
        }
    }
    let chain = words.len;
    var at = best;
    while at >= 0 {
        words.push(states[at].word);
        at = states[at].prev;
    }
    reverse(words[chain..]);
    return st.score, true;
}

// Where the mixed sentence `text` (`words`, scoring `score`) goes in the
// menu: 0 for first, 2 for the first page behind the Chinese, -1 for nowhere.
fn mixed_place(m: Menu&, w: Words&, input: const u8[:], words: const i64[:], keys: const u8[:], text: const u8[:],
               score: f64) -> i64 {
    // A word of four letters or fewer is also a pile of pinyin: it can sit
    // on the page, and takes first only with a capital. An unfinished
    // completion is only a bridge while the word is being typed, and does
    // not take first place over a Chinese reading either.
    var short_en = false;
    var shown: u8[>..] = [];
    for i in words {
        let word = w.list[i];
        if word.source != ENGLISH { continue; }
        let typed: i64 = word.end - word.from;
        if typed < 5 && !span_capital(word.from, typed) { short_en = true; }
        shown.clear();
        english::spelling(word.entry, shown);
        var letters: i64 = 0;
        for c in shown { if ascii::is_alpha(c) { letters++; } }
        if letters > typed { short_en = true; }
    }
    var slot: i64 = -1;
    if !reached_front(input.len) {
        slot = if short_en { 2 } else { 0 };    // Chinese cannot read the keys (github)
    } else {
        let lead = score - front_score[input.len];
        if lead >= EN_TOP1 && !short_en { slot = 0; }
        else if lead >= EN_PAGE { slot = 2; }
    }
    // What the user chose for these keys before outranks all of that.
    let mixed_chosen = userdb::chosen(keys, text);
    var chinese_chosen: i64 = 0;
    if m.candidates.len > 0 && m.candidates[0].to == input.len {
        chinese_chosen = userdb::chosen(keys, candidate_text(m, m.candidates[0]));
    }
    if mixed_chosen > 0 && mixed_chosen >= chinese_chosen { slot = 0; }
    else if chinese_chosen > mixed_chosen && slot == 0 { slot = 2; }
    else if mixed_chosen > 0 && slot < 0 { slot = 2; }
    return slot;
}

// Puts the best mixed sentence into the menu the Chinese search assembled.
// True when it became the first candidate: its words are then the menu's
// path, which the preedit and the word make_room commits follow.
fn place_mixed(m: Menu&, w: Words&, input: const u8[:]) -> bool {
    var english: i64[>..] = [];
    for i in w.list.len { if w.list[i].source == ENGLISH { english.push(i); } }
    guard english.len > 0 && input.len > 0 && front_score.len == input.len + 1 else { return false; }
    // The whole input is one English word: place_english owns the spelling,
    // the case, and where it sits. A mixed split would only break that.
    var keys: u8[>..] = [];
    typed_span(input, skip_separators(input, 0), input.len, keys);
    if english::exact(keys) >= 0 { return false; }
    var words: i64[>..] = [];
    let score, found = mixed_sentence(w, input, english, words);
    guard found && words.len > 1 else { return false; }
    var text: u8[>..] = [];
    append_words(w, words, text);
    guard text.len > 0 && text.len <= 65535 else { return false; }
    var slot = mixed_place(m, w, input, words, keys, text, score);
    guard slot >= 0 else { return false; }
    // A custom shortcut for these keys stays first.
    if slot == 0 && m.candidates.len > 0 && m.candidates[0].count == 0 && m.candidates[0].code_len == 0 { slot = 1; }
    let existing = find_candidate(m, text);
    if existing != slot {
        if existing >= 0 {
            remove_at(m.candidates, existing);
            if existing < slot { slot--; }
        }
        if slot > m.candidates.len { slot = m.candidates.len; }
        insert_candidate(m, slot, sentence_candidate(m, w, words, text, input.len));
    }
    if slot == 0 {
        m.path.clear();
        for i in words { m.path.push(i as u32); }
    }
    return slot == 0;
}

// A span of the best reading. For Chinese, input[from..to] reads through
// edges[edge] as syllable `depth` of the word `word` (an index into Words.list).
// For English, the span is the whole word and `edge` and `depth` are unused.
struct Segment { from: u8, to: u8, edge: u32, word: u32, depth: u8 }

// Recover the best reading's spans in order. Only its Chinese words need
// to be matched against the graph again.
fn segments(m: Menu&, w: Words&, g: lattice::Graph&, input: const u8[:], include_english: bool, out: Segment[>..]&) {
    out.clear();
    for i in m.path {
        let word = w.list[i];
        if word.source == ENGLISH {
            if include_english {
                out.push(Segment { from: word.from, to: word.end, edge: 0, word: i, depth: 0 });
            }
            continue;
        }
        var edges: u32[>..] = [];
        let found = match_edges(g, source_lexicon(word.source), word.entry, input, word.from, 0, word.to, edges);
        if !found { continue; }
        var at: i64 = word.from;
        for d in edges.len {
            let edge = g.edges[edges[d]];
            out.push(Segment { from: skip_separators(input, at) as u8, to: edge.to, edge: edges[d], word: i,
                               depth: d as u8 });
            at = edge.to;
        }
    }
}

// Can entry i's syllables from `depth` on be read from input position `at`
// to exactly `to`? If so, `edges` holds the edge read for each syllable.
recursive fn match_edges(g: lattice::Graph&, lex: lexicon::Lexicon&, i: i64, input: const u8[:], at: i64,
                         depth: i64, to: i64, edges: u32[>..]&) -> bool {
    let p = skip_separators(input, at);
    let e = lex.entries[i];
    if depth == e.len { return p == to; }
    if p >= input.len || p >= lattice::MAX_INPUT { return false; }
    let s = lexicon::syl(lex, e, depth);
    for k in g.first_edge[p]..g.first_edge[p + 1] {
        let edge = g.edges[k];
        var has = false;
        for j in edge.syls..edge.syls + edge.count {
            if g.syls[j].plain == s { has = true; break; }
        }
        if !has { continue; }
        edges.push(k as u32);
        if match_edges(g, lex, i, input, edge.to, depth + 1, to, edges) { return true; }
        edges.pop();
    }
    return false;
}
