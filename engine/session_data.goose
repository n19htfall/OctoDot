// The data the engine has loaded, and the host's switches over it: the
// images, the input and shape-code schemes, the lexicon sets, the grammar
// model, custom phrases (compiled in the background), fuzzy pinyin, English
// words, the reranker and the character set.
import std;
import os;
import lexicon;
import spelling;
import auxcode;
import image;
import decoder;
import decoder_sentence;
import userdb;
import sets;
import phrases;
import grammar;
import english;
import semantic;
import rerank;
import session;
import session_context;

namespace session;

// Loads the images from `directory`: 0, or what failed. The auxiliary codes
// and the grammar model are optional: without them ` is simply not
// accepted, and sentences are made without context.
fn open(directory: const u8[:]) -> i32 {
    ready = false;
    var kept: u8[>..] = [];         // the user dictionary, by text, across a reload
    if userdb::lex.entries.len > 0 || userdb::dormant.len > 0 || userdb::live_choices > 0 || userdb::live_english > 0 {
        userdb::save(kept);
    }
    userdb::reset();
    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/lexicon.img"), img) { return 1; }
        var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
        if !lexicon::load(img, stats) { return 2; }
    }
    data_dir.clear();
    data_dir.append(directory);
    sets::reset();
    sets::survey(directory);
    mount_defaults();
    list_schemes();
    if scheme.len == 0 { scheme.append("fullpinyin"); }
    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/spellings.", scheme, ".img"), img) { return 3; }
        if !spelling::load(img, lexicon::live_digest, lexicon::live.toned.len) { return 4; }
        apply_fuzzy();
    }
    userdb::scope.clear();
    userdb::scope.append(scheme);
    if aux_scheme.len == 0 { aux_scheme.append("none"); }
    if aux_scheme == "none" {
        auxcode::clear(auxcode::live);
    } else {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/aux.", aux_scheme, ".img"), img) || !auxcode::load(img) {
            auxcode::clear(auxcode::live);
        }
    }
    if use_grammar { grammar::open(directory); } else { grammar::close(); }
    {
        var img: u8[>..] = [];
        if !read_file(str(directory, "/english.img"), img) || !english::load(img) { english::clear_live(); }
    }
    if !semantic::load(str(directory, "/semantic.tsv")) { semantic::clear(); }
    rerank::open(directory);        // no model in the images: the reranker stays off
    decoder::forget_fits();
    userdb::reset();                // now bound to this lexicon's syllables
    if kept.len > 0 { userdb::restore(kept); }
    trim_memory();
    ready = true;
    return 0;
}

// ---- input schemes -------------------------------------------------------------------

// The schemes in the data directory whose images verify, as
// "id \t name \t preedit" lines (preedit: typed or syllables).
fn list_schemes() {
    scheme_list.clear();
    var names: u8[>..] = [];
    guard list_dir(data_dir, names) else { return; }
    var pos: i64 = 0;
    while pos < names.len {
        let file = lexicon::next_line(names, pos);
        let id = image::id_of(file, "spellings.");
        if id.len == 0 { continue; }
        var img: u8[>..] = [];
        var t = spelling::Table {};
        if !read_file(str(data_dir, "/", file), img) || !spelling::load_into(t, img, lexicon::live_digest,
                                                                            lexicon::live.toned.len) {
            continue;
        }
        let meta = t.meta[0];
        if meta.id != id { continue; }
        format(scheme_list, meta.id, "\t", meta.name, "\t",
               if meta.preedit == spelling::PREEDIT_SYLLABLES { "syllables" } else { "typed" }, "\n");
    }
}

