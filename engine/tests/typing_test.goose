// Typing through the engine with the real lexicon, headless: what a user
// sees for common input, the editing keys, and how long a key takes.
//
//   typing-test IMAGES
import std;
import os;
import octo from "..";

var failures: i64 = 0;
var soft_misses: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    print(if ok { "ok    " } else { "FAIL  " }, what);
    if !ok { failures++; }
}

// For ranking quality the lexicon alone cannot promise: reported, not failed.
fn hope(ok: bool, what: const u8[:]) {
    print(if ok { "ok    " } else { "miss  " }, what);
    if !ok { soft_misses++; }
}

fn key_event(key: i64, c: i64, modifiers: i64) -> session::KeyEvent {
    session::KeyEvent { key: key as u16, flags: 0, modifiers: modifiers as u32, codepoint: c as u32, time_ms: 0 }
}

fn press(s: u64, key: i64) -> u32 { session::key(s, key_event(key, 0, 0)) }
fn typed(s: u64, c: i64) -> u32 { session::key(s, key_event(session::KEY_OTHER, c, 0)) }

fn type_text(s: u64, text: const u8[:]) {
    for c in text { typed(s, c); }
}

fn candidate(i: i64) -> u8[>..] {
    var t: u8[>..] = [];
    if i >= 0 && i < session::menu.candidates.len {
        let c = session::menu.candidates[i];
        t.append(session::menu.pool[c.text..c.text + c.len]);
    }
    return t;
}

fn rank(text: const u8[:]) -> i64 {
    for i in session::menu.candidates.len {
        if compare(candidate(i), text) == 0 { return i; }
    }
    return -1;
}

fn first_is(s: u64, input: const u8[:], want: const u8[:], hard: bool) {
    press(s, session::KEY_ESCAPE);
    type_text(s, input);
    let got = candidate(0);
    let what = str(input, " → ", want, " first (got ", got, ")");
    if hard { check(compare(got, want) == 0, what); } else { hope(compare(got, want) == 0, what); }
    press(s, session::KEY_ESCAPE);
}

fn within(s: u64, input: const u8[:], want: const u8[:], n: i64) {
    press(s, session::KEY_ESCAPE);
    type_text(s, input);
    let r = rank(want);
    check(r >= 0 && r < n, str(input, " → ", want, " among the first ", n, " (rank ", r, ")"));
    press(s, session::KEY_ESCAPE);
}

fn editing(s: u64) {
    press(s, session::KEY_ESCAPE);
    type_text(s, "zhongguoren");
    let zg = rank("中国");
    check(zg >= 0 && session::menu.candidates[zg].to == 8, "zhongguoren offers 中国 for its first 8 letters");
    session::select(zg);
    check(compare(session::confirmed, "中国") == 0 && compare(session::input, "ren") == 0,
          "selecting 中国 confirms it and leaves ren to convert");
    check(compare(candidate(0), "人") == 0, "ren then offers 人 first");
    let r = press(s, session::KEY_SPACE);
    check((r & session::HAS_COMMIT) != 0 && compare(session::commit, "中国人") == 0, "space commits 中国人");
    let after = session::snapshot(s);
    check(after[8] == 0 && after[9] == 0 && after[10] == 0 && after[11] == 0,
          "  and the snapshot's preedit is empty: no pinyin left behind for the app");

    type_text(s, "zhongguoren");
    session::select(rank("中国"));
    press(s, session::KEY_BACKSPACE);
    press(s, session::KEY_BACKSPACE);
    press(s, session::KEY_BACKSPACE);
    check(session::input.len == 0 && compare(session::confirmed, "中国") == 0, "backspace takes back ren letter by letter");
    press(s, session::KEY_BACKSPACE);
    check(compare(session::input, "zhongguo") == 0 && session::confirmed.len == 0,
          "one more backspace takes back the selection: zhongguo again");
    press(s, session::KEY_ESCAPE);
    check(!session::composing(), "escape cancels");

    type_text(s, "nihao");
    let e = press(s, session::KEY_RETURN);
    check((e & session::HAS_COMMIT) != 0 && compare(session::commit, "nihao") == 0, "return commits the letters as typed");

    type_text(s, "nihao");
    session::key(s, key_event(session::KEY_OTHER, '1', 0));     // '2' would teach it 拟好 for nihao
    check(session::commit.len > 0 && !session::composing(), "a digit selects from the page");

    let comma = typed(s, ',');
    check((comma & session::HAS_COMMIT) != 0 && compare(session::commit, "，") == 0, ", gives ， when not composing");
    check(typed(s, '3') == 0 && typed(s, '.') == 0, "after a digit, . passes through (3.14 stays 3.14)");

    type_text(s, "nihao");
    let period = typed(s, '.');
    check((period & session::HAS_COMMIT) != 0 && compare(session::commit, "你好。") == 0,
          "punctuation while composing commits the best reading, then the mark");

    type_text(s, "nihao");
    var whole: u8[>..] = [];
    for i in session::menu.candidates.len {
        if session::menu.candidates[i].to == session::input.len {
            whole.append(candidate(i));
            break;
        }
    }
    let cmd = session::key(s, key_event(session::KEY_OTHER, 's', session::MOD_COMMAND));
    check((cmd & session::HANDLED) == 0 && (cmd & session::HAS_COMMIT) != 0 && compare(session::commit, whole) == 0 &&
          !session::composing(), "command while composing commits that reading, then lets the shortcut through");

    type_text(s, "zhong");
    let n = session::menu.candidates.len;
    session::key(s, key_event(session::KEY_END, 0, 0));
    check(n > 1 && session::highlight == n - 1, "end jumps to the last candidate");
    session::key(s, key_event(session::KEY_HOME, 0, 0));
    check(session::highlight == 0 && session::page == 0, "home jumps back to the first");
    press(s, session::KEY_ESCAPE);


    type_text(s, "shi");
    let pages = session::menu.candidates.len;
    press(s, session::KEY_PAGE_DOWN);
    check(pages > session::PAGE_SIZE && session::page == 1 && session::highlight == session::PAGE_SIZE,
          "page down moves to the next page of candidates");
    press(s, session::KEY_ESCAPE);

    type_text(s, "a");
    check(session::menu.candidates.len > session::PAGE_SIZE * session::GRID_ROWS, "enough candidates to fill the grid");
    press(s, session::KEY_RIGHT);
    check(session::highlight == 1 && !session::expanded, "right moves along the row");
    press(s, session::KEY_DOWN);
    check(session::expanded && session::highlight == 1, "down opens the grid where the highlight already is");
    let grid = session::snapshot(s);
    let grid_flags: i64 = (grid[6] as i64) | ((grid[7] as i64) << 8);
    check((grid_flags & session::FLAG_EXPANDED) != 0 && session::grid_row == 0, "the snapshot marks the grid open");
    press(s, session::KEY_DOWN);
    check(session::highlight == 1 + session::PAGE_SIZE, "down again moves to the same place on the next row");
    press(s, session::KEY_UP);
    check(session::highlight == 1 && session::expanded, "up moves back a row");
    press(s, session::KEY_UP);
    check(!session::expanded && session::highlight == 1, "up from the first row closes the grid");
    press(s, session::KEY_DOWN);
    let picked = candidate(session::PAGE_SIZE + 2);
    session::key(s, session::KeyEvent { key: 0, flags: session::KEYFLAG_PICK as u16, modifiers: 0,
                                        codepoint: (session::PAGE_SIZE + 2) as u32, time_ms: 0 });
    check(compare(session::commit, picked) == 0 && !session::expanded, "a click in the grid commits that candidate");

    session::key(s, key_event(session::KEY_OTHER, 'x', session::MOD_COMMAND));
    check(!session::composing(), "command shortcuts pass through");

    let other = session::new_session();
    type_text(s, "ni");
    session::free_session(s);
    check(typed(s, 'a') == 0, "a freed session's handle is refused");
    check(typed(other, 'a') != 0, "another session keeps working");
}

// Is `text` left out of the candidates that read all of `input`? (Shorter
// ones are other readings of its start: "zhong7" may also be z + hong7.)
fn absent(s: u64, input: const u8[:], text: const u8[:]) {
    press(s, session::KEY_ESCAPE);
    type_text(s, input);
    var whole: i64 = 0;
    var found = false;
    for i in session::menu.candidates.len {
        if session::menu.candidates[i].to == input.len {
            whole++;
            if compare(candidate(i), text) == 0 { found = true; }
        }
    }
    check(!found && whole > 0, str(input, " leaves ", text, " out (", whole, " candidates read all of it)"));
    press(s, session::KEY_ESCAPE);
}

