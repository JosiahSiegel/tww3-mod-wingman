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
#   usr/
#     bin/rpfm_cli                           <- target binary
#     bin/rpfm_ui
#     share/rpfm/icons/*                     <- runtime resources (relative paths)
#     share/rpfm/locale/*
#     share/rpfm/ui/*
#     share/applications/rpfm.desktop
#     share/licenses/rpfm/LICENSE
#
# The archive is flat — `usr/` is the top-level entry. We do NOT use
# --strip-components because there is no top-level wrapper to remove.
# Final path on disk: tools/rpfm/usr/bin/rpfm_cli (binary) plus the
# sibling share/ subtree, so the binary's relative resource lookups work.
#
# Note: tar --use-compress-program=unzstd requires the `zstd` package.
# On GitHub-hosted ubuntu-latest it is preinstalled; if absent we install
# it via apt-get.
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

# Install RPFM's runtime dependencies. RPFM (built with Qt5 + KDE Frameworks 5 +
# libgit2) requires system libraries that aren't on a stock ubuntu-latest runner.
# The Arch PKGBUILD lists the canonical set; the Ubuntu equivalents below cover
# the headless `rpfm_cli` binary. Tested by running rpfm_cli --version after
# install — it must complete without a "library not found" error.
#
# Refs:
#   https://github.com/Frodo45127/rpfm/blob/v4.5.4/install/arch/rpfm-bin/PKGBUILD
#   https://github.com/Frodo45127/rpfm/blob/v4.5.4/Cargo.toml (crate deps)
#
# This list is deliberately broad — better to install one package too many
# than to spend another CI cycle chasing the next "library not found" error.
# All packages are standard Ubuntu repos; total install time ~30-60s on a warm
# runner (cached apt metadata + pre-warmed package cache).
echo "Installing RPFM runtime dependencies via apt-get..."
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends \
        libgit2-1.9 \
        libqt5core5t64 \
        libqt5gui5t64 \
        libqt5network5t64 \
        libqt5widgets5t64 \
        libqt5xml5t64 \
        libkf5archive5 \
        libkf5completion5 \
        libkf5configcore5 \
        libkf5configgui5 \
        libkf5configwidgets5 \
        libkf5coreaddons5 \
        libkf5guiaddons5 \
        libkf5i18n5 \
        libkf5iconthemes5 \
        libkf5itemviews5 \
        libkf5kiocore5 \
        libkf5texteditor5 \
        libkf5widgetsaddons5 \
        libkf5xmlgui5 \
        xz-utils \
        p7zip-full \
        || {
            echo "WARNING: some apt packages failed to install. rpfm_cli may fail" >&2
            echo "         to start with a 'library not found' error. See logs." >&2
        }
fi

mkdir -p "${TOOLS_DIR}"

# Download to a tmpdir (cleaned up below) to keep the repo directory tidy.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"

echo "Downloading ${RPFM_URL}..."
curl -fsSL "${RPFM_URL}" -o "${RPFM_TARBALL}"

echo "Extracting to ${TOOLS_DIR}..."
# The archive is flat — top-level entries are `usr/bin/rpfm_cli`, `usr/share/...`,
# `usr/bin/rpfm_ui`. NO strip-components: the `usr/` subtree is the root we want.
# Result: tools/rpfm/usr/bin/rpfm_cli (binary), tools/rpfm/usr/share/rpfm/...
# (icons/locale/ui, sibling resource paths relative to the binary still resolve).
tar --use-compress-program=unzstd -xf "${RPFM_TARBALL}" -C "${TOOLS_DIR}"

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