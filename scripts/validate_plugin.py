#!/usr/bin/env python3
"""
Lightweight validator for the Claude Code AND Cursor plugin + marketplace
manifests.

Dependency-free (stdlib only) so CI needs no extra install. Checks that each
plugin.json / marketplace.json is well-formed JSON, carries the required fields,
and that marketplace plugin sources point at paths that exist in the repo. It
ALSO enforces version lockstep: every manifest that declares a version, plus the
launcher and the in-code version constants, must agree — a divergence here is
exactly the silent skew that ships a skill whose command surface no longer
matches the binary. This is not a replacement for `claude plugin validate` (run
that locally before publishing) — it's a fast guard against the most common
cause of a plugin failing to install: a broken or mismatched manifest.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Claude Code lives under .claude-plugin/; Cursor mirrors it under .cursor-plugin/.
CLAUDE_PLUGIN = os.path.join(ROOT, ".claude-plugin", "plugin.json")
CLAUDE_MARKET = os.path.join(ROOT, ".claude-plugin", "marketplace.json")
CURSOR_PLUGIN = os.path.join(ROOT, ".cursor-plugin", "plugin.json")
CURSOR_MARKET = os.path.join(ROOT, ".cursor-plugin", "marketplace.json")

# kebab-case, no spaces — the public identifier used in `name@marketplace`.
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
# Cursor plugin.json declares dirs it ships (skills/commands/agents/hooks/rules).
DIR_KEYS = ("skills", "commands", "agents", "hooks", "rules")

errors = []
# (label, version) pairs collected from every source, checked for agreement.
versions = []


def load(path):
    if not os.path.isfile(path):
        errors.append(f"missing file: {os.path.relpath(path, ROOT)}")
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        errors.append(f"{os.path.relpath(path, ROOT)}: invalid JSON: {e}")
        return None


def check_name(value, where):
    if not isinstance(value, str) or not value:
        errors.append(f"{where}: 'name' must be a non-empty string")
    elif not NAME_RE.match(value):
        errors.append(f"{where}: 'name' must be kebab-case (got {value!r})")


def validate_plugin(data, label, cursor=False):
    if data is None:
        return
    if "name" not in data:
        errors.append(f"{label}: required field 'name' is missing")
    else:
        check_name(data["name"], label)
    # version is optional, but if present must look like a version string.
    v = data.get("version")
    if v is not None and not isinstance(v, str):
        errors.append(f"{label}: 'version' must be a string")
    elif isinstance(v, str):
        versions.append((label, v))
    # Cursor declares the dirs it ships as relative paths; they must exist so an
    # install doesn't silently drop skills/commands.
    if cursor:
        for key in DIR_KEYS:
            ref = data.get(key)
            if ref is None:
                continue
            if not isinstance(ref, str) or not ref.startswith("."):
                errors.append(f"{label}: '{key}' must be a relative './' path")
                continue
            resolved = os.path.normpath(os.path.join(ROOT, ref))
            if not os.path.isdir(resolved):
                errors.append(f"{label}: '{key}' points at a missing dir: {ref}")


def validate_marketplace(data, label):
    if data is None:
        return
    if "name" not in data:
        errors.append(f"{label}: required field 'name' is missing")
    else:
        check_name(data["name"], label)

    plugins = data.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        errors.append(f"{label}: 'plugins' must be a non-empty array")
        return

    for i, entry in enumerate(plugins):
        where = f"{label} plugins[{i}]"
        if not isinstance(entry, dict):
            errors.append(f"{where}: must be an object")
            continue
        if "name" not in entry:
            errors.append(f"{where}: required field 'name' is missing")
        else:
            check_name(entry["name"], where)
        v = entry.get("version")
        if v is not None and not isinstance(v, str):
            errors.append(f"{where}: 'version' must be a string")
        elif isinstance(v, str):
            versions.append((where, v))
        src = entry.get("source")
        if src is None:
            errors.append(f"{where}: required field 'source' is missing")
        elif isinstance(src, str):
            # Relative in-repo path (e.g. "./" or "./plugins/foo").
            if src.startswith("."):
                resolved = os.path.normpath(os.path.join(ROOT, src))
                if not os.path.isdir(resolved):
                    errors.append(f"{where}: source path does not exist: {src}")
        elif not isinstance(src, dict):
            errors.append(f"{where}: 'source' must be a string or object")


def collect_code_versions():
    """Pull the version out of the launcher and the two in-code constants so the
    lockstep check spans manifests AND the things that actually report a version
    at runtime — the surface the skew bug lived on."""
    sources = [
        ("bin/reticle", re.compile(r'RETICLE_VERSION="\$\{RETICLE_VERSION:-([^}"]+)\}"')),
        ("reticle-cli/src/main/kotlin/dev/reticle/cli/Main.kt",
         re.compile(r'RETICLE_VERSION\s*=\s*"([^"]+)"')),
        ("reticle-agent/android/src/main/kotlin/dev/reticle/agent/ReticleRuntime.kt",
         re.compile(r'VERSION\s*=\s*"([^"]+)"')),
    ]
    for rel, pat in sources:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue  # optional: a manifest-only checkout still validates
        with open(path, encoding="utf-8") as f:
            m = pat.search(f.read())
        if m:
            versions.append((rel, m.group(1)))
        else:
            # The file is present but its version moved/renamed — fail rather than
            # silently drop it from the lockstep set (that would let skew through).
            errors.append(f"{rel}: could not find a version string to lockstep-check")


def check_version_lockstep():
    distinct = {v for _, v in versions}
    if len(distinct) > 1:
        detail = ", ".join(f"{lbl}={ver}" for lbl, ver in versions)
        errors.append(
            "version skew across manifests/code — all must match: " + detail
        )


def main():
    validate_plugin(load(CLAUDE_PLUGIN), ".claude-plugin/plugin.json")
    validate_marketplace(load(CLAUDE_MARKET), ".claude-plugin/marketplace.json")
    # Cursor manifests are optional; validate them only if the dir exists, so a
    # Claude-only checkout still passes.
    checked = [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]
    if os.path.isdir(os.path.join(ROOT, ".cursor-plugin")):
        validate_plugin(load(CURSOR_PLUGIN), ".cursor-plugin/plugin.json", cursor=True)
        validate_marketplace(load(CURSOR_MARKET), ".cursor-plugin/marketplace.json")
        checked += [".cursor-plugin/plugin.json", ".cursor-plugin/marketplace.json"]

    collect_code_versions()
    check_version_lockstep()

    if errors:
        print("Plugin manifest validation FAILED:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print("Plugin manifest validation passed:")
    for rel in checked:
        print(f"  - {rel}")
    if versions:
        print(f"  - version lockstep OK ({versions[0][1]})")


if __name__ == "__main__":
    main()