// Tones and shape codes typed with a syllable.
fn composite(s: u64) {
    first_is(s, "zhong7", "中", true);
    absent(s, "zhong7", "种");
    absent(s, "zhong9", "中");
    first_is(s, "zhong7guo", "中国", true);
    first_is(s, "zhong0zhi", "种植", true);
    first_is(s, "zhong9zi", "种子", true);
    press(s, session::KEY_ESCAPE);
    type_text(s, "dui8");
    check(compare(session::input, "dui") == 0, "a tone with no reading is refused (dui8 stays dui)");
    first_is(s, "zh7", "中", true);
    press(s, session::KEY_ESCAPE);
    type_text(s, "ni");
    check(typed(s, '2') != 0 && !session::composing(), "1-6 still pick while composing");

    first_is(s, "shi`o", "是", true);
    absent(s, "shi`o", "事");
    first_is(s, "shi`", "是", true);
    first_is(s, "zhong`aguo", "中国", true);
    absent(s, "zhong`kguo", "中国");
    first_is(s, "woshi`ozhongguoren", "我是中国人", true);
    first_is(s, "zhong7`aguo", "中国", true);
    press(s, session::KEY_ESCAPE);
    check(typed(s, '`') == 0, "` passes through when not composing");
    type_text(s, "shi`o7");
    check(compare(session::input, "shi`o") == 0, "a tone inside a shape code is refused");
    press(s, session::KEY_BACKSPACE);
    press(s, session::KEY_BACKSPACE);
    check(compare(session::input, "shi") == 0 && compare(candidate(0), "是") == 0,
          "backspace takes back the code and the `");
    press(s, session::KEY_ESCAPE);
}

// The preedit the snapshot shows, after typing `input` from scratch.
fn preedit_of(s: u64, input: const u8[:]) -> u8[>..] {
    press(s, session::KEY_ESCAPE);
    type_text(s, input);
    let snap = session::snapshot(s);
    let n: i64 = snap[8] | (snap[9] << 8) | (snap[10] << 16) | (snap[11] << 24);
    var text: u8[>..] = [];
    text.append(snap[12..12 + n]);
    press(s, session::KEY_ESCAPE);
    return text;
}

// 小鹤双拼: the same engine with another spelling table.
fn shuangpin(s: u64) {
    check(find(session::scheme_list, "flypy\t小鹤双拼\tsyllables\n") >= 0 &&
          find(session::scheme_list, "fullpinyin\t全拼\ttyped\n") >= 0, "the data directory offers 全拼 and 小鹤双拼");
    check(session::set_scheme("nope") == 1 && session::scheme == "fullpinyin",
          "an unknown scheme is refused, and full pinyin stays");
    // Learned in full pinyin, by syllables, so it carries over.
    userdb::reset();
    userdb::clock_override = 1794000000;
    let shishi = rank_after(s, "shishi", "实时");
    pick(s, "shishi", "实时", 0);
    check(shishi > 0 && session::set_scheme("flypy") == 0 && session::scheme == "flypy", "switched to 小鹤双拼");
    first_is(s, "vsgo", "中国", true);
    first_is(s, "wouivsgorf", "我是中国人", true);
    first_is(s, "nihc", "你好", true);
    first_is(s, "vs7", "中", true);
    first_is(s, "ui`o", "是", true);
    check(preedit_of(s, "wouivsgorf") == "wo ui vs go rf", "the preedit shows the keys typed, by syllable: wo ui vs go rf");
    check(preedit_of(s, "vs7go") == "vs7 go" && preedit_of(s, "ui`o") == "ui`o" && preedit_of(s, "vsg") == "vs g" &&
          preedit_of(s, "xa'nk") == "xa'nk",
          "  a tone and a shape code with their syllable, a key waiting for its pair, an apostrophe between");
    check(rank_after(s, "uiui", "实时") == 0, str("实时 learned in full pinyin (rank ", shishi, " there) is first for uiui"));
    pick(s, "uiui", "事实", 0);
    var saved: u8[>..] = [];
    saved.append(session::user_save());
    check(find(saved, "\nflypy:uiui\t事实\t") >= 0 && find(saved, "\nfullpinyin:shishi\t实时\t") >= 0,
          "choices are kept per scheme: flypy:uiui and fullpinyin:shishi");
    check(session::set_scheme("fullpinyin") == 0 && rank_after(s, "shishi", "事实") >= 0, "and back to full pinyin");
    userdb::reset();
    userdb::clock_override = 0;
}

// Hot swaps (docs/hotswap-architecture.md): lexicon sets on and off at
// once, even mid-composition; schemes in well under a millisecond.
fn hot_swaps(s: u64) {
    check(find(session::sets_list(), "diming\t地名\ton\tmounted\n") >= 0 &&
          find(session::sets_list(), "yiren\t艺人\ton\tmounted\n") >= 0, "the sets on by default are mounted: 地名, 名人, 艺人");
    let with = rank_after(s, "lianxiqu", "濂溪区");
    press(s, session::KEY_ESCAPE);
    type_text(s, "lianxiqu");
    var t = clock_ns();
    let off = session::use_set("diming", false);
    let off_ns = clock_ns() - t;
    let picked = typed(s, '1' + with);          // where 濂溪区 was; the menu is rebuilt first
    check(with >= 0 && with < 6 && off == 0 && (picked & session::HANDLED) != 0 && session::commit != "濂溪区" &&
          find(session::confirmed, "濂溪区") < 0,
          str("地名 off in the middle of composing lianxiqu (", off_ns / 1000, " µs): the pick comes from what is left"));
    check(rank_after(s, "lianxiqu", "濂溪区") < 0, "  and 濂溪区, only 地名 has it, is gone");
    t = clock_ns();
    let on = session::use_set("diming", true);
    let on_ns = clock_ns() - t;
    check(on == 0 && rank_after(s, "lianxiqu", "濂溪区") == with, str("地名 on again (", on_ns / 1000, " µs): 濂溪区 is back"));
    check(session::use_set("nope", true) == 1 && session::use_set("diming", true) == 0,
          "a set that is not there is refused; mounting one twice is harmless");
    var rounds_ok = true;
    for round in 20 {
        rounds_ok = rounds_ok && session::use_set("diming", false) == 0 && session::use_set("mingren", false) == 0 &&
                    session::use_set("yiren", false) == 0 && session::use_set("diming", true) == 0 &&
                    session::use_set("mingren", true) == 0 && session::use_set("yiren", true) == 0;
    }
    check(rounds_ok && rank_after(s, "lianxiqu", "濂溪区") == with, "20 rounds of all three sets off and on");
    t = clock_ns();
    let a = session::set_scheme("flypy");
    let to_flypy = clock_ns() - t;
    t = clock_ns();
    let b = session::set_scheme("fullpinyin");
    let to_full = clock_ns() - t;
    check(a == 0 && b == 0 && to_flypy < 1000000 && to_full < 1000000,
          str("switching schemes: ", to_flypy / 1000, " µs to 小鹤, ", to_full / 1000, " µs back (gate: under 1 ms)"));
}

// Pumps until no phrase job is pending or waiting (20 s at most).
fn settle() -> bool {
    var waited: i64 = 0;
    while (session::pump() & session::PUMP_PENDING) != 0 {
        if waited > 20000 { return false; }
        sleep_ms(5);
        waited += 5;
    }
    return true;
}

fn status_starts(prefix: const u8[:]) -> bool {
    let st = session::phrases_status();
    st.len >= prefix.len && compare(st[..prefix.len], prefix) == 0
}

