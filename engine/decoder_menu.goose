// The menu a user picks from: the best sentence, then the words that start
// the input; and the best reading's spans, for the preedit.
import std;
import dictionary;
import lexicon;
import lattice;
import userdb;
import phrases;
import grammar;
import decoder;
import decoder_sentence;

namespace decoder;

let MAX_CANDIDATES = 120;

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
fn assemble(m: Menu&, w: Words&, input: const u8[:]) -> i64 {
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
    let whole_lo, whole_hi = span(w, begin, end);
    let whole_word = whole_lo < whole_hi;
    let sentence_allowed = !grammar::on || !whole_word;
    let found = if grammar::on && !whole_word { best_line(w, input, end, path) } else { best_path(w, input, end, path) };
    if found {
        reverse(path[..]);                  // the searches list a path's words last first
        for i in path { m.path.push(i as u32); }
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
        edges.push(k);
        if match_edges(g, lex, i, input, edge.to, depth + 1, to, edges) { return true; }
        edges.pop();
    }
    return false;
}
