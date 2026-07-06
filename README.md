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

## Known Limitations (v0.1 alpha)

- Scripted battle AI doesn't perfectly replicate a player's tactical decisions; it uses the game's standard AI plans (attack / defend / auto).
- No custom battle maps or new units.
- Tested on Immortal Empires only; Realm of Chaos and other campaigns should work but are not fully verified.

## License

[MIT](./LICENSE) — this mod contains no Games Workshop or Creative Assembly intellectual property, only original Lua code.
