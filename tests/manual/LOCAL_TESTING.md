# Wingman — Local Testing Guide

End-to-end guide for running Wingman on a development machine **before** publishing to Steam Workshop. Covers the build, install, in-game smoke, and the iterative dev loop.

> **Audience**: Contributors, testers, and the author. **Not for end-users** — they get `!wingman.pack` from the Workshop.

---

## TL;DR (5-minute smoke)

If you've already built and installed once and just want to re-verify a code change:

```bash
# 1. Rebuild the pack
python scripts/build_pack.py

# 2. Copy into TWW3 (PowerShell)
Copy-Item "dist\!wingman.pack" "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.pack" -Force

# 3. Tail the script log while you play
tail -f "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\script_log_*.txt"

# 4. Launch TWW3 (original launcher, NOT EA Mod Manager)
# 5. Mod Manager: tick MCT + Wingman → Play
# 6. New IE campaign, Reikland → verify the [Wingman] init line appears in the log
```

If the init line appears, the mod is at least bootable. Run the full scenarios for deeper verification.

---

## Prerequisites

| Tool | Why | Where |
|---|---|---|
| Total War: WARHAMMER III (Steam) | Game to mod | `C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III` |
| Steam | Launcher + subscription | https://store.steampowered.com/app/1142710 |
| [Mod Configuration Tool (MCT)](https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021) | Required dependency for Wingman settings UI | Subscribe via Steam Workshop |
| Python 3.6+ | Runs `scripts/build_pack.py` and `scripts/lupa_smoke.py` | Pre-installed everywhere |
| Python 3.11+ with Pillow | Optional: regenerate the thumbnail if you change `assets/workshop/build_thumbnail.py` | `pip install Pillow` |

That's it. **No RPFM, no Assembly Kit, no 100+ MB binary downloads, no Qt/KDE runtime libraries.** The packer is ~150 lines of pure Python implementing the [PFH5 format spec](https://github.com/TotalWar-Modding/docs/blob/master/pack%20file%20format.md) directly.

---

## Step 1: Build the pack (< 1 second)

Every code change requires a rebuild — but the rebuild is instant:

1. **Edit source** in this repo (any `.lua`, `.tsv`, `.png`).
2. **Run**: `python scripts/build_pack.py`
3. **Verify output**: `dist/!wingman.pack` (~200 KB) and `dist/!wingman.png` are written. The script also validates the PFH5 magic (`50464835`) on the output.

**Iterative dev loop time**: < 1 second from edit to fresh pack, dominated by Python startup + file reads.

> **Why no RPFM?** RPFM is a great general-purpose tool for TWW3 modding — schema validation, animation conversion, DB table editors, etc. But for a script-only mod like Wingman, all of that is dead weight. The PFH5 format is a ~10 KB spec and our use case is file concatenation. A pure-Python packer is faster, deterministic, has zero apt dependencies, and the failure mode is "open the file in a hex editor" instead of "install Qt5 libraries on the build server."

---

## Step 3: Install the thumbnail and enable script logging (one-time)

These two steps must happen **once** before the first test run.

### Thumbnail

The Workshop launcher needs `!wingman.png` next to the `.pack` for the Mod Manager tile to render.

```bash
# PowerShell (run from the repo root)
Copy-Item "assets\workshop\!wingman.png" "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.png"
```

The filename MUST match the `.pack` base name exactly (case-sensitive, no extra characters).

### Script logging

By default TWW3 swallows `out()` calls. To make Wingman's structured logs visible:

```bash
# PowerShell
New-Item -ItemType File -Path "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\script\enable_console_logging" -Force
```

That empty file (no extension) is the trigger. From now on, every `out("[Wingman] ...")` line in any mod will be written to `script_log_*.txt` in the game folder.

