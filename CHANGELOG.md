# Changelog

All notable changes to Wingman will be documented here.

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
