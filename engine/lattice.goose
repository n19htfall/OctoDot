// The syllable graph over typed letters: every way to read the input as
// spellings, each edge standing for a set of toneless syllables.
//
// A ' separates syllables and is never part of one. The last stretch of
// input may be the start of a longer spelling ("zho"), which then stands
// for every syllable those spellings do, at a penalty: completion.
//
// What else is typed with a syllable becomes a constraint on its edge, which
// the word search applies before it keeps anything:
//   a tone      7 8 9 0 (first to fourth, 0 also neutral), 万象's tone
//               spellings: "zhong7" reads only zhōng
//   a shape     ` and one or two letters after the syllable: its character
//   code        must have an auxiliary code starting with them ("shi`o")
import std;
import lexicon;
import spelling;

namespace lattice;

// Keys in one composition. A long clause in full pinyin runs past it (8 of
// zhihu120's 120 sentences, up to 90 letters); the session then commits the
// best reading's first word to make room, so no key is lost. Raising it
// buys no accuracy (zhihu120 scores the same at 64, 80, 96 and 128) and
// costs time: abbreviation-heavy input takes about 50 µs more per letter,
// past the 5 ms gate by 99 letters.
let MAX_INPUT = 64;
let LN2 = 0.6931471805599453;
let COMPLETION_PENALTY = -1.0;      // log2: a half-typed syllable counts half

// log2 units, ≤ 0: charged to a syllable that starts with a, o or e right
// after another syllable with no ' between them. Pinyin spelling asks for
// the ' there (xi'an, fang'an), so a reading that needs one is less likely
// when it was not typed. Off: measured, it barely helps and it flips words
// people type every day to the rarer spelled-out reading (fangan → 反感
// instead of 方案, 8.8 times as frequent). Kept as a setting.
var vowel_split_penalty = 0.0;

// input[from..to] read as one spelling; its syllables are syls[syls..syls + count].
// With a tone typed, its readings are limited to the toned syllables
// tones[tones..tones + tone_count]; with a shape code, its characters to
// those input[aux..aux + aux_len] fits.
struct Edge { from: u8, to: u8, syls: u32, count: u16, kind: u8, tones: u32, tone_count: u16, aux: u8, aux_len: u8 }

// A syllable an edge stands for, with its credibility in log2 units (≤ 0).
struct Syl { plain: u16, credibility: f32 }

root struct Graph {
    edges: Edge[>..] = [],
    syls: Syl[>..] = [],
    tones: u16[>..] = [],       // toned syllable ids, for edges with a tone
    first_edge: u32[>..] = []   // the edges from position p: edges[first_edge[p]..first_edge[p + 1]]
}

fn clear(g: Graph&) {
    g.edges.clear();
    g.syls.clear();
    g.tones.clear();
    g.first_edge.clear();
}

fn has_digit(text: const u8[:]) -> bool {
    for c in text { if c >= '0' && c <= '9' { return true; } }
    return false;
}

fn is_letter(c: u8) -> bool { c >= 'a' && c <= 'z' }

// An edge from `from` to `to` for spellings [s_lo, s_hi): the union of their
// syllables, each with its best credibility, sorted by syllable id. Tone
// spellings ("zhong7") count only when typed in full (`tones`), and then
// also limit the edge to their toned syllables. With `syllables_only`, a
// spelling counts only for a syllable it spells exactly. 万象's typo
// spellings are dropped at preparation (docs/remove-typo-spellings.md);
// the guard remains for the spellings that are not syllables (a variant
// such as lve). False if no edge was added.
fn add(g: Graph&, sp: spelling::Table&, lex: lexicon::Lexicon&, from: i64, to: i64, s_lo: i64, s_hi: i64,
       penalty: f64, tones: bool, syllables_only: bool) -> bool {
    let start = g.syls.len;
    let tone_start = g.tones.len;
    var kind: i64 = spelling::INVALID;
    for s in s_lo..s_hi {
        let spelled = sp.spellings[s];
        let toned = has_digit(spelled.text);
        if toned && !tones { continue; }
        for r in spelled.rows..spelled.rows + spelled.count {
            let row = sp.rows[r];
            if !spelling::usable(row) { continue; }     // a fuzzy spelling whose groups are off
            let plain: i64 = lex.toned[row.toned].plain;
            if syllables_only && compare(lex.plain[plain].text, spelled.text) != 0 { continue; }
            if toned && !contains(g.tones[tone_start..], row.toned) { g.tones.push(row.toned); }
            let credibility = (row.credibility as f64) / LN2 + penalty;
            if row.kind < kind { kind = row.kind; }
            var found = false;
            for i in start..g.syls.len {
                if g.syls[i].plain == plain {
                    if credibility > g.syls[i].credibility { g.syls[i].credibility = credibility as f32; }
                    found = true;
                    break;
                }
            }
            if !found { g.syls.push(Syl { plain: plain as u16, credibility: credibility as f32 }); }
        }
    }
    if g.syls.len == start { return false; }
    sort(g.syls[start..]) { a, b => a.plain < b.plain };
    g.edges.push(Edge { from: from as u8, to: to as u8, syls: start as u32, count: (g.syls.len - start) as u16,
                        kind: kind as u8, tones: tone_start as u32, tone_count: (g.tones.len - tone_start) as u16,
                        aux: 0, aux_len: 0 });
    return true;
}

