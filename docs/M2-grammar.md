# M2: the grammar model

Status: done, 2026-11-08. The first M2 task, brought forward from the
roadmap's "a reader for 万象's grammar model".

## Goal

Rank by context. Without a model, every word is scored alone, so the decoder
cannot choose between 萎缩 and 猥琐 after 冰川, or between 分为 and 氛围
after 说好. 万象 publishes a grammar model for librime that does exactly
this. The goal was to read it faithfully and use it the way librime does,
then measure the result against librime's own published numbers on the same
sentences.

## The model

| Fact | Value |
|---|---|
| Source | [RIME-LMDG](https://github.com/amzxyz/RIME-LMDG), release LTS: `wanxiang-lts-zh-hans.gram`, by amzxyz |
| License | CC BY 4.0 (`NOTICE`, `LICENSE-grammar.txt` in the app) |
| Size | 418,080,812 bytes; 63,698,788 character n-grams |
| Format | librime-octagram's: a 44-byte header (`Rime::Grammar/1.0`), then a darts-clone double-array trie |
| Keys | a context of up to 5 characters followed by the start of a word, or a word followed by `$` (how likely it ends a sentence), in octagram's compact encoding |
| Values | ln(score) × 10000; almost all between 13 and 23 |
| Pinning | `data/grammar.lock`, by SHA-256: upstream replaces the file in place under the same name |
| Settings | 万象's, from `wanxiang.schema.yaml` (pinned in `data/wanxiang.lock`): context 6, minimum 2, penalties −14 / −6 / −100 / rear −18, `max_homophones` 8 |

librime-octagram scores a word after its context like this. Starting from
the non-collocation penalty (−6), it tries each suffix of the context's last
5 characters, and each prefix of the word's first 5 characters that follows
that suffix in the trie. It keeps the best of value / 10000 + the collocation
penalty (−14). At the end of the input, it also tries `word$` with the rear
penalty.

## Why mapped, not loaded

The engine reads only its own verified images, built ahead of time, so the
first plan was to convert the model into one. `octo-prep grammar-stats`
reads all 63.7 million n-grams in 30 s and tests whether any can go:

- **By the settings.** A key that can never beat the non-collocation penalty,
  or that no query is long enough to reach, never changes a result. Only
  469 keys are that weak, and 9 that long.
- **By each other.** A key never wins the maximum if a shorter key inside it
  scores at least as much: one with less context, or less of the word, but
  at least one character on each side of the split. That shorter key matches
  whenever this one does. Only 0.05% of keys are covered that way, because
  longer n-grams in this model nearly always score higher.

So no smaller set gives the same scores. Fitting under the IME's 80 MiB
memory gate would mean keeping under 5% of the model.

So the model is used whole, as librime uses it: memory-mapped and read in
place. Mapped read-only, its pages are clean and file-backed. The system can
drop them under pressure, and they are not part of the process's memory
footprint. The bench's day of typing (20,000 commits with the model on) grows
the footprint by 10.3 MiB, as it did without the model.

Goose cannot hold a slice into mapped memory, so the trie walk is the
engine's one piece of C:
- **`engine/gram.h`, about 250 lines.** It is a port of librime-octagram's
  format and Query over darts-clone's units.
- **Bounds-checked.** Every unit is read through one function that checks the
  index against the array's size, so a damaged file gives wrong scores,
  never a read outside the mapping.
- **Compiled into the generated code.** `engine/octo.build` includes it as a
  `static inline` header, so it compiles in the same unit as the engine and
  sees Goose's own slice type.
- **Fuzzed.** The `gram` fuzz target maps arbitrary bytes as a model and
  queries them under ASan, seeded with the real header over 4,096 and
  16,384 units.
- **Checked for privacy.** `tools/check-privacy.sh` rejects any printing or
  logging in it.

## Pipeline

```
data/grammar.lock ──fetch──▶ .data/grammar/wanxiang-lts-zh-hans.gram ──────────┐ (hard link)
wanxiang.schema.yaml ──octo-prep──▶ grammar.tsv ──octo-compile──▶ grammar.img ─┤
                                                                               ▼
                                                          build/images/, the app's data/
```

- **`grammar.img`** is a one-section image (kind 5). It records the model's
  file name and size, which bind the two (a different file is refused), and
  万象's settings.
- **`grammar.goose`** loads the image, hands the settings to `gram.h`, and
  maps `<language>.gram`.
- **`session::open`** maps the model if the images have one. The host can
  turn it on or off at once (ABI v8: `octo_grammar`, `octo_set_grammar`;
  input menu: 语法模型 Grammar Model, remembered). The sandboxed self-test
  fails if the bundle has no model to map.

## The sentence search

With the model on, the sentence is librime's (`Poet`'s beam search and
`ScriptTranslation::Evaluate`):

