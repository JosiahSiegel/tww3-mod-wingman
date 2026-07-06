# Changelog

All notable changes to Wingman will be documented here.

## [Unreleased] — W7

### Added
- **W7 Autopilot mode** — full UI lock + CAI personality rewrite +
  scripted orders. When the user engages Autopilot, Wingman:
  1. Calls `cm:steal_user_input(true)` so all keyboard input is
     routed to script (the player can still move the camera; mouse
     and gamepad still work).
  2. Locks the end-turn button via the CA-blessed 3-call pattern:
     `uim:override("end_turn"):set_allowed(false)` (persistent
     across save/load) + `cm:override_ui("disable_end_turn", true)`
     + `cm:disable_end_turn(true)`.
  3. Installs the user-selected CAI personality on the player
     faction via `cm:force_change_cai_faction_personality` AND
     `cm:cai_set_faction_script_context("ALPHA")` (defense-in-depth).
  4. Shows the "Wingman in Control — click to take back" banner
     via `core:get_or_create_component("wingman_banner", ...)` +
     `SetVisible(true)`. The banner has a "Take Back Control"
     button.
  5. Registers an ESC key callback via
     `cm:steal_escape_key_with_callback` so the player can hold
     ESC for 3 seconds to take back control without clicking the
     banner button.
  6. Persists the autopilot-active flag via `cm:set_saved_value`
     and re-applies the lock on save/load via
     `cm:add_loading_game_callback`.
- **W7 Advisory mode** — per-turn 3-button dilemma at
  FactionTurnStart (Apply / Skip / Always Apply). Uses
  `cm:create_dilemma_builder` + 3 `add_choice_payload("FIRST"|"SECOND"|"THIRD")`
  + `cm:launch_custom_dilemma_from_builder` (the vanilla
  `mc_peg_street_pawnshop` 3-button pattern). A
  `DilemmaChoiceMadeEvent` listener gates whether the W6 step
  dispatch runs. "Always Apply" sets `advisory_auto_accept = true`
  so future turns auto-apply without prompting.
- **New W7 settings** (MCT dropdowns + strings):
  - `wingman_ai_mode` (off | advisory | autopilot)
  - `wingman_ai_autopilot_personality` (CAI personality key, default
    `wh3_combi_legendary_default`)
  - `wingman_ai_takeback_hotkey` (esc | none)
  - `wingman_ai_advisory_dilemma_key` (dilemma key, default
    `wingman_advisory_default`)
- **New UI asset**: `ui/campaign ui/wingman_banner.twui.xml` —
  the persistent banner with a text label and a "Take Back Control"
  button (id = `button_take_back`). The Lua side listens for
  `ComponentLClickUp` with that id and calls
  `wingman_ai.release_autopilot()`.
- **New tests**: `tests/manual/test_w7_autopilot.py` — 10 focused
  tests covering engage, release, advisory toggle, save/load
  round-trip, personality propagation, dilemma firing,
  banner show/hide, take-back button, ESC take-back.
- **New runnable scenarios**: S11d (Autopilot) and S11e (Advisory)
  in `tests/manual/wingman_scenarios.md`. Quick smoke list now
  includes both; evidence checklist now has 12 rows.

### Honest scope note (W7)
- Autopilot mode is a *scripted-order driver + UI lock + CAI
  personality rewrite*, NOT a literal `cm:set_faction_human`
  ownership flip (no such API exists in TWW3 — confirmed in vanilla
  source).
- The "ESC hold for 3 seconds" is the engine's responsibility for
  when it fires the callback; the Lua side just handles the
  callback when it fires.
- `wingman_ai_autopilot_personality` is a CAI personality key, not
  a CAI script context value. The 2 systems coexist: the personality
  key controls which ai_personalities row is loaded for the
  faction; the context value (`"ALPHA"`) controls which CAI
  evaluation profile is used. Both are applied for defense-in-depth.
- The banner uses the simplest possible layout: one label + one
  button. A future polish pass could add a faction-flag icon and
  a settings cog, but the tested contract is show/hide + take-back
  click only.
