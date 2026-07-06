# Changelog

All notable changes to Wingman will be documented here.

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
