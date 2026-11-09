// Lexicon sets: dictionaries beside the core that the user switches on and
// off at once (地名, 名人, 艺人), with no rebuild. Each is its own image
// (lexicon.<id>.img), bound to the core's syllabary, mounted into a slot.
//
// A root struct cannot be an array element, so the slots are fixed globals
// reached by number (slot(k)). Mounting verifies the image into a free slot
// first; until it passes, nothing the search uses has changed, so a failure
// needs no rollback. Unmounting clears the slot and returns its pages to the
// system. Every change bumps `generation`, so a menu built before it is
// rebuilt before any of its words is used.
//
// See docs/hotswap-architecture.md.
import std;
import os;
import math;
import lexicon;

namespace sets;

let SLOTS = 6;

var slot_0 = lexicon::Lexicon {};
var slot_1 = lexicon::Lexicon {};
var slot_2 = lexicon::Lexicon {};
var slot_3 = lexicon::Lexicon {};
var slot_4 = lexicon::Lexicon {};
var slot_5 = lexicon::Lexicon {};

var used: bool[6] = [false; 6];
var generation: u64 = 1;
var log_total = 0.0;                // log2 of the weight of everything mounted, with the core
var available: u8[>..] = [];        // "id \t name \t on|off" per set found in the data directory

fn slot(k: i64) -> lexicon::Lexicon& {
    if k == 0 { slot_0 } else if k == 1 { slot_1 } else if k == 2 { slot_2 }
    else if k == 3 { slot_3 } else if k == 4 { slot_4 } else { slot_5 }
}

// The slot holding set `id`, or -1.
fn find(id: const u8[:]) -> i64 {
    for k in SLOTS { if used[k] && compare(slot(k).meta[0].id, id) == 0 { return k; } }
    return -1;
}

fn mounted(id: const u8[:]) -> bool { find(id) >= 0 }

// Weights are on one scale across the core and the sets: a word scores
// against everything mounted, so with every set on, ranking is what one
// merged lexicon gives.
fn retotal() {
    var total = 0.0;
    if lexicon::live.meta.len == 1 { total = lexicon::live.meta[0].total_weight; }
    for k in SLOTS { if used[k] { total += slot(k).meta[0].total_weight; } }
    log_total = log2(total + 1.0);
}

// Forgets every set (when the core is loaded again).
fn reset() {
    for k in SLOTS {
        lexicon::clear(slot(k));
        used[k] = false;
    }
    available.clear();
    retotal();
    generation++;
}

// The sets in `directory` whose images verify against the live core, as
// "id \t name \t on|off" lines.
fn survey(directory: const u8[:]) {
    available.clear();
    var names: u8[>..] = [];
    guard list_dir(directory, names) else { return; }
    var pos: i64 = 0;
    while pos < names.len {
        let file = lexicon::next_line(names, pos);
        if file.len <= 12 || compare(file[..8], "lexicon.") != 0 || compare(file[file.len - 4..], ".img") != 0 {
            continue;
        }
        var img: u8[>..] = [];
        var probe = lexicon::Lexicon {};
        var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
        if !read_file(str(directory, "/", file), img) { continue; }
        let ok, digest = lexicon::load_into(probe, img, stats);
        if !ok || digest != lexicon::live_digest || compare(file[8..file.len - 4], probe.meta[0].id) != 0 { continue; }
        format(available, probe.meta[0].id, "\t", probe.meta[0].name, "\t", if probe.meta[0].on { "on" } else { "off" }, "\n");
    }
}

// Mounts set `id` from `directory`: 0, or 1 if there is no such image, it
// does not verify against the live core, or every slot is taken. Nothing
// changes on failure.
fn mount(directory: const u8[:], id: const u8[:]) -> i32 {
    guard lexicon::is_id(id) && id != "core" else { return 1; }
    if find(id) >= 0 { return 0; }
    var k: i64 = -1;
    for i in SLOTS { if !used[i] { k = i; break; } }
    guard k >= 0 else { return 1; }
    var img: u8[>..] = [];
    guard read_file(str(directory, "/lexicon.", id, ".img"), img) else { return 1; }
    var stats = lexicon::LoadStats { check_ns: 0, verify_ns: 0, validate_ns: 0 };
    let ok, digest = lexicon::load_into(slot(k), img, stats);
    if !ok || digest != lexicon::live_digest || compare(slot(k).meta[0].id, id) != 0 {
        lexicon::clear(slot(k));
        return 1;
    }
    used[k] = true;
    retotal();
    generation++;
    return 0;
}

// Unmounts set `id`: 0, or 1 if it is not mounted.
fn unmount(id: const u8[:]) -> i32 {
    let k = find(id);
    guard k >= 0 else { return 1; }
    lexicon::clear(slot(k));
    used[k] = false;
    retotal();
    generation++;
    trim_memory();
    return 0;
}

// The sets as the host lists them: "id \t name \t on|off \t mounted|off" lines.
fn describe(out: u8[>..]&) {
    var pos: i64 = 0;
    while pos < available.len {
        let line = lexicon::next_line(available, pos);
        let id, rest, ok = split_once(line, '\t');
        if !ok { continue; }
        format(out, line, "\t", if mounted(id) { "mounted" } else { "off" }, "\n");
    }
}
