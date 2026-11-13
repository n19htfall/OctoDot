// The accuracy set (octo-prep accuracy builds it into build/accuracy/ from
// data/accuracy.lock's sources): words typed alone, and sentences typed
// whole, in the scheme given, with the lexicon sets on by default and
// nothing learned.
//
//   words      is the line's text the first candidate? M1's gate: at least
//              95% of the common words and idioms together (exit 1 below
//              that). Names and places are a metric, like sentences: typed
//              alone, a name that shares its pinyin with a common word (胡适,
//              护士) has no right answer without context, which is what
//              M2's grammar model reads.
//   sentences  the share right as a whole and the share of characters right
//              (1 - edit distance / length); a metric, not a gate. Scored as
//              rime-schema-compare scores librime on the same sentences, so
//              the numbers compare: 他/她/它 count as one, as do 的/地/得.
//              A sentence longer than a composition is typed as the IME
//              takes it, which commits a first word to make room.
//
// Every line is checked first: each syllable must be one the lexicon knows,
// each character's reading one the lexicon has for it somewhere, and two
// syllables that together spell one (xi an: xian) must have a ' between
// them, as a typist writes xi'an. A line that fails is an error in the set,
// so nothing is measured (exit 2).
//
// With a reranker in the images (engine/rerank.goose), sentences are
// reranked as the IME reranks them, here at once rather than on a worker;
// --no-rerank measures the decoder alone.
//
//   accuracy IMAGES SET_DIR [SCHEME] [--no-grammar] [--no-rerank] [--chained] [--diagnose]
import std;
import os;
import dictionary;
import octo from "..";

struct Line { category: u8[..31], text: u8[..255], number: i64, syls: u16[..64], apostrophes: u64, count: i64 }

var keys: spelling::Keys[>..] = [];
var problems: i64 = 0;

fn problem(path: const u8[:], number: i64, text: const u8[:], why: const u8[:]) {
    print("set   ", path, ":", number, "  ", text, "  ", why);
    problems++;
}

// Every (character, toneless syllable) the core and the mounted sets hold.
fn learn_readings(lex: lexicon::Lexicon&, readings: dictionary<u64, bool>&) {
    for p in lex.pairs {
        let plain: u64 = lexicon::live.toned[p.toned].plain;
        readings.insert((p.cp as u64) << 16 | plain, true);
    }
}

// Reads one file of the set into `lines`, checking each line.
fn read_set(path: const u8[:], lines: Line[>..]&, plain_ids: dictionary<const u8[:], i64>&,
            readings: dictionary<u64, bool>&) {
    var data: u8[>..] = [];
    if !read_file(path, data) {
        print("accuracy: cannot read ", path);
        exit(2);
    }
    var category: u8[..31] = "";
    var number: i64 = 0;
    for raw in split(data, '\n') {
        number++;
        let line: const u8[:] = raw;
        if line.len == 0 { continue; }
        if line.len > 3 && line[..3] == "## " {
            category = line[3..];
            continue;
        }
        if line[0] == '#' { continue; }
        let tab = position(line, '\t');
        if tab < 0 {
            problem(path, number, line, "no tab between the text and its pinyin");
            continue;
        }
        let text: const u8[:] = line[..tab];
        let pinyin: const u8[:] = line[tab + 1..];
        var l = Line { category: category, text: text, number: number, syls: [], apostrophes: 0, count: 0 };
        var cps: u32[>..] = [];
        each_utf8(text) { cp => cps.push(cp as u32); };
        // the syllables, and which ones follow an apostrophe
        var start: i64 = 0;
        var apostrophe = false;
        var bad = false;
        for i in pinyin.len + 1 {
            let end = i == pinyin.len || pinyin[i] == ' ' || pinyin[i] == '\'';
            if !end { continue; }
            if i > start {
                let syl: const u8[:] = pinyin[start..i];
                let id = plain_ids.get(syl);
                if id {
                    if l.count < 64 {
                        if apostrophe { l.apostrophes |= (1 as u64) << l.count; }
                        l.syls.push(id as u16);
                    }
                    l.count++;
                } else {
                    problem(path, number, text, str("no syllable \"", syl, "\""));
                    bad = true;
                }
                apostrophe = false;
            }
            if i < pinyin.len && pinyin[i] == '\'' { apostrophe = true; }
            start = i + 1;
        }
        if bad { continue; }
        if l.count != cps.len || l.count > 64 || l.count == 0 || text.len > 255 {
            problem(path, number, text, str(cps.len, " characters but ", l.count, " syllables"));
            continue;
        }
        for k in l.count {
            if !readings.contains((cps[k] as u64) << 16 | l.syls[k]) {
                var c: u8[>..] = [];
                push_utf8(c, cps[k]);
                problem(path, number, text, str("the lexicon never reads ", c, " as ",
                                                lexicon::live.plain[l.syls[k]].text));
            }
        }
        // typed in full pinyin, two syllables that together spell one (xi an: xian) need a ' between them
        for k in 1..l.count {
            if (l.apostrophes >> k & 1) != 0 { continue; }
            let joined = str(lexicon::live.plain[l.syls[k - 1]].text, lexicon::live.plain[l.syls[k]].text);
            if plain_ids.contains(joined) {
                problem(path, number, text, str("\"", joined, "\" is one syllable; write ",
                                                lexicon::live.plain[l.syls[k - 1]].text, "'",
                                                lexicon::live.plain[l.syls[k]].text));
            }
        }
        lines.push(l);
    }
}

// The keys typed for a line in the scheme in use.
fn code_of(l: Line, full_pinyin: bool, out: u8[>..]&) {
    for k in l.count {
        if full_pinyin && (l.apostrophes >> k & 1) != 0 { out.push('\''); }
        out.append(keys[l.syls[k]].text);
    }
}

