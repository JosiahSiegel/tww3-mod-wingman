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
