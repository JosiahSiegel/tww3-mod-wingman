#!/usr/bin/env python
"""Install the built wingman.pack into the local TWW3 install.

The TWW3 launcher (original Total War launcher, NOT the EA Mod Manager)
loads mods from `add_working_directory` paths listed in
`<TWW3>/used_mods.txt`. Each path is a Workshop-style folder named
`<appid>/<workshop_id>/` containing `<modname>.pack` + `<modname>.png`.

This script:
  1. Reads $TWW3 from the environment (or auto-detects the default
     Steam install path).
  2. Copies dist/wingman.pack + dist/wingman.png into the workshop
     folder `<TWW3>/workshop/content/1142710/<WINGMAN_LOCAL_ID>/`.
  3. Adds the `add_working_directory` line to used_mods.txt (idempotent).
  4. Ensures `mod "wingman.pack";` is enabled in used_mods.txt.
  5. Removes any stale copy from `<TWW3>/data/` so the launcher's
     duplicate detection doesn't get confused.

WHY THIS EXISTS

The original TWW3 launcher's Mod Manager reads used_mods.txt and
looks for each `mod "X.pack";` entry in the corresponding
`add_working_directory` paths. A `.pack` placed directly in
`<TWW3>/data/` is NOT scanned for mod entries — that folder is for
the vanilla game + early-style local mods without MCT integration.
Wingman uses the modern MCT integration path, so it must live in a
workshop-style folder.

For published Workshop items, Steam assigns the workshop_id at upload
time and the launcher writes the add_working_directory entry
automatically. For local-only testing, we use a placeholder ID
(9999999999) — change WORKSHOP_ID in this script when you publish
and re-run.

USAGE

    # PowerShell:
    $env:TWW3 = "E:\\SteamLibrary\\steamapps\\common\\Total War WARHAMMER III"
    python scripts/deploy.py

    # Bash:
    TWW3="/e/SteamLibrary/steamapps/common/Total War WARHAMMER III" python scripts/deploy.py

    # Auto-detect (Windows default install only — for non-default, set $TWW3):
    python scripts/deploy.py --auto

The script prints every step. Re-run any time you change the pack.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path


# Local-only workshop ID placeholder. After you publish to Steam
# Workshop, set this to the real ID and re-run.
WORKSHOP_ID = "9999999999"

# Steam AppID for Total War: WARHAMMER III
APP_ID = "1142710"

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
    # Auto-detect
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--tww3", type=str, default=None,
        help="Path to TWW3 install root (overrides $TWW3 and auto-detect).",
    )
    parser.add_argument(
        "--workshop-id", type=str, default=WORKSHOP_ID,
        help="Workshop folder ID to use for local install (default: 9999999999).",
    )
    parser.add_argument(
        "--uninstall", action="store_true",
        help="Remove the workshop folder + used_mods.txt entries (revert).",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    tww3 = Path(args.tww3) if args.tww3 else (
        Path(os.environ["TWW3"]) if os.environ.get("TWW3") else find_tww3_root()
    )
    if not tww3.is_dir():
        raise SystemExit(f"ERROR: TWW3 root not found: {tww3}")
    workshop_id = args.workshop_id

    # Verify the pack was built.
    src_pack = repo_root / "dist" / "wingman.pack"
    src_png  = repo_root / "dist" / "wingman.png"
    if not src_pack.is_file():
        raise SystemExit(f"ERROR: {src_pack} not found. Run `python scripts/build_pack.py` first.")
    if not src_png.is_file():
        raise SystemExit(f"ERROR: {src_png} not found. Run `python scripts/build_thumbnail.py` first.")

    # Workshop folder = <TWW3>/workshop/content/<APP_ID>/<WORKSHOP_ID>/
    ws_dir = tww3 / "workshop" / "content" / APP_ID / workshop_id
    used_mods = tww3 / "used_mods.txt"
    # The launcher writes used_mods.txt with forward-slash paths (verified
    # against existing add_working_directory entries). On Windows, Path.as_posix()
    # gives us the same forward-slash form regardless of OS native separator.
    ws_dir_posix = ws_dir.as_posix()

    if args.uninstall:
        step("Uninstalling")
        if ws_dir.is_dir():
            shutil.rmtree(ws_dir)
            print(f"  Removed: {ws_dir}")
        if used_mods.is_file():
            text = used_mods.read_text(encoding="utf-8")
            # Remove the wingman block: add_working_directory + mod "wingman.pack";
            new_text = re.sub(
                r'add_working_directory "[^"]*wingman[^"]*";\s*\n?',
                '',
                text,
                flags=re.IGNORECASE,
            )
            new_text = re.sub(
                r'mod "wingman\.pack";\s*\n?',
                '',
                new_text,
                flags=re.IGNORECASE,
            )
            if new_text != text:
                used_mods.write_text(new_text, encoding="utf-8")
                print(f"  Cleaned: {used_mods}")
        # Also remove stale data/ copies
        for stale in ("wingman.pack", "wingman.png"):
            p = tww3 / "data" / stale
            if p.is_file():
                p.unlink()
                print(f"  Removed: {p}")
        print("OK: uninstall complete")
        return 0

    # --- Install ---
    step(f"TWW3 install root: {tww3}")
    step(f"Workshop folder:    {ws_dir}")
    step(f"Pack source:        {src_pack} ({src_pack.stat().st_size:,} bytes)")
    step(f"Thumbnail source:   {src_png}  ({src_png.stat().st_size:,} bytes)")

    # 1. Create the workshop folder + copy the pack and thumbnail.
    ws_dir.mkdir(parents=True, exist_ok=True)
    dst_pack = ws_dir / "wingman.pack"
    dst_png  = ws_dir / "wingman.png"
    shutil.copy(src_pack, dst_pack)
    shutil.copy(src_png, dst_png)
    print(f"  Installed: {dst_pack}")
    print(f"  Installed: {dst_png}")

    # 2. Update used_mods.txt: add_working_directory + mod "wingman.pack";
    if not used_mods.is_file():
        raise SystemExit(f"ERROR: {used_mods} not found. Run the game once to create it.")
    # The TWW3 launcher writes used_mods.txt with Windows \r\n line
    # endings. We normalize to \n for processing and write back with
    # the same endings it had, so we don't disturb the file format.
    raw_bytes = used_mods.read_bytes()
    has_crlf = b'\r\n' in raw_bytes
    text = raw_bytes.decode('utf-8').replace('\r\n', '\n')

    add_working_dir_line = f'add_working_directory "{ws_dir_posix}";'
    mod_line = 'mod "wingman.pack";'

    # Always start from a clean state: strip any pre-existing wingman
    # entries (any separator form), strip any duplicate mod lines, then
    # write the canonical block. This makes re-runs safe even if a
    # prior run wrote the wrong path or a duplicate mod line.
    new_lines = []
    for line in text.splitlines():
        if 'add_working_directory' in line and ('wingman' in line or workshop_id in line):
            continue  # drop our add_working_directory (any separator)
        if re.match(r'\s*mod\s+"wingman\.pack"\s*;', line, re.IGNORECASE):
            continue  # drop our mod line (we re-append below)
        new_lines.append(line)
    # Append the canonical block (forward-slash path, single source of truth).
    new_lines.append(add_working_dir_line)
    new_lines.append(mod_line)
    new_text = '\n'.join(new_lines) + '\n'
    if has_crlf:
        new_text = new_text.replace('\n', '\r\n')
    used_mods.write_bytes(new_text.encode('utf-8'))
    print(f"  Wrote canonical block: {add_working_dir_line}")
    print(f"                        {mod_line}")

    used_mods.write_bytes(new_text.encode('utf-8'))
    print(f"  Updated: {used_mods}")

    # 3. Remove any stale copy from <TWW3>/data/ (the launcher won't
    #    find it there, but having a stale .pack confuses the deploy
    #    process and the test scripts).
    for stale in ("wingman.pack", "wingman.png"):
        p = tww3 / "data" / stale
        if p.is_file():
            p.unlink()
            print(f"  Removed stale: {p}")

    step("Install complete")
    print("Next: launch TWW3 via the original Total War launcher.")
    print("The MCT panel (top-left settings icon on the main menu) should now")
    print("list 'Wingman - Your AI Co-Pilot' as an enabled mod.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