// Decodes `input` in one go: the first candidate, and the place of `want`
// among the candidates that cover the whole input (-1 if absent).
fn decode(input: const u8[:], want: const u8[:], got: u8[>..]&) -> i64 {
    session::clear_composition();
    session::input.append(input);
    session::rebuild();
    var place: i64 = -1;
    var whole: i64 = 0;
    for i in session::menu.candidates.len {
        let c = session::menu.candidates[i];
        let text = session::menu.pool[c.text..c.text + c.len];
        if i == 0 { got.append(text); }
        if c.to != session::input.len { continue; }
        if place < 0 && text == want { place = whole; }
        whole++;
    }
    return place;
}

// Whether the core or a mounted set holds `text` read as the line reads it.
fn in_lexicon(l: Line) -> bool {
    var code: u16[>..] = [];
    for k in l.count { code.push(l.syls[k]); }
    if holds(lexicon::live, code, l.text) { return true; }
    for k in sets::SLOTS { if sets::used[k] && holds(sets::slot(k), code, l.text) { return true; } }
    return false;
}

fn holds(lex: lexicon::Lexicon&, code: const u16[:], text: const u8[:]) -> bool {
    let lo, hi = lexicon::exact(lex, code);
    for i in lo..hi {
        var t: u8[>..] = [];
        lexicon::text(lex, i, t);
        if t == text { return true; }
    }
    return false;
}

// 他/她/它 as one, and 的/地/得 as one (so 其它 is 其他), as rime-schema-compare
// scores: pinyin cannot tell them apart, and the benchmark's numbers compare.
fn folded(cp: u32) -> u32 {
    if cp == 0x5979 || cp == 0x5B83 { return 0x4ED6; }      // 她 它 → 他
    if cp == 0x5730 || cp == 0x5F97 { return 0x7684; }      // 地 得 → 的
    return cp;
}

fn edit_distance(a: const u32[:], b: const u32[:]) -> i64 {
    var row: i64[>..] = [];
    for j in b.len + 1 { row.push(j); }
    for i in a.len {
        var diagonal = row[0];
        row[0] = i + 1;
        for j in b.len {
            let above = row[j + 1];
            row[j + 1] = min(min(row[j] + 1, above + 1), diagonal + (if a[i] == b[j] { 0 } else { 1 }));
            diagonal = above;
        }
    }
    return row[b.len];
}

fn percent(hits: i64, total: i64) -> u8[>..] {
    var s: u8[>..] = [];
    format_flt(s, if total > 0 { 100.0 * hits / total } else { 0.0 }, 1);
    s.push('%');
    return s;
}


// ---- Why a sentence is missed (--diagnose) ----
//
// For a sentence the engine gets wrong, the word graph it searched is built
// again and two paths are scored exactly as the beam scores them (each
// word's score plus the grammar model's fit after the path's last two
// words): the best that spells the right sentence and the best that spells
// what the engine offered. Then:
//   graph   no path through the words found spells it (a missing word, a
//           word the search's budgets left out, or, in hotlist, a reading
//           pypinyin guessed wrong)
//   cut     only a word beyond the homophones each span offers spells it
//   search  it scores higher than what was offered: the beam lost it
//   model   it scores lower: the scoring itself prefers the wrong sentence
// and where the right sentence ranks among the beam's 50 best, which is what
// a reranker could reach.

struct Path { prev: i32, word: i32, k: i32, score: f64 }

var tree_paths: f64[>..] = [];
var tree_tokens: f64[>..] = [];

// The words each span offers the beam (its `homophones` best), as a mask.
fn offered_mask(w: decoder::Words&, input: const u8[:], end: i64, homophones: i64) -> bool[>..] {
    var mask: bool[>..] = [];
    for x in w.list.len { mask.push(false); }
    let begin = decoder::skip_separators(input, 0);
    var offered: i64[>..] = [];
    for p in input.len {
        offered.clear();
        decoder::offers(w, p, homophones, offered);
        for x in offered {
            let to: i64 = w.list[x].to;
            if to <= end && !(p == begin && to == end) { mask[x] = true; }
        }
    }
    return mask;
}

// The best score of a path through the allowed words that spells exactly
// `target`, scored as the beam scores; NONE if there is none.
fn constrained(w: decoder::Words&, pool: const u8[:], text_at: const u32[:], allowed: const bool[:],
               input: const u8[:], end: i64, target: const u8[:]) -> f64 {
    let begin = decoder::skip_separators(input, 0);
    var lines: Path[>..] = [Path { prev: -1, word: -1, k: 0, score: 0.0 }];
    var ends: i32[>..] = [];
    var next: i32[>..] = [-1];
    for p in input.len + 1 { ends.push(-1); }
    ends[begin] = 0;
    var seen = dictionary<u64, i32> {};
    var context: u8[>..] = [];
    var i: i64 = 0;
    while i < w.list.len {
        let from: i64 = w.list[i].from;
        var j = i;
        while j < w.list.len && w.list[j].from == from { j++; }
        var t: i64 = ends[from];
        while t >= 0 {
            let line = lines[t];
            context.clear();
            if line.word < 0 {
                context.append(decoder::preceding);
            } else {
                if line.prev >= 0 && lines[line.prev].word >= 0 {
                    let pw: i64 = lines[line.prev].word;
                    context.append(pool[text_at[pw]..text_at[pw + 1]]);
                }
                let lw: i64 = line.word;
                context.append(pool[text_at[lw]..text_at[lw + 1]]);
            }
            let context_hash = hash(context);
            for x in i..j {
                if !allowed[x] { continue; }
                let to: i64 = w.list[x].to;
                if to > end || (from == begin && to == end) { continue; }
                let text = pool[text_at[x]..text_at[x + 1]];
                let k: i64 = line.k;
                if k + text.len > target.len || target[k..k + text.len] != text { continue; }
                let score = line.score + w.list[x].score +
                            decoder::fit(context, context_hash, text, hash(text), to == end);
                let key = hash(text) ^ ((to as u64) * 0x9E3779B97F4A7C15) ^ (((k + text.len) as u64) * 0xC2B2AE3D27D4EB4F);
                let known = seen.get(key);
                if known {
                    if score > lines[known].score {
                        lines[known] = Path { prev: t as i32, word: x as i32, k: (k + text.len) as i32, score: score };
                    }
                } else {
                    lines.push(Path { prev: t as i32, word: x as i32, k: (k + text.len) as i32, score: score });
                    next.push(ends[to]);
                    ends[to] = (lines.len - 1) as i32;
                    seen.insert(key, (lines.len - 1) as i32);
                }
            }
            t = next[t];
        }
        i = j;
    }
    var best = decoder::NONE;
    var c: i64 = ends[end];
    while c >= 0 {
        if lines[c].k == target.len && lines[c].word >= 0 && lines[c].score > best { best = lines[c].score; }
        c = next[c];
    }
    return best;
}

