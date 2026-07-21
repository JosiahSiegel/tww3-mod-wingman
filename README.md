# Wingman — Your AI Co-Pilot for Total War: WARHAMMER III

Let an AI co-pilot take the stick on your campaign and battles. Set rules, turn caps, victory conditions, faction bans, and periodic breaks. Compatible with Immortal Empires and most other campaigns.

## Features

- **Active AI Controller (W6)** — Wingman doesn't just hand the turn back; it actively *moves your armies*, *queues buildings*, *recruits*, *attacks*, and *sieges* on your behalf. Stays within a per-turn order budget for safety.
- **Autopilot mode (W7)** — full UI lock + CAI personality swap + scripted orders. Click "Take Back Control" on the banner (or hold ESC 3s) to take back control anytime. The closest you can get to "AI plays my turn" in TWW3 without a literal ownership-flip API.
- **Advisory mode (W7)** — at the start of each turn, Wingman surfaces a 3-button dilemma (Apply / Skip / Always Apply). You decide per turn whether the AI runs its plan.
- **Full turn coverage (W8)** — 14-step dispatch handles post-battle decisions (replenish AP, stop convalescing), heal damaged armies, embed idle agents, auto-accept incoming trade/peace offers, and queue buildings in empty settlement slots. Minimizes "turn stalls".
- **Spectator panel (W8)** — rich in-game panel showing current turn, per-turn action summary, last few decisions, and a "Follow Next AI Army" button. Appears alongside the take-back banner in Autopilot mode.
- **Strategic pause (W8)** — opt into a "give me a checkpoint every N turns" 4-button dilemma (Continue / Skip This Pause / Take Control / Always Pause).
- **Campaign Auto-Pilot** — auto-ends your turns so AI factions play uninterrupted while you watch.
- **Battle Takeover** — 4 modes: scripted AI fighting, autoresolve-if-favorable, pause-to-choose, or just spectate.
- **Rules & Limits** — turn caps, custom victory conditions (own these settlements / destroy these factions), banned-faction watcher.
- **Save-Friendly** — settings persist across save/load and game restart.

## Requirements

- **Total War: WARHAMMER III** (Steam)
- **[Mod Configuration Tool (MCT)](https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021)** — required dependency. Auto-subscribes when you enable Wingman.

## Installation

1. Subscribe to this mod on Steam Workshop.
2. Launch the game via the **original Total War launcher** (NOT the new EA Mod Manager — Workshop uploads only work in the original).
3. Open Mod Manager. Enable **Mod Configuration Tool** first, then enable **Wingman**.
4. Start any campaign. Wingman's settings panel appears in the MCT menu.

## Safety

