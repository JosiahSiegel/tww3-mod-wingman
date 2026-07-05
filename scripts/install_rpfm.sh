#!/usr/bin/env bash
# Install RPFM CLI v4.5.4 for CI builds.
#
# v4.5.4 is the last release with a true CLI binary (v5+ uses a server + WebSocket,
# which is overkill for headless pack assembly in CI).
#
# Workflow should cache `tools/rpfm` keyed on RPFM_VERSION
# (see .github/workflows/release.yml) — this script is idempotent and
# fast-skips the install if the cached binary is already present and executable.
#
# Notes for tar compatibility:
#   - `--strip-components` requires GNU tar. GitHub-hosted ubuntu-latest runners
#     use GNU tar, so this is safe. On BSD/macOS tar, replace with manual
#     `mv $(find ... -type f) tools/rpfm/` equivalent.
#   - `tar --use-compress-program=unzstd` requires the `zstd` package. On
#     ubuntu-latest it is preinstalled; if absent we install it via apt-get.
set -euo pipefail

RPFM_VERSION="4.5.4"
RPFM_TARBALL="rpfm-v${RPFM_VERSION}-x86_64-unknown-linux-gnu.tar.zst"
RPFM_URL="https://github.com/Frodo45127/rpfm/releases/download/v${RPFM_VERSION}/${RPFM_TARBALL}"

# GITHUB_WORKSPACE is set inside Actions; fall back to cwd for local testing.
TOOLS_DIR="${GITHUB_WORKSPACE:-$(pwd)}/tools/rpfm"

# Idempotency: if the cached binary is already executable, skip the heavy work.
if [ -x "${TOOLS_DIR}/rpfm_cli" ]; then
    echo "rpfm_cli already installed at ${TOOLS_DIR}/rpfm_cli"
    echo "RPFM_BIN=${TOOLS_DIR}/rpfm_cli"
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
# --strip-components=1 removes the top-level `rpfm-v4.5.4-x86_64-unknown-linux-gnu/`
# directory so the binary lands directly at tools/rpfm/rpfm_cli.
tar --use-compress-program=unzstd -xf "${RPFM_TARBALL}" -C "${TOOLS_DIR}" --strip-components=1

chmod +x "${TOOLS_DIR}/rpfm_cli"

echo "RPFM installed at ${TOOLS_DIR}"
# rpfm_cli --version may not be supported in all subcommand sets; non-fatal if it fails.
"${TOOLS_DIR}/rpfm_cli" --version 2>/dev/null || echo "(rpfm_cli --version probe failed; binary is present, proceeding)"

# MUST be the last line so the workflow can `grep '^RPFM_BIN='` to capture the path.
echo "RPFM_BIN=${TOOLS_DIR}/rpfm_cli"
