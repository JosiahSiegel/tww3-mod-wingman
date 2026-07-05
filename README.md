# Wingman — Your AI Co-Pilot for Total War: WARHAMMER III

Let an AI co-pilot take the stick on your campaign and battles. Set rules, turn caps, victory conditions, faction bans, and periodic breaks. Compatible with Immortal Empires and most other campaigns.

## Features

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

- **[`tests/manual/LOCAL_TESTING.md`](tests/manual/LOCAL_TESTING.md)** — end-to-end local testing guide: RPFM build, install, script-logging setup, iterative dev loop, lupa pre-launch smoke test (`scripts/lupa_smoke.py`), common pitfalls, evidence capture protocol.
- **[`pack/BUILD_INSTRUCTIONS.md`](pack/BUILD_INSTRUCTIONS.md)** — RPFM build steps (`scripts/build_pack.sh`, `scripts/install_rpfm.sh`) + Workshop upload flow.
- **[`tests/manual/wingman_scenarios.md`](tests/manual/wingman_scenarios.md)** — 10 manual test scenarios (S1–S10) with binary pass/fail and evidence paths.
- **[`.github/workflows/release.yml`](.github/workflows/release.yml)** — automated CI build + Steam Workshop publish workflow.

### Continuous Integration (GitHub Actions)

The repo includes a `.github/workflows/release.yml` workflow that automates building and publishing.

**What it does** (on `v*` tag push, or manual trigger):

1. **Smoke test** — runs `scripts/lupa_smoke.py` to verify all 9 Lua modules load together under stubbed TWW3 engine globals. Catches syntax errors before the pack build.
2. **RPFM install** — downloads Rusted PackFile Manager CLI v4.5.4 (Linux binary) and caches it under `tools/rpfm/` keyed on version.
3. **Pack build** — runs `scripts/build_pack.sh` to invoke RPFM CLI and produce `dist/!wingman.pack` (with PFH5 magic validation) plus copy `dist/!wingman.png`.
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

Wingman doesn't "give" your faction to the AI (the game has no such API — your faction stays under your control). Instead, it **automates your turn**: each time your turn starts, Wingman evaluates your rules, optionally dismisses popups, and ends your turn so the AI factions play through. You become a spectator with full vision. You can take back control anytime by toggling Wingman off.

## Known Limitations (v0.1 alpha)

- Scripted battle AI doesn't perfectly replicate a player's tactical decisions; it uses the game's standard AI plans (attack / defend / auto).
- No custom battle maps or new units.
- Tested on Immortal Empires only; Realm of Chaos and other campaigns should work but are not fully verified.

## License

[See LICENSE](./LICENSE)
