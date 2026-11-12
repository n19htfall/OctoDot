# The reranker

Status: built, 2026-11-09. On by default when the images hold a model.

## Summary

- **What it does.** The decoder's sentence search finds the right sentence
  among its 16 best far more often than it ranks it first (87% against 66%
  of corpus sentences, in 小鹤双拼). A small character-level language model,
  trained by OctoDot, scores those 16, and the best by
  `search score + 2.25 × log2 P(<s> text </s>)` goes first.
- **What it gains**, measured by the accuracy harness on the shipped images:

  | | 小鹤双拼 | 全拼 |
  |---|---|---|
  | hotlist (3,392 sentences) | 65.8% → **73.4%** | 63.6% → **71.8%** |
  | zhihu120 (120, never used for tuning) | 62.5% → **75.8%** | 61.7% → **76.7%** |

  For comparison, Qwen2.5-0.5B choosing among the same 16 reached 75.7% and
  75.0% on hotlist, at 36 times the size.
- **What it costs.** The key itself does not wait: it returns, and its
  preedit is shown, as before (p99 0.9 ms). The candidates wait for the
  reranker and are shown once, already reranked: the decoder's order is
  never on screen, so nothing switches. From the key to them takes 3.6 ms
  at the median and 6.2 ms at the 99th percentile (typing test, 全拼, with
  prefix states kept across keys). The shortlist's search is 0.23 ms mean,
  0.64 ms p99 in 小鹤双拼 (2.2 and 5.6 ms in 全拼). 55 MB of weights,
  memory-mapped, so not part of the IME's memory footprint. The prefix
  cache is separate and capped at 8 MiB; a composition of ordinary length
  uses about 1.5 MiB.
- **What it never overrides**: a sentence the user chose for these keys
  before, English placed first, a custom phrase, a whole-input word, or a
  menu the user has started to move through.

## 1. The model

A GPT-2-shaped causal Transformer over characters: 6 layers, 384 wide,
6 heads, learned positions (42), pre-norm LayerNorm, exact GELU, the output
tied to the input embedding; 13.7M parameters, 8,000 characters (the most
frequent in its data) plus `<unk>`, `<s>`, `</s>`. OctoDot trained it on
clauses (runs of 2 to 40 ideographs) of FineWeb-2's Mandarin web text
(ODC-By 1.0; NOTICE), with every sentence of the accuracy set left out:
5.79 bits per character on held-out clauses. The weights are released
(`data/rerank.lock`) under CC BY-NC-SA 4.0 (`LICENSE-weights`); the
training code is not part of this repository.

The weight, 2.25, is chosen on hotlist alone by 2-fold cross-validation;
zhihu120 is scored once, at that weight.

## 2. Files

| File | From | What it is |
|---|---|---|
| `rerank.weights` | the released model | the tensors as float32, after a header of the shape ("OLM1"); memory-mapped by `engine/rerank.h` |
| `rerank.tsv` | the released model | the shape, the weights' size, the weight, the shortlist's search, the characters |
| `rerank.img` | `octo-compile --rerank` | `rerank.tsv` as a verified image (kind 7), loaded by `engine/rerank.goose` |
| `rerank.check.tsv` | the released model | the trained model's scores for 11 sentences, which the images test checks the engine against (not shipped) |

`make fetch` (part of `make`) puts the released model's three files in
`.data/rerank`, each checked against its SHA-256 in `data/rerank.lock`;
`make images` then builds `rerank.img` and links the weights beside it. A
new model is a new release of the three files and a new lock. The engine
also runs without them: images with no reranker work as before.

As with the grammar model, nothing in the weights file is trusted: opening
checks its header against `rerank.img` and its size against the header, so
every tensor lies inside the mapping, and scoring checks every id and
length it is given. A damaged file gives wrong scores (NaN is refused),
never a read outside it. Both are fuzzed (`fuzz-rerank`,
`fuzz-rerank-weights`, under ASan and UBSan).

## 3. Engine

- **`engine/rerank.h`**, the second piece of the engine in C after
  `gram.h`: the forward pass. The dense layers are Accelerate's sgemm
  (through `engine/blas.c`, compiled apart so the engine links libcblas).
  The candidates of a shortlist mostly share their start (一家三口后部车票,
  一家三口候补车票), and the model looks only backward, so each distinct
  start is computed once, as a trie node: 40% of the characters. GELU's erf
  and the softmax's exp are polynomials that vectorize; libm's took more
  than half the time. The engine's scores match the trained model's within 0.001 bits.
- **`engine/rerank.goose`**: the image, mapping the weights, turning text
  into ids, scoring a shortlist, and the choice (`best`).
