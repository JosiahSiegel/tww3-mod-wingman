# Wingman — Your AI Co-Pilot for Total War: WARHAMMER III

Let an AI co-pilot take the stick on your campaign and battles. Set rules, turn caps, victory conditions, faction bans, and periodic breaks. Compatible with Immortal Empires and most other campaigns.

## Features

- **Active AI Controller** — Wingman doesn't just hand the turn back; it actively *moves your armies* toward enemies, *queues* building slots, *recruits*, and *attacks*. Stays within a per-turn order budget for safety.
- **W7 Autopilot mode** — full UI lock + CAI personality swap + scripted orders. Click "Take Back Control" on the banner (or hold ESC 3s) to take back control anytime. The closest you can get to "AI plays my turn" in TWW3 without a literal ownership-flip API.
- **W7 Advisory mode** — at the start of each FactionTurnStart, Wingman surfaces a 3-button dilemma (Apply / Skip / Always Apply). You decide each turn whether the AI runs its plan.
- **Campaign Auto-Pilot** — Wingman auto-ends your turns so AI factions play uninterrupted while you watch.
- **Battle Takeover** — choose from scripted AI fighting, autoresolve-if-favorable, pause-to-choose, or just spectate.
- **Rules & Limits** — turn caps, custom victory conditions (own these settlements / destroy these factions), banned-faction watcher.
- **Periodic Breaks** — Wingman hands control back every N turns so you can review.
- **Save-Friendly** — settings persist across save/load and game restart.

## Requirements

- **Total War: WARHAMMER III** (Steam)
- **[Mod Configuration Tool (MCT)](https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021)** — required dependency. Auto-subscribes when you enable Wingman.

## Installation

1. Subscribe to this mod on Steam Workshop.
2. Launch the game (use the **original Total War launcher**, not the new EA Mod Manager — Workshop uploads only work in the original).
3. Open Mod Manager. Enable **Mod Configuration Tool** first, then enable **Wingman**.
4. Start any campaign. Wingman's settings panel appears in the MCT menu.

### Building and testing locally

If you want to build the mod from source and test changes locally (contributors, testers):

- **[`tests/manual/LOCAL_TESTING.md`](tests/manual/LOCAL_TESTING.md)** — end-to-end local testing guide: pack build (pure-Python), install, script-logging setup, iterative dev loop, lupa pre-launch smoke test (`scripts/lupa_smoke.py`), common pitfalls, evidence capture protocol.
- **[`pack/BUILD_INSTRUCTIONS.md`](pack/BUILD_INSTRUCTIONS.md)** — pack build steps (`scripts/build_pack.py`) + Workshop upload flow.
- **[`tests/manual/wingman_scenarios.md`](tests/manual/wingman_scenarios.md)** — 12 manual test scenarios (S1–S10 + S11d Autopilot + S11e Advisory) with binary pass/fail and evidence paths.
- **[`.github/workflows/release.yml`](.github/workflows/release.yml)** — automated CI build + Steam Workshop publish workflow.

### Continuous Integration (GitHub Actions)

The repo includes a `.github/workflows/release.yml` workflow that automates building and publishing.

**What it does** (on `v*` tag push, or manual trigger):

1. **Smoke test** — runs `scripts/lupa_smoke.py` to verify all 9 Lua modules load together under stubbed TWW3 engine globals. Catches syntax errors before the pack build.
2. **Pack build** — runs `scripts/build_pack.py` (pure-Python PFH5 writer, zero deps) to produce `dist/!wingman.pack` with PFH5 magic validation, plus copies `dist/!wingman.png`. No RPFM, no apt installs, no large binary downloads.
4. **Draft GitHub Release** — uploads the pack + thumbnail as a draft release (so the durable artifact exists before any external publish).
5. **Steam Workshop publish** — gated by a `steam-workshop` GitHub Environment (required reviewer). Runs `weilbyte/steam-workshop-upload@v1` against appid `1142710`.

**Required repo setup** (one-time, in repo Settings):