fn folded_text(text: const u8[:]) -> u32[>..] {
    var a: u32[>..] = [];
    each_utf8(text) { cp => a.push(folded(cp as u32)); };
    return a;
}

struct Diagnosis { graph: i64, cut: i64, search: i64, model: i64, whole: i64, long: i64, right: i64,
                   top: i64[6], wide: i64, sized: i64, words: i64, offered: i64, chars: i64,
                   fixable: i64, kept_all: i64[6], kept_offered: i64[6], size_all: i64[6], size_offered: i64[6] }

let DELTAS = [10.0, 20.0, 30.0, 40.0, 60.0, 80.0];

// Diagnoses one sentence typed as `code`, the engine having offered `got`.
fn diagnose(l: Line, code: const u8[:], got: const u8[:], d: Diagnosis&, out: u8[>..]&) {
    let want = folded_text(l.text);
    if folded_text(got) == want { d.right++; return; }
    if code.len > lattice::MAX_INPUT { d.long++; return; }
    var g = lattice::Graph {};
    lattice::build(g, code, spelling::live, lexicon::live);
    var w = decoder::Words {};
    decoder::search(w, g, lexicon::live, code);
    let end = decoder::readable(w, code);
    var pool: u8[>..] = [];
    var text_at: u32[>..] = [];
    for word in w.list {
        text_at.push(pool.len as u32);
        decoder::word_text(word, pool);
    }
    text_at.push(pool.len as u32);
    var all: bool[>..] = [];
    for x in w.list.len { all.push(true); }
    let offered = offered_mask(w, code, end, grammar::homophones());
    d.sized++;
    d.words += w.list.len;
    for x in w.list.len { if offered[x] { d.offered++; } }
    d.chars += want.len;
    let gold_any = constrained(w, pool, text_at, all, code, end, l.text);
    let gold = constrained(w, pool, text_at, offered, code, end, l.text);
    let mine = constrained(w, pool, text_at, offered, code, end, got);
    // where the right sentence ranks among the beam's 50 best, and whether a wider search finds it
    var paths: i64[>..] = [];
    let n = decoder::sentences(w, code, end, decoder::BEAM, grammar::homophones(), 50, paths);
    var rank: i64 = -1;
    var r: i64 = 0;
    var text: u8[>..] = [];
    var at: i64 = 0;
    while at < paths.len && rank < 0 {
        var e = at;
        while paths[e] >= 0 { e++; }
        text.clear();
        var k = e - 1;
        while k >= at {
            decoder::word_text(w.list[paths[k]], text);
            k--;
        }
        if folded_text(text) == want { rank = r; }
        r++;
        at = e + 1;
    }
    let bounds = [1, 2, 5, 10, 20, 50];
    for b in 6 { if rank >= 0 && rank < bounds[b] { d.top[b]++; } }
    var widest: i64[>..] = [];
    if decoder::sentences(w, code, end, 64, 32, 1, widest) > 0 {
        text.clear();
        var k = widest.len - 2;
        while k >= 0 {
            decoder::word_text(w.list[widest[k]], text);
            k--;
        }
        if folded_text(text) == want { d.wide++; }
    }
    // P2: for each delta, does the right sentence survive pruning (over all
    // words, and over the words offered to the beam), and how many words stay?
    if gold_any > decoder::NONE {
        d.fixable++;
        var kept: bool[>..] = [];
        var both: bool[>..] = [];
        for di in 6 {
            let n = decoder::prune(w, code, end, DELTAS[di], kept);
            d.size_all[di] += n;
            both.clear();
            var m: i64 = 0;
            for x in w.list.len {
                both.push(kept[x] && offered[x]);
                if both[x] { m++; }
            }
            d.size_offered[di] += m;
            if constrained(w, pool, text_at, kept, code, end, l.text) > decoder::NONE { d.kept_all[di]++; }
            if di == 1 {                    // at 20 bits: paths through the pruned graph, and a token tree of them
                var paths_to: f64[>..] = [];
                for p in code.len + 1 { paths_to.push(0.0); }
                paths_to[decoder::skip_separators(code, 0)] = 1.0;
                var tokens = 0.0;
                for x in w.list.len {
                    if !both[x] { continue; }
                    let word = w.list[x];
                    let to: i64 = word.to;
                    paths_to[to] += paths_to[word.from];
                    var chars: i64 = 0;
                    each_utf8(pool[text_at[x]..text_at[x + 1]]) { cp => chars++; };
                    tokens += paths_to[word.from] * chars;
                }
                tree_paths.push(paths_to[end]);
                tree_tokens.push(tokens);
            }
            if constrained(w, pool, text_at, both, code, end, l.text) > decoder::NONE { d.kept_offered[di]++; }
        }
    }
    var why: u8[..15] = "";
    if gold_any <= decoder::NONE { why = "graph"; d.graph++; }
    else if gold <= decoder::NONE { why = "cut"; d.cut++; }
    else if mine <= decoder::NONE { why = "whole"; d.whole++; }
    else if gold > mine { why = "search"; d.search++; }
    else { why = "model"; d.model++; }
    var margin: u8[>..] = [];
    if gold > decoder::NONE && mine > decoder::NONE { format_flt(margin, mine - gold, 1); } else { margin.append("-"); }
    format(out, "diag  ", l.category, "  ", why, "  ", margin, " bits  rank ", rank, "  want ", l.text, "  got ", got, "\n");
}


