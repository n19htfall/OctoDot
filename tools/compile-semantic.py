#!/usr/bin/env python3
"""Build the English-to-Chinese sense table the mixed decoder reads.

Reads the glossary (Chinese, tab, semicolon-separated English glosses) and
keeps a gloss only when that English token is already a whole word in the
English dictionary. Senses are ranked by the Chinese lexicon weight and
clipped to four per word. A missing output simply leaves the feature off.

  python3 tools/compile-semantic.py \
      data/glossary_clean.tsv \
      build/data/wanxiang/english.tsv \
      build/data/wanxiang/lexicon.tsv \
      build/images/semantic.tsv
"""

import sys
from math import log2

FLOOR = 2000
TOP = 4
MAX_CHARS = 4
PARTICLE = set("吧吗呢啊呀啦哇哦嘛哟")
PUNCT = set("。！？，、；：,.!?;:\"'“”‘’（）()[]【】《》<>…—-~/\\")


def chars(text):
    return list(text)


def bad_surface(text):
    cs = chars(text)
    if not cs or len(cs) > MAX_CHARS:
        return True
    if any(c in PUNCT or ord(c) < 128 for c in cs):
        return True
    if len(cs) > 1 and cs[-1] in PARTICLE:
        return True
    return False


def english_codes(path):
    codes = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip() or line.startswith("#"):
                continue
            codes.add(line.split("\t", 1)[0])
    return codes


def lexicon_weights(path):
    best = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip() or line.startswith("#") or "\t" not in line:
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            try:
                weight = int(parts[2])
            except ValueError:
                continue
            if weight > best.get(parts[0], 0):
                best[parts[0]] = weight
    return best


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: compile-semantic.py GLOSSARY ENGLISH LEXICON OUT")
    glossary, english, lexicon, out = sys.argv[1:]
    codes = english_codes(english)
    weights = lexicon_weights(lexicon)
    senses = {}
    rows = empty = bad = multi = single = kept_pairs = 0
    with open(glossary, encoding="utf-8") as handle:
        for line in handle:
            rows += 1
            if "\t" not in line:
                bad += 1
                continue
            chinese, gloss = line.rstrip("\n").split("\t", 1)
            chinese = chinese.strip()
            if bad_surface(chinese):
                bad += 1
                continue
            weight = weights.get(chinese, 0)
            if weight < FLOOR:
                continue
            for piece in gloss.replace("；", ";").split(";"):
                token = piece.strip().lower()
                if not token.isascii() or not token.isalpha() or token not in codes:
                    continue
                bucket = senses.setdefault(token, {})
                if weight > bucket.get(chinese, 0):
                    bucket[chinese] = weight
                    kept_pairs += 1
    none = one = many = 0
    lines = []
    for code in sorted(senses):
        ranked = sorted(senses[code].items(), key=lambda item: (-item[1], item[0]))[:TOP]
        if not ranked:
            none += 1
            continue
        if len(ranked) == 1:
            one += 1
        else:
            many += 1
        flat = []
        for surface, weight in ranked:
            flat.append(surface)
            flat.append(str(weight))
        lines.append(code + "\t" + "\t".join(flat))
    with open(out, "w", encoding="utf-8") as handle:
        handle.write("# code, then up to four Chinese senses and their lexicon weights\n")
        handle.write("\n".join(lines))
        handle.write("\n")
    print(f"rows {rows}")
    print(f"rejected surfaces {bad}")
    print(f"english words {len(senses)} single {one} multi {many}")
    print(f"kept pairs {kept_pairs}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
