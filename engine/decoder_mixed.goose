// Mixed sentences: Chinese and English words over the same keys
// (docs/mixed-input-design.md). A beam of its own weighs the mixture, from
// where the Chinese search's front leaves off, and place_mixed puts the best
// mixed sentence into the menu.
import std;
import userdb;
import grammar;
import english;
import semantic;
import decoder;
import decoder_english;
import decoder_sentence;
import decoder_menu;

namespace decoder;

let EN_SWITCH = -5.0;        // once per ZH↔EN boundary, not between two English words
let EN_TOP1 = 18.0;          // mixed score − Chinese score, to take the first place
let EN_PAGE = 2.0;           // ...to stay on the first page, behind the Chinese
let SEM_LIFT = 8.0;          // most a Chinese sense of an English word may add over the score it already has
let SENSE_PRIOR = 0.15;      // per bit a sense is rarer than the word's commonest sense
let EN_FINAL_BA = 12.0;      // 吧 ending the input after an English word that has a Chinese sense
var mixed_beam: i64 = 4;     // states kept per position

fn set_mixed_beam(n: i64) {
    if n >= 1 { mixed_beam = n; }
}

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
    guard from < w.front_n.len && w.front_n[from] > 0 else { return -1, -1, 0.0; }
    let en_from: i64 = en.from;
    let en_end: i64 = en.end;
    guard en_end > en_from && en_end <= input.len && !span_capital(en_from, en_end - en_from) else { return -1, -1, 0.0; }
    let row = semantic::find_row(input[en_from..en_end]);
    guard row >= 0 else { return -1, -1, 0.0; }
    let last: i64 = w.front_ids[w.front_at[from] + w.front_n[from] - 1];
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

// The same inside a mixed sentence, which what was committed last does not
// reach into.
fn mixed_boost(w: Words&, anterior: i64, prev: i64, current: i64) -> f64 {
    if userdb::pom.len == 0 || prev < 0 { return 0.0; }
    return recalled(w, surface_of(w, prev), surface_of(w, anterior), current);
}

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
        if after_chinese && !reached_front(w, from) { continue; }
        var score = (if after_chinese { w.front_score[from] } else { 0.0 }) + word.score;
        var zh_at: i32 = -1;
        var tail: i32 = -1;
        var tail_head: i32 = -1;
        if after_chinese {
            score += EN_SWITCH;
            if w.front_n[from] > 0 { zh_at = w.front_ids[w.front_at[from] + w.front_n[from] - 1]; }
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
    if anchor > begin && reached_front(w, anchor) {
        let a: i64 = w.front_at[anchor];
        let count: i64 = w.front_n[anchor];
        if st.tail >= 0 && count > 0 {
            for k in a..a + count - 1 { words.push(w.front_ids[k]); }
            if st.tail_head >= 0 { words.push(st.tail_head); }
            words.push(st.tail);
        } else {
            for k in a..a + count { words.push(w.front_ids[k]); }
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
    if !reached_front(w, input.len) {
        slot = if short_en { 2 } else { 0 };    // Chinese cannot read the keys (github)
    } else {
        let lead = score - w.front_score[input.len];
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
    guard english.len > 0 && input.len > 0 && w.front_score.len == input.len + 1 else { return false; }
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
