// Ranking without an outside corpus, judged by the lexicon itself.
//
//   words    common entries of 2-4 syllables, each the most frequent entry
//            for its code, typed as plain pinyin with no ': is that entry
//            the first candidate? A miss here is over-splitting: frequent
//            single characters beating a real word.
//   phrases  two or three such words typed together: is their
//            concatenation first? A miss here is over-merging: a long entry
//            swallowing a word boundary that was really there.
//   probes   the first candidates for some well-known ambiguous inputs.
//
// A word penalty trades one error for the other, which is what this
// measures, for a few values of it and of the vowel-split penalty.
//
// In another input scheme, each syllable is typed with that scheme's own
// keys for it (its shortest spelling that stands for that syllable alone).
//
// This measures the decoder without context, so the grammar model stays
// off: its phrases are unrelated words strung together, which a model of
// real text rightly reads otherwise (77.5% of them first with the model
// on, 96.7% without). Real text is make accuracy's: Zhihu sentences.
//
//   eval IMAGES [SCHEME]
import std;
import os;
import octo from "..";

// The keys for each toneless syllable in the scheme in use.
var keys: spelling::Keys[>..] = [];

fn learn_keys() { spelling::syllable_keys(spelling::live, lexicon::live, keys); }

fn code_of(i: i64, out: u8[>..]&) {
    let e = lexicon::live.entries[i];
    for k in e.len { out.append(keys[lexicon::syl(lexicon::live, e, k)].text); }
}

fn text_of(i: i64, out: u8[>..]&) { lexicon::text(lexicon::live, i, out); }

// The first candidate for `input`, decoded in one go.
fn first(input: const u8[:], out: u8[>..]&) {
    session::input.clear();
    session::input.append(input);
    session::rebuild();
    if session::menu.candidates.len > 0 {
        let c = session::menu.candidates[0];
        out.append(session::menu.pool[c.text..c.text + c.len]);
    }
}

// A user typing `code` for `want`: the first candidate when it is right,
// otherwise the longest candidate that starts what is still wanted, again
// and again, as people build a phrase the engine got wrong. Selections teach
// the user dictionary. False if no candidate fits at some point.
fn simulate(code: const u8[:], want: const u8[:]) -> bool {
    session::clear_composition();
    session::commit.clear();
    session::input.append(code);
    session::rebuild();
    var done: i64 = 0;                      // bytes of `want` confirmed
    while session::composing() {
        var best: i64 = -1;
        var best_len: i64 = 0;
        for i in session::menu.candidates.len {
            let c = session::menu.candidates[i];
            let text = session::menu.pool[c.text..c.text + c.len];
            let rest = want[done..];
            let whole = c.to == session::input.len;
            if text.len <= rest.len && compare(rest[..text.len], text) == 0 && text.len > best_len &&
               (!whole || text.len == rest.len) {
                best = i;
                best_len = text.len;
            }
        }
        if best < 0 {
            session::clear_composition();
            return false;
        }
        done += best_len;
        session::select(best);
    }
    return compare(session::commit, want) == 0;
}

fn phrase_parts(phrases: const i64[:], p: i64, code: u8[>..]&, want: u8[>..]&) {
    for k in 3 {
        if phrases[p + k] >= 0 {
            code_of(phrases[p + k], code);
            text_of(phrases[p + k], want);
        }
    }
}

// Top-1 over phrases [from, to) of the phrase list, as a percentage.
fn phrase_top1(phrases: const i64[:], from: i64, to: i64) -> f64 {
    var hits: i64 = 0;
    var p = from * 3;
    while p < to * 3 {
        var code: u8[>..] = [];
        var want: u8[>..] = [];
        phrase_parts(phrases, p, code, want);
        var got: u8[>..] = [];
        first(code, got);
        if compare(got, want) == 0 { hits++; }
        p += 3;
    }
    return 100.0 * hits / (to - from);
}