- **Homophones.** Each span (start, end) offers its 8 best words
  (`max_homophones`). Without a model, a span inside the input keeps only its
  best word, which is all a search without context can use.
- **The beam.** At each position, the best line for each distinct last word
  is kept, and the 7 best lines are extended by every word that starts there.
- **The score.** A word adds its own score plus the model's score given the
  line's last two words. The first word's context is the preceding text,
  which is empty, as in 万象's setup. A word ending the input is queried as
  the rear.
- **No sentence when one word fits.** librime makes no sentence when a
  dictionary word reads the whole input, and neither does OctoDot. A name or
  an idiom typed alone stays the word candidates' business.

One deliberate difference: scale. librime adds the model's score to
ln(weight) − ln(10⁸), with no word penalty. OctoDot adds it to its own word
score, which is log2(weight / total) minus the 6-bit word penalty. Measured
on the 3,392 corpus sentences:

| Per-word offset from OctoDot's score | Sentences right | Characters right |
|---|---|---|
| +3.56 bits (librime's scale) | 60.0% | 89.2% |
| 0 (no word penalty) | 62.8% | 90.8% |
| −3 | 63.5% | 91.2% |
| **−6 (OctoDot's own score, word penalty included)** | **63.5%** | **91.3%** |
| −9 | 63.1% | 91.3% |

The plateau runs from −3 to −6. Adding the model's score to the word score
as it is sits on it and needs no extra constant.

## Speed

Two changes made the beam cheap enough:
- **librime's limit of 8 words per span**, where the first version kept 8 per
  syllable sequence: abbreviations read one span as many.
- **A lookup per line by its last word's text**, where the first version
  scanned every line ending at that position.

The model's answers are also cached by their exact question (context, word,
end of input or not). A key adds one letter, so nearly every pair was scored
for the key before. The cache is a fixed, direct-mapped table: 65,536 slots,
1 MiB, constant time, never grown or emptied mid-search. Equal questions get
equal answers, so it changes no result.

| Typing gates (`make test`) | Without the model | With it |
|---|---|---|
| up to 20 letters, p99 (gate 2 ms) | 1.1 ms | 1.4 ms |
| 21 to 45 letters, abbreviation-heavy, p99 (gate 5 ms) | 2.2 ms | 3.0 ms |
| past a full 64-key composition, p99 (gate 5 ms) | 3.5 ms | 4.6 ms |

The last gate has little headroom. That cost was already high without the
model, and three quarters of it is the word search, not the model. Making
the search incremental, so it reuses the words of the previous key, is the
next speed step.

## Results

`make accuracy`, 万象 v18.1.9 with all lexicon sets, nothing learned.
librime's numbers are rime-schema-compare's, on the same sentences
(zhihu120) or the same corpus (all 3,466 sentences in its report).

| | Without the model | With it | librime with it |
|---|---|---|---|
| zhihu120 (held out), 全拼 | 49.2% / 88.4% | **61.7% / 92.1%** | 60.00% / 92.23% |
| corpus, 3,392 sentences, 全拼 | 54.6% / 90.2% | **63.5% / 91.3%** | 63.85% / 92.47% |
| zhihu120, 小鹤双拼 | 50.0% / 89.5% | **62.5% / 93.3%** | — |
| corpus, 小鹤双拼 | 55.2% / 90.6% | **65.9% / 93.2%** | — |
| common words and idioms (gate 95%) | 99.5% | 99.7% | — |
| names / places typed alone | 78.7% / 89.3% | 79.3% / 89.3% | — |

Each sentence cell is the share of sentences right as a whole, then the
share of characters right.

Without the model, OctoDot matches librime without it (54.6% against
54.33%). With it, OctoDot matches librime on the held-out sentences and
comes within half a point on the corpus. The corpus was used only to choose
the scale; zhihu120 was not used for any choice.

- **Names typed alone barely move.** With nothing before them, the model has
  no context to read, and a name that shares its pinyin with a common word
  stays second. The model fixes names in sentences, and learning fixes them
  alone.
- **`make eval` runs with the model off.** Its phrases are unrelated words
  strung together, which a model of real text rightly reads otherwise:
  77.5% of them first with the model, 96.7% without. It measures the
  context-free layer that the word penalty and learning tune.

## Next

- **Incremental word search**, for headroom on long input.
- **Context from the composition.** `decoder::preceding` is the hook: what was
  chosen earlier in the composition, and perhaps the last commit, kept in
  memory only.
- **The model's version.** Upstream replaces it in place. A new upload fails
  the fetch on its hash; `tools/fetch-pinned.sh data/grammar.lock
  .data/grammar --rehash` takes it after review, and `octo-prep
  grammar-stats` tells whether anything about it changed.