> **Also enable via**: MCT has a "Script Logging" toggle in some versions. Or use the [Script Debug Activator](https://steamcommunity.com/sharedfiles/filedetails/?id=2789857593) Workshop mod.

---

## Step 4: Launch and verify boot (~3 minutes)

### Launch path (CRITICAL — read carefully)

TWW3 has **two** launcher experiences as of late 2025:

1. **Original Total War launcher** — has the Mod Manager, supports Workshop uploads. ✓ **Use this for testing.**
2. **New EA Mod Manager (Early Access)** — does NOT support Workshop uploads yet. ✗ **Do NOT use for testing.**

To pick the original launcher:

1. Right-click TWW3 in your Steam library → Properties → General → Launch Options → set to `Ask when starting game`.
2. Launch TWW3.
3. Choose **"Original launcher"** at the boot chooser.
4. Tick "Always use this option" to skip the chooser next time.

### Enable the mods

1. In the launcher, click **Mod Manager**.
2. Verify both mods appear in the list:
   - **Mod Configuration Tool** (subscribed from Workshop)
   - **!wingman** (just installed to `data/`)
3. Tick both. **MCT first** (load order).
4. Click **Play**.

### Verify boot

The campaign loading screen appears. While it loads:

1. Open the game folder (`<TWW3>/`) and locate `script_log_*.txt` — there should be one new file per launch with today's date.
2. Open it in your text editor.
3. Search for `[Wingman]` (Ctrl+F). You should see lines like:

```
[Wingman] init: enter
[Wingman] init complete. mode=disabled, campaign_handover=false, battle_handover=false
```

If you see those, the mod loaded cleanly.

If you see only `[Wingman] WARNING: MCT (Mod Configuration Tool) is not loaded.`, MCT didn't subscribe or wasn't ticked — fix and retry.

### Where logs go

| Log | Path |
|---|---|
| Script log (with `enable_console_logging` flag) | `<TWW3>/script_log_*.txt` |
| (Sometimes) deeper logs | `%APPDATA%\The Creative Assembly\Warhammer3\logs\` |

Search for the most recent timestamp when debugging.

---

## Step 5: Run scenarios

Open `tests/manual/wingman_scenarios.md` for the full S1–S10 matrix. **Start with these four**:

| Scenario | Purpose | Time |
|---|---|---|
| **S7** Workshop/local install regression | Confirm mod loads at all | 2 min |
| **S1** Campaign handover happy path | Confirm core orchestration | 10 min |
| **S6** Save/load persistence | Confirm state restoration | 10 min |
| **S10** Multiplayer guard | Confirm safety | 15 min (requires MP partner) |

Run **S3, S4, S5, S8, S9** next for deeper coverage. Each scenario has:
- **Setup** — exact settings to enter via MCT
- **Steps** — concrete button clicks
- **Pass condition** — binary observable (log line + state)
- **Evidence** — files to save (`tests/manual/evidence/<scenario_id>.log`, `.png`, `.save`)
- **Fail signals** — what a bug looks like and which module owns the fix

### 5-minute smoke (alternative)

If you don't have time for full scenarios, do this:

1. Boot to campaign (Step 4). Verify `[Wingman] init` in log.
2. Open MCT → Wingman → set `wingman_enabled = true`, `wingman_campaign_handover_enabled = true`.
3. Set `wingman_auto_end_turn_delay_seconds = 2`.
4. End turn manually.
5. Wait 5 seconds. Verify turn counter advanced.
6. Save + reload. Verify settings persist.
7. Quit.

If 1–7 pass, the mod is at least bootable and the core orchestration works.

---

## Step 6: Iterative dev loop

The cycle for any code change:

```
┌─────────────────────────────────────────────────────────┐
│  edit .lua in VS Code (or any editor)                   │
│  ↓                                                       │
│  python scripts/build_pack.py   (< 1s)                  │
│  ↓                                                       │
│  Copy dist\!wingman.pack to <TWW3>\data\   (~1s)        │
│  ↓                                                       │
│  (Optional) tail the script log for live feedback        │
│  ↓                                                       │
│  In-game: hot-load via F5 (NOT in vanilla TWW3)         │
│           — or quit and relaunch (~30s)                 │
│  ↓                                                       │
│  Verify behavior matches expectations                   │
│  ↓                                                       │
│  Loop                                                     │
└─────────────────────────────────────────────────────────┘
```

> **Hot-reload**: TWW3 does not support mod hot-reload out of the box. You'll relaunch the game for each cycle. With `!wingman` being a script-only mod (no new models, no new tables), relaunch is fast (~30s on a modern machine).

---

## Pre-launch sanity check (lupa integration test)

Before opening TWW3, you can verify the Lua modules load and execute together using a Python lupa harness. This catches syntax errors and module-load issues **before** the slower in-game test cycle.

### Setup

```bash
# One-time
pip install lupa
```

### Run the existing smoke test

```bash
# From repo root, with Python 3.11+
python -c "
import lupa
lua = lupa.LuaRuntime(unpack_returned_tuples=True)

# Engine stubs — see tests/manual/test_t7_integration.py for the full version
lua.execute('''
_G.out = setmetatable({tag={fight=function(self,s)end}},{__call=function(self,s)end})
function _G.find_uicomponent() return nil end
_G.cm = {
    is_multiplayer=function(self)return false end,
    get_local_faction_name=function(self)return 'wh_main_emp_empire' end,
    turn_number=function(self)return 1 end,
    add_first_tick_callback=function(self,cb)return true end,
}
_G.core = {
    add_listener=function(self,n,e,c,cb,p)return true end,
    remove_listener=function(self,n)return true end,
    svr_save_registry_string=function(self,k,v)return true end,
    svr_load_registry_string=function(self,k)return '' end,
}
_G.mission_manager=nil
_G.wingman_mct={is_available=function(self)return false end,
    get_default_settings=function(self) return {wingman_enabled=false,wingman_campaign_handover_enabled=false,wingman_battle_handover_enabled=false} end,
    read_settings=function(self)return _G.wingman_mct.get_default_settings()end}
''')

files = [
    'script/campaign/mod/wingman_state.lua',
    'script/campaign/mod/wingman_safety.lua',
    'script/campaign/mod/wingman_missions.lua',
    'script/campaign/mod/wingman_rules.lua',
    'script/campaign/mod/wingman_campaign.lua',
    'script/campaign/mod/wingman_battle.lua',
    'script/campaign/mod/wingman_init.lua',
    'script/battle/mod/wingman_battle_init.lua',
]
ok = 0
for f in files:
    result = lua.eval(f'pcall(dofile, [=[D:/repos/tww3-mod-wingman/{f}]=])')
    if isinstance(result, str):
        print(f'FAIL {f}: {result}')
    else:
        ok += 1
        print(f'OK   {f}')
print(f'{ok}/{len(files)} modules load + execute cleanly')

# Bootstrap calls
for fn in ['wingman.init', 'wingman.register_listeners', 'wingman.shutdown']:
    result = lua.eval(f'pcall(_G.{fn})')
    print(f'{fn}: {\"OK\" if result is True else \"FAIL\"}')
"
```

If this prints `OK` for all 8 modules and all 3 bootstrap calls, your code change is syntactically valid and the modules integrate. Safe to proceed to the in-game cycle.

If anything fails, fix the code **before** opening TWW3.

---

## Common pitfalls

| Symptom | Likely cause | Fix |
|---|---|---|
| Mod doesn't appear in Mod Manager | `.pack` not in `<TWW3>/data/`, or wrong filename | Re-run `python scripts/build_pack.py` and copy. Filename must be `!wingman.pack`. |
| Mod ticked but campaign crashes on load | Lua syntax error in one of the files | Open `script_log_*.txt`, find first Lua error line, fix it. |
| `[Wingman] WARNING: MCT ... not loaded` | MCT not subscribed or not ticked | Subscribe via Steam, tick before Wingman in Mod Manager. |
| `[Wingman] init` line never appears | `enable_console_logging` flag missing | Create the empty file in `<TWW3>/data/script/`. |
| Settings panel doesn't show Wingman | `wingman_mct.lua` not in pack | Run `python -c "import struct; f=open('dist/!wingman.pack','rb'); m=f.read(4); t,_,_,n,_,_,_=struct.unpack('<7I',f.read(28)); print(m,t,n); assert m==b'PFH5' and (t & 0xF)==3 and n==10"` — expect no assertion error. |
| Wingman auto-ends turns but I want it off | `wingman_enabled` is true | Open MCT → Wingman → untick `wingman_enabled`. |
| Turn counter increments but my settings didn't change | Periodic break fired (default every 10 turns) | Set `wingman_periodic_break_interval = 0` to disable. |
| Crash when AI declares war | Diplomacy popup race | Check `wingman_break_on_war_declaration = true` (default). |
| `Patch X.Y: New table Z required` | N/A — pure-Python packer has no schema cache. If you see this, it's because the in-game launcher is hitting a TWW3 patch-time validation — unrelated to this mod. |
| Lua error: `attempt to index a function value (global 'out')` | You wrote `out.something` but TWW3's `out` is callable AND a table. | Use `if out and out.tag and out.tag.fight then` guard pattern. |

---

## Evidence capture protocol

When running scenarios, capture evidence under `tests/manual/evidence/`:

```
tests/manual/evidence/
├── s1_step2.log           # Script log slice at the relevant moment
├── s1_step4.png           # Screenshot
├── s2_battle_init.log
├── s2_in_battle.png
├── wingman_s1_pre.save    # Savegame before the scenario
├── wingman_s1_post.save   # Savegame after the scenario
└── ...
```

The scenarios doc lists exactly what to capture per scenario. Without evidence, a passing scenario is not proven.

---

## Testing checklist (copy-paste for each release)

```
Wingman 0.1.0-alpha local test — release ____

[ ] Step 1: Python 3.6+ available (`python --version` works)
[ ] Step 2: !wingman.pack built and installed (timestamp fresh)
[ ] Step 3: !wingman.png next to .pack; enable_console_logging exists
[ ] Step 4: Original launcher → Mod Manager → MCT + Wingman ticked → Play
[ ] Step 4 verify: [Wingman] init complete. line in script_log_*.txt
[ ] Step 5: S1 (campaign handover) — PASS
[ ] Step 5: S2 (battle scripted_ai) — PASS
[ ] Step 5: S3 (turn cap) — PASS
[ ] Step 5: S4 (custom win) — PASS
[ ] Step 5: S5 (faction ban) — PASS
[ ] Step 5: S6 (save/load) — PASS
[ ] Step 5: S7 (install regression) — PASS
[ ] Step 5: S8 (diplomacy safety) — PASS
[ ] Step 5: S9 (battle result dismiss) — PASS
[ ] Step 5: S10 (MP guard) — PASS
[ ] Pre-launch lupa smoke — PASS
[ ] Evidence files saved to tests/manual/evidence/

If all checked → ready for Steam Workshop upload (Hidden first).
```

---

## Related docs

- `tests/manual/wingman_scenarios.md` — S1–S10 manual scenarios
- `tests/manual/QA_REPORT.md` — final architecture compliance audit
- `pack/BUILD_INSTRUCTIONS.md` — pack build (`scripts/build_pack.py`) + Workshop upload
- `WORKSHOP.md` — Workshop publishing checklist
- `.omo/plans/wingman-mod.md` — implementation plan with rationale

---

## Quick reference: log-line patterns

If you grep `script_log_*.txt` for these patterns, you'll know which scenario you can confirm:

| Pattern | Means |
|---|---|
| `[Wingman] init: enter` | Bootstrap started |
| `[Wingman] init complete. mode=...` | Bootstrap done |
| `[Wingman] scheduled end_turn in Ns for turn M` | Auto-turn queued (S1) |
| `[Wingman] cm:end_turn ok. turn=N` | Auto-turn fired (S1) |
| `[Wingman] turn N ended.` | Player turn completed (S1) |
| `[Wingman] rules: breakpoint (turn_cap_reached) at turn N` | Turn cap hit (S3) |
| `[Wingman] victory condition met. reason=...` | Custom win satisfied (S4) |
| `[Wingman] Banned faction spotted: ...` | Faction ban triggered (S5) |
| `[Wingman] mp_guard: blocking ... (multiplayer detected)` | MP guard fired (S10) |
| `[Wingman] pause_for_popup: ...` | Diplomacy/modal pause (S8) |
| `[Wingman] dismiss_battle_result: clicked continue` | Result auto-dismissed (S9) |
| `AI plan applied: ... (alliance=N)` | Scripted AI took over battle (S2) |
| `battle init ok. v0.1.0-alpha mode=... bias=...` | Battle script loaded (S2) |
| `[Wingman] ERROR_SAFE: ...` | Automation halted — check log for cause |
| `[Wingman] shutdown: ...` | `wingman.shutdown()` was called |

## CI smoke test

The repo includes `scripts/lupa_smoke.py` — a Python script that loads all 9 Lua modules under stubbed TWW3 engine globals and exercises the bootstrap. This is the same test that runs as the first step of `.github/workflows/release.yml`.

Run it locally before opening TWW3 to catch syntax errors and module-load issues fast:

```bash
pip install lupa
python scripts/lupa_smoke.py
```

Expected output: 8 `OK   <file>` lines + 4 bootstrap calls succeed + `ALL CHECKS PASS`. Exit code 0 on success, 1 on any failure.

This catches the most common CI failures (Lua syntax errors, missing modules, broken init wiring) in under 5 seconds — much faster than the full in-game cycle (~30 seconds per build).