#!/usr/bin/env bash
# Build !wingman.pack from repo source using RPFM CLI.
#
# Called from .github/workflows/release.yml after scripts/install_rpfm.sh
# has produced $RPFM_BIN (or after a cache hit restores tools/rpfm/rpfm_cli).
#
# Mod layout: source-of-truth folders are `script/` and `text/` (the same roots
# RPFM's MyMod workflow expects). The output pack uses the `!` prefix for high
# load-order priority, and the file-type is set to Mod (PFHFileType 3).
#
# Thumbnail is copied separately because RPFM packs are data-only.

set -euo pipefail

RPFM_BIN="${RPFM_BIN:-${GITHUB_WORKSPACE:-$(pwd)}/tools/rpfm/rpfm_cli}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
PACK_NAME="!wingman.pack"
PACK_PATH="${REPO_ROOT}/dist/${PACK_NAME}"
WORKSHOP_THUMB="${REPO_ROOT}/assets/workshop/${PACK_NAME}.png"

# Sanity: the binary must exist and be executable.
if [ ! -x "${RPFM_BIN}" ]; then
    echo "ERROR: RPFM_BIN not executable: ${RPFM_BIN}" >&2
    echo "       Run scripts/install_rpfm.sh first, or set RPFM_BIN explicitly." >&2
    exit 1
fi

echo "Building ${PACK_NAME} using ${RPFM_BIN}..."

mkdir -p "${REPO_ROOT}/dist"

# Step 1: Create the empty pack on disk.
"${RPFM_BIN}" pack create --pack-path "${PACK_PATH}"

# Step 2: Set the pack file type. For a TWW3 mod this MUST be Mod (PFH type 3).
"${RPFM_BIN}" pack set-file-type --pack-path "${PACK_PATH}" --file-type Mod

# Step 3: Add every source file under script/ and text/, preserving the
# relative path inside the pack. find -print0 + read -d '' is space-safe.
echo "Adding source files..."
add_file() {
    local src="$1"
    # Strip the repo-root prefix + leading slash to get the in-pack path,
    # e.g. "script/campaign/mod/wingman_init.lua". Use POSIX separators so
    # the in-pack paths are stable across Windows-hosted dev builds.
    local rel="${src#${REPO_ROOT}/}"
    rel="${rel#/}"
    "${RPFM_BIN}" pack add \
        --pack-path "${PACK_PATH}" \
        --source-path "${src}" \
        --pack-path-in-pack "${rel}"
}

# Enumerate and add. If script/ or text/ is missing (unlikely for this repo,
# but defensive against partial checkouts) emit a warning but continue.
for root in "${REPO_ROOT}/script" "${REPO_ROOT}/text"; do
    if [ ! -d "${root}" ]; then
        echo "WARNING: ${root} does not exist; skipping." >&2
        continue
    fi
    while IFS= read -r -d '' f; do
        add_file "$f"
    done < <(find "${root}" -type f -print0 2>/dev/null)
done

# Step 4: Copy the workshop thumbnail next to the pack. RPFM packs don't
# bundle PNGs, so the Workshop uploader expects the thumbnail as a sibling.
if [ -f "${WORKSHOP_THUMB}" ]; then
    cp "${WORKSHOP_THUMB}" "${REPO_ROOT}/dist/${PACK_NAME}.png"
    echo "Thumbnail copied: ${REPO_ROOT}/dist/${PACK_NAME}.png"
else
    echo "WARNING: thumbnail not found at ${WORKSHOP_THUMB}" >&2
fi

# Step 5: Validate the output.
echo "Validating ${PACK_PATH}..."
if [ ! -f "${PACK_PATH}" ]; then
    echo "ERROR: pack file not created at ${PACK_PATH}" >&2
    exit 1
fi

# stat syntax differs between GNU and BSD: try GNU first, then BSD.
if SIZE=$(stat -c%s "${PACK_PATH}" 2>/dev/null); then
    :
elif SIZE=$(stat -f%z "${PACK_PATH}" 2>/dev/null); then
    :
else
    echo "ERROR: stat failed for ${PACK_PATH}" >&2
    exit 1
fi

echo "Pack size: ${SIZE} bytes"
if [ "${SIZE}" -lt 50000 ]; then
    echo "ERROR: pack suspiciously small (${SIZE} bytes); expected >= 50000." >&2
    exit 1
fi

# PFH5 magic check: first 4 bytes are the ASCII bytes 'P','F','H','5' =>
# hex 50 46 48 35. A correctly-created mod pack always starts with this magic.
MAGIC=$(head -c 4 "${PACK_PATH}" | od -An -tx1 | tr -d ' \n')
EXPECTED="50464835"
if [ "${MAGIC}" != "${EXPECTED}" ]; then
    echo "ERROR: not a valid PFH5 pack (magic = ${MAGIC}, expected ${EXPECTED})" >&2
    exit 1
fi

echo "Build successful: ${PACK_PATH} (${SIZE} bytes)"
ls -la "${REPO_ROOT}/dist/"
