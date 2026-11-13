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
let SEM_LIFT = 8.0;          // most a Chinese sense of an English word may add over the score it already has
let EN_PAGE = 2.0;           // ...to stay on the first page, behind the Chinese
let EN_THREE = 100;          // a lowercase 3-letter word must be at least this common
let MAX_EN_EDGES = 48;
var mixed_beam: i64 = 4;
// How many English edges the scan found, kept, and refused for the quota.
var en_seen: i64 = 0;
var en_kept: i64 = 0;
var en_quota: i64 = 0;

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

root struct Words {
    list: Word[>..] = [],
    checks: Check[>..] = []
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

fn skip_separators(input: const u8[:], at: i64) -> i64 {
    var p = at;
    while p < input.len && input[p] == '\'' { p++; }
    return p;
}

// Every word readable from every position, in order of position.
fn search(w: Words&, g: lattice::Graph&, lex: lexicon::Lexicon&, input: const u8[:]) {
    if sets::log_total == 0.0 { sets::retotal(); }
    let log_total = sets::log_total;
    if english::active() { english::begin_spellings(); }
    let begin = skip_separators(input, 0);
    for start in input.len {
        if input[start] != '\'' && g.first_edge[start] != g.first_edge[start + 1] {
        var budget: i64 = if start == begin { MAX_GROUPS } else { MAX_GROUPS_INSIDE };
        walk(w, g, lex, LEXICON, input, start, start, 0, 0, lex.entries.len, 0.0, log_total, start == begin, budget);
        if userdb::lex.entries.len > 0 {
            var user_budget: i64 = MAX_GROUPS_INSIDE;
            walk(w, g, userdb::lex, USER, input, start, start, 0, 0, userdb::lex.entries.len, 0.0, log_total,
                 start == begin, user_budget);
        }
        for k in sets::SLOTS {
            if !sets::used[k] { continue; }
            var set_budget: i64 = MAX_GROUPS_INSIDE;
            walk(w, g, sets::slot(k), SET + k, input, start, start, 0, 0, sets::slot(k).entries.len, 0.0, log_total,
                 start == begin, set_budget);
        }
        }
    }
    if english::active() { add_english_edges(w, g, input); }
}

// Extends the words in [lo, hi), which share `depth` syllables read so far,
// by every edge from `at`. An edge's syllables come in runs of consecutive
// ids; each run narrows the range at once, which then splits into one group
// per syllable actually present, so an abbreviation costs what it finds.
fn is_letter(c: u8) -> bool { c >= 'a' && c <= 'z' }

fn span_capital(from: i64, len: i64) -> bool {
    guard typed_case.len > from + len - 1 else { return false; }
    for i in from..from + len { if typed_case[i] != 0 { return true; } }
    return false;
}

// A 小鹤 key pair that this start cuts in two, so the syllable before it
// would be left as a single key.
fn cuts_pair(g: lattice::Graph&, input: const u8[:], from: i64) -> bool {
    guard spelling::live.meta.len == 1 && spelling::live.meta[0].preedit == spelling::PREEDIT_SYLLABLES else { return false; }
    guard from > 0 && from < input.len && is_letter(input[from - 1]) && is_letter(input[from]) else { return false; }
    let p = from - 1;
    guard p + 1 < g.first_edge.len else { return false; }
    for k in g.first_edge[p]..g.first_edge[p + 1] {
        let e = g.edges[k];
        if e.kind > spelling::FUZZY { continue; }
        var letters: i64 = 0;
        var i: i64 = e.from;
        while i < e.to && i < input.len && is_letter(input[i]) {
            letters++;
            i++;
        }
        if letters >= 2 && (e.from as i64) < from && i > from { return true; }
    }
    return false;
}

fn isolated_span(input: const u8[:], from: i64, end: i64) -> bool {
    let left = from == 0 || input[from - 1] == '\'';
    let right = end == input.len || (end < input.len && input[end] == '\'');
    return left && right;
}

fn short_listed(code: const u8[:]) -> bool {
    compare(code, "ai") == 0 || compare(code, "ok") == 0 || compare(code, "ui") == 0 ||
        compare(code, "pc") == 0 || compare(code, "tv") == 0
}

fn en_local(dict: i64, len: i64, capital: bool, prefix: bool) -> f64 {
    var s = EN_ALPHA * english::bits(dict) + EN_BETA * (len as f64) + EN_BIAS;
    if capital { s += EN_GAMMA; }
    if prefix { s -= EN_PREFIX_PENALTY; }
    return s;
}

fn cased_letters(input: const u8[:], from: i64, end: i64, out: u8[>..]&) {
    out.clear();
    let marked = typed_case.len == input.len;
    for p in from..end {
        let c = input[p];
        out.push(if marked && typed_case[p] != 0 && c >= 'a' && c <= 'z' { c - 32 } else { c });
    }
}

// An English word the scan may keep. `prefix` is the one unfinished tail.
struct EnCand { from: u8, end: u8, to: u8, spell: u32, score: f32 }

fn admit_english(input: const u8[:], from: i64, len: i64, dict: i64, cut: bool) -> bool {
    let capital = span_capital(from, len);
    if cut && len < 4 && !capital { return false; }
    if len >= 4 { return true; }
    if len == 3 { return capital || english::entry_at(dict).weight >= EN_THREE; }
    if capital || isolated_span(input, from, from + len) { return true; }
    return short_listed(english::entry_at(dict).code);
}

fn push_english(input: const u8[:], from: i64, len: i64, dict: i64, prefix: bool, out: EnCand[>..]&) {
    guard from + len <= input.len && out.len + 8 < MAX_WORDS else { return; }
    var typed: u8[>..] = [];
    cased_letters(input, from, from + len, typed);
    var text: u8[>..] = [];
    if prefix {
        english::top_form(dict, text);
        if span_capital(from, len) && text.len > 0 {
            var cased: u8[>..] = [];
            english::apply_case(text, typed, cased);
            text.clear();
            text.append(cased);
        }
    } else {
        english::prefer(dict, typed, text);
    }
    guard text.len > 0 && text.len <= 65535 else { return; }
    let end = from + len;
    let to = skip_separators(input, end);
    let id = english::note(text);
    out.push(EnCand { from: from as u8, end: end as u8, to: to as u8, spell: id as u32,
                      score: en_local(dict, len, span_capital(from, len), prefix) as f32 });
}

// Exact English words over the raw letters, from the start of the input, from
// where a Chinese word ends, and from where an English word ends. In 小鹤 a
// start may also fall inside a key pair, and then only a longer word or a
// capital is kept. One unfinished prefix may cover the tail being typed.
fn add_english_edges(w: Words&, g: lattice::Graph&, input: const u8[:]) {
    en_seen = 0;
    en_kept = 0;
    en_quota = 0;
    guard input.len > 0 && input.len <= lattice::MAX_INPUT else { return; }
    var start: u8[lattice::MAX_INPUT + 1] = [0; lattice::MAX_INPUT + 1];
    var used: u8[lattice::MAX_INPUT + 1] = [0; lattice::MAX_INPUT + 1];
    let origin = skip_separators(input, 0);
    start[origin] = 1;
    for word in w.list {
        if word.source == ENGLISH { continue; }
        if (word.to as i64) <= input.len { start[word.to] = 1; }
    }
    let pairs = spelling::live.meta.len == 1 && spelling::live.meta[0].preedit == spelling::PREEDIT_SYLLABLES;
    if pairs {
        for p in 1..input.len { if cuts_pair(g, input, p) { start[p] = 1; } }
    }
    var extra: EnCand[>..] = [];
    var prefix_at: i64 = -1;
    var guard_n: i64 = 0;
    while guard_n < 8 {
        guard_n++;
        var added: i64 = 0;
        var fresh: u8[lattice::MAX_INPUT + 1] = [0; lattice::MAX_INPUT + 1];
        for from in input.len {
            if start[from] == 0 || used[from] != 0 || !is_letter(input[from]) { continue; }
            used[from] = 1;
            var run: i64 = 0;
            while from + run < input.len && is_letter(input[from + run]) && run < english::MAX_CODE { run++; }
            if run < 2 { continue; }
            let cut = pairs && cuts_pair(g, input, from);
            let slice = input[from..from + run];
            for len in 2..run + 1 {
                if len >= 3 && !english::head_has(slice[0], slice[1], slice[2]) { break; }
                if extra.len >= MAX_EN_EDGES * 4 { break; }
                let dict = english::exact(slice[..len]);
                if dict < 0 || !admit_english(input, from, len, dict, cut) { continue; }
                en_seen++;
                let before = extra.len;
                push_english(input, from, len, dict, false, extra);
                if extra.len > before {
                    added++;
                    let to: i64 = extra[extra.len - 1].to;
                    if to < input.len && start[to] == 0 && used[to] == 0 { fresh[to] = 1; }
                }
            }
        }
        var any = false;
        for p in input.len {
            if fresh[p] != 0 { start[p] = 1; any = true; }
        }
        if !any || added == 0 { break; }
    }
    // The tail being typed: at most one completion, so the first candidate
    // does not flicker while the last letters of a word are still missing.
    var best_prefix = -1.0e30;
    var best_from: i64 = -1;
    var best_dict: i64 = -1;
    var best_len: i64 = 0;
    for from in input.len {
        if used[from] == 0 || !is_letter(input[from]) { continue; }
        var run: i64 = 0;
        while from + run < input.len && is_letter(input[from + run]) { run++; }
        if from + run != input.len || run < 4 || run > english::MAX_CODE { continue; }
        let slice = input[from..from + run];
        if english::exact(slice) >= 0 { continue; }
        if !english::head_has(slice[0], slice[1], slice[2]) { continue; }
        var ids: i64[>..] = [];
        english::completions(slice, 1, ids);
        if ids.len == 0 { continue; }
        let cut = pairs && cuts_pair(g, input, from);
        if cut && !span_capital(from, run) { continue; }
        let local = en_local(ids[0], run, span_capital(from, run), true);
        if local > best_prefix {
            best_prefix = local;
            best_from = from;
            best_dict = ids[0];
            best_len = run;
        }
    }
    if best_dict >= 0 {
        let before = extra.len;
        push_english(input, best_from, best_len, best_dict, true, extra);
        if extra.len > before { prefix_at = extra.len - 1; }
    }
    if extra.len == 0 { return; }
    if extra.len > MAX_EN_EDGES {
        en_quota++;
        var order: i64[>..] = [];
        for i in extra.len { if i != prefix_at { order.push(i); } }
        sort(order) { a, b => extra[a].score > extra[b].score };
        let room: i64 = if prefix_at >= 0 { MAX_EN_EDGES - 1 } else { MAX_EN_EDGES };
        var kept: EnCand[>..] = [];
        for i in order.len {
            if kept.len >= room { break; }
            kept.push(extra[order[i]]);
        }
        if prefix_at >= 0 { kept.push(extra[prefix_at]); }
        extra.clear();
        extra.append(kept);
    }
    en_kept = extra.len;
    var words: Word[>..] = [];
    for e in extra {
        words.push(Word { from: e.from, end: e.end, to: e.to, source: ENGLISH, entry: e.spell,
                          score: e.score });
    }
    var merged: Word[>..] = [];
    var i: i64 = 0;
    var j: i64 = 0;
    while i < w.list.len || j < words.len {
        let take = j < words.len && (i >= w.list.len || words[j].from < w.list[i].from);
        if take { merged.push(words[j]); j++; } else { merged.push(w.list[i]); i++; }
    }
    w.list.clear();
    w.list.append(merged);
}

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
// words reaches from its start.
fn readable(w: Words&, input: const u8[:]) -> i64 {
    var reached: bool[lattice::MAX_INPUT + 1] = [false; lattice::MAX_INPUT + 1];
    let begin = skip_separators(input, 0);
    reached[begin] = true;
    var far = begin;
    for word in w.list {                    // words come in order of where they start
        if reached[word.from] {
            reached[word.to] = true;
            if word.to > far { far = word.to; }
        }
    }
    return far;
}

// How far Chinese words alone reach, ignoring English spans. Rule 1 of
// English placement: no complete Chinese reading of the whole input.
fn chinese_reach(w: Words&, input: const u8[:]) -> i64 {
    var reached: bool[lattice::MAX_INPUT + 1] = [false; lattice::MAX_INPUT + 1];
    let begin = skip_separators(input, 0);
    reached[begin] = true;
    var far = begin;
    for word in w.list {
        if word.source == ENGLISH { continue; }
        if reached[word.from] {
            reached[word.to] = true;
            if word.to > far { far = word.to; }
        }
    }
    return far;
}

// The best sentence over input[..end]: its words, last first, in `path`;
// false if it cannot be read through to `end`.
fn surface_of(w: Words&, i: i64) -> u64 {
    if i < 0 { return 0; }
    let word = w.list[i];
    if word.source == ENGLISH { return 0; }
    return userdb::hash_surface_entry(source_lexicon(word.source), word.entry);
}

fn context_boost(w: Words&, anterior: i64, prev: i64, current: i64) -> f64 {
    if userdb::pom.len == 0 { return 0.0; }
    var prev_h: u64 = 0;
    var ant_h: u64 = 0;
    if prev >= 0 {
        prev_h = surface_of(w, prev);
        if prev_h == 0 { return 0.0; }
        ant_h = if anterior >= 0 { surface_of(w, anterior) } else { userdb::carry_prev };
    } else {
        prev_h = userdb::carry_prev;
        ant_h = userdb::carry_ant;
    }
    if prev_h == 0 { return 0.0; }
    let word = w.list[current];
    if word.source == ENGLISH { return 0.0; }
    let lex = source_lexicon(word.source);
    let len = lex.entries[word.entry].len;
    return userdb::recall(prev_h, ant_h, userdb::hash_reading_entry(lex, word.entry), len);
}

// Best pure-Chinese score at each input position, and the words that reach
// it (first first). Recorded by whichever search assembled the menu.
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

fn store_front(at: i64, score: f64, words: i32[>..]&) {
    guard at >= 0 && at < front_score.len else { return; }
    front_score[at] = score;
    front_at[at] = front_ids.len as i32;
    front_n[at] = words.len as i32;
    front_ids.append(words);
}

fn note_viterbi(w: Words&, input: const u8[:], begin: i64, best: f64[lattice::MAX_INPUT + 1], back: i64[lattice::MAX_INPUT + 1]) {
    reset_front(input.len + 1);
    front_score[begin] = 0.0;
    for p in input.len + 1 {
        if p == begin { continue; }
        if back[p] < 0 { continue; }
        var chain: i32[>..] = [];
        var at = p;
        var steps: i64 = 0;
        while at != begin && steps < 64 {
            let i = back[at];
            if i < 0 || i >= w.list.len { break; }
            chain.push(i as i32);
            at = w.list[i].from;
            steps++;
        }
        var seq: i32[>..] = [];
        var k = chain.len - 1;
        while k >= 0 {
            seq.push(chain[k]);
            k--;
        }
        store_front(p, best[p], seq);
    }
}

fn best_path(w: Words&, input: const u8[:], end: i64, path: i64[>..]&) -> bool {
    var best: f64[lattice::MAX_INPUT + 1] = [NONE; lattice::MAX_INPUT + 1];
    var back: i64[lattice::MAX_INPUT + 1] = [-1; lattice::MAX_INPUT + 1];
    let begin = skip_separators(input, 0);
    best[begin] = 0.0;
    for i in w.list.len {                    // words come in order of where they start
        let word = w.list[i];
        if word.source == ENGLISH { continue; }
        if best[word.from] <= NONE { continue; }
        let pi = back[word.from];
        var boost = 0.0;
        if pi >= 0 { boost = context_boost(w, back[w.list[pi].from], pi, i); }
        else { boost = context_boost(w, -1, -1, i); }
        let s = best[word.from] + word.score + boost;
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

fn note_beam(input: const u8[:], begin: i64, lines: Line[>..]&, next: i32[>..]&, ends: i32[>..]&, offered: i64[>..]&) {
    reset_front(input.len + 1);
    for p in input.len + 1 {
        var best_i: i64 = -1;
        var best_s = NONE;
        var c: i64 = if p < ends.len { ends[p] } else { -1 };
        while c >= 0 && c < lines.len {
            if lines[c].score > best_s && (lines[c].word >= 0 || p == begin) {
                best_s = lines[c].score;
                best_i = c;
            }
            c = next[c];
        }
        if best_i < 0 { continue; }
        var chain: i32[>..] = [];
        var at = best_i;
        var steps: i64 = 0;
        while at >= 0 && steps < 64 && lines[at].word >= 0 {
            let o: i64 = lines[at].word;
            if o < 0 || o >= offered.len { break; }
            chain.push(offered[o] as i32);
            at = lines[at].prev;
            steps++;
        }
        var seq: i32[>..] = [];
        var k = chain.len - 1;
        while k >= 0 {
            seq.push(chain[k]);
            k--;
        }
        store_front(p, best_s, seq);
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

var fit_hits: i64 = 0;
var fit_misses: i64 = 0;

fn fit(context: const u8[:], context_hash: u64, word: const u8[:], word_hash: u64, rear: bool) -> f64 {
    var key = (context_hash * 0x100000001B3) ^ (word_hash * 0x9E3779B97F4A7C15) ^ (if rear { 1 } else { 0 });
    if key == 0 { key = 1; }                // 0 marks an empty slot
    if fits.len != FIT_SLOTS { forget_fits(); }
    let slot: i64 = (key & (FIT_SLOTS - 1)) as i64;
    if fits[slot].key == key {
        fit_hits++;
        return fits[slot].value;
    }
    fit_misses++;
    let f = grammar::query(context, word, rear) / lattice::LN2;
    fits[slot] = Fit { key: key, value: f };
    return f;
}

fn reset_fit_stats() {
    fit_hits = 0;
    fit_misses = 0;
}

fn fit_stats() -> i64, i64 { return fit_hits, fit_misses; }

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
    // The words each span offers, and their texts, made once.
    var offered: i64[>..] = [];
    var pool: u8[>..] = [];
    var text_at: u32[>..] = [];             // pool[text_at[k]..text_at[k + 1]] is offered[k]'s text
    var text_hash: u64[>..] = [];
    var group_at: i64[>..] = [];            // offered[group_at[b]..group_at[b + 1]] start at the same position
    var span_words: i64[>..] = [];
    var i: i64 = 0;
    while i < w.list.len {
        let from: i64 = w.list[i].from;
        var j = i;
        while j < w.list.len && w.list[j].from == from { j++; }
        span_words.clear();
        for x in i..j {
            if w.list[x].source == ENGLISH { continue; }
            let to: i64 = w.list[x].to;
            if to <= end && !(from == begin && to == end) { span_words.push(x); }
        }
        sort(span_words) { a, b =>
            let x = w.list[a];
            let y = w.list[b];
            x.to < y.to || (x.to == y.to && x.score > y.score)
        };
        group_at.push(offered.len);
        var n: i64 = 0;
        for k in span_words.len {
            n = if k > 0 && w.list[span_words[k]].to == w.list[span_words[k - 1]].to { n + 1 } else { 0 };
            if n >= homophones { continue; }
            offered.push(span_words[k]);
            text_at.push(pool.len as u32);
            word_text(w.list[span_words[k]], pool);
        }
        i = j;
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
    let len = text.len;
    if len == 0 || len > 65535 || seen.contains(text) { return; }
    let at = m.pool.len;
    m.pool.append(text);
    seen.insert(m.pool[at..], true);
    let refs = m.refs.len;
    for i in words { m.refs.push(Ref { source: w.list[i].source, entry: w.list[i].entry }); }
    m.candidates.push(Candidate { to: to as u8, text: at as u32, len: len as u16, refs: refs as u32,
                                  count: words.len as u16, code: 0, code_len: 0 });
}

// A candidate that is only text, made of no words: a shortcut.
fn offer_text(m: Menu&, seen: dictionary<const u8[:], bool>&, text: const u8[:], to: i64) {
    guard m.candidates.len < MAX_CANDIDATES && text.len > 0 && text.len <= 65535 && !seen.contains(text) else { return; }
    let at = m.pool.len;
    m.pool.append(text);
    seen.insert(m.pool[at..], true);
    m.candidates.push(Candidate { to: to as u8, text: at as u32, len: text.len as u16, refs: m.refs.len as u32, count: 0,
                                  code: 0, code_len: 0 });
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

// A span of the best reading. For Chinese, input[from..to] reads through
// edges[edge] as syllable `depth` of the word `word` (an index into Words.list).
// For English, the span is the whole word and `edge` and `depth` are unused.
struct Segment { from: u8, to: u8, edge: u32, word: u32, depth: u8 }

struct Mx { prev: i32, word: i32, score: f64, last_en: u8, zh_prev: i32, zh_at: i32, anchor: i32, saw_zh: u8, tail: i32, tail_head: i32 }

// How much better the next Chinese word reads after a Chinese sense of the
// English word just taken, than after the context already scored. 0 when
// the table has no sense, or the sense is no help. A typed capital is left
// alone: Python and Apple keep their names.
fn shadow_lift(input: const u8[:], en: Word, left: const u8[:], word: const u8[:], rear: bool) -> f64 {
    guard semantic::active() else { return -1.0e30; }
    let from: i64 = en.from;
    let end: i64 = en.end;
    guard end > from && end <= input.len else { return -1.0e30; }
    if span_capital(from, end - from) { return -1.0e30; }
    let code = input[from..end];
    let n = semantic::count(code);
    guard n > 0 else { return -1.0e30; }
    var best = -1.0e30;
    var sense: u8[>..] = [];
    var shadow: u8[>..] = [];
    for i in n {
        semantic::copy(code, i, sense);
        shadow.clear();
        if left.len > 0 && !(left.len == 1 && left[0] == ' ') { shadow.append(left); }
        shadow.append(sense);
        let g = fit(shadow, hash(shadow), word, hash(word), rear) + 0.15 * semantic::prior(code, i);
        if g > best { best = g; }
    }
    guard best > -1.0e20 else { return 0.0; }
    return best;
}

// How well `head` is followed by a Chinese sense of `code`.
fn sense_follow(code: const u8[:], head: const u8[:]) -> f64 {
    var best = -1.0e30;
    var sense: u8[>..] = [];
    let n = semantic::count(code);
    for i in n {
        semantic::copy(code, i, sense);
        let g = fit(head, hash(head), sense, hash(sense), false) + 0.15 * semantic::prior(code, i);
        if g > best { best = g; }
    }
    return best;
}

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
// word was known. A longer word such as 你和 hides it. Re-read only that
// syllable by how well it precedes a sense: 喝咖啡, not how common 你和 is.
fn prefix_tail(w: Words&, input: const u8[:], en: Word, from: i64) -> i32, i32, f64 {
    guard semantic::active() else { return -1, -1, 0.0; }
    let ef: i64 = en.from;
    let ee: i64 = en.end;
    guard ee > ef && ee <= input.len && from < front_n.len && front_n[from] > 0 else { return -1, -1, 0.0; }
    if span_capital(ef, ee - ef) { return -1, -1, 0.0; }
    let code = input[ef..ee];
    guard semantic::count(code) > 0 else { return -1, -1, 0.0; }
    let last: i64 = front_ids[front_at[from] + front_n[from] - 1];
    guard last >= 0 && last < w.list.len else { return -1, -1, 0.0; }
    let lw = w.list[last];
    if lw.source == ENGLISH || (lw.to as i64) != from { return -1, -1, 0.0; }
    var mark: u8[>..] = [];
    word_text(lw, mark);
    var start: i64 = 0;
    var at: i64 = 0;
    while at < mark.len {
        start = at;
        let c = mark[at];
        if c < 0x80 { at += 1; }
        else if c < 0xE0 { at += 2; }
        else if c < 0xF0 { at += 3; }
        else { at += 4; }
    }
    var syl: i64 = lw.from;
    if start < mark.len {
        let last_char = mark[start..];
        for i in w.list.len {
            let word = w.list[i];
            if word.source == ENGLISH || (word.to as i64) != from { continue; }
            var one: u8[>..] = [];
            word_text(word, one);
            if one == last_char { syl = word.from; break; }
        }
    }
    var picks: i64[>..] = [];
    let cap = grammar::homophones();
    var orig: i64 = if (lw.from as i64) == syl { last } else { -1 };
    for i in w.list.len {
        let word = w.list[i];
        if word.source == ENGLISH || (word.from as i64) != syl || (word.to as i64) != from { continue; }
        keep_best(w, picks, i, cap);
    }
    if orig >= 0 {
        var listed = false;
        for p in picks { if p == orig { listed = true; } }
        if !listed { picks.push(orig); }
    } else {
        var mark: u8[>..] = [];
        word_text(lw, mark);
        var start: i64 = 0;
        var at: i64 = 0;
        while at < mark.len {
            start = at;
            let c = mark[at];
            if c < 0x80 { at += 1; }
            else if c < 0xE0 { at += 2; }
            else if c < 0xF0 { at += 3; }
            else { at += 4; }
        }
        var oi: i64 = 0;
        while oi < picks.len {
            var one: u8[>..] = [];
            word_text(w.list[picks[oi]], one);
            if start < mark.len && one == mark[start..] { orig = picks[oi]; }
            oi++;
        }
    }
    guard orig >= 0 else { return -1, -1, 0.0; }
    var orig_text: u8[>..] = [];
    word_text(w.list[orig], orig_text);
    let orig_right = sense_follow(code, orig_text);
    var best_i: i32 = -1;
    var best_d = 0.0;
    var one: u8[>..] = [];
    for pick in picks {
        one.clear();
        word_text(w.list[pick], one);
        let gr = sense_follow(code, one);
        let d = (w.list[pick].score as f64) - (w.list[orig].score as f64) + (gr - orig_right);
        if d > best_d {
            best_d = d;
            best_i = pick as i32;
        }
    }
    guard best_i >= 0 && (best_i as i64) != orig else { return -1, -1, 0.0; }
    if (lw.from as i64) == syl { return best_i, -1, best_d; }
    var head: i64 = -1;
    var head_s = -1.0e30;
    for i in w.list.len {
        let word = w.list[i];
        if word.source == ENGLISH || (word.from as i64) != (lw.from as i64) || (word.to as i64) != syl { continue; }
        if (word.score as f64) > head_s {
            head_s = word.score as f64;
            head = i;
        }
    }
    guard head >= 0 else { return best_i, -1, best_d; }
    return best_i, head as i32, best_d;
}

fn mixed_boost(w: Words&, prev: i64, ant: i64, current: i64) -> f64 {
    guard prev >= 0 && current >= 0 else { return 0.0; }
    let prev_h = surface_of(w, prev);
    guard prev_h != 0 else { return 0.0; }
    var ant_h: u64 = 0;
    if ant >= 0 { ant_h = surface_of(w, ant); }
    let word = w.list[current];
    if word.source == ENGLISH { return 0.0; }
    let lex = source_lexicon(word.source);
    let len = lex.entries[word.entry].len;
    return userdb::recall(prev_h, ant_h, userdb::hash_reading_entry(lex, word.entry), len);
}

fn reached_front(p: i64) -> bool { p >= 0 && p < front_score.len && front_score[p] > -1.0e20 }

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

fn mixed_beam_width() -> i64 { mixed_beam }

var mx_peak: i64 = 0;
var mx_extend: i64 = 0;
var mx_peak_max: i64 = 0;
var mx_extend_sum: i64 = 0;
var mx_searches: i64 = 0;

fn mixed_load() -> i64, i64, i64 { return mx_peak_max, mx_extend_sum, mx_searches; }

fn reset_mixed_load() {
    mx_peak = 0;
    mx_extend = 0;
    mx_peak_max = 0;
    mx_extend_sum = 0;
    mx_searches = 0;
}

// The best mixed sentence, inserted into the menu. True when it became the
// first candidate, whose word path then replaced the Chinese one.
fn place_mixed(m: Menu&, w: Words&, input: const u8[:]) -> bool {
    mx_peak = 0;
    mx_extend = 0;
    mx_searches++;
    var english: i64 = 0;
    for word in w.list { if word.source == ENGLISH { english++; } }
    guard english > 0 && input.len > 0 && front_score.len == input.len + 1 else { return false; }
    let begin = skip_separators(input, 0);
    // The whole input is one English word: place_english owns the spelling,
    // the case, and where it sits. A mixed split would only break that.
    var whole_code: u8[>..] = [];
    typed_span(input, begin, input.len, whole_code);
    if english::exact(whole_code) >= 0 { return false; }
    var whole = false;
    for word in w.list {
        if word.source != ENGLISH && word.from == begin && (word.to as i64) == input.len { whole = true; }
    }
    let use_fit = grammar::on && !whole;
    let hom = grammar::homophones();
    var idx: i64[>..] = [];
    var en_idx: i64[>..] = [];
    for i in w.list.len {
        let word = w.list[i];
        if (word.to as i64) > input.len { continue; }
        if word.source == ENGLISH { en_idx.push(i); } else { idx.push(i); }
    }
    sort(idx) { a, b =>
        let x = w.list[a];
        let y = w.list[b];
        x.from < y.from || (x.from == y.from && (x.to < y.to || (x.to == y.to && x.score > y.score)))
    };
    var zh_lo: i32[>..] = [];
    var zh_hi: i32[>..] = [];
    for p in input.len + 1 {
        zh_lo.push(0);
        zh_hi.push(0);
    }
    var i: i64 = 0;
    while i < idx.len {
        let from: i64 = w.list[idx[i]].from;
        var j = i;
        while j < idx.len && w.list[idx[j]].from == from { j++; }
        if from >= 0 && from <= input.len {
            zh_lo[from] = i as i32;
            zh_hi[from] = j as i32;
        }
        i = j;
    }
    var states: Mx[>..] = [];
    var next: i32[>..] = [];
    var heads: i32[>..] = [];
    for p in input.len + 1 { heads.push(-1); }
    for ei in en_idx {
        let word = w.list[ei];
        let from: i64 = word.from;
        let to: i64 = word.to;
        if to <= from || to > input.len { continue; }
        if from == begin && to == input.len { continue; }   // a pure English sentence stays with place_english
        var base = NONE;
        var saw: u8 = 0;
        var anchor: i64 = from;
        if from == begin {
            base = 0.0;
        } else if reached_front(from) {
            base = front_score[from];
            saw = 1;
        } else {
            continue;
        }
        var score = base + (word.score as f64);
        if saw != 0 { score += EN_SWITCH; }
        var zh_at: i32 = -1;
        if saw != 0 && front_n[from] > 0 {
            zh_at = front_ids[(front_at[from] + front_n[from] - 1)];
        }
        var tail: i32 = -1;
        var tail_head: i32 = -1;
        if saw != 0 {
            let swapped, head, bump = prefix_tail(w, input, word, from);
            tail = swapped;
            tail_head = head;
            if swapped >= 0 { zh_at = swapped; }
            score += bump;
        }
        consider_mx(states, next, heads, to, Mx { prev: -1, word: ei as i32, score: score, last_en: 1, zh_prev: -1,
                                                   zh_at: zh_at, anchor: anchor as i32, saw_zh: saw, tail: tail,
                                                   tail_head: tail_head });
    }
    var text: u8[>..] = [];
    var ctx: u8[>..] = [];
    for p in input.len {
        var here: i32[>..] = [];
        var c: i64 = heads[p];
        while c >= 0 && c < states.len {
            here.push(c as i32);
            c = next[c];
        }
        if here.len > mx_peak { mx_peak = here.len; }
        if mx_peak > mx_peak_max { mx_peak_max = mx_peak; }
        mx_extend += here.len;
        mx_extend_sum += here.len;
        if here.len == 0 { continue; }
        for s_i in here {
            let s = states[s_i];
            ctx.clear();
            if s.last_en == 0 && s.word >= 0 {
                if s.zh_prev >= 0 { word_text(w.list[s.zh_prev], ctx); }
                word_text(w.list[s.word], ctx);
            } else if s.last_en != 0 && s.zh_at >= 0 && (s.zh_at as i64) < w.list.len {
                // One Chinese word of backoff across the English span, so a
                // sentence-final syllable can still be told apart. The word
                // before that stays out, and the English text is not context.
                word_text(w.list[s.zh_at], ctx);
            } else if s.last_en != 0 {
                ctx.push(' ');
            }
            let ctx_hash = hash(ctx);
            let lo: i64 = if p < zh_lo.len { zh_lo[p] } else { 0 };
            let hi: i64 = if p < zh_hi.len { zh_hi[p] } else { 0 };
            var n_hom: i64 = 0;
            var prev_to: i64 = -1;
            var span_best = 0.0;
            var blank: u8[>..] = [];
            blank.push(' ');
            let blank_hash = hash(blank);
            for k in lo..hi {
                let wi = idx[k];
                let word = w.list[wi];
                let to: i64 = word.to;
                if to != prev_to {
                    n_hom = 0;
                    prev_to = to;
                    span_best = word.score as f64;
                }
                if to <= p || n_hom >= hom { continue; }
                n_hom++;
                text.clear();
                word_text(word, text);
                var score = s.score + (word.score as f64);
                if s.last_en != 0 { score += EN_SWITCH; }
                if use_fit {
                    let rear = to == input.len;
                    var g = fit(ctx, ctx_hash, text, hash(text), rear);
                    // Across English, a collocation may break a near tie
                    // (吧 against 把) and may not overturn a clearer unigram.
                    if s.last_en != 0 {
                        let uni = fit(blank, blank_hash, text, hash(text), rear);
                        let near = (word.score as f64) + 0.5 >= span_best;
                        g = uni;
                        if near && ctx.len > 0 && ctx[0] != ' ' {
                            let coll = fit(ctx, ctx_hash, text, hash(text), rear);
                            if coll > g { g = coll; }
                        }
                    }
                    score += fit_weight * g;
                    if s.last_en != 0 && (s.word as i64) >= 0 && (s.word as i64) < w.list.len &&
                       w.list[s.word].source == ENGLISH {
                        let alt = shadow_lift(input, w.list[s.word], ctx, text, rear);
                        if alt > -1.0e20 {
                            var lift = alt - g;
                            if lift > SEM_LIFT { lift = SEM_LIFT; }
                            if lift > 0.0 { score += lift; }
                        }
                        // 吧 closing the input, after a word that has a Chinese sense,
                        // is the sentence-final particle. Bounded, and only at the end.
                        if rear && text == "吧" && semantic::count(input[w.list[s.word].from..w.list[s.word].end]) > 0 {
                            score += 12.0;
                        }
                    }
                    if emit_on { score += emit_weight * emission(input, word.from, to, text); }
                }
                if s.last_en == 0 { score += mixed_boost(w, s.word, s.zh_prev, wi); }
                var zp: i32 = -1;
                if s.last_en == 0 { zp = s.word; }
                consider_mx(states, next, heads, to, Mx { prev: s_i, word: wi as i32, score: score, last_en: 0,
                                                          zh_prev: zp, zh_at: -1, anchor: s.anchor, saw_zh: 1, tail: s.tail,
                                                          tail_head: s.tail_head });
            }
            for ei in en_idx {
                let word = w.list[ei];
                if (word.from as i64) != p { continue; }
                let to: i64 = word.to;
                if to <= p || to > input.len { continue; }
                var score = s.score + (word.score as f64);
                if s.last_en == 0 { score += EN_SWITCH; }
                var zh_at: i32 = if s.last_en == 0 { s.word } else { s.zh_at };
                consider_mx(states, next, heads, to, Mx { prev: s_i, word: ei as i32, score: score, last_en: 1,
                                                          zh_prev: -1, zh_at: zh_at, anchor: s.anchor, saw_zh: s.saw_zh,
                                                          tail: s.tail, tail_head: s.tail_head });
            }
        }
    }
    var best_i: i64 = -1;
    var best_s = NONE;
    var c: i64 = if input.len < heads.len { heads[input.len] } else { -1 };
    while c >= 0 && c < states.len {
        if states[c].saw_zh != 0 && states[c].score > best_s {
            best_s = states[c].score;
            best_i = c;
        }
        c = next[c];
    }
    guard best_i >= 0 else { return false; }
    var chain: i32[>..] = [];
    var at = best_i;
    var steps: i64 = 0;
    while at >= 0 && steps < 64 {
        chain.push(states[at].word);
        at = states[at].prev;
        steps++;
    }
    var words: i64[>..] = [];
    let anchor: i64 = states[best_i].anchor;
    if anchor > begin && reached_front(anchor) {
        let a: i64 = front_at[anchor];
        let n: i64 = front_n[anchor];
        let tail = states[best_i].tail;
        let tail_head = states[best_i].tail_head;
        if tail >= 0 && n > 0 {
            for k in a..a + n - 1 { words.push(front_ids[k]); }
            if tail_head >= 0 { words.push(tail_head); }
            words.push(tail);
        } else {
            for k in a..a + n { words.push(front_ids[k]); }
        }
    }
    var k = chain.len - 1;
    while k >= 0 {
        words.push(chain[k]);
        k--;
    }
    guard words.len > 1 else { return false; }
    var saw_en = false;
    var saw_zh = false;
    for wi in words {
        if wi < 0 || wi >= w.list.len { return false; }
        if w.list[wi].source == ENGLISH { saw_en = true; } else { saw_zh = true; }
    }
    guard saw_en && saw_zh else { return false; }
    text.clear();
    append_words(w, words, text);
    guard text.len > 0 && text.len <= 65535 else { return false; }
    let zh_ok = reached_front(input.len);
    var short_en = false;
    for wi in words {
        let word = w.list[wi];
        if word.source != ENGLISH { continue; }
        let n: i64 = (word.end as i64) - (word.from as i64);
        if n < 5 && !span_capital(word.from, n) { short_en = true; }
        var shown: u8[>..] = [];
        english::spelling(word.entry, shown);
        var letters: i64 = 0;
        for c in shown {
            if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') { letters++; }
        }
        // An unfinished completion is only a bridge while the word is being
        // typed. It does not take first place over a Chinese reading.
        if letters > n { short_en = true; }
    }
    var slot: i64 = -1;
    // A word of four letters or fewer is also a pile of pinyin. It can sit
    // on the page. It takes first only with a capital, or as part of a longer
    // English word. A longer word also takes first when Chinese cannot read
    // the keys (github).
    if !zh_ok && !short_en {
        slot = 0;
    } else {
        let delta = if zh_ok { best_s - front_score[input.len] } else { 0.0 };
        if zh_ok && delta >= EN_TOP1 && !short_en { slot = 0; }
        else if (zh_ok && delta >= EN_PAGE) || (!zh_ok && short_en) { slot = 2; }
    }
    var span: u8[>..] = [];
    typed_span(input, begin, input.len, span);
    let mixed_chosen = userdb::chosen(span, text);
    var chinese_chosen: i64 = 0;
    if m.candidates.len > 0 {
        let c0 = m.candidates[0];
        if (c0.to as i64) == input.len {
            chinese_chosen = userdb::chosen(span, m.pool[c0.text..c0.text + c0.len]);
        }
    }
    if mixed_chosen > 0 && mixed_chosen >= chinese_chosen { slot = 0; }
    else if chinese_chosen > mixed_chosen && slot == 0 { slot = 2; }
    else if mixed_chosen > 0 && slot < 0 { slot = 2; }
    guard slot >= 0 else { return false; }
    if slot == 0 && m.candidates.len > 0 {
        let c0 = m.candidates[0];
        if c0.count == 0 && c0.code_len == 0 { slot = 1; }
    }
    var existing: i64 = -1;
    for ci in m.candidates.len {
        let c = m.candidates[ci];
        if c.len == text.len && compare(m.pool[c.text..c.text + c.len], text) == 0 { existing = ci; }
    }
    if existing == slot {
        if slot == 0 { write_path(m, words); }
        return slot == 0;
    }
    if existing >= 0 {
        remove_at(m.candidates, existing);
        if existing < slot { slot--; }
    }
    if slot > m.candidates.len { slot = m.candidates.len; }
    if m.candidates.len >= MAX_CANDIDATES { remove_at(m.candidates, m.candidates.len - 1); }
    guard m.candidates.len < MAX_CANDIDATES else { return false; }
    let at_pool = m.pool.len;
    m.pool.append(text);
    let refs = m.refs.len;
    for wi in words {
        let word = w.list[wi];
        m.refs.push(Ref { source: word.source, entry: word.entry });
    }
    let cand = Candidate { to: input.len as u8, text: at_pool as u32, len: text.len as u16, refs: refs as u32,
                           count: words.len as u16, code: 0, code_len: 0 };
    var next_c: Candidate[>..] = [];
    if slot > m.candidates.len { slot = m.candidates.len; }
    next_c.append(m.candidates[..slot]);
    next_c.push(cand);
    next_c.append(m.candidates[slot..]);
    m.candidates.clear();
    m.candidates.append(next_c);
    if slot == 0 { write_path(m, words); }
    return slot == 0;
}

fn write_path(m: Menu&, words: i64[>..]&) {
    m.path.clear();
    for wi in words { m.path.push(wi as u32); }
}

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
