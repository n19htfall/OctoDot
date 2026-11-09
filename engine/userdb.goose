// The user dictionary: what this user has chosen, learned from their
// conversions and used in ranking. It keeps two kinds of memory:
//
//   words     learned words by their syllables. They form a small lexicon
//             of the same shape as the main one (lexicon::Lexicon), so the
//             word search walks it unchanged. A learned word scores like the
//             best lexicon word for the same syllables (or a floor, for a
//             phrase the lexicon lacks), plus a bonus that grows with use.
//             This is what carries a choice over to other input: 西安 chosen
//             for "xian" also wins for "xi'an", in sentences and in "xa".
//   choices   which text was chosen for exactly this typed input. Among the
//             candidates covering the same input, a chosen one comes first,
//             whatever the scores say: "mgs" chose 美国式, so next time "mgs"
//             offers it first.
//   english   an English word picked for a code (docs/english-design.md):
//             code, text, uses, day. It ranks like a choice and decays like one.
//
// Both decay: a use counts half after HALF_LIFE_DAYS without another, and
// what has not been used for COLD_DAYS is dropped when saved.
//
// Every change carries the commit it came from, so a commit the user deletes
// right away and types again differently can be taken back (retract), and
// changes from the last 15 minutes can be forgotten. Each word and choice
// also keeps what it was before its first use today (its base), so that
// forgetting today takes back only today's uses: a word used for months and
// once more today goes back to how it was this morning, and only what was
// first learned today goes.
//
// Persistence is a versioned text format of OctoDot's own, not a Goose
// image, so it survives compiler and lexicon upgrades: words are stored by
// their text and toned pinyin, not by ids. The host encrypts it at rest.
// Use is kept by local day only: no times, and never which app.
import std;
import os;
import math;
import dictionary;
import lexicon;

namespace userdb;

let HEADER = "# OctoDot user dictionary 1";
let WORDS_SECTION = "# words: text, toned pinyin, uses, local day";
let CHOICES_SECTION = "# choices: input as typed, text, uses, local day";
let ENGLISH_SECTION = "# english: code, text, uses, local day";
let MAX_PHRASE = 16;            // syllables in a learned phrase (decoder::MAX_DEPTH)
let MAX_SENTENCE = 6;           // syllables in a sentence accepted in one go that becomes a word
let MAX_WORDS = 100000;         // the least used go first beyond these
let MAX_CHOICES = 50000;
let MAX_ENGLISH = 20000;
let MAX_INPUT = 64;             // keys in a choice's input (lattice::MAX_INPUT)
let HALF_LIFE_DAYS = 90.0;
let COLD_DAYS = 365;            // unused this long: dropped when saved
let FLOOR_BITS = 12.0;          // a learned phrase the lexicon lacks scores at least weight 4096
let RECENT_SECONDS = 900;       // forget(RECENT): the last 15 minutes

// How much a use counts: a word the user picked themselves twice as much as
// one that came along in a sentence the engine proposed, so that an accepted
// sentence does not echo the engine's own guess back into it louder than the
// user's corrections.
let EXPLICIT = 2.0;
let INCIDENTAL = 1.0;

// forget() scopes
let RECENT = 0;
let TODAY = 1;
let EVERYTHING = 2;

// Bits added to a learned word with one use; two more for each doubling.
// Tuned with engine/tests/eval.goose.
var bonus_bits = 6.0;

// uses as of `day`; base_uses as of base_day, what it was before its first
// use on `day` (base_day 0: it was first learned that day).
struct Stat { uses: f32, day: u32, base_uses: f32, base_day: u32 }

// A choice: pool[input..input + input_len] chose pool[text..text + text_len].
struct Choice { input: u32, input_len: u8, text: u32, text_len: u16, uses: f32, day: u32, live: bool,
               base_uses: f32, base_day: u32 }

// A change, kept in memory only, so it can be taken back: a word (by its
// entry run) or a choice (by index), what it was before, and the commit.
let WORD = 0;
let CHOICE = 1;
let ENGLISH = 2;
struct Change { kind: u8, id: u32, commit: u32, time: i64, uses: f32, day: u32, added: bool }

var lex = lexicon::Lexicon {};          // learned words; toned is a copy of the live lexicon's
var stats = dictionary<u32, Stat> {};   // by entry run
var choices: Choice[>..] = [];
var pool: u8[>..] = [];                 // choices' input and text
var choice_at = dictionary<u64, i64> {};    // hash of input \t text → index into choices
var live_choices: i64 = 0;
// English words the user has picked: pool_en holds code and text.
struct EnglishUse { code: u32, code_len: u8, text: u32, text_len: u16, uses: f32, day: u32, live: bool,
                   base_uses: f32, base_day: u32 }
