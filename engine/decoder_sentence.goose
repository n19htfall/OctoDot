// The best Chinese sentences through the words a search found: by the words'
// own scores (best_path), or, with the grammar model, librime's beam search
// (best_line, kbest_sentences), which the reranker's shortlist and the
// accuracy harness also run with wider settings.
import std;
import dictionary;
import lattice;
import userdb;
import grammar;
import decoder;

namespace decoder;

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

// ---- the Chinese front ---------------------------------------------------------------

fn reset_front(w: Words&, positions: i64) {
    w.front_score.clear();
    w.front_at.clear();
    w.front_n.clear();
    w.front_ids.clear();
    for i in positions {
        w.front_score.push(NONE);
        w.front_at.push(0);
        w.front_n.push(0);
    }
}

// Records the reading that reaches `at`, given last word first.
fn store_front(w: Words&, at: i64, score: f64, last_first: const i32[:]) {
    w.front_score[at] = score;
    w.front_at[at] = w.front_ids.len as i32;
    w.front_n[at] = last_first.len as i32;
    w.front_ids.append(last_first);
    reverse(w.front_ids[w.front_at[at]..]);
}

// Whether some Chinese reading reaches position p.
fn reached_front(w: Words&, p: i64) -> bool { p >= 0 && p < w.front_score.len && w.front_score[p] > NONE / 2.0 }

// The front as best_path left it: the best path to each position.
fn note_viterbi(w: Words&, input: const u8[:], begin: i64, best: f64[lattice::MAX_INPUT + 1], back: i64[lattice::MAX_INPUT + 1]) {
    reset_front(w, input.len + 1);
    w.front_score[begin] = 0.0;
    var chain: i32[>..] = [];
    for p in input.len + 1 {
        if p == begin || back[p] < 0 { continue; }
        chain.clear();
        var at = p;
        while at != begin {
            chain.push(back[at] as i32);
            at = w.list[back[at]].from;
        }
        store_front(w, p, best[p], chain);
    }
}

// ---- sentences ----------------------------------------------------------------------

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

// The text before the input, which the first word of a sentence follows.
// Empty, the first word scores the model's non-collocation penalty, as in
// librime: so it is in the IME, which does not set it yet (the accuracy
// harness's --chained does).
var preceding: u8[>..];

// Partial sentences the beam keeps, ending where their last word ends: the
// line each extends (-1 for none) and its last word, as an index into the
// words the beam was offered (-1 for the empty line the search starts from).
struct Line { prev: i32, word: i32, score: f64 }

// Adds `line`, ending at `to`, to that position's list (ends[to], linked
// through next); returns its index.
fn add_line(lines: Line[>..]&, next: i32[>..]&, ends: i32[>..]&, to: i64, line: Line) -> i32 {
    lines.push(line);
    next.push(ends[to]);
    ends[to] = (lines.len - 1) as i32;
    return ends[to];
}

// The front as the beam left it: at each position, the best line ending there.
fn note_beam(w: Words&, input: const u8[:], begin: i64, lines: Line[>..]&, next: i32[>..]&, ends: i32[>..]&,
             offered: i64[>..]&) {
    reset_front(w, input.len + 1);
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
        store_front(w, p, lines[best].score, chain);
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
    if kf < 0 || kt < 0 || kt - kf != chars || kt >= emit_start.len { return emit_floor * chars; }
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
    return kbest_sentences(w, input, end, beam, homophones, 1, keep, paths, scores);
}

// The same search keeping up to `per_state` lines for each position and
// last word, not just the best: with enough of them and a wide beam, the
// `keep` best sentences by the same scores, which the accuracy harness
// measures the right sentence's rank among. One per state is the search the
// IME runs. Sentences of the same text may come more than once. Each
// sentence's score (best first) goes in `scores`.
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
            // What a word after this line follows: its last two words (the
            // preceding text, for the empty line), as text for the model and
            // as words for the user's recent text.
            var prev: i64 = -1;
            var anterior: i64 = -1;
            context.clear();
            if line.word < 0 {
                context.append(preceding);
            } else {
                if line.prev >= 0 && lines[line.prev].word >= 0 {
                    let before: i64 = lines[line.prev].word;
                    anterior = offered[before];
                    context.append(pool[text_at[before]..text_at[before + 1]]);
                }
                prev = offered[line.word];
                context.append(pool[text_at[line.word]..text_at[line.word + 1]]);
            }
            let context_hash = hash(context);
            for o in lo..hi {
                let word = w.list[offered[o]];
                let to: i64 = word.to;
                let text = pool[text_at[o]..text_at[o + 1]];
                var score = line.score + word.score + fit_weight * fit(context, context_hash, text, text_hash[o], to == end);
                score += context_boost(w, anterior, prev, offered[o]);
                if emit_on { score += emit_weight * emission(input, from, to, text); }
                let made = Line { prev: t, word: o as i32, score: score };
                // The state it reaches: this position and this last word's text.
                let key = text_hash[o] ^ ((to as u64) * 0x9E3779B97F4A7C15);
                let found = by_text.get(key);
                if per_state <= 1 {
                    if found && lines[found].word >= 0 && pool[text_at[lines[found].word]..text_at[lines[found].word + 1]] == text {
                        if score > lines[found].score { lines[found] = made; }
                    } else if !found {
                        by_text.insert(key, add_line(lines, next, ends, to, made));
                    }
                } else if !found {
                    by_text.insert(key, (slots.len / per_state + 1) as i32);
                    slots.push(add_line(lines, next, ends, to, made));
                    for r in per_state - 1 { slots.push(-1); }
                } else {
                    let base = (found - 1) * per_state;
                    let first_word: i64 = lines[slots[base]].word;
                    if pool[text_at[first_word]..text_at[first_word + 1]] == text {
                        var free: i64 = -1;
                        var worst: i64 = -1;
                        for r in per_state {
                            let held: i64 = slots[base + r];
                            if held < 0 {
                                if free < 0 { free = base + r; }
                            } else if worst < 0 || lines[held].score < lines[worst].score {
                                worst = held;
                            }
                        }
                        if free >= 0 { slots[free] = add_line(lines, next, ends, to, made); }
                        else if score > lines[worst].score { lines[worst] = made; }
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
    note_beam(w, input, begin, lines, next, ends, offered);
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
        let s = forward[word.from] + word.score;
        if s > forward[to] { forward[to] = s; }
    }
    var i = w.list.len - 1;
    while i >= 0 {
        let word = w.list[i];
        if word.source != ENGLISH {
            let to: i64 = word.to;
            if to <= end && backward[to] > NONE {
                let s = word.score + backward[to];
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
                   forward[word.from] + word.score + backward[to] >= floor;
        kept.push(keep);
        if keep { n++; }
    }
    return n;
}
