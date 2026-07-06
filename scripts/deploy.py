#!/usr/bin/env python
"""Install the built wingman.pack into the local TWW3 install.

The TWW3 launcher (original Total War launcher, NOT the EA Mod Manager)
scans `<TWW3>/data/` for `.pack` files and uses `<TWW3>/used_mods.txt`
to know which packs are enabled. Manual / non-Workshop mods go in
`data/`. Workshop-subscribed mods go in
`<Steam>/steamapps/workshop/content/1142710/<workshop_id>/` and Steam
writes the matching `add_working_directory` line automatically.

This script:
  1. Reads $TWW3 from the environment (or auto-detects the default
     Steam install path).
  2. Copies dist/wingman.pack + dist/wingman.png into `<TWW3>/data/`.
  3. Adds the `mod "wingman.pack";` line to used_mods.txt (idempotent;
     strips any prior wingman entries — including the bogus
     `add_working_directory` lines that earlier versions of this
     script wrote to a fake workshop folder).
  4. Preserves \\r\\n line endings (the launcher's own writes use CRLF).

WHY data/ AND NOT workshop/content/1142710/<fake-id>/

The Workshop folder path is reserved for Steam-managed subscriptions.
The launcher's `add_working_directory` lookup only works for real
Workshop IDs that correspond to active Steam subscriptions. A
manually-created folder with a fake ID is silently ignored. The
canonical install path for non-Workshop mods is `<TWW3>/data/`.
Verified against the Lewdhammer wiki, the Modcu 2025 install guide,
and 12 working mods in the user's own install (all of which live in
either `data/` or workshop/content/1142710/<real-id>/).

USAGE

    # PowerShell:
    $env:TWW3 = "E:\\SteamLibrary\\steamapps\\common\\Total War WARHAMMER III"
    python scripts\\deploy.py

    # Bash:
    TWW3="/e/SteamLibrary/steamapps/common/Total War WARHAMMER III" python scripts/deploy.py

    # Auto-detect (Windows default install only — for non-default, set $TWW3):
    python scripts/deploy.py --auto

The script is idempotent. Re-run any time you change the pack.
For the canonical TWW3 modding reference (PFH5 spec, MCT API, etc.)
see tests/manual/CANONICAL_TWW3_MODDING.md.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path


# Default Steam install paths (Windows). The first one that exists wins.
DEFAULT_TWW3_PATHS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III",
    r"D:\SteamLibrary\steamapps\common\Total War WARHAMMER III",
    r"E:\SteamLibrary\steamapps\common\Total War WARHAMMER III",
    # Steam might be installed to a custom drive; the user can always override.
]


def find_tww3_root() -> Path:
    """Resolve the TWW3 install root from $TWW3 or auto-detect."""
    env = os.environ.get("TWW3", "").strip()
    if env:
        p = Path(env)
        if p.is_dir():
            return p
        raise SystemExit(f"ERROR: $TWW3 is set to {env!r} but that path does not exist.")
    for cand in DEFAULT_TWW3_PATHS:
        if Path(cand).is_dir():
            return Path(cand)
    raise SystemExit(
        "ERROR: Could not auto-detect TWW3. Set $TWW3 to your install path:\n"
        "  e.g. $env:TWW3 = 'E:\\SteamLibrary\\steamapps\\common\\Total War WARHAMMER III'\n"
        "  Or pass --tww3 <path>."
    )


def step(msg: str) -> None:
    print(f"--- {msg} ---")


def clean_wingman_entries(text: str) -> list[str]:
    """Strip every wingman-related line (any separator/format) so we
    can re-append the canonical block. Idempotent re-runs are safe."""
    out = []
    seen_mod = False
    for line in text.splitlines():
        # Drop any add_working_directory line whose quoted path mentions
        # wingman or our (legacy) workshop placeholder.
        if "add_working_directory" in line and ("wingman" in line.lower() or "9999999999" in line):
            continue
        # Drop duplicate mod "wingman.pack"; lines (keep first).
        if re.match(r'\s*mod\s+"wingman\.pack"\s*;', line, re.IGNORECASE):
            if seen_mod:
                continue
            seen_mod = True
        out.append(line)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--tww3", type=str, default=None,
        help="Path to TWW3 install root (overrides $TWW3 and auto-detect).",
    )
    parser.add_argument(
        "--uninstall", action="store_true",
        help="Remove the wingman pack + used_mods.txt entries (revert).",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    tww3 = Path(args.tww3) if args.tww3 else (
        Path(os.environ["TWW3"]) if os.environ.get("TWW3") else find_tww3_root()
    )
    if not tww3.is_dir():
        raise SystemExit(f"ERROR: TWW3 root not found: {tww3}")
    data_dir = tww3 / "data"
    used_mods = tww3 / "used_mods.txt"

    # Verify the pack was built.
    src_pack = repo_root / "dist" / "wingman.pack"
    src_png  = repo_root / "dist" / "wingman.png"
    if not src_pack.is_file():
        raise SystemExit(f"ERROR: {src_pack} not found. Run `python scripts/build_pack.py` first.")
    if not src_png.is_file():
        raise SystemExit(f"ERROR: {src_png} not found. Run `python scripts/build_thumbnail.py` first.")

    if args.uninstall:
        step("Uninstalling")
        for stale in ("wingman.pack", "wingman.png"):
            p = data_dir / stale
            if p.is_file():
                p.unlink()
                print(f"  Removed: {p}")
        if used_mods.is_file():
            raw = used_mods.read_bytes()
            has_crlf = b"\r\n" in raw
            text = raw.decode("utf-8").replace("\r\n", "\n")
            new_lines = clean_wingman_entries(text)
            new_text = "\n".join(new_lines) + "\n"
            if has_crlf:
                new_text = new_text.replace("\n", "\r\n")
            used_mods.write_bytes(new_text.encode("utf-8"))
            print(f"  Cleaned: {used_mods}")
        print("OK: uninstall complete")
        return 0

    # --- Install ---
    step(f"TWW3 install root: {tww3}")
    step(f"Install path:        {data_dir}  (canonical non-Workshop mod location)")
    step(f"Pack source:         {src_pack} ({src_pack.stat().st_size:,} bytes)")
    step(f"Thumbnail source:    {src_png}  ({src_png.stat().st_size:,} bytes)")

    # 1. Copy the pack and thumbnail into <TWW3>/data/.
    data_dir.mkdir(parents=True, exist_ok=True)
    dst_pack = data_dir / "wingman.pack"
    dst_png  = data_dir / "wingman.png"
    shutil.copy(src_pack, dst_pack)
    shutil.copy(src_png, dst_png)
    print(f"  Installed: {dst_pack}")
    print(f"  Installed: {dst_png}")

    # 2. Update used_mods.txt: ensure exactly one 'mod "wingman.pack";' line.
    if not used_mods.is_file():
        raise SystemExit(
            f"ERROR: {used_mods} not found. Run the game once to create it, "
            "then re-run this script."
        )
    raw_bytes = used_mods.read_bytes()
    has_crlf = b"\r\n" in raw_bytes
    text = raw_bytes.decode("utf-8").replace("\r\n", "\n")

    new_lines = clean_wingman_entries(text)
    # Also strip any leftover wingman add_working_directory lines (legacy
    # workshop-folder experiment from earlier commit 6ff12c8).
    new_lines = [
        l for l in new_lines
        if not ("add_working_directory" in l and "wingman" in l.lower())
    ]
    # Append the canonical mod line only if clean_wingman_entries didn't
    # already keep one. data/-based installs do not need an
    # add_working_directory line — the launcher scans data/ directly.
    has_mod_line = any(
        re.match(r'\s*mod\s+"wingman\.pack"\s*;', l, re.IGNORECASE)
        for l in new_lines
    )
    if not has_mod_line:
        new_lines.append('mod "wingman.pack";')
    new_text = "\n".join(new_lines) + "\n"
    if has_crlf:
        new_text = new_text.replace("\n", "\r\n")
    used_mods.write_bytes(new_text.encode("utf-8"))
    print(f'  Updated: {used_mods} (added: mod "wingman.pack";)')

    step("Install complete")
    print("Next: launch TWW3 via the original Total War launcher.")
    print("The MCT panel (top-left settings icon on the main menu) should now")
    print("list 'Wingman — Your AI Co-Pilot' as an enabled mod.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
