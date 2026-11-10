# OctoDot

A privacy-first Chinese input method for macOS. The input engine is written
in [Goose](https://github.com/aardappel/goose) and runs behind a narrow C ABI
inside a sandboxed InputMethodKit app with no network access.

**Status: M0 done, M1 in progress, M2's grammar model in.** It types today
on the whole 万象 lexicon, in full pinyin or 小鹤双拼, with sentences ranked
by 万象's grammar model (as accurate as librime with it on the same Zhihu
sentences: [`docs/M2-grammar.md`](docs/M2-grammar.md)) and reranked by a
small neural model of OctoDot's own, on the Mac (73.4% of corpus sentences
right in 小鹤双拼, from 65.8%: [`docs/rerank-design.md`](docs/rerank-design.md)), abbreviations
(`zgr`), tones (`zhong7`), shape codes (`` shi`o ``), 万象's daily
character set, fuzzy pinyin if you want it (z = zh, n = l and eight more,
each its own switch, all off by default: [`docs/fuzzy-pinyin.md`](docs/fuzzy-pinyin.md)),
and learning from your choices, stored encrypted.
Prototypes that tested the architecture's riskiest assumptions live in
[`spikes/`](spikes), with their findings in
[`spikes/README.md`](spikes/README.md). The plan for the first daily-drivable
version, on the 万象 lexicon, is [`docs/M1-plan.md`](docs/M1-plan.md).

## Typing

OctoDot is two bundles ([`docs/distribution-and-onboarding.md`](docs/distribution-and-onboarding.md)):
`OctoDot.app`, which you keep in `/Applications` and which sets up, updates
and removes the input method, and `OctoDotIME.app`, the input method itself,
which it installs in `~/Library/Input Methods` (sandboxed, with no network).
`make install` puts the companion in `/Applications` and, through it, the
input method in place; on a Mac with an earlier OctoDot
(`com.example.inputmethod.OctoDot`) it removes that one, starting afresh (its
learned words stay in its container, not carried over). Opening OctoDot.app
walks a new user through the same, and lets them try typing right there.
An update loads into the running IME in place, so every app keeps typing.
Only a change to its small launcher (`macos/Sources/Launcher`) restarts the
IME. Then apps built on Chromium (Chrome, Edge, VS Code, Typora and other
Electron apps) type nothing until you quit and reopen them; install restarts
Spotlight's host for you, and native apps reconnect by themselves.
Then add OctoDot in System Settings → Keyboard → Input Sources. The input
menu switches, at once and with nothing to rebuild, between 全拼 and 小鹤双拼
(in 小鹤 the preedit shows the keys you type, by syllable: `vsgo` → `vs go`),
turns the 词库 lexicon sets (地名, 名人, 艺人) and the 语法模型 grammar model
on and off, and picks the 形码 shape-code scheme (万象, 墨奇, 自然码 and six
more).

| Keys | What they do while composing |
|---|---|
| letters, `'` | pinyin; `'` separates syllables (`xi'an`) |
| `7` `8` `9` `0` after a syllable | its tone: first to fourth (`0` also neutral) |
| `` ` `` then one or two letters | the syllable's shape code, 万象's scheme (`` shi`o `` → 是) |
| `1`–`6`, space, a click | pick from the page; space picks the highlighted candidate |
| `-` `=`, Page Up/Down, arrows | turn pages, move the highlight |
| Backspace | the last letter, or the last selection |
| Shift- or Control-Backspace | forget the highlighted candidate from what OctoDot has learned |
| Return, Escape | commit the letters as typed, or cancel |
| Control-g | show rare characters too, or only the daily set (通用规范汉字表) |
| Shift alone | switch between Chinese and English |

**Custom phrases.** Choose *Edit Custom Phrases…* in the input menu. One
entry per line, as in 万象/Rime's `custom_phrase.txt`: text, then a tab or
spaces, then a code. A pinyin code makes a word that works in sentences and
in every scheme (`雾凇奇观 wu song qi guan`, or in 小鹤 keys: `雾凇奇观
wussqigr`). Any other code is a shortcut, offered first when typed exactly
(`我的邮箱 yx`). Save the file, and a moment later it is in use, compiled in
the background.

