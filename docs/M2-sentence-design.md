# Sentence accuracy: the root cause, and a design to raise it

Status: proposal, 2026-11-08. It builds on [`M2-grammar.md`](M2-grammar.md).
Section 1 is measured; the rest is the plan, with decisions marked.

## Summary

- **The scoring is the bottleneck, not the search.**
  - In about nine of ten wrong sentences, the right one is in the word
    graph we already build, and our scoring ranks it lower.
  - A search nine times as wide recovers 2 sentences out of 3,392.
- **A better scorer over today's graph has a ceiling of 94.8%** of the
  corpus sentences. We get 63.6% now (全拼; 小鹤 65.8%).
- **The proposal is a second pass.** A small neural language model
  re-reads a pruned copy of the graph after each key, verifying the
  current sentence and correcting it where it is wrong.
  - It runs beside today's decoder, which still answers in under 2 ms.
  - It reads the word graph, not keys, so every input scheme gains.

## 1. Where the misses come from

`make accuracy DIAGNOSE=1` builds the word graph of every missed sentence
again. It finds two paths and scores both exactly as the beam does:
- the best path that spells the right sentence;
- the best path that spells what the engine offered.

It then classifies the miss:

| | What it means |
|---|---|
| graph | no path through the words found spells the right sentence |
| cut | only a word beyond the 8 homophones per span spells it |
| search | the right sentence scores higher; the beam lost it |
| model | the right sentence scores lower; the scoring prefers the wrong one |

| Misses | graph | cut | search | **model** |
|---|---|---|---|---|
| zhihu120, 全拼 (41 diagnosable) | 1 | 0 | 0 | **40** |
| corpus, 全拼 (1,158) | 90 | 10 | 3 | **1,055 (91%)** |
| zhihu120, 小鹤 (45) | 1 | 0 | 0 | **44** |
| corpus, 小鹤 (1,152) | 102 | 8 | 4 | **1,038 (90%)** |

- **Search is not the bottleneck.** A beam of 64 with 32 homophones, nine
  times as wide, gets 2 more sentences right out of 3,392.
- **The ceiling.** Count the corpus sentences already right, plus every model
  and search miss, and a perfect scorer over today's graph reaches **94.8%**.
  We get 63.6%.
- **The wrong sentence wins confidently.** The median margin is 10.4 bits,
  the 90th percentile 30 bits.
  - 形成临时的堤坝 comes out as 行程临时的地步啊.
  - 国道疏通的难度 comes out as 过到死胡同的难度.
  - 持续的雨雾天气也 comes out as 持续的雨雾天企业.

  A fluent reader rejects all three at once.
- **Reranking a short list cannot reach most misses.** The right sentence is
  among the beam's 50 best for only 21% of them, because the beam keeps one
  line per last word, so its list is not diverse. A better scorer has to read
  the graph, not a list.
- **The graph misses** are words 万象 lacks (马竞, 审丑, 唠嗑 split in two), a
  rare character beyond the 8 kept per syllable group, and in the corpus,
  readings that its pypinyin-style derivation got wrong (重绘).

**Graph sizes.** For the 11 to 13 characters of a missed sentence:

| Scheme | Words found | Offered to the beam |
|---|---|---|
| 全拼 | 8,800 | 900 |
| 小鹤 | 340 | 210 |

Full pinyin lets every letter stand as an abbreviation, so its graphs are
25 times larger.

## 2. Why the scoring fails

A sentence today scores as the sum of two local, uncalibrated signals:

1. **万象's word weights.** They count words alone and are sometimes far off
   ordinary usage: 老是 409,258 against 老师 10,767, 发过 63,497 against 法国
   4,521.
2. **万象's grammar model,** read the way librime-octagram reads it. A word
   scores the best match of its first 5 characters after the last 5 of
   context, among stored character n-grams, plus a fixed penalty. That is a
   maximum over matches, not a probability. It has no backoff and no
   normalization, and nothing beyond the two words before.

