# Fuzzy pinyin (模糊音)

Status: built, 2026-11-09. Off by default.

## What it is

A fuzzy group makes two spellings count as one sound, for people who do not
tell them apart: with z = zh on, `zong` offers 中 beside 总, and `zongguo` is
中国. OctoDot has 万象's ten groups, each on or off on its own, in Settings →
Input → 模糊音:

| Group | | Group | |
|---|---|---|---|
| `z_zh` | z = zh | `r_y` | r = y |
| `c_ch` | c = ch | `h_f` | h = f |
| `s_sh` | s = sh | `k_g` | k = g |
| `n_l` | n = l | `en_eng` | en = eng |
| `r_l` | r = l | `in_ing` | in = ing |

Each works both ways (typing z offers zh's words, typing zh offers z's), in
every scheme: in 小鹤双拼, `zs` (z + ong) offers 中 too, since the groups apply
to pinyin before the scheme turns it into keys.

## How

- **Built ahead, chosen at run time.** `octo-prep` evaluates 万象's
  `模糊音_*` rule blocks from `wanxiang_algebra.yaml` ahead of every scheme's
  own rules (they rewrite toned pinyin, `zhōng` → `zōng`, which the scheme's
  rules then turn into keys). Every spelling row it writes carries the groups
  its derivation needed, as bits, and the table names the groups (`#fuzzy`).
  Derivations needing different groups are kept apart, so a row needing both
  z = zh and en = eng (`zen` for zheng) counts only while both are on; one
  made useless by another needing fewer groups is dropped.
- **The engine** (`engine/spelling.goose`) skips a row unless every group it
  needs is on (`spelling::usable`), where the syllable graph is built. Turning
  a group on or off is a setting (`octo_set_fuzzy`, by id), applied at once:
  nothing is rebuilt. The keys a typist presses for a syllable (the accuracy
  harness's, custom phrases') come from exact rows only.
- **A fuzzy spelling is a fuzzy one**, as librime's `fuzz` makes it: a fuzzy
  type and a penalty of log(0.5). 万象 writes its groups as `derive`, which
  would give `zong` → 中 the standing of `zong` → 总; with the penalty a much
  more common word still comes first (中 over 总), but between words of near
  weight the exact spelling does.

## Cost

The spelling tables hold the fuzzy rows too: 全拼 16,546 rows (8,422 exact),
小鹤双拼 9,891 (4,808 exact); 233 KB and 154 KB. With every group off, the
exact rows are byte for byte the tables before, and the accuracy set gives
the same numbers (小鹤双拼 73.4%, 全拼 71.8% of hotlist sentences).

## Tests

- images test: every row comes back with its groups; both tables name the ten.
- typing test: off by default (`zong` is never 中); z = zh alone offers 中 for
  `zong` and 中国 for `zongguo`, and leaves s = sh off; z = zh with en = eng
  offers 正 for `zen`, neither alone does; an unknown id is ignored; the
  choice holds in 小鹤双拼 (`zs`, `zsgo`); off again.
- smoke test: the same through the Swift API.
