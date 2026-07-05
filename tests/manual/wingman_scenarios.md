# Wingman — Manual Verification Scenarios

This is the runnable TDD suite for the Wingman TWW3 mod. Each scenario is binary pass/fail, runs in-game, and produces evidence you file under `tests/manual/evidence/`. The mod's own log lines are the source of truth — no behavior counts as fixed until the corresponding line shows up in `script_log_*.txt`.

The scenarios here mirror the plan in `.omo/plans/wingman-mod.md` (Verification Scenarios S1–S10, Smoke-test Workflow), but they're rewritten as a runnable matrix with the actual log prefixes emitted by the modules. Use this file as the entry point for any release pass.

> **First time testing locally?** Read [`LOCAL_TESTING.md`](./LOCAL_TESTING.md) first — it covers the RPFM build, the script-logging setup, the original-launcher requirement, and the iterative dev loop.

## How to run these

### Prerequisites

1. **Total War: WARHAMMER III** installed via Steam.
2. **[Mod Configuration Tool (MCT)](https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021)** subscribed and enabled. Wingman hard-depends on it; without MCT you'll see `[Wingman] WARNING: MCT (Mod Configuration Tool) is not loaded.` at startup and every automation is disabled.
3. **Wingman** subscribed from the Workshop, or installed locally as `!wingman.pack` plus matching `!wingman.png` in `<TWW3>/data/`.
4. **Script logging enabled**: create an empty file at `<TWW3 install>/data/script/enable_console_logging`. The game then writes `script_log_*.txt` into the game folder.
5. Launch via the **original Total War launcher** (not the EA Mod Manager). The new Mod Manager does not support Workshop upload testing reliably.

### Evidence capture

All evidence files go into `tests/manual/evidence/`. The naming convention below keeps every scenario's artifacts grouped:

| Artifact kind | Path |
|---|---|
| Logs | `tests/manual/evidence/<scenario_id>_<step>.log` |
| Screenshots | `tests/manual/evidence/<scenario_id>_<step>.png` |
| Savegames | `tests/manual/wingman_<scenario_id>_<pre|post>.save` |