var english: EnglishUse[>..] = [];
var pool_en: u8[>..] = [];
var english_at = dictionary<u64, i64> {};   // hash of code \t text → index
var live_english: i64 = 0;
var journal: Change[>..] = [];
var dormant: u8[>..] = [];              // word lines naming syllables this lexicon lacks, kept as they were
var changes: u64 = 0;                   // bumped on every change, so the host knows when to save
var utc_offset: i64 = 0;                // seconds east of UTC, for the local day
var scope: u8[>..] = [];                // the input scheme choices are kept under: "flypy:vsgo"
var clock_override: i64 = 0;            // seconds since the epoch, for tests; 0 is the real clock

fn now() -> i64 { if clock_override != 0 { clock_override } else { time_ns() / 1000000000 } }
fn today() -> u32 { ((now() + utc_offset) / 86400) as u32 }

fn effective(uses: f64, last: u32, day: u32) -> f64 {
    let age: f64 = if day > last { day - last } else { 0.0 };
    uses * exp2(-age / HALF_LIFE_DAYS)
}

fn cold(last: u32, day: u32) -> bool { day > last && day - last >= COLD_DAYS }

// Empties the dictionary, bound to the live lexicon's syllabary.
fn reset() {
    lexicon::clear(lex);
    lex.toned.append(lexicon::live.toned);
    stats.clear();
    choices.clear();
    pool.clear();
    choice_at.clear();
    live_choices = 0;
    english.clear();
    pool_en.clear();
    english_at.clear();
    live_english = 0;
    journal.clear();
    dormant.clear();
    changes++;
}

fn code_of(pairs: const lexicon::Pair[:], out: u16[>..]&) {
    for p in pairs { out.push(lexicon::live.toned[p.toned].plain); }
}

// ---- words -------------------------------------------------------------------------

// The stored weight for a word with these syllables and effective uses: the
// best lexicon word's for the same syllables, or the floor, plus the bonus.
fn weight(code: const u16[:], uses: f64) -> u16 {
    let lo, hi = lexicon::exact(lexicon::live, code);
    var base = FLOOR_BITS;
    if lo < hi {
        let best = (lexicon::live.entries[lo].weight as f64) / lexicon::WEIGHT_SCALE;
        if best > base { base = best; }
    }
    let bits = base + bonus_bits + 2.0 * log2(1.0 + uses) - 2.0;
    var q = round(bits * lexicon::WEIGHT_SCALE);
    if q < 0.0 { q = 0.0; }
    if q > 65535.0 { q = 65535.0; }
    return q as u16;
}

fn pair_at(i: i64, k: i64) -> lexicon::Pair { lex.pairs[lex.runs[lex.entries[i].run + k]] }

fn pairs_of_entry(i: i64, out: lexicon::Pair[>..]&) {
    for k in lex.entries[i].len { out.push(pair_at(i, k)); }
}

// Where the word made of `pairs` is: its index, or -1 and the index to
// insert it at, keeping entries in syllable order and, within the same
// syllables, highest weight first (for weight `w`).
fn locate(pairs: const lexicon::Pair[:], code: const u16[:], w: u16) -> i64, i64 {
    var lo: i64 = 0;
    var hi = lex.entries.len;
    for d in code.len {
        lo, hi = lexicon::narrow(lex, lo, hi, d, code[d], code[d]);
        if lo == hi { return -1, lo; }
    }
    var at = lo;                    // [lo, end): exactly these syllables, then longer words
    var spot: i64 = -1;
    while at < hi && lex.entries[at].len == code.len {
        var same = true;
        for k in code.len {
            let p = pair_at(at, k);
            if p.cp != pairs[k].cp || p.toned != pairs[k].toned { same = false; break; }
        }
        if same { return at, at; }
        if spot < 0 && lex.entries[at].weight < w { spot = at; }
        at++;
    }
    return -1, if spot >= 0 { spot } else { at };
}

// Moves entry i to its place among the entries with the same syllables
// after its weight changed.
fn reorder(i: i64, code_len: i64) {
    var j = i;
    while j > 0 && lex.entries[j - 1].len == code_len && lexicon::compare_entries(lex, j - 1, j) == 0 &&
          lex.entries[j - 1].weight < lex.entries[j].weight {
        let t = lex.entries[j - 1];
        lex.entries[j - 1] = lex.entries[j];
        lex.entries[j] = t;
        j--;
    }
    while j + 1 < lex.entries.len && lex.entries[j + 1].len == code_len &&
          lexicon::compare_entries(lex, j, j + 1) == 0 && lex.entries[j + 1].weight > lex.entries[j].weight {
        let t = lex.entries[j + 1];
        lex.entries[j + 1] = lex.entries[j];
        lex.entries[j] = t;
        j++;
    }
}