// Custom phrases: a text file compiled by a contained worker in the
// background, mounted when no composition is in progress.
fn custom_phrases(s: u64) {
    let dir = "build/phrases-test";
    make_dir(dir);
    let source = "build/phrases-test/custom_phrases.txt";
    write_file(source, str("# test list\n雾凇奇观\twu song qi guan\n量子纠缠态\tliangzijiuchantai\n重庆小面\tchóng qìng xiǎo miàn\n",
                           "我的邮箱\tyx\nme@example.com\tyx\t2000000\nno tab on this line\n某某\tzzz9\n龘靐齉\tda bing nang\n"));
    let job = session::compile_phrases(source, dir);
    check(job > 0 && settle() && status_starts("ready\t4\t2\t2\t7\t"),
          str("compiled in the background: 4 words, 2 shortcuts, 2 lines skipped from line 7 (", session::phrases_status(), ")"));
    first_is(s, "dabingnang", "龘靐齉", true);
    first_is(s, "wusongqiguan", "雾凇奇观", true);
    first_is(s, "liangzijiuchantai", "量子纠缠态", true);
    first_is(s, "cqxm", "重庆小面", true);
    press(s, session::KEY_ESCAPE);
    type_text(s, "yx");
    check(candidate(0) == "me@example.com" && candidate(1) == "我的邮箱", "shortcut yx: the heavier first, then the other");
    press(s, session::KEY_ESCAPE);
    session::set_scheme("flypy");
    first_is(s, "wussqigr", "雾凇奇观", true);
    first_is(s, "yx", "me@example.com", true);
    session::set_scheme("fullpinyin");

    // The way people write it: spaces instead of a tab (a full-width one,
    // too), and codes in the keys of the scheme in use.
    write_file(source, "嫑嫑 biao biao\n我的地址　dz\n齉齉 nhnh 300\n");
    session::set_scheme("flypy");
    session::compile_phrases(source, dir);
    check(settle() && status_starts("ready\t2\t1\t0\t"),
          str("spaces work as well as a tab, and 小鹤 keys make a word (", session::phrases_status(), ")"));
    first_is(s, "bnbn", "嫑嫑", true);
    first_is(s, "nhnh", "齉齉", true);
    first_is(s, "dz", "我的地址", true);
    session::set_scheme("fullpinyin");
    first_is(s, "biaobiao", "嫑嫑", true);
    first_is(s, "nangnang", "齉齉", true);

    // Mid-composition the new result waits; it lands once the composition ends.
    write_file(source, "齉靐龘\tnang bing da\n");
    press(s, session::KEY_ESCAPE);
    type_text(s, "wusong");
    session::compile_phrases(source, dir);
    var waited: i64 = 0;
    while !status_starts("ready") && waited < 20000 { session::pump(); sleep_ms(5); waited += 5; }
    check((session::pump() & session::PUMP_PENDING) != 0 && rank_after(s, "nangbingda", "齉靐龘") < 0 &&
          rank_after(s, "biaobiao", "嫑嫑") == 0, "  compiled while composing: staged, the old list still in use");
    check(settle() && rank_after(s, "nangbingda", "齉靐龘") == 0 && rank_after(s, "biaobiao", "嫑嫑") < 0,
          "  after the composition ends: the new list in use, the old one gone");

    // Two jobs in a row: only the newer one's result counts, whichever ends last.
    let older = "build/phrases-test/older.txt";
    write_file(older, "龘龘\tda da\n");
    write_file(source, "靐靐\tbing bing\n齉齉\tnang nang\n");
    let a = session::compile_phrases(older, dir);
    let b = session::compile_phrases(source, dir);
    check(b == a + 1 && settle() && status_starts("ready\t2\t") && rank_after(s, "dada", "龘龘") < 0 &&
          rank_after(s, "bingbing", "靐靐") == 0, "two jobs: the newer one's result is the one in use");

    // A worker that aborts ends alone: the session goes on, the old phrases stay.
    session::phrases_test_abort = true;
    session::compile_phrases(source, dir);
    check(settle() && status_starts("failed") && find(session::phrases_status(), "phrases.goose") >= 0 &&
          rank_after(s, "bingbing", "靐靐") == 0,
          str("a worker that aborts: the job fails with only the check's place (", session::phrases_status(), "), the phrases in use stay"));
    first_is(s, "nihao", "你好", true);

    // An empty list takes everything away.
    write_file(source, "# nothing\n");
    session::compile_phrases(source, dir);
    check(settle() && status_starts("ready\t0\t0\t") && !sets::mounted("custom") && phrases::live.list.len == 0 &&
          rank_after(s, "bingbing", "靐靐") < 0, "an empty list: no custom words or shortcuts left");
}

fn control_g(s: u64) -> u32 { session::key(s, key_event(session::KEY_OTHER, 'g', session::MOD_CONTROL)) }

// The daily character set, and Control-g for the full one.
fn charsets(s: u64) {
    absent(s, "gei", "給");
    absent(s, "hou", "後");
    within(s, "ei", "诶", 6);
    within(s, "biang", "𰻞", 6);
    within(s, "kun", "堃", 30);
    first_is(s, "diaosi", "屌丝", true);
    first_is(s, "likasili", "李·卡斯利", true);      // a mark with no syllable of its own
    press(s, session::KEY_ESCAPE);
    type_text(s, "gei");
    let r = control_g(s);
    let snap = session::snapshot(s);
    let flags: i64 = (snap[6] as i64) | ((snap[7] as i64) << 8);
    check((r & session::DIRTY) != 0 && rank("給") >= 0 && (flags & session::FLAG_FULL_CHARSET) != 0,
          str("Control-g while composing shows the full set (給 for gei, rank ", rank("給"), "), and the snapshot says so"));
    check(compare(candidate(0), "给") == 0, "  给 stays first");
    control_g(s);
    check(rank("給") < 0 && !decoder::full_charset, "Control-g again: back to the daily set");
    press(s, session::KEY_ESCAPE);
    check(control_g(s) == 0, "Control-g passes through when not composing");
}

// Random keys, weighted towards letters so inputs grow long: whatever is
// typed, no key may fail a check (which would end the IME's process).
fn random_keys(s: u64) {
    var r = rng { 7 };
    let keys = "abcdefghijklmnopqrstuvwxyzaeiouhngaeiouhng'`78901234-=";
    var n: i64 = 0;
    for i in 20000 {
        let k = r.rand_int(keys.len + 4);
        if k < keys.len { typed(s, keys[k]); }
        else if k == keys.len { press(s, session::KEY_BACKSPACE); }
        else if k == keys.len + 1 { press(s, session::KEY_SPACE); }
        else if k == keys.len + 2 { press(s, session::KEY_DOWN); }
        else if r.rand_int(4) == 0 { press(s, session::KEY_ESCAPE); }
        if session::input.len > 40 { n++; }
    }
    press(s, session::KEY_ESCAPE);
    check(n > 0, str("20,000 random keys (letters, ' ` tones, digits, editing keys), ", n,
                     " of them on input over 40 bytes, and no check failed"));
}

fn keyed(s: u64, c: i64, flags: i64) -> u32 {
    session::key(s, session::KeyEvent { key: session::KEY_OTHER as u16, flags: flags as u16, modifiers: 0,
                                        codepoint: c as u32, time_ms: 0 })
}

// Types `input` and picks `text` from the first page with its digit key.
fn pick(s: u64, input: const u8[:], text: const u8[:], flags: i64) -> bool {
    press(s, session::KEY_ESCAPE);
    type_text(s, input);
    let r = rank(text);
    guard r >= 0 && r < session::PAGE_SIZE else { return false; }
    keyed(s, '1' + r, flags);
    return true;
}

fn rank_after(s: u64, input: const u8[:], text: const u8[:]) -> i64 {
    press(s, session::KEY_ESCAPE);
    type_text(s, input);
    let r = rank(text);
    press(s, session::KEY_ESCAPE);
    return r;
}

