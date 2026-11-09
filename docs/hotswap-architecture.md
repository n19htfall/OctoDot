# Hot-swap architecture: switch anything, deploy nothing

Rime makes the user *deploy* (重新部署) after changing a scheme, a dictionary
or a setting: it recompiles prisms and tables, which takes seconds to
minutes. OctoDot has no deploy step. Whatever the user can switch is either
an image compiled ahead of time, swapped in after verification in
milliseconds, or a small text file compiled in the background into such an
image. Typing never waits on any of it, and nothing in flight is lost.

This document is the design. It also answers an external proposal
(2026-11-07), adopting what fits this engine and saying why the rest does
not.

## What can be switched, and how

| What | Data | Size | Switch cost | Mechanism | Status |
|---|---|---|---|---|---|
| Input scheme (全拼, 小鹤双拼, …) | `spellings.<id>.img` | 80–120 KB | 65–90 µs | verified load, replaces the live table | done |
| Shape-code scheme (万象, 墨奇, 自然码, …) | `aux.<id>.img` | 130–815 KB | a few ms | verified load, replaces the live table | done, in the input menu |
| Character set (daily / full) | per-reading flags in the lexicon | — | 0 | a flag the search reads | done |
| Lexicon sets (地名, 名人, 艺人) | `lexicon.<set>.img` | 0.3–1.5 MB | on 1.6 ms (地名), off 0.9 ms | mounted into a slot beside the base | done, in the input menu |
| User dictionary | its text form | grows with use | ms | restore from text | done |
| Custom phrases (the user's own list) | text → `lexicon.custom.img`, `shortcuts.custom.img` | small | background, milliseconds | compiled by a contained worker, then mounted | done |
| Base lexicon (单字, 基础, 错音, 多音) | `lexicon.img` | 23 MB | ~29 ms | changes only with an app update, which restarts the IME | build time |

## Principles

1. **Data only.** Every switch replaces verified data; there is no plugin
   code. Goose has no function pointers or dynamic dispatch beyond enum
   tags anyway.
2. **One syllabary per build.** The base, every set, every spelling table
   and every compiled phrase list is bound to the digest of the same
   syllabary (`syllables.tsv`, every toned syllable any of them uses). A
   loader refuses an image built against another syllabary, leaving the live
   data as it was.
3. **Loaders never abort, so they run on the main thread.** Every image
   loader verifies framing (`from_bytes`), a checksum, and every
   cross-reference and ordering before it accepts anything. On anything
   malformed it returns false with nothing half loaded; all five are fuzzed
   (`make fuzz`). Verification does not need a worker, and could not use
   one: a verified structure cannot cross a thread boundary (only flat
   values can), so the main thread would have to rebuild it anyway.
4. **Containment is for compiling untrusted text.** Turning a text file into
   an image is more code, run less often, and not proven abort-free. It runs
   in a `thread_spawn_contained` worker, which may only write an image file.
   The main thread then loads that file through the same verified loader.
5. **Nothing changes under a composition.** Data that changes what the keys
   mean (a scheme) commits the composition first, as typed. Data that only
   changes the candidates (a set, the user dictionary) bumps a generation
   counter, and the menu is rebuilt before any of its words is used. Picks
   already made keep a copy of what they chose. Images compiled in the
   background wait, staged, until no composition is in progress.
6. **The user dictionary never stores ids.** It is saved by text and toned
   pinyin, and resolved against whatever lexicon is live when it loads. No
   pair id or syllable id ever reaches the disk.

## Engine data model

Goose's constraint: a `root struct` (one with independently growable
fields, like `lexicon::Lexicon`) can only be a local or a global, never an
array element or a field. So the lexicons the search walks live in **fixed
global slots**, and code reaches them by number:

```
source 0       lexicon::live     the base, always mounted
source 1       userdb::lex       the user dictionary, in memory
source 2 + k   sets::slot_k      k < sets::SLOTS (6): a mounted set
```

```goose
// engine/sets.goose
let SLOTS = 6;
var slot_0 = lexicon::Lexicon {};  … var slot_5 = lexicon::Lexicon {};
struct Mounted { id: u8[..15], name: u8[..31], on_by_default: bool }
var mounted: Mounted[..6];          // mounted[k] describes slot_k; id empty if free

fn slot(k: i64) -> lexicon::Lexicon&    // an if-chain over the six globals
fn mount(id: const u8[:]) -> i32        // verified load into a free slot; nothing else changes on failure
fn unmount(id: const u8[:]) -> i32      // clears the slot, then trim_memory() returns its pages
```

- **Mounting** loads `lexicon.<id>.img` into a free slot with the same
  verified loader as the base, and checks the image names itself `<id>` and
  binds to the live syllabary. Only then does the slot count as mounted.
  A failure leaves the slot empty and everything else untouched: there is
  nothing to roll back, because nothing live was touched.
- **Unmounting** clears the slot's arrays and calls `trim_memory()`, so the
  pages go back to macOS at once.
