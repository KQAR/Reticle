#!/usr/bin/env python3
"""
Version lockstep: every place that states Reticle's release must agree.

The repo-root VERSION file is the source of truth. The Kotlin helper and the
Android agent read a constant generated from it, so they cannot drift and are not
listed. What is still written by hand is checked here: the Swift host's
`ReticleVersion.current` (what `reticle version` prints, what `reticle update`
names a release directory after, and what the helper daemon's staleness check
compares). A skew between them ships a binary that misreports itself.

Dependency-free (stdlib only) so CI needs no install. The skill guide's own
consistency (every topic reachable from SKILL.md) is pinned by
`SkillGuideTests` in reticle-host, next to the table it checks.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOURCES = [
    ("reticle-host/Sources/ReticleHostShared/HelperCalling.swift",
     re.compile(r'static\s+let\s+current\s*=\s*"([^"]+)"')),
]


def main():
    errors = []
    with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
        truth = f.read().strip()
    for rel, pat in SOURCES:
        path = os.path.join(ROOT, rel)
        try:
            with open(path, encoding="utf-8") as f:
                m = pat.search(f.read())
        except FileNotFoundError:
            m = None
        # A constant that moved must fail here, not drop out of the check.
        if not m:
            errors.append(f"{rel}: could not find a version string to lockstep-check")
        elif m.group(1) != truth:
            errors.append(f"{rel} says {m.group(1)}, VERSION says {truth}")
    if errors:
        print("Version lockstep FAILED:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print(f"Version lockstep OK ({truth})")


if __name__ == "__main__":
    main()