// The user dictionary: learning from conversions, keeping, forgetting.
fn learning(s: u64) {
    userdb::reset();
    userdb::clock_override = 1794000000;          // 2026-11-07, so days are fixed
    let before = rank_after(s, "xian", "西安");
    check(before > 0, str("before learning, xian puts 西安 at rank ", before));
    check(pick(s, "xian", "西安", 0) && session::commit == "西安", "picking 西安 for xian commits it");
    check(rank_after(s, "xian", "西安") == 0, "learned: next time xian puts 西安 first");
    check(rank_after(s, "xi'an", "西安") == 0 && rank_after(s, "xiangan", "先干") >= 0,
          "  and other input is still read as before");

    // A phrase built from two picks that the engine did not offer: 说好,
    // then whichever of 分为 and 氛围 it did not put first (with the grammar
    // model it reads 说好分为 right; without, 说好氛围).
    press(s, session::KEY_ESCAPE);
    type_text(s, "shuohaofenwei");
    let first = candidate(0);
    session::select(rank("说好"));
    let other: u8[>..] = if first == "说好分为" { "氛围" } else { "分为" };
    session::select(rank(other));
    let phrase = str("说好", other);
    check(session::commit == phrase && first != phrase,
          str("shuohaofenwei: 说好 then ", other, " commits ", phrase, " (the engine offered ", first, ")"));
    first_is(s, "shuohaofenwei", phrase, true);

    // Kept and restored, by text: what the host encrypts and stores.
    var saved: u8[>..] = [];
    saved.append(session::user_save());
    check(find(saved, "西安\txī ān\t2.000\t") >= 0 && find(saved, str(phrase, "\tshuō hǎo fēn wéi\t")) >= 0 &&
          find(saved, "\nfullpinyin:xian\t西安\t1.000\t") >= 0 &&
          find(saved, str("\nfullpinyin:shuohaofenwei\t", phrase, "\t")) >= 0,
          "saved: words by text and toned pinyin (a pick counts 2 uses), choices by the input typed");
    userdb::reset();
    check(rank_after(s, "xian", "西安") > 0, "emptied: 西安 is back where the lexicon puts it");
    check(session::user_restore(saved) == 0 && rank_after(s, "xian", "西安") == 0, "restored: 西安 first again");
    check(session::user_restore("not a dictionary") == 1 && userdb::lex.entries.len == 0,
          "something that is not a saved dictionary is refused, leaving it empty");
    var odd: u8[>..] = [];
    odd.append(userdb::HEADER);
    odd.append("\n西安\txī ān\t2\t20399\n乂\tyìx\t1\t20399\nbad line\n");
    check(session::user_restore(odd) == 0 && rank_after(s, "xian", "西安") == 0,
          "a saved dictionary with bad lines: the good ones load");
    var again: u8[>..] = [];
    again.append(session::user_save());
    check(find(again, "乂\tyìx\t1\t20399") >= 0 && find(again, "bad line") < 0,
          "  a line naming unknown syllables is kept for later, a malformed one is dropped");

    // Forgetting.
    userdb::reset();
    pick(s, "xian", "西安", 0);
    userdb::clock_override += 60;
    check(userdb::forget(userdb::RECENT) == 2 && rank_after(s, "xian", "西安") > 0,
          "forget the last 15 minutes: 西安 is unlearned");
    pick(s, "xian", "西安", 0);
    userdb::clock_override += 3600;
    check(userdb::forget(userdb::RECENT) == 0 && rank_after(s, "xian", "西安") == 0,
          "  learning from an hour ago stays");
    check(userdb::forget(userdb::TODAY) >= 1 && rank_after(s, "xian", "西安") > 0, "forget today: gone");

    // Forgetting today takes back only today's uses. 西安 learned a month ago
    // and picked again today (twice), a choice made then and again today, and
    // a word first learned today; the IME restarts in between (saved and
    // restored), and today is forgotten: 西安 and the choice go back to their
    // uses and day from before today, the new word goes.
    userdb::reset();
    let now_was = userdb::clock_override;
    userdb::clock_override = now_was - 30 * 86400;
    pick(s, "xian", "西安", 0);
    pick(s, "xian", "西安", 0);
    let month_ago = userdb::today();
    press(s, session::KEY_ESCAPE);
    type_text(s, "zgr");
    let zgr_pick = candidate(2);
    session::select(2);
    userdb::clock_override = now_was;
    pick(s, "xian", "西安", 0);
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_ESCAPE);
    type_text(s, "zgr");
    session::select(rank(zgr_pick));
    pick(s, "xianzai", "现在", 0);
    var midday: u8[>..] = [];
    midday.append(session::user_save());
    check(find(midday, str("#base\t4.000\t", month_ago, "\n")) >= 0 && find(midday, str("#base\t1.000\t", month_ago, "\n")) >= 0,
          "used today: a word and a choice are saved with what they were before today");
    check(session::user_restore(midday) == 0 && userdb::forget(userdb::TODAY) >= 3,
          "  restored after a restart, and today forgotten");
    var after: u8[>..] = [];
    after.append(session::user_save());
    check(find(after, str("西安\txī ān\t4.000\t", month_ago, "\n")) >= 0 && rank_after(s, "xian", "西安") == 0,
          "forget today: 西安, learned a month ago and used again today, keeps its uses and day from before today");
    check(find(after, str("fullpinyin:zgr\t", zgr_pick, "\t1.000\t", month_ago, "\n")) >= 0 &&
          rank_after(s, "zgr", zgr_pick) == 0, "  as does a choice made a month ago and again today");
    check(find(after, "现在\t") < 0 && find(after, "#base") < 0,
          "  a word first learned today is gone, and nothing of today is left to take back");

    // Forgetting the last 15 minutes likewise: 西安 learned a month ago and
    // a choice made then, used again a minute ago, go back to how they were.
    userdb::reset();
    userdb::clock_override = now_was - 30 * 86400;
    pick(s, "xian", "西安", 0);
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_ESCAPE);
    type_text(s, "zgr");
    session::select(rank(zgr_pick));
    userdb::clock_override = now_was;
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_ESCAPE);
    type_text(s, "zgr");
    session::select(rank(zgr_pick));
    userdb::clock_override += 60;
    check(userdb::forget(userdb::RECENT) >= 2, "forget the last 15 minutes after using old learning again");
    var recent: u8[>..] = [];
    recent.append(session::user_save());
    check(find(recent, str("西安\txī ān\t4.000\t", month_ago, "\n")) >= 0 &&
          find(recent, str("fullpinyin:zgr\t", zgr_pick, "\t1.000\t", month_ago, "\n")) >= 0 &&
          rank_after(s, "xian", "西安") == 0,
          "  西安 and the zgr choice keep their uses and day from a month ago");

    // Handed over to the next build of the engine in the process (a core
    // loaded by an update): what was learned before it can still be forgotten
    // as the last 15 minutes. 西安 from a month ago is used again and 现在 is
    // new; the dictionary is saved and restored, the journal handed over.
    userdb::reset();
    userdb::clock_override = now_was - 30 * 86400;
    pick(s, "xian", "西安", 0);
    pick(s, "xian", "西安", 0);
    userdb::clock_override = now_was;
    pick(s, "xian", "西安", 0);
    pick(s, "xianzai", "现在", 0);
    var dict: u8[>..] = [];
    dict.append(session::user_save());
    var handed: u8[>..] = [];
    handed.append(session::journal_save());
    check(session::user_restore(dict) == 0 && userdb::journal.len == 0 && userdb::journal_restore(handed) >= 2,
          "a new core: the dictionary restored, and the journal handed over taken over");
    var commits_zero = true;
    for c in userdb::journal { if c.commit != 0 { commits_zero = false; } }
    check(commits_zero, "  its changes carry no commit, which was the old core's numbering");
    userdb::clock_override += 60;
    check(userdb::forget(userdb::RECENT) >= 2, "  forgetting the last 15 minutes after it");
    var undone: u8[>..] = [];
    undone.append(session::user_save());
    check(find(undone, str("西安\txī ān\t4.000\t", month_ago, "\n")) >= 0 && find(undone, "现在\t") < 0,
          "  takes back what was learned before the new core: 西安 as it was, 现在 gone");
    userdb::clock_override += 3600;
    check(session::user_restore(dict) == 0 && userdb::journal_restore(handed) == 0 &&
          userdb::journal_restore("garbage\tline\n1\tx\n") == 0,
          "  a journal handed over an hour later, or malformed, restores nothing");
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_ESCAPE);
    type_text(s, "xian");
    session::key(s, key_event(session::KEY_BACKSPACE, 0, session::MOD_SHIFT));
    check(rank(candidate(0)) == 0 && candidate(0) != "西安" && session::input == "xian",
          "Shift-Backspace on the highlighted 西安 forgets it, and the letters stay");
    press(s, session::KEY_ESCAPE);

    // Choices: exactly what was typed comes first next time.
    userdb::reset();
    press(s, session::KEY_ESCAPE);
    type_text(s, "zgr");
    let third = candidate(2);
    session::select(2);
    check(rank_after(s, "zgr", third) == 0, str("zgr: picking ", third, " (third) puts it first for zgr next time"));
    // A single letter teaches the choice, not the word.
    userdb::reset();
    let gai_before = rank_after(s, "gai", "盖");
    press(s, session::KEY_ESCAPE);
    type_text(s, "g");
    let g_rank = rank("盖");
    session::select(g_rank);
    check(g_rank > 0 && rank_after(s, "g", "盖") == 0 && rank_after(s, "gai", "盖") == gai_before,
          str("g: picking 盖 (rank ", g_rank, ") puts it first for g, and leaves gai alone (rank ", gai_before, ")"));

    // A commit deleted at once and typed again differently is taken back.
    userdb::reset();
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_BACKSPACE);
    press(s, session::KEY_BACKSPACE);
    check(pick(s, "xian", "先", 0) && rank_after(s, "xian", "先") == 0 && userdb::lex.entries.len == 1,
          "西安 deleted with two Backspaces, xian typed again and 先 picked: 西安's learning is taken back");
    userdb::reset();
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_BACKSPACE);
    check(pick(s, "xian", "先", 0) && userdb::lex.entries.len == 2,
          "  but not when only part of it was deleted (an edit, not a correction)");
    userdb::reset();
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_LEFT);
    press(s, session::KEY_BACKSPACE);
    press(s, session::KEY_BACKSPACE);
    check(pick(s, "xian", "先", 0) && userdb::lex.entries.len == 2,
          "  nor after the caret moved: the Backspaces deleted something else");

    // A sentence accepted in one go: its words count once each, and it
    // becomes a phrase if short.
    userdb::reset();
    press(s, session::KEY_ESCAPE);
    type_text(s, "woshizhongguoren");
    press(s, session::KEY_SPACE);
    var accepted: u8[>..] = [];
    accepted.append(session::user_save());
    check(session::commit == "我是中国人" && find(accepted, "中国人\tzhōng guó rén\t1.000") >= 0 &&
          find(accepted, "我是中国人\twǒ shì zhōng guó rén\t1.000") >= 0,
          "an accepted sentence: each word counts once, and the 5-syllable sentence becomes a phrase");

    // The dictionary changing in the middle of a composition (found by the
    // keystroke fuzzer): a pick already made keeps what it chose, and the
    // menu is rebuilt before its words are used.
    userdb::reset();
    pick(s, "zhongguo", "中国", 0);
    press(s, session::KEY_ESCAPE);
    type_text(s, "zhongguoren");
    session::select(rank("中国"));
    userdb::forget(userdb::EVERYTHING);
    let done = press(s, session::KEY_SPACE);
    check((done & session::HAS_COMMIT) != 0 && session::commit == "中国人" && userdb::lex.entries.len >= 2,
          "forgetting everything between two picks: the commit still learns 中国 and 中国人, from its own copy");
    userdb::reset();
    pick(s, "xian", "西安", 0);
    press(s, session::KEY_ESCAPE);
    type_text(s, "xian");
    userdb::forget(userdb::EVERYTHING);
    check(typed(s, '1') != 0 && session::commit.len > 0, "  and a stale menu is rebuilt before a pick reads it");

    // What is not learned.
    userdb::reset();
    pick(s, "xian", "西安", session::KEYFLAG_NO_LEARN);
    check(userdb::lex.entries.len == 0 && session::commit == "西安",
          "a pick the host marks no-learn (secure field, no-learn app, incognito) commits but teaches nothing");
    press(s, session::KEY_ESCAPE);
    type_text(s, "xian");
    press(s, session::KEY_RETURN);
    check(userdb::lex.entries.len == 0, "letters committed as typed teach nothing");

    // Decay: unused words fade and are dropped when saved.
    pick(s, "xian", "西安", 0);
    userdb::clock_override += 200 * 86400;
    check(rank_after(s, "xian", "西安") == 0, "200 days unused, 西安 still leads (uses decay, the bonus stays)");
    userdb::clock_override += 200 * 86400;
    var faded: u8[>..] = [];
    faded.append(session::user_save());
    check(find(faded, "西安") < 0, "400 days unused, it is dropped when saved");

    // A learned rare character shows in the daily set.
    userdb::reset();
    press(s, session::KEY_ESCAPE);
    type_text(s, "gei");
    session::key(s, key_event(session::KEY_OTHER, 'g', session::MOD_CONTROL));
    session::select(rank("給"));                  // commits, so Control-g now would pass through
    decoder::full_charset = false;
    check(!decoder::full_charset && rank_after(s, "gei", "給") >= 0, "a rare character the user chose shows in the daily set");

    userdb::reset();
    let natural = rank_after(s, "xian", "西安");
    check(pick(s, "xian", "西安", 0), "bury: 西安 is picked");
    press(s, session::KEY_ESCAPE);
    type_text(s, "xian");
    session::key(s, key_event(session::KEY_BACKSPACE, 0, session::MOD_SHIFT));
    let buried = rank_after(s, "xian", "西安");
    check(userdb::tomb_count() >= 1 && (buried < 0 || buried > natural),
          str("Shift-Backspace buries 西安 under its old rank ", natural, " (now ", buried, ")"));
    var kept: u8[>..] = [];
    kept.append(session::user_save());
    check(find(kept, "#tomb\t西安\t") >= 0, "the burial is stored with the dictionary");
    press(s, session::KEY_ESCAPE);
    type_text(s, "xian");
    let again = rank("西安");
    if again >= 0 { session::select(again); }
    check(again >= 0 && userdb::tomb_count() == 0, "picking 西安 again lifts the burial");

    userdb::reset();
    check(pick(s, "xian", "先", 0), "a character can be picked");
    press(s, session::KEY_ESCAPE);
    type_text(s, "xian");
    session::key(s, key_event(session::KEY_BACKSPACE, 0, session::MOD_SHIFT));
    check(userdb::tomb_count() == 0 && rank_after(s, "xian", "先") >= 0,
          "a character is unlearned and not buried");
    for _ in 30 { pick(s, "shi", "是", 0); }
    first_is(s, "shijian", "时间", true);

    userdb::reset();
    userdb::clock_override = 1794000000;
    userdb::observe(1, 0, 2, 2);
    check(userdb::recall(1, 0, 2, 2) > 0.0 && userdb::recall(0, 0, 2, 2) == 0.0 && userdb::recall(1, 0, 2, 1) == 0.0 &&
          userdb::recall(9, 0, 2, 2) == 0.0, "contextual memory boosts that reading only, and not a bare or mismatched one");
    userdb::observe(1, 5, 2, 2);
    check(userdb::recall(1, 5, 2, 2) > 0.0 && userdb::recall(1, 8, 2, 2) > 0.0, "a trigram still backs off to its bigram");
    userdb::clock_override += 7 * 3600;
    check(userdb::pom_alive() == 0 && userdb::recall(1, 5, 2, 2) == 0.0, "six hours later the quadratic fade is gone");

    userdb::reset();
    userdb::clock_override = 0;
}

