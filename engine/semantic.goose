// Chinese senses of an English word, for the grammar only. The text the user
// sees stays the English word. A missing table leaves the feature off.
import std;
import os;
import math;

namespace semantic;

let TOP = 4;

struct Row { code_at: u32, code_len: u8, sense_at: u32, count: u8 }
struct Sense { text_at: u32, text_len: u16, weight: u32 }

var live = false;
var code_pool: u8[>..] = [];
var rows: Row[>..] = [];
var senses: Sense[>..] = [];
var text_pool: u8[>..] = [];

fn clear() {
    live = false;
    code_pool.clear();
    rows.clear();
    senses.clear();
    text_pool.clear();
}

fn active() -> bool { live }

// A lexicon weight fits in u32. Ten digits cannot overflow i64; anything
// longer, or above 2^32-1, is refused rather than wrapped or truncated.
fn parse_weight(text: const u8[:]) -> i64, bool {
    guard text.len > 0 && text.len <= 10 else { return 0, false; }
    var n: i64 = 0;
    for c in text {
        if c < '0' || c > '9' { return 0, false; }
        n = n * 10 + (c - '0');
    }
    guard n > 0 && n <= 4294967295 else { return 0, false; }
    return n, true;
}

fn load(path: const u8[:]) -> bool {
    clear();
    var data: u8[>..] = [];
    guard read_file(path, data) else { return false; }
    for raw in split(data, '\n') {
        if raw.len == 0 || raw[0] == '#' { continue; }
        var parts: i64[>..] = [];
        var at: i64 = 0;
        while at <= raw.len {
            let rel = find(raw[at..], "\t");
            if rel < 0 {
                parts.push(at);
                parts.push(raw.len);
                break;
            }
            parts.push(at);
            parts.push(at + rel);
            at += rel + 1;
        }
        // Each field is a start/end pair. After the code, senses come in
        // surface/weight pairs, so the remaining offsets come in fours.
        guard parts.len >= 6 && (parts.len - 2) % 4 == 0 else { continue; }
        let code = raw[parts[0]..parts[1]];
        guard code.len > 0 && code.len <= 32 else { continue; }
        var count: i64 = 0;
        let sense_at = senses.len;
        var i = 2;
        while i + 1 < parts.len && count < TOP {
            let surface = raw[parts[i]..parts[i + 1]];
            let weight, ok = parse_weight(raw[parts[i + 2]..parts[i + 3]]);
            i += 4;
            if !ok || surface.len == 0 || surface.len > 24 || weight <= 0 { continue; }
            senses.push(Sense { text_at: text_pool.len as u32, text_len: surface.len as u16, weight: weight as u32 });
            text_pool.append(surface);
            count++;
        }
        guard count > 0 else { continue; }
        rows.push(Row { code_at: code_pool.len as u32, code_len: code.len as u8, sense_at: sense_at as u32,
                        count: count as u8 });
        code_pool.append(code);
    }
    guard rows.len > 0 && ordered() else { clear(); return false; }
    live = true;
    return true;
}

// Binary search and prior() both assume this. Keys increase strictly, so a
// duplicate or a regression cannot hide. Each word's senses are heaviest first.
fn ordered() -> bool {
    for i in 1..rows.len {
        let prev = rows[i - 1];
        let cur = rows[i];
        let before = code_pool[prev.code_at..prev.code_at + prev.code_len];
        let after = code_pool[cur.code_at..cur.code_at + cur.code_len];
        if compare(after, before) <= 0 { return false; }
    }
    for row in rows {
        var heaviest: u32 = 4294967295;
        for k in row.count {
            let w = senses[row.sense_at + k].weight;
            if w > heaviest { return false; }
            heaviest = w;
        }
    }
    return true;
}

// The row holding `code`'s senses, or -1 for a word the table does not have:
// what count, sense and prior take.
fn find_row(code: const u8[:]) -> i64 {
    guard live && code.len > 0 else { return -1; }
    var a: i64 = 0;
    var b = rows.len;
    while a < b {
        let m = a + (b - a) / 2;
        let row = rows[m];
        let cmp = compare(code_pool[row.code_at..row.code_at + row.code_len], code);
        if cmp < 0 { a = m + 1; }
        else if cmp > 0 { b = m; }
        else { return m; }
    }
    return -1;
}

fn count(row: i64) -> i64 { if row < 0 { 0 } else { rows[row].count } }

// Sense i of a row, heaviest first.
fn sense(row: i64, i: i64) -> const u8[:] {
    let s = senses[rows[row].sense_at + i];
    return text_pool[s.text_at..s.text_at + s.text_len];
}

// log2 of sense i's weight over the row's heaviest, which ordered() has
// checked comes first: 0 for the top sense, less for the others.
fn prior(row: i64, i: i64) -> f64 {
    let best = senses[rows[row].sense_at].weight;
    let mine = senses[rows[row].sense_at + i].weight;
    return log2(mine as f64) - log2(best as f64);
}