// Adds a word with `uses` and `day`, or, if it is there, sets them. Returns
// its run, which identifies it until it is removed.
fn put(pairs: const lexicon::Pair[:], uses: f64, day: u32) -> u32 {
    var code: u16[>..] = [];
    code_of(pairs, code);
    let w = weight(code, effective(uses, day, today()));
    let i, spot = locate(pairs, code, w);
    if i >= 0 {
        let run = lex.entries[i].run;
        let old = stats.get_or_insert(run, Stat { uses: 0.0, day: 0, base_uses: 0.0, base_day: 0 });
        stats.insert(run, Stat { uses: uses as f32, day: day, base_uses: old.base_uses, base_day: old.base_day });
        lex.entries[i].weight = w;
        reorder(i, code.len);
        return run;
    }
    let run = lex.runs.len as u32;
    for p in pairs {
        lex.runs.push(lex.pairs.len as u16);   // pairs are not shared: a run owns its own
        lex.pairs.push(p);
        lex.flags.push(0);                       // never filtered as rare: the user chose it
    }
    insert_at(lex.entries, spot, lexicon::Entry { run: run, weight: w, len: pairs.len as u8 });
    stats.insert(run, Stat { uses: uses as f32, day: day, base_uses: 0.0, base_day: 0 });
    return run;
}

fn index_of_run(run: u32) -> i64 {
    for i in lex.entries.len { if lex.entries[i].run == run { return i; } }
    return -1;
}

fn remove_index(i: i64) {
    stats.remove(lex.entries[i].run);
    remove_at(lex.entries, i);
}

fn stat_of(i: i64) -> Stat {
    stats.get_or_insert(lex.entries[i].run, Stat { uses: 0.0, day: 0, base_uses: 0.0, base_day: 0 })
}

// Sets word i's uses and day (its base stays) and moves it to its place.
fn restat(i: i64, uses: f32, day: u32) {
    let old = stat_of(i);
    stats.insert(lex.entries[i].run, Stat { uses: uses, day: day, base_uses: old.base_uses, base_day: old.base_day });
    var pairs: lexicon::Pair[>..] = [];
    pairs_of_entry(i, pairs);
    var code: u16[>..] = [];
    code_of(pairs, code);
    lex.entries[i].weight = weight(code, effective(uses, day, today()));
    reorder(i, code.len);
}

// A word the user converted, in commit `commit`: `amount` more uses, today.
// Words longer than MAX_PHRASE syllables are not kept.
fn learn(pairs: const lexicon::Pair[:], amount: f64, commit: u32) {
    guard pairs.len > 0 && pairs.len <= MAX_PHRASE && lex.pairs.len + pairs.len < lexicon::MAX_PAIRS else { return; }
    if lex.toned.len == 0 { lex.toned.append(lexicon::live.toned); }
    var code: u16[>..] = [];
    code_of(pairs, code);
    let i, spot = locate(pairs, code, 0);
    let day = today();
    var before = Stat { uses: 0.0, day: day, base_uses: 0.0, base_day: 0 };
    if i >= 0 { before = stat_of(i); }
    // Its base: what it was before today's first use. That is now, unless it
    // was used earlier today; a word new today has none.
    var base_uses: f32 = 0.0;
    var base_day: u32 = 0;
    if i >= 0 && before.day < day {
        base_uses = before.uses;
        base_day = before.day;
    } else if i >= 0 {
        base_uses = before.base_uses;
        base_day = before.base_day;
    }
    let run = put(pairs, effective(before.uses, before.day, day) + amount, day);
    stats.insert(run, Stat { uses: stats.get_or_insert(run, before).uses, day: day, base_uses: base_uses, base_day: base_day });
    note(Change { kind: WORD, id: run, commit: commit, time: now(), uses: before.uses, day: before.day, added: i < 0 });
    if lex.entries.len > MAX_WORDS { drop_weakest_word(); }
    changes++;
}

fn drop_weakest_word() {
    let day = today();
    var worst: i64 = 0;
    var least = 1.0e30;
    for i in lex.entries.len {
        let s = stat_of(i);
        let u = effective(s.uses, s.day, day);
        if u < least { least = u; worst = i; }
    }
    remove_index(worst);
}

// Removes the learned word made of `pairs`, and every choice of its text.
fn unlearn(pairs: const lexicon::Pair[:]) -> bool {
    var code: u16[>..] = [];
    code_of(pairs, code);
    let i, spot = locate(pairs, code, 0);
    var text: u8[>..] = [];
    for p in pairs { push_utf8(text, p.cp); }
    var removed = false;
    for c in choices.len {
        let ch = choices[c];
        if ch.live && compare(pool[ch.text..ch.text + ch.text_len], text) == 0 {
            kill_choice(c);
            removed = true;
        }
    }
    if i >= 0 {
        remove_index(i);
        removed = true;
    }
    if removed { changes++; }
    return removed;
}

// ---- choices -----------------------------------------------------------------------

// A choice's input as stored: the scheme, a colon, the keys. The same keys
// mean different things in different schemes ("an" in full pinyin and in
// 小鹤双拼), so choices never cross schemes; learned words, by syllable, do.
fn scoped(input: const u8[:], out: u8[>..]&) {
    out.append(if scope.len > 0 { scope[..] } else { "fullpinyin" });
    out.push(':');
    out.append(input);
}

fn choice_key(input: const u8[:], text: const u8[:]) -> u64 {
    var key: u8[>..] = [];
    key.append(input);
    key.push('\t');
    key.append(text);
    return hash(key);
}