fn latency(s: u64) {
    let sentences = ["jintiantianqibucuowomenquchuqiwanba", "woshiyigezhongguoren", "zgrmghg",
                     "xianzaikaishishurufaceshi", "zhegeshurufashiyonggooseyuyanxiede"];
    var samples: i64[>..] = [];
    for round in 20 {
        for text in sentences {
            press(s, session::KEY_ESCAPE);
            for c in text {
                let t = clock_ns();
                typed(s, c);
                samples.push(clock_ns() - t);
            }
        }
    }
    press(s, session::KEY_ESCAPE);
    sort(samples);
    let n = samples.len - 1;
    print("latency  key → candidates, ", samples.len, " keys (inputs up to 35 letters): p50 ",
          samples[n / 2] / 1000, " µs, p99 ", samples[n * 99 / 100] / 1000, " µs, max ", samples[n] / 1000, " µs");
    check(samples[n * 99 / 100] < 5000000, "p99 under 5 ms");

    // With the reranker the candidates are shown after refine: the time to
    // the reranked candidates, reported (the key itself, and so the preedit
    // and the app typed in, wait only for the part above).
    if session::rerank_state() == 1 {
        var shown: i64[>..] = [];
        for round in 5 {
            for text in sentences {
                press(s, session::KEY_ESCAPE);
                for c in text {
                    let t = clock_ns();
                    if (typed(s, c) & session::PENDING) != 0 { session::refine(s); }
                    shown.push(clock_ns() - t);
                }
            }
        }
        press(s, session::KEY_ESCAPE);
        sort(shown);
        let m = shown.len - 1;
        print("latency  key → reranked candidates (refine included), ", shown.len, " keys: p50 ", shown[m / 2] / 1000,
              " µs, p99 ", shown[m * 99 / 100] / 1000, " µs, max ", shown[m] / 1000, " µs");
    }

    // M1's gates: p99 ≤ 2 ms for inputs up to 20 letters, and ≤ 5 ms at
    // worst for long, abbreviation-heavy input (40 letters and more).
    var short: i64[>..] = [];
    var long: i64[>..] = [];
    let heavy = ["zgrmghgzgrmghgzgrmghgzgrmghgzgrmghgzgrmghg", "wszgrwszgrwszgrwszgrwszgrwszgrwszgrwszgrws",
                 "jintiantianqibucuowomenquchuqiwanbazgrmghgxyz", "xianzaikaishishurufaceshizhegeshurufashiyong",
                 "bcdfghjklmnpqrstwxyzbcdfghjklmnpqrstwxyzbcd"];
    for round in 10 {
        for text in heavy {
            press(s, session::KEY_ESCAPE);
            for i in text.len {
                let t = clock_ns();
                typed(s, text[i]);
                let took = clock_ns() - t;
                if i < 20 { short.push(took); } else { long.push(took); }
            }
        }
    }
    press(s, session::KEY_ESCAPE);
    sort(short);
    sort(long);
    let a = short.len - 1;
    let b = long.len - 1;
    print("latency  up to 20 letters: p99 ", short[a * 99 / 100] / 1000, " µs; 21 to 45 letters, abbreviation-heavy: p99 ",
          long[b * 99 / 100] / 1000, " µs, max ", long[b] / 1000, " µs");
    check(short[a * 99 / 100] <= 2000000, "gate: p99 ≤ 2 ms for inputs up to 20 letters");
    check(long[b * 99 / 100] <= 5000000, "gate: ≤ 5 ms for long, abbreviation-heavy input (p99; the max is above)");

    // Past a full composition, where each key may first commit a word to make
    // room: real long clauses (zhihu120's longest, in full pinyin) and
    // abbreviations, timed from the 46th letter on.
    var longest: i64[>..] = [];
    let clauses = ["lingyifangmiantamenyejiangchangshirangyixiedaxingqixietongguosheshuidefangshidaodaqianfang",
                   "zheyeshiqingzanggaoyuanjizhoubiandiqudongjiequanzaihaichengxiandequanxinxianzhutezheng",
                   "zgrmghgzgrmghgzgrmghgzgrmghgzgrmghgzgrmghgwszgrwszgrwszgrwszgrwszgrwszgrwszgrwszgrwszgrwszgrwszgrws",
                   "jintiantianqibucuowomenquchuqiwanbaxianzaikaishishurufaceshizhegeshurufashiyonggooseyuyanxiedewoshizhongguoren"];
    for round in 5 {
        for text in clauses {
            press(s, session::KEY_ESCAPE);
            for i in text.len {
                let t = clock_ns();
                typed(s, text[i]);
                let took = clock_ns() - t;
                if i >= 45 { longest.push(took); }
            }
        }
    }
    press(s, session::KEY_ESCAPE);
    sort(longest);
    let z = longest.len - 1;
    print("latency  46 to 110 letters, a full composition making room: p99 ", longest[z * 99 / 100] / 1000,
          " µs, max ", longest[z] / 1000, " µs");
    check(longest[z * 99 / 100] <= 5000000, "gate: ≤ 5 ms past a full composition (p99)");
}

