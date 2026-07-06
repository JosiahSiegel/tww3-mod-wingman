# Changelog

All notable changes to Wingman will be documented here.

## [Unreleased]

### Added
- **Active AI Controller** (W5) — `wingman_ai.lua` issues scripted orders
  on behalf of the player's faction at FactionTurnStart: moves idle armies
  toward enemy regions, queues building slots, recruits (when a unit key
  is configured), all capped by a per-turn order budget. New MCT settings:
  `wingman_ai_enabled`, `wingman_ai_aggression` (defensive/balanced/aggressive),
  `wingman_ai_orders_per_turn`.
- New manual test scenario **S11** in `tests/manual/wingman_scenarios.md`
  covering the AI Controller, with an explicit "honest scope box" listing
  what it does NOT do (diplomacy, techs, rites, heros, war declarations).
- `lupa_smoke.py` now loads `wingman_ai.lua` and exercises `run_for_local_faction`.

### Honesty note
This is a *scripted-order driver*, not a real AI personality. TWW3's
`cm:set_faction_human` is unsafe for player factions and we don't use it.
The real AI planner still runs inside battles. Diplomacy/techs/rites
are intentionally not touched.

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
