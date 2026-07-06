#!/usr/bin/env python3
"""
Wingman pure-Python PFH5 pack builder.

Replaces the RPFM-CLI based build with a direct PFH5 writer. RPFM was
overkill for this mod — we're a script-only pack with no DB tables, no
animations, no models. The PFH5 format is a simple concatenation:

    header  (32 bytes, little-endian)
    file index  (per-file: 4B size, 4B timestamp, null-terminated UTF-8 path)
    file data  (concatenated raw bytes, same order as the index)

This script:
  - Walks script/ and text/ in the repo root
  - Writes a Mod-type PFH5 (Type byte = 0x03)
  - Validates the resulting file's PFH5 magic and a sane size
  - Copies the thumbnail alongside

Run as part of CI (replaces scripts/install_rpfm.sh + build_pack.sh).
Zero external dependencies — works on any Python 3.6+ runtime.

Reference: https://github.com/TotalWar-Modding/docs/blob/master/pack%20file%20format.md
"""

import os
import struct
import sys
import time
from pathlib import Path

# Defaults — NO `!` prefix. The `!` prefix was an older CA convention for
# "highest-priority override" (vanilla + this pack: this wins). Wingman
# only ADDS new files (script/campaign/mod/wingman_*.lua,
# script/mct/settings/wingman_mct.lua, text/db/wingman.loc.tsv) and
# overrides no vanilla files, so the `!` is unnecessary. Worse: in
# practice, `!`-prefixed local packs appear to be skipped by the
# launcher in the user's TWW3 install (TWW3.0+, July 2026 build).
# Subscribed Workshop mods CAN use `!` (the Workshop folder bypasses
# the local-pack loader), but local `!`-prefixed files silently
# never load. Verified empirically: 91 other mod files load, zero
# wingman_*.lua files load, the `!` prefix is the discriminator.
PACK_NAME = "wingman.pack"
THUMB_NAME = "wingman.png"

# Magic bytes for "PFH5"
PFH5_MAGIC = b"PFH5"
# PackFile type: 0=Boot 1=Release 2=Patch 3=Mod 4=Movie. We use Mod (3).
PF_TYPE_MOD = 0x03

# Source roots inside the repo that go into the pack.
SOURCE_ROOTS = ["script", "text"]


def find_source_files(repo_root: Path) -> list[tuple[str, Path]]:
    """Return [(in_pack_path, absolute_disk_path)] for every file to pack."""
    files: list[tuple[str, Path]] = []
    for root_name in SOURCE_ROOTS:
        root_dir = repo_root / root_name
        if not root_dir.is_dir():
            print(f"WARN: source root missing: {root_dir}", file=sys.stderr)
            continue
        for disk_path in sorted(root_dir.rglob("*")):
            if not disk_path.is_file():
                continue
            # In-pack path is repo-relative, with BACKSLASH separators.
            # Verified against every working pack in the user's TWW3
            # install (groovy_mct 142/142 backslash, sm0_recruit_defeated
            # 30/30 backslash, etc.). My pack was using forward slashes
            # and the launcher was silently finding files via the VFS
            # fallback, but MCT's load_mods() iterates /script/mct/settings/
            # with forward slashes and only registers mods whose pack
            # index path matches the canonical (backslash) form. The
            # diagnostic log showed `Registering mod X` for every other
            # MCT mod but never for wingman -- because my pack's
            # file-index paths didn't match the lookup key.
            rel = str(disk_path.relative_to(repo_root)).replace("/", "\\")
            files.append((rel, disk_path))
    return files


def build_file_index(entries: list[tuple[str, int, int]]) -> bytes:
    """
    Serialize the File Index.

    entries: list of (in_pack_path, size_on_disk, timestamp) — one per file.
    Returns the raw index bytes (NOT length-prefixed; the caller computes size).

    Per the canonical PFH5 spec (verified against rpfm_lib
    rpfm_lib/src/files/pack/pack_versions/pfh5.rs, June 2026), each
    entry is:
        u32  data_size        little-endian
        u32  timestamp        little-endian  -- ONLY if header bitmask
                                              HAS_INDEX_WITH_TIMESTAMPS (0x04000000)
                                              is set. We never set it, so this
                                              is omitted.
        u8   is_compressed    0x00 (uncompressed) or 0x01 (compressed).
                              Always present since PFH5, regardless of
                              bitmask. CRITICAL: omitting this byte shifts
                              all path strings by 1 byte, so the launcher
                              reads the first character of the path as the
                              is_compressed flag and the rest as garbage.
                              This is what made the W7/W8 packs load
                              silently into the mod list but never appear
                              in the MCT panel.
        path\0               UTF-8, NUL-terminated. Use forward slashes;
                              the launcher normalizes back-slashes on read.

    Minimum entry size = 4 (size) + 1 (compressed flag) + 1 (NUL for empty
    path) = 6 bytes, per the rpfm_lib source comment "// 6 because 4
    (size) + 1 (compressed?) + 1 (null), 10 because + 4 (timestamp)".
    """
    buf = bytearray()
    for path, size, _ts in entries:
        buf += struct.pack("<I", size)        # data size
        buf += b"\x00"                        # is_compressed = false (PFH5 always has this byte)
        buf += path.encode("utf-8") + b"\x00" # NUL-terminated UTF-8 path
    return bytes(buf)


