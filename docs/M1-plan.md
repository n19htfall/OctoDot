# M1 plan: a daily-drivable OctoDot on the 万象 lexicon

Status: draft, 2026-11-07. Builds on the M0 findings in
[`spikes/README.md`](../spikes/README.md).

## Goal

M1 turns the M0 prototypes into an input method you can type with all day:
full pinyin with sentence input over the 万象拼音 (rime-wanxiang) lexicon,
a real candidate window, a user dictionary that learns and is stored
encrypted, and the blueprint's privacy controls. OctoDot has one user for
now, so M1 is built and signed locally; public distribution comes in M3,
together with Traditional-character output.

### Progress

| Task | State |
|---|---|
| A1. Pin and fetch 万象; `NOTICE` | Done. `data/wanxiang.lock` pins v18.1.9 (commit `880ac18d`) and ten files by SHA-256; `tools/fetch-wanxiang.sh` verifies them; `make relock` moves the pin and shows the diff |
| A2. `octo-prep` | Done. `make` writes `build/data/wanxiang/` in about 6 s, byte-for-byte deterministic; 31 tests, including golden spellings from 万象's own rules |
| A3. Image formats, `octo-compile`, verified loaders | Done. Every gate met; `make test` round-trips every entry, `make bench` checks the gates, `make fuzz` fuzzes both loaders |
| Typeable slice: thin B1–B3, B5, C1–C3 | Done. Full pinyin on the whole lexicon, in an installable IME (`make install`); see below |
| Ranking evaluation | Done. `make eval` judges ranking with the lexicon itself; it drove the defaults below |
| Composite input: tone keys and shape codes | Done; see below |
| Composite input: character sets | Done; see below |
| Composite input: words with symbols (`李·卡斯利`) | Done; see below. Every row of the lexicon is now kept |
| User learning, encrypted store, privacy policy (B4, C4, C5) | Done; see below. Signing with your Apple Development identity is still to choose |
| Candidate window (C3): Liquid Glass, syllable-split preedit, clicks | Horizontal layout done; see below. A vertical layout is still to do |
| Input schemes: 小鹤双拼 beside full pinyin, switched live | Done; see below. (Brought forward from M2: it is how you type.) |
| Robustness and speed gates | Typing path and user-dictionary parser fuzzed, one bug found and fixed; latency gates met; see below |
| Hot swap: lexicon sets and shape codes switched live, no rebuild | Done; design and results in [`hotswap-architecture.md`](hotswap-architecture.md) |
| Custom phrases: words and shortcuts from a text file, compiled in the background | Done; see the same document |
| Hardening: memory, abnormal exits, the privacy check, CI, an hour of fuzzing per target | Done; see "Hardening" below |
| Accuracy set from outside sources: 900 words, 3,512 sentences of Zhihu text | Done. 99.5% of common words and idioms first in both schemes (gate 95%). Tracked: names, places, and sentences, where the grammar model is measured. See "The accuracy set" below |
| M2, brought forward: 万象's grammar model, mapped in place, librime's sentence search | Done; Zhihu sentences 49.2% → 61.7% whole (librime with the same model: 60.0%). See [`M2-grammar.md`](M2-grammar.md) |

What A2 found in the v18.1.9 data:
- **Entries:** 1,675,011 kept from 1,675,786 rows, with 774 exact duplicates merged.
- **Dropped:** one row, `李·卡斯利`, whose middle dot has no syllable. The
  pair encoding needs one syllable per character, so characters that have
  no syllable need handling before extension dictionaries arrive.
- **Kept with a note:** 18 rows without a weight and 15 malformed weights
  (`45N`), read as librime reads them.
- **Full-pinyin spellings:** 63 rules give 2,380 distinct spellings in
  8,420 rows (4,851 normal, 3,569 abbreviations). The engine's spelling
  table is tiny.
- **Exceptions to self-spelling:** every syllable is spelled by its own
  letters except ng, n and m, which 万象 spells eng, en and me.
- **Release churn:** v18.1.8 to v18.1.9 changes 1,367 lexicon lines (768
  added, 599 removed), so bumps stay reviewed.

What A3 built and measured (`engine/`, `tools/octo-compile/`):
- **Two images in one container format.** The header carries magic,
  version, kind, layout, a digest and a checksum, then a table of framed
  `to_bytes` sections. The spelling image's digest names the syllabary it
  was built for, so it cannot be loaded against the wrong lexicon.
- **Gates:**

  | | Result | Gate |
  |---|---|---|
  | Lexicon image | 23.2 MiB | ≤ 32 MiB |
  | Read + verified load, median of 5 | 22.8 ms | ≤ 50 ms |
  | Resident memory with the lexicon loaded | 23.5 MiB | |
  | Spelling image | 120 KB | |

  The load splits into read 2.6 ms, checksum 2.1 ms, `from_bytes` 2.2 ms
  and validation 15.9 ms. Validation is what makes every later lookup
  bounds-safe; it can be made faster if load time ever matters.
- **Lookups** over the 1,675,011 entries, 200k samples each:
  - exact code: p50 208 ns, p99 708 ns;
  - an abbreviated syllable as an id range: p50 375 ns, p99 1.0 µs;
  - spelling: p50 83 ns.
- **Build:** `octo-compile` turns 91 MB of TSV into both images in about
  0.3 s, and the images are byte-for-byte reproducible.
- **Proof against the sources:** `images-test` finds every one of the
  1,675,011 entries by its code, with its text and weight, and every
  spelling row. Each kind of damage is refused, never half-loaded:
  - a flipped byte;
  - truncation;
  - the wrong kind of image;
  - a zero-length entry;
  - an out-of-range pair id;
  - a moved index node;
  - a non-monotone index;
  - a spelling table built for another syllabary.
