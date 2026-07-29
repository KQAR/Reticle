#!/usr/bin/env python3
"""Check docs/architecture-map/ against itself, the repo, and the VERSION file.

The map is a hand-maintained projection over the prose docs, and it carried the
projection twice: `map.json` for agents, plus a byte-identical copy embedded in
`index.html` for the interactive page. Nothing compared them, so they drifted —
measured when this script was written: the embedded copy was missing a whole
flow step and still said version 0.11.0 while the repo was on 0.12.0. A viewer
reading the page and an agent reading the JSON were being told different things
about the same system.

What is checked:

  * the embedded copy equals map.json (structurally, so formatting is free);
  * meta.version equals the repo-root VERSION;
  * every edge endpoint and every id a flow step cites resolves to a real node
    or edge — a typo'd id renders as a step that highlights nothing;
  * every fixture the map names exists under reticle-protocol/fixtures/;
  * every module directory the map names exists.

`--fix` rewrites the embedded copy from map.json, so keeping the two in step is
one edit plus one command rather than two edits and a hope.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "docs/architecture-map/map.json"
PAGE = ROOT / "docs/architecture-map/index.html"
FIXTURES = ROOT / "reticle-protocol/fixtures"
EMBED = re.compile(
    r'(?P<open><script id="graph" type="application/json">)(?P<body>.*?)(?P<close></script>)',
    re.S,
)


def embedded(page_text: str) -> tuple[dict, re.Match]:
    match = EMBED.search(page_text)
    if not match:
        raise SystemExit("index.html has no <script id=\"graph\"> block to compare")
    return json.loads(match.group("body")), match


def check(data: dict, page_text: str) -> list[str]:
    problems: list[str] = []

    page_data, _ = embedded(page_text)
    if page_data != data:
        problems.append(
            "index.html's embedded map differs from map.json — one of the two is "
            "stale. Re-run with --fix to rewrite the page from the JSON."
        )

    version = (ROOT / "VERSION").read_text().strip()
    if data.get("meta", {}).get("version") != version:
        problems.append(
            f"map.json meta.version is {data.get('meta', {}).get('version')!r}, "
            f"but VERSION says {version!r}"
        )

    node_ids = {n["id"] for n in data.get("nodes", [])}
    edge_ids = {e["id"] for e in data.get("edges", [])}
    for edge in data.get("edges", []):
        for side in ("from", "to"):
            if edge[side] not in node_ids:
                problems.append(f"edge {edge['id']!r} points at unknown node {edge[side]!r}")
    for flow in data.get("flows", []):
        for index, step in enumerate(flow.get("steps", [])):
            for ref in step.get("nodes", []):
                if ref not in node_ids:
                    problems.append(f"flow {flow['id']!r} step {index} cites unknown node {ref!r}")
            for ref in step.get("edges", []):
                if ref not in edge_ids:
                    problems.append(f"flow {flow['id']!r} step {index} cites unknown edge {ref!r}")

    # Anything the prose in the map names as a fixture or a module has to exist:
    # a renamed file leaves the map describing a system that is not there.
    prose = json.dumps(data)
    for fixture in sorted(set(re.findall(r"[a-z0-9.\-]+\.(?:cases|golden)\.json", prose))):
        if not (FIXTURES / fixture).exists():
            problems.append(f"map names fixture {fixture!r}, which is not in reticle-protocol/fixtures/")
    for module in sorted(set(re.findall(r"\breticle-[a-z]+(?:/[a-z]+)?\b", prose))):
        if not (ROOT / module).exists():
            problems.append(f"map names module path {module!r}, which does not exist")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fix", action="store_true", help="rewrite index.html's embedded map from map.json")
    args = parser.parse_args()

    data = json.loads(MAP.read_text())
    page_text = PAGE.read_text()

    if args.fix:
        _, match = embedded(page_text)
        body = json.dumps(data, indent=2, ensure_ascii=False)
        PAGE.write_text(
            page_text[: match.start("body")] + body + page_text[match.end("body") :]
        )
        print("index.html: embedded map rewritten from map.json")
        page_text = PAGE.read_text()

    problems = check(data, page_text)
    if problems:
        print("architecture map is inconsistent:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("architecture map OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