def build_pfh5(source_files: list[tuple[str, Path, int]], out_path: Path) -> None:
    """
    Write a Mod-type PFH5 pack.

    source_files: list of (in_pack_path, disk_path, timestamp) — order matters
                  (the file index and data sections must use the same order).
    out_path: absolute path to the output .pack file.
    """
    # Read file data into memory up front. Wingman is small (< 100 KB total)
    # so this is fine. For larger mods, stream from disk instead.
    file_payloads: list[bytes] = []
    for _, disk_path, _ in source_files:
        file_payloads.append(disk_path.read_bytes())

    # Build the file index
    file_index_entries = [
        (path, len(payload), ts)
        for (path, _, ts), payload in zip(source_files, file_payloads)
    ]
    file_index_bytes = build_file_index(file_index_entries)

    # Header layout (32 bytes, little-endian):
    #   0-3   : "PFH5"
    #   4-7   : Type + Bitmask. For Mod (3) with no flags: 0x03.
    #   8-11  : PF Index Count. We have no nested pack files → 0.
    #   12-15 : PF Index Size. → 0.
    #   16-19 : File Index Count. → number of files.
    #   20-23 : File Index Size. → byte length of the index.
    #   24-27 : Timestamp (PackFile creation time, Unix seconds).
    #   28-31 : Unknown / reserved. Set to 0.
    now_ts = int(time.time())
    header = b"".join([
        PFH5_MAGIC,
        struct.pack("<I", PF_TYPE_MOD),
        struct.pack("<I", 0),                              # PF index count
        struct.pack("<I", 0),                              # PF index size
        struct.pack("<I", len(source_files)),               # file index count
        struct.pack("<I", len(file_index_bytes)),          # file index size
        struct.pack("<I", now_ts),                         # pack timestamp
        struct.pack("<I", 0),                              # reserved
    ])
    assert len(header) == 32, f"header must be 32 bytes, got {len(header)}"

    # Assemble and write
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as f:
        f.write(header)
        f.write(file_index_bytes)
        for payload in file_payloads:
            f.write(payload)


def validate_pfh5(path: Path) -> None:
    """Read back and verify the magic + header sanity. Crashes loudly on mismatch."""
    with path.open("rb") as f:
        magic = f.read(4)
        if magic != PFH5_MAGIC:
            raise SystemExit(f"FAIL: not a PFH5 archive (magic = {magic!r}, expected {PFH5_MAGIC!r})")
        f.seek(0, 2)
        size = f.tell()
    if size < 64:
        raise SystemExit(f"FAIL: pack suspiciously small ({size} bytes)")
    print(f"OK: {path.name}  ({size:,} bytes)")


def main() -> int:
    repo_root = Path(os.environ.get("REPO_ROOT", Path.cwd()))
    dist_dir = repo_root / "dist"
    pack_path = dist_dir / PACK_NAME
    thumb_src = repo_root / "assets" / "workshop" / THUMB_NAME
    thumb_dst = dist_dir / THUMB_NAME

    print(f"Building {PACK_NAME} from {repo_root} (pure-Python PFH5 writer)...")

    # Discover source files
    source_files = find_source_files(repo_root)
    if not source_files:
        raise SystemExit(f"FAIL: no source files found under {SOURCE_ROOTS} in {repo_root}")
    print(f"Source files: {len(source_files)}")
    for in_pack, _ in source_files[:5]:
        print(f"  + {in_pack}")
    if len(source_files) > 5:
        print(f"  ... ({len(source_files) - 5} more)")

    # Assign a single creation timestamp to all files (we don't care about per-file mtimes —
    # the game reads file content by path, not by timestamp).
    now_ts = int(time.time())
    source_files_with_ts = [(p, d, now_ts) for (p, d) in source_files]

    # Build the pack
    dist_dir.mkdir(parents=True, exist_ok=True)
    build_pfh5(source_files_with_ts, pack_path)

    # Copy the thumbnail next to the pack (the launcher reads them as siblings)
    if not thumb_src.is_file():
        raise SystemExit(f"FAIL: thumbnail not found at {thumb_src}")
    thumb_dst.write_bytes(thumb_src.read_bytes())
    print(f"Thumbnail copied: {thumb_dst}")

    # Validate
    validate_pfh5(pack_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())