// Past a composition's lattice::MAX_INPUT keys, a key commits the best
// reading's first word to make room: nothing typed is lost.
fn long_input(s: u64) {
    press(s, session::KEY_ESCAPE);
    let one = "woshizhongguoren";               // 我是中国人, 16 letters; nine times is 144
    var typed_letters: i64 = 0;
    var committed_letters: i64 = 0;
    var commits: i64 = 0;
    var committed: u8[>..] = [];
    var want: u8[>..] = [];
    for round in 9 {
        want.append("我是中国人");
        for c in one {
            let before = session::input.len;
            let r = typed(s, c);
            typed_letters++;
            if (r & session::HAS_COMMIT) != 0 {
                commits++;
                committed.append(session::commit);
                committed_letters += before + 1 - session::input.len;
            }
        }
    }
    let kept = committed_letters + session::input.len;
    check(commits > 0 && kept == typed_letters && session::input.len <= lattice::MAX_INPUT,
          str(typed_letters, " letters typed with no pause: ", commits, " first words committed to make room (",
              committed_letters, " letters), ", session::input.len, " still to convert, none lost"));
    var whole = committed;
    whole.append(candidate(0));
    hope(whole == want, str("  and the commits with the rest read 我是中国人 nine times (got ", whole, ")"));
    // a full composition again, then a tone and a ': kept, after a word is committed for them
    let full = session::input.len;
    let toned = typed(s, '7');
    let tone_kept = session::input.len > 0 && session::input[session::input.len - 1] == '7';
    type_text(s, "zhong");
    while session::room() { typed(s, 'a'); }
    let sep = typed(s, '\'');
    let sep_kept = session::input.len > 0 && session::input[session::input.len - 1] == '\'';
    check(full == lattice::MAX_INPUT && tone_kept && (toned & session::HAS_COMMIT) != 0 && sep_kept &&
          (sep & session::HAS_COMMIT) != 0, "  a tone and a ' typed into a full composition are kept the same way");
    press(s, session::KEY_ESCAPE);
}

fn show_code(s: u64, code: const u8[:]) {
    press(s, session::KEY_ESCAPE);
    session::input.append(code);
    session::rebuild();
}

fn top_form(i: i64) -> u8[>..] {
    var t: u8[>..] = [];
    english::top_form(i, t);
    return t;
}

fn has_capital_byte(text: const u8[:]) -> bool {
    for c in text { if c >= 'A' && c <= 'Z' { return true; } }
    return false;
}

// The English list, typed exactly in the scheme already selected.
// Gate: on the first page for 99%, and first whenever there is no complete
// Chinese reading. Otherwise a common word goes second when the Chinese
// reading is weak (an abbreviation, a key left over), and when the keys read
// as full syllables an English word comes after every Chinese candidate on
// the first page (the last place, or right after a shorter list).
fn english_list(s: u64, order: const i64[:], from: i64, to: i64, what: const u8[:]) {
    var checked: i64 = 0;
    var on_page: i64 = 0;
    var rule_bad: i64 = 0;
    var second_bad: i64 = 0;
    var over_weak: i64 = 0;
    var sample: u8[>..] = [];
    for n in from..to {
        let i = order[n];
        let code = english::live.entries[i].code;
        let form = top_form(i);
        show_code(s, code);
        let r = rank(form);
        checked++;
        if r >= 0 && r < session::PAGE_SIZE { on_page++; }
        else if sample.len < 240 { format(sample, " ", code, "→", form, "#", r); }
        if session::letters_unread || session::weak_chinese {
            if r != 0 { rule_bad++; }
            if session::weak_chinese { over_weak++; }
        } else if session::chinese_full {
            if r != behind_chinese() { second_bad++; }
        } else if english::live.entries[i].weight >= english::COMMON_WEIGHT && r != 1 {
            second_bad++;
        }
        press(s, session::KEY_ESCAPE);
    }
    check(checked > 0 && on_page * 100 >= checked * 99,
          str(what, ": ", on_page, " of ", checked, " on the first page (gate: 99%)", sample));
    check(rule_bad == 0, str(what, ": first whenever the letters have no Chinese reading, or one 2^25 times less likely (",
                             over_weak, " of those; ", rule_bad, " were not first)"));
    check(second_bad == 0, str(what, ": otherwise second after a reading with an abbreviation if common, behind the ",
                               "first page's Chinese after a full one (", second_bad, " were not)"));
}

// Fuzzy pinyin (docs/fuzzy-pinyin.md): off by default; a group on makes its
// spellings count, in every scheme; groups combine; the choice holds across
// a scheme switch.
fn on_first_page(s: u64, keys: const u8[:], text: const u8[:]) -> bool {
    press(s, session::KEY_ESCAPE);
    type_text(s, keys);
    let r = rank(text);
    press(s, session::KEY_ESCAPE);
    return r >= 0 && r < session::PAGE_SIZE;
}

fn fuzzy_pinyin(s: u64) {
    check(session::fuzzy_groups() == "z_zh\t0\nc_ch\t0\ns_sh\t0\nn_l\t0\nr_l\t0\nr_y\t0\nh_f\t0\nk_g\t0\nen_eng\t0\nin_ing\t0\n",
          "fuzzy pinyin: 万象's ten groups, all off by default");
    check(!on_first_page(s, "zong", "中") && !on_first_page(s, "sanghai", "上海") && on_first_page(s, "zong", "总"),
          "off: zong is 总, never 中; sanghai is not 上海");
    session::set_fuzzy("z_zh");
    check(on_first_page(s, "zong", "中") && on_first_page(s, "zong", "总") && first(s, "zongguo") == "中国",
          "z = zh: zong offers 中 beside 总, and zongguo is 中国");
    check(!on_first_page(s, "sanghai", "上海"), "  only that group: s = sh stays off (sanghai is not 上海)");
    check(!on_first_page(s, "zen", "正"), "  zen is not 正 (zheng) with z = zh alone");
    session::set_fuzzy("z_zh en_eng");
    check(on_first_page(s, "zen", "正"), "z = zh and en = eng together: zen offers 正 (zheng)");
    session::set_fuzzy("z_zh nonsense");
    check(session::fuzzy_groups()[..7] == "z_zh\t1\n" && on_first_page(s, "zong", "中"), "an unknown group is ignored");
    check(session::set_scheme("flypy") == 0 && on_first_page(s, "zs", "中") && first(s, "zsgo") == "中国",
          "the choice holds in 小鹤双拼: zs offers 中, zsgo is 中国");
    check(preedit_of(s, "zsgo") == "zs go", "  the preedit still shows the keys typed: zs go");
    session::set_fuzzy("");
    check(!on_first_page(s, "zs", "中") && session::fuzzy_groups()[..7] == "z_zh\t0\n", "all off again: zs is not 中");
    check(session::set_scheme("fullpinyin") == 0, "back to full pinyin");
}

// The first candidate for `keys`, typed afresh.
fn first(s: u64, keys: const u8[:]) -> u8[>..] {
    press(s, session::KEY_ESCAPE);
    type_text(s, keys);
    let c = candidate(0);
    press(s, session::KEY_ESCAPE);
    return c;
}

