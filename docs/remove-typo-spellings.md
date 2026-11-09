# Removing typo spellings (万象's 容错): a guide for the implementing agent

Status: implemented 2026-11-09. The behavior is removed; it is not an option.

## 1. What it is, and why it goes

Typing `ziheng` shows the preedit `zih eng` and offers 只嗯, 知恩, 之恩 first.
`zih` is read as zhi. That is not a separate auto-correct feature: it is 38
rules inside 万象's **全拼** spelling rules (`base/全拼` in
`wanxiang_algebra.yaml`) that spell common slips as if they were correct:
`zih`/`hzi` for zhi, `nag`/`agn` for ang, `zhogn` for zhong, `wia` for wai,
`ten` for teng, and so on.

`octo-prep` evaluates those rules like every other, and each typo becomes a
**NORMAL** spelling with **no penalty** (the rules are written as `derive`),
so the engine trusts `zih` exactly as much as `zhi`. Real readings of the
same keys (zi + h…, 自豪, 孩子) lose to the typo reading. The owner finds
this terrible; it goes.

Facts to rely on (checked against 万象 v18.1.9, the release pinned in
`data/wanxiang.lock`):

- Only **全拼** has them. 小鹤双拼's rules (`base/小鹤双拼`) have none; its
  table must come out byte for byte the same.
- The block is the 38 `derive` rules in `base/全拼` right after
  `derive/(.+)(\d)/$1/` (which strips tone digits: **keep that one**),
  through `derive/([tl])eng$/$1en/`. The exact list is in the appendix.
  (`derive/([zcs])h([aeiu])$/$1$2h/` appears again further down the file,
  under `lite:`; OctoDot does not read that section.)
- The spelling tables' `correction` column (and `Row.correction` in
  `engine/spelling.goose`) is **unrelated**: it is librime's corrector flag,
  always 0 in OctoDot's data. Leave it alone.
- Fuzzy pinyin (`docs/fuzzy-pinyin.md`) is unrelated too: its groups are
  separate rule blocks (`模糊音_*`), evaluated before the scheme's rules.

## 2. The change

Drop the 38 rules in `octo-prep`, from a pinned list, so the dropped set is
explicit, reviewed, and fails loudly if 万象 changes it.

1. **The list.** Create `data/wanxiang-typo-rules.txt`: a header of `#`
   comment lines (what it is, that `octo-prep` drops these rules from the
   schemes' rule lists, the date and 万象 release it was checked against,
   and that a `make relock` to a 万象 release that changes them must update
   it), then the 38 rules from the appendix, one per line, exactly as
   written there (the YAML value: no leading `- `, no trailing `# comment`).