Log files are copies of `script_log_*.txt` (the newest one in the game folder) trimmed to the relevant time window. To find the file: check both `<TWW3 install>/` and `%APPDATA%\The Creative Assembly\Warhammer3\logs\` — the location depends on the install path and platform.

### Quick smoke (run these first)

When you're short on time, run these four in order. They cover boot, core orchestration, persistence, and safety.

1. **S7** — Workshop/local install. Confirms the mod loads at all.
2. **S1** — Campaign handover happy path. Confirms core orchestration.
3. **S6** — Save/load persistence. Confirms state restoration.
4. **S3** — Turn cap. Confirms the rule engine.
5. **S10** — MP guard. Confirms the safety floor.

If S7, S1, S6, S3, and S10 all pass, the mod is bootable and the core paths work. Defer S2, S4, S5, S8, S9 to a deeper pass before each release.

---

## S1 — Campaign handover happy path

**Objective**: Verify that with Wingman enabled and campaign handover on, the player's turn auto-ends after the configured delay.

**Setup**:
- New Immortal Empires single-player campaign.
- Faction: Reikland (stable vanilla faction).
- Difficulty: Normal.
- Mods enabled: MCT, Wingman.
- In MCT → Wingman settings:
  - `wingman_enabled` = **true**
  - `wingman_campaign_handover_enabled` = **true**
  - `wingman_auto_end_turn_delay_seconds` = **2**
  - `wingman_periodic_break_interval` = **0** (disable, to isolate this scenario)
  - `wingman_break_on_pending_battle` = **true** (default — pauses if a battle interrupts)
- Save the game immediately as `wingman_s1_pre.save`.

**Steps**:
1. Open the campaign map. Wait for the campaign-script first tick to fire.
2. End the current turn manually (click End Turn).
3. **WAIT** — do not interact with the game for 5 seconds.
4. Observe: the player turn should automatically end, AI factions should play out their turns, then the player turn should return with the counter incremented.

**Pass condition** (binary):
- No crash to desktop.
- Log shows (exact prefixes from `wingman_init.lua` and `wingman_campaign.lua`):
  - `[Wingman] init: enter`
  - `[Wingman] init ok. v0.1.0-alpha.`
  - `[Wingman] mode change: disabled -> campaign_handover (...)`  *(on first round start, after MCT settings load)*
  - `[Wingman] scheduled end_turn in 2s for turn N`  *(N matches the player turn counter at end-step 2)*
  - `[Wingman] cm:end_turn ok. turn=N`  *(same N as above, or N+1 depending on the round-start ordering)*
  - `[Wingman] turn N ended.`
- After AI turns complete, the player turn returns and the turn counter is one higher than at step 2.

**Evidence**:
- `evidence/s1_step2.log` — log lines from the end-of-step-2 to the next player turn, showing scheduled + actual end_turn.
- `evidence/s1_step4.png` — campaign map screenshot after auto-end (turn counter visible).
- `wingman_s1_post.save` — savegame after one full cycle.

**Fail signals**:
- No `[Wingman] scheduled end_turn in 2s for turn N` line → MCT settings didn't load; check for the `round start, settings refreshed` line and that the initial `mode change` happened. The most common cause is `wingman_campaign_handover_enabled` not being on in the MCT panel.
- Crash during AI turn → diplomacy popup race or pending battle popup; check log for the last `[Wingman]` line. Probably a S8 / S9 issue; defer to those scenarios.
- Turn counter doesn't increment after a long pause → `cm:end_turn` not actually executing; the log will show `safe_call[cm:end_turn]: ...` and a `WARN`. Mode will have flipped to `error_safe` and you'll see `ERROR_SAFE: do_end_turn: cm.end_turn unavailable` (or similar).
- Log shows `turn N already processed this round` twice → duplicate `FactionTurnStart` listener; this is a S6 regression; defer to that scenario.

**Cross-references**: feeds S6 (load the post savegame). Also touches S8 (any popup pause) and S3 (if turn cap is enabled).

---

## S2 — Battle takeover with scripted_ai mode

**Objective**: Verify that when battle handover is enabled with mode = `scripted_ai`, Wingman applies an AI plan and the player's units act without player input.

**Setup**:
- Use the save from S1 (or start fresh; S1 setup works).
- In MCT → Wingman settings:
  - `wingman_enabled` = **true**
  - `wingman_battle_handover_enabled` = **true**
  - `wingman_battle_control_mode` = **`scripted_ai`** (default)
  - `wingman_battle_plan_bias` = **`auto`** (default)
  - `wingman_auto_dismiss_battle_results` = **true** (default)
- Position an army next to a settlement or enemy army to provoke a manual battle.
- Save as `wingman_s2_pre.save`.

**Steps**:
1. Initiate a manual battle (attack a settlement or fight a field battle).
2. Deploy your units normally during the deployment phase.
3. **DO NOT** issue orders after the battle starts.
4. Wait ~10 seconds. Observe player units.

**Pass condition**:
- No crash.
- Log shows (from `wingman_battle.lua` and `wingman_battle_init.lua`):
  - `scripted_ai queued. bias=auto threshold=60`  *(from campaign-side `on_pending_battle`)*
  - `on_battle_being_fought: payload ready (mode=scripted_ai bias=auto)`  *(from `on_battle_being_fought`)*
  - `battle init ok. v0.1.0-alpha mode=scripted_ai bias=auto enabled=true threshold=60`  *(battle-side init line)*
  - `battle_state: v=0.1.0-alpha mode=scripted_ai bias=auto enabled=true threshold=60 | local_alliance=... | alliance_count=N | phase=Deployed`  *(when the deployed phase triggers)*
  - `AI plan applied: auto->attack (alliance=N)`  *(this is what we want to see — `auto` bias maps to attack under the hood)*
- Player units start moving and engaging enemies without you issuing orders.
- Battle ends normally with a victory screen.

**Evidence**:
- `evidence/s2_battle_init.log` — log lines on battle start (campaign-side + battle-side init).
- `evidence/s2_in_battle.png` — screenshot mid-battle with player units acting.
- `wingman_s2_post.save` — savegame after the battle returns to the campaign.

**Fail signals**:
- No `AI plan applied:` line → the plan force failed. Look for one of these in the log:
  - `apply_ai_plan: alliance has no force_ai_plan_type_* method; this patch may not support scripted plan forcing` → API renamed in a recent patch; this is a regression to fix.
  - `apply_ai_plan: bm:alliances() failed` or `apply_ai_plan: bm:local_alliance() failed` → engine API drift; defer to debugging.
- Units stand still for 10+ seconds despite `AI plan applied:` being logged → the plan was applied but the engine's scripted AI didn't tick; visually confirm and re-run.
- Crash on battle start → usually a missing `bm:` API; check for `bm=<missing>` in `battle_state` log.
- Log shows `on_pending_battle` but no `scripted_ai queued` → the mode got dispatched to `pause_to_choose` or `autoresolve_if_favorable` instead. Re-check MCT setting.

**Cross-references**: S6 (load the post savegame), S9 (battle result dismissal happens at the end of this battle).

---

## S3 — Turn-cap rule edge case

**Objective**: Verify the turn-cap rule triggers a breakpoint at the configured turn.

**Setup**:
- New IE campaign, Reikland.
- In MCT → Wingman settings:
  - `wingman_enabled` = **true**
  - `wingman_campaign_handover_enabled` = **true**
  - `wingman_turn_cap_enabled` = **true**
  - `wingman_turn_cap_value` = **3** (small value to make the test fast)
  - `wingman_turn_cap_outcome` = **`breakpoint`** (default)
  - `wingman_periodic_break_interval` = **0** (disable, to isolate the turn-cap test)
- Save as `wingman_s3_pre.save`.

**Steps**:
1. End the current turn (turn 1 ends → turn 2 starts → Wingman auto-ends → AI plays).
2. Wait for AI turns to complete.
3. On player turn 3: Wingman should detect `turn >= cap` and trigger a breakpoint.
4. Verify the player regains manual control and the turn counter sits at 3.

**Pass condition**:
- No crash.
- Log shows:
  - `rules: breakpoint (turn_cap_reached) at turn 3`  *(from `wingman_campaign.handle_rule_outcome` in `wingman_campaign.lua`)*
  - `mode change: campaign_handover -> breakpoint (rule_breakpoint)`  *(state-mode transition logged via `wingman_state.set_mode`)*
  - `breakpoint: rule_breakpoint`  *(from `wingman_state.set_breakpoint`)*
  - No `cm:end_turn ok. turn=3` after the breakpoint fires — control is released.
- The player can interact with the campaign UI normally (move units, end turn manually, open MCT, etc.).

**Evidence**:
- `evidence/s3_turn3.log` — log lines from the start of turn 2 through the breakpoint on turn 3.
- `evidence/s3_after_breakpoint.png` — campaign map showing the player can now interact.
- `wingman_s3_post.save` — savegame at the breakpoint.

**Fail signals**:
- Turn 3 still auto-ends → `evaluate_turn_cap` not triggering. Check that `wingman_turn_cap_enabled` is on and the value actually equals 3 (MCT slider clamps to range 1–500).
- Log shows `rules: pass` for every turn instead of `breakpoint` → rule module not loaded; look for `rules_module_not_loaded` reason (this would mean T5 wiring is broken — investigate before merging).
- Game crashes → look for mission_manager API mismatch; ensure `set_turn_limit` is being called without throwing. The `create_turn_cap_mission:` log line should appear once at campaign start.
- Mode flips to `error_safe` → the rule evaluator threw; check the log for `safe_call[rules.evaluate_all]: ...` followed by `ERROR_SAFE:`.

**Cross-references**: feeds S6 (load the post savegame). Also see S4 (custom win is the second rule path).

---

## S4 — Custom win condition

**Objective**: Verify the custom-win rule detects when the player owns all required settlements.

**Setup**:
- New IE campaign, Reikland (you start with Altdorf).
- In MCT → Wingman settings:
  - `wingman_enabled` = **true**
  - `wingman_campaign_handover_enabled` = **true** *(so rules actually evaluate each turn; otherwise they don't run)*
  - `wingman_custom_win_enabled` = **true**
  - `wingman_required_settlements_csv` = `wh_main_altdorf` *(Reikland's capital; the player owns it on turn 1)*
  - `wingman_required_defeated_factions_csv` = *(leave empty; S4 covers settlements only)*
  - `wingman_turn_cap_outcome` = **`victory`** *(so a victory rule result actually triggers the game-victory payload; see failure note below if you keep breakpoint)*
  - `wingman_periodic_break_interval` = **0**
- Save as `wingman_s4_pre.save`.

**Steps**:
1. End the current turn once (or just wait for the first `FactionTurnStart`).
2. Wait for rules to evaluate.
3. Observe whether Wingman declares victory.

**Pass condition**:
- No crash.
- Log shows:
  - Either `rules: victory (custom_win_complete); not ending turn`  *(from `wingman_campaign.handle_rule_outcome`)*
  - Or `rules: victory (turn_cap_victory); not ending turn`  *(only if turn cap is also set)*
  - `[Wingman] victory condition met. reason=custom_win_complete`  *(from `wingman_missions.complete_victory`)*
- If the campaign-victory screen doesn't appear, the most likely reason is that `wingman_turn_cap_outcome` is `breakpoint` and Wingman treats the rule result as a breakpoint instead of a victory. Switch to `victory` and rerun. This is a v0.1 limitation; document in CHANGELOG if you keep it.

**Evidence**:
- `evidence/s4_victory.log` — log line on the rule result + mission completion.
- `evidence/s4_victory_screen.png` — campaign victory screen (if `outcome=victory`).
- `wingman_s4_post.save` — savegame after rule completion (if the campaign continued).

**Fail signals**:
- No victory trigger → settlement not actually owned (verify with `cm:query_model()` in a debug pass), or the settlement key is typo'd. Look for `custom_win_settlements_missing` in the rule result reason.
- Log shows `custom_win_no_objectives` warning → both CSVs are empty; the player needs at least one objective.
- Log shows `custom_win_no_local_faction` → first-tick callback fired before the local faction was available; the rule will pass harmlessly and you need to wait for the next `FactionTurnStart`.
- Validation warning `WARNING: CSV key ... ignored — only [a-z0-9_] allowed.` → key contained uppercase or special chars; lowercase it.

**Cross-references**: feeds S6. Also closely related to S3 (both rules; S3 covers turn cap, S4 covers custom win).

---

## S5 — Faction ban watcher

**Objective**: Verify the banned-faction watcher triggers a warning/breakpoint when the player owns a banned faction.

**Setup**:
- New IE campaign, Reikland.
- In MCT → Wingman settings:
  - `wingman_enabled` = **true**
  - `wingman_campaign_handover_enabled` = **true**
  - `wingman_faction_restrictions_enabled` = **true**
  - `wingman_restriction_violation_action` = **`warn_pause`** (default; produces a warning rule result without forcing a breakpoint)
- Open the MCT panel → Wingman → Rules → Faction Ban List. The list is populated dynamically from `cm:model():world():faction_manager()`. Find your **current** faction (e.g. `wh_main_empire_reikland` for Reikland) and tick it banned. Close the panel.
- Save as `wingman_s5_pre.save`.

**Steps**:
1. Confirm the ban is checked in the panel (re-open MCT and verify the checkbox is on).
2. End the player turn.
3. Wait for Wingman to evaluate restrictions.

**Pass condition**:
- No crash.
- Log shows:
  - `rules: warning (banned_faction_owned_warn); continuing`  *(from `wingman_campaign.handle_rule_outcome`, with `warn_pause`)*
  - The `WARN` variant of the same: `[Wingman][WARN] rules: warning (...)`
- Automation continues (a warning doesn't stop auto-end).
- If you set `wingman_restriction_violation_action` to `pause_disable` instead, you should also see `rules: breakpoint (banned_faction_owned_pause) at turn N` and a mode change to `breakpoint`.

**Evidence**:
- `evidence/s5_ban.log` — log line(s) showing the rule result and (if applicable) mode change.
- `evidence/s5_mct_panel.png` — screenshot of the MCT panel with the ban checkbox on.

**Fail signals**:
- No warning → MCT dynamic ban list not being read at runtime. Look for `faction_restrictions: get_banned_factions failed: ...` or `faction_restrictions_no_bans` in the rule result. Possible causes: MCT API change; the ban checkbox is a child option not picked up by `wingman_mct.get_banned_factions()`.
- Wrong faction flagged → you ticked a different faction's checkbox; verify the checkbox label says "Reikland (wh_main_empire_reikland)".
- Log shows `faction_restrictions: local faction unknown` → first-tick timing issue; usually resolves by the second player turn.

**Cross-references**: standalone. Reuses the same rule-evaluation infrastructure as S3 and S4.

---

## S6 — Save/load persistence

**Objective**: Verify Wingman state, settings, and listeners survive a save/quit/load cycle without duplicating.

**Setup**:
- Existing campaign from S1 (or S3, S4 — any scenario that ran at least two auto-turns).
- Save as `wingman_s6_pre.save`.

**Steps**:
1. Save the game.
2. Quit to desktop.
3. Relaunch the game.
4. Load the savegame.
5. Open MCT → verify Wingman settings still show the values you set before quit.
6. End the player turn once.

**Pass condition**:
- No crash on load.
- Settings match what was set before quit (verify in the MCT panel).
- After loading, **exactly one** of each init log line fires per campaign load. Specifically:
  - **One** `[Wingman] init: enter`
  - **One** `[Wingman] init ok. v0.1.0-alpha.`
  - **One** `register_listeners: panel=... battle=... war=...`  *(from safety module)*
  - **One** `register_listeners: turn_start=... turn_end=... round_start=...`  *(from campaign module)*
  - **One** `register_listeners: pending=... start=... done=...`  *(from battle module)*
- If you see `[Wingman] init: already initialized; skipping` instead of `init: enter` followed by `init ok.`, that's a *good* sign on a re-init within the same session but a *bad* sign on a fresh load — investigate the listener tracking in `wingman_init.lua`.
- Turn-end automation resumes correctly: the same `scheduled end_turn` → `cm:end_turn ok` sequence runs again on the next player turn.

**Evidence**:
- `evidence/s6_pre_load.log` — log captured just before you quit (last 100 lines or so).
- `evidence/s6_post_load.log` — log captured from launch through the first auto-end after load.
- `evidence/s6_settings_panel.png` — MCT panel after reload showing the same values.
- `wingman_s6_post.save` — savegame after the resume turn.

**Fail signals**:
- Two `init: enter` / `init ok.` lines for one campaign → `wingman._initialized` not being checked; the `init: already initialized; skipping` log should fire instead.
- Two `register_listeners: panel=...` lines → listeners registered twice. The `listeners_registered` flag in each module should be guarding against this; if it isn't, that's the regression to fix.
- Settings reset to defaults → `wingman_state.load` not finding persisted values. Check that `core:svr_load_registry_string("wingman.v1.global_settings", ...)` returns the expected JSON. The save is via `core:svr_save_registry_string` in `wingman_state.save`.
- Schema mismatch warning at load → look for `schema mismatch: saved=X current=1`. If you bumped `SCHEMA_VERSION`, transient state should be cleared. Verify nothing user-visible got wiped.
- Stale `pending_battle` shows up at load → `wingman_state.load` is hydrating it; if the original battle completed, this should have been cleared by `BattleCompleted`. If you see a `payload ready` log on a battle that already happened, that's a leak.

**Cross-references**: should be run after S1, S3, or S4 (any scenario that generated real state). The savegame file should match the post-savegame from the feeding scenario.

---

## S7 — Workshop/local install

**Objective**: Verify a fresh install of `!wingman.pack` (with matching `!wingman.png`) loads correctly with MCT.

**Setup**:
- Clean local install path: copy `!wingman.pack` to `<TWW3>/data/`.
- Copy `!wingman.png` to the same folder.
- Verify both files exist (filename case-sensitive; no uppercase). The pack filename and the thumbnail filename must match exactly.
- Launch the original Total War launcher (NOT the EA Mod Manager).

**Steps**:
1. In Mod Manager, enable **MCT first**, then Wingman. MCT must be above Wingman in the load order.
2. Click Play.
3. Start a new IE campaign.

**Pass condition**:
- No `Failed to open pack` or `Missing pack file` errors in the launcher UI.
- No `Patch X.Y: New table Z required` error — that means the pack structure is wrong (re-pack via RPFM).
- Campaign loads without crash.
- MCT menu shows the **Wingman** settings panel under the Wingman section.
- Log contains:
  - `[Wingman] init: enter`  *(proves the script folder made it into the pack)*
  - `[Wingman] init ok. v0.1.0-alpha.`
  - `[Wingman] register_listeners: panel=true battle=true war=true`
  - `WARNING: MCT (Mod Configuration Tool) is not loaded.` should **NOT** appear (you enabled MCT).

**Evidence**:
- `evidence/s7_launcher.png` — launcher with mod ticked.
- `evidence/s7_mct_panel.png` — MCT panel showing the Wingman section.
- `evidence/s7_init.log` — log with init lines.

**Fail signals**:
- `Patch X.Y: New table Z required` → pack structure mismatch; re-pack via RPFM with PFH5 format and the right manifest_version.
- `WARNING: MCT (Mod Configuration Tool) is not loaded.` → MCT isn't actually enabled, or the load order is wrong.
- Init lines absent → `script/campaign/mod/wingman_init.lua` didn't make it into the pack. Open the pack with RPFM and verify the path.
- `Failed to open pack` → the pack file is corrupted; re-export.
- Launcher doesn't show Wingman → `!wingman.png` is missing or has a typo'd filename (case-sensitive).

**Cross-references**: prerequisite for every other scenario. If S7 fails, fix install before testing anything else.

---

## S8 — Diplomacy popup safety

**Objective**: Verify Wingman pauses (doesn't crash) when a diplomacy panel pops up during auto-turn.

**Setup**:
- IE campaign with handover enabled. The `on_panel_opened` listener fires for any panel whose key contains `diplomacy`, `war`, `dilemma`, `trade`, `warning`, `alert`, `event_message`, or `skill`.
- In MCT → Wingman settings:
  - `wingman_enabled` = **true**
  - `wingman_campaign_handover_enabled` = **true**
  - `wingman_break_on_diplomacy_panel` = **true** (default)
  - `wingman_break_on_war_declaration` = **true** (default)
  - `wingman_break_on_pending_battle` = **true** (default)
- Save near a rival faction that's likely to send a diplomacy offer (any save where you have neighbors; the AI tends to open diplomacy on its own).

**Steps**:
1. Enable Wingman handover.
2. End the player turn.
3. Wait for the AI turn → diplomacy offer / war declaration arrives.

**Pass condition**:
- No crash.
- Log shows:
  - `pause_for_popup: <panel_key>`  *(where `<panel_key>` contains `diplomacy`, `war`, `dilemma`, or one of the other PANEL_KEYWORDS from `wingman_safety.lua`)*
  - `breakpoint: popup_blocking`  *(from `wingman_state.set_breakpoint`)*
  - `mode change: campaign_handover -> breakpoint (popup_blocking)`  *(from `wingman_state.set_mode`)*
- Player can manually dismiss the panel and continue (re-enable Wingman by toggling `wingman_enabled` off then on, or by closing the panel and ending the turn manually).

**Evidence**:
- `evidence/s8_pause.log` — log on diplomacy popup showing `pause_for_popup:` and the breakpoint.
- `evidence/s8_panel.png` — screenshot of the diplomacy panel.
- `wingman_s8_pre_pause.save` and `wingman_s8_post_resume.save` — savegames bracketing the event.

**Fail signals**:
- Crash on AI turn → safety listeners not registered early enough. Verify `wingman_safety.register_listeners` runs before `wingman_campaign.register_listeners` in `wingman.init`. The `register_listeners: panel=... battle=... war=...` log line should appear at init time, before any turn events.
- No `pause_for_popup:` log when a panel is up → either the `on_panel_opened` callback isn't matching the panel key (different naming convention in the current patch), or the listener isn't registered. The `panel_key_blocks` heuristic in `wingman_safety.lua` does substring matching, so most panel keys are caught.
- Automation continues past the panel → `wingman_break_on_diplomacy_panel` is set to `false` in the settings; the mod respects that explicitly.

**Cross-references**: closely related to the war-declaration listener (`FactionJoinsWar`); you may see both `pause_for_popup: ...` and `FactionJoinsWar: war declared on player (<name>)` if the war arrives with a confirmation panel.

---

## S9 — Battle result dismissal

**Objective**: Verify post-battle result panels are auto-dismissed when the setting is enabled, and that Wingman pauses rather than crashes when the dismissal isn't safe.

**Setup**:
- Use the save from S2 (after a battle has been completed at least once) or any save where `wingman_auto_dismiss_battle_results = true` (the default).
- In MCT → Wingman settings:
  - `wingman_battle_handover_enabled` = **true**
  - `wingman_auto_dismiss_battle_results` = **true**

**Steps**:
1. Confirm the setting is on.
2. Complete a battle (any — autoresolved or fought).
3. After the result panel appears, observe whether Wingman dismisses it.

**Pass condition**:
- No crash.
- Either:
  - The result panel auto-dismisses and you see `[Wingman] dismiss_battle_result: clicked continue` in the log (from `wingman_safety.dismiss_battle_result_if_safe`), **or**
  - The result panel stays and you see `[Wingman] dismiss_battle_result: result panel or continue button not found` (a `panel_missing` result). This is safe — Wingman pauses rather than clicking blindly. The log will also show `pause_for_popup: post_battle_modal_blocking` or `pause_for_popup: post_battle_war_pending` if a modal is open or war was just declared.
- No stuck turn-end loop. If a turn is pending, the player can dismiss the panel and end the turn manually.

**Evidence**:
- `evidence/s9_dismiss.log` — log on battle completion + dismissal attempt, including the `dismiss_battle_result:` line.
- `evidence/s9_panel_state.png` — screenshot of the campaign map after the panel should have been dismissed (or after Wingman paused).

**Fail signals**:
- Result panel never dismisses despite `dismiss_battle_result: clicked continue` → SimulateLClick fired but the engine didn't process it; this is rare and usually a patch issue. Verify by manually clicking Continue to confirm the panel is dismissable at all.
- Log shows `dismiss_battle_result: result panel or continue button not found` repeatedly → UI path changed in a patch. The `RESULT_PANEL_CANDIDATES` and `CONTINUE_CANDIDATES` lists in `wingman_safety.lua` need new entries.
- Log shows `dismiss_battle_result: war declaration pending; pausing instead of clicking` → a war-declaration event fired within 2 turns of the panel; conservative behavior is to pause. Verify by closing the war panel and trying again.
- Log shows `WARN: dismiss_battle_result: SimulateLClick failed: ...` → the click API threw; `enter_error_safe_mode` should fire. Check for `ERROR_SAFE:` immediately after.

**Cross-references**: runs naturally at the end of S2.

---

## S10 — Multiplayer guard

**Objective**: Verify Wingman disables itself in multiplayer to prevent desyncs.

**Setup**:
- Start a multiplayer campaign (host or join). Both players need MCT and Wingman enabled.
- In MCT → Wingman settings on the host:
  - `wingman_enabled` = **true** (so the guard has something to do)
  - `wingman_campaign_handover_enabled` = **true** (so the guard has something to block)
- On both clients: same mod set.

**Steps**:
1. Launch the MP campaign.
2. Observe the log on both clients during the campaign load.

**Pass condition** (binary, on both clients):
- No crash.
- Log shows:
  - `[Wingman] init: enter`
  - `[Wingman] mp_guard: blocking init (multiplayer detected)`  *(from `wingman_safety.mp_guard` at the top of `wingman.init`)*
  - `[Wingman] init: disabled (multiplayer)`  *(from the early-return path in `wingman.init`)*
- No automation runs: no `scheduled end_turn`, no `cm:end_turn ok`, no `scripted_ai queued`, no `pause_for_popup:`.
- No desync warnings or `NetSync` errors.

**Evidence**:
- `evidence/s10_mp_log.log` — log on MP load showing the `mp_guard: blocking` line and the absence of automation.

**Fail signals**:
- Automation runs in MP → MP guard not at the top of `init`. Verify `wingman_safety.mp_guard("init")` is the first thing `wingman.init` does after logging `init: enter`. Each subsequent `init` call inside `wingman_campaign.on_faction_turn_start`, `wingman_battle.on_pending_battle`, `wingman_missions.init_for_faction`, etc. also calls `mp_guard` — if any of those run in MP without that call, this scenario fails.
- Log shows `mp_guard: cm:is_multiplayer threw for init: ...` → the `cm:is_multiplayer` API was renamed or the call signature changed; the `pcall` wrapper logs but returns false defensively.
- `WARN: mp_guard: cm missing for init; assuming single-player` → `cm` global wasn't available at script load time. The MP guard still returns true in this case (assume SP), which is wrong if you're actually in MP. Investigate before merging.

**Cross-references**: standalone. Should be run on every release, even if no MP-only changes were made.

---

## Evidence checklist

Use this table to track which artifacts you have at the end of a test pass. Mark each cell ✓/✗ and link to the file.

| Scenario | Pre-save | Post-save | Log(s) | Screenshot(s) | Pass | Notes |
|---|---|---|---|---|---|---|
| S1 handover happy path | | | | | | |
| S2 battle scripted_ai | | | | | | |
| S3 turn cap | | | | | | |
| S4 custom win | | | | | | |
| S5 faction ban | | | | | | |
| S6 save/load | | | | | | |
| S7 install | n/a | n/a | | | | |
| S8 diplomacy | | | | | | |
| S9 result dismiss | n/a | n/a | | | | |
| S10 MP guard | n/a | n/a | | | | |

A release is **READY** for Steam Workshop upload only when:

- All 10 scenarios have binary pass/fail evidence.
- All evidence files exist in `tests/manual/evidence/`.
- No scenarios have open "Fail signals" — every failure must be either fixed or marked "known limitation" in `CHANGELOG.md`.

---

## Known issues

_Populated as scenarios reveal problems. Format:_

- **[S?] short description.** First seen in version X.Y.Z. Status: open / fixed in X.Y.Z / known limitation.

(No issues yet — this section is intentionally empty on first release.)

---

## Smoke workflow (5 minutes)

If you don't have time for full S1–S10, run this abbreviated smoke. It covers boot, core orchestration, persistence, and rule evaluation.

1. Load the mod (**S7 setup**).
2. Start a new IE campaign, Reikland.
3. Enable campaign handover, set `wingman_auto_end_turn_delay_seconds` = 2.
4. End the turn once. Verify auto-end (S1 partial — the `scheduled end_turn` and `cm:end_turn ok` lines should appear).
5. Save + reload. Verify settings persist and the init lines don't duplicate (S6 partial).
6. Toggle turn cap on, set value = 3, save, and skip ahead. Verify `rules: breakpoint (turn_cap_reached)` fires on turn 3 (S3 partial).
7. Quit.

If those ~5 minutes pass, the mod is at least bootable and the core orchestration works. Defer S2, S4, S5, S8, S9, and S10 to a deeper test pass before each release.