- **The fuzzer found a real bug within seconds.** The validator checked
  the first-syllable index step by step as it used it. An index such as
  `[0, 500, 300]` passes its first step and then reads past the end, so the
  validator itself could abort on a crafted image. It now proves each
  index monotone before using it, and `images-test` keeps the case as a
  regression. Since the fix, 20-second runs of both loaders are clean,
  standalone (ASan, UBSan and Goose's `--debug` checks) and on libFuzzer.

What the typeable slice does, and what measuring it changed:
- **Engine:** `engine/lattice.goose` reads input as spellings, with `'`
  separators and completion of a half-typed last syllable.
  `engine/decoder.goose` finds every word from each position and the best
  sentence through them. `engine/session.goose` handles composing:
  partial selection, backspace that undoes a selection, paging,
  and punctuation. (An English mode on a Shift tap was removed on
  2026-11-08: a Shift-click switched it unnoticed.)
- **Host:** `macos/` is the app, with ABI v2 (plain scalars, so no
  generated struct name enters the ABI).
- **Speed:** 370 µs per key typically, 0.87 ms p99, under 1 ms worst case,
  for inputs up to 35 letters.
- **What `make eval` found.** It takes common entries as the right answer
  for their own pinyin, typed alone (2–4 syllables) and in phrases of 2–3
  words, sampled both uniformly and by frequency:

  | Change | Phrases first | Words by frequency first |
  |---|---|---|
  | First slice | 86.0% | 99.3% |
  | Recall fix | 95.5% | 99.3% |
  | + word penalty 6 bits | 97.0% | 99.8% |
  | + inner-abbreviation penalty −4 bits | 97.5% | 99.9% |

  - **The recall fix mattered most.** The first slice kept up to 60
    homophones for every syllable group at every position. Abbreviation
    edges made long inputs hit the word cap before the search reached later
    positions, so no sentence covered the whole input. Now only the start
    of the input keeps many homophones; elsewhere one best word per span is
    all the sentence search can use. Worst-case latency fell from 4.8 ms to
    under 1 ms.
  - **The vowel-split penalty stays off.** It charges a syllable that starts
    with a, o or e after another with no `'`. It barely helps and flips
    everyday words to the rarer spelled-out reading: `fangan` gives 反感
    over 方案, which is 8.8 times as frequent. It remains a setting.
  - **Most remaining misses are true ambiguity** (说好分为/氛围,
    天将/天降), which a grammar model or the user dictionary resolves.

### Exit criteria

| Area | Criterion |
|---|---|
| Typing | A week of daily use in TextEdit, Notes, Safari, Chrome, VS Code, Xcode, Terminal and WeChat, with no lost keystrokes and no IME crash |
| Accuracy | ≥ 95% top-1 on about 600 common words and idioms from outside sources. Names, places and 120 sentences are tracked as metrics for M2's grammar model (decided 2026-11-08: a name typed alone that shares its pinyin with a common word has no right answer without context) |
| Latency | Key → snapshot p99 ≤ 2 ms for inputs up to 20 letters; ≤ 5 ms worst case (40+ letters, abbreviation-heavy) |
| Memory | Default lexicon image ≤ 32 MiB; IME resident footprint ≤ 80 MiB after a day of use |
| Robustness | Every loader, the decoder and the key path fuzzed for an hour with no findings; no main-thread aborts while dogfooding |
| Privacy | No learning in secure fields, no-learn apps or incognito; user dictionary encrypted at rest; no typed text in any log |

## The default lexicon: 万象 Base

Measured at release v18.1.9 (2026-11-06), the import set of the Base
edition's `wanxiang.dict.yaml`:

| Fact | Value |
|---|---|
| License | CC BY 4.0, for both rime-wanxiang and rime-wanxiang-data |
| Dictionaries | zi 51,051 · jichu 1,493,819 · cuoyin 196 · duoyin 4,737 · diming 89,415 · mingren 22,127 · yiren 14,441 |
| Total | 1,675,786 entries in about 55 MB of YAML |
| Entry format | `text⇥tone-marked pinyin, space-separated⇥weight`; cuoyin adds a fourth column, a category |
| Syllables | 1,590 with tones, 419 without; one syllable per character (one exception) |
| (character, syllable) pairs | 51,454, which fits in a u16 |
| Prefixes | 97,308 distinct two-syllable prefixes; 1,000,260 three-syllable |
| Weights | Median 242, p99 5,055, max 48.3M; 989 zeros, 18 missing, about 15 malformed (`45N`, `10s`) |
| Homophones | Up to 894 per code (`yi`); p99 4 |
| Beyond the BMP | 18,135 entries contain characters outside it |

### Pinning and attribution

- `data/wanxiang.lock` records the release tag, its commit and the SHA-256
  of every file we take. `tools/fetch-wanxiang.sh` downloads exactly those
  files, on developer machines and in CI only. The IME never downloads
  anything.
- Upstream releases every few days (eight in the last three weeks), so
  bumping is deliberate. `make relock TAG=<tag>` pins the new release,
  prepares it, and prints what changed (the import report's numbers, and
  lexicon lines added and removed) for review before committing.
- CC BY 4.0 requires credit, a link to the license, and a note of changes.
  A `NOTICE` file in the repo and in the app bundle, and an About item in
  the input menu, say: "Lexicon: 万象拼音 by amzxyz, CC BY 4.0, converted
  to OctoDot's format."

### What M1 takes, and what it leaves for later

M1 takes the seven Base dictionaries, the full-pinyin rules in
`wanxiang_algebra.yaml`, and the tones, which ride along in the pair table
for later tone filtering and hints.

Later milestones:
- **Lua features** (about 30 components): OctoDot runs no scripts by design.
  Useful features get reimplemented natively, starting in M2.
- **Shuangpin and auxiliary-code schemes** (M2): data-only, once the
  spelling tables exist.
- **OpenCC data** for Traditional output and emoji (M3).
- **Extension dictionaries and English mixed input.**
- **The grammar model** (below).

wanxiang also ranks sentences with an n-gram collocation model,
`wanxiang-lts-zh-hans.gram`, which is 418 MB. M2 adds a reader and a
writer for it. At that size it is far beyond M0's verified-copy loading
model, so the reader will use memory-mapped, bounds-checked reads (the
alternative M0 describes).

## Composite input: tone keys and shape codes (done)

How to type them, while composing:
- **A tone:** type 7, 8, 9 or 0 after a syllable for the first to fourth
  tone (0 is also the neutral tone), as in 万象. `zhong7` gives 中, and
  `zhong9` gives 种. This works mid-sentence too: `zhong7guo` gives 中国.
  The keys 1–6 still pick from the page. A tone that leaves the input with
  no reading at all is refused (`dui8`).
- **A shape code:** type `` ` `` after a syllable, then one or two letters
  of its character's auxiliary code. `` shi`o `` gives 是. Codes also work
  mid-sentence: `` woshi`ozhongguoren `` gives 我是中国人. The scheme is
  万象's own (`aux.wanxiang.img`). All nine schemes from 万象's
  `aux_code.csv` are built (`aux.<scheme>.img`); choosing one waits for
  settings (C5).

How it works:
- **Data.** The tone spellings were already in the spelling table. The
  shape codes come from `custom/aux_code.csv`, pinned in
  `data/wanxiang.lock`. octo-prep normalizes the file into `aux.tsv`,
  merging alternatives (`｜`, quoted commas) and dropping component text.
  octo-compile builds one image per scheme, keyed by code point and
  verified like the others. It has a fuzz target (`make fuzz`).
- **Constraints on edges.** A tone spelling's edge carries its toned
  syllables. `` ` `` adds variants of the edge before it, with a code of
  one or two letters. Word recall checks each word against every
  constraint on its path before applying the homophone cut. Only a syllable
  spelled out takes a code: 万象 accepts `zhon` for zhong, so `` zhong`k ``
  could otherwise read as `zhon` plus an initial `g` carrying the code.
- **Different from 万象.** 万象 filters whole candidates after decoding,
  so its code applies to the candidate as a whole. Here a code belongs to
  the syllable it follows, so it can narrow any character in a sentence
  without losing candidates.
- **Menu.** The menu now covers the longest stretch of input that can be
  read. A word is offered only if what follows it can be read too, so
  `zh` with `ong7` left over no longer appears.
- **Checks.** `make test-typing` adds the cases above and 20,000 random
  keys (letters, `'`, `` ` ``, tones, digits, editing keys), with no check
  failing. `make test-app` runs `` shi`o `` and `zhong9` through the Swift
  bridge. Latency and `make eval` are unchanged: 0.88 ms p99 headless,
  0.69 ms through the bridge, phrases first 97.5%.

## Composite input: character sets (done)

- **What the user sees.** Candidates show 万象's daily character set:
  single characters outside 通用规范汉字表 are hidden. That clears
  characters like 昰 and the traditional 給 out of the menus. Control-g
  while composing switches to the full set and back, the same key 万象
  uses. Words are never filtered, so 屌丝 still comes first for `diaosi`.
  Characters that are not ideographs always appear.
- **Data: Unicode's Unihan database,** pinned in `data/unihan.lock`
  (Unicode 18.0.0, SHA-256, with Unicode's license) and fetched by
  `tools/fetch-unihan.sh`. It records which ideographs are in 通用规范汉字表
  (kTGH, exactly 8,105), GB2312 (kGB0, 6,763) and Big5 (kBigFive, 13,064),
  and which code points are ideographs at all (kRSUnicode). 万象 keeps the
  same information only in a compiled Rime binary. octo-prep writes
  `charsets.tsv`, and its report counts the lexicon against each set: all
  8,105 table characters are in the lexicon, and 3 of its 43,339
  characters are in no set (none of them ideographs).
- **The daily set is 通用规范汉字表 plus `data/daily-extra.txt`,** a short
  reviewed list with a reason on each line: 诶, 囧, and 𰻞/𰻝 (biáng, which
  万象 adds too). GB2312 as a whole was rejected because it would bring
  back forms the 2013 table retired (後, 馀), which 万象 hides as well.
- **In the image,** each character reading carries one byte of set flags,
  layout 2 of the lexicon. That adds 51 KB, and a filter costs one load.
  Word recall drops a rare single character before the homophone cut,
  just as it does a constraint. The snapshot reports the full-set state
  (flag 16).
- **Limits.** Under the full set, very rare characters can still fall
  outside the 60 homophones kept per syllable (昰 for `shi`). A shape code
  reaches them (`` shi`o ``).
