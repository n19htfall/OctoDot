// octo-compile: octo-prep's normalized sources → OctoDot's images.
//
//   octo-compile PREPARED OUT [--limit N] [--rerank DIR]
//
// PREPARED holds octo-prep's syllables.tsv, charsets.tsv, lexicon.tsv (the
// core) and lexicon.<set>.tsv (each switchable set), spellings.<scheme>.tsv
// and aux.tsv; OUT receives lexicon.img, spellings.<scheme>.img, schemes.tsv,
// and aux.<scheme>.img for each auxiliary-code
// scheme, and grammar.img when octo-prep prepared grammar.tsv (the model's
// .gram file goes beside it; the Makefile links it there). With --limit, only the first N entries and
// spellings, characters with auxiliary codes and English words are kept:
// small images, as fuzzing seeds. With --rerank, DIR's rerank.tsv (one of
// the released model's files, data/rerank.lock) becomes rerank.img; its rerank.weights goes beside
// it, as the Makefile links it.
import std;
import os;
import octo from "../../engine";

fn read(directory: const u8[:], name: const u8[:], out: u8[>..]&) {
    if !read_file(str(directory, "/", name), out) {
        write_stderr(str("octo-compile: cannot read ", directory, "/", name, "\n"));
        exit(1);
    }
}

fn store(directory: const u8[:], name: const u8[:], data: const u8[:]) {
    if !write_file_atomic(str(directory, "/", name), data) {
        write_stderr(str("octo-compile: cannot write ", directory, "/", name, "\n"));
        exit(1);
    }
}