fn main() {
    let argv = args();
    if argv.len != 2 && argv.len != 3 {
        write_stderr("usage: eval IMAGES [SCHEME]\n");
        exit(2);
    }
    session::use_grammar = false;
    if session::open(argv[1]) != 0 || (argv.len == 3 && session::set_scheme(argv[2]) != 0) {
        write_stderr("eval: cannot open the images, or no such scheme\n");
        exit(2);
    }
    learn_keys();
    print("scheme: ", spelling::live.meta[0].name);
    // Samples are chosen by a hash of each entry's text, not by its index, so
    // they stay the same when entries are added or removed elsewhere and
    // results compare across lexicon releases.
    //   words      weight at least 1000 (about the top tenth) and the most
    //              frequent entry for their code: one in 27, about 3,000
    //   frequent   the same kind of entry, of any weight, each drawn with
    //              probability weight / 280,000: as often as they are typed
    let common = round(log2(1001.0) * lexicon::WEIGHT_SCALE);
    var words: i64[>..] = [];
    var frequent: i64[>..] = [];
    let n = lexicon::live.entries.len;
    for i in n {
        let e = lexicon::live.entries[i];
        if e.len < 2 || e.len > 4 { continue; }
        var text: u8[>..] = [];
        lexicon::text(lexicon::live, i, text);
        let h = hash(text);
        let as_word = e.weight >= common && h % 27 == 0;
        let w = exp2(e.weight / lexicon::WEIGHT_SCALE) - 1.0;
        let as_frequent = (h >> 11) / 9007199254740992.0 * 280000.0 < w;
        if !as_word && !as_frequent { continue; }
        var code: u16[>..] = [];
        for k in e.len { code.push(lexicon::syl(lexicon::live, e, k) as u16); }
        let lo, hi = lexicon::exact(lexicon::live, code);
        if lo != i { continue; }
        var beaten = false;                     // a mounted set may hold a heavier word for this code
        for k in sets::SLOTS {
            if !sets::used[k] { continue; }
            let slo, shi = lexicon::exact(sets::slot(k), code);
            if slo < shi && sets::slot(k).entries[slo].weight > e.weight { beaten = true; }
        }
        if beaten { continue; }
        if as_word { words.push(i); }
        if as_frequent { frequent.push(i); }
    }
    var r = rng { 2026 };
    var phrases: i64[>..] = [];                     // three word indices per phrase; -1 for none
    while phrases.len < 3 * 1500 {
        let count = 2 + r.rand_int(2);
        var letters: i64 = 0;
        var picked: i64[3] = [-1; 3];
        for k in count {
            picked[k] = words[r.rand_int(words.len)];
            letters += lexicon::live.entries[picked[k]].len * 6;
        }
        if letters > 64 { continue; }
        for k in 3 { phrases.push(picked[k]); }
    }

    let probes = ["xian", "xi'an", "fangan", "fang'an", "minge", "caiken", "shishi", "keyi", "jiaoyu", "dajia", "yixia",
                  "woaini", "tianan", "jiangan", "zhongguorenmin", "womenyiqiqu"];
    print(words.len, " words, ", frequent.len, " drawn by frequency, ", phrases.len / 3, " phrases");
    print("word | split | inner abbreviation | words top-1 | phrases top-1 | words by frequency top-1");
    for setting in 7 {
            let wp = if setting == 0 { 0.0 } else if setting == 6 { 9.0 } else { 6.0 };
            let sp = if setting == 2 { -2.0 } else if setting == 3 || setting == 5 { -4.0 } else { 0.0 };
            let ip = if setting >= 4 { -4.0 } else { 0.0 };
            decoder::word_penalty = wp;
            lattice::vowel_split_penalty = sp;
            decoder::inner_abbreviation_penalty = ip;
            var word_hits: i64 = 0;
            for i in words {
                var code: u8[>..] = [];
                code_of(i, code);
                var want: u8[>..] = [];
                text_of(i, want);
                var got: u8[>..] = [];
                first(code, got);
                if compare(got, want) == 0 { word_hits++; }
            }
            var phrase_hits: i64 = 0;
            var p: i64 = 0;
            while p < phrases.len {
                var code: u8[>..] = [];
                var want: u8[>..] = [];
                for k in 3 {
                    if phrases[p + k] >= 0 {
                        code_of(phrases[p + k], code);
                        text_of(phrases[p + k], want);
                    }
                }
                var got: u8[>..] = [];
                first(code, got);
                if compare(got, want) == 0 { phrase_hits++; }
                p += 3;
            }
            var frequent_hits: i64 = 0;
            for i in frequent {
                var code: u8[>..] = [];
                code_of(i, code);
                var want: u8[>..] = [];
                text_of(i, want);
                var got: u8[>..] = [];
                first(code, got);
                if compare(got, want) == 0 { frequent_hits++; }
            }
            var c: u8[>..] = [];
            format_flt(c, 100.0 * frequent_hits / frequent.len, 1);
            var a: u8[>..] = [];
            format_flt(a, 100.0 * word_hits / words.len, 1);
            var b: u8[>..] = [];
            format_flt(b, 100.0 * phrase_hits / (phrases.len / 3), 1);
            print("  ", wp, " | ", sp, " | ", ip, " | ", a, "% | ", b, "% | ", c, "%");
    }
    // Learning: a user types the first half of the phrases (picking pieces
    // where the engine is wrong), then both halves are measured again: the
    // half typed shows what was learned, the other half what it costs
    // elsewhere. For a few values of the bonus a learned word gets.
    decoder::word_penalty = 6.0;
    lattice::vowel_split_penalty = 0.0;
    decoder::inner_abbreviation_penalty = -4.0;
    let half = phrases.len / 6;
    userdb::clock_override = 1794000000;
    let typed_before = phrase_top1(phrases, 0, half);
    let other_before = phrase_top1(phrases, half, 2 * half);
    var line: u8[>..] = [];
    format(line, "learning, phrases first: typed half ");
    format_flt(line, typed_before, 1);
    format(line, "%, other half ");
    format_flt(line, other_before, 1);
    format(line, "% before");
    print(line);
    print("bonus (bits) | typed half after | other half after | could not be built");
    for bonus in [2.0, 4.0, 6.0, 8.0] {
        userdb::reset();
        userdb::bonus_bits = bonus;
        var failed: i64 = 0;
        var p: i64 = 0;
        while p < half * 3 {
            var code: u8[>..] = [];
            var want: u8[>..] = [];
            phrase_parts(phrases, p, code, want);
            if !simulate(code, want) { failed++; }
            p += 3;
        }
        var a: u8[>..] = [];
        format_flt(a, phrase_top1(phrases, 0, half), 1);
        var b: u8[>..] = [];
        format_flt(b, phrase_top1(phrases, half, 2 * half), 1);
        print("  ", bonus, " | ", a, "% | ", b, "% | ", failed, " (", userdb::lex.entries.len, " words learned)");
    }
    userdb::reset();
    userdb::bonus_bits = 6.0;
    userdb::clock_override = 0;

    decoder::word_penalty = 6.0;
    lattice::vowel_split_penalty = -4.0;
    decoder::inner_abbreviation_penalty = -4.0;
    var shown: i64 = 0;
    var q: i64 = 0;
    while q < phrases.len && shown < 12 {
        var code: u8[>..] = [];
        var want: u8[>..] = [];
        for k in 3 {
            if phrases[q + k] >= 0 {
                code_of(phrases[q + k], code);
                text_of(phrases[q + k], want);
            }
        }
        var got: u8[>..] = [];
        first(code, got);
        if compare(got, want) != 0 {
            print("miss  ", code, "  want ", want, "  got ", got);
            shown++;
        }
        q += 3;
    }
    for setting in (if spelling::live.meta[0].id == "fullpinyin" { 2 } else { 0 }) {   // probes are full pinyin
        decoder::word_penalty = if setting == 0 { 0.0 } else { 6.0 };
        lattice::vowel_split_penalty = if setting == 0 { 0.0 } else { -4.0 };
        decoder::inner_abbreviation_penalty = if setting == 0 { 0.0 } else { -4.0 };
        var line: u8[>..] = [];
        format(line, if setting == 0 { "probes, no penalties:" } else { "probes, 6 / -4 / -4:" });
        for probe in probes {
            var got: u8[>..] = [];
            first(probe, got);
            format(line, "  ", probe, "→", got);
        }
        print(line);
    }
}