- **`decoder::shortlist`**: the 16 best distinct sentences of a K-best
  search (8 lines kept per position and last word, beam 64), with the words
  each is made of, so a reranked sentence teaches like any other.
- **The session**:
  1. a key builds the menu as before, and says `PENDING` if the reranker
     may change its first candidate (`rerankable`);
  2. the host calls `refine` before it shows the candidates: the shortlist
     from the menu's words, kept from the key, is scored and the best put
     first. The decoder's sentence stays, second. Nothing if a newer key
     built another menu, or the user moved the highlight or the page.

  The tests and the accuracy harness set `rerank_sync`, which reranks in
  the key itself.

  (A first version scored on a worker thread and showed the decoder's
  menu until the score came, a few milliseconds later; the candidates
  visibly reordered. Showing them only once reranked needs no worker: the
  main thread waits for the score either way.)

  Inside one composition the next shortlist repeats most of the previous
  one's prefixes, so `rerank_now` (both the host's `refine` and
  `rerank_sync`) keeps the trie of the last score that produced usable
  bits. A node is the token-id path from `<s>`. The next call walks that
  path parent then token; a miss drops the whole branch, even when the
  same character sits at the same depth under another parent. `<unk>` is
  an id like any other. Each kept node stores, per layer, K and V after
  the bias, then the final LayerNorm vector and `lse = logsumexp` over
  the vocabulary. A hit does not run the layer. Its next-token log
  probability is one dot product, `dot(h, embedding[next]) - lse`, so
  「一家三口」 followed by `</s>` and the same prefix followed by 「候」 share
  the node and not the edge. Both entries call one forward. A cold score
  puts every trie row in the batch; an incremental score puts only the
  misses, and attention reads a hit ancestor's K and V from its slot.
  The output projection and the `<s>`-to-`</s>` sum are that same
  function. An all-hit call skips the forward and the vocabulary matrix.

  The resident budget is 8 MiB, including the trie index (token, parent,
  first child, sibling: 16 bytes). The floats per slot are
  `4 × (2 × layers × dims + dims + 1)`: 19,972 bytes on the released
  model, 19,988 with the index, 419 slots. The block grows to the trie
  just scored, and a slot whose branch left the trie is reused on the
  next one. A trie that does not fit is scored cold and the published
  trie is dropped, leaving the block for a smaller job. If the block
  itself or a forward workspace cannot be allocated, the block is
  released before that cold score. Slots are addressed by index, so growing the block does not
  leave a stale pointer. Writes begin only after the new trie's slots are
  reserved, so a new branch cannot overwrite a node that a later row
  still matches. A failure after a write drops the whole trie.

  `octo_rerank_score` keeps no trie. It is what `rerank::score` and a raw
  request whose first id is not `<s>` call, and it accepts that wider input.
  SGEMM batch size and the single dot product move a candidate by well
  under 0.001 bits on the released model (7.6e-6 bits on the 11 training
  sentences, all hits; a cold start through the cache matched the cold
  score bit for bit on the synthetic pair). When a cached score was
  actually used and the top two weighted totals are within
  `2 × |weight| × 0.001` (0.0045 at weight 2.25), the same job is scored
  cold and the earlier candidate still wins a tie. An unusable incremental
  score is decided the same way. The cache is cleared in constant time
  when the composition ends (commit, Escape, scheme change, client
  change, reset, releasing the active session, or Backspace of the last
  key). Turning the reranker off, `trim`, and closing or reopening the
  model free the block. `trim` leaves the pending menu; the next `refine`
  scores it cold.

The search the scores were tuned on kept 16 lines per state, beam 256: on
the main thread in 全拼 that took 8.9 ms mean, 20.8 ms at the 99th
percentile. 8 and 64 take a quarter of that, and lose 0.3 (小鹤双拼) and
0.2 (全拼) points of the gain:

| per state, beam | 小鹤 hotlist | search, 小鹤 (mean, p99) | 全拼 hotlist | search, 全拼 |
|---|---|---|---|---|
| 16, 256 | 73.7% | 0.70, 2.16 ms | 72.0% | 8.88, 20.75 ms |
| **8, 64** | **73.4%** | **0.23, 0.64 ms** | **71.8%** | **2.22, 5.56 ms** |
| 4, 32 | 72.9% | 0.11, 0.30 ms | 70.9% | 1.02, 2.65 ms |
| 2, 16 | 71.0% | 0.06, 0.16 ms | 68.7% | 0.55, 1.41 ms |

## 4. Host