fn main() {
    let argv = args();
    var limit: i64 = 0;
    var rerank_dir: u8[>..] = [];
    var usable = argv.len >= 3 && argv.len % 2 == 1;
    var a: i64 = 3;
    while usable && a + 1 < argv.len {
        if argv[a] == "--limit" {
            let n, ok = parse_int(argv[a + 1]);
            usable = ok && n > 0;
            limit = n;
        } else if argv[a] == "--rerank" {
            rerank_dir.append(argv[a + 1]);
        } else {
            usable = false;
        }
        a += 2;
    }
    if !usable {
        write_stderr("usage: octo-compile PREPARED OUT [--limit N] [--rerank DIR]\n");
        exit(2);
    }
    let prepared = argv[1];
    let output = argv[2];
    let started = clock_ns();

    var syllables: u8[>..] = [];
    read(prepared, "syllables.tsv", syllables);
    make_dir(output);
    store(output, "syllables.tsv", syllables);      // custom phrases compile against it at run time
    var err: u8[>..] = [];
    var names: u8[>..] = [];
    if !list_dir(prepared, names) {
        write_stderr(str("octo-compile: cannot list ", prepared, "\n"));
        exit(1);
    }
    // The core (lexicon.tsv → lexicon.img) and every set (lexicon.<id>.tsv →
    // lexicon.<id>.img), all bound to the same syllabary.
    {
        var charsets: u8[>..] = [];
        read(prepared, "charsets.tsv", charsets);
        var pos: i64 = 0;
        while pos < names.len {
            let file = lexicon::next_line(names, pos);
            if file.len < 11 || compare(file[..7], "lexicon") != 0 || compare(file[file.len - 4..], ".tsv") != 0 {
                continue;
            }
            let core = file == "lexicon.tsv";
            if !core && (file[7] != '.' || file.len <= 12) { continue; }
            var tsv: u8[>..] = [];
            read(prepared, file, tsv);
            var lex = lexicon::Lexicon {};
            err.clear();
            let digest, ok = lexicon::compile(lex, syllables, tsv, charsets, limit, err);
            if !ok {
                write_stderr(str("octo-compile: ", file, ": ", err));
                exit(1);
            }
            let id = lex.meta[0].id;
            if (core && id != "core") || (!core && compare(file[8..file.len - 4], id) != 0) {
                write_stderr(str("octo-compile: ", file, " names lexicon ", id, "\n"));
                exit(1);
            }
            var img: u8[>..] = [];
            lexicon::write(lex, digest, img);
            let image = if core { str("lexicon.img") } else { str("lexicon.", id, ".img") };
            store(output, image, img);
            print(image, " (", lex.meta[0].name, "): ", lex.entries.len, " entries, ", lex.pairs.len,
                  " character readings, ", lex.nodes.len, " index nodes, ", lex.marks.len, " marks, ", img.len, " bytes");
        }
    }
    // Every scheme octo-prep prepared: spellings.<id>.tsv → spellings.<id>.img.
    var schemes: u8[>..] = [];
    var pos: i64 = 0;
    while pos < names.len {
        let file = lexicon::next_line(names, pos);
        if file.len <= 14 || compare(file[..10], "spellings.") != 0 || compare(file[file.len - 4..], ".tsv") != 0 {
            continue;
        }
        var tsv: u8[>..] = [];
        read(prepared, file, tsv);
        var table = spelling::Table {};
        err.clear();
        let digest, ok = spelling::compile(table, syllables, tsv, limit, err);
        if !ok {
            write_stderr(str("octo-compile: ", file, ": ", err));
            exit(1);
        }
        if compare(file[10..file.len - 4], table.meta[0].id) != 0 {
            write_stderr(str("octo-compile: ", file, " names scheme ", table.meta[0].id, "\n"));
            exit(1);
        }
        var img: u8[>..] = [];
        spelling::write(table, digest, img);
        let image = str("spellings.", table.meta[0].id, ".img");
        store(output, image, img);
        print(image, " (", table.meta[0].name, "): ", table.spellings.len, " spellings, ", table.rows.len, " rows, ",
              img.len, " bytes");
        format(schemes, table.meta[0].id, "\t", table.meta[0].name, "\n");
    }
    if schemes.len == 0 {
        write_stderr("octo-compile: no spellings.<scheme>.tsv to compile\n");
        exit(1);
    }
    store(output, "schemes.tsv", schemes);
    {
        var tsv: u8[>..] = [];
        read(prepared, "aux.tsv", tsv);
        let n = auxcode::schemes(tsv);
        if n == 0 {
            write_stderr("octo-compile: aux.tsv has no header naming its schemes\n");
            exit(1);
        }
        var line: u8[>..] = [];
        for column in n {
            var table = auxcode::Table {};
            if !auxcode::compile(table, tsv, column, limit, err) {
                write_stderr(str("octo-compile: ", err));
                exit(1);
            }
            var img: u8[>..] = [];
            auxcode::write(table, img);
            let name = str("aux.", table.meta[0].scheme, ".img");
            store(output, name, img);
            format(line, if column == 0 { "" } else { ", " }, table.meta[0].scheme, " ", table.chars.len);
        }
        print("aux.<scheme>.img: characters with codes: ", line);
    }
    if file_exists(str(prepared, "/grammar.tsv")) {
        var tsv: u8[>..] = [];
        read(prepared, "grammar.tsv", tsv);
        var settings = grammar::Settings {};
        if !grammar::compile(settings, tsv, err) {
            write_stderr(str("octo-compile: ", err, "\n"));
            exit(1);
        }
        var img: u8[>..] = [];
        grammar::write(settings, img);
        store(output, "grammar.img", img);
        let m = settings.meta[0];
        print("grammar.img: ", m.language, ".gram, ", m.file_size, " bytes, ", m.homophones, " homophones per span");
    }
    {
        var tsv: u8[>..] = [];
        read(prepared, "english.tsv", tsv);
        var dict = english::Dict {};
        err.clear();
        if !english::compile(dict, tsv, limit, err) {
            write_stderr(str("octo-compile: ", err));
            exit(1);
        }
        var img: u8[>..] = [];
        english::write(dict, img);
        store(output, "english.img", img);
        print("english.img: ", dict.entries.len, " codes, ", dict.forms.len, " forms, ", img.len, " bytes");
    }
    if rerank_dir.len > 0 {
        var tsv: u8[>..] = [];
        read(rerank_dir, "rerank.tsv", tsv);
        var model = rerank::Model {};
        err.clear();
        if !rerank::compile(model, tsv, err) {
            write_stderr(str("octo-compile: ", err, "\n"));
            exit(1);
        }
        var img: u8[>..] = [];
        rerank::write(model, img);
        store(output, "rerank.img", img);
        let m = model.meta[0];
        print("rerank.img: ", m.layers, " layers of ", m.dims, ", ", m.vocab, " characters, rerank.weights ",
              m.file_size, " bytes; weight ", m.weight, " over the ", m.shortlist, " best of ", m.per_state,
              " per state, beam ", m.beam);
    }
    print("done in ", (clock_ns() - started) / 1000000, " ms");
}