// Switches the input scheme: 0, or 1 if there is no such scheme or its
// image does not verify, which leaves the current one in place.
fn set_scheme(id: const u8[:]) -> i32 {
    guard ready && spelling::is_id(id) else { return 1; }
    var img: u8[>..] = [];
    var t = spelling::Table {};
    guard read_file(str(data_dir, "/spellings.", id, ".img"), img) &&
          spelling::load_into(t, img, lexicon::live_digest, lexicon::live.toned.len) &&
          compare(t.meta[0].id, id) == 0 else { return 1; }
    spelling::load(img, lexicon::live_digest, lexicon::live.toned.len);     // verified just now
    apply_fuzzy();
    scheme.clear();
    scheme.append(id);
    userdb::scope.clear();
    userdb::scope.append(id);
    clear_composition();
    recent.clear();
    tail_clear();
    return 0;
}

// Fuzzy pinyin (docs/fuzzy-pinyin.md): the groups the user has on, by id,
// space-separated ("z_zh c_ch"); none by default. By id rather than bit, so
// a choice holds across schemes and builds.
var fuzzy_ids: u8[>..];
var fuzzy_text: u8[>..];

fn set_fuzzy(ids: const u8[:]) {
    fuzzy_ids.clear();
    if ids.len <= 256 { fuzzy_ids.append(ids); }
    apply_fuzzy();
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }
}

// The live table's bits for the groups the user has on.
fn apply_fuzzy() {
    var mask: u32 = 0;
    for i in spelling::live.groups.len {
        for raw in split(fuzzy_ids[..], ' ') {
            let id: const u8[:] = raw;
            if compare(id, spelling::live.groups[i].id) == 0 { mask = mask | ((1 << i) as u32); }
        }
    }
    spelling::fuzzy_on = mask;
}

// The live scheme's fuzzy groups, one per line: "id \t 1" if on, "id \t 0"
// if off. Lent until the next call.
fn fuzzy_groups() -> const u8[:] {
    fuzzy_text.clear();
    for i in spelling::live.groups.len {
        let on = (spelling::fuzzy_on & ((1 << i) as u32)) != 0;
        format(fuzzy_text, spelling::live.groups[i].id, "\t", if on { 1 } else { 0 }, "\n");
    }
    return fuzzy_text[..];
}

// ---- shape codes ---------------------------------------------------------------------

var aux_text: u8[>..];

// The shape-code schemes in the data directory whose images verify, as
// "id \t name" lines.
fn aux_list() -> const u8[:] {
    aux_text.clear();
    var names: u8[>..] = [];
    guard list_dir(data_dir, names) else { return aux_text; }
    var pos: i64 = 0;
    while pos < names.len {
        let file = lexicon::next_line(names, pos);
        let id = image::id_of(file, "aux.");
        if id.len == 0 { continue; }
        var img: u8[>..] = [];
        if !read_file(str(data_dir, "/", file), img) { continue; }
        let s, opened = image::open(img, image::KIND_AUX, auxcode::LAYOUT);
        if !opened || s.count != auxcode::SECTIONS { continue; }
        let meta, ok = from_bytes<auxcode::Meta[>..]>(image::section(img, s, 3));
        if !ok || meta.len != 1 || meta[0].scheme != id { continue; }
        format(aux_text, meta[0].scheme, "\t", meta[0].name, "\n");
    }
    return aux_text;
}

// Switches the shape-code scheme: 0, or 1 if there is no such scheme or its
// image does not verify (the current one stays).
fn set_aux_scheme(id: const u8[:]) -> i32 {
    guard ready && spelling::is_id(id) else { return 1; }
    if id == "none" {
        auxcode::clear(auxcode::live);
    } else {
        var img: u8[>..] = [];
        var probe = auxcode::Table {};
        guard read_file(str(data_dir, "/aux.", id, ".img"), img) && auxcode::load_into(probe, img) else { return 1; }
        auxcode::load(img);                         // verified just now
    }
    aux_scheme.clear();
    aux_scheme.append(id);
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }                 // a code typed already now means this scheme's
    return 0;
}

// ---- lexicon sets and the grammar model ---------------------------------------------

