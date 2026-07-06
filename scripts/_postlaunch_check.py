"""Post-launch diagnostic: pull the exact evidence from the latest !groove_log.txt.

Run after the user relaunches TWW3. Prints:
  - Deployed pack SHA + size
  - Log file mtime (proves it's fresh)
  - ALL wingman-related lines from the log (load + body output + errors)
  - Whether 'Registering mod wingman' appears (smoking gun for body execution)
  - Whether 'Failed to load mod file wingman_mct.lua' appears (loud failure mode)
  - Whether '[Wingman] MCT registration complete' appears (success signal)
  - For comparison: the same checks for recruit_defeated (the working mod)
"""
import hashlib
import os
import sys

PACK = r'E:/SteamLibrary/steamapps/common/Total War WARHAMMER III/data/wingman.pack'
LOG = r'E:/SteamLibrary/steamapps/common/Total War WARHAMMER III/!groove_log.txt'

print("=== DEPLOYED STATE ===")
h = hashlib.sha256(open(PACK, 'rb').read()).hexdigest()[:16]
size = os.path.getsize(PACK)
log_mtime = os.path.getmtime(LOG)
pack_mtime = os.path.getmtime(PACK)
print(f"  pack SHA: {h}")
print(f"  pack size: {size} bytes")
print(f"  log mtime:  {log_mtime:.0f}")
print(f"  pack mtime: {pack_mtime:.0f}")
print(f"  log FRESHER than pack: {log_mtime > pack_mtime}")
print()

if not os.path.isfile(LOG):
    print("FAIL: !groove_log.txt not found")
    sys.exit(1)

with open(LOG, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
print(f"=== LOG: {len(lines)} lines ===")
print()

# Find the wingman load + everything after
wingman_load_idx = None
for i, line in enumerate(lines):
    if 'wingman_mct.lua' in line and 'Loading module w/ full path' in line:
        wingman_load_idx = i
        break

if wingman_load_idx is None:
    print("FAIL: wingman_mct.lua not found in log")
    print("(user may not have reached the MCT load phase yet)")
    sys.exit(1)

print("=== WINGMAN_MCT.LUA LOAD SEQUENCE ===")
# Show 50 lines starting from the load
for i in range(wingman_load_idx, min(wingman_load_idx + 50, len(lines))):
    line = lines[i].rstrip()
    if 'wingman' in line.lower() or 'Wingman' in line or 'Failed to load' in line:
        print(f"  L{i+1}: {line}")
print()

# Smoking-gun checks
print("=== SMOKING-GUN CHECKS ===")
all_text = ''.join(lines)

checks = [
    ('Registering mod wingman', 'BODY EXECUTED (register_mod called)'),
    ('[Wingman] MCT registration complete', 'SUCCESS (all 31 options + 4 sections registered)'),
    ('Failed to load mod file wingman_mct.lua', 'LOUD FAILURE (outer loader caught the error)'),
    ('[Wingman] WARNING', 'MCT NOT LOADED (the old early-return block would have printed this)'),
    ('[Wingman DEBUG]', 'Diagnostic noise (should be 0)'),
    ('[Wingman FATAL]', 'Diagnostic noise (should be 0)'),
]
for needle, meaning in checks:
    count = all_text.count(needle)
    status = 'FOUND' if count > 0 else 'NOT FOUND'
    print(f"  [{status}] {needle!r:50s} x{count}  -- {meaning}")
print()

# Comparison with recruit_defeated (the working mod)
print("=== COMPARISON: recruit_defeated_settings.lua (working mod) ===")
for i, line in enumerate(lines):
    if 'recruit_defeated_settings.lua' in line and 'Loading module w/ full path' in line:
        for j in range(i, min(i + 8, len(lines))):
            print(f"  L{j+1}: {lines[j].rstrip()}")
        break
print()

# Final verdict
if '[Wingman] MCT registration complete' in all_text:
    print("=== VERDICT: WINGMAN REGISTERED SUCCESSFULLY ===")
    print("MCT panel should show 'Wingman -- Your AI Co-Pilot'")
elif 'Failed to load mod file wingman_mct.lua' in all_text:
    print("=== VERDICT: LOUD FAILURE (good -- we can now see the actual error) ===")
    # Find and print the error
    for i, line in enumerate(lines):
        if 'Failed to load mod file wingman_mct.lua' in line:
            for j in range(max(0, i-2), min(i+10, len(lines))):
                print(f"  L{j+1}: {lines[j].rstrip()}")
            break
elif 'Registering mod wingman' not in all_text:
    print("=== VERDICT: BODY STILL NOT EXECUTING (same bug as before) ===")
    print("The body goes from 'Loading module' to 'loaded successfully!' with no body output.")
    print("This means the file body returned early OR threw silently BEFORE mct:register_mod('wingman').")
else:
    print("=== VERDICT: UNCLEAR -- needs more analysis ===")