OctoDot learns from what you choose: a candidate you pick comes first the
next time you type the same thing. It never learns in password fields, in
password managers or in incognito. The input menu turns incognito on and
off and forgets the last 15 minutes, today, or everything. What it learned
is stored encrypted, with its key in your Keychain.

## Layout

| Path | What it is |
|---|---|
| `toolchain/goose.lock` | The one Goose compiler OctoDot builds with (tag and commit) |
| `toolchain/bootstrap-goose.sh` | Builds that compiler from source into `.toolchain/` |
| `data/wanxiang.lock` | The 万象拼音 release the default lexicon comes from, pinned by commit and SHA-256 |
| `data/wanxiang-typo-rules.txt` | 全拼 typo spellings `octo-prep` drops, pinned to the rules in 万象 v18.1.9 |
| `tools/fetch-wanxiang.sh` | Fetches and verifies those files into `.data/`; `--relock TAG` moves the pin |
| `data/unihan.lock`, `tools/fetch-unihan.sh` | The same for Unicode's Unihan database, the source of character sets |
| `data/rerank.lock` | The reranker OctoDot trained ([`docs/rerank-design.md`](docs/rerank-design.md)): its released weights, pinned by SHA-256. The training code is not part of this repository |
| `data/daily-extra.txt` | Characters the daily set shows beyond 通用规范汉字表, each with its reason |
| `tools/octo-prep/` | Swift tool: 万象 dictionaries, spelling rules and shape codes, and Unihan's character sets → normalized sources and an import report |
| `engine/` | The Goose engine package: the image container, the lexicon, spelling and shape-code tables, the decoder and the composing session; its tests, benchmark and fuzz targets |
| `macos/` | The input method: a sandboxed InputMethodKit app around the engine's C ABI |
| `tools/octo-compile/` | Goose tool: normalized sources → verified images (`build/images/`) |
| `mk/toolchain.mk` | The pinned Goose compiler and Xcode settings the Makefiles share |
| `spikes/` | M0: four prototypes and what they settled |
| `site/` | The website (Vite + React), published at [n19htfall.github.io/OctoDot](https://n19htfall.github.io/OctoDot/) by `.github/workflows/pages.yml` |
| `docs/M1-plan.md` | M1: a daily-drivable IME on the 万象 lexicon |
| `docs/hotswap-architecture.md` | Switching schemes, lexicon sets and shape codes live, with no deploy step |
| `LICENSE` | OctoDot's license: the GNU General Public License v3.0 |
| `LICENSE-weights` | The reranker weights' license: CC BY-NC-SA 4.0 |
| `NOTICE` | Third-party material and licenses |

## Requirements

macOS 14 or later on Apple silicon, Xcode (Swift 6), CMake and Git.

```sh
make                   # fetch the pinned 万象 files, Unihan, 万象's grammar model and the reranker (~535 MB, once), prepare, build the images
make install           # the companion into /Applications, and through it the input method for this user
make uninstall         # remove both (your learned words stay, in the input method's container)
make dmg-dev           # build/…/OctoDot-<version>-dev.dmg, development-signed, mounted and checked
make dmg-release       # Developer ID, notarized and stapled (needs that certificate and a notarytool profile)
make test              # the privacy check, octo-prep's tests, the images, typing, the accuracy gate, and the app
make test-debug        # typing, the images and 小鹤双拼 accuracy, with Goose's --debug checks (not part of make test)
make eval              # ranking quality, judged by the lexicon itself
make accuracy          # the accuracy set, built from pinned outside sources, listing every miss (SCHEME=flypy for 小鹤双拼)
make bench             # the images against M1's gates: size, load time, memory, lookups
make fuzz              # fuzz the image loaders (with libFuzzer too, if LLVM is installed)
make relock TAG=...    # pin another 万象 release and review what changed
make -C spikes test    # M0; builds the pinned Goose compiler on first use (~45 s)
```

## License

OctoDot's source code is licensed under the GNU General Public License
v3.0 ([`LICENSE`](LICENSE)). The reranker's released weights (the files
[`data/rerank.lock`](data/rerank.lock) pins) are licensed separately, under
CC BY-NC-SA 4.0 ([`LICENSE-weights`](LICENSE-weights)): free to use and
adapt for non-commercial purposes, with credit, under the same license.
Third-party material keeps its own licenses ([`NOTICE`](NOTICE)).