// Mounts the sets that are on unless the user turns them off.
fn mount_defaults() {
    var pos: i64 = 0;
    while pos < sets::available.len {
        let line = lexicon::next_line(sets::available, pos);
        let id, rest, ok1 = split_once(line, '\t');
        let name, state, ok2 = split_once(rest, '\t');
        if ok1 && ok2 && state == "on" { sets::mount(data_dir, id); }
    }
}

// Turns set `id` on or off: 0, or 1 if that cannot be done (no such set, its
// image does not verify, or no slot is free). The candidates change at once;
// a menu built before is rebuilt before any of its words is used.
fn use_set(id: const u8[:], on: bool) -> i32 {
    guard ready else { return 1; }
    return if on { sets::mount(data_dir, id) } else { sets::unmount(id) };
}

var sets_text: u8[>..];

fn sets_list() -> const u8[:] {
    sets_text.clear();
    sets::describe(sets_text);
    return sets_text;
}

// The grammar model, on or off at once (a mapping, no copying): -1 when the
// images have none, 0 off, 1 on.
fn grammar_state() -> i32 {
    if grammar::on { return 1; }
    return if ready && grammar::available(data_dir) { 0 } else { -1 };
}

// Where the grammar model's .gram file is when it is not beside grammar.img
// (the IME keeps it outside its signed bundle). Before open().
fn set_grammar_folder(directory: const u8[:]) {
    grammar::elsewhere.clear();
    grammar::elsewhere.append(directory);
}

// Turns the model on or off and remembers it for the next open: 0, or 1 if
// it cannot be turned on. A composition in progress is read again.
fn set_grammar(on: bool) -> i32 {
    guard ready else { return 1; }
    use_grammar = on;
    var result: i32 = 0;
    if on { result = if grammar::open(data_dir) == 0 { 0 } else { 1 }; } else { grammar::close(); }
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }
    return result;
}

// ---- custom phrases (engine/phrases.goose), compiled in the background --------------

let PHRASES_IDLE = 0;
let PHRASES_COMPILING = 1;
let PHRASES_READY = 2;
let PHRASES_FAILED = 3;

// octo_pump's result bits
let PUMP_CHANGED = 1;           // a job finished, or its result was applied
let PUMP_PENDING = 2;           // a job is running, or a result waits for the composition to end

struct Supervisor { job: u64, thread: i64 }

var jobs: u64 = 0;                      // the last job id handed out
var supervisors: Supervisor[>..];       // started, not yet reaped
var phrases_state: i64 = PHRASES_IDLE;
var phrases_done = phrases::Done { id: 0, ok: false, words: 0, shortcuts: 0, skipped: 0, first_bad: 0, why: [] };
var phrases_dir: u8[>..];               // where the compiled images go, and are mounted from
var staged = false;                     // a compiled result waits for the composition to end
var phrases_test_abort = false;         // tests: the next job's worker aborts
var phrases_text: u8[>..];

// Starts compiling the custom phrase file `source` into images in `out`; the
// result arrives through pump(). A newer job supersedes any still running.
// Returns its id, or 0 if it cannot start.
fn compile_phrases(source: const u8[:], out: const u8[:]) -> u64 {
    guard ready && source.len > 0 && source.len < 1024 && out.len > 0 && out.len < 1024 && data_dir.len < 1024 else {
        return 0;
    }
    jobs++;
    var job = phrases::Job { id: jobs, source: source, images: data_dir[..], out: out, scheme: scheme[..],
                             abort: phrases_test_abort };
    phrases_test_abort = false;
    phrases_dir.clear();
    phrases_dir.append(out);
    supervisors.push(Supervisor { job: jobs, thread: thread_spawn(phrases::supervise, job) });
    phrases_state = PHRASES_COMPILING;
    return jobs;
}