- The take-back button's on-click effect is reversible: clicking
  it again does nothing (autopilot is off). Re-engaging autopilot
  re-mounts the banner via `core:get_or_create_component` (the
  engine reuses the existing component if it's still alive).

## [Unreleased] — W6

### Added
- **W6 AI Controller — full behavioral surface** (extends W5):
  - **Attack adjacent enemies** via `cm:attack` / `cm:attack_region` (gated
    by `wingman_ai_attack_adjacent`).
  - **Defensive garrison + stand-and-defend stance** via `cm:join_garrison`
    + `cm:force_character_force_into_stance` (defensive aggression only).
  - **Instantly research all faction technologies** via
    `cm:instantly_research_all_technologies` (once per campaign; bulk-only —
    no per-tech API exists in TWW3, documented as a hard limitation).
  - **Perform faction rituals** via `cm:perform_ritual` (once per turn;
    limited discovery via a candidate-key list).
  - **Diplomacy** via `cm:force_make_trade_agreement`, `cm:force_make_peace`,
    `cm:force_alliance`, `cm:force_make_vassal`, `cm:force_confederation`,
    `cm:force_declare_war` (gated by `wingman_ai_diplomacy_enabled`,
    default OFF; war declarations are intentionally NOT auto-issued in v0.1).
  - **CAI personality rewrite (Option B)** via
    `cm:cai_set_faction_script_context(local_faction, "ALPHA")` runs once
    per campaign so the engine's AI evaluation heuristics for the player's
    faction use the highest-skill profile.
  - **Recruitment rewritten** to discover valid unit_keys via
    `force:recruitment_items()` + `cm:char_can_recruit_unit()` instead of
    relying on a hardcoded literal — works across all factions safely.
  - **Persistence helpers** (`mark_tech_research_done`, `mark_ritual_done`,
    `was_ritual_done_recently`) on `wingman_state` so AI one-shot actions
    survive save/load.

### Fixed
- **wingman_ai.lua W5 was issuing scripted orders against four cm: APIs
  that don't exist in TWW3** (`order_move_to_settlement`, `force_recruit_unit`,
  `construct_building`, `queue_building_for_faction`). Calls were silently
  no-op'd under pcall guards. Replaced with real APIs: `cm:move_to` (with
  `cm:get_region(rk):settlement():logical_position_x/y()` coords),
  `cm:grant_unit_to_character`, `cm:add_building_to_settlement_queue`,
  `cm:attack_region`.
- **wingman_ai.lua docstring at line 31** claimed "TWW3 has no
  `cm:force_declare_war` API" — that was WRONG. The API exists with
  signature `(attacker, defender, invite_attacker_allies, invite_defender_allies)`
  and has 7+ call sites in `Frodo45127/tww3_dynamic_disasters`. Fixed.
- **lupa smoke gate (`scripts/lupa_smoke.py`)** stubbed the missing
  APIs as if they existed — this masked the regression. Stubs now reflect
  real TWW3 APIs.

### Honest scope note (W6)
- We do NOT transfer faction ownership to AI (TWW3 has no
  `cm:set_faction_human` — confirmed in vanilla source
  `/tmp/opencode/wh3-dump/script/_lib/lib_campaign_manager.lua`: only
  read-only `cm:is_faction_human` exists).
- The W6 approach is: rewrite the player's AI evaluation CONTEXT to
  "ALPHA" via `cm:cai_set_faction_script_context`, then drive the actual
  turn with scripted orders.
- Recruitment auto-discovers valid unit_keys — no literal keys hardcoded.
- Diplomacy reads only what's available via `force_*` outputs; engine
  acceptance determines success.
- Per-tech research is impossible; bulk only.
- `step_construct_buildings` is a stub in v0.1 (returns 0); it requires
  a per-faction building-chain key mapping that doesn't exist yet.
- Auto-war declarations are NOT issued in v0.1; the infrastructure
  (order_force_declare_war + safe_diplomacy budget) is in place but the
  policy is OFF until user opts in.

## [0.1.0-alpha] - 2026-07-05

### Added
- Initial alpha release.
- Campaign handover (auto-end-turn orchestration).
- Battle takeover with 4 modes (scripted AI, autoresolve-if-favorable, pause-to-choose, manual-observe).
- Rules engine: turn cap, custom victory (settlements / defeated factions), faction restriction watcher.
- Periodic breakpoints.
- MCT settings panel with co-pilot-themed labels.
- Save/load persistence via `cm:save_named_value` and `core:svr_save_registry_string`.

### Safety
- Multiplayer guard (auto-disable in MP).
- Diplomacy popup pause.
- Battle result dismissal.
- `pcall` wrappers around risky API calls.
- Error-safe mode that halts automation on unexpected errors.
