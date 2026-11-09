// The images against their sources: every entry of lexicon.tsv must come
// back from the lexicon image by its toneless code, with its text and
// weight; every row of the spelling TSV from the spelling image; and
// damaged or mismatched images must be refused, never half-loaded.
//
//   images-test PREPARED IMAGES
import std;
import os;
import math;
import binary;
import dictionary;
import octo from "..";

var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    print(if ok { "ok    " } else { "FAIL  " }, what);
    if !ok { failures++; }
}

fn read(directory: const u8[:], name: const u8[:], out: u8[>..]&) {
    if !read_file(str(directory, "/", name), out) {
        write_stderr(str("images-test: cannot read ", directory, "/", name, "\n"));
        exit(2);
    }
}

fn load_lexicon(img: const u8[:]) -> bool {
    var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
    return lexicon::load(img, stats);
}

// Where element `index` of section `s` starts: after the section's ULEB
// count, at a fixed element size.
fn element_at(img: const u8[:], s: i64, index: i64, size: i64) -> i64 {
    let at, ok = binary::read_u32le(img, image::HEADER + 8 * s);
    let count, n = parse_uleb(img[at..]);
    return at + n + index * size;
}

fn every_entry_round_trips(lex: lexicon::Lexicon&, syllables: const u8[:], tsv: const u8[:]) {
    var ids = dictionary<const u8[:], i64> {};
    lexicon::toned_ids(syllables, ids);
    var missing: i64 = 0;
    var rows: i64 = 0;
    var pos: i64 = 0;
    while pos < tsv.len {
        let line = lexicon::next_line(tsv, pos);
        if line.len == 0 || line[0] == '#' { continue; }
        rows++;
        let word, rest1, ok1 = split_once(line, '\t');
        let code_text, rest2, ok2 = split_once(rest1, '\t');
        let weight_text, source, ok3 = split_once(rest2, '\t');
        let weight, ok4 = parse_flt(weight_text);
        var q = round(log2(weight + 1.0) * lexicon::WEIGHT_SCALE);
        if q > 65535.0 { q = 65535.0; }
        var code: u16[>..] = [];
        each_split(code_text, ' ') {
            let id = ids.get(it);
            if id { code.push(lex.toned[id].plain); }
        };
        let lo, hi = lexicon::exact(lex, code);
        var found = false;
        for i in lo..hi {
            var text: u8[>..] = [];
            lexicon::text(lex, i, text);
            if compare(text, word) == 0 && lex.entries[i].weight == q { found = true; break; }
        }
        if !found { missing++; }
    }
    check(missing == 0 && rows == lex.entries.len,
          str("all ", rows, " ", lex.meta[0].name, " entries come back by their code, with text and weight (", missing, " missing)"));
}

fn every_spelling_round_trips(syllables: const u8[:], tsv: const u8[:]) {
    var ids = dictionary<const u8[:], i64> {};
    lexicon::toned_ids(syllables, ids);
    var missing: i64 = 0;
    var rows: i64 = 0;
    var pos: i64 = 0;
    while pos < tsv.len {
        let line = lexicon::next_line(tsv, pos);
        if line.len == 0 || line[0] == '#' { continue; }
        rows++;
        let text, rest1, ok1 = split_once(line, '\t');
        let syllable, rest2, ok2 = split_once(rest1, '\t');
        let kind_text, rest3, ok3 = split_once(rest2, '\t');
        let credibility_text, rest4, ok4 = split_once(rest3, '\t');
        let correction, fuzzy_text, ok6 = split_once(rest4, '\t');
        let credibility, ok5 = parse_flt(credibility_text);
        let fuzzy, ok7 = parse_int(fuzzy_text);
        let id = ids.get(syllable);
        let s = spelling::find(spelling::live, text);
        var found = false;
        if id && s >= 0 && ok6 && ok7 {
            let sp = spelling::live.spellings[s];
            for r in sp.rows..sp.rows + sp.count {
                let row = spelling::live.rows[r];
                if row.toned == id && row.kind == spelling::kind_code(kind_text) &&
                   row.credibility == credibility as f32 && (row.fuzzy as i64) == fuzzy &&
                   (row.correction == 1) == (correction == "1") {
                    found = true;
                }
            }
        }
        if !found { missing++; }
    }
    check(missing == 0 && rows == spelling::live.rows.len,
          str("all ", rows, " ", spelling::live.meta[0].name, " spelling rows come back, fuzzy groups and all (",
              missing, " missing)"));
    check(spelling::live.groups.len == 10 && spelling::live.groups[0].id == "z_zh" &&
          spelling::live.groups[8].id == "en_eng",
          str(spelling::live.meta[0].name, " names its ", spelling::live.groups.len, " fuzzy groups (z_zh … in_ing)"));
}