// On the main thread, often while a job is pending: takes finished jobs,
// drops any but the latest, and applies its result once no composition is in
// progress. Returns PUMP_* bits.
fn pump() -> u32 {
    var bits: u32 = 0;
    loop {
        let d, has = qpoll<phrases::Done>();
        if !has { break; }
        for i in supervisors.len {                  // its supervisor ends right after: reap it
            if supervisors[i].job == d.id {
                thread_wait(supervisors[i].thread);
                remove_at(supervisors, i);
                break;
            }
        }
        var id: u8[>..] = [];
        format(id, d.id);
        let words = str(phrases_dir, "/lexicon.custom.", id, ".img");
        let shortcuts = str(phrases_dir, "/shortcuts.custom.", id, ".img");
        if d.id != jobs || !d.ok {                  // superseded by a newer job, or failed: its files go
            delete_file(words);
            delete_file(shortcuts);
            if d.id != jobs { continue; }
        }
        phrases_done = d;
        phrases_state = if d.ok { PHRASES_READY } else { PHRASES_FAILED };
        if d.ok {                                   // the latest result, in place for mounting
            let canonical = str(phrases_dir, "/lexicon.custom.img");
            if d.words > 0 { rename_file(words, canonical); } else { delete_file(canonical); }
            rename_file(shortcuts, str(phrases_dir, "/shortcuts.custom.img"));
            staged = true;
        }
        bits = bits | PUMP_CHANGED;
    }
    if staged && !composing() {
        mount_phrases(phrases_dir);
        staged = false;
        bits = bits | PUMP_CHANGED;
    }
    // A superseded job can still be running after the newest one finished.
    // Its supervisor must be reaped before the runtime can stop safely.
    if staged || phrases_state == PHRASES_COMPILING || supervisors.len > 0 { bits = bits | PUMP_PENDING; }
    return bits;
}

// Mounts compiled phrase images from `directory`: the words as the "custom"
// set, the shortcuts as the live shortcut table. Missing images leave none.
// 0, or 1 if an image is there but does not verify.
fn mount_phrases(directory: const u8[:]) -> i32 {
    guard ready else { return 1; }
    var bad = false;
    sets::unmount("custom");
    if file_exists(str(directory, "/lexicon.custom.img")) && sets::mount(directory, "custom") != 0 { bad = true; }
    var img: u8[>..] = [];
    phrases::clear(phrases::live);
    if read_file(str(directory, "/shortcuts.custom.img"), img) && !phrases::load_into(phrases::live, img) { bad = true; }
    sets::generation++;                             // the menu's shortcuts and words changed
    return if bad { 1 } else { 0 };
}

// The phrases' state for the host: "state \t words \t shortcuts \t skipped
// \t first bad line \t why", state one of idle, compiling, ready, failed.
fn phrases_status() -> const u8[:] {
    phrases_text.clear();
    let d = phrases_done;
    let state = if phrases_state == PHRASES_COMPILING { "compiling" } else if phrases_state == PHRASES_READY { "ready" }
                else if phrases_state == PHRASES_FAILED { "failed" } else { "idle" };
    format(phrases_text, state, "\t", d.words, "\t", d.shortcuts, "\t", d.skipped, "\t", d.first_bad, "\t", d.why[..]);
    return phrases_text;
}

// ---- switches ------------------------------------------------------------------------

fn set_english(v: bool) {
    english::set_on(v);
    if input.len > 0 { rebuild(); }
}

// The full character set (every character, not only 万象's daily ones), as
// a setting: the default Control-g switches from while composing.
fn set_full_charset(v: bool) {
    decoder::full_charset = v;
    decoder::forget_fits();
    if input.len > 0 { rebuild(); }
}

fn set_rerank(v: bool) {
    rerank::set_on(v);
    if input.len > 0 { rebuild(); }
}

// What came before a composition, read for its candidates or not
// (session_context.goose). Off, nothing is forgotten: the tail is still
// kept, so turning it back on needs no new commit.
fn set_context(v: bool) {
    context_on = v;
    if !v { tail_read = false; }
    if input.len > 0 { rebuild(); }
}

// -1 if the images have no reranker, else 1 while it is on and 0 while off.
fn rerank_state() -> i32 {
    if !rerank::mapped { return -1; }
    return if rerank::on { 1 } else { 0 };
}