fn find_choice(input: const u8[:], text: const u8[:]) -> i64 {
    let c = choice_at.get(choice_key(input, text));
    guard c else { return -1; }
    let ch = choices[c];
    guard ch.live && compare(pool[ch.input..ch.input + ch.input_len], input) == 0 &&
          compare(pool[ch.text..ch.text + ch.text_len], text) == 0 else { return -1; }
    return c;
}

fn kill_choice(c: i64) {
    let ch = choices[c];
    choice_at.remove(choice_key(pool[ch.input..ch.input + ch.input_len], pool[ch.text..ch.text + ch.text_len]));
    choices[c].live = false;
    live_choices--;
}

// How often `text` was chosen for exactly `input`, after decay, rounded: an
// old single choice stops counting after about one half-life.
fn chosen(typed: const u8[:], text: const u8[:]) -> i64 {
    guard live_choices > 0 else { return 0; }
    var input: u8[>..] = [];
    scoped(typed, input);
    let c = find_choice(input, text);
    guard c >= 0 else { return 0; }
    return round(effective(choices[c].uses, choices[c].day, today())) as i64;
}

fn set_choice(input: const u8[:], text: const u8[:], uses: f64, day: u32) -> i64 {
    let c = find_choice(input, text);
    if c >= 0 {
        choices[c].uses = uses as f32;
        choices[c].day = day;
        return c;
    }
    let at = pool.len;
    pool.append(input);
    pool.append(text);
    choices.push(Choice { input: at as u32, input_len: input.len as u8, text: (at + input.len) as u32,
                          text_len: text.len as u16, uses: uses as f32, day: day, live: true,
                          base_uses: 0.0, base_day: 0 });
    choice_at.insert(choice_key(input, text), choices.len - 1);
    live_choices++;
    return choices.len - 1;
}

// `text` was chosen for `input` (as typed, without separators) in `commit`.
fn choose(typed: const u8[:], text: const u8[:], commit: u32) {
    guard typed.len > 0 && typed.len <= MAX_INPUT && text.len > 0 && text.len <= 1024 else { return; }
    var input: u8[>..] = [];
    scoped(typed, input);
    let c = find_choice(input, text);
    let day = today();
    var uses = 0.0;
    var last = day;
    var base_uses: f32 = 0.0;               // as for a word: what it was before today's first use
    var base_day: u32 = 0;
    if c >= 0 {
        uses = choices[c].uses;
        last = choices[c].day;
        if last < day {
            base_uses = choices[c].uses;
            base_day = last;
        } else {
            base_uses = choices[c].base_uses;
            base_day = choices[c].base_day;
        }
    }
    let at = set_choice(input, text, effective(uses, last, day) + 1.0, day);
    choices[at].base_uses = base_uses;
    choices[at].base_day = base_day;
    note(Change { kind: CHOICE, id: at as u32, commit: commit, time: now(), uses: uses as f32, day: last,
                  added: c < 0 });
    if live_choices > MAX_CHOICES { drop_weakest_choice(); }
    changes++;
}

fn drop_weakest_choice() {
    let day = today();
    var worst: i64 = -1;
    var least = 1.0e30;
    for c in choices.len {
        if !choices[c].live { continue; }
        let u = effective(choices[c].uses, choices[c].day, day);
        if u < least { least = u; worst = c; }
    }
    if worst >= 0 { kill_choice(worst); }
}

// ---- taking learning back ----------------------------------------------------------

fn note(c: Change) {
    var old: i64 = 0;                   // the journal keeps 15 minutes
    while old < journal.len && journal[old].time < now() - RECENT_SECONDS { old++; }
    if old > 0 {
        var kept: Change[>..] = [];
        kept.append(journal[old..]);
        journal.clear();
        journal.append(kept);
    }
    journal.push(c);
}

// Undoes one change; false if what it changed is gone.
fn undo(c: Change) -> bool {
    if c.kind == WORD {
        let i = index_of_run(c.id);
        guard i >= 0 else { return false; }
        if c.added { remove_index(i); } else { restat(i, c.uses, c.day); }
        return true;
    }
    if c.kind == ENGLISH {
        guard c.id < english.len && english[c.id].live else { return false; }
        if c.added { kill_english(c.id); } else {
            english[c.id].uses = c.uses;
            english[c.id].day = c.day;
        }
        return true;
    }
    guard c.id < choices.len && choices[c.id].live else { return false; }
    if c.added {
        kill_choice(c.id);
    } else {
        choices[c.id].uses = c.uses;
        choices[c.id].day = c.day;
    }
    return true;
}

// Takes back everything commit `commit` taught: the user deleted it right
// away and typed the same input again, choosing something else.
fn retract(commit: u32) -> i64 {
    guard commit != 0 else { return 0; }
    var n: i64 = 0;
    var kept: Change[>..] = [];
    var k = journal.len - 1;
    while k >= 0 {                          // newest first, so each restores what was before it
        if journal[k].commit == commit {
            if undo(journal[k]) { n++; }
        }
        k--;
    }
    for c in journal { if c.commit != commit { kept.push(c); } }
    journal.clear();
    journal.append(kept);
    if n > 0 { changes++; }
    return n;
}