- **Checks.** The image test compares every reading's flags with
  `charsets.tsv`, checks the 8,105 count and 中's sets, and refuses an
  out-of-range flag byte. It also checks every code of all nine shape-code
  schemes against its image. The typing tests and the Swift bridge test
  the filter and Control-g. `make eval` and the load gate are unchanged:
  phrases first 97.5%, load 28.8 ms against the 50 ms gate.

## Composite input: words with symbols (done)

- **The case.** 万象 had one row whose text has more characters than its
  code has syllables: `李·卡斯利`, read `lǐ kǎ sī lì`. It was the only row
  octo-prep dropped. Digits are not this case: `2型糖尿病` reads its 2 as èr.
- **octo-prep** lets a word contain *marks* with no syllable: the
  middle dots of transcribed names (· ‧ ・ ･ •) and hyphens. It writes
  `-` in the code for each (`lǐ - kǎ sī lì`) and notes the row in the
  report. Any other mismatch is still dropped.
- **The image** keeps marks in a side table (lexicon layout 3): entry,
  position, character, verified on load. Only `lexicon::text` reads it,
  so the syllable index and the search never see a mark. This replaces
  the zero-syllable pairs first planned, which would have made every index
  key skip them on the hot path.
- **Checks.** All 1,675,012 rows come back by their code with text and
  weight. `likasili` gives 李·卡斯利 first. The image test refuses a mark
  for a missing entry, and the fuzz target renders every entry with a mark.
- **`make eval` samples by a hash of each entry's text now,** not by its
  index. One added row had shifted every later index and changed the
  whole sample, so results did not compare across lexicon changes.
  Comparisons within one build were paired and still hold. On the new
  sample the defaults hold too: word penalty 6 (phrases 95.1% → 96.7%),
  middle-abbreviation penalty −4 (→ 97.0%), and no vowel-split penalty
  (it lowers phrases to 96.5%). The baseline is now 99.8% for words, 97.0%
  for phrases and 99.9% for words drawn by frequency.

## The accuracy set

