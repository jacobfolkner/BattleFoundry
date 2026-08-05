#!/usr/bin/env bash
# Downloads GUT (Godot Unit Testing, https://github.com/bitwes/Gut) into
# addons/gut. Pinned by version + checksum rather than vendored in git --
# it's ~260 static third-party files that never change once fetched, so
# committing them just bloats every diff/clone. Safe to re-run: no-ops if
# the pinned version is already present.
set -euo pipefail

GUT_VERSION="9.7.0"
GUT_SHA256="7bbe6cc7f9c2954e8cf44d9eaf309cc16b5c0b2980291b58ece9c6b66899cb10"
GUT_URL="https://github.com/bitwes/Gut/archive/refs/tags/v${GUT_VERSION}.zip"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON_DIR="${REPO_ROOT}/addons/gut"

if [[ -f "${ADDON_DIR}/plugin.cfg" ]] && grep -q "version=\"${GUT_VERSION}\"" "${ADDON_DIR}/plugin.cfg"; then
	echo "GUT ${GUT_VERSION} already present at ${ADDON_DIR}, skipping download."
	exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Downloading GUT ${GUT_VERSION}..."
curl -sL -o "${WORK_DIR}/gut.zip" "${GUT_URL}"

ACTUAL_SHA256="$(sha256sum "${WORK_DIR}/gut.zip" | cut -d' ' -f1)"
if [[ "${ACTUAL_SHA256}" != "${GUT_SHA256}" ]]; then
	echo "Checksum mismatch for GUT ${GUT_VERSION} download:" >&2
	echo "  expected ${GUT_SHA256}" >&2
	echo "  got      ${ACTUAL_SHA256}" >&2
	exit 1
fi

unzip -q "${WORK_DIR}/gut.zip" -d "${WORK_DIR}/extracted"

mkdir -p "${REPO_ROOT}/addons"
rm -rf "${ADDON_DIR}"
mv "${WORK_DIR}/extracted/Gut-${GUT_VERSION}/addons/gut" "${ADDON_DIR}"

echo "GUT ${GUT_VERSION} installed to ${ADDON_DIR}."