// Takes back learning: the last 15 minutes (from the journal, which lives
// only in memory), today's (by the day field), or all of it. Returns the
// number of words and choices removed or restored.
fn forget(scope: i64) -> i64 {
    var n: i64 = 0;
    if scope == EVERYTHING {
        n = lex.entries.len + live_choices + live_english;
        reset();
        return n;
    }
    if scope == RECENT {
        let since = now() - RECENT_SECONDS;
        while journal.len > 0 && journal[journal.len - 1].time >= since {
            if undo(journal.pop()) { n++; }
        }
    } else if scope == TODAY {
        // What was used today goes back to its base, as it was before today;
        // what was first learned today goes.
        let day = today();
        var restored = false;
        var i: i64 = 0;
        while i < lex.entries.len {
            let st = stat_of(i);
            if st.day < day {
                i++;
                continue;
            }
            n++;
            if st.base_day > 0 && st.base_day < day {
                stats.insert(lex.entries[i].run, Stat { uses: st.base_uses, day: st.base_day, base_uses: 0.0, base_day: 0 });
                restored = true;
                i++;
            } else {
                remove_index(i);
            }
        }
        if restored { refresh(); }          // their weights, and so their order, follow
        for c in choices.len {
            if !choices[c].live || choices[c].day < day { continue; }
            n++;
            if choices[c].base_day > 0 && choices[c].base_day < day {
                choices[c].uses = choices[c].base_uses;
                choices[c].day = choices[c].base_day;
                choices[c].base_uses = 0.0;
                choices[c].base_day = 0;
            } else {
                kill_choice(c);
            }
        }
        for e in english.len {
            if !english[e].live || english[e].day < day { continue; }
            n++;
            if english[e].base_day > 0 && english[e].base_day < day {
                english[e].uses = english[e].base_uses;
                english[e].day = english[e].base_day;
                english[e].base_uses = 0.0;
                english[e].base_day = 0;
            } else {
                kill_english(e);
            }
        }
        journal.clear();
    }
    if n > 0 { changes++; }
    return n;
}

// ---- handing the journal over --------------------------------------------------------

// The journal as text, for the next build of the engine in the same process
// (the host hands it over in memory when it loads a new core), so that what
// was learned before can still be forgotten as the last 15 minutes. Each
// change is named by what it changed, not by ids, which differ between
// builds: kind \t time \t uses before \t day before \t added (0 or 1) \t
//   word:    text \t toned syllables, space-separated
//   choice:  input as stored \t text
fn journal_save(out: u8[>..]&) {
    let since = now() - RECENT_SECONDS;
    var named: u8[>..] = [];
    for c in journal {
        if c.time < since { continue; }
        named.clear();
        if c.kind == WORD {
            let i = index_of_run(c.id);
            if i < 0 { continue; }
            lexicon::text(lex, i, named);
            named.push('\t');
            for k in lex.entries[i].len {
                if k > 0 { named.push(' '); }
                named.append(lex.toned[pair_at(i, k).toned].text);
            }
        } else if c.kind == ENGLISH {
            if c.id >= english.len || !english[c.id].live { continue; }
            let e = english[c.id];
            named.append(pool_en[e.code..e.code + e.code_len]);
            named.push('\t');
            named.append(pool_en[e.text..e.text + e.text_len]);
        } else {
            if c.id >= choices.len || !choices[c.id].live { continue; }
            let ch = choices[c.id];
            named.append(pool[ch.input..ch.input + ch.input_len]);
            named.push('\t');
            named.append(pool[ch.text..ch.text + ch.text_len]);
        }
        format(out, c.kind, "\t", c.time, "\t");
        format_flt(out, c.uses, 3);
        format(out, "\t", c.day, "\t", if c.added { 1 } else { 0 }, "\t", named, "\n");
    }
}