The accuracy criterion's set is built from outside sources, so no line of
it is picked by hand. `data/accuracy.lock` pins each source to a commit
and a SHA-256. `tools/fetch-accuracy.sh` fetches them into `.data/accuracy/`
for testing only; none is committed or shipped.

| Source | What it gives | License |
|---|---|---|
| [rime-schema-compare](https://github.com/jidzhang/rime-schema-compare) (the jidzhang fork of gaboolic's benchmark) | zhihu120: 120 sentences of Zhihu text. words234: 450 frequent words. Both have readings audited by hand | None stated; fetched for testing, never redistributed |
| [THUOCL](https://github.com/thunlp/THUOCL) (Tsinghua) | Names, places and idioms, with how many documents use each | MIT |
| [phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data) | Readings of words that do not come from 万象 | MIT |

`octo-prep accuracy` builds `build/accuracy/` from them:
- **Common words:** words234's 450.
- **Names, places and idioms:** THUOCL's 150 most used of each, keeping only
  what phrase-pinyin-data lists as a word. THUOCL's places include
  segmentation fragments such as 新一, which this filter drops. Each word
  takes phrase-pinyin-data's reading.
- **Sentences:** zhihu120.
- **Readings:** each one must be a reading 万象 gives that character in some
  word. A word that 万象 reads differently is set aside rather than
  guessed at.

What it sets aside goes to `review.tsv`: 73 entries that are not words,
and 4 disagreements. Two of those are 万象's own errors: it reads 盖茨 as
gě and 查韦斯 as zhā.

`make accuracy` lists every miss. `make test` gates the common words and
idioms at 95% in both schemes. Names, places and sentences are metrics,
which M2's grammar model is measured against. Typed alone, a name that
shares its pinyin with a common word (胡适, 护士) has no right answer
without context. Sentences are scored as rime-schema-compare scores librime, so
the numbers compare: 他/她/它 count as one, as do 的/地/得.

| | 全拼 | 小鹤双拼 |
|---|---|---|
| common words | 99.6% | 99.6% |
| names | 78.7% | 79.3% |
| places | 89.3% | 90.0% |
| idioms | 99.3% | 99.3% |
| **common words and idioms (gate: 95%)** | **99.5%** | **99.5%** |
| words, all | 94.3% | 94.6% |
| sentences right as a whole | 49.2% (59 of 120) | 50.0% |
| characters right in sentences | 88.4% | 89.5% |

On the same 120 sentences, rime-schema-compare's reports give these
results through librime:

| | Sentences | Characters |
|---|---|---|
| 万象 | 48.33% | 89.27% |
| 万象 with its grammar model (M2's target) | 60.00% | 92.23% |
| best: 白霜 with the grammar model | 65.83% | 93.43% |

So OctoDot's decoder matches librime on the same lexicon. What remains is
context.

- **Names are the weak spot.** Most misses are a name sharing its pinyin with
  a more common word (布什 and 不是, 胡适 and 护士, 朱熹 and 主席, 姚明 and
  要命). Some are THUOCL noise that nobody expects first, such as 元和,
  大路 and 上新.
- **Seven words are not in 万象 at all,** among them 长治久安, 李长春 and
  贝卢斯科尼.
- **One choice fixes each collision** through learning. The grammar model is
  what can rank them in context.
- **A hand-written draft came first,** with 659 words and 205 clauses. It
  scored 95.6% on words and 92.7% on sentences. Those clauses were far
  easier than real text, which is why the set now comes from outside.

### Long input

8 of zhihu120's sentences run past 64 letters in full pinyin, which is the
most one composition holds. The IME used to drop every key after that. Now
a key typed into a full composition first commits the best reading's first
word:
- The selections made before it teach the user dictionary as usual.
- The committed word teaches nothing, since no one chose it.

Tones, ' and shape codes are kept the same way. The typing test types 144
letters with no pause and checks that none is lost.

The cap stays at 64. Raising it buys no accuracy: zhihu120 scores the same
at 64, 80, 96 and 128. It does cost time: abbreviation-heavy input takes
about 50 µs more per letter, and passed the 5 ms gate at 99 letters. Typing
past a full composition measures p99 3.5 ms.

## Hardening

- **Memory.** The installed IME measured 46 MB of physical footprint after
  use, against the 80 MiB gate. Its peak was 100 MB at launch: the phrase
  compiler's worker loads a second copy of the core while it runs. Now it
  runs at launch only if the phrase file or the IME binary is newer than
  the last result.

  The bench simulates a day of typing: 20,000 words of varied pinyin
  committed through the session, each teaching the user dictionary. It
  ended with 19,923 learned words and memory up 9.7 MiB (the saved
  dictionary is 1.9 MiB), so a long day stays near 56 MB.

  On memory pressure, the host calls `octo_trim` (ABI v7), and the engine
  returns its unused pages.
- **Abnormal exits.** Goose turns a stack overflow on the main thread into a
  silent `_exit`, with no crash report. So a marker file is written at
  launch and removed on a clean stop, which is quitting or the SIGTERM that
  `make install` and logout send. A marker found at the next launch counts
  as an abnormal end. It is logged with no user data, and shown in the
  input menu so it gets reported.
- **No typed text in any log.** `tools/check-privacy.sh`, run first by
  `make test`, rejects three things:
  - prints in engine code;
  - aborts whose message is built at run time;
  - IME logging outside `Logger`, and values marked public that are not on
    an allowed list of statuses, ids and counts.

  A planted violation of each kind is caught.
- **An hour of fuzzing per target, no findings** (the robustness exit
  criterion), under ASan, UBSan and Goose's debug checks:

  | Target | Inputs in an hour |
  |---|---|
  | keystrokes into a session over the real images | 213,192 |
  | lexicon image loader | 12,771,774 |
  | spelling image loader | 34,476,825 |
  | shape-code image loader | 39,848,842 |
  | saved user dictionary | 2,411,333 |
  | custom phrase compiler | 1,238,989 |

- **CI.** `.github/workflows/test.yml` runs `make test` on an Apple silicon
  runner, with the Goose compiler and the pinned data cached. It runs only
  when started by hand: on a private repository, macOS minutes count ten
  times against the allowance, and one run takes about ten minutes. It has
  not run yet.

## Robustness and speed gates

- **Two new fuzz targets** (`make fuzz`), beside the three image loaders:
  - `keys`: every byte is a keystroke into a session over the real images.
    That covers letters, digits, separators, editing keys, Control-g,
    scheme switches, the no-learn flag, saving and restoring the user
    dictionary, and forgetting. After every key the session's invariants
    must hold: buffers in bounds, the highlight and page inside the menu,
    candidates and their words inside their pools, and the snapshot well
    formed.
  - `userdb`: every input is a saved user dictionary. Restoring never
    aborts; a refused file leaves the dictionary empty, not half loaded;
    and saving what was restored, restoring that and saving again gives
    the same bytes.

  Seeds are checked in under `engine/fuzz/seeds/`, readable text for the
  keystrokes.
- **Found and fixed:** the menu and the picks referred to learned words by
  their position in the user dictionary. A forget or an unlearn in the
  middle of a composition left those references stale, so a later commit
  read a word that had moved or was gone, an index out of bounds on the
  main thread. Now a pick copies its words' readings when it is made, the
  menu is rebuilt whenever the dictionary changed since it was built, and
  the lookup checks bounds. The crashing input is a seed, and a typing
  test covers the case.
- **Latency gates** (`make test-typing`, measured while a fuzzer ran on
  another core):

  | Gate | Measured |
  |---|---|
  | p99 ≤ 2 ms for inputs up to 20 letters (abbreviation-heavy) | 1.5 ms |
  | ≤ 5 ms worst case for 40+ letters, abbreviation-heavy | p99 3.0 ms, max 3.4 ms |

## Input schemes: 小鹤双拼 (done)

**A scheme is data, and the engine never knows which keys are typed.**
Full pinyin and 小鹤双拼 differ only in their spelling table. That table is
the keys → syllables map that octo-prep computes from 万象's own algebra,
exactly as librime would. Everything after it works on syllables: the
graph, the word search, sentences, learning, tones, shape codes and the
character set.

- **Data.** octo-prep's scheme list holds `base/全拼` (id `fullpinyin`,
  preedit `typed`) and `base/小鹤双拼` (id `flypy`, preedit `syllables`).
  Each `spellings.<id>.tsv` starts with a `#scheme` line. octo-compile
  builds every scheme it finds into `spellings.<id>.img`. The image (layout
  2) carries its id, name and preedit style, so it describes itself. 小鹤
  is 1,937 spellings, all of them full readings: `vs` zhong, `ui` shi, `hc`
  hao, `vs7` zhōng, `v7` any first-tone zh syllable. It has no single-letter
  abbreviations; 万象 leaves them off.
- **全拼's typo spellings are left out.** 万象's 全拼 algebra has 38 `derive`
  rules that spell common slips as correct readings (`zih` and `hzi` for zhi,
  `zhogn` for zhong) with no penalty, so a slip outranks the real reading of
  those keys. `octo-prep` drops them, from the pinned list
  `data/wanxiang-typo-rules.txt` (checked against 万象 v18.1.9). 小鹤双拼 has
  none of those rules, and its table is unchanged. A half-typed syllable
  still completes (`lon` to long, `ten` to teng). See
  [`remove-typo-spellings.md`](remove-typo-spellings.md).
- **Engine.** `session::set_scheme(id)` verifies the new table before it
  replaces the live one, so a bad image never leaves the user unable to
  type. The scheme list comes from the data directory, image by verified
  image. Nothing else changes.
- **Preedit.** Every scheme shows the keys typed, split by syllable:
  `zhong guo ren` in full pinyin, `wo ui vs go rf` in shuangpin, a tone or
  shape code staying with its syllable (`vs7 go`, `` ui`o ``). (Until
  2026-11-09 a `syllables` scheme spelled each syllable's pinyin out,
  `wouivsgorf` → `wo shi zhong guo ren`; users read back the keys they
  pressed, not the expansion.)
- **Learning across schemes.** Learned words are stored by syllables, so
  they carry over: 实时 learned as `shishi` comes first for `uiui`.
  Choices are stored by keys, so they are scoped by scheme
  (`flypy:uiui`, `fullpinyin:shishi`), since the same keys mean different
  things in each scheme. Choices saved before scoping load as full pinyin.
- **Host.** ABI v4 adds `octo_schemes` and `octo_set_scheme`. The input
  menu lists the schemes with a check mark, and remembers the choice. On
  switching, whatever is being typed is committed as typed, since its keys
  meant the old scheme.
- **Measured** (`make eval SCHEME=flypy`, the same samples, each syllable
  typed with 小鹤's own keys):

  | | Words first | Phrases first | Words by frequency | After learning, other half |
  |---|---|---|---|---|
  | 全拼 | 99.8% | 97.0% | 99.9% | 98.3% |
  | 小鹤双拼 | 100.0% | 97.5% | 100.0% | 98.5% |

  Two keys per syllable remove full pinyin's segmentation ambiguity (`xian`
  against `xi'an`). Only 8 of 419 syllables share their keys with another,
  which is 小鹤's own design: `lo` is lo and luo, `en` is en and n, `eg` is
  eng and ng, `me` is me and m.
- **Adding a scheme** is one line in octo-prep's list, if its keys are
  letters. 自然码, 搜狗 and the other twelve 万象 schemes are all in the
  algebra file. Schemes that use `;` (微软双拼) also need the session to
  accept that key.

## Candidate window (C3: horizontal layout done)

- **On macOS 26 and later** it is a Liquid Glass capsule (`NSGlassEffectView`).
  - **Light mode:** a light tint quiets busy text behind the glass.
  - **Dark mode:** a dark backing keeps the white text legible over a light
    page, since glass alone takes its brightness from what is behind it.
- **On macOS 14–25** it is a blurred capsule (`NSVisualEffectView`).
- **The highlighted candidate**, the one Space picks, sits in an
  accent-colored pill that slides when the highlight moves. The pill jumps
  without sliding when typing changes the list.
- **Text:** candidates at 18 pt, with small grey index numbers on their
  baseline. The page arrows come after a divider and dim when there is no
  page that way.
- **Clicks:** candidates and page arrows can be clicked, with a hover
  highlight. A click acts like the key for it. The panel never takes focus
  from the app.
- **The preedit** is split into the syllables of the best reading
  (`zhong guo ren`, `wo shi z g r`, `zhong7 guo`k`), with a thick accent
  underline. `decoder::syllable_ends` re-matches only the best sentence's
  words against the graph, so the search carries nothing extra.
- **`OctoDot --preview [SECONDS]`** shows the window with sample
  candidates, the highlight walking along (`OCTO_APPEARANCE=dark` for dark
  mode), for checking the design by eye or with `screencapture`.

## User learning (B4, C4, C5: done)

What it does for the user:
- **Choosing teaches it.** Pick 西安 for `xian` and next time `xian`
  offers 西安 first. The choice also carries to `xi'an`, to sentences, and
  to abbreviations of the same syllables.
- **Phrases.** A phrase built from several picks (说好 + 分为) comes first
  next time as a whole. So does a short sentence accepted with Space.
- **Mistakes are taken back.** If the user deletes a commit with Backspace
  right away, then types the same input and picks something else, the
  deleted commit's learning is undone. Shift- or Control-Backspace on a
  highlighted candidate forgets it.
- **The input menu** has *Incognito: Learn Nothing* and three ways to
  forget: the last 15 minutes, today, or everything.
- **Nothing is learned** in secure fields (any password box), in password
  managers, in incognito, or from letters committed as typed.

How it works:
- **Two memories (`engine/userdb.goose`).**
  - **Words:** learned words by syllables, kept as a small in-memory
    lexicon of the same shape as the main one, so the word search walks it
    unchanged. A learned word scores like the best lexicon word for the
    same syllables (or weight 4096 for a phrase the lexicon lacks), plus 6
    bits for one use and 2 more per doubling.
  - **Choices:** which text was chosen for exactly this typed input. In
    the menu, among candidates covering the same input, chosen ones come
    first regardless of score. The sentence candidate yields only to
    whole-input words chosen more often than it.
- **What one commit teaches:**
  - the choice for each pick's letters;
  - each word, counted twice if the user picked it and once if it came
    along in an accepted sentence, so a sentence accepted with Space does
    not echo the engine's own guess louder than the user's corrections;
  - the whole as a phrase, if it took two or more picks (up to 16
    syllables) or was a sentence accepted in one go (up to 6).

  A pick made from a single letter (`g`) teaches only its choice: picking
  from pages of a one-letter abbreviation says too little to promote the
  word everywhere.
- **Decay.** A use counts half after 90 days without another, and an old
  single choice stops reordering after about one half-life. What is unused
  for 365 days is dropped when saved.
- **Retraction.** The session counts Backspaces that pass through to the
  app against the last 4 commits. Any other key that changes the app's
  text or caret clears them. Every learning change carries its commit's
  id, so `userdb::retract` can undo exactly that commit.
- **Storage.**
  - **Format:** the engine saves versioned text, words by text and toned
    pinyin, choices by the letters typed, with uses and the local day. It
    is not tied to syllable ids, so it survives lexicon and compiler
    upgrades. Words naming syllables a later lexicon lacks are kept as they
    are.
  - **Encryption:** the host seals it with AES-GCM under a 256-bit key in
    the login Keychain (this device only, never synced). It is bound to the
    context "OctoDot user dictionary" and written atomically in the
    sandbox container, in two generations.
  - **Recovery:** a damaged current file falls back to the previous one,
    and a file no key opens is set aside, never overwritten. Typing never
    waits on any of it.
  - **When it saves:** 5 seconds after a change, when the input method is
    switched away, and on quit.
- **ABI v3.** `octo_key` takes a flags word (KEYFLAG_NO_LEARN) from the
  host's privacy policy. New calls: `octo_user_save`, `octo_user_restore`,
  `octo_user_changes`, `octo_forget` and `octo_set_utc_offset`.
- **Measured** with `make eval`. A simulated user types 750 phrases,
  building the right text pick by pick wherever the first candidate is
  wrong. Afterwards, the phrases it typed come first 100% of the time (from
  97.7%). The 750 phrases it never typed rise from 96.3% to 98.3%, best at
  6 bits: 2 gives 97.6%, 4 gives 98.1%, 8 gives 97.1%. Both halves draw on
  the same words, so the second figure shows mostly that learning does no
  harm elsewhere.
- **Checks.**
  - The typing tests cover learning, choices, the single-letter rule,
    phrases and accepted sentences, saving and restoring (including bad
    lines and unknown syllables), forgetting in each scope, retraction and
    its two negative cases, Shift-Backspace, the no-learn flag, letters
    committed as typed, decay, and a learned rare character shown in the
    daily set.
  - The Swift bridge tests the ABI and the sealed store: no plaintext on
    disk, the fallback to the previous file, and a wrong key.
  - The sandboxed self-test makes, reads and removes a Keychain key and
    saves and loads the store inside the container.
- **Ideas from qingjian** (github.com/qingjian-team/qingjian, GPL-3.0; ideas
  only, no code):
  - choices keyed by the typed input, ranked ahead of score;
  - no carrying over picks from a single letter;
  - explicit picks counting double;
  - phrase limits by how the phrase was made;
  - retracting a deleted commit;
  - the 90-day half-life.

  Its personal bigram/trigram model needs a decoder that tracks the
  previous word, so it waits for M2 and the grammar model.
- **Still open.**
  - **Signing:** with the ad-hoc signature, macOS asks again for the
    Keychain key after every rebuild. Building with your Apple Development
    identity (`SIGN_IDENTITY`) makes that a one-time question.
  - **Settings:** the no-learn app list is built in; editing it waits for
    settings.

## Composite input: design decisions

Input that combines sound with something else has to work in one decoder:
tones, auxiliary (shape) codes, character-set limits, and words containing
symbols. Rime-style engines split this between translators and filters
after decoding. These were weighed against measurements and the data (a
design review, 2026-11-07).

**Adopted**
1. **Constraints act inside word recall, before anything is cut.** Recall
   keeps only so many homophones per group, and one word per span inside
   the input. A tone or shape constraint applied afterwards would lose the
   character it was typed to find. So an edge carries its constraints, and
   each word's pairs are checked as it is found.
2. **Characters with no syllable** (built, adapted). Punctuation inside a
   word (`李·卡斯利`) lives in a side table that only text rendering reads,
   not in pairs the index would have to skip. Latin letters typed as
   themselves (`T恤`, `卡拉OK`) are a different problem, mixed input, for
   later.
3. **Sidecar tables beside the lexicon.**
   - **Per-pair flags in the lexicon image:** membership of 通用规范汉字表,
     GB2312 and Big5, from Unihan (built; see above). They are read on the
     hot path, so they are indexed by pair for O(1) lookup.
   - **Auxiliary codes in a small image per scheme:** from 万象's
     `aux_code.csv`, which covers nine schemes (万象, 墨奇, 野鹤, 自然码,
     五笔前2 …), two letters each and sometimes several per character.
     Codes belong to characters, not readings, so these images are keyed by
     code point (built; see above). Switching schemes never rebuilds the
     lexicon. That avoids 万象 Pro's separate auxiliary-code lexicon.
4. **A word insertion penalty,** at the 6 bits `make eval` measured. A value
   argued for in the abstract was not good enough.

**Adapted**
5. **Tones are typed 7, 8, 9, 0 after a syllable, as in 万象** (built). The
   spelling table already held those spellings (`zhong7`), including tones
   on initials (`zh7`). With six candidates per page, 7–0 are free while
   composing, so they become a tone constraint on the edge.
6. **An edge stands for a set of syllables in runs, not one id range.**
   Fuzzy spellings are not contiguous.

**Declined**
7. **The vowel-split penalty,** by measurement (above).
8. **Shape schemes (五笔, 仓颉) as "any syllable plus a shape code".** That
   scans the whole lexicon on every key. They need their own index, sorted
   by shape code, but they share everything after the index: lattice, word
   search, sentence and menu. One decoder with several indexes is the real
   unification.
9. **Fixed-point (Q8.8) scores.** The reason given, that integers wrap in
   release builds, argues against them: floats do not wrap, and scores are
   already stored as f32.
10. **Fixed columns of 8 edges per position.** Goose has no heap: the
    per-key arrays are bump-allocated and freed at scope exit. A cap of 8
    would silently drop readings (z, zh, zhu, zhua, zhuan, zhuang).
11. **A bonus for matching an auxiliary code.** A constraint that filters
    already puts the match first; a bonus only distorts ranking among
    matches.
12. **Incremental lattice updates as a goal.** Word search, not the lattice,
    takes the time, and p99 is 0.87 ms. Caching per-position words stays in
    reserve if the budget tightens.

## Decisions

1. **Spelling rules are evaluated at build time, not in the engine.**
   wanxiang's 3,162 rules use Perl regex features that Goose's regex lacks:
   807 lookarounds (727 lookaheads, 60 negative lookaheads, 20 negative
   lookbehinds), and `^`/`$` anchors in about a thousand rules. A Swift
   build tool evaluates them with `NSRegularExpression`, since ICU supports
   lookaround and `$1` replacements. It follows librime's semantics, as
   written in its `calculus.cc`:
   - `xform`, `derive`, `abbrev` and `fuzz` replace every match;
   - `erase` needs a full match;
   - abbreviations and fuzzy spellings cost log 0.5, corrections log 0.01.

   The output is a spelling table (spelling → syllable or syllable range,
   type, penalty), and the engine loads it as data. Each shuangpin scheme
   becomes another table, so shuangpin needs no engine code in M2.
2. **Images are prebuilt and shipped.** Upstream YAML goes through
   `octo-prep` (Swift) to normalized TSV, then through `octo-compile`
   (Goose) to verified images in `OctoDot.app/Contents/Resources/data/`.
   `octo-compile` is the same code the IME will run for user imports. The
   IME never parses YAML. Only Goose writes images, because their layout is
   Goose's serialization format.
3. **A compact lexicon encoding.** A word is stored as a run of u16 pair ids
   (character plus toned syllable), so one run carries the text, the code
   and the tones: 11.7 MB for all 5.83M characters, against 29 MB for text
   plus syllable ids.
   - **Ordering and index:** entries are sorted by their toneless syllable
     sequence, with a two-level index (first two syllables, 97k nodes) and
     binary search below it.
   - **Abbreviations as ranges:** syllable ids follow alphabetical order, so
     abbreviations such as `z` or `zh` cover contiguous id ranges, and the
     index matches them as ranges.
   - **Projected image:** about 27 MiB.
4. **No grammar model in M1.** Candidates rank by unigram weight plus user
   learning, measured against the sentence set. The model's reader and
   writer come in M2.
5. **JSON config in M1.** Goose's stdlib has a strict JSON reader; TOML
   arrives with the Settings app in M2.
6. **Make and swiftc stay.** There is no Xcode project; M0's build works,
   and XcodeGen is not installed.
7. **Builds are signed with your Apple Development identity.** An ad-hoc
   signature changes with every build, and Keychain access rules follow the
   signature, so every rebuild would prompt for the user-dictionary key.
   Developer ID signing and notarization come in M3, with public
   distribution.

## Architecture changes from M0

```
build time (developer machine, CI)                           run time (IME)

wanxiang release ── fetch, pinned ──▶ 7 dict.yaml + algebra.yaml
                                        │ octo-prep (Swift, ICU regex)
                                        ▼
                     normalized TSV: syllables, pairs, spellings, lexicon
                                        │ octo-compile (Goose)
                                        ▼
                     images: header + checksum ──▶ Resources/data ──▶ verified load ──▶ engine
```

### Engine modules (Goose, `engine/`)

| Module | Job |
|---|---|
| syllabary | The 419 toneless syllables (u16 ids, alphabetical), tones, and the 51k pair table |
| spelling | A letter trie over the spelling table: every spelling that starts at an input position |
| lattice | The syllable graph over the input: `'` delimiters, ambiguous splits (xian / xi'an), completion of a partial last syllable |
| lexicon | The compact image and two-level index; common-prefix search with syllable ranges, with a cap on branches explored |
| decoder | Best path over the lattice by log weight + user boost − spelling penalties; a sentence candidate, then words and characters for the first segment |
| composition | Input buffer, caret, partial selection (a candidate covering the first syllables confirms them and composing continues), paging, punctuation, ASCII mode |
| userdb | Learning, decay, forgetting and clearing; a versioned record format of our own (not a Goose image, so it survives compiler upgrades) |
| jobs | User-dictionary compaction, and later imports, in contained workers (spike 02's supervisor pattern) |
| api | C ABI v2: sessions, keys, snapshot v2, selection, paging, privacy flags, user-dictionary save and load, pump |

Snapshot v2 adds segments (confirmed and active), candidate comments, page
index and has-more, the highlighted index, and mode flags (ASCII,
incognito).

### Host (Swift, `macos/`)

- A shared module (bridge, snapshot decoder, crypto store, privacy policy)
  used by the IME and its tests. The Makefile assembles and signs the bundle
  as in spike 01.
- Input controller v1:
  - keyDown and flagsChanged, so Shift alone toggles ASCII mode;
  - shortcuts pass through to the app;
  - marked text shows the segments and the caret.
- Candidate window v1:
  - horizontal and vertical layouts, 5 to 9 candidates a page;
  - highlight, page indicators and comments;
  - dark mode and multiple displays;
  - a fallback position when the client reports no caret rectangle.
- Input menu: ASCII mode, incognito, clear recent learning (15 minutes,
  today or all), About and licenses.
- Background plumbing:
  - background jobs wake the main thread through a CFRunLoopSource (a C shim);
  - a memory-pressure source calls `octo_trim`;
  - a launch marker detects abnormal exits, since Goose turns main-thread
    stack overflows into silent exits.

## Privacy in M1

- **Entitlements:** unchanged from M0, the sandbox plus the Mach-name
  exception. No network, and no App Group yet (there is no Settings app).
- **The user dictionary at rest:**
  - the engine exports versioned records;
  - Swift encrypts them with AES-GCM under a Keychain key, writes
    atomically and keeps two generations, in the IME's own container;
  - it saves when idle (debounced) and on deactivation.
- **What it learns from:**
  - only conversions, never raw ASCII, digit runs, URLs or email addresses;
  - nothing while `IsSecureEventInputEnabled()` is true, in no-learn apps
    (password managers by default), or in incognito;
  - last use is kept by day, and it never records which app.
- **Clearing recent learning:** "last 15 minutes" uses a session journal
  that lives only in memory; "today" uses the day field.
- **Logs:** they carry no typed text, and engine abort messages carry only
  the check and its source line. A CI check rejects `print` in engine code
  and user data in `abort` messages.

## Work breakdown

### Phase A: data

| Task | Done when |
|---|---|
| A1. Pin and fetch wanxiang; `NOTICE` | The lock file holds SHA-256s and the fetch script verifies them |
| A2. `octo-prep`: YAML-subset readers, NFC and tone splitting, librime-compatible algebra, import report | Output is deterministic; golden spelling tests pass (abbreviations, corrections, `v`/`u`, toned spellings) |
| A3. Image formats, `octo-compile`, verified loaders | Image ≤ 32 MiB, load ≤ 50 ms, lookup p99 measured; a fuzz target for each loader |

### Phase B: engine

| Task | Done when |
|---|---|
| B1. Lattice and spelling search | Golden segmentation tests pass (xian / xi'an, fangan, delimiters) |
| B2. Decoder and candidate assembly | ≥ 95% top-1 on the phrase set; latency budget met on the benchmark |
| B3. Composition model | Key-sequence tests pass: partial selection, backspace undo, paging, punctuation, ASCII mode |
| B4. User dictionary | Learn, rank, persist, reload, forget round trip; privacy cases |
| B5. ABI v2 and snapshot v2 | Swift ↔ Goose round-trip tests; key path fuzzed |

### Phase C: host

| Task | Done when |
|---|---|
| C1. Move out of `spikes/`; Apple Development signing; install and uninstall | `make install` gives a working IME |
| C2. Controller v1 and input menu | Manual checklist across apps |
| C3. Candidate window v1 | Layout and positioning checklist |
| C4. Encrypted user dictionary | Survives restarts; a wrong key or corrupt file falls back to empty and never crashes |
| C5. Privacy policy | Secure-field, no-learn-app and incognito tests |
| C6. Wake source, memory pressure, launch marker | Spike 02's behavior holds in the real app |

### Phase D: quality

| Task | Done when |
|---|---|
| D1. Test suites | `make test` runs the golden, behavior and benchmark suites against thresholds |
| D2. Fuzzing | Targets extended to every loader; an hour of libFuzzer before each tag |
| D3. CI on GitHub Actions (macOS, Apple silicon) | Goose bootstrap and data fetch cached; build and test on every push |
| D4. Dogfooding | A week of daily use; fix list closed |

### Checkpoints

1. Images build and pass the size and load gates (A3).
2. The engine decodes the phrase set headless (B2).
3. Typing in TextEdit on the real lexicon (C1 to C3, on B5).
4. Learning, encryption and privacy controls (B4, C4, C5).
5. Exit criteria met.

## Risks

| Risk | Mitigation |
|---|---|
| Accuracy without the grammar model | Done: the grammar model is in (M2-grammar.md) |
| Spelling semantics drift from librime | Golden tests from librime's documented behavior; compare spelling sets against a librime build if results look off |
| Upstream churn (releases every few days) | Pinned lock file, reviewed bumps; the importer fails loudly on unknown formats |
| Memory once extension dictionaries are added | A budget per image; shards or memory-mapped reads if needed |
| Goose churn | Pinned v2026.4; the ABI boundary |
| IMK client quirks | The app checklist; per-app rules |
| License provenance | Both repos declare CC BY 4.0; read their provenance notes before any public release |

## After M1

- **M2:** the grammar model (done ahead of time: M2-grammar.md), plus the
  shuangpin and auxiliary-code schemes as data.
- **M3:** Traditional-character output (OpenCC data) and public
  distribution: Developer ID signing, notarization and an installer.
- Until M3 OctoDot has a single user, so builds stay local and are signed
  with your Apple Development identity.
