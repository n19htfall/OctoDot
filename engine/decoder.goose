// From a syllable graph to candidates: every dictionary word readable from
// each position, the best sentence through them, and the menu a user picks
// from. The decoder is one namespace in five files:
//
//   decoder.goose            the words a search finds, and their index by span
//   decoder_english.goose    the English words over the same letters
//   decoder_sentence.goose   the best Chinese sentences through the words
//   decoder_mixed.goose      the best sentence of Chinese and English words
//   decoder_menu.goose       the menu: the sentence, then the words to pick from
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
import lexicon;
import lattice;
import auxcode;
import userdb;
import sets;
import grammar;
import english;
import decoder_english;

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
let NONE = -1.0e30;         // the score of what cannot be read

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

// What a search found, and what the sentence searches over it leave behind.
//   list       the words, in order of where they start
//   checks     search's own: the constraints on the path being walked
//   by_span    the Chinese words by span: those that start at p are
//              by_span[span_at[p]..span_at[p + 1]], by where they end
//              (index_spans); offers and best_of pick a span's best from it
//   front_*    the Chinese front: the best pure-Chinese score at each input
//              position (NONE where no reading reaches) and the words that
//              reach it, first first, front_ids[front_at[p]..front_at[p] +
//              front_n[p]]. Left by the last Chinese sentence search
//              (best_path, kbest_sentences); the mixed search starts from it.
root struct Words {
    list: Word[>..] = [],
    checks: Check[>..] = [],
    by_span: u32[>..] = [],
    span_at: u32[>..] = [],
    front_score: f64[>..] = [],
    front_at: i32[>..] = [],
    front_n: i32[>..] = [],
    front_ids: i32[>..] = []
}

fn clear_words(w: Words&) {
    w.list.clear();
    w.checks.clear();
    w.by_span.clear();
    w.span_at.clear();
    reset_front(w, 0);
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
                    if lex.nodes[m].syl < t { a = m + 1; } else { b = m; }
                }
                if a >= nb || lex.nodes[a].syl != t { continue; }
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

// input[begin..to] as typed, without separators: the key choices are kept by.
fn typed_span(input: const u8[:], begin: i64, to: i64, out: u8[>..]&) {
    for c in input[begin..to] { if c != '\'' { out.push(c); } }
}