// Takes over a journal handed over by journal_save, after the dictionary it
// belongs to was restored. Changes older than 15 minutes, and those whose
// word or choice is not there, are left out; none carries its commit, which
// was another build's numbering. Returns how many changes came back.
fn journal_restore(data: const u8[:]) -> i64 {
    journal.clear();
    var ids = dictionary<const u8[:], i64> {};
    for t in lex.toned.len { ids.insert(lex.toned[t].text, t); }
    let since = now() - RECENT_SECONDS;
    var n: i64 = 0;
    var pos: i64 = 0;
    while pos < data.len {
        let line = lexicon::next_line(data, pos);
        if line.len == 0 { continue; }
        let kind_text, rest1, ok1 = split_once(line, '\t');
        let time_text, rest2, ok2 = split_once(rest1, '\t');
        let uses_text, rest3, ok3 = split_once(rest2, '\t');
        let day_text, rest4, ok4 = split_once(rest3, '\t');
        let added_text, rest5, ok5 = split_once(rest4, '\t');
        let first, second, ok6 = split_once(rest5, '\t');
        let kind, ok7 = parse_int(kind_text);
        let time, ok8 = parse_int(time_text);
        let uses, ok9 = parse_flt(uses_text);
        let day, ok10 = parse_int(day_text);
        if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8 && ok9 && ok10) { continue; }
        if (kind != WORD && kind != CHOICE && kind != ENGLISH) || time < since || time > now() || uses < 0.0 ||
           uses >= 1.0e9 || day < 0 || day >= 0xFFFFFFFF {
            continue;
        }
        var id: i64 = -1;
        if kind == WORD {
            var cps: u32[>..] = [];
            each_utf8(first) { cp => cps.push(cp as u32); };
            var pairs: lexicon::Pair[>..] = [];
            var known = true;
            var k: i64 = 0;
            each_split(second, ' ') {
                let t = ids.get(it);
                if t && k < cps.len { pairs.push(lexicon::Pair { cp: cps[k], toned: t as u16 }); } else { known = false; }
                k++;
            };
            if !known || k != cps.len || cps.len == 0 || cps.len > MAX_PHRASE { continue; }
            var code: u16[>..] = [];
            code_of(pairs, code);
            let i, spot = locate(pairs, code, 0);
            if i < 0 { continue; }
            id = lex.entries[i].run as i64;
        } else if kind == ENGLISH {
            id = find_english(first, second);
            if id < 0 { continue; }
        } else {
            id = find_choice(first, second);
            if id < 0 { continue; }
        }
        journal.push(Change { kind: kind as u8, id: id as u32, commit: 0, time: time, uses: uses as f32, day: day as u32,
                              added: added_text == "1" });
        n++;
    }
    return n;
}

// Recomputes every word's weight for today, as when the day changes.
fn refresh() {
    let day = today();
    for i in lex.entries.len {
        var pairs: lexicon::Pair[>..] = [];
        pairs_of_entry(i, pairs);
        var code: u16[>..] = [];
        code_of(pairs, code);
        let s = stat_of(i);
        lex.entries[i].weight = weight(code, effective(s.uses, s.day, day));
    }
    sort(lex.entries) { a, b => before(a, b) };
}

// Entry order: syllables, shorter first, then higher weight.
fn before(a: lexicon::Entry, b: lexicon::Entry) -> bool {
    let n: i64 = if a.len < b.len { a.len } else { b.len };
    for k in n {
        let x: i64 = lex.toned[lex.pairs[lex.runs[a.run + k]].toned].plain;
        let y: i64 = lex.toned[lex.pairs[lex.runs[b.run + k]].toned].plain;
        if x != y { return x < y; }
    }
    if a.len != b.len { return a.len < b.len; }
    return a.weight > b.weight;
}

// ---- english words -----------------------------------------------------------------

fn is_english_code(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= 32 else { return false; }
    for c in text { if c < 'a' || c > 'z' { return false; } }
    return true;
}

fn is_english_text(text: const u8[:]) -> bool {
    guard text.len > 0 && text.len <= 1024 && find(text, "\t") < 0 && find(text, "\n") < 0 else { return false; }
    var valid = true;
    each_utf8(text) { cp => if !lexicon::is_scalar(cp as u32) { valid = false; } };
    return valid;
}

fn english_key(code: const u8[:], text: const u8[:]) -> u64 {
    var key: u8[>..] = [];
    key.append(code);
    key.push('\t');
    key.append(text);
    return hash(key);
}

fn find_english(code: const u8[:], text: const u8[:]) -> i64 {
    let c = english_at.get(english_key(code, text));
    guard c else { return -1; }
    let e = english[c];
    guard e.live && compare(pool_en[e.code..e.code + e.code_len], code) == 0 &&
          compare(pool_en[e.text..e.text + e.text_len], text) == 0 else { return -1; }
    return c;
}

fn kill_english(c: i64) {
    let e = english[c];
    english_at.remove(english_key(pool_en[e.code..e.code + e.code_len], pool_en[e.text..e.text + e.text_len]));
    english[c].live = false;
    live_english--;
}

fn drop_weakest_english() {
    let day = today();
    var worst: i64 = -1;
    var least = 1.0e30;
    for c in english.len {
        if !english[c].live { continue; }
        let u = effective(english[c].uses, english[c].day, day);
        if u < least { least = u; worst = c; }
    }
    if worst >= 0 { kill_english(worst); }
}

fn set_english(code: const u8[:], text: const u8[:], uses: f64, day: u32) -> i64 {
    let c = find_english(code, text);
    if c >= 0 {
        english[c].uses = uses as f32;
        english[c].day = day;
        return c;
    }
    let at = pool_en.len;
    pool_en.append(code);
    pool_en.append(text);
    english.push(EnglishUse { code: at as u32, code_len: code.len as u8, text: (at + code.len) as u32,
                              text_len: text.len as u16, uses: uses as f32, day: day, live: true,
                              base_uses: 0.0, base_day: 0 });
    english_at.insert(english_key(code, text), english.len - 1);
    live_english++;
    return english.len - 1;
}