// ---- The emitter experiment: export segments, import emissions ----

fn initial_of(plain: const u8[:]) -> const u8[:] {
    if plain.len >= 2 && (plain[..2] == "zh" || plain[..2] == "ch" || plain[..2] == "sh") { return plain[..2]; }
    return plain[..1];
}

// For one sentence: the first pass's syllables (a token each: the syllable,
// or ^ and its initial if abbreviated), where they start in the input, and
// the characters the pruned graph (offered words within 30 bits) allows at
// each: "number \t tokens \t bounds \t candidates per syllable".
fn export_segments(l: Line, code: const u8[:], out: u8[>..]&) {
    if code.len > lattice::MAX_INPUT { return; }
    var g = lattice::Graph {};
    lattice::build(g, code, spelling::live, lexicon::live);
    var w = decoder::Words {};
    decoder::search(w, g, lexicon::live, code);
    let end = decoder::readable(w, code);
    var path: i64[>..] = [];
    if !decoder::best_line(w, code, end, path) && !decoder::best_path(w, code, end, path) { return; }
    var m = decoder::Menu {};
    var k = path.len - 1;
    while k >= 0 {
        m.path.push(path[k] as u32);
        k--;
    }
    var segs: decoder::Segment[>..] = [];
    decoder::segments(m, w, g, code, false, segs);
    if segs.len == 0 { return; }
    var tokens: u8[>..] = [];
    var bounds: i64[>..] = [];
    for seg in segs {
        let word = w.list[seg.word];
        let pair = session::pair_at(decoder::source_lexicon(word.source), word.entry, seg.depth);
        let plain = lexicon::live.plain[lexicon::live.toned[pair.toned].plain].text;
        if tokens.len > 0 { tokens.push(' '); }
        if g.edges[seg.edge].kind <= spelling::FUZZY { tokens.append(plain); } else { tokens.push('^'); tokens.append(initial_of(plain)); }
        bounds.push(decoder::skip_separators(code, seg.from));
    }
    bounds.push(decoder::skip_separators(code, segs[segs.len - 1].to));
    // candidates: characters of offered words within 30 bits that line up with the syllables
    let offered = offered_mask(w, code, end, grammar::homophones());
    var kept: bool[>..] = [];
    decoder::prune(w, code, end, 30.0, kept);
    var cands: u32[>..] = [];               // flat: position << 32 is not needed; (position, cp) pairs
    var cand_pos: i32[>..] = [];
    for x in w.list.len {
        if !kept[x] || !offered[x] { continue; }
        let word = w.list[x];
        let a = decoder::skip_separators(code, word.from);
        let b = decoder::skip_separators(code, word.to);
        var kf: i64 = -1;
        var kt: i64 = -1;
        for i in bounds.len {
            if bounds[i] == a { kf = i; }
            if bounds[i] == b { kt = i; }
        }
        if kf < 0 || kt < 0 { continue; }
        var text: u8[>..] = [];
        decoder::word_text(word, text);
        var cps: u32[>..] = [];
        each_utf8(text) { cp => cps.push(cp as u32); };
        if cps.len != kt - kf { continue; }
        for i in cps.len {
            var dup = false;
            for j in cands.len { if cand_pos[j] == (kf + i) as i32 && cands[j] == cps[i] { dup = true; break; } }
            if !dup {
                cands.push(cps[i]);
                cand_pos.push((kf + i) as i32);
            }
        }
    }
    format(out, l.number, "\t", tokens, "\t");
    for i in bounds.len { format(out, if i > 0 { " " } else { "" }, bounds[i]); }
    out.push('\t');
    for p in segs.len {
        if p > 0 { out.push(' '); }
        var any = false;
        for j in cands.len { if cand_pos[j] == p as i32 { push_utf8(out, cands[j]); any = true; } }
        if !any { out.push('-'); }
    }
    out.push('\n');
}

struct EmitRecord { k: i32, cp: u32, bits: f64 }
var emit_records: EmitRecord[>..] = [];
var emit_first = dictionary<i64, i64> {};       // sentence line → its first record
var emit_count = dictionary<i64, i64> {};
var emit_bounds_at = dictionary<i64, i64> {};   // sentence line → its bounds in emit_bound_list
var emit_bound_list: i64[>..] = [];
var emit_bound_count = dictionary<i64, i64> {};

// An emitter's scores: "S \t number \t bounds" then "E \t k \t char \t bits" lines.
fn load_emissions(path: const u8[:]) -> bool {
    var data: u8[>..] = [];
    if !read_file(path, data) { return false; }
    var current: i64 = -1;
    for raw in split(data, '\n') {
        let line: const u8[:] = raw;
        if line.len < 3 { continue; }
        let kind, rest, ok = split_once(line, '\t');
        if !ok { continue; }
        if kind == "S" {
            let num, bounds, ok2 = split_once(rest, '\t');
            let n, ok3 = parse_int(num);
            if !ok2 || !ok3 { continue; }
            current = n;
            emit_first.insert(n, emit_records.len);
            emit_count.insert(n, 0);
            emit_bounds_at.insert(n, emit_bound_list.len);
            var c: i64 = 0;
            for b in split(bounds, ' ') {
                let v, ok4 = parse_int(b);
                if ok4 { emit_bound_list.push(v); c++; }
            }
            emit_bound_count.insert(n, c);
        } else if kind == "E" && current >= 0 {
            let ks, rest2, ok2 = split_once(rest, '\t');
            let ch, bits_text, ok3 = split_once(rest2, '\t');
            let k, ok4 = parse_int(ks);
            let bits, ok5 = parse_flt(bits_text);
            if !ok2 || !ok3 || !ok4 || !ok5 { continue; }
            var cp: u32 = 0;
            each_utf8(ch) { c => cp = c as u32; };
            emit_records.push(EmitRecord { k: k as i32, cp: cp, bits: bits });
            let count = emit_count.get(current);
            emit_count.insert(current, (if count { count } else { 0 }) + 1);
        }
    }
    return true;
}

