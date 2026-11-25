#!/usr/bin/env bash
#
# Install Reticle (macOS 15+ arm64):
#
#   curl -fsSL https://raw.githubusercontent.com/KQAR/Reticle/main/install.sh | bash
#
# Downloads the first release zip, verifies it against the release's SHA256SUMS,
# and hands the unpacked directory to its own host (`reticle update --from <dir>`),
# which lays out ~/.reticle and links ~/.local/bin/reticle. That layout is written
# down once, in the Swift host; this script only fetches. Later upgrades are
# `reticle update`, which also refreshes the agent skill stubs.
#
# RETICLE_VERSION=<v> pins a release (default: the latest).
# RETICLE_RELEASES_URL overrides `https://github.com/KQAR/Reticle/releases/download`
# (as `<url>/v<version>/<asset>`; needs RETICLE_VERSION).
set -euo pipefail

REPO="KQAR/Reticle"
ASSET="reticle-macos-arm64.zip"

die() { echo "reticle install: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Reticle runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "Reticle ships for Apple silicon (arm64) only."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 15 )) || die "Reticle needs macOS 15 or newer (this is $(sw_vers -productVersion))."

version="${RETICLE_VERSION:-}"
version="${version#v}"
if [[ -n "${RETICLE_RELEASES_URL:-}" ]]; then
  [[ -n "${version}" ]] || die "RETICLE_RELEASES_URL needs RETICLE_VERSION."
  base="${RETICLE_RELEASES_URL}/v${version}"
elif [[ -n "${version}" ]]; then
  base="https://github.com/${REPO}/releases/download/v${version}"
else
  base="https://github.com/${REPO}/releases/latest/download"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "downloading ${base}/${ASSET}"
curl -fsSL "${base}/${ASSET}" -o "${tmp}/${ASSET}" || die "download failed: ${base}/${ASSET}"
curl -fsSL "${base}/SHA256SUMS" -o "${tmp}/SHA256SUMS" || die "download failed: ${base}/SHA256SUMS"
expected="$(awk -v a="${ASSET}" '$2 == a {print $1; exit}' "${tmp}/SHA256SUMS")"
actual="$(shasum -a 256 "${tmp}/${ASSET}" | awk '{print $1}')"
[[ -n "${expected}" && "${expected}" == "${actual}" ]] \
  || die "checksum mismatch for ${ASSET} (expected ${expected:-<none>}, got ${actual}); refusing it."

unzip -q "${tmp}/${ASSET}" -d "${tmp}/unpacked"
"${tmp}/unpacked/reticle/bin/reticle-host" update --from "${tmp}/unpacked/reticle"
# First install: point the agents that are present at the guide. Later upgrades
# refresh what this wrote, from `reticle update`.
"${HOME}/.reticle/current/bin/reticle-host" skill setup