- **Every change bumps `sets::generation`.** The session's menu remembers
  the generation it was built at (with the user dictionary's), and is rebuilt
  before use if either moved.
- **The search** walks the base, then the user dictionary, then each mounted
  set, from every position (`decoder::search`). Words carry their source.
  Text, the readings learned from a pick, and the syllable split of the
  preedit all go through `decoder::source_lexicon(source)`.
- **Scores stay comparable.** A word scores log2 of its weight over the
  total weight of everything mounted, so with every set mounted, ranking is
  what the single merged image gave.
- **Each word lives in one place.** octo-prep gives a (text, reading) pair to
  the core if any core dictionary has it, taking the highest weight across
  all files. Otherwise it goes to each set that has it. Turning a set off
  removes only words found nowhere else.

## Custom phrases: background compilation (done)

The user's own list is a text file in the IME's container
(`custom_phrases.txt`, opened from the input menu). Its format is 万象's and
Rime's `custom_phrase.txt`, one entry per line: `text <Tab> code [<Tab>
weight]`.

- **Fields are separated by a tab, as in Rime, or by spaces.** With
  spaces, the text runs to the first space, a final number is the weight,
  and the code lies between. A full-width space counts. Without this, a
  line typed with spaces was silently skipped; that was the first thing a
  real user hit.
- **A code in pinyin makes a word** (`雾凇奇观	wu song qi guan`; also
  without spaces, segmented to one syllable per character, or with tone
  marks, or in the keys of the scheme in use: `wussqigr` in 小鹤双拼). A
  code is read as full pinyin first, then in the scheme's keys. Words are stored by syllable, so they join sentences and
  abbreviations in every scheme: `wussqigr` in 小鹤 finds the same word. A
  character's reading comes from the core lexicon (the word's own if the core
  has it, else the character's most frequent reading for that syllable), so
  多音字 read right. A word without a weight gets twice the weight of the
  core's best word for the same syllables, so it comes first for them.
- **Any other code, letters a-z only, is a shortcut** (`我的邮箱	yx`),
  offered before everything else when exactly those keys are typed, in any
  scheme.
- **A line that is neither is skipped.** The status counts skipped lines and
  names the first one with its reason, shown in the input menu.

How it runs without blocking typing (`engine/phrases.goose`, spike 02's
pattern):

```
main   compile_phrases(source, out) → job id (the previous id plus one)
         spawns a supervisor thread with a flat Job { id, source, images, out }
super    spawns the compiler as a contained worker, and blocks in thread_wait
worker   reads the source (at most 4 MB, 100k lines) and the core (lexicon.img
         with syllables.tsv, verified); compiles the words through the same
         lexicon compiler octo-compile uses; writes lexicon.custom.<id>.img and
         shortcuts.custom.<id>.img atomically; qput(Done { id, counts, why })
super    if the worker aborted (it sent nothing): qput(Done { id, failed, why })
main   pump(), polled by the host while a job is pending:
         reaps the supervisor; drops a Done that is not the latest job's (and
         deletes its files); renames the latest result into place; mounts it
         at once if nothing is being composed, else stages it until then