// Puts sentence `number`'s emissions in the decoder, or turns them off.
fn use_emissions(number: i64) {
    decoder::emit_on = false;
    let first = emit_first.get(number);
    if !first { return; }
    let count = emit_count.get(number);
    let at = emit_bounds_at.get(number);
    let nb = emit_bound_count.get(number);
    if !count || !at || !nb { return; }
    decoder::emit_bounds.clear();
    decoder::emit_bounds.append(emit_bound_list[at..at + nb]);
    decoder::emit_start.clear();
    decoder::emit_cp.clear();
    decoder::emit_bits.clear();
    for k in nb - 1 {
        decoder::emit_start.push(decoder::emit_cp.len);
        for r in first..first + count {
            if emit_records[r].k == k as i32 {
                decoder::emit_cp.push(emit_records[r].cp);
                decoder::emit_bits.push(emit_records[r].bits);
            }
        }
    }
    decoder::emit_start.push(decoder::emit_cp.len);
    decoder::emit_on = true;
}


// Where the right sentence ranks among the distinct sentences each search
// finds (--coverage), and what the search costs: the IME's search (one line
// per position and last word, beam 7), then K-best searches keeping 2, 4, 8
// and 16 lines per state with the beam widened to match. Ceilings: the right
// sentence as a path in the graph at all, and through the words offered to
// the beam.
let COVER_K = [1, 4, 16, 64, 256, 1024];
let COVER_CONFIGS = 5;
let COVER_PER_STATE = [1, 2, 4, 8, 16];
let COVER_BEAM = [7, 14, 28, 56, 256];
struct Coverage { n: i64, graph: i64, offered: i64, at: i64[30] }
var cover_ns: i64[>..] = [];                // each sentence's search time, per configuration in turn

fn cover(l: Line, code: const u8[:], c: Coverage&) {
    c.n++;
    if code.len > lattice::MAX_INPUT { return; }
    var g = lattice::Graph {};
    lattice::build(g, code, spelling::live, lexicon::live);
    var w = decoder::Words {};
    decoder::search(w, g, lexicon::live, code);
    let end = decoder::readable(w, code);
    let want = folded_text(l.text);
    var pool: u8[>..] = [];
    var text_at: u32[>..] = [];
    for word in w.list {
        text_at.push(pool.len as u32);
        decoder::word_text(word, pool);
    }
    text_at.push(pool.len as u32);
    var all: bool[>..] = [];
    for x in w.list.len { all.push(true); }
    let offered = offered_mask(w, code, end, grammar::homophones());
    if constrained(w, pool, text_at, all, code, end, l.text) > decoder::NONE { c.graph++; }
    if constrained(w, pool, text_at, offered, code, end, l.text) > decoder::NONE { c.offered++; }
    var seen = dictionary<u64, bool> {};
    for ci in COVER_CONFIGS {
        var paths: i64[>..] = [];
        var scores: f64[>..] = [];
        let t0 = clock_ns();
        let n = decoder::kbest_sentences(w, code, end, COVER_BEAM[ci], grammar::homophones(), COVER_PER_STATE[ci], 1024,
                                         paths, scores);
        cover_ns.push(clock_ns() - t0);
        seen = dictionary<u64, bool> {};
        var rank: i64 = -1;
        var distinct: i64 = 0;
        var at: i64 = 0;
        var text: u8[>..] = [];
        for r in n {
            var e = at;
            while paths[e] >= 0 { e++; }
            text.clear();
            var k = e - 1;
            while k >= at {
                decoder::word_text(w.list[paths[k]], text);
                k--;
            }
            at = e + 1;
            let folded = folded_text(text);
            var h: u64 = 0;
            for cp in folded { h = hash(h ^ ((cp as u64) * 0x9E3779B97F4A7C15)); }
            if seen.contains(h) { continue; }
            seen.insert(h, true);
            if folded == want { rank = distinct; break; }
            distinct++;
        }
        for b in 6 { if rank >= 0 && rank < COVER_K[b] { c.at[ci * 6 + b]++; } }
    }
}

// The decode's K best sentences and their scores (with emissions, when
// loaded), for a verifier: "number \t score \t text" lines.
var timing_rerank = false;                  // --time-rerank: how long the shortlist and its scoring take
var rerank_per_state: i64 = 0;              // --rerank-search=P,B: another search for the shortlist than rerank.img's
var rerank_beam: i64 = 0;
var shortlist_ns: i64[>..] = [];
var scoring_ns: i64[>..] = [];
var top_per_state: i64 = 1;                 // --top-per-state=N: the search behind --export-top
var top_beam: i64 = 7;                      // --top-beam=N

// The reranker's two costs for `code`: the shortlist's search and the
// model's scoring, both at refine in the IME.
fn time_rerank(code: const u8[:]) {
    if code.len > lattice::MAX_INPUT { return; }
    var g = lattice::Graph {};
    lattice::build(g, code, spelling::live, lexicon::live);
    var w = decoder::Words {};
    decoder::search(w, g, lexicon::live, code);
    let end = decoder::readable(w, code);
    let m = rerank::live.meta[0];
    var s = decoder::Shortlist {};
    let t0 = clock_ns();
    let n = decoder::shortlist(w, code, end, m.beam, m.per_state, m.shortlist, s);
    let t1 = clock_ns();
    shortlist_ns.push(t1 - t0);
    var job = rerank::Job { ids: [], starts: [] };
    rerank::clear_job(job);
    for k in n { if !rerank::add(job, decoder::shortlist_text(s, k)) { break; } }
    if rerank::count(job) < 2 { return; }
    var bits: f64[>..] = [];
    let t2 = clock_ns();
    rerank::score(job, bits);
    scoring_ns.push(clock_ns() - t2);
}

