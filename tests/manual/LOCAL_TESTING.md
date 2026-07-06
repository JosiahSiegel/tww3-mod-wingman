# Wingman — Local Testing Guide

End-to-end guide for running Wingman on a development machine **before** publishing to Steam Workshop. Covers the build, install, in-game smoke, and the iterative dev loop.

> **Audience**: Contributors, testers, and the author. **Not for end-users** — they get `!wingman.pack` from the Workshop.

## TL;DR (5-minute smoke)

If you've already built and installed once and just want to re-verify a code change:

```bash
# 1. Lupa pre-launch smoke (catches syntax errors in <5s)
python scripts/lupa_smoke.py

# 2. Rebuild the pack
python scripts/build_pack.py

# 3. Copy into TWW3
Copy-Item "dist\!wingman.pack" "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.pack" -Force

# 4. Launch TWW3 (original launcher, NOT EA Mod Manager)
# 5. Mod Manager: tick MCT + Wingman → Play
# 6. New IE campaign, Reikland → verify the [Wingman] init line appears in the log
```

If the init line appears, the mod is at least bootable. Run the full scenarios for deeper verification.

---

## Prerequisites

| Tool | Why |
|---|---|
| Total War: WARHAMMER III (Steam) | Game to mod |
| [Mod Configuration Tool (MCT)](https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021) | Required dependency for Wingman settings UI |
| Python 3.6+ | Runs `scripts/build_pack.py` and `scripts/lupa_smoke.py` |
| `lupa` (`pip install lupa`) | Runs the pre-launch smoke test |
| Python 3.11+ with Pillow (optional) | Regenerate the thumbnail if you change `assets/workshop/build_thumbnail.py` |