- `octo_key`'s result has bit 8 (`PENDING`) when the reranker may change
  the menu. The handler shows the commit and the preedit at once, and the
  candidates on the next turn of the run loop, after `octo_refine` (its
  snapshot if it says `DIRTY`, else the key's). A key that comes first
  settles it: the menu is reranked before that key acts on it, so Space
  picks what would have been shown. (ABI 12.)
- The IME uses the sentence model whenever its weights are available.
- The sandboxed self-test reports that the weights map inside the sandbox.

## 5. Tests

- **images test**: `rerank.img` verifies and the weights map; the forward
  pass reproduces the trained model's scores for `rerank.check.tsv` (11
  sentences, max 0.000021 bits from the trained model); a truncated image
  and weights of another size are refused. The same sentences scored again
  from the cache match the cold score within 0.000008 bits, with every
  node a hit and no forward or vocabulary row. Consecutive jobs check the
  counters, not only the bits: A `[1,3,4,2] [1,3,5,2]` is 4 cold nodes; B
  `[1,3,4,6,2] [1,3,7,2]` has 5 nodes and 3 hits, and the edge out of
  `[1,3,4]` changes from `</s>` to 6; B again is all hits; A after B
  recomputes the dropped 5. Also candidate order, the same token under
  another parent, `<unk>`, the position limit, a trie over a test budget,
  a failed allocation, and a near tie that is scored cold and still keeps
  the earlier candidate.
- **typing test**: off, nothing is pending; `rerank_sync` puts
  一家三口候补车票 first over the decoder's 一家三口后部车票; through
  `refine` as the host calls it, once; Space commits it and it is learned;
  `refine` reranks the latest key's menu, and leaves alone one the user
  moved through; a sentence the user chose stays first. The same keystrokes
  with the cache off and on agree: `refine`, `rerank_sync`, Backspace,
  turning the model off and on, a client switch and reset, in 全拼 and
  小鹤双拼. The first score of a composition is cold. `trim` drops a warm
  cache and the pending menu still reranks. The time from a key to its
  reranked candidates is reported beside the key latency gates.
- **smoke test**: the same, through the Swift API the IME uses.
- **accuracy harness**: reranks by default (`--no-rerank` for the decoder
  alone); `--time-rerank` reports both costs; `--rerank-search=P,B` tries
  another search.
- **fuzzing**: both files, with UBSan's reports now fatal (the first run
  found NaN converted to int in the vectorized exp, from damaged weights).
  The weights target also scores one mapping several times through the
  cache (a changed branch, bad ids and offsets, clear, close and reopen).
  Reopening a model of the same shape does not reuse the previous model's
  nodes.

Measured on this machine, release build, incremental before cold so a
warm CPU does not favor the cache. Each sentence starts a new composition;
inside it, keys are sent as the host sends them and `refine` runs when
the key says `PENDING`, including a mistype and Backspace.

| | 全拼 incremental | 全拼 cold | 小鹤 incremental | 小鹤 cold |
|---|---|---|---|---|
| key p50 / p99 | 0.343 / 0.903 ms | 0.349 / 0.911 ms | 0.058 / 0.115 ms | 0.057 / 0.116 ms |
| key → refine p50 / p99 | 3.276 / 5.246 ms | 3.689 / 6.390 ms | 2.396 / 3.208 ms | 2.668 / 4.055 ms |
| score p50 / p99 | 2.342 / 3.372 ms | 3.211 / 5.071 ms | 2.261 / 3.111 ms | 3.204 / 3.805 ms |
| prefix hits | 3567 / 7692 (46%) | — | 2700 / 5586 (48%) | — |
| forward rows, vocabulary rows | 4125, 4125 | every row | 2886, 2886 | every row |
| full rescores | 0 | 0 | 0 | 0 |
| cache peak | 1542 KiB | 0 | 1112 KiB | 0 |

The typing test's own 全拼 sample (the same one as before this cache) is
0.347 / 0.873 ms for the key and 3.598 / 6.212 ms from the key to the
reranked candidates. A long 全拼 clause, one composition, hit 3150 / 5140
nodes (61%); its first score was 2.6 ms and the cache peaked at 2108 KiB.
Key latency gates still hold (p99 ≤ 2 ms up to 20 letters, ≤ 5 ms after).

## 6. Later

- **Learning**: a reranked sentence the user commits is learned as a
  choice, so the decoder ranks it first itself next time.
- **Context**: the model scores each sentence alone. It could read the
  text before it in the composition (`decoder::preceding`).
- **Size**: 8-bit weights would halve the file; the matrix products would
  need another kernel than sgemm.