2. **`octo-prep`.**
   - `tools/octo-prep/Sources/OctoPrep/Prep.swift`: add to `PrepOptions`
     `public var droppedRules: String?` (the list's path). In `prepare`,
     read it (skip blank and `#` lines) into a set. When building each
     scheme's rules (`let rules = try fuzzyRules + formulas.map(Rule.init)`),
     filter out the formulas in the set. Do **not** drop anything from the
     fuzzy groups.
   - Fail if any listed rule was found in **no** scheme's rule list
     (`throw AlgebraError(description: "data/wanxiang-typo-rules.txt names a rule 万象's algebra no longer has: …; review the list")`):
     a 万象 update that rewrites a typo rule must not slip through
     silently.
   - Report it: add `droppedRules: Int?` to `Report.Spellings` (how many
     rules were left out of that scheme), and print it with the spellings
     line.
   - `tools/octo-prep/Sources/octo-prep/main.swift`: read `--drop-rules FILE`
     into `options.droppedRules` (as `--agid` is read).
   - Root `Makefile`: pass `--drop-rules data/wanxiang-typo-rules.txt` to
     `octo-prep` in the `$(PREPARED)/report.json` rule, and add the file to
     that rule's prerequisites, so editing the list re-prepares.

3. **Comments that describe typo spellings as present** (update the wording;
   the code stays):
   - `engine/lattice.goose`, the comment on `add` ("not the typo zhogn") and
     the one above the half-typed-syllable completion ("never to one of
     万象's typo spellings: lina is li na, not the start of linag"). Keep
     `syllables_only` and that completion logic: they still keep completions
     to real syllables (and away from variants like `lve`). Say that 万象's
     typo spellings are dropped at preparation (this document), and that the
     guard remains for the spellings that are not syllables.
   - `engine/tests/typing_test.goose`, the comment above
     `first_is(s, "lina", "李娜", true)`: same.

4. **Tests.**
   - `octo-prep` (`tools/octo-prep/Tests/OctoPrepTests/`): a test that a
     scheme's rules minus a dropped rule lose exactly that rule's spellings
     (for example `derive/([zcs])h([aeiu])$/$1$2h/` on `zhi`: `zih` goes,
     `zhi` stays), and that a listed rule missing from every scheme throws.
     Follow `AlgebraTests.swift`'s style (swift-testing, `#expect`).
   - `engine/tests/typing_test.goose`, in full pinyin, near the existing
     `first_is` checks: `ziheng`'s preedit is `zi heng` (not `zih eng`) and
     its first candidate is not 只嗯; `zih`'s preedit is `zi h`; `hzi`'s is
     `h zi`. Use the existing helpers (`preedit_of`, `type_text`,
     `candidate`, `check`).
   - Do not test `lon` → 龙 or `ten` → 疼 as typos: those still work, as
     half-typed syllables completing to long and teng (a different, wanted
     feature). They must keep working.

5. **Docs.** Add a short paragraph to `docs/M1-plan.md` (where the
   spellings are described) or a new section here, saying 全拼's typo
   spellings are left out and why, pointing to this document. Mention the
   pinned list in `README.md` only if the README lists `data/` files.

Do not edit anything under `.data/` (fetched and pinned by SHA-256).

## 3. What to expect (measured 2026-11-09, with the rules dropped in a scratch build)

| | Before | After |
|---|---|---|
| 全拼 spellings / rows | 3,071 / 16,546 | **2,589 / 13,070** |
| 小鹤双拼 spellings / rows | 2,473 / 9,891 | unchanged, the file identical |
| `ziheng` | `zih eng`: 只嗯 知恩 之恩 | `zi heng`: 字哼 淄河 滋贺 |
| `zih` | `zih`: 只 支 值 | `zi h`: 自豪 字号 自嗨 |
| `hzi` | `hzi`: 只 支 值 | `h zi`: 孩子 汉字 盒子 |
| `zhogn` | 中 | `zh o g n`: 中欧姑娘 中欧 … (no typo reading) |
| `lon`, `ten` | 龙, 腾 | 龙, 腾 (completions, as before) |
| typing test | 230 ok | 230 ok (plus the new checks) |
| accuracy, 全拼 hotlist | 71.8% (2,435) | **72.0% (2,442)** |
| accuracy, 全拼 zhihu120 | 76.7% (92) | 75.8% (91): one sentence flips between the homophones 吉隆 and 基隆 in the reranker's shortlist, not a typo case |
| accuracy, common words and idioms gate | 99.7% | 99.7% |
| accuracy, 小鹤双拼 | 73.4% / 75.8% | unchanged |

## 4. Verifying

1. `make prep`: the spellings lines show 全拼 2,589 spellings / 13,070 rows
   and 38 rules dropped; 小鹤双拼 unchanged (0 dropped). `grep -P '^zih\t'
   build/data/wanxiang/spellings.fullpinyin.tsv` finds nothing.
2. `swift test --package-path tools/octo-prep`: all pass, the new tests too.
3. `make images`, then `build/bin/images-test build/data/wanxiang build/images`
   (every row round-trips) and `build/bin/typing-test build/images` (no
   FAIL; the latency gates may fail only while the machine is busy with
   something else).
4. `build/bin/accuracy build/images build/accuracy fullpinyin` and `… flypy`:
   the numbers in section 3.
5. `make -C engine/fuzz test FUZZ_SECONDS=10` (the spelling target must stay
   clean) and `make -C macos test`.
6. `make install` only with the owner's go-ahead.

## Appendix: the 38 rules (万象 v18.1.9, `base/全拼`)

```
derive/([zcs])h(a|e|i|u|ai|ei|an|en|ou|uo|ua|un|ui|uan|uai|uang|ang|eng|ong)$/h$1$2/
derive/([zcs])h([aeiu])$/$1$2h/
derive/^([wghk])ai$/$1ia/
derive/([qjx])ia$/$1ai/
derive/([wtfghkz])ei$/$1ie/
derive/([jqx])ie$/$1ei/
derive/([rtypsdghklzcbnm])ao$/$1oa/
derive/([ypfm])ou$/$1uo/
derive/([wrtypsdfghklzcbnm])ang$/$1nag/
derive/([wrtypsdfghklzcbnm])ang$/$1agn/
derive/([wrtpsdfghklzcbnm])eng$/$1wng/
derive/([wrtpsdfghklzcbnm])eng$/$1neg/
derive/([wrtpsdfghklzcbnm])eng$/$1egn/
derive/([qtypdjlxbnm])ing$/$1nig/
derive/([qtypdjlxbnm])ing$/$1ign/
derive/([rtysdghklzcn])ong$/$1nog/
derive/([rtysdghklzcn])ong$/$1ogn/
derive/([qtpdjlxbnm])iao$/$1ioa/
derive/([qtpdjlxbnm])iao$/$1oia/
derive/([rtsghkzc])ui$/$1iu/
derive/([qjlxnm])iu$/$1ui/
derive/([qjlxn])iang$/$1aing/
derive/([qjlxn])iang$/$1inag/
derive/(g|k|h|zh|sh)ua$/$1au/
derive/(g|h|k|zh|ch|sh)uai$/$1aui/
derive/(g|h|k|zh|ch|sh)uai$/$1uia/
derive/([qrtysdghjklzxc])un$/$1nu/
derive/([nlyjqx])ue$/$1eu/
derive/(g|h|k|zh|ch|sh)uang$/$1aung/
derive/(g|h|k|zh|ch|sh)uang$/$1uagn/
derive/(g|h|k|zh|ch|sh)uang$/$1unag/
derive/(g|h|k|zh|ch|sh)uang$/$1augn/
derive/([jqx])iong$/$1inog/
derive/([jqx])iong$/$1oing/
derive/([jqx])iong$/$1iogn/
derive/([jqx])iong$/$1oign/
derive/ong$/on/
derive/([tl])eng$/$1en/
```
