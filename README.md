# Wingman — Your AI Co-Pilot for Total War: WARHAMMER III

Let an AI co-pilot take the stick on your campaign and battles. Set rules, turn caps, victory conditions, faction bans, and periodic breaks. Compatible with Immortal Empires and most other campaigns.

## Features

- **Active AI Controller** — Wingman doesn't just hand the turn back; it actively *moves your armies* toward enemies, *queues* building slots, *recruits*, and *attacks*. Stays within a per-turn order budget for safety.
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
- **[`tests/manual/wingman_scenarios.md`](tests/manual/wingman_scenarios.md)** — 10 manual test scenarios (S1–S10) with binary pass/fail and evidence paths.
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
- **Emergency stop**: Open MCT → Wingman → toggle `wingman_enabled` off.

## How It Works

Wingman doesn't "give" your faction to the AI (the game has no such API for player factions, so ownership stays with you). What it **does** is issue scripted orders on your behalf:

1. **AI Controller** (W5, default on) — at the start of each of your turns, Wingman *moves* your idle armies toward enemy regions, *queues* a building in each of your settlements, *recruits* (when a safe unit_key is configured), and ends the turn. Your armies actually move on the campaign map.
2. **Turn automation** — after orders are queued, Wingman evaluates your rules (turn cap, custom win, faction bans, periodic break), optionally dismisses popups, and calls `cm:end_turn()` so the AI factions take their turns.

You become a spectator with full vision. You can take back control anytime by toggling Wingman off (or use **periodic breakpoints** to be handed control every N turns).

> **Honest scope (W5 AI Controller).** It's a *scripted-order driver*, not a real AI personality. TWW3 has no API to transfer your faction to AI control. Inside battles, the real AI planner still makes tactical decisions. Diplomacy, rites, techs, hero skill picks, and war declarations are not script-driven — they use vanilla logic. The AI Controller handles the visible parts: movement, recruitment, building. See `tests/manual/wingman_scenarios.md` → **S11** for what passes / fails.

## Known Limitations (v0.1 alpha)

- Scripted battle AI doesn't perfectly replicate a player's tactical decisions; it uses the game's standard AI plans (attack / defend / auto).
- No custom battle maps or new units.
- Tested on Immortal Empires only; Realm of Chaos and other campaigns should work but are not fully verified.

## License

[See LICENSE](./LICENSE)
