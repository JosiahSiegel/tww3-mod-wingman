# Building `!wingman.pack`

The repo ships a **pure-Python PFH5 pack builder** at `scripts/build_pack.py` — zero external dependencies, no GUI tools, no large binary downloads. It reads the spec at <https://github.com/TotalWar-Modding/docs/blob/master/pack%20file%20format.md> and writes a valid Mod-type `.pack` archive.

The mod is script-only (Lua + a `.loc.tsv`); no DB tables, no animations, no models to convert. The Python packer handles the entire pipeline.

## Prerequisites

- **Python 3.6+** (already on PATH — pre-installed on GitHub Actions ubuntu-latest runners)
- A clean install of Total War: WARHAMMER III (Steam)

## Build Steps

### 1. Run the pack builder

From the repo root:

```bash
python scripts/build_pack.py
```

This produces:

- `dist/!wingman.pack` — PFH5 archive containing every file under `script/` and `text/`
- `dist/!wingman.png` — copy of the Workshop thumbnail (the launcher reads both as siblings)

The script:

1. Walks `script/` and `text/` recursively
2. Writes a Mod-type PFH5 header (32 bytes: magic `PFH5`, type `0x03`, file index count + size, timestamp)
3. Writes the file index (size + timestamp + null-terminated path per file)
4. Concatenates the raw file bytes in the same order
5. Validates the output (magic bytes + minimum size)

### 2. Install Locally for Testing

```powershell
# PowerShell
Copy-Item "dist\!wingman.pack" "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.pack" -Force
Copy-Item "dist\!wingman.png"  "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.png"  -Force
```

Or on bash:

```bash
cp dist/'!wingman.pack' dist/'!wingman.png' \
   "/c/Program Files (x86)/Steam/steamapps/common/Total War WARHAMMER III/data/"
```

Enable script logging (recommended for debugging):

```powershell
New-Item -ItemType File -Path "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\script\enable_console_logging" -Force
```

Then launch the original Total War launcher (NOT the EA Mod Manager) → Mod Manager → enable MCT + Wingman → Play.

### 3. Verify the pack is well-formed (optional)

The Python script already validates this when it runs, but if you want to spot-check the binary:

```bash
python -c "
import struct
with open('dist/!wingman.pack', 'rb') as f:
    magic = f.read(4)
    type_bm, _, _, fn_n, fn_sz, ts, _ = struct.unpack('<7I', f.read(28))
    print(f'Magic: {magic}, Type: {type_bm & 0xF}, Files: {fn_n}')
    assert magic == b'PFH5' and (type_bm & 0xF) == 3
    print('Header valid: OK')
"
```

Expected output:

```
Magic: b'PFH5', Type: 3, Files: 10
Header valid: OK
```

> **For the full end-to-end local testing guide** (iterative dev loop, evidence capture, common pitfalls, lupa pre-launch smoke test), see [`tests/manual/LOCAL_TESTING.md`](../tests/manual/LOCAL_TESTING.md).

### 4. Upload to Workshop

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
3. Re-run `python scripts/build_pack.py` (refreshes the pack from repo).
4. Copy the new `dist/!wingman.pack` + `!wingman.png` into `<TWW3>/data/`.
5. Test the change in-game.
6. Original launcher → Mod Manager → right-click Wingman → **Update**.
7. Add **change notes** describing what changed.

## Common Pitfalls

| Problem | Fix |
|---|---|
| Thumbnail fails to upload | Must be PNG (not JPG). Must be < 1 MB exactly. Filename must match pack base. |
| `Patch X.Y: New table Z required` error | Pure-Python packer has no schema cache to invalidate. If you see this, it's because the in-game launcher is hitting a TWW3 patch-time validation — unrelated to this mod. |
| MCT panel missing | Verify `script/mct/settings/wingman_mct.lua` is in the pack — should be at `script/mct/settings/wingman_mct.lua` in the File Index. |
| Lua errors in log | Check `script_log_*.txt` for the first error line; the call stack points at the file. |
| Upload spins forever | Restart Steam and try again. |
| Pack file doesn't load | Verify PFH5 magic and Mod type using the snippet in Step 3 above. |

## Automated Build (GitHub Actions)

For contributors who don't want to build locally, the repo ships `.github/workflows/release.yml` that builds the pack on every `v*` tag push or PR:

- Push a SemVer tag (e.g., `git tag v0.2.0 && git push origin v0.2.0`).
- The workflow runs the lupa smoke test → builds the pack → uploads it as a workflow artifact → creates a draft GitHub Release → (gated on reviewer approval) publishes to Steam Workshop.
- PRs against `main` also run the build — the contributor can download the `.pack` from the run's artifacts row.

The workflow is **pure-Python** (no RPFM, no apt installs, no Qt5 libs) — installs in seconds on a fresh runner.

To configure Steam Workshop publishing in CI:

1. **First-time publish must be manual** — open the game, original TW launcher → Mod Manager → right-click Wingman → Upload → accept EULA → publish as Hidden. Copy the numeric Workshop item ID from the URL.
2. **In GitHub repo settings**:
   - Settings → Secrets and variables → **Variables** → Actions → New variable `WORKSHOP_ITEM_ID` = `<your item ID>`
   - Settings → Secrets and variables → **Secrets** → Actions → New secret:
     - `STEAM_USERNAME` (recommend a dedicated builder account)
     - `STEAM_PASSWORD`
     - `STEAM_TFASEED` (Steam Guard shared_secret, not TOTP — see [Weilbyte's README](https://github.com/Weilbyte/steam-workshop-upload) for extraction)
   - Settings → **Environments** → New environment `steam-workshop` → Required reviewers: add at least 1 maintainer → Deployment branches: limit to `main`.
3. **Trigger**: `git tag v0.X.Y && git push origin v0.X.Y` — workflow runs, reviewer approves the `steam-workshop` environment, publish proceeds.

**TWW3 SteamCMD caveat**: TWW3's Workshop is known to sometimes reject SteamCMD-uploaded items with `K_EResultFail` (community reports). If CI publish fails:
- The draft GitHub Release contains the working `.pack` file (no work lost).
- Fall back to manual upload via the in-game launcher.
- File a follow-up issue if it's reproducible.

**Verification without publishing**: run `workflow_dispatch` with the default `dry_run: true` to skip the publish job — useful for testing the build pipeline on PRs.