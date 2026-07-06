"""One-shot diagnostic: extract Wingman debug lines from the user's !groove_log.txt.

Run after relaunching TWW3 via the original launcher:

    py scripts/extract_diag.py

Prints every [Wingman DEBUG], [WingmanTest DEBUG], and [Wingman FATAL] line
from the most recent !groove_log.txt. The pattern of which line is LAST
tells us exactly where wingman_mct.lua's body bails:

  - If T0..T11 (wingman_test) all log OK and the full file's first D-line
    (D0 = "file loading") logs but nothing after: file body bails at D1
    (get_mct call) -- environment issue (get_mct is nil).

  - If D0..D2 log but D3 doesn't: get_mct() returned OK but
    mct:register_mod("wingman") threw -- duplicate-key, key validation,
    or mod class instantiation issue.

  - If D0..D3 log but D4..D8 don't: one of the 4 canonical chadvandy
    setup calls threw. Read the [Wingman FATAL] line for the method name.

  - If D0..D12 (sections) log and a specific SECTION prints === ... ===
    but not DONE: an option in that section's add_new_option / set_text /
    set_tooltip_text call threw. The SECTION-FATAL line tells which.

  - If NO [Wingman DEBUG] lines log at all but wingman_mct.lua reports
    "loaded successfully": the file body is being bypassed entirely
    (loader short-circuits on the file). This is a different class of
    bug (path resolution or sandboxing).
"""
import os
import re
import sys
from pathlib import Path

# TWW3 install path (the same one scripts/deploy.py uses)
TWW3 = Path(os.environ.get("TWW3", r"E:/SteamLibrary/steamapps/common/Total War WARHAMMER III"))
LOG = TWW3 / "!groove_log.txt"

if not LOG.is_file():
    print(f"FAIL: log file not found: {LOG}")
    print("Set TWW3 env var if your install is in a non-default location.")
    sys.exit(1)

print(f"Reading {LOG} ({LOG.stat().st_size:,} bytes) ...")

# Extract relevant lines
patterns = [
    re.compile(r"\[Wingman DEBUG\]"),
    re.compile(r"\[WingmanTest DEBUG\]"),
    re.compile(r"\[Wingman FATAL\]"),
    re.compile(r"\[WingmanTest FATAL\]"),
    re.compile(r"wingman_mct\.lua"),
    re.compile(r"wingman_test_mct\.lua"),
    re.compile(r"Failed to load mod file"),
    re.compile(r"Registering mod wingman"),
    re.compile(r"Registered mod wingman"),
    re.compile(r"Creating a new option .*wingman"),
]

# Find the last "game session" start (the loader prints a header) so we
# only show the most recent run's output, not historical noise.
content = LOG.read_text(encoding="utf-8", errors="replace")
all_lines = content.splitlines()

# Find the indices of all our patterns, then take the last contiguous cluster
# (everything from the most recent script_log timestamp / load_mods start).
def find_last_session_start(lines):
    """Walk backwards to find the most recent session boundary."""
    for i in range(len(lines) - 1, -1, -1):
        if "[lib] Loading module w/ full path \"script\\\\groovy\\\\modules\\\\command_manager\\\\main.lua\"" in lines[i]:
            return i
        if "[lib] Loading module w/ full path \"script/mct/settings/wingman_mct.lua\"" in lines[i]:
            return max(0, i - 50)
    return 0

start = find_last_session_start(all_lines)
print(f"Showing from line {start + 1} to end of {LOG.name} (most recent session)")
print("=" * 80)

hits = []
for i, line in enumerate(all_lines[start:], start=start):
    for pat in patterns:
        if pat.search(line):
            hits.append((i + 1, line))
            break

if not hits:
    print("NO MATCHES. The log contains no [Wingman DEBUG] / [WingmanTest DEBUG] /")
    print("[Wingman FATAL] / 'wingman_mct.lua' / 'Registering mod wingman' lines.")
    print()
    print("Possible reasons:")
    print("  1. TWW3 hasn't been relaunched since the debug build was deployed")
    print("     (pack mtime should be 2026-07-06 ~17:06).")
    print("  2. The launcher is loading the OLD pack from the Workshop folder")
    print("     instead of the local data\\wingman.pack. Verify with:")
    print("       ls -la 'E:/SteamLibrary/.../data/wingman.pack'")
    print("       ls -la 'E:/SteamLibrary/.../workshop/content/1142710/' | grep wingman")
    print("  3. The launcher is ignoring wingman.pack entirely (silent skip).")
    print("     Check used_mods.txt has 'mod \"wingman.pack\";' in it.")
else:
    for lineno, line in hits:
        print(f"  L{lineno:>5}: {line}")

print()
print("=" * 80)
print(f"Total: {len(hits)} matching lines in the most recent session.")
print()
print("Copy everything between the '===' bars and paste back to Claude.")
