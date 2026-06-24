#!/usr/bin/env python3
"""
Lightweight validator for the Claude Code plugin + marketplace manifests.

Dependency-free (stdlib only) so CI needs no extra install. Checks that
.claude-plugin/plugin.json and .claude-plugin/marketplace.json are well-formed
JSON and carry the required fields, and that the marketplace's plugin sources
point at paths that exist in the repo. This is not a replacement for
`claude plugin validate` (run that locally before publishing) — it's a fast
guard against the most common cause of a plugin failing to install: a broken
manifest.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, ".claude-plugin", "plugin.json")
MARKET = os.path.join(ROOT, ".claude-plugin", "marketplace.json")

# kebab-case, no spaces — the public identifier used in `name@marketplace`.
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

errors = []


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


def validate_plugin(data):
    if data is None:
        return
    if "name" not in data:
        errors.append("plugin.json: required field 'name' is missing")
    else:
        check_name(data["name"], "plugin.json")
    # version is optional, but if present must look like a version string.
    v = data.get("version")
    if v is not None and not isinstance(v, str):
        errors.append("plugin.json: 'version' must be a string")


def validate_marketplace(data):
    if data is None:
        return
    if "name" not in data:
        errors.append("marketplace.json: required field 'name' is missing")
    else:
        check_name(data["name"], "marketplace.json")

    plugins = data.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        errors.append("marketplace.json: 'plugins' must be a non-empty array")
        return

    for i, entry in enumerate(plugins):
        where = f"marketplace.json plugins[{i}]"
        if not isinstance(entry, dict):
            errors.append(f"{where}: must be an object")
            continue
        if "name" not in entry:
            errors.append(f"{where}: required field 'name' is missing")
        else:
            check_name(entry["name"], where)
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


def main():
    validate_plugin(load(PLUGIN))
    validate_marketplace(load(MARKET))

    if errors:
        print("Plugin manifest validation FAILED:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print("Plugin manifest validation passed:")
    print(f"  - {os.path.relpath(PLUGIN, ROOT)}")
    print(f"  - {os.path.relpath(MARKET, ROOT)}")


if __name__ == "__main__":
    main()