fn milliseconds(ns: i64[>..]&) -> u8[>..] {
    var out: u8[>..] = [];
    if ns.len == 0 { return out; }
    sort(ns) { a, b => a < b };
    var total: i64 = 0;
    for x in ns { total += x; }
    format(out, "mean ");
    format_flt(out, (total as f64) / ns.len / 1.0e6, 2);
    format(out, " ms, p99 ");
    format_flt(out, ns[ns.len * 99 / 100] / 1.0e6, 2);
    format(out, " ms");
    return out;
}

fn export_top(l: Line, code: const u8[:], k: i64, out: u8[>..]&) {
    if code.len > lattice::MAX_INPUT { return; }
    var g = lattice::Graph {};
    lattice::build(g, code, spelling::live, lexicon::live);
    var w = decoder::Words {};
    decoder::search(w, g, lexicon::live, code);
    let end = decoder::readable(w, code);
    var paths: i64[>..] = [];
    var scores: f64[>..] = [];
    // A K-best search may find a text more than once (segmented differently):
    // the K best distinct texts, from up to 8 times as many sentences.
    let n = decoder::kbest_sentences(w, code, end, top_beam, grammar::homophones(), top_per_state, k * 8, paths, scores);
    var seen = dictionary<u64, bool> {};
    var written: i64 = 0;
    var at: i64 = 0;
    var text: u8[>..] = [];
    for r in n {
        if written == k { break; }
        var e = at;
        while paths[e] >= 0 { e++; }
        text.clear();
        var j = e - 1;
        while j >= at {
            decoder::word_text(w.list[paths[j]], text);
            j--;
        }
        at = e + 1;
        var h: u64 = 0;
        for cp in folded_text(text) { h = hash(h ^ ((cp as u64) * 0x9E3779B97F4A7C15)); }
        if seen.contains(h) { continue; }
        seen.insert(h, true);
        format(out, l.number, "\t");
        format_flt(out, scores[r], 3);
        format(out, "\t", text, "\n");
        written++;
    }
}

// Whether `arg` is the option `name` ("--name=") with a value, and that value.
fn has(arg: const u8[:], name: const u8[:]) -> bool { arg.len > name.len && starts_with(arg, name) }

fn value(arg: const u8[:]) -> const u8[:] {
    let name, v, ok = split_once(arg, '=');
    return v;
}