// The reranker (engine/rerank.goose): a better sentence among the decoder's
// best put first, at once with rerank_sync and through refine as the host
// calls it, never over the user's own choice or a menu they moved through.
fn reranking(s: u64) {
    guard session::rerank_state() >= 0 else {
        print("skip  reranking: the images have no reranker (data/rerank.lock, make images)");
        return;
    }
    let keys = "yijiasankouhoubuchepiao";
    let decoded = "一家三口后部车票";
    let reranked = "一家三口候补车票";
    session::set_rerank(false);
    press(s, session::KEY_ESCAPE);
    var last: u32 = 0;
    for c in keys { last = typed(s, c); }
    check(compare(candidate(0), decoded) == 0 && (last & session::PENDING) == 0,
          str("reranker off: the decoder's ", candidate(0), ", nothing pending"));
    press(s, session::KEY_ESCAPE);
    session::set_rerank(true);

    session::rerank_sync = true;
    type_text(s, keys);
    check(compare(candidate(0), reranked) == 0 && compare(candidate(1), decoded) == 0,
          str("scored at once: ", candidate(0), " first, the decoder's ", candidate(1), " second"));
    press(s, session::KEY_ESCAPE);
    session::rerank_sync = false;

    // As the host does it: the key says PENDING, and the host calls refine
    // before it shows the candidates, so only the reranked menu is shown.
    press(s, session::KEY_ESCAPE);
    var result: u32 = 0;
    for c in keys { result = typed(s, c); }
    check((result & session::PENDING) != 0 && compare(candidate(0), decoded) == 0,
          "the key says the reranker may change the menu, and has not yet");
    let refined = session::refine(s);
    check((refined & session::DIRTY) != 0 && compare(candidate(0), reranked) == 0 &&
          compare(candidate(1), decoded) == 0 && session::refine(s) == 0,
          str("refine puts ", candidate(0), " first, the decoder's sentence second, and then has nothing left"));
    press(s, session::KEY_SPACE);
    check(compare(session::commit, reranked) == 0, str("Space commits the reranked sentence: ", session::commit));
    check(userdb::forget(userdb::RECENT) >= 1, "  and learns it like any choice (forgotten again here)");

    // A newer key replaces the menu waiting to be reranked; a menu the user
    // has moved through is left as it is.
    type_text(s, keys);
    typed(s, 'a');
    press(s, session::KEY_BACKSPACE);
    check((session::refine(s) & session::DIRTY) != 0 && compare(candidate(0), reranked) == 0,
          "refine reranks the menu of the latest key");
    press(s, session::KEY_ESCAPE);
    type_text(s, keys);
    press(s, session::KEY_RIGHT);
    check(session::refine(s) == 0 && compare(candidate(0), decoded) == 0,
          str("once the highlight moved, refine leaves the menu as it is: ", candidate(0)));
    press(s, session::KEY_ESCAPE);

    // The user's own choice stands: picking the decoder's sentence keeps it
    // first, with nothing to rerank.
    check(pick(s, keys, decoded, 0), str("picking ", decoded));
    session::rerank_sync = true;
    type_text(s, keys);
    check(compare(candidate(0), decoded) == 0, str("a sentence the user chose stays first: ", candidate(0)));
    press(s, session::KEY_ESCAPE);
    session::rerank_sync = false;
    userdb::forget(userdb::RECENT);
}

// Notes in `seen` if typing `code` offers `form` anywhere among the candidates.
fn offered_form(s: u64, code: const u8[:], form: const u8[:], seen: u8[>..]&) {
    show_code(s, code);
    if rank(form) >= 0 { format(seen, " ", code, "→", form); }
    press(s, session::KEY_ESCAPE);
}

// The first candidates and the placement flags, for a failing check's message.
fn menu_line() -> u8[>..] {
    var out: u8[>..] = [];
    format(out, " [full ", session::chinese_full, ", unread ", session::letters_unread, "]");
    var i: i64 = 0;
    while i < 8 && i < session::menu.candidates.len {
        let c = session::menu.candidates[i];
        format(out, " ", i, ":", session::menu.pool[c.text..c.text + c.len], if c.code_len > 0 { "(en)" } else { "" });
        i++;
    }
    return out;
}

// Where an English word goes behind the Chinese: the last place on the first
// page, or the end of a shorter list of Chinese candidates.
fn behind_chinese() -> i64 {
    var chinese: i64 = 0;
    for c in session::menu.candidates { if c.code_len == 0 { chinese++; } }
    return if chinese < session::PAGE_SIZE - 1 { chinese } else { session::PAGE_SIZE - 1 };
}

// The first page has no English candidate before position `upto`.
fn chinese_before(upto: i64) -> bool {
    var i: i64 = 0;
    while i < upto && i < session::menu.candidates.len {
        if session::menu.candidates[i].code_len != 0 { return false; }
        i++;
    }
    return true;
}