// `text` was picked for the English code `code`. Uses count like a choice.
fn learn_english(code: const u8[:], text: const u8[:], commit: u32) {
    guard is_english_code(code) && is_english_text(text) else { return; }
    let c = find_english(code, text);
    let day = today();
    var uses = 0.0;
    var last = day;
    var base_uses: f32 = 0.0;
    var base_day: u32 = 0;
    if c >= 0 {
        uses = english[c].uses;
        last = english[c].day;
        if last < day {
            base_uses = english[c].uses;
            base_day = last;
        } else {
            base_uses = english[c].base_uses;
            base_day = english[c].base_day;
        }
    }
    let at = set_english(code, text, effective(uses, last, day) + 1.0, day);
    english[at].base_uses = base_uses;
    english[at].base_day = base_day;
    note(Change { kind: ENGLISH, id: at as u32, commit: commit, time: now(), uses: uses as f32, day: last,
                  added: c < 0 });
    if live_english > MAX_ENGLISH { drop_weakest_english(); }
    changes++;
}

// How often `text` was picked for `code`, after decay, rounded.
fn english_uses(code: const u8[:], text: const u8[:]) -> i64 {
    let c = find_english(code, text);
    guard c >= 0 else { return 0; }
    return round(effective(english[c].uses, english[c].day, today())) as i64;
}

// The picked form of `code` with the most uses, and that many. 0 if none still count.
fn english_top(code: const u8[:], out: u8[>..]&) -> i64 {
    out.clear();
    var best: i64 = -1;
    var uses: i64 = 0;
    for c in english.len {
        if !english[c].live { continue; }
        let e = english[c];
        if compare(pool_en[e.code..e.code + e.code_len], code) != 0 { continue; }
        let u = round(effective(e.uses, e.day, today())) as i64;
        if u > uses {
            uses = u;
            best = c;
        }
    }
    guard best >= 0 else { return 0; }
    let e = english[best];
    out.append(pool_en[e.text..e.text + e.text_len]);
    return uses;
}

fn unlearn_english(code: const u8[:], text: const u8[:]) -> bool {
    let c = find_english(code, text);
    guard c >= 0 else { return false; }
    kill_english(c);
    changes++;
    return true;
}

// ---- persistence -------------------------------------------------------------------

// The dictionary as text: the header, then three sections, each line
//   words:    text \t toned syllables, space-separated \t uses \t local day
//   choices:  input as typed \t text \t uses \t local day
//   english:  code \t text \t uses \t local day
// with the dormant word lines as they came. What has gone cold is left out:
// that is how forgetting happens. A word or choice used today is followed by
//   #base \t uses \t local day
// what it was before today's first use, for forgetting today. It starts
// with '#' so that a build from before bases skips it, as it skips headers.
fn save(out: u8[>..]&) {
    let day = today();
    format(out, HEADER, "\n", WORDS_SECTION, "\n");
    for i in lex.entries.len {
        let e = lex.entries[i];
        let s = stat_of(i);
        if cold(s.day, day) { continue; }
        lexicon::text(lex, i, out);
        out.push('\t');
        for k in e.len {
            if k > 0 { out.push(' '); }
            out.append(lex.toned[pair_at(i, k).toned].text);
        }
        out.push('\t');
        format_flt(out, s.uses, 3);
        format(out, "\t", s.day, "\n");
        if s.day >= day && s.base_day > 0 { save_base(out, s.base_uses, s.base_day); }
    }
    out.append(dormant);
    format(out, CHOICES_SECTION, "\n");
    for ch in choices {
        if !ch.live || cold(ch.day, day) { continue; }
        out.append(pool[ch.input..ch.input + ch.input_len]);
        out.push('\t');
        out.append(pool[ch.text..ch.text + ch.text_len]);
        out.push('\t');
        format_flt(out, ch.uses, 3);
        format(out, "\t", ch.day, "\n");
        if ch.day >= day && ch.base_day > 0 { save_base(out, ch.base_uses, ch.base_day); }
    }
    format(out, ENGLISH_SECTION, "\n");
    for e in english {
        if !e.live || cold(e.day, day) { continue; }
        out.append(pool_en[e.code..e.code + e.code_len]);
        out.push('\t');
        out.append(pool_en[e.text..e.text + e.text_len]);
        out.push('\t');
        format_flt(out, e.uses, 3);
        format(out, "\t", e.day, "\n");
        if e.day >= day && e.base_day > 0 { save_base(out, e.base_uses, e.base_day); }
    }
}

let BASE_PREFIX = "#base\t";

fn save_base(out: u8[>..]&, uses: f32, day: u32) {
    out.append(BASE_PREFIX);
    format_flt(out, uses, 3);
    format(out, "\t", day, "\n");
}

// A stored choice input: "scheme:keys". A line saved before schemes were
// kept has no scheme, and was typed in full pinyin.
fn is_input(text: const u8[:]) -> bool {
    let colon = find(text, ":");
    let keys = if colon >= 0 { text[colon + 1..] } else { text };
    guard keys.len > 0 && keys.len <= MAX_INPUT && (colon < 0 || (colon > 0 && colon <= 15)) else { return false; }
    for c in text[..(if colon >= 0 { colon } else { 0 })] {
        if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') { return false; }
    }
    for c in keys { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '`') { return false; } }
    return true;
}