Neither can see whether a sentence is Chinese as a whole: whether a verb has
its object, or whether 路基 fits a passage about 道路. The errors above are
exactly those.

So this is a modeling limit, not a tuning problem. Another percent might come
from weighting the two signals better (§5, phase 1). The rest of the gap to
94.8% needs a model of the whole sentence, with calibrated probabilities.

## 3. What the state of the art does

- **Neural conversion beats statistical IMEs at sentences.**
  - A frozen Chinese GPT is state of the art on full pinyin and degrades
    on abbreviations; adding pinyin context and a pinyin-constrained
    training loss recovers much of it ([PinyinGPT, ACL
    2022](https://arxiv.org/abs/2203.00249)).
  - A benchmark of LLMs on Chinese and Japanese IME tasks finds the
    strongest models resolve ambiguous input better than traditional IMEs,
    at a real cost in computation ([Zou et al., LREC
    2026](https://aclanthology.org/2026.lrec-1.337/)).
  - Earlier work: [Moon IME](https://arxiv.org/abs/1809.00329), [open
    vocabulary learning for neural pinyin IME](https://arxiv.org/abs/1811.04352),
    [PERT](https://arxiv.org/abs/2205.11737).
- **On-device and real-time is solved in Japanese.** azooKey's Zenzai runs
  zenz, a roughly 90M-parameter GPT-2 conversion model, fully locally through
  llama.cpp. Generating with it alone was too slow for typing, so the
  statistical converter drafts and zenz verifies (speculative decoding),
  which removes most model calls ([zenz model
  card](https://huggingface.co/Miwa-Keita/zenz-v1-checkpoints), [IPA
  report](https://www.ipa.go.jp/jinzai/mitou/it/2024/nl10bi0000006qh1-att/seikashosai-ok-3.pdf)).
- **Making neural conversion cheap.** Yao et al. compute the output layer
  only over the candidates allowed at each step, a hundredfold faster
  softmax that reaches real time on a CPU ([ICLR
  2019](https://arxiv.org/abs/1810.09309)).
- **Rescoring a lattice with a neural LM.** Exact rescoring grows
  exponentially with depth. Merging hypotheses that share their last n
  characters bounds it, and a heuristic search over which histories to keep
  is 4× faster than the standard method and more accurate ([Xu et al.,
  ICASSP 2018](https://www.danielpovey.com/files/2018_icassp_lattice_pruning.pdf)).
  Two refinements help further: keep the best-scoring path when merging, and
  cache the model's outputs by full history ([future word
  contexts](https://arxiv.org/abs/1708.05592)).

## 4. Design: a second pass that verifies and corrects

```
key ─▶ syllable lattice ─▶ word graph ─▶ FIRST PASS (today's beam, n-gram) ─▶ shown at once (≤ 2 ms)
                                │                    │ draft
                                ▼                    ▼
                         P2 prune to Δ ───▶ SECOND PASS (neural LM, background)
                                              P3 verify the draft in one batch
                                              P4 re-decode from the first disagreement
                                              P5 reuse the last key's work
                                                     │
                                                     ▼
                               P6 upgrade the sentence candidate, if still current
```

### 4.1 The scorer

- **The model.** A small causal Transformer over characters (decision below).
  Characters suit pinyin conversion: every word in the graph is a character
  string, and words 万象 lacks can be built from single characters, which
  the model can still judge.
- **The combined score.** A path scores a weighted sum of:
  - the neural log-probability of its characters;
  - today's word score (weight and spelling credibility);
  - the octagram score;
  - the number of words.

  The weights are tuned on the corpus sentences, with zhihu120 held out,
  as the scale was in M2-grammar.md. Today's signals stay for what the
  model lacks: the lexicon's knowledge of real words, and the spelling
  credibilities.
- **Context.** What was chosen earlier in the composition, and the last
  commit, kept in memory only (`decoder::preceding`). That is how a name
  typed alone after 我喜欢 can become 胡适 rather than 护士.

### 4.2 The pruning pipeline

Each stage is measured with the diagnosis above: how many fixable misses
survive it, and what it costs.

| Stage | What it does | Why it is safe or bounded |
|---|---|---|
| P0 | syllable lattice (today) | — |
| P1 | word graph, 8 best per span (today). For the second pass, the single characters per syllable could widen to about 16 | fixes some cut and missing-word misses; measured, since every extra character adds arcs |
| P2 | max-product forward-backward over the first-pass scores: keep an arc only if some path through it is within Δ bits of the best | a correct sentence with margin m survives iff m ≤ Δ. Δ = 40 keeps 95.5% of fixable misses, Δ = 30 keeps 89.7% (measured). Two linear passes. Collapses full pinyin's abbreviation readings |
| P3 | speculative verification: score the draft's characters in one batch, and find the first word boundary where a surviving alternative beats it | about 64% of sentences are already right. For them the second pass is one batch and confirms them |
| P4 | neural beam from that boundary: hypotheses keyed by graph position and last 5 characters, merged keeping the best (Xu; future word contexts); beam 4 to 8; output scored only over the characters the graph allows next (Yao) | work is bounded by beam × the characters left, not by the graph's size |
| P5 | reuse the last key's work: the model's state for the longest common prefix of the new draft (a prefix cache by text), first-pass words for unchanged spans (incremental search) | a key adds one letter, so most of the sentence is already computed. Incremental search is also what long input needs (M2-grammar.md, Speed) |
| P6 | scheduling: the second pass runs in the background with a deadline. Its result replaces the sentence candidate only if the composition is unchanged, it beats the draft by a margin, and the user is not paging or highlighting. A newer key cancels it. On commit, if it is nearly done, wait for it | typing never waits for the model, and the candidate changes at most once per pause |

### 4.3 Latency budget

These targets are measured on the M4. The second pass estimates come from a
30M-parameter model and have to be measured in phase 2:

| | Target | Estimate for a 30M model |
|---|---|---|
| first pass, p99, ≤ 20 letters | ≤ 2 ms (today's gate, unchanged) | 1.4 ms today |
| second pass, key → upgraded candidate, p95 | ≤ 25 ms | P3: one batch of about 13 characters, under 2 ms. P4: about 6 hypotheses × 13 steps, about 4 ms |
| second pass, p99 | ≤ 40 ms | — |
| memory footprint | ≤ 80 MiB (unchanged) | weights memory-mapped, as the grammar model is; model state about 1 MiB per hypothesis |

People notice delays above about 50 ms. A first answer in 2 ms and an
occasional correction within 25 ms reads as instant. A 0.5B-parameter model
would take about 60 ms or more, which is why the production model should be
small.

### 4.4 What each input scheme gains

The second pass reads the word graph, which every scheme builds the same way
with its constraints already applied. 全拼, 小鹤, abbreviations, tone keys,
shape codes and custom phrases all gain, and so does any scheme added later.

Abbreviated input should gain most: its graphs are largest, and its n-gram
signal weakest. That is also where PinyinGPT found a GPT alone breaks down,
which P2's lattice keeps from happening.

### 4.5 Runtime (decision)

| Option | For | Against |
|---|---|---|
| **a. C inference in the engine**, like gram.h, with Accelerate | the harnesses (accuracy, typing, fuzz) measure and fuzz it headless; no new dependency | a small Transformer to write and keep (a few hundred lines) |
| b. Core ML stateful model in the Swift host | the Neural Engine; lowest power | outside the engine: the headless harnesses cannot measure it; a second language for decoding |
| c. ggml / llama.cpp (MIT) through the package sidecar | proven; GGUF weights memory-mapped; Metal or Accelerate; what Zenzai uses | a large dependency inside a privacy-first IME |

Recommendation: prototype on c to measure, then ship a when the model's
shape is settled. a keeps decoding in one place, where every gate already
measures it.

### 4.6 The model (decision)

1. **Measure the ceiling first, offline.** An open Chinese LM rescores the
   corpus's pruned graphs through P2 to P4. Qwen2.5-0.5B (Apache-2.0) is
   one candidate. This tells how much of the 31 points a strong model
   recovers, and at what Δ. It needs Python ML tooling in a scratch
   environment and a model of about 1 GB downloaded; the disk has 30 GB
   free.
2. **Then the production model.** A small model of 20 to 60M parameters,
   trained on open text or distilled from the strong model with MLX on the
   M4. The choice comes from the measured curve of accuracy against latency.
   Corpus licenses decide what it can be trained on.

### 4.7 Acceptance

- **Corpus sentences:** at least 75% right as a whole (stretch: 80%), and at
  least 95% of characters, in 全拼 and 小鹤. zhihu120 reported held out.
- **Unchanged:** the common words and idioms gate, and every latency and
  memory gate, plus the second pass's own latency gates above.
- **Fuzzed:** the model loader and the scorer, as every loader is.

## 5. Phases

1. **Measure and tighten the current decoder** (days):
   - P2 pruning in the engine, with its retention measured;
   - context from earlier choices;
   - weights for the existing signals tuned on the corpus.

   Expected: one to three points, and the pruned graphs the second pass
   needs.
2. **The neural ceiling, offline:** an open model over the pruned graphs.
   This decides whether to go on, and the model's size.
3. **The model:** train or distill the small character model.
4. **The second pass in the engine:** P3 to P6, its gates, and fuzzing.
5. **Incremental word search:** P5's first half, and headroom on long
   input.

## Phase 1 results (2026-11-08)

- **P2 is in the engine (`decoder::prune`) and keeps the right sentence.**
  Pruning by the words' own scores keeps it for 98.0% of fixable corpus
  misses at Δ = 20 bits, and 99.7% at Δ = 30:

  | Δ | Right sentence kept | Words left, 全拼 | Words left, 小鹤 |
  |---|---|---|---|
  | 20 bits | 98.0% | 150 (of 8,800 found) | 88 (of 340) |
  | 30 bits | 99.7% | 616 | 151 |

  So the second pass reads graphs of about 100 to 150 words.
- **Context does nothing for the current scorer.** The harness option
  `--chained` types each corpus clause after the previous one, with its
  comma. Results are identical to no context, because octagram holds no
  n-grams across a clause break. Context is left to the neural pass.
- **Re-weighting is not a robust gain.** A grammar weight of 0.6 raises
  corpus characters in 全拼 from 91.3% to 92.3%. But it loses 4 held-out
  sentences in 全拼, and does worse in 小鹤 on both sets. The weight stays
  at 1.0 (`decoder::fit_weight`).

Next: phase 2, the offline neural ceiling over P2's graphs.

## Revision: emit, decode, verify (replaces P3 and P4)

P4 as first written runs a step-by-step neural beam: about 6 hypotheses
over 13 steps. On a CPU that is memory-bound, because every step streams
all the model's weights again for a handful of tokens.
- **The better shape is few, wide passes.** Score many tokens per pass, as
  SpecInfer and Medusa do with tree attention: a token tree, a mask that lets
  each token see only its ancestors, and one forward pass for every branch
  ([SpecInfer](https://arxiv.org/pdf/2305.09781),
  [Medusa](https://arxiv.org/html/2401.10774v3)).
- **But a pruned graph does not fold into a small tree.** A causal model's
  state depends on the whole prefix, so a token tree has to copy everything
  after two paths merge. Measured at Δ = 20 bits on the corpus misses:

  | Words offered to the beam | Full paths, median | p90 | Tree tokens for all of them, median |
  |---|---|---|---|
  | 全拼 | about 1 million | about 2 × 10¹⁰ | about 1.9 million |
  | 小鹤 | about 0.8 million | about 3 × 10¹⁰ | about 1.7 million |

  Only the K best paths fit in a tree. Choosing them is a job for the scorer
  the diagnosis found wrong: the right sentence is among the beam's 50 best
  for 21% of misses.
- **What can read a DAG in one pass is a bidirectional model.** Without a
  causal mask, a token's state does not depend on its path, so nothing
  multiplies. FLAT does this for Chinese NER, flattening a character-word
  lattice into spans with relative positions
  ([FLAT, ACL 2020](https://arxiv.org/abs/2004.11795)).

So the second pass becomes two wide forward passes around the cheap, exact
search that already works:

1. **Emit (one bidirectional pass, about 20 to 60 tokens).** A
   non-autoregressive pinyin encoder reads the syllables of the first
   pass's segmentation, and the preceding text when there is any. It gives
   each syllable a distribution over characters. That is PERT's design: a
   Transformer over pinyin trained directly on pinyin-character pairs, and
   stronger still combined with an n-gram model
   ([PERT](https://arxiv.org/abs/2205.11737)).
   - **Why it fits pinyin.** One character per syllable makes the output as
     long as the input, so no generation loop is needed. The encoder sees
     the right context too, which a causal model scoring paths left to right
     cannot.
   - **The output layer stays small.** It scores only the characters the
     pruned graph allows at each syllable (Yao et al.).
   - **Segmentations.** When full pinyin's two best segmentations differ
     (xian, xi'an), both go in as a batch of two, still one pass.
   - **Abbreviations.** An initial alone is its own input token. Training
     abbreviates at random, which is PinyinGPT's lesson.
2. **Decode (CPU, exact, about 0.2 ms).** Today's beam over the P2-pruned
   graph. Each word now also scores its characters' emissions, beside its
   own score, the octagram score and the word count, with weights tuned on
   the corpus. The graph stays a DAG of 100 to 150 words. The diagnosis
   showed this search loses almost nothing (3 of 1,158 misses).
3. **Verify (one causal pass with tree attention, about 100 to 150 tokens).**
   The decode's K best distinct sentences (K about 8 to 16) are folded into a
   token tree by shared prefix. A small character LM scores them all in one
   forward pass, with the ancestor mask, after the preceding text (its state
   cached across keys). The final ranking interpolates the two scores. This
   adds what emissions lack: dependencies between the chosen characters.
   K is small now because the decode already uses the emissions, so the
   right sentence should be among its first few. That has to be measured.

| Budget, 20M-parameter models on the M4 | Estimate |
|---|---|
| emit: 20 to 60 tokens, one pass | about 1 ms |
| decode | about 0.2 ms |
| verify: about 150 tokens, one pass | 2 to 3 ms (about 6 GFLOP at AMX fp16 rates) |
| total | about 3 to 4 ms |

At about 4 ms the second pass can run within the keystroke itself, for
typical input. The candidate shown is then already the corrected one, with
no swap and no flicker. P6's background scheduling remains, but only as the
fallback for long input.

Both models train on text alone. Any Chinese text, read with phrase-pinyin-
data and 万象's readings and abbreviated at random, gives pinyin-character
pairs for the encoder and plain text for the verifier. Neither depends on
the input scheme or the lexicon's version.

A FLAT-style lattice encoder is the next step if emissions fall short. It
would read the pruned graph's words as spans and score each word directly:
about 160 tokens, one pass. It is stronger, because it sees the candidate
words, but it is bound to this decoder: its training graphs come from the
engine, and change with it.

**Phase 2, revised.**
- **Emit:** train a small encoder with MLX on open text, and measure
  emit + decode on the corpus.
- **Verify:** measure an open model (Qwen2.5-0.5B) over the decode's top K,
  as the verifier's ceiling.
- **K:** measure how often the right sentence is in the decode's top K.