// Each pair's sets as charsets.tsv gives them, and two anchors that do not
// go through the same parser: the table's 8,105 characters, and 中.
fn every_pair_has_its_sets(tsv: const u8[:]) {
    var sets = dictionary<u32, i64> {};
    var err: u8[>..] = [];
    check(lexicon::charsets(tsv, sets, err), "charsets.tsv parses");
    var wrong: i64 = 0;
    var table = dictionary<u32, bool> {};
    var zhong: i64 = -1;
    for p in lexicon::live.pairs.len {
        let cp = lexicon::live.pairs[p].cp;
        let f: i64 = lexicon::live.flags[p];
        if f != sets.get_or_insert(cp, 0) { wrong++; }
        if (f & lexicon::TGH) != 0 { table.insert(cp, true); }
        if cp == 0x4E2D { zhong = f; }
    }
    check(wrong == 0, str("every character reading carries its character's sets (", wrong, " wrong)"));
    check(table.count == 8105, str("the lexicon's characters in 通用规范汉字表: ", table.count, " of 8105"));
    check(zhong == (lexicon::HAN | lexicon::TGH | lexicon::GB2312 | lexicon::BIG5), "中: ideograph, table, GB2312, Big5");
}

// Every code of every scheme in aux.tsv is found in that scheme's image.
fn every_aux_code_round_trips(tsv: const u8[:], images: const u8[:]) {
    let n = auxcode::schemes(tsv);
    check(n == 9, str("aux.tsv names ", n, " schemes"));
    for column in n {
        let at = find(tsv, "\n");
        let name, ok = auxcode::field(tsv[7..at], column);
        var img: u8[>..] = [];
        read(images, str("aux.", name, ".img"), img);
        check(auxcode::load(img) && compare(auxcode::live.meta[0].scheme, name) == 0, str("aux.", name, ".img loads"));
        var codes: i64 = 0;
        var missing: i64 = 0;
        var pos = at + 1;
        while pos < tsv.len {
            let line = lexicon::next_line(tsv, pos);
            if line.len == 0 || line[0] == '#' { continue; }       // the names line
            let character, rest, ok1 = split_once(line, '\t');
            let cell, ok2 = auxcode::field(rest, column);
            var cps: u32[>..] = [];
            each_utf8(character) { cp => cps.push(cp as u32); };
            var from: i64 = 0;
            while cell.len > 0 && from <= cell.len {
                var end = find(cell[from..], " ");
                end = if end < 0 { cell.len } else { from + end };
                codes++;
                if !auxcode::fits(auxcode::live, cps[0], cell[from..end]) { missing++; }
                from = end + 1;
            }
        }
        check(missing == 0 && codes == auxcode::live.codes.len,
              str("  ", name, ": all ", codes, " codes found (", missing, " missing)"));
    }
}

// Each set's image against its source, and a set built for another
// syllabary refused, leaving nothing mounted.
fn every_set_round_trips(prepared: const u8[:], images: const u8[:], syllables: const u8[:]) {
    for id in 3 {
        let name = if id == 0 { "diming" } else if id == 1 { "mingren" } else { "yiren" };
        var tsv: u8[>..] = [];
        var img: u8[>..] = [];
        read(prepared, str("lexicon.", name, ".tsv"), tsv);
        read(images, str("lexicon.", name, ".img"), img);
        var probe = lexicon::Lexicon {};
        var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
        let ok, digest = lexicon::load_into(probe, img, stats);
        check(ok && digest == lexicon::live_digest && probe.meta[0].id == name && probe.meta[0].on,
              str("lexicon.", name, ".img loads, names itself, is on by default, and binds to the core's syllabary"));
        every_entry_round_trips(probe, syllables, tsv);
    }
    var img: u8[>..] = [];
    read(images, "lexicon.yiren.img", img);
    img[24] ^= 0x01;                                // the syllabary digest
    image::restamp(img);
    let elsewhere = str(images, "-elsewhere");      // beside the real images, in build/
    make_dir(elsewhere);
    check(write_file(str(elsewhere, "/lexicon.yiren.img"), img), "  (a copy built for another syllabary written)");
    check(sets::mount(elsewhere, "yiren") == 1 && !sets::mounted("yiren"),
          "a set built for another syllabary is refused, and nothing is mounted");
    check(sets::mount(images, "yiren") == 0 && sets::mounted("yiren") && sets::unmount("yiren") == 0,
          "  the real one mounts and unmounts");
}