- **Multiplayer**: Wingman disables itself automatically to prevent desyncs.
- **Diplomacy popups**: by default Wingman pauses if a diplomacy panel appears (the #1 cause of crashes in similar mods).
- **Battle results**: Wingman auto-dismisses the post-battle results screen only when safe; otherwise hands back to you.
- **Emergency stop**:
  - **Default**: Open MCT → Wingman → toggle `wingman_enabled` off.
  - **Autopilot mode**: click "Take Back Control" on the in-game banner, or hold ESC for 3 seconds.

## Modes (quick reference)

| Mode | What it does | Take back control via |
|---|---|---|
| **Off** (default) | Standard W6 controller issues scripted orders + CAI personality rewrite on your turn | Toggle `wingman_enabled` off in MCT |
| **Advisory** | 3-button dilemma at FactionTurnStart (Apply / Skip / Always Apply) | Click "Skip" in the dilemma |
| **Autopilot** | Full UI lock + CAI personality swap + scripted orders + spectator panel | Banner button, ESC 3s, or MCT toggle |

Set in MCT → Wingman → Campaign Handover → `wingman_ai_mode`.

## Why Wingman can't "become the AI" (engine ceiling)

You might wonder: why doesn't Wingman just flip your faction to AI-controlled and let the engine play it natively? **Because the TWW3 engine doesn't allow it — from any modding surface.**

- The `is_human` bit on a faction is a **C++-owned, signed-binary decision**. CA exposes exactly one Lua binding for it — the read-only `faction:is_human()` (verified in vanilla source at `lib_campaign_manager.lua:3878`). There is **no** `cm:set_faction_human`, no `make_faction_ai`, no DB column, no `.pack` override. The full `FACTION_SCRIPT_INTERFACE` has 267 methods and **zero** setters for the human bit.
- A C++-level fix would require recompiling the game executable, which is impossible: TWW3 is closed-source and the Steam binary is signed.
- The most successful community "spectate AI" mod — **[Auto-Run & Spectate AI](https://steamcommunity.com/sharedfiles/filedetails/?id=3008387343)** by Acephelos — is at the *same* ceiling. It does not flip the human bit; it auto-ends your turn and grants vision via map-reveal.

**What Wingman does instead** (the closest the engine permits): UI lock + legendary CAI personality swap + scripted-order dispatch on every turn + CAI evaluation-context rewrite to "ALPHA" (highest skill). W8's full-coverage step dispatch makes the "your faction is technically still human" gap academic in practice — Wingman handles movement, attacks, sieges, recruitment, buildings, research, rites, diplomacy, healing, post-battle cleanup, and hero actions, then ends the turn.

## How It Works (technical)

1. **CAI personality rewrite** — at the start of the campaign, Wingman calls `cm:cai_set_faction_script_context(local_faction, "ALPHA")` so the engine's strategic AI (stance, threat, priorities) uses the highest-skill profile when evaluating your faction.
2. **Active AI controller** — each turn, Wingman issues scripted orders on your behalf: move armies, attack adjacent enemies, siege settlements, garrison idle defenders, queue buildings, recruit via pool discovery, research all technologies, perform faction rituals, handle diplomacy.
3. **Turn automation** — after orders are queued, Wingman evaluates your rules (turn cap, custom win, faction bans, periodic break), optionally dismisses popups, and calls `cm:end_turn()` so the AI factions take their turns.

You become a spectator with full vision. Take back control anytime via toggle, banner, or ESC.

## For contributors

- **[`tests/manual/LOCAL_TESTING.md`](tests/manual/LOCAL_TESTING.md)** — local dev loop: build, install, iterative cycle, lupa pre-launch smoke, common pitfalls.
- **[`pack/BUILD_INSTRUCTIONS.md`](pack/BUILD_INSTRUCTIONS.md)** — pack build + Workshop upload flow.
- **[`tests/manual/wingman_scenarios.md`](tests/manual/wingman_scenarios.md)** — 16 manual test scenarios (S1–S10, S11, S11b, S11c, S11d, S11e) with binary pass/fail and evidence paths.
- **[`.github/workflows/release.yml`](.github/workflows/release.yml)** — CI build + Steam Workshop publish (gated by reviewer environment).
- **[`WORKSHOP.md`](WORKSHOP.md)** — Steam Workshop publishing checklist.
- **[`CHANGELOG.md`](CHANGELOG.md)** — release notes.

## Known Limitations

- Scripted battle AI doesn't perfectly replicate a player's tactical decisions; it uses the game's standard AI plans (attack / defend / auto).
- No custom battle maps or new units.
- Tested on Immortal Empires only; Realm of Chaos and other campaigns should work but are not fully verified.

## Recent audit history (post-alpha)

The mod has been through 6 rounds of deep-dive code review (14 merged PRs). Each round caught real bugs in the AI dispatch, listener wiring, perf, or state machine — none of which the lupa-smoke harness alone could expose. Highlights:

- **Round 1** (PRs #1–#8) — 5 critical behavior bugs in AI dispatch (defensive cap, list_characters 1-based, type-check-always-true on mission_manager, etc.).
- **Round 2** (PR #9) — 2 safety bugs: `mp_guard` treated a thrown `cm.query_model` as multiplayer, and `PANEL_KEYWORDS` was a substring match instead of exact-key.
- **Round 3** (PRs #10, #11) — hot-path perf fixes (O(N²) → O(N) in `step_hero_actions`, O(N) → O(1) hoists in `iter_regions`/`iter_factions`) plus a realistic TWW3 engine stub harness and a Lua 5.1 source-level compat scanner.
- **Round 4** (PR #12) — 3 critical listener bugs: a 6-arg call to `wingman_listeners.register` made the AI a no-op in production, the spectator panel callback was `false`, and the missions module bypassed the central registry.
- **Round 5** (PR #13) — removed leftover `[Wingman DIAG]` debug logs; added a 422-line MCT settings test; fixed cross-file constant duplication between `wingman_battle_init.lua` and `wingman_constants.lua` by switching the battle state to `dofile` the campaign-side constants.
- **Round 6** (PR #14) — state-machine correctness test for `wingman_state.lua` (mode machine, monotonic turn processing, ritual-recent fallback, schema-migration ordering). No production change; locks down the public contract.

TWW3 PRs are reviewed by [umactually](https://github.com/JosiahSiegel/umactually) (the maintainer's AI code-review CLI) — see PR #13 for the first umactually-APPROVED TWW3 PR.

## License

[MIT](./LICENSE) — this mod contains no Games Workshop or Creative Assembly intellectual property, only original Lua code.

## Public Lua API (for contributors and downstream modders)

Every module below is loaded by the campaign loader. None of these APIs
require `core` or `cm` to be present at load time — they're safe to
import from any Lua context (including tests).

### `wingman_constants` — single source of truth for stringly-typed values

Holds every string constant used in 2+ Lua files. Use these instead of
string literals; if you find yourself typing `"scripted_ai"` or
`"aggressive"` anywhere, look it up here.

```lua
local C = wingman_constants

-- Battle control modes (wingman_battle_control_mode setting)
C.MODE_SCRIPTED_AI             -- "scripted_ai"
C.MODE_AUTORESOLVE_IF_FAVORABLE -- "autoresolve_if_favorable"
C.MODE_PAUSE_TO_CHOOSE         -- "pause_to_choose"
C.MODE_MANUAL_OBSERVE          -- "manual_observe"

-- Aggression profiles (wingman_ai_aggression setting)
C.AGGRESSION_DEFENSIVE         -- "defensive"
C.AGGRESSION_BALANCED          -- "balanced"
C.AGGRESSION_AGGRESSIVE        -- "aggressive"

-- Setting key names (read these to avoid stringly-typed lookups)
C.SETTINGS.WINGMAN_ENABLED
C.SETTINGS.WINGMAN_AI_ORDERS_PER_TURN
C.SETTINGS.WINGMAN_AI_DIFFICULTY
C.SETTINGS.WINGMAN_AI_AGGRESSION
C.SETTINGS.WINGMAN_BATTLE_CONTROL_MODE
C.SETTINGS.WINGMAN_DEBUG_LOGGING

-- Validators
C.is_battle_mode(value)        -- true for the 4 valid modes
C.is_aggression(value)         -- true for the 3 valid profiles
```

### `wingman_listeners` — central event-listener registry

Use this for every `core:add_listener` call. Tracks registered names
and provides bulk removal on save/load. Idempotent on re-registration.

```lua
-- Register a listener. Returns true on success, false on engine error.
wingman_listeners.register(
    name,      -- string, unique within the mod
    event,     -- string, engine event ("FactionTurnStart", ...)
    condition, -- typically true; or a function returning bool
    callback,  -- function(context) called when the event fires
    persist    -- bool (optional, default false): survive save/load
)

-- Remove a single listener
wingman_listeners.unregister(name)

-- Bulk-remove every tracked listener. Returns the count of remove
-- ATTEMPTS (success or failure). Use this from your mod's shutdown
-- path or on save/load to avoid leaks.
local n_removed = wingman_listeners.unregister_all()

-- Diagnostics
wingman_listeners.count()                       -- number tracked
wingman_listeners.is_registered(name)           -- bool
wingman_listeners.list_names()                  -- array of strings
local n_tracked, n_dupes = wingman_listeners.diagnostics()
```

### `wingman_state` — settings + state persistence

`SCHEMA_VERSION` is the version of the on-disk schema. When you bump
it, add a `MIGRATIONS[new_version]` entry.

```lua
-- Read the current schema
wingman_state.SCHEMA_VERSION   -- number, currently 1

-- Read the full settings table (defaults + persisted + MCT)
wingman_state.get_settings()   -- table

-- Update settings with validation + clamping
local validated = wingman_state.update_settings({
    wingman_ai_orders_per_turn = 8,
    wingman_battle_control_mode = wingman_constants.MODE_AUTORESOLVE_IF_FAVORABLE,
})

-- JSON encode (for diagnostic dumps / test fixtures)
wingman_state.json_encode(value)  -- string

-- Read defaults without a get_settings() round-trip
wingman_state.DEFAULTS   -- table (read-only)

-- Schema migration hook (for the next maintainer who bumps SCHEMA_VERSION)
wingman_state.MIGRATIONS = {
    -- [2] = function(settings) ... return settings end,
}
-- Test it with:
wingman_state.migrate_settings(saved_settings, from_version, to_version)
```

### Load order (for custom loaders)

`lupa_smoke.py` is the canonical loader. If you write your own
loader, the order is:

1. `wingman_constants.lua`    (no deps)
2. `wingman_listeners.lua`    (no deps)
3. `wingman_state.lua`        (needs wingman_constants)
4. `wingman_safety.lua`       (needs wingman_listeners)
5. `wingman_missions.lua`
6. `wingman_rules.lua`
7. `wingman_ai.lua`           (needs wingman_state, wingman_listeners, wingman_constants)
8. `wingman_campaign.lua`     (needs wingman_state, wingman_listeners)
9. `wingman_battle.lua`       (needs wingman_state, wingman_listeners)
10. `wingman_init.lua`
11. `wingman_battle_init.lua` (battle-side)
12. `wingman_mct.lua`         (MCT settings UI)

Each module that depends on another runs an `if type(X) ~= "table" then
error(...) end` guard at load time. Loading a consumer before its
dependency produces a clear error, not a delayed nil deref.

17 test files, 130+ checks, all green. Run from the repo root:

```bash
python3 scripts/lupa_smoke.py
for t in tests/manual/test_*.py; do python3 "$t"; done
```

| File | What it covers |
|---|---|
| `test_behavior_bugs.py` | Round-1 behavior bug regressions (5 checks) |
| `test_behavior_bugs_2.py` | Round-2 behavior bug regressions (9 checks) |
| `test_state_migrations.py` | Schema migration chain (5 checks) |
| `test_listener_helper.py` | `wingman_listeners` register/unregister lifecycle (5 checks) |
| `test_listener_arg_shapes.py` | Round-4 listener-arg-shape regressions (7 checks; locks down the central registry contract) |
| `test_json_encode.py` | Numeric-aware key sort in JSON encoder (5 checks) |
| `test_constants_module.py` | `wingman_constants` single-source-of-truth (5 checks) |
| `test_load_order_guards.py` | Every cross-module consumer has a load-order guard (5 checks) |
| `test_hot_path_perf.py` | O(1) hoists in `iter_regions`/`iter_factions`; O(N²)→O(N) in `step_hero_actions` (5 sections) |
| `test_realistic_engine.py` | Real TWW3 API-shape stubs for tests that need full engine state (7 sections) |
| `test_lua51_compat.py` | Source of truth: no `goto`, `::label::`, `bit32.*`, `//`, `loadstring`, `string.pack`, or unguarded `table.unpack` in any Lua source (3 checks) |
| `test_mct_integration.py` | MCT module load + register path |
| `test_mct_settings.py` | MCT module settings (defaults, slider clamping, dropdown normalization, CSV parsing, cross-file constant sync; 13 sections) |
| `test_state_machine.py` | Round-6 state-machine correctness for `wingman_state.lua` (5 sections) |
| `test_w6_ai_features.py` | W6 step dispatch end-to-end |
| `test_w7_autopilot.py` | W7 autopilot + advisory mode behavior |
| `test_w8_step_coverage.py` | W8 14-step dispatch coverage (20 checks) |

Tests are a mix of fast lupa-smoke stubs (`test_behavior_bugs.py`, `test_w6_ai_features.py`) and realistic-engine tests (`test_realistic_engine.py`, `test_state_machine.py`) that exercise the real shape of TWW3 engine state. See `tests/manual/LOCAL_TESTING.md` for the dev loop.
