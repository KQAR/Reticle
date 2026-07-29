#!/usr/bin/env python3
"""Check that a translated doc still has the same skeleton as its original.

`docs/roadmap.md` and `docs/roadmap.zh-CN.md` are the same document in two
languages, and the roadmap is where scope decisions are recorded — a section
added to one and not the other means two readers get two different answers to
"is this in scope". Nothing compared them, and the two files had already drifted
apart in length.

Prose cannot be diffed across languages, but the SKELETON can: the sequence of
heading levels, and the numbering of the ordered sections. That is exactly the
part that changes when a section is added, removed or reordered, which is the
drift worth catching. Wording, ordering within a section, and table contents are
left alone.

`README.zh-CN.md` is deliberately NOT checked: it is an abridged translation
(44 headings against the English 56), which is a documented choice rather than
drift. Listing that here is the point — an unchecked pair should be unchecked on
purpose, not by omission.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PAIRS = [
    ("docs/roadmap.md", "docs/roadmap.zh-CN.md"),
]

HEADING = re.compile(r"^(#{1,6}) (.+)$", re.M)
ORDINAL = re.compile(r"^(\d+)\.")


def skeleton(path: Path) -> list[tuple[int, str | None]]:
    """Heading levels, plus the ordinal prefix of a numbered section."""
    out: list[tuple[int, str | None]] = []
    for match in HEADING.finditer(path.read_text(encoding="utf-8")):
        title = match.group(2).strip()
        ordinal = ORDINAL.match(title)
        out.append((len(match.group(1)), ordinal.group(1) if ordinal else None))
    return out


def main() -> int:
    problems: list[str] = []
    for original, translation in PAIRS:
        a, b = skeleton(ROOT / original), skeleton(ROOT / translation)
        if a == b:
            continue
        if len(a) != len(b):
            problems.append(
                f"{original} has {len(a)} headings, {translation} has {len(b)} — "
                "a section was added or removed on one side only"
            )
        for index, (left, right) in enumerate(zip(a, b)):
            if left != right:
                problems.append(
                    f"{original} and {translation} diverge at heading #{index + 1}: "
                    f"level {left[0]} ordinal {left[1]} vs level {right[0]} ordinal {right[1]}"
                )
                break

    if problems:
        print("translated docs are out of step with their originals:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("translated docs OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
