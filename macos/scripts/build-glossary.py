#!/usr/bin/env python3
"""Build a small read-only, bidirectional lookup index from the supplied TSV.

The second column can contain semicolon-separated English alternatives.
When several Chinese entries share one English term, the input method's
existing lexicon frequency selects the most familiar one; ties use TSV order.
"""

import sqlite3
import sys
import unicodedata
from pathlib import Path


def normalized(text):
    return unicodedata.normalize("NFC", text.strip()).lower()


def main():
    glossary, lexicon, output = map(Path, sys.argv[1:])
    entries = []
    words = set()
    with glossary.open(encoding="utf-8-sig", newline="") as source:
        for number, line in enumerate(source, 1):
            fields = line.rstrip("\r\n").split("\t")
            if len(fields) != 2 or not all(field.strip() for field in fields):
                raise ValueError(f"{glossary}:{number}: expected two nonempty tab-separated fields")
            chinese, english = (unicodedata.normalize("NFC", field.strip()) for field in fields)
            entries.append((chinese, english))
            words.add(chinese)

    weights = {}
    with lexicon.open(encoding="utf-8") as source:
        for line in source:
            if line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t", 3)
            if len(fields) < 3 or fields[0] not in words:
                continue
            try:
                weight = float(fields[2])
            except ValueError:
                continue
            weights[fields[0]] = max(weights.get(fields[0], 0), weight)

    # Keep the first Chinese spelling if frequencies are equal. This avoids
    # using the source's character sort order as a popularity ranking.
    reverse = {}
    for chinese, english in entries:
        for alternative in english.split(";"):
            key = normalized(alternative)
            if not key:
                continue
            weight = weights.get(chinese, 0)
            previous = reverse.get(key)
            if previous is None or weight > previous[0]:
                reverse[key] = (weight, chinese)

    output.unlink(missing_ok=True)
    with sqlite3.connect(output) as db:
        db.executescript("""
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE zh (term TEXT PRIMARY KEY, translation TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE en (term TEXT PRIMARY KEY, translation TEXT NOT NULL) WITHOUT ROWID;
        """)
        db.executemany("INSERT INTO zh VALUES (?, ?)", entries)
        db.executemany("INSERT INTO en VALUES (?, ?)",
                       ((english, chinese) for english, (_, chinese) in sorted(reverse.items())))


if __name__ == "__main__":
    main()