fn english_words(s: u64) {
    check(english::active() && english::live.entries.len > 2000, "the English dictionary is loaded");
    var order: i64[>..] = [];
    for i in english::live.entries.len { order.push(i); }
    sort(order) { a, b =>
        let wa = english::live.entries[a].weight;
        let wb = english::live.entries[b].weight;
        wa > wb || (wa == wb && compare(english::live.entries[a].code, english::live.entries[b].code) < 0)
    };
    var terms: i64[>..] = [];
    for i in order {
        if terms.len >= 300 { break; }
        if has_capital_byte(top_form(i)) { terms.push(i); }
    }
    check(terms.len == 300, "300 capitalized terms to stand for words people type in Chinese");
    check(session::set_scheme("fullpinyin") == 0, "English, typed in fullpinyin");
    english_list(s, order, 0, 2000, "fullpinyin, 2000 most frequent");
    english_list(s, terms, 0, terms.len, "fullpinyin, 300 terms");
    check(session::set_scheme("flypy") == 0, "English, typed in flypy");
    english_list(s, order, 0, 2000, "flypy, 2000 most frequent");
    english_list(s, terms, 0, terms.len, "flypy, 300 terms");
    check(session::set_scheme("fullpinyin") == 0, "back to full pinyin");

    show_code(s, "github");
    check(session::letters_unread && compare(candidate(0), "GitHub") == 0, "github has no Chinese reading, so GitHub is first");
    press(s, session::KEY_ESCAPE);
    show_code(s, "iphone");
    check(rank("iPhone") >= 0 && rank("iPhone") < session::PAGE_SIZE, "iphone → iPhone on the first page");
    press(s, session::KEY_ESCAPE);
    show_code(s, "nasa");
    check(rank("NASA") >= 0 && rank("NASA") < session::PAGE_SIZE, "nasa → NASA on the first page");
    press(s, session::KEY_ESCAPE);
    show_code(s, "ok");
    check(rank("ok") == 1, str("ok is common, so ok goes second (typed lowercase, its lowercase form) and the first stays Chinese",
                                menu_line()));
    press(s, session::KEY_ESCAPE);
    // Keys that read as full Chinese syllables keep the first page Chinese.
    show_code(s, "he");
    check(session::chinese_full && chinese_before(session::PAGE_SIZE - 1) && rank("he") == session::PAGE_SIZE - 1,
          str("he reads as a full syllable: Chinese keeps the first page, he takes its last place", menu_line()));
    press(s, session::KEY_ESCAPE);
    show_code(s, "chang");
    check(session::chinese_full && chinese_before(session::PAGE_SIZE - 1) && rank("change") >= session::PAGE_SIZE,
          str("chang: its completions (change, changed) wait past the first page", menu_line()));
    press(s, session::KEY_ESCAPE);
    // No plural noun and no third-person -s verb is offered (octo-prep leaves
    // them out with AGID): the word's own form is.
    var inflected_seen: u8[>..] = [];
    offered_form(s, "change", "changes", inflected_seen);
    offered_form(s, "progra", "programs", inflected_seen);
    offered_form(s, "windo", "windows", inflected_seen);
    offered_form(s, "car", "cars", inflected_seen);
    offered_form(s, "be", "is", inflected_seen);
    offered_form(s, "go", "goes", inflected_seen);
    check(inflected_seen.len == 0, str("no plural or third-person -s form among the candidates", inflected_seen));
    show_code(s, "windows");
    check(rank("Windows") >= 0 && rank("windows") < 0, "windows offers the name Windows, not the plural");
    press(s, session::KEY_ESCAPE);
    // An English word inside the best sentence keeps its keys in the preedit,
    // between the syllables around it; capitals typed show, and commit, as typed.
    let mixed_full = preedit_of(s, "woyonggithubzuosha");
    type_text(s, "woyonggithubzuosha");
    check(find(candidate(0), "GitHub") >= 0 && mixed_full == "wo yong github zuo sha",
          str("woyonggithubzuosha: ", candidate(0), ", the preedit keeping github between the syllables (got \"",
              mixed_full, "\")"));
    press(s, session::KEY_ESCAPE);
    check(session::set_scheme("flypy") == 0, "in 小鹤双拼");
    let mixed_flypy = preedit_of(s, "niysgithubzoua");
    type_text(s, "niysgithubzoua");
    check(find(candidate(0), "GitHub") >= 0 && mixed_flypy == "ni ys github zo ua",
          str("niysgithubzoua: ", candidate(0), ", the preedit ni ys github zo ua (got \"", mixed_flypy, "\")"));
    press(s, session::KEY_ESCAPE);
    check(session::set_scheme("fullpinyin") == 0, "back to full pinyin");
    let capital = preedit_of(s, "Github");
    type_text(s, "Github");
    press(s, session::KEY_RETURN);
    check(capital == "Github" && session::commit == "Github",
          str("a capital typed shows in the preedit and Enter commits it as typed (preedit \"", capital,
              "\", commit \"", session::commit, "\")"));
    show_code(s, "hello");
    check(!session::chinese_full && rank("hello") == 0,
          str("hello: its Chinese reading (和来咯) is 2^25 times less likely than the word, so hello comes first",
              menu_line()));
    press(s, session::KEY_ESCAPE);
    show_code(s, "when");
    check(!session::chinese_full && !session::letters_unread && rank("when") == 1,
          str("when reads only with an abbreviation, and is common: it goes second", menu_line()));
    press(s, session::KEY_ESCAPE);
    check(session::set_scheme("flypy") == 0, "in 小鹤双拼");
    show_code(s, "development");
    check(session::chinese_full && rank("development") == 0,
          str("小鹤 development: the Chinese reads every key, as nonsense (的这螺片蒽酮): development first", menu_line()));
    var nonsense: u8[>..] = [];
    for i in session::menu.candidates.len {
        let t = candidate(i);
        if t.len > 0 && t[0] >= 0x80 { nonsense.append(t); break; }
    }
    show_code(s, "when");
    check(rank("when") > 0, str("小鹤 when: 忘恩 is a real word, only 2^21 times less likely: Chinese stays first", menu_line()));
    show_code(s, "he");
    check(compare(candidate(0), "和") == 0, str("小鹤 he: 和 stays first", menu_line()));
    check(pick(s, "development", nonsense, 0) && rank_after(s, "development", nonsense) == 0,
          str("picking ", nonsense, " for development keeps it first the next time: a choice beats the rule"));
    check(userdb::forget(userdb::RECENT) >= 1 && rank_after(s, "development", "development") == 0,
          "forgetting the choice puts development first again");
    press(s, session::KEY_ESCAPE);
    check(session::set_scheme("fullpinyin") == 0, "back to full pinyin");

    press(s, session::KEY_ESCAPE);
    session::key(s, key_event(session::KEY_OTHER, 'H', session::MOD_SHIFT));
    type_text(s, "ello");
    check(compare(candidate(0), "Hello") == 0, "a capital Hello comes first, in the case typed");
    press(s, session::KEY_ESCAPE);
    session::key(s, key_event(session::KEY_OTHER, 'G', session::MOD_SHIFT));
    type_text(s, "ithub");
    check(compare(candidate(0), "GitHub") == 0, "Github keeps the dictionary's inner capitals");
    press(s, session::KEY_ESCAPE);

    show_code(s, "progra");
    var ids: i64[>..] = [];
    english::completions("progra", 2, ids);
    check(ids.len == 2, "progra completes to two words");
    if ids.len == 2 {
        let a = top_form(ids[0]);
        let b = top_form(ids[1]);
        let ra = rank(a);
        let rb = rank(b);
        let after = if session::letters_unread { ra == 0 && rb == 1 } else { ra >= 3 && rb == ra + 1 };
        check(after, str("progra → ", a, " then ", b, " (", ra, ", ", rb, ")"));
    }
    press(s, session::KEY_ESCAPE);

    type_text(s, "woyonggithub");
    check(compare(candidate(0), "我用GitHub") == 0, str("woyonggithub → 我用GitHub (got ", candidate(0), ")"));
    press(s, session::KEY_ESCAPE);

    session::set_english(false);
    show_code(s, "github");
    check(compare(candidate(0), "GitHub") != 0, "with English words off, github is not GitHub first");
    press(s, session::KEY_ESCAPE);
    session::set_english(true);

    userdb::reset();
    userdb::clock_override = 1794000000;
    check(pick(s, "ok", "OK", 0) && pick(s, "ok", "OK", 0), "picking OK for ok twice");
    check(rank_after(s, "ok", "OK") == 0, "learned: ok then offers OK first");
    var saved: u8[>..] = [];
    saved.append(session::user_save());
    check(find(saved, "\nok\tOK\t2.000\t") >= 0, "saved: the english section keeps code, text, uses, day");
    let quiet = userdb::changes;
    check(pick(s, "bug", "bug", session::KEYFLAG_NO_LEARN) && userdb::changes == quiet, "a no-learn pick teaches no English word");
    userdb::forget(userdb::EVERYTHING);
    check(rank_after(s, "ok", "OK") == 2, "forgetting everything puts OK back to its place, behind ok");
    check(session::user_restore(saved) == 0 && rank_after(s, "ok", "OK") == 0, "restoring brings the English word back");
    press(s, session::KEY_ESCAPE);
    type_text(s, "ok");
    session::key(s, key_event(session::KEY_BACKSPACE, 0, session::MOD_SHIFT));
    check(rank("OK") != 0 && session::input == "ok", "Shift-Backspace forgets the learned OK and leaves the letters");
    press(s, session::KEY_ESCAPE);

    session::set_english_space(true);
    check(pick(s, "ok", "OK", 0), "space: the first English word");
    check(pick(s, "ok", "OK", 0) && session::commit == " OK", str("  and the next one is spaced (got \"", session::commit, "\")"));
    session::set_english_space(false);
    check(pick(s, "ok", "OK", 0) && session::commit == "OK", "with the space off, the next English word is not spaced");
    userdb::reset();
    userdb::clock_override = 0;

    // The lookup itself, and what a key costs on top of the Chinese reading.
    var t = clock_ns();
    for i in 20000 {
        english::exact("programming");
        english::exact("zzzz");
    }
    let lookup = (clock_ns() - t) / 20000;
    check(lookup < 50000, str("an English lookup is ", lookup / 1000, " µs (gate: under 50)"));
    session::set_english(true);
    var on_ns: i64 = 0;
    var off_ns: i64 = 0;
    let sample = "woshizhongguoren";
    for round in 20 {
        press(s, session::KEY_ESCAPE);
        for c in sample {
            let t0 = clock_ns();
            typed(s, c);
            on_ns += clock_ns() - t0;
        }
    }
    session::set_english(false);
    for round in 20 {
        press(s, session::KEY_ESCAPE);
        for c in sample {
            let t0 = clock_ns();
            typed(s, c);
            off_ns += clock_ns() - t0;
        }
    }
    session::set_english(true);
    press(s, session::KEY_ESCAPE);
    let keys = 20 * sample.len;
    let added = (on_ns - off_ns) / keys;
    print("english  added ", added / 1000, " µs per key on 我是中国人, beside the lookup above");
}

fn main() {
    let argv = args();
    if argv.len != 2 {
        write_stderr("usage: typing-test IMAGES\n");
        exit(2);
    }
    check(session::open(argv[1]) == 0, "the engine opens the images");
    let s = session::new_session();

    first_is(s, "nihao", "你好", true);
    first_is(s, "zhongguo", "中国", true);
    first_is(s, "zhongguoren", "中国人", true);
    first_is(s, "shurufa", "输入法", true);
    first_is(s, "xi'an", "西安", true);
    within(s, "xian", "西安", 10);
    within(s, "zgr", "中国人", 5);
    within(s, "zho", "中", 6);
    // A half-typed syllable completes to a syllable. 万象's typo spellings
    // are dropped at preparation (docs/remove-typo-spellings.md); the guard
    // remains for spellings that are not syllables. lina is li na.
    first_is(s, "lina", "李娜", true);
    // zih is not zhi: the keys split, and 只嗯 is not a candidate.
    check(preedit_of(s, "ziheng") == "zi heng", "ziheng's preedit is zi heng");
    type_text(s, "ziheng");
    check(compare(candidate(0), "只嗯") != 0, str("ziheng's first candidate is not 只嗯 (got ", candidate(0), ")"));
    press(s, session::KEY_ESCAPE);
    check(preedit_of(s, "zih") == "zi h", "zih's preedit is zi h");
    check(preedit_of(s, "hzi") == "h zi", "hzi's preedit is h zi");
    first_is(s, "woshizhongguoren", "我是中国人", false);
    first_is(s, "jintiantianqibucuo", "今天天气不错", false);
    first_is(s, "womenyiqiqukankan", "我们一起去看看", false);
    editing(s);
    let ps = session::new_session();
    check(preedit_of(ps, "zhongguoren") == "zhong guo ren", "the preedit splits the letters by syllable: zhong guo ren");
    check(preedit_of(ps, "xi'an") == "xi'an" && preedit_of(ps, "xian") == "xian",
          "  a typed ' stays as it is, and xian (先) is one syllable");
    check(preedit_of(ps, "zgr") == "z g r" && preedit_of(ps, "woshizgr") == "wo shi z g r",
          "  abbreviations too: z g r, wo shi z g r");
    check(preedit_of(ps, "zhong7guo`k") == "zhong7 guo`k", "  tones and shape codes stay with their syllable");
    userdb::reset();
    composite(session::new_session());
    userdb::reset();
    charsets(session::new_session());
    learning(session::new_session());
    shuangpin(session::new_session());
    hot_swaps(session::new_session());
    custom_phrases(session::new_session());
    userdb::reset();
    random_keys(session::new_session());
    userdb::reset();
    long_input(session::new_session());
    userdb::reset();
    english_words(session::new_session());
    userdb::reset();
    reranking(session::new_session());
    userdb::reset();
    fuzzy_pinyin(session::new_session());
    userdb::reset();
    latency(session::new_session());
    print(soft_misses, " ranking hopes missed");
    if failures > 0 { exit(1); }
}
