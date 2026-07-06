# Building `!wingman.pack`

The repo ships a **pure-Python PFH5 pack builder** at `scripts/build_pack.py` — zero external dependencies, no GUI tools, no large binary downloads. It reads the spec at <https://github.com/TotalWar-Modding/docs/blob/master/pack%20file%20format.md> and writes a valid Mod-type `.pack` archive.

The mod is script-only (Lua + a `.loc.tsv`); no DB tables, no animations, no models to convert.

## Prerequisites

- **Python 3.6+**
- A clean install of Total War: WARHAMMER III (Steam)

## Steps

### 1. Build

```bash
python scripts/build_pack.py
```

Produces:

- `dist/!wingman.pack` — PFH5 archive containing every file under `script/` and `text/`
- `dist/!wingman.png` — copy of the Workshop thumbnail

The script validates the PFH5 magic on the output.

### 2. Install Locally

**PowerShell**:

```powershell
Copy-Item "dist\!wingman.pack" "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.pack" -Force
Copy-Item "dist\!wingman.png"  "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\!wingman.png"  -Force
```

**Bash**:

```bash
cp dist/'!wingman.pack' dist/'!wingman.png' \
   "/c/Program Files (x86)/Steam/steamapps/common/Total War WARHAMMER III/data/"
```

### 3. Enable Script Logging (one-time)

```powershell
New-Item -ItemType File -Path "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\script\enable_console_logging" -Force
```

That empty file (no extension) makes `out("[Wingman] ...")` lines visible in `script_log_*.txt`.

### 4. Launch and Verify

1. Launch via the **original Total War launcher** (NOT EA Mod Manager).
2. Mod Manager → tick **MCT** (first) + **Wingman** → **Play**.
3. Open `<TWW3>/script_log_*.txt`, search for `[Wingman] init`. You should see `[Wingman] init complete. mode=disabled, campaign_handover=false, battle_handover=false`.

### 5. Spot-check the pack (optional)

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

### 6. Upload to Workshop

1. Verify in-game (run S1 + S7 from `tests/manual/wingman_scenarios.md`).
2. In Mod Manager, right-click Wingman → **Upload**.
3. Accept EULA.
4. Workshop item fields:
   - **Title**: `Wingman — Your AI Co-Pilot`
   - **Description**: contents of `WORKSHOP_DESCRIPTION.md`
   - **Tags**: `Campaign`, `UI`
   - **Required items**: MCT (Workshop ID `2927955021`)
   - **Preview**: `!wingman.png` (already embedded)
5. Publish as **Hidden** for smoke verification.
6. Subscribe from a clean Steam profile and run S7 from the scenarios doc.
7. Switch to **Public** only when S7 passes.

## Updating an Existing Workshop Item

1. Make your code changes.
2. Bump `CHANGELOG.md` version.
3. Re-run `python scripts/build_pack.py`.
4. Copy the new `dist/!wingman.pack` + `!wingman.png` into `<TWW3>/data/`.
5. Test in-game.
6. Original launcher → Mod Manager → right-click Wingman → **Update**.
7. Add **change notes** describing what changed.

## Common Pitfalls

| Problem | Fix |
|---|---|
| Thumbnail fails to upload | Must be PNG, < 1 MB, filename matches pack base |
| `Patch X.Y: New table Z required` | Pure-Python packer has no schema cache. If you see this, it's an in-game launcher patch-time validation — unrelated to this mod. |
| MCT panel missing | Verify `script/mct/settings/wingman_mct.lua` is in the pack |
| Lua errors in log | Check `script_log_*.txt` for the first error line; the call stack points at the file |
| Upload spins forever | Restart Steam, retry |

## CI / GitHub Actions

`.github/workflows/release.yml` automates build + Workshop publish on `v*` tag push:

1. Runs lupa smoke test.
2. Builds the pack.
3. Uploads as a 90-day workflow artifact.
4. Creates a DRAFT GitHub Release.
5. Publishes to Steam Workshop (gated by the `steam-workshop` reviewer environment).

PRs against `main` run the build only — download the `.pack` from the run's artifacts to test locally.

### Configure CI Publishing

1. **First publish must be manual** — open the game, original TW launcher → Mod Manager → right-click Wingman → Upload → accept EULA → publish as Hidden. Copy the numeric Workshop item ID from the URL.
2. **GitHub repo settings**:
   - Settings → Variables → Actions → `WORKSHOP_ITEM_ID` = `<your item ID>`.
   - Settings → Secrets → Actions: `STEAM_USERNAME`, `STEAM_PASSWORD`, `STEAM_TFASEED` (Steam Guard shared_secret, not TOTP).
   - Settings → Environments → `steam-workshop` → required reviewers (≥ 1) → deployment branches: `main`.
3. **Trigger**: `git tag v0.X.Y && git push origin v0.X.Y`. Reviewer approves the environment; publish proceeds.

**TWW3 SteamCMD caveat**: TWW3's Workshop sometimes rejects SteamCMD-uploaded items with `K_EResultFail`. If CI publish fails:
- The draft GitHub Release contains the working `.pack`.
- Fall back to manual upload via the in-game launcher.

**Verification without publishing**: run `workflow_dispatch` with the default `dry_run: true` to skip the publish job — useful for testing the build pipeline on PRs.
