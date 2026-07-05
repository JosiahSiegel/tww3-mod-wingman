# Steam Workshop Publishing Checklist

## Required Artifacts

- [ ] `!wingman.pack` (built via RPFM MyMod → Import → Pack)
- [ ] `!wingman.png` (thumbnail, **256×256 PNG, under 1 MB strict**, filename must match pack base)
- [ ] README content (used for description)
- [ ] CHANGELOG entry

## Workshop Item Settings

- **Title**: Wingman — Your AI Co-Pilot for TWW3
- **Description**: First paragraph of README + "## Requirements" + "## Safety" sections
- **Tags**: `Campaign`, `UI`
- **Required Items**: MCT (Workshop ID `2927955021`)
- **Visibility**: Hidden first, switch to Public only after smoke testing
- **Preview Image**: `!wingman.png`

## Upload Steps

1. Build pack locally: `RPFM → MyMod → Import → PackFile → Install`
2. Place `!wingman.png` next to `!wingman.pack` in TWW3 `data\` folder
3. Launch **original Total War launcher** (NOT the new EA Mod Manager — it does not support uploads yet)
4. Open **Mod Manager**
5. Right-click the Wingman mod → **Upload**
6. Accept EULA pop-up on first upload
7. Fill in title, description, tags, required items
8. Publish as **Hidden** for initial smoke verification
9. Subscribe from a clean Steam profile, run scenarios S1–S10 from `tests/manual/wingman_scenarios.md`
10. Switch to **Public** only when S7 (Workshop install) passes cleanly

## Update Steps

1. Keep the `.pack` filename **identical** — Steam Workshop IDs are immutable
2. Bump version in `CHANGELOG.md`
3. Rebuild + reinstall locally
4. Original launcher → Mod Manager → right-click mod → **Update**
5. Add **change notes** describing what changed

## Common Upload Errors

| Error | Fix |
|---|---|
| Thumbnail won't load | PNG only (not JPG), filename matches pack, **< 1 MB strict** |
| Upload spins forever | Restart Steam, retry |
| Mod not appearing in Mod Manager | Check `data/` for `.pack` file, verify filename has no uppercase, restart launcher |
| "Patch X.Y: New table Z required" | Pack references an outdated schema; rebuild after game patch |
