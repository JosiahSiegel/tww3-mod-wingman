# Building `!wingman.pack`

## Prerequisites

- [Rusted PackFile Manager (RPFM)](https://github.com/Frodo45127/rpfm/releases) v5.0.5 or newer
- A clean install of Total War: WARHAMMER III (Steam)
- (Optional but recommended) Total War: WARHAMMER III - Assembly Kit BETA (Steam Tools appid 1880380) — for dependency cache generation

## Build Steps

### 1. Configure RPFM

1. Launch RPFM.
2. `PackFile → Preferences → Settings`:
   - **Game Path**: `C:\Program Files (x86)\Steam\steamapps\common\Total War Warhammer III`
   - **MyMod folder**: `D:\repos\tww3-mod-wingman` (or wherever this repo is)
   - **Selected Game**: Warhammer 3
3. `Special Stuff → Warhammer 3 → Generate Dependencies Cache` (one-time, ~2 minutes)

### 2. Create the Pack

1. `MyMod → New MyMod` → name `!wingman` → Save.
2. RPFM creates `!wingman.pack` and links it to your repo folder.
3. `MyMod → Import` — RPFM picks up all files under `script/` and `text/` in the repo.
4. Verify the import log shows all 10 files imported (7 campaign + 1 battle + 1 MCT + 1 loc).

### 3. Set Pack Metadata (PackFile → Pack File Properties)

- **Title**: `Wingman — Your AI Co-Pilot`
- **Author**: (your Steam display name)
- **Version**: `0.1.0-alpha`
- **Description**: see `WORKSHOP_DESCRIPTION.md`
- **Preview Image**: select `assets/workshop/!wingman.png`

### 4. Install Locally for Testing

1. `PackFile → Install` — copies `!wingman.pack` to `<TWW3>/data/`.
2. Copy `assets/workshop/!wingman.png` to `<TWW3>/data/!wingman.png` (filename MUST match).
3. Enable script logging: create empty file `<TWW3>/data/script/enable_console_logging`.
4. Launch original TW launcher → Mod Manager → enable MCT + Wingman → Play.

> **For the full end-to-end local testing guide** (RPFM config, iterative dev loop, evidence capture, common pitfalls, lupa pre-launch smoke test), see [`tests/manual/LOCAL_TESTING.md`](../tests/manual/LOCAL_TESTING.md).

### 5. Upload to Workshop

1. Verify the pack works in-game (run `tests/manual/wingman_scenarios.md` S1 + S7).
2. In Mod Manager, right-click Wingman → **Upload**.
3. Accept EULA pop-up.
4. Workshop item fields:
   - Title: `Wingman — Your AI Co-Pilot`
   - Description: contents of `WORKSHOP_DESCRIPTION.md`
   - Tags: `Campaign`, `UI`
   - Required items: add MCT (Workshop ID `2927955021`)
   - Preview: `!wingman.png` (already embedded)
5. Publish as **Hidden** for initial smoke verification.
6. Subscribe from a clean Steam profile and run S7 from the scenarios doc.
7. Switch to **Public** only when S7 passes.

## Updating an Existing Workshop Item

1. Make your code changes.
2. Bump `CHANGELOG.md` version.
3. `MyMod → Import` (refreshes the pack from repo).
4. `PackFile → Install` (re-deploys to local `data/`).
5. Test the change in-game.
6. Original launcher → Mod Manager → right-click Wingman → **Update**.
7. Add **change notes** describing what changed.

## Common Pitfalls

| Problem | Fix |
|---|---|
| Thumbnail fails to upload | Must be PNG (not JPG). Must be < 1 MB exactly. Filename must match pack base. |
| `Patch X.Y: New table Z required` error | You haven't run `Generate Dependencies Cache` since the last TWW3 patch. |
| MCT panel missing | Ensure `script/mct/settings/wingman_mct.lua` is in the pack — check via RPFM's MyMod view. |
| Lua errors in log | Check `script_log_*.txt` for the first error line; the call stack points at the file. |
| Upload spins forever | Restart Steam and try again. |