// Replaces the dictionary with a saved one. False, leaving it empty, if
// `data` is not one; lines it cannot read are skipped, and word lines naming
// syllables this lexicon lacks are kept for the next save.
fn restore(data: const u8[:]) -> bool {
    reset();
    guard data.len >= HEADER.len && compare(data[..HEADER.len], HEADER) == 0 &&
          (data.len == HEADER.len || data[HEADER.len] == '\n') else { return false; }
    var ids = dictionary<const u8[:], i64> {};
    for t in lex.toned.len { ids.insert(lex.toned[t].text, t); }
    var section = WORD;
    var pos = HEADER.len;
    var last_word: i64 = -1;                 // the run, or the choice, the line before stored; -1 none
    var last_choice: i64 = -1;
    var last_english: i64 = -1;
    var last_dormant = false;
    while pos < data.len {
        let line = lexicon::next_line(data, pos);
        if line.len == 0 { continue; }
        if line.len > BASE_PREFIX.len && compare(line[..BASE_PREFIX.len], BASE_PREFIX) == 0 {
            let uses_text, day_text, ok = split_once(line[BASE_PREFIX.len..], '\t');
            let uses, ok1 = parse_flt(uses_text);
            let day, ok2 = parse_int(day_text);
            if ok && ok1 && ok2 && uses >= 0.0 && uses < 1.0e9 && day > 0 && day < 0xFFFFFFFF {
                if last_word >= 0 {
                    let st = stats.get_or_insert(last_word as u32, Stat { uses: 0.0, day: 0, base_uses: 0.0, base_day: 0 });
                    stats.insert(last_word as u32, Stat { uses: st.uses, day: st.day, base_uses: uses as f32,
                                                          base_day: day as u32 });
                } else if last_choice >= 0 {
                    choices[last_choice].base_uses = uses as f32;
                    choices[last_choice].base_day = day as u32;
                } else if last_english >= 0 {
                    english[last_english].base_uses = uses as f32;
                    english[last_english].base_day = day as u32;
                } else if last_dormant {
                    dormant.append(line);
                    dormant.push('\n');
                }
            }
            last_word = -1;
            last_choice = -1;
            last_english = -1;
            last_dormant = false;
            continue;
        }
        last_word = -1;
        last_choice = -1;
        last_english = -1;
        last_dormant = false;
        if line[0] == '#' {
            if line == WORDS_SECTION { section = WORD; }
            if line == CHOICES_SECTION { section = CHOICE; }
            if line == ENGLISH_SECTION { section = ENGLISH; }
            continue;
        }
        let first, rest1, ok1 = split_once(line, '\t');
        let second, rest2, ok2 = split_once(rest1, '\t');
        let uses_text, day_text, ok3 = split_once(rest2, '\t');
        let uses, ok4 = parse_flt(uses_text);
        let day, ok5 = parse_int(day_text);
        if !(ok1 && ok2 && ok3 && ok4 && ok5 && uses >= 0.0 && uses < 1.0e9 && day >= 0 && day < 0xFFFFFFFF) {
            continue;
        }
        var cps: u32[>..] = [];
        if section == ENGLISH {
            if is_english_code(first) && is_english_text(second) && live_english < MAX_ENGLISH {
                last_english = set_english(first, second, uses, day as u32);
            }
            continue;
        }
        if section == CHOICE {
            var valid = is_input(first) && second.len > 0 && second.len <= 1024;
            each_utf8(second) { cp => if !lexicon::is_scalar(cp as u32) { valid = false; } };
            if valid && live_choices < MAX_CHOICES {
                if find(first, ":") >= 0 {
                    last_choice = set_choice(first, second, uses, day as u32);
                } else {
                    last_choice = set_choice(str("fullpinyin:", first), second, uses, day as u32);
                }
            }
            continue;
        }
        each_utf8(first) { cp => cps.push(cp as u32); };
        var pairs: lexicon::Pair[>..] = [];
        var known = true;
        var k: i64 = 0;
        each_split(second, ' ') {
            let id = ids.get(it);
            if id && k < cps.len { pairs.push(lexicon::Pair { cp: cps[k], toned: id as u16 }); } else { known = false; }
            k++;
        };
        if k != cps.len || cps.len == 0 || cps.len > MAX_PHRASE { continue; }
        if !known {
            dormant.append(line);
            dormant.push('\n');
            last_dormant = true;
            continue;
        }
        var valid = true;
        for cp in cps { if !lexicon::is_scalar(cp) { valid = false; } }
        if !valid || lex.pairs.len + pairs.len >= lexicon::MAX_PAIRS || lex.entries.len >= MAX_WORDS { continue; }
        last_word = put(pairs, uses, day as u32) as i64;
    }
    journal.clear();
    changes++;
    return true;
}