// If ` follows the edge just added, the same edge again with the shape code
// typed after it: one letter or two (a code has two; with more letters
// after, the graph decides where the code ends). A ` with nothing after it
// yet constrains nothing. Only a syllable spelled out takes a code, so
// "zhong`k" cannot be read as "zhon" (万象 accepts it for zhong) and an
// initial "g" with the code.
fn shape(g: Graph&, input: const u8[:]) {
    let e = g.edges[g.edges.len - 1];
    let at: i64 = e.to;
    guard at < input.len && input[at] == '`' && e.kind <= spelling::FUZZY else { return; }
    var letters: i64 = 0;
    while at + 1 + letters < input.len && letters < 2 && is_letter(input[at + 1 + letters]) { letters++; }
    if letters == 0 {
        var bare = e;
        bare.to = (at + 1) as u8;
        g.edges.push(bare);
        return;
    }
    for k in 1..letters + 1 {
        var coded = e;
        coded.to = (at + 1 + k) as u8;
        coded.aux = (at + 1) as u8;
        coded.aux_len = k as u8;
        g.edges.push(coded);
    }
}

// Builds the graph for `input`: letters, ' separators, tone digits and `
// shape codes, at most MAX_INPUT bytes (longer input is cut there).
fn build(g: Graph&, typed: const u8[:], sp: spelling::Table&, lex: lexicon::Lexicon&) {
    clear(g);
    let input = if typed.len > MAX_INPUT { typed[..MAX_INPUT] } else { typed };
    let longest: i64 = sp.meta[0].longest;
    for i in input.len + 1 {
        g.first_edge.push(g.edges.len as u32);
        if i == input.len || !is_letter(input[i]) || (i > 0 && input[i - 1] == '`') { continue; }
        var whole = false;          // does a spelling run exactly to the end?
        let split: f64 = if i > 0 && input[i - 1] != '\'' && (input[i] == 'a' || input[i] == 'o' || input[i] == 'e') {
            vowel_split_penalty
        } else { 0.0 };
        for len in 1..longest + 1 {
            if i + len > input.len || input[i + len - 1] == '\'' || input[i + len - 1] == '`' { break; }
            let s = spelling::find(sp, input[i..i + len]);
            if s >= 0 && add(g, sp, lex, i, i + len, s, s + 1, split, true, false) {
                if i + len == input.len { whole = true; }
                shape(g, input);
            }
        }
        // A half-typed last syllable. Where the keys spell pinyin, it completes
        // to a syllable. 万象's typo spellings are dropped at preparation
        // (docs/remove-typo-spellings.md), so "lina" is li na. The guard
        // remains for the spellings that are not syllables (a variant such
        // as lve). Other schemes' keys spell no syllable, so any spelling
        // completes.
        let rest = input[i..];
        if !whole && rest.len <= longest && find(rest, "'") < 0 && find(rest, "`") < 0 {
            let lo, hi = spelling::prefixed(sp, rest);
            let pinyin_keys = sp.meta[0].preedit == spelling::PREEDIT_TYPED;
            if lo < hi { add(g, sp, lex, i, input.len, lo, hi, COMPLETION_PENALTY + split, false, pinyin_keys); }
        }
    }
    g.first_edge.push(g.edges.len as u32);
}