fn damaged_images_are_refused(good: const u8[:], spellings: const u8[:]) {
    var bad: u8[>..] = [];
    bad.append(good);
    bad[bad.len / 2] ^= 0x5A;
    check(!load_lexicon(bad) && lexicon::live.entries.len == 0, "one flipped byte: refused by the checksum, nothing kept");

    check(!load_lexicon(good[..good.len / 2]), "a truncated image is refused");
    check(!load_lexicon(spellings), "a spelling image is refused as a lexicon");

    bad.clear();
    bad.append(good);
    bad[element_at(bad, 4, 0, 7) + 6] = 0;          // the first entry's length
    image::restamp(bad);
    check(!load_lexicon(bad), "an entry of length 0, under a valid checksum: refused by validation");

    bad.clear();
    bad.append(good);
    let run = element_at(bad, 3, 0, 2);              // the first pair id of the first word
    bad[run] = 0xFF;
    bad[run + 1] = 0xFF;
    image::restamp(bad);
    check(!load_lexicon(bad), "a pair id out of range, under a valid checksum: refused by validation");

    bad.clear();
    bad.append(good);
    let node = element_at(bad, 7, 1, 6);             // move the second index node's start
    bad[node + 2] ^= 0x01;
    image::restamp(bad);
    check(!load_lexicon(bad), "an index node moved, under a valid checksum: refused by validation");

    // Found by the fuzzer: an index whose ends are right but whose middle is
    // not monotone made the validator itself read out of bounds.
    bad.clear();
    bad.append(good);
    let first = element_at(bad, 5, 1, 4);           // first[1] = 0x00FFFFFF
    bad[first] = 0xFF;
    bad[first + 1] = 0xFF;
    bad[first + 2] = 0xFF;
    bad[first + 3] = 0x00;
    image::restamp(bad);
    check(!load_lexicon(bad), "a non-monotone first-syllable index, under a valid checksum: refused, not crashed");

    bad.clear();
    bad.append(good);
    bad[element_at(bad, 9, 0, 1)] = 0xFF;          // the first pair's sets
    image::restamp(bad);
    check(!load_lexicon(bad), "a character-set byte out of range, under a valid checksum: refused by validation");

    bad.clear();
    bad.append(good);
    let mark = element_at(bad, 10, 0, 9);           // the first mark's entry
    for i in 4 { bad[mark + i] = 0xFF; }
    image::restamp(bad);
    check(!load_lexicon(bad), "a mark for an entry that does not exist, under a valid checksum: refused by validation");

    check(load_lexicon(good) && lexicon::live.entries.len > 0, "the good image loads again afterwards");
    check(!spelling::load(spellings, lexicon::live_digest ^ 1, lexicon::live.toned.len),
          "a spelling table built for another syllabary is refused");
}

