# 八千点 OctoDot

A privacy-first Chinese input method for macOS. It types whole sentences in
全拼 (full pinyin) or 小鹤双拼, and everything it does happens on your Mac:
the input method runs in a sandbox with no network access at all.

[**Download OctoDot 0.1.0**](https://github.com/n19htfall/OctoDot/releases/download/v0.1.0/OctoDot-0.1.0.dmg)
(413 MB, macOS 14 or later, Apple silicon) ·
[mirror on Quark](https://pan.quark.cn/s/b9a29be252cb) ·
[all releases](https://github.com/n19htfall/OctoDot/releases) ·
[website](https://n19htfall.github.io/OctoDot/)

## Why OctoDot

- **Your typing stays on your Mac.** The input method cannot reach the
  network, so there is nowhere for your keystrokes to go. See
  [Privacy](#privacy).
- **It gets sentences right.** A grammar model scores whole sentences, and a
  small neural network, running on your Mac, reranks them. On 120 Zhihu
  sentences it had never seen, OctoDot typed 75.8% correctly as a whole on
  the first try, against 66.7% for the pinyin input built into macOS and
  60.0% for Rime with the same grammar model.
- **A large, current lexicon.** The words come from
  [万象拼音](https://github.com/amzxyz/rime-wanxiang), with optional sets for
  place names, well-known people and artists.

## Install

1. Download the disk image above, open it, and drag OctoDot into
   Applications.
2. Open OctoDot. It walks you through installing and enabling the input
   method. If macOS asks you to confirm, the guide takes you to System
   Settings → Keyboard → Text Input → Input Sources.
3. Choose 全拼 or 小鹤双拼, and try typing right there in the guide.
4. Switch to OctoDot from the input menu in the menu bar.

If OctoDot does not show up in the input menu, remove it in System Settings →
Keyboard → Text Input → Input Sources and add it again.

**Updating.** OctoDot.app checks for updates and installs them. An update
loads into the running input method, so the apps you are typing in carry on
without a restart.

**Uninstalling.** Open OctoDot.app and remove the input method from there,
then move OctoDot.app to the Trash.

## Features

- **全拼 and 小鹤双拼**, on the same lexicon. Switch at any time from the
  input menu. In 小鹤双拼 the input area shows the keys you typed, split by
  syllable (`vsgo` → `vs go`).
- **Chinese and English together.** Type `woyonggithub` and get
  「我用GitHub」. Common English words appear among the candidates; there is
  no separate English mode to switch into.
- **Shape codes (形码).** After a syllable, type `` ` `` and one or two
  letters to narrow the candidates by how the character is written
  (`` shi`o `` → 是). Nine schemes, including 万象, 墨奇 and 自然码.
- **Tones.** After a syllable, `7` `8` `9` `0` pick the first to fourth tone
  (`zhong7`).
- **Abbreviations.** Type initials only (`zgr`).
- **Fuzzy pinyin (模糊音).** Ten pairs such as z = zh and n = l, each with
  its own switch. All are off by default.
- **It learns your choices.** A candidate you pick comes first the next
  time. You can make it forget the last 15 minutes, today, or everything.
- **Custom phrases.** Keep your own phrases in a text file; they take
  effect a moment after you save (`yx` → 我的邮箱).
- **More candidates at once.** Press ↓ to open the candidates as a grid.
- **Candidate translations.** On macOS 26 or later, hold Option to replace
  the visible candidates with their Chinese–English translations. Install the
  Chinese and English translation languages in System Settings → General →
  Language & Region → Translation Languages for on-device translation;
  Dictionary entries are also used when available.

## Privacy

OctoDot is two apps, and they are kept apart on purpose:

| | OctoDot.app | The input method (OctoDotIME) |
|---|---|---|
| What it does | Installs, updates and removes the input method | Turns your keystrokes into text |
| Sees what you type | No | Yes |
| Can use the network | Yes, only to check for and download updates | No. macOS's sandbox refuses it |

- The input method asks for one thing only: to be an input method. It does
  not ask for Accessibility, Input Monitoring, the clipboard or Full Disk
  Access.
- What it learns from you is encrypted with AES-GCM, and the key is kept in
  your Keychain. macOS asks you to allow this once.
- It does not learn in password fields, in password managers, or in
  incognito mode, which you can turn on from the input menu.
- Updates are signed with Ed25519 and checked against a SHA-256 before they
  are installed.

## Keys

| Keys | What they do while you are typing |
|---|---|
| letters, `'` | pinyin; `'` separates syllables (`xi'an`) |
| `1`–`6`, Space, a click | pick a candidate; Space picks the highlighted one |
| `-` `=`, Page Up/Down, arrows | turn pages, move the highlight |
| `7` `8` `9` `0` after a syllable | its tone, first to fourth (`0` is also the neutral tone) |
| `` ` `` then one or two letters | the syllable's shape code (`` shi`o `` → 是) |
| Backspace | delete the last letter, or undo the last pick |
| Shift- or Control-Backspace | forget the highlighted candidate |
| Return, Escape | commit the letters as typed, or cancel |
| Control-g | show rare characters too, or only the everyday set (通用规范汉字表) |
| Hold Option | replace the visible candidates with translations (macOS 26 or later) |
| Shift alone | switch between Chinese and English |

The input menu in the menu bar switches between 全拼 and 小鹤双拼, turns the
extra lexicon sets (地名, 名人, 艺人) and the grammar model on and off, picks
the shape-code scheme, and opens Settings.

### Custom phrases

Choose *Edit Custom Phrases…* in the input menu. Write one entry per line:
the text, then a tab or spaces, then a code.

```
雾凇奇观    wu song qi guan
我的邮箱    yx
```

A pinyin code (first line) makes a word that works inside sentences and in
both 全拼 and 小鹤双拼. Any other code (second line) is a shortcut, offered
first when you type it exactly. The format is the one 万象 and Rime use for
`custom_phrase.txt`.

## Building from source

You need macOS 14 or later on Apple silicon, Xcode (Swift 6), CMake and Git.

```sh
make            # fetch the pinned lexicon and models (~535 MB, once) and build
make install    # put OctoDot.app in /Applications and install the input method
make uninstall  # remove both; your learned words stay in the input method's container
make test       # the privacy check, the unit tests, typing, and the accuracy gate
make dmg-dev    # a development-signed disk image
```

`make accuracy`, `make bench`, `make eval` and `make fuzz` measure accuracy,
size and speed, ranking quality, and the robustness of the file loaders.
`make bench-typing-memory` exercises per-key typing, corrections, learning,
snapshots and reranking, and checks whether memory settles after warmup.

The input engine is written in [Goose](https://github.com/aardappel/goose)
and sits behind a small C interface inside a sandboxed InputMethodKit app.

| Path | What it is |
|---|---|
| `engine/` | The engine: lexicon, spelling and shape-code tables, the sentence decoder, the typing session, and their tests |
| `macos/` | The two apps: OctoDot.app and the input method |
| `tools/` | The tools that turn the lexicon sources into the files the engine loads, and the release scripts |
| `data/`, `toolchain/` | Lock files that pin every outside source and the compiler by commit and SHA-256 |
| `site/` | The website |
| `docs/` | Design notes: [sentences and the grammar model](docs/M2-grammar.md), [the reranker](docs/rerank-design.md), [English words](docs/english-design.md), [fuzzy pinyin](docs/fuzzy-pinyin.md), [live switching](docs/hotswap-architecture.md), [distribution and onboarding](docs/distribution-and-onboarding.md) |
| `spikes/` | Early prototypes and [what they settled](spikes/README.md) |

## License and credits

- OctoDot's source code is licensed under the GNU General Public License
  v3.0 ([`LICENSE`](LICENSE)).
- The reranker's weights are open and licensed separately, under
  CC BY-NC-SA 4.0 ([`LICENSE-weights`](LICENSE-weights)): free to use and
  adapt for non-commercial purposes, with credit, under the same license.
  The code that trained them is not part of this repository.
- The lexicon and the grammar model come from amzxyz's
  [万象拼音](https://github.com/amzxyz/rime-wanxiang) (CC BY 4.0). Other
  third-party material is listed in [`NOTICE`](NOTICE).