- **Variables → Actions**: `WORKSHOP_ITEM_ID` — numeric Workshop item ID, created manually on first publish via the in-game launcher (SteamCMD can't accept the EULA dialog).
- **Secrets → Actions**: `STEAM_USERNAME`, `STEAM_PASSWORD`, `STEAM_TFASEED` (Steam Guard shared_secret, not a TOTP code).
- **Environments**: `steam-workshop` with at least 1 required reviewer, limited to `main` branch.

**⚠️ TWW3 SteamCMD caveat**: Community reports indicate TWW3's Mod Manager sometimes rejects SteamCMD-uploaded items with `K_EResultFail`. If CI publish fails, the durable `.pack` is already in the GitHub Release — fall back to manual in-game upload (original TW launcher → Mod Manager → right-click → Upload). See [WORKSHOP.md](./WORKSHOP.md) for that flow.

## Safety

- **Multiplayer**: Wingman disables itself automatically to prevent desyncs.
- **Diplomacy popups**: by default Wingman pauses if a diplomacy panel appears (this is the #1 cause of crashes in similar mods).
- **Battle results**: Wingman auto-dismisses the post-battle results screen only when safe; otherwise hands back to you.
- **Emergency stop**: Open MCT → Wingman → toggle `wingman_enabled` off. (For W7 Autopilot mode specifically: click the "Take Back Control" button on the in-game banner, or hold ESC for 3 seconds.)

## How It Works

Wingman doesn't "give" your faction to the AI (the game has no such API for player factions — confirmed in vanilla source: only the read-only `cm:is_faction_human` exists; `cm:set_faction_human` was never an API). What it **does** is issue scripted orders on your behalf AND rewrite your faction's AI-evaluation context to the highest-skill profile:

1. **CAI personality rewrite (W6 Option B)** — at the start of the campaign, Wingman calls `cm:cai_set_faction_script_context(local_faction, "ALPHA")` so the engine's strategic AI (stance, threat, priorities) uses the highest-skill profile when evaluating your faction.
2. **Active AI controller (W6 Option A)** — each turn, Wingman issues scripted orders on your behalf:
   - **Move armies** toward / into enemy regions
   - **Attack adjacent enemies** (gated by `wingman_ai_attack_adjacent`)
   - **Siege settlements** via `cm:attack_region`
   - **Garrison idle defenders** in friendly settlements (defensive aggression)
   - **Queue buildings** in each owned settlement
   - **Recruit units** using auto-discovered unit_keys (pool-based, faction-safe)
   - **Research all technologies** (bulk, once per campaign)
   - **Perform faction rituals** (once per turn)
   - **Handle diplomacy** — trade agreements, peace, alliances, vassals, confederations, war declarations (gated by `wingman_ai_diplomacy_enabled`, default OFF; war declarations are intentionally not auto-issued in v0.1)
3. **Turn automation** — after orders are queued, Wingman evaluates your rules (turn cap, custom win, faction bans, periodic break), optionally dismisses popups, and calls `cm:end_turn()` so the AI factions take their turns.

You become a spectator with full vision. You can take back control anytime by toggling Wingman off (or use **periodic breakpoints** to be handed control every N turns).

> **Honest scope (W6 AI Controller).** It's a *scripted-order driver + personality rewrite*, not a literal AI take-over. TWW3 has no `cm:set_faction_human` API to literally transfer ownership; we use the closest equivalent (`cm:cai_set_faction_script_context`). Inside battles, the real AI planner still makes tactical decisions. The controller handles the visible parts: movement, attack, recruitment, building, research, rites, diplomacy. See `tests/manual/wingman_scenarios.md` → **S11 / S11b / S11c** for what passes / fails.

## W7 Modes: Autopilot & Advisory

W7 adds two new modes that build on the W6 controller. The mode is selected in MCT → Wingman → Campaign Handover → `wingman_ai_mode`:

### Autopilot (full lock)

When the user sets `wingman_ai_mode = autopilot`, Wingman engages full UI lock + CAI personality rewrite on the player faction:

- `cm:steal_user_input(true)` — all keyboard input is routed to script (the player can still move the camera; mouse and gamepad still work).
- `uim:override("end_turn"):set_allowed(false)` + `cm:override_ui("disable_end_turn", true)` + `cm:disable_end_turn(true)` — the CA-blessed 3-call end-turn lock pattern. The first call persists across save/load; the other two are per-call.
- `cm:force_change_cai_faction_personality(local_faction, chosen_personality)` + `cm:cai_set_faction_script_context(local_faction, "ALPHA")` — defense-in-depth: the explicit personality swap changes which `ai_personalities` row is loaded for the faction; the script context change tells the engine to use the highest-skill evaluation profile.
- `core:get_or_create_component("wingman_banner", ...)` + `SetVisible(true)` — the "Wingman in Control — click to take back" banner appears. The banner has a button (`button_take_back`) that fires `ComponentLClickUp` → `release_autopilot()`.
- `cm:steal_escape_key_with_callback("wingman_esc", on_esc_take_back, false)` — the player can also hold ESC for 3 seconds to take back control.
- `cm:set_saved_value("wingman_ai_autopilot_active", true)` + `cm:add_loading_game_callback(...)` — the lock persists across save/load and re-applies automatically on load.

To exit Autopilot, the user can either (a) click the "Take Back Control" button on the banner, (b) hold ESC for 3 seconds, or (c) toggle `wingman_ai_mode` to "off" in MCT. All three paths call `wingman_ai.release_autopilot()`, which reverses every lock.

### Advisory (per-turn confirmation)

When the user sets `wingman_ai_mode = advisory`, at the start of each FactionTurnStart for the player faction, Wingman fires a 3-button dilemma (Apply / Skip / Always Apply):

- `cm:create_dilemma_builder("wingman_advisory_default")` + 3 `add_choice_payload("FIRST"|"SECOND"|"THIRD", payload)` + `cm:launch_custom_dilemma_from_builder(builder, faction)` — the canonical TWW3 3-button prompt pattern (vanilla `mc_peg_street_pawnshop.lua:41-117`).
- A `DilemmaChoiceMadeEvent` listener gates whether the W6 step dispatch runs:
  - **Apply** (choice 1) — run the W6 step dispatch this turn.
  - **Skip** (choice 2) — set `state.skip_remaining_steps = true`; `run_for_local_faction` bails out before any orders are issued.
  - **Always Apply** (choice 3) — run the W6 step dispatch AND set `state.advisory_auto_accept = true` so future turns auto-apply without showing the dilemma (until the user toggles the mode off).

Advisory mode is non-locking by design — the player can still interact with the campaign UI at any time. The W6 step dispatch is gated only on the user's per-turn choice.

See `tests/manual/wingman_scenarios.md` → **S11d** (Autopilot) and **S11e** (Advisory) for the runnable TDD scenarios.

## Known Limitations (v0.1 alpha)

- Scripted battle AI doesn't perfectly replicate a player's tactical decisions; it uses the game's standard AI plans (attack / defend / auto).
- No custom battle maps or new units.
- Tested on Immortal Empires only; Realm of Chaos and other campaigns should work but are not fully verified.

## License

[See LICENSE](./LICENSE)