```

- Files are named by job, so a superseded job finishing late overwrites
  nothing.
- A worker that aborts ends alone. The status carries only the failed
  check and its source line, never user text, and the phrases in use stay.
- The host polls on a 50 ms timer only while a job is pending, instead of a
  run-loop source and a C shim. That keeps every engine test free of extra C,
  and the ABI flat.
- **A save takes effect by itself,** a quarter second later. The host
  watches the file's folder, which an editor that saves by renaming a new
  copy over the file changes, and the file itself, which one that writes in
  place changes; the file watch re-arms after a replacement. Waiting for
  the next activation instead, as the first version did, felt broken.
- At launch, the last result goes into use at once, and the file compiles
  again in the background, so a result from an older build never lingers.

## The four questions of the external proposal

1. **Replacing global images without leaks or a half state.** The slot idiom
   above. A failed load never touches live data: spelling tables and aux
   tables are verified into a local table before replacing the live one,
   and sets load into a free slot. A retired image's arrays are cleared,
   then `trim_memory()` returns the pages, which it does on macOS through a
   MAP_FIXED remap.
2. **A pause of 5 ms or less when the base lexicon is swapped.** Not
   needed: the base changes only with an app update, and installing one
   restarts the IME. If a runtime base swap is ever wanted, the measured
   29 ms (read 3 ms, checksum 2 ms, `from_bytes` 3 ms, validation 18 ms)
   would run in the idle window after a commit. A worker could validate
   first and pass a content hash, letting the main thread skip validation
   and spend about 9 ms instead.
3. **Pair ids across lexicon versions.** Nothing persisted holds a pair id.
   The user dictionary is saved as text and toned pinyin, choices as text
   and typed keys. Both resolve against the live lexicon whenever it loads,
   including after a relock. Lines naming syllables a newer lexicon lacks are
   kept as they are, dormant, for the next save.
4. **The ABI.** Plain scalars and byte slices, since generated struct names
   are unstable (ABI v5):

   ```c
   sl_u8    octo_sets(void);                    // "id \t name \t on|off (default) \t mounted|off" per line
   int32_t  octo_mount(sl_u8 id, uint32_t on);   // 0, or 1: not found, does not verify, or no free slot
   sl_u8    octo_aux_schemes(void);              // "id \t name" per line
   int32_t  octo_set_aux_scheme(sl_u8 id);       // 0, or 1
   // ABI v6, custom phrases:
   uint64_t octo_compile_phrases(sl_u8 source, sl_u8 out);   // job id, or 0
   uint32_t octo_pump(void);                    // 1 changed | 2 still pending
   sl_u8    octo_phrases_status(void);          // "state \t words \t shortcuts \t skipped \t line \t why"
   int32_t  octo_mount_phrases(sl_u8 directory); // compiled before: into use without compiling
   ```

## Not adopted from the external proposal

- **A 16-bit "glyph meta" sidecar holding the shape code.** Shape codes
  belong to characters, not readings. Many characters have several codes
  (about 3% of cells), and a code is not always 2 letters. The per-scheme
  aux images keyed by code point already switch in milliseconds. Character
  sets are already a flag byte per reading.
- **Syllable id 0 as an epsilon for `李·卡斯利`.** It would make every index
  key skip it on the hot path. Marks live in a side table that only text
  rendering reads.
- **Sets sharing the base's pair table.** A set would then have to be
  rebuilt whenever the base changes. A set carries its own readings and
  binds only to the syllabary.
- **Validating images inside workers as a rule.** See principle 3.
- **A five-state machine (live, building, staged, rollback, safe mode).**
  The slots and generation counter give the same guarantees with less
  state: nothing live is touched until verified, so there is nothing to roll
  back. Background compiles have a staged image. If no image opens at all,
  every key passes through to the app; that is the safe mode M0 already
  built.
- **Twenty base-lexicon swaps under an RSS watermark.** There are no runtime
  base swaps. Repeated mounting and unmounting of sets is tested instead.

## Gates

| Gate | Test | Result |
|---|---|---|
| Switching schemes takes under 1 ms, and learned words apply at once | typing test: `set_scheme` timed both ways; a word learned in full pinyin comes first in 小鹤 | 64 µs to 小鹤, 88 µs back; 实时 first for `uiui` |
| A set switches at once, and the menu never uses stale words | typing test: 地名 turned off while `lianxiqu` is composed; the pick at 濂溪区's place comes from the rebuilt menu | 濂溪区 gone and back; no stale word read |
| An image built for another syllabary is refused, and the live one kept | images test: a set and a spelling table with their digest changed | both refused; the real ones load |
| Mounting and unmounting do not leak | bench: 20 more rounds of all three sets, physical footprint measured | +0.0 MiB; all three mount in 2.2 ms |
| Switching in the middle of typing never breaks the session | keystroke fuzzer: control bytes toggle 地名 and the shape-code scheme between keys | clean (see `make fuzz`) |
| A compile that aborts ends alone, and old jobs never win | typing test: a worker made to abort; two jobs started back to back | the job fails with only `assert failed (phrases.goose:401)`, phrases in use stay; the newer job's list is the one in use |
| A result waits while a composition is in progress | typing test: a list compiled while `wusong` is composed | staged, the old list in use; the new one after the composition ends |
| Compiling never aborts on any text | fuzz target `phrases`: compile any bytes against the real core; the images it makes must load and verify | clean |
| It works inside the sandbox | self-test inside the signed bundle: a list compiled by a contained worker, and all three sets mounted | both pass |
| Saving takes effect by itself | self-test inside the sandbox, on a scratch list: created, written in place, replaced by rename, written again | all four apply within moments |

## What it cost, and what paid for it

Three more lexicons to search from every position first cost 60–70% per key
(p50 424 → 718 µs). The fix speeds up every lexicon. Each image already had
a two-level index (first syllable → its words; second syllable → a node),
used only by exact lookups. Word search now uses it too, for the first two
syllables, instead of binary searches over the entries, where every probe
was four dependent loads.

| | Before | After |
|---|---|---|
| Core only | p50 424 µs, p99 1.28 ms | p50 197 µs, p99 0.75 ms |
| Core and all three sets | p50 718 µs, p99 2.01 ms | p50 291 µs, p99 1.08 ms |

With every set mounted, typing is faster than the core alone was before.
The indexed path visits the same groups in the same order, so the search's
results are unchanged.

Ranking with the sets (`make eval`), measured on a sample redrawn because
the sets' words left the core:

| | Words first | Phrases first | Words by frequency | After learning, other half |
|---|---|---|---|---|
| 全拼, one merged lexicon | 99.8% | 97.0% | 99.9% | 98.3% |
| 全拼, core + 3 sets | 99.8% | 96.7% | 99.9% | 98.9% |
| 小鹤双拼, core + 3 sets | 100.0% | 97.3% | 100.0% | 99.5% |

Single words miss the same 6 as before. The phrase sample changed with the
words it is drawn from, and the difference is within its sampling error of
about ±0.45 points.
