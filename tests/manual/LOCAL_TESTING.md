# Wingman — Local Testing Guide

End-to-end guide for running Wingman on a development machine **before** publishing to Steam Workshop. Covers the build, install, in-game smoke, and the iterative dev loop.

> **Audience**: Contributors, testers, and the author. **Not for end-users** — they get `!wingman.pack` from the Workshop.

---

## TL;DR (5-minute smoke)

If you've already built and installed once and just want to re-verify a code change:

```bash
# 1. Rebuild the pack from repo changes (RPFM GUI: MyMod → Import → PackFile → Install)
# 2. Tail the script log while you play
tail -f "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\script_log_*.txt"
# 3. Launch TWW3 (original launcher, NOT EA Mod Manager)
# 4. Mod Manager: tick MCT + Wingman → Play
# 5. New IE campaign, Reikland → verify the [Wingman] init line appears in the log
```

If the init line appears, the mod is at least bootable. Run the full scenarios for deeper verification.

---

## Prerequisites

| Tool | Why | Where |
|---|---|---|
| Total War: WARHAMMER III (Steam) | Game to mod | `C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III` |
| Steam | Launcher + subscription | https://store.steampowered.com/app/1142710 |
| [Mod Configuration Tool (MCT)](https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021) | Required dependency for Wingman settings UI | Subscribe via Steam Workshop |
| [Rusted PackFile Manager (RPFM)](https://github.com/Frodo45127/rpfm/releases) v5.0.5+ | Builds `!wingman.pack` from the source repo | https://github.com/Frodo45127/rpfm/releases |
| (Optional) [TWW3 Assembly Kit BETA](https://store.steampowered.com/app/1880380/) | Speeds up RPFM dependency cache generation | Steam Tools library |
| Python 3.11+ with Pillow | Regenerate thumbnail if needed | `pip install Pillow` |

---

## Step 1: Configure RPFM (one-time, ~5 minutes)

1. Install RPFM from the releases page. Extract to a writable location (e.g., `D:\Tools\rpfm\`).
2. Launch RPFM.
3. `PackFile → Preferences → Settings`:
   - **Game Path**: `C:\Program Files (x86)\Steam\steamapps\common\Total War Warhammer III`
   - **MyMod folder**: `D:\repos\tww3-mod-wingman` (this repo's root)
   - **Selected Game**: **Warhammer 3**
4. `Special Stuff → Warhammer 3 → Generate Dependencies Cache` (one-time, ~2 minutes).
   - You only need to re-run this after a TWW3 game patch.

> **Why a separate tool?** TWW3 loads mods from `.pack` files (CA's proprietary PFH5 archive). You cannot just point the game at the `.lua` files in the repo — RPFM packs them into the format the game reads.

---

## Step 2: Build the pack (~2 minutes)

Every code change requires a rebuild.

1. **Edit source** in this repo (any `.lua`, `.tsv`, `.png`).
2. **In RPFM**: `MyMod → Import` — pulls changes from the repo into the open pack.
3. **In RPFM**: `PackFile → Install` — copies `!wingman.pack` to `<TWW3>/data/`.
4. **Verify install**: the file `<TWW3>/data/!wingman.pack` should exist with a recent timestamp.

**Iterative dev loop time**: ~30 seconds from edit to in-game-testable, dominated by the RPFM Import/Install dialog.

> **First-time build**: ~5 minutes (RPFM also generates its dependency cache during this).

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
│  RPFM: MyMod → Import   (~5s)                           │
│  ↓                                                       │
│  RPFM: PackFile → Install   (~5s)                       │
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
| Mod doesn't appear in Mod Manager | `.pack` not in `<TWW3>/data/`, or wrong filename | Re-run `PackFile → Install` in RPFM. Filename must be `!wingman.pack`. |
| Mod ticked but campaign crashes on load | Lua syntax error in one of the files | Open `script_log_*.txt`, find first Lua error line, fix it. |
| `[Wingman] WARNING: MCT ... not loaded` | MCT not subscribed or not ticked | Subscribe via Steam, tick before Wingman in Mod Manager. |
| `[Wingman] init` line never appears | `enable_console_logging` flag missing | Create the empty file in `<TWW3>/data/script/`. |
| Settings panel doesn't show Wingman | `wingman_mct.lua` not in pack | Open the pack in RPFM, verify `script/mct/settings/wingman_mct.lua` is present. |
| Wingman auto-ends turns but I want it off | `wingman_enabled` is true | Open MCT → Wingman → untick `wingman_enabled`. |
| Turn counter increments but my settings didn't change | Periodic break fired (default every 10 turns) | Set `wingman_periodic_break_interval = 0` to disable. |
| Crash when AI declares war | Diplomacy popup race | Check `wingman_break_on_war_declaration = true` (default). |
| `Patch X.Y: New table Z required` | TWW3 patched, dependency cache stale | RPFM → `Special Stuff → Warhammer 3 → Generate Dependencies Cache`. |
| Upload to Workshop spins forever | Steam hiccup | Restart Steam. |
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

[ ] Step 1: RPFM configured, dependencies cached
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
- `pack/BUILD_INSTRUCTIONS.md` — RPFM build + Workshop upload
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