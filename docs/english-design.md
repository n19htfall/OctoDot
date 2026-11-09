# English words while typing Chinese

Status: phases 1 and 2 built, 2026-11-09 (section 7). Decisions are
marked.

## Summary

- **English words become candidates, not a mode.** OctoDot has no English
  mode, and should not get one back. Typing `hello` offers `hello` beside
  the Chinese, and picking it commits it, as any candidate.
- **The data is 万象's own English dictionary** (`dicts/en.dict.yaml`, 73,165
  words and terms with frequencies, CC-BY-4.0, the license OctoDot already
  complies with for 万象).
- **The hard part is placement, not lookup.** The same letters are Chinese
  and English at once, so the first candidate stays Chinese unless there is
  evidence for English: no Chinese reading at all, a capital typed, or the
  user picking that English word before.
- **Phase 2 mixes the two in one sentence** (`woyonggithub` → 我用GitHub), by
  making English words one more source of words in the word graph.
- **Chinese accuracy is the gate.** The accuracy harness must not move, and
  no corpus sentence may get an English word first.

## 1. The data

| Source | Size | License | Verdict |
|---|---|---|---|
| **万象 `dicts/en.dict.yaml`** | 73,165 entries, weighted | CC-BY-4.0 | **Use it** |
| rime-ice `en_dicts/` | 370 KB + extensions | GPL-3.0 | No: GPL |
| Melt English (`melt_eng`) | 120 KB | Apache-2.0 | Fallback: much smaller |

万象's file, read on 2026-11-09:
- Lines are `text \t code \t weight`: `abandon	abandon	1002`.
- 1,730 multi-word terms, typed without spaces: `GitHub Copilot` is
  `githubcopilot`.
- 9,786 forms with capitals, often case variants of one word: `in`, `In`,
  `IN`; proper nouns and brands in their own case: `GitHub`, `Aaron`.
- Weights run from 1 to 4,709,228 (`the`); the median is 32.
- No mixed Chinese–English entries (`A股`, `T恤`). Those belong to the
  Chinese lexicon.

**Decision:** pin the file in `data/wanxiang.lock` and
`tools/fetch-wanxiang.sh` with its SHA-256, like the Chinese dictionaries,
and credit it under the existing `LICENSE-wanxiang.txt`.

**No plurals, no third-person -s.** (Decided 2026-11-09.) One types an
English word for its lemma, so `octo-prep` leaves out plural nouns and
verbs' third-person -s forms: `changes`, `cars`, `children`, `goes`, `is`.
It knows them from AGID, SCOWL's inflection database (`data/agid.lock`;
MIT-style license, read at build time only, nothing of it in the app). A
lowercase form goes when all three hold:
- AGID lists it as a plural or an -s form, with a part of speech it is sure
  of (forms it tags as only "a slight chance" do not count);
- AGID does not list it as a lemma itself: `news`, `series`, `his`, `us`,
  `yes`, `people` stay;
- its base is in real use, with at least a quarter of its weight: forms that
  outgrew a rare base stay (`data`, from datum; `physics`, from physic).

`its` stays by name (AGID files it as the plural of the noun "it"). A
capitalized form is a name and always stays: `windows` goes, `Windows`
stays. A lowercase phrase goes with its last word (`best practices`).
Past tenses and -ing forms stay. 9,101 forms go, leaving 63,153 codes.

**The image.** `octo-prep` builds `english.img`, verified at load like
every image:
- one entry per **code**: the letters, lowercased, without spaces;
- for each code, its forms by weight (`in` → `in`, `In`, `IN`), and a score:
  log2 of the summed weight;
- codes sorted, so an exact match and a prefix's range are binary searches.

About 3.9 MB (63,153 codes). A fuzz target loads it from random bytes, as
for the others.

## 2. The ambiguity, and how candidates are placed

The keys alone rarely say "this is English":
- **Full pinyin** reads abbreviations (`z g r`), so almost any letter string
  has a complete Chinese reading. Only a few cannot be read at all
  (`github`: no syllable starts `gi`).
- **小鹤双拼** reads nearly every pair of letters as a syllable, so nearly
  every English word also spells a Chinese sentence.

So English is placed by evidence, in this order. **Decision:**
1. **No complete Chinese reading** of the whole input: the English exact
   match comes first, then completions, then the partial Chinese.
2. **A capital typed** (Shift with the first letter, `Github`): English is
   meant, so English comes first. The typed case wins over the
   dictionary's when the word is plain lowercase there (`Hello`); a
   dictionary form with inner capitals wins over all-lowercase typing
   (`iphone` → `iPhone`, `nasa` → `NASA`).