fn main() {
    let argv = args();
    if argv.len != 3 {
        write_stderr("usage: images-test PREPARED IMAGES\n");
        exit(2);
    }
    var syllables: u8[>..] = [];
    var lexicon_tsv: u8[>..] = [];
    var spellings_tsv: u8[>..] = [];
    var lexicon_img: u8[>..] = [];
    var spelling_img: u8[>..] = [];
    var charsets_tsv: u8[>..] = [];
    var aux_tsv: u8[>..] = [];
    read(argv[1], "charsets.tsv", charsets_tsv);
    read(argv[1], "aux.tsv", aux_tsv);
    read(argv[1], "syllables.tsv", syllables);
    read(argv[1], "lexicon.tsv", lexicon_tsv);
    read(argv[1], "spellings.fullpinyin.tsv", spellings_tsv);
    read(argv[2], "lexicon.img", lexicon_img);
    read(argv[2], "spellings.fullpinyin.img", spelling_img);

    check(load_lexicon(lexicon_img), "the lexicon image loads and validates");
    check(spelling::load(spelling_img, lexicon::live_digest, lexicon::live.toned.len),
          "the spelling image loads, bound to the lexicon's syllabary");
    every_entry_round_trips(lexicon::live, syllables, lexicon_tsv);
    every_set_round_trips(argv[1], argv[2], syllables);
    every_spelling_round_trips(syllables, spellings_tsv);
    {                                       // and 小鹤双拼's table
        var tsv: u8[>..] = [];
        var img: u8[>..] = [];
        read(argv[1], "spellings.flypy.tsv", tsv);
        read(argv[2], "spellings.flypy.img", img);
        check(spelling::load(img, lexicon::live_digest, lexicon::live.toned.len) && spelling::live.meta[0].id == "flypy" &&
              spelling::live.meta[0].preedit == spelling::PREEDIT_SYLLABLES, "the 小鹤双拼 image loads and names itself");
        every_spelling_round_trips(syllables, tsv);
        check(spelling::load(spelling_img, lexicon::live_digest, lexicon::live.toned.len), "back to full pinyin");
    }
    every_pair_has_its_sets(charsets_tsv);
    every_aux_code_round_trips(aux_tsv, argv[2]);
    damaged_images_are_refused(lexicon_img, spelling_img);
    the_grammar_model_answers(argv[1], argv[2]);
    every_english_word(argv[1], argv[2]);
    if file_exists(str(argv[2], "/rerank.img")) { the_reranker_scores_as_trained(argv[2]); }
    else { print("skip  no rerank.img: the images have no reranker (data/rerank.lock, make images)"); }
    if failures > 0 { exit(1); }
}

// The engine's forward pass (rerank.h) gives the scores the model gave in
// training (rerank.check.tsv, released with the weights), and the reranker
// refuses damaged data.
fn the_reranker_scores_as_trained(images: const u8[:]) {
    var img: u8[>..] = [];
    read(images, "rerank.img", img);
    check(rerank::open(images) == 0 && rerank::mapped, "rerank.img loads and validates, and rerank.weights maps");
    var check_tsv: u8[>..] = [];
    read(images, "rerank.check.tsv", check_tsv);
    var job = rerank::Job { ids: [], starts: [] };
    rerank::clear_job(job);
    var want: f64[>..] = [];
    var texts: u8[>..] = [];
    for raw in split(check_tsv, '\n') {
        let line: const u8[:] = raw;
        let text, bits_text, ok = split_once(line, '\t');
        let bits, good = parse_flt(bits_text);
        if !ok || !good { continue; }
        if rerank::count(job) == rerank::MAX_SHORTLIST || !rerank::add(job, text) { break; }
        want.push(bits);
        format(texts, if texts.len > 0 { ", " } else { "" }, text);
    }
    var bits: f64[>..] = [];
    let ok = rerank::score(job, bits);
    var worst = 0.0;
    for i in want.len {
        let d = if ok { bits[i] - want[i] } else { 1000.0 };
        if d > worst { worst = d; }
        if -d > worst { worst = -d; }
    }
    check(want.len >= 8 && ok && worst < 0.01,
          str("the forward pass scores ", want.len, " sentences as MLX did, within ", worst, " bits (", texts, ")"));
    // Damage: a truncated image, and weights of another size, are refused,
    // and leave nothing mapped.
    var model = rerank::Model {};
    check(!rerank::load_into(model, img[..img.len - 1]) && model.meta.len == 0, "a truncated rerank.img is refused");
    let elsewhere = str(images, "-rerank-elsewhere");
    make_dir(elsewhere);
    var weights: u8[>..] = [];
    weights.append("OLM1");
    for _ in 1000 { weights.push(0); }
    check(write_file_atomic(str(elsewhere, "/rerank.img"), img) &&
          write_file_atomic(str(elsewhere, "/rerank.weights"), weights) && rerank::open(elsewhere) == 3 &&
          !rerank::mapped, "rerank.weights of another size is refused, and nothing is left mapped");
    delete_file(str(elsewhere, "/rerank.img"));
    delete_file(str(elsewhere, "/rerank.weights"));
    rerank::close();
}