fn main() {
    let all = args();
    var diagnosing = false;
    var chained = false;                    // each sentence typed after the one before it, as if just committed
    var export_path: u8[>..] = [];          // --export=FILE: segments, for an emitter
    var top_path: u8[>..] = [];             // --export-top=FILE: the decode's 16 best, for a verifier
    var top: u8[>..] = [];
    var exported: u8[>..] = [];
    var emitting = false;                   // --emissions=FILE: its scores in the decoder
    var covering = false;                   // --coverage: the right sentence's rank in wider searches
    var at: i64[>..] = [];                  // the positional arguments
    for i in all.len {
        if all[i] == "--no-grammar" { session::use_grammar = false; }
        else if all[i] == "--diagnose" { diagnosing = true; }
        else if all[i] == "--chained" { chained = true; }
        else if all[i] == "--coverage" { covering = true; }
        else if all[i] == "--no-english" { english::set_on(false); }
        else if all[i] == "--no-rerank" { rerank::set_on(false); }
        else if all[i] == "--time-rerank" { timing_rerank = true; }
        else if has(all[i], "--rerank-search=") {
            let p, b, ok = split_once(value(all[i]), ',');
            let pv, ok1 = parse_int(p);
            let bv, ok2 = parse_int(b);
            if ok && ok1 && ok2 && pv > 0 && bv > 0 { rerank_per_state = pv; rerank_beam = bv; }
        }
        else if has(all[i], "--top-per-state=") {
            let v, ok = parse_int(value(all[i]));
            if ok { top_per_state = v; }
        }
        else if has(all[i], "--top-beam=") {
            let v, ok = parse_int(value(all[i]));
            if ok { top_beam = v; }
        }
        else if has(all[i], "--export=") { export_path.append(value(all[i])); }
        else if has(all[i], "--export-top=") { top_path.append(value(all[i])); }
        else if has(all[i], "--emissions=") {
            if !load_emissions(value(all[i])) {
                write_stderr("accuracy: cannot read the emissions\n");
                exit(2);
            }
            emitting = true;
        }
        else if has(all[i], "--emit-weight=") {
            let v, ok = parse_flt(value(all[i]));
            if ok { decoder::emit_weight = v; }
        }
        else if has(all[i], "--fit-weight=") {
            let v, ok = parse_flt(value(all[i]));
            if ok { decoder::fit_weight = v; }
        }
        else { at.push(i); }
    }
    if at.len != 3 && at.len != 4 {
        write_stderr("usage: accuracy IMAGES SET_DIR [SCHEME] [--no-grammar]\n");
        exit(2);
    }
    let images = all[at[1]];
    let set_dir = all[at[2]];
    if session::open(images) != 0 || (at.len == 4 && session::set_scheme(all[at[3]]) != 0) {
        write_stderr("accuracy: cannot open the images, or no such scheme\n");
        exit(2);
    }
    session::rerank_sync = true;
    if rerank_per_state > 0 && rerank::mapped {
        rerank::live.meta[0].per_state = rerank_per_state as u8;
        rerank::live.meta[0].beam = rerank_beam as u16;
    }
    spelling::syllable_keys(spelling::live, lexicon::live, keys);
    var plain_ids = dictionary<const u8[:], i64> {};
    for p in lexicon::live.plain.len { plain_ids.insert(lexicon::live.plain[p].text, p); }
    var readings = dictionary<u64, bool> {};
    learn_readings(lexicon::live, readings);
    for k in sets::SLOTS { if sets::used[k] { learn_readings(sets::slot(k), readings); } }

    var words: Line[>..] = [];
    var sentences: Line[>..] = [];
    read_set(str(set_dir, "/words.tsv"), words, plain_ids, readings);
    read_set(str(set_dir, "/sentences.tsv"), sentences, plain_ids, readings);
    if problems > 0 {
        print("accuracy: ", problems, " problem(s) in the set; nothing measured");
        exit(2);
    }
    let full_pinyin = spelling::live.meta[0].id == "fullpinyin";
    let model: u8[>..] = if grammar::on { str(", with the grammar model ", grammar::live.meta[0].language) }
                         else { ", without a grammar model" };
    let reranker: u8[>..] = if rerank::active() { str(", reranked (weight ", rerank::live.meta[0].weight, ")") }
                            else { "" };
    print("accuracy: ", words.len, " words, ", sentences.len, " sentences, typed in ", spelling::live.meta[0].name, model,
          reranker);

    // words, by category
    var categories: u8[..31][>..] = [];
    for l in words { if !contains(categories, l.category) { categories.push(l.category); } }
    var hits: i64 = 0;
    var gated: i64 = 0;
    var gated_hits: i64 = 0;
    var absent: i64 = 0;
    var misses: u8[>..] = [];
    for cat in categories {
        var n: i64 = 0;
        var h: i64 = 0;
        for l in words {
            if l.category != cat { continue; }
            n++;
            var code: u8[>..] = [];
            code_of(l, full_pinyin, code);
            var got: u8[>..] = [];
            let place = decode(code, l.text, got);
            if place == 0 && got == l.text {
                h++;
                continue;
            }
            let known = in_lexicon(l);
            if !known { absent++; }
            format(misses, "miss  ", cat, "  ", code, "  want ", l.text, "  got ", got, "  (want is ");
            if place >= 0 { format(misses, "#", place + 1); } else { format(misses, "not offered"); }
            format(misses, if known { ")\n" } else { ", not in the lexicon)\n" });
        }
        hits += h;
        let gate = cat == "common" || cat == "idioms";
        if gate {
            gated += n;
            gated_hits += h;
        }
        print("  ", cat, ": ", percent(h, n), " first (", h, " of ", n, ")", if gate { ", gated" } else { "" });
    }
    print("words: ", percent(hits, words.len), " first (", hits, " of ", words.len, "); ",
          words.len - hits - absent, " misses ranked, ", absent, " not in the lexicon");

    // sentences, by set
    var sentence_misses: u8[>..] = [];
    var english_first: i64 = 0;
    var latin_first: i64 = 0;               // a first candidate with any Latin letter in it (我用GitHub)
    var halves: i64 = 0;                    // sentences half typed, to a syllable's end
    var halves_english: i64 = 0;            // ... with an English word first over a weak Chinese reading
    var halves_sample: u8[>..] = [];
    var sets: u8[..31][>..] = [];
    for l in sentences { if !contains(sets, l.category) { sets.push(l.category); } }
    for set in sets {
        var n: i64 = 0;
        var whole: i64 = 0;
        var exact: i64 = 0;
        var right_chars: i64 = 0;
        var all_chars: i64 = 0;
        var split_inputs: i64 = 0;
        var d = Diagnosis { graph: 0, cut: 0, search: 0, model: 0, whole: 0, long: 0, right: 0, top: [0; 6], wide: 0,
                            sized: 0, words: 0, offered: 0, chars: 0, fixable: 0, kept_all: [0; 6],
                            kept_offered: [0; 6], size_all: [0; 6], size_offered: [0; 6] };
        var cov = Coverage { n: 0, graph: 0, offered: 0, at: [0; 30] };
        cover_ns.clear();
        var before: u8[>..] = [];
        for l in sentences {
            if l.category != set { continue; }
            n++;
            decoder::preceding.clear();
            if chained && before.len > 0 { decoder::preceding.append(before); decoder::preceding.append("，"); }
            if emitting { use_emissions(l.number); }
            before.clear();
            before.append(l.text);
            // Typed as the IME takes it: when the input is full, the next key
            // commits the best reading's first word to make room.
            var code: u8[>..] = [];
            code_of(l, full_pinyin, code);
            // On the way: each prefix that ends a syllable, as the user sees
            // it while typing. An English word must not take first place over
            // a half-typed sentence either.
            if english::active() {
                let reranking = rerank::on;     // English placement comes before the reranker: not needed here
                rerank::set_on(false);
                var prefix: u8[>..] = [];
                for k in l.count - 1 {
                    if full_pinyin && (l.apostrophes >> k & 1) != 0 { prefix.push('\''); }
                    prefix.append(keys[l.syls[k]].text);
                    if prefix.len > 60 { break; }
                    session::clear_composition();
                    session::input.append(prefix);
                    session::rebuild();
                    halves++;
                    if session::first_has_english() {
                        halves_english++;
                        if halves_sample.len < 400 { format(halves_sample, " ", prefix, "→", l.text); }
                    }
                }
                rerank::set_on(reranking);
            }
            session::clear_composition();
            session::commit.clear();
            var made_room = false;
            var english_led = false;
            for c in code {
                if !session::room() {
                    session::rebuild();
                    if session::lead_is_english() { english_led = true; }
                    session::make_room();
                    made_room = true;
                }
                session::input.push(c);
            }
            session::rebuild();
            var got: u8[>..] = [];
            got.append(session::commit);
            if session::menu.candidates.len > 0 {
                let c = session::menu.candidates[0];
                let text = session::menu.pool[c.text..c.text + c.len];
                if session::first_has_english() { english_led = true; }
                got.append(text);
            }
            if english_led { english_first++; }
            for b in got { if (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') { latin_first++; break; } }
            if made_room { split_inputs++; }
            if diagnosing { diagnose(l, code, got, d, sentence_misses); }
            if export_path.len > 0 { export_segments(l, code, exported); }
            if timing_rerank && rerank::active() { time_rerank(code); }
            if top_path.len > 0 { export_top(l, code, 16, top); }
            if covering { cover(l, code, cov); }
            var a: u32[>..] = [];
            each_utf8(l.text) { cp => a.push(folded(cp as u32)); };
            var b: u32[>..] = [];
            each_utf8(got) { cp => b.push(folded(cp as u32)); };
            all_chars += a.len;
            right_chars += max(0, a.len - edit_distance(a, b));
            if got == l.text { exact++; }
            if a == b { whole++; } else {
                format(sentence_misses, "miss  ", l.category, "  ", code, "  want ", l.text, "  got ", got, "\n");
            }
        }
        if covering && cov.n > 0 {
            print("coverage, ", set, ": the right sentence in the graph ", percent(cov.graph, cov.n),
                  ", through the words offered to the beam ", percent(cov.offered, cov.n), "; among the K best distinct:");
            for ci in COVER_CONFIGS {
                var line: u8[>..] = [];
                for b in 6 { format(line, "  ", COVER_K[b], ": ", percent(cov.at[ci * 6 + b], cov.n)); }
                var times: i64[>..] = [];
                var i = ci;
                while i < cover_ns.len {
                    times.push(cover_ns[i]);
                    i += COVER_CONFIGS;
                }
                sort(times) { a, b => a < b };
                var total: i64 = 0;
                for t in times { total += t; }
                let mean = if times.len > 0 { total / times.len / 1000 } else { 0 };
                let p99 = if times.len > 0 { times[times.len * 99 / 100] / 1000 } else { 0 };
                print("  ", COVER_PER_STATE[ci], " per state, beam ", COVER_BEAM[ci], ":", line, "   search mean ", mean,
                      " µs, p99 ", p99, " µs");
            }
        }
        if diagnosing {
            print("diagnosis, ", set, ": of ", n - d.right, " wrong (", d.long, " too long to diagnose): graph ", d.graph,
                  ", cut ", d.cut, ", search ", d.search, ", model ", d.model, ", whole-word candidate ", d.whole);
            print("  the right sentence among the beam's best: top 1 ", d.top[0], ", 2 ", d.top[1], ", 5 ", d.top[2],
                  ", 10 ", d.top[3], ", 20 ", d.top[4], ", 50 ", d.top[5], "; a search 9 times as wide (beam 64, ",
                  "32 homophones) gets ", d.wide, " more right");
            if d.sized > 0 {
                print("  graphs of the wrong ones: ", d.words / d.sized, " words found, ", d.offered / d.sized,
                      " offered to the beam, for ", d.chars / d.sized, " characters (means)");
            }
            if tree_paths.len > 0 {
                sort(tree_paths) { a, b => a < b };
                sort(tree_tokens) { a, b => a < b };
                let m = tree_paths.len;
                print("  at 20 bits, offered words: full paths median ", tree_paths[m / 2], ", p90 ", tree_paths[m * 9 / 10],
                      "; tokens in a tree of them all median ", tree_tokens[m / 2], ", p90 ", tree_tokens[m * 9 / 10]);
                tree_paths.clear();
                tree_tokens.clear();
            }
            if d.fixable > 0 {
                print("  pruned to delta bits (P2): the right sentence survives / mean words kept, of ", d.fixable,
                      " in the graph:");
                for di in 6 {
                    print("    ", DELTAS[di], ": all words ", percent(d.kept_all[di], d.fixable), " / ",
                          d.size_all[di] / d.fixable, "; offered ", percent(d.kept_offered[di], d.fixable), " / ",
                          d.size_offered[di] / d.fixable);
                }
            }
        }
        print("sentences, ", set, ": ", percent(whole, n), " right as a whole (", whole, " of ", n, "; ", exact,
              " exactly, without counting 他/她/它 or 的/地/得 as one), ", percent(right_chars, all_chars),
              " of characters right; ", split_inputs, " over ", lattice::MAX_INPUT,
              " keys, so first words were committed to make room");
    }

    if export_path.len > 0 {
        if !write_file(export_path, exported) { write_stderr("accuracy: cannot write the export\n"); }
    }
    if top_path.len > 0 {
        if !write_file(top_path, top) { write_stderr("accuracy: cannot write the top sentences\n"); }
    }
    decoder::emit_on = false;
    write_stdout(misses);
    write_stdout(sentence_misses);
    print("english: ", english_first, " corpus sentences with an English word first (gate: 0); ", latin_first,
          " with a Latin letter anywhere in the first candidate; ", halves_english, " of ", halves,
          " half-typed sentences (to a syllable's end) with one first over a weak Chinese reading (gate: 0)",
          halves_sample);
    if timing_rerank && shortlist_ns.len > 0 {
        let m = rerank::live.meta[0];
        print("rerank: the shortlist (", m.per_state, " per state, beam ", m.beam, ") ", milliseconds(shortlist_ns),
              "; scoring it ", milliseconds(scoring_ns));
    }
    print("gate: ", percent(gated_hits, gated), " of the common words and idioms first (", gated_hits, " of ", gated,
          "; at least 95%)");
    if english_first != 0 {
        print("accuracy: an English word came first for a corpus sentence");
        exit(1);
    }
    if halves_english != 0 {
        print("accuracy: an English word came first for a half-typed corpus sentence");
        exit(1);
    }
    if gated == 0 || 100 * gated_hits < 95 * gated {
        print("accuracy: common words and idioms below the 95% gate");
        exit(1);
    }
}