3. **Learned:** an English word the user picked for this code before ranks
   by its uses, like a Chinese choice, and can reach first place. Type
   `github` and pick `GitHub` twice, and it comes first from then on.
4. **A Chinese reading of nonsense** (decided 2026-11-09): the exact match
   comes first when the best Chinese reading is 2^25 times less likely
   than the English word (log2 probabilities, each within its own
   dictionary): `development` in 小鹤双拼 reads 的这螺片蒽酮, `hello` in full
   pinyin 和来咯. Not when the user picked that Chinese for these letters
   before. Measured on every lexicon word whose keys spell an English word:
   none, of any weight, falls 25 bits behind, in either scheme (the
   farthest common one, 忘恩 for `when` in 小鹤, 21.4). It brings 1,764 of
   the 2,000 most frequent words first in 小鹤, 1,591 in full pinyin, and
   no corpus sentence, whole or half typed (to a syllable's end, 34,000 per
   scheme), gets an English word first. Completions then follow it.
5. **Otherwise the first candidate stays Chinese.** An exact English match
   goes second if the word is common (score above a threshold set on the
   test lists, section 6).
6. **Completions** (`progra` → `program`, `programming`): from 4 letters on,
   at most two, after the third candidate.

The neural reranker (`docs/rerank-design.md`) only reorders Chinese
sentences. English candidates are placed by the rules above, after it.

**Later refinement:** rule 4 compares the English word with the decoder's
best Chinese reading by a fixed margin; a calibrated comparison could also
replace rule 5's common-word threshold, and weigh an English word at the
head of a longer input (`developmentzenmeyang`), which today is read as
Chinese wherever Chinese reads the keys.

## 3. Engine

- **`engine/english.goose`:** loads `english.img`. `exact(code)` gives the
  forms. `completions(prefix, n)` gives the n best words starting with
  `prefix`: a binary search, then a scan of the range, capped.
- **Candidate kinds.** Candidates are Chinese words today, carrying
  references to the words they are made of, for learning. An English
  candidate carries its text and its code, and no word references.
- **The menu.** `session::rebuild` asks the decoder for the Chinese menu as
  now, then places English candidates into it (section 2).
- **Committing** an English candidate inserts its text. **Decision:** no
  space is added by default. A setting adds one between consecutive
  English words.
- **Learning.** The user dictionary gets a third section, `english: code \t
  text \t uses \t day`, saved and sealed with the rest, with the same
  decay, the same `#base` lines, and the same forgetting (15 minutes,
  today, everything). Incognito and password fields learn nothing, as now.
- **ABI.** `octo_set_english(on)` turns English candidates on or off. The
  snapshot does not change: candidates are text.

## 4. Phase 2: mixed sentences

`woyonggithub` → 我用GitHub, one candidate, one commit:
- **English words as a source in the word graph.** Every span of the input
  that is an English code of 3 or more letters becomes a word in the graph.
  Its score is its English score, less a fixed penalty for switching
  language, so the sentence search weighs it against Chinese readings of
  the same keys.
- **The grammar model** sees it as an unknown word, as it would see a name.
- **小鹤双拼:** an English span may start in the middle of a key pair.
  Allowed, since the English reading is of the raw letters; to be measured.
- Ships only if the Chinese gate holds, measured on a set of mixed
  sentences built for it.

## 5. Host

- **Settings → Input:** "英文单词 English words" (on by default), and "Space
  after English words" (off).
- **The candidate window** needs nothing: Latin text renders in the same
  system font.
- **Privacy:** all offline. English learning lives in the sealed user
  dictionary, like the rest.

## 6. Measuring

- **Chinese does not regress.** The accuracy harness gives the same numbers
  with English on (today 63.6% full pinyin, 65.8% 小鹤), and a new count,
  "corpus sentences with an English word first", stays 0. **Gate.**
- **English is found.** A test list: the 2,000 most frequent words, and 300
  terms people type in Chinese text (GitHub, iPhone, NASA, Python, ok, bug).
  For each, typed exactly in both schemes: the English word's rank.
  **Gate:** on the first page for 99%, first whenever rule 1 or 2 applies.
- **Speed.** The English lookup adds under 50 µs per key.

## 7. Plan

1. **Phase 1:** the data, `english.img`, exact matches and completions,
   placement rules 1–6, learning, the setting, and both test sets, with
   the gates.
2. **Phase 2:** English words in the word graph, for mixed sentences,
   behind the same gates.
3. **Later:** the calibrated placement (section 2); tolerance for typos.