fn every_english_word(prepared: const u8[:], images: const u8[:]) {
    var tsv: u8[>..] = [];
    var img: u8[>..] = [];
    read(prepared, "english.tsv", tsv);
    read(images, "english.img", img);
    check(english::load(img) && english::live.entries.len > 0, "english.img loads and validates");
    var missing: i64 = 0;
    var rows: i64 = 0;
    var pos: i64 = 0;
    while pos < tsv.len {
        let line = lexicon::next_line(tsv, pos);
        if line.len == 0 || line[0] == '#' { continue; }
        rows++;
        let code, rest1, ok1 = split_once(line, '\t');
        let weight_text, rest, ok2 = split_once(rest1, '\t');
        let weight, ok3 = parse_int(weight_text);
        let i = english::exact(code);
        if !(ok1 && ok2 && ok3) || i < 0 || english::live.entries[i].weight != weight { missing++; continue; }
        let score = english::score_of(i);
        if score < log2(weight as f64) - 0.01 || score > log2(weight as f64) + 0.01 { missing++; continue; }
        var form: u8[>..] = [];
        english::top_form(i, form);
        let head, tail, ok = split_once(rest, '\t');
        let first = if ok { head } else { rest };
        if compare(form, first) != 0 || english::form_count(i) < 1 { missing++; }
    }
    check(missing == 0 && rows == english::live.entries.len,
          str("all ", rows, " English codes come back with their weight, score and first form (", missing, " missing)"));
    var truncated: u8[>..] = [];
    truncated.append(img[..32]);
    check(!english::load(truncated) && english::live.entries.len == 0, "a truncated English image is refused, and nothing is left loaded");
    check(english::load(img), "the English image loads again afterwards");
}

// The grammar model, mapped and queried in place. The values are n-grams
// octo-prep grammar-stats read out of the pinned file: 冰川萎缩 165939 and
// 我们一起 184206 (ln × 10000), and no 冰川猥琐.
fn the_grammar_model_answers(prepared: const u8[:], images: const u8[:]) {
    var tsv: u8[>..] = [];
    read(prepared, "grammar.tsv", tsv);
    var settings = grammar::Settings {};
    var err: u8[>..] = [];
    var img: u8[>..] = [];
    read(images, "grammar.img", img);
    check(grammar::compile(settings, tsv, err) && grammar::load_into(settings, img) &&
          settings.meta[0].language == "wanxiang-lts-zh-hans" && settings.meta[0].homophones == 8,
          "grammar.img loads, with 万象's settings and its model's name");
    check(grammar::open(images) == 0 && grammar::on, "the model maps");
    let none = grammar::query("", "一起", false);
    let together = grammar::query("我们", "一起", false);
    let shrink = grammar::query("冰川", "萎缩", false);
    let lewd = grammar::query("冰川", "猥琐", false);
    check(none == -6.0, str("no context: the non-collocation penalty (", none, ")"));
    check(together >= 18.4206 - 14.0 - 0.0001, str("我们 + 一起 scores at least its n-gram's 4.42 (", together, ")"));
    check(shrink >= 16.5939 - 14.0 - 0.0001 && lewd == -6.0,
          str("冰川 + 萎缩 scores ", shrink, ", 冰川 + 猥琐 ", lewd, ": the model tells the homophones apart"));
    // The model must be the file grammar.img records. A small, well-formed
    // .gram (the header and 256 empty units) under the same name: refused
    // while grammar.img records the real model's size, mapped (with nothing
    // in it) once it records its own.
    let elsewhere = str(images, "-elsewhere");
    var fake: u8[>..] = [];
    fake.append("Rime::Grammar/1.0");
    while fake.len < 36 { fake.push(0); }
    for v in [256 as u32, 4 as u32] { for i in 4 { fake.push(((v >> (8 * i)) & 0xFF) as u8); } }
    while fake.len < 44 + 256 * 4 { fake.push(0); }
    var named = settings;
    var other: u8[>..] = [];
    grammar::write(named, other);
    check(write_file(str(elsewhere, "/wanxiang-lts-zh-hans.gram"), fake) &&
          write_file(str(elsewhere, "/grammar.img"), other) && grammar::open(elsewhere) == 3 && !grammar::on,
          "a model of another size than grammar.img records is refused, and the model is off");
    named.meta[0].file_size = fake.len as u64;
    other.clear();
    grammar::write(named, other);
    check(write_file(str(elsewhere, "/grammar.img"), other) && grammar::open(elsewhere) == 0 &&
          grammar::query("我们", "一起", false) == -6.0, "  one that matches maps, and an empty one knows no n-gram");
    check(grammar::open(images) == 0 && grammar::query("我们", "一起", false) == together,
          "  and the real one maps again in its place");
    grammar::close();
}

