# Steam Workshop Publishing Checklist

## Required Artifacts

- `wingman.pack` (built via `python scripts/build_pack.py` — see `pack/BUILD_INSTRUCTIONS.md`)
- `wingman.png` (thumbnail, **256×256 PNG, under 1 MB strict**, filename must match pack base)

## Workshop Item Settings

- **Title**: Wingman — Your AI Co-Pilot for TWW3
- **Description**: contents of `WORKSHOP_DESCRIPTION.md`
- **Tags**: `Campaign`, `UI`
- **Required Items**: MCT (Workshop ID `2927955021`)
- **Visibility**: Hidden first, switch to Public only after smoke testing
- **Preview Image**: `wingman.png`

## Upload Steps

1. Build pack: `python scripts/build_pack.py` (or follow `pack/BUILD_INSTRUCTIONS.md`).
2. Place `dist\wingman.pack` and `dist\wingman.png` in TWW3 `data\` folder.
3. Launch **original Total War launcher** (NOT EA Mod Manager).
4. Open **Mod Manager**.
5. Right-click Wingman → **Upload**.
6. Accept EULA on first upload.
7. Fill in title, description, tags, required items.
8. Publish as **Hidden** for smoke verification.
9. Subscribe from a clean Steam profile, run **S7** (Workshop install) from `tests/manual/wingman_scenarios.md`.
10. Switch to **Public** only when S7 passes cleanly.

## Update Steps

1. Keep the `.pack` filename **identical** — Steam Workshop IDs are immutable.
2. Bump version in `CHANGELOG.md`.
3. Rebuild + reinstall locally.
4. Original launcher → Mod Manager → right-click mod → **Update**.
5. Add **change notes** describing what changed.

## Common Upload Errors

| Error | Fix |
|---|---|
| Thumbnail won't load | PNG only, filename matches pack, < 1 MB strict |
| Upload spins forever | Restart Steam, retry |
| Mod not appearing | Check `data/` for `.pack`, verify filename (no uppercase), restart launcher |
| "Patch X.Y: New table Z required" | Out-of-date schema; rebuild after game patch |

## CI vs Manual Publishing

`.github/workflows/release.yml` automates Steam Workshop publish on tag push. Caveats:

- **First publish must be manual** — SteamCMD cannot accept the EULA dialog. Upload via the original TW launcher once; subsequent updates can flow through CI.
- **TWW3 has known `K_EResultFail` issues** with SteamCMD uploads. The Mod Manager may reject items uploaded outside CA's launcher.
- **If CI publish fails**, the durable `.pack` artifact is in the draft GitHub Release — re-upload via the in-game launcher.