**No RPFM, no Assembly Kit, no 100+ MB binary downloads, no Qt/KDE runtime libraries.** The packer is ~150 lines of pure Python implementing the [PFH5 format spec](https://github.com/TotalWar-Modding/docs/blob/master/pack%20file%20format.md) directly.

---

## Step 1: Build the pack (< 1 second)

```bash
python scripts/build_pack.py
```

Output: `dist/!wingman.pack` (~370 KB) and `dist/!wingman.png`. The script validates the PFH5 magic on the output.

**Iterative dev loop time**: < 1 second from edit to fresh pack.

---

## Step 2: Install to TWW3

```powershell
Copy-Item "dist\!wingman.pack" "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.pack" -Force
Copy-Item "dist\!wingman.png"  "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.png"  -Force
```

The filename MUST match the `.pack` base name exactly (case-sensitive, no extra characters).

---

## Step 3: Enable script logging (one-time)

```powershell
New-Item -ItemType File -Path "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\script\enable_console_logging" -Force
```

That empty file (no extension) is the trigger. From now on, every `out("[Wingman] ...")` line is written to `script_log_*.txt` in the game folder.

> **Also enable via**: MCT has a "Script Logging" toggle in some versions. Or the [Script Debug Activator](https://steamcommunity.com/sharedfiles/filedetails/?id=2789857593) Workshop mod.

---

## Step 4: Launch and verify boot (~3 minutes)

### Launch path (CRITICAL)

TWW3 has **two** launcher experiences:

1. **Original Total War launcher** — has the Mod Manager, supports Workshop uploads. ✓ **Use this.**
2. **New EA Mod Manager (Early Access)** — does NOT support Workshop uploads yet. ✗ **Do NOT use.**

To pick the original launcher:

1. Right-click TWW3 in your Steam library → Properties → General → Launch Options → set to `Ask when starting game`.
2. Launch TWW3 → choose **"Original launcher"** at the boot chooser.
3. Tick "Always use this option" to skip the chooser next time.

### Enable the mods

1. In the launcher, click **Mod Manager**.
2. Tick **Mod Configuration Tool** (subscribed from Workshop) and **!wingman** (just installed to `data/`). **MCT first** (load order).
3. Click **Play**.

### Verify boot

While the campaign loads, open `<TWW3>/script_log_*.txt` and search for `[Wingman]`. You should see:

```
[Wingman] init: enter
[Wingman] init complete. mode=disabled, campaign_handover=false, battle_handover=false
```

If you see only `[Wingman] WARNING: MCT (Mod Configuration Tool) is not loaded.`, MCT isn't subscribed or wasn't ticked — fix and retry.

### Where logs go

| Log | Path |
|---|---|
| Script log (with `enable_console_logging` flag) | `<TWW3>/script_log_*.txt` |
| (Sometimes) deeper logs | `%APPDATA%\The Creative Assembly\Warhammer3\logs\` |

Search the most recent timestamp when debugging.

---

## Step 5: Run scenarios

Open `tests/manual/wingman_scenarios.md` for the full 16-scenario matrix (S1–S10, S11, S11b–S11e). **Start with these four**:

| Scenario | Purpose | Time |
|---|---|---|
| **S7** Workshop/local install | Confirm mod loads at all | 2 min |
| **S1** Campaign handover | Confirm core orchestration | 10 min |
| **S6** Save/load persistence | Confirm state restoration | 10 min |
| **S10** Multiplayer guard | Confirm safety | 15 min (requires MP partner) |

Each scenario has: **Setup** (exact MCT settings) → **Steps** (concrete clicks) → **Pass condition** (binary observable) → **Evidence** (files to save) → **Fail signals** (which module owns the fix).

### 5-minute smoke (alternative)

If you don't have time for full scenarios:

1. Boot to campaign (Step 4). Verify `[Wingman] init` in log.
2. MCT → Wingman → set `wingman_enabled = true`, `wingman_campaign_handover_enabled = true`.
3. Set `wingman_auto_end_turn_delay_seconds = 2`.
4. End turn manually.
5. Wait 5 seconds. Verify turn counter advanced.
6. Save + reload. Verify settings persist.
7. Quit.

If 1–7 pass, the mod is at least bootable and the core orchestration works.

---

## Step 6: Iterative dev loop

```
┌─────────────────────────────────────────────────────────┐
│  edit .lua in VS Code (or any editor)                   │
│  ↓                                                       │
│  python scripts/lupa_smoke.py   (< 5s, catches syntax)  │
│  ↓                                                       │
│  python scripts/build_pack.py   (< 1s)                  │
│  ↓                                                       │
│  Copy dist\!wingman.pack to <TWW3>\data\   (~1s)        │
│  ↓                                                       │
│  (Optional) tail the script log for live feedback        │
│  ↓                                                       │
│  In-game: relaunch TWW3 (~30s, no mod hot-reload)        │
│  ↓                                                       │
│  Verify behavior matches expectations                   │
│  ↓                                                       │
│  Loop                                                     │
└─────────────────────────────────────────────────────────┘
```

> TWW3 does not support mod hot-reload. With Wingman being script-only (no new models, no new tables), relaunch is fast (~30s on a modern machine).

---

## Pre-launch sanity check (lupa)

Before opening TWW3, verify the Lua modules load under a stubbed engine. Catches syntax errors and module-load issues **before** the slower in-game test cycle:

```bash
pip install lupa
python scripts/lupa_smoke.py
```

Expected output: 9 `OK   <file>` lines + 4 bootstrap calls succeed + `ALL CHECKS PASS`. Exit code 0 on success, 1 on any failure.

This catches the most common CI failures (Lua syntax errors, missing modules, broken init wiring) in under 5 seconds — much faster than the full in-game cycle.

The repo also has dedicated test suites:

- `tests/manual/test_w6_ai_features.py` — W6 step dispatch (5 tests)
- `tests/manual/test_w7_autopilot.py` — W7 Autopilot + Advisory (10 tests)
- `tests/manual/test_w8_step_coverage.py` — W8 step coverage + spectator + strategic pause (20 tests)

Run all three after any wingman_ai.lua change:

```bash
for f in tests/manual/test_w{6,7,8}_*.py; do
  echo "=== $f ==="
  PYTHONIOENCODING=utf-8 python "$f" || { echo "FAIL: $f"; exit 1; }
done
```

---

## Common pitfalls

| Symptom | Likely cause | Fix |
|---|---|---|
| Mod doesn't appear in Mod Manager | `.pack` not in `<TWW3>/data/`, or wrong filename | Re-run `python scripts/build_pack.py` and copy. Filename must be `!wingman.pack`. |
| Mod ticked but campaign crashes on load | Lua syntax error | Open `script_log_*.txt`, find first Lua error line, fix it. |
| `[Wingman] WARNING: MCT ... not loaded` | MCT not subscribed or not ticked | Subscribe via Steam, tick before Wingman in Mod Manager. |
| `[Wingman] init` line never appears | `enable_console_logging` flag missing | Create the empty file in `<TWW3>/data/script/`. |
| Settings panel doesn't show Wingman | `wingman_mct.lua` not in pack | Verify with the PFH5 magic check in `BUILD_INSTRUCTIONS.md` step 5 |
| Wingman auto-ends turns but I want it off | `wingman_enabled` is true | Open MCT → Wingman → untick `wingman_enabled`. |
| Turn counter increments but my settings didn't change | Periodic break fired (default every 10 turns) | Set `wingman_periodic_break_interval = 0` to disable. |
| Crash when AI declares war | Diplomacy popup race | Check `wingman_break_on_war_declaration = true` (default). |
| `Patch X.Y: New table Z required` | In-game launcher patch-time validation — unrelated to this mod | N/A |
| Lua error: `attempt to index a function value (global 'out')` | `out` is callable AND a table in TWW3 | Use `if out and out.tag and out.tag.fight then` guard pattern |

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

[ ] python scripts/lupa_smoke.py — PASS
[ ] python scripts/lupa_smoke.py — PASS (re-run after any change)
[ ] W6 + W7 + W8 test suites — PASS
[ ] Step 1: !wingman.pack built (timestamp fresh)
[ ] Step 2: !wingman.pack + !wingman.png in <TWW3>\data\
[ ] Step 3: enable_console_logging exists
[ ] Step 4: Original launcher → Mod Manager → MCT + Wingman ticked → Play
[ ] Step 4 verify: [Wingman] init complete. line in script_log_*.txt
[ ] S1 (campaign handover) — PASS
[ ] S6 (save/load) — PASS
[ ] S7 (install regression) — PASS
[ ] S10 (MP guard) — PASS
[ ] S11d (Autopilot) — PASS
[ ] S11e (Advisory) — PASS
[ ] Evidence files saved to tests/manual/evidence/

If all checked → ready for Steam Workshop upload (Hidden first).
```

---

## Related docs

- `tests/manual/wingman_scenarios.md` — 16 manual scenarios (S1–S11e)
- `tests/manual/QA_REPORT.md` — final architecture compliance audit
- `pack/BUILD_INSTRUCTIONS.md` — pack build + Workshop upload
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
| `[Wingman] autopilot engaged: ...` | W7 Autopilot locked (S11d) |
| `[Wingman] autopilot released` | W7 Autopilot unlocked |
| `[Wingman] advisory dilemma fired: ...` | W7 Advisory prompt (S11e) |
| `[Wingman] strategic_pause dilemma fired: ...` | W8 strategic pause (W8-D) |
