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
  never on screen, so nothing switches. From the key to them takes 4.2 ms
  at the median and 8.5 ms at the 99th percentile (typing test, 全拼),
  within a frame. The shortlist's search is 0.23 ms mean, 0.64 ms p99 in
  小鹤双拼 (2.2 and 5.6 ms in 全拼); scoring, 4.2 ms mean, 8 ms p99. 55 MB
  of weights, memory-mapped, so not part of the IME's memory footprint.
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
- Settings → Input: "整句模型 Sentence model", on unless turned off; shown
  only when the images hold a model.
- The sandboxed self-test reports that the weights map inside the sandbox.

## 5. Tests

- **images test**: `rerank.img` verifies and the weights map; the forward
  pass reproduces the trained model's scores for `rerank.check.tsv`; a truncated image
  and weights of another size are refused.
- **typing test**: off, nothing is pending; `rerank_sync` puts
  一家三口候补车票 first over the decoder's 一家三口后部车票; through
  `refine` as the host calls it, once; Space commits it and it is learned;
  `refine` reranks the latest key's menu, and leaves alone one the user
  moved through; a sentence the user chose stays first. The time from a key
  to its reranked candidates is reported beside the key latency gates.
- **smoke test**: the same, through the Swift API the IME uses.
- **accuracy harness**: reranks by default (`--no-rerank` for the decoder
  alone); `--time-rerank` reports both costs; `--rerank-search=P,B` tries
  another search.
- **fuzzing**: both files, with UBSan's reports now fatal (the first run
  found NaN converted to int in the vectorized exp, from damaged weights).

## 6. Later

- **Learning**: a reranked sentence the user commits is learned as a
  choice, so the decoder ranks it first itself next time.
- **Context**: the model scores each sentence alone. It could read the
  text before it in the composition (`decoder::preceding`).
- **Incremental scoring**: each key repeats most of the previous key's
  starts; caching their states across keys would cut most of the scoring.
- **Size**: 8-bit weights would halve the file; the matrix products would
  need another kernel than sgemm.
