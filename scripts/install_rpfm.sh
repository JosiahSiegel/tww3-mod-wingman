#!/usr/bin/env bash
# Install RPFM CLI v4.5.4 for CI builds.
#
# v4.5.4 is the last release with a true CLI binary (v5+ uses a server + WebSocket,
# which is overkill for headless pack assembly in CI).
#
# Workflow should cache `tools/rpfm` keyed on RPFM_VERSION
# (see .github/workflows/release.yml) — this script is idempotent and
# fast-skips the install if the cached binary is already executable.
#
# Archive layout (verified by inspecting the tarball):
#   rpfm-v4.5.4-x86_64-unknown-linux-gnu/    <- strip 1
#     usr/
#       bin/rpfm_cli                         <- target binary
#       bin/rpfm_ui
#       share/rpfm/icons/*                   <- runtime resources (relative paths)
#       share/rpfm/locale/*
#       share/rpfm/ui/*
#       share/applications/rpfm.desktop
#       share/licenses/rpfm/LICENSE
#
# `--strip-components=1` keeps the `usr/` subtree intact because the binary
# resolves sibling resources (icons, locale) relative to its own location.
# Final path on disk: tools/rpfm/usr/bin/rpfm_cli
#
# Notes for tar compatibility:
#   - `--strip-components` requires GNU tar. GitHub-hosted ubuntu-latest runners
#     use GNU tar, so this is safe.
#   - `tar --use-compress-program=unzstd` requires the `zstd` package. On
#     ubuntu-latest it is preinstalled; if absent we install it via apt-get.
set -euo pipefail

RPFM_VERSION="4.5.4"
RPFM_TARBALL="rpfm-v${RPFM_VERSION}-x86_64-unknown-linux-gnu.tar.zst"
RPFM_URL="https://github.com/Frodo45127/rpfm/releases/download/v${RPFM_VERSION}/${RPFM_TARBALL}"

# GITHUB_WORKSPACE is set inside Actions; fall back to cwd for local testing.
TOOLS_DIR="${GITHUB_WORKSPACE:-$(pwd)}/tools/rpfm"
RPFM_BIN="${TOOLS_DIR}/usr/bin/rpfm_cli"

# Idempotency: if the cached binary is already executable, skip the heavy work.
if [ -x "${RPFM_BIN}" ]; then
    echo "rpfm_cli already installed at ${RPFM_BIN}"
    echo "RPFM_BIN=${RPFM_BIN}"
    exit 0
fi

# Ensure zstd (and therefore unzstd) is available. Preinstalled on ubuntu-latest,
# but degrade gracefully for local dev / future runner images.
if ! command -v unzstd >/dev/null 2>&1; then
    echo "Installing zstd (unzstd not found)..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq zstd
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y zstd
    else
        echo "ERROR: zstd not installed and no supported package manager found." >&2
        exit 1
    fi
fi

mkdir -p "${TOOLS_DIR}"

# Download to a tmpdir (cleaned up below) to keep the repo directory tidy.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"

echo "Downloading ${RPFM_URL}..."
curl -fsSL "${RPFM_URL}" -o "${RPFM_TARBALL}"

echo "Extracting to ${TOOLS_DIR}..."
# Strip only the top-level `rpfm-v4.5.4-x86_64-unknown-linux-gnu/` directory.
# The `usr/` subtree is preserved so the binary's relative path lookups
# (`../share/rpfm/icons/...`) still resolve.
tar --use-compress-program=unzstd -xf "${RPFM_TARBALL}" -C "${TOOLS_DIR}" --strip-components=1

if [ ! -x "${RPFM_BIN}" ]; then
    echo "ERROR: rpfm_cli binary not found at ${RPFM_BIN} after extraction." >&2
    echo "Archive contents (first 20 entries):" >&2
    tar --use-compress-program=unzstd -tf "${RPFM_TARBALL}" 2>/dev/null | head -20 >&2
    exit 1
fi

echo "RPFM installed at ${RPFM_BIN}"
# rpfm_cli --version may not be supported in all subcommand sets; non-fatal if it fails.
"${RPFM_BIN}" --version 2>/dev/null || echo "(rpfm_cli --version probe failed; binary is present, proceeding)"

# MUST be the last line so the workflow can `grep '^RPFM_BIN='` to capture the path.
echo "RPFM_BIN=${RPFM_BIN}"