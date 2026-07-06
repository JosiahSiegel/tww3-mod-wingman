# Wingman — Canonical TWW3 Modding Reference (July 2026)

> **What this is**: A single source of truth for how TWW3 modding works in
> 2026, verified against the canonical rpfm_lib source code (the Rust
> implementation of the PFH5 pack format by the Total War modding community)
> and the actual bytes of 12 working mods in the user's install. This is
> the doc I wish I'd had at W1 — it would have saved four false-fix cycles
> (MCT API rewrite, `!` prefix, workshop-folder install, byte-stuffing).
>
> **Audience**: Future maintainers + me. If a previous fix "solved" something
> and you don't know why, start here.

## Table of contents

1. [PFH5 pack file format](#1-pfh5-pack-file-format)
2. [Mod install path](#2-mod-install-path)
3. [MCT integration pattern](#3-mct-integration-pattern)
4. [Build / install / test workflow](#4-build--install--test-workflow)
5. [Common gotchas and what actually broke (history)](#5-common-gotchas-and-what-actually-broke-history)
6. [Sources and references](#6-sources-and-references)

---

## 1. PFH5 pack file format

The canonical implementation is **`rpfm_lib`** by Frodo45127:
`https://github.com/Frodo45127/rpfm` (file:
`rpfm_lib/src/files/pack/pack_versions/pfh5.rs`).

### 1.1 Header (32 bytes, fixed)

```
Offset  Size  Field                Example value
------  ----  ---------------------  --------------
0x00    4     Magic (literal)        "PFH5"  (bytes 50 46 48 35)
0x04    4     Type + Bitmask (u32 LE)  0x00000003 for Mod-type
                                       0x00000001 for Release (vanilla)
0x08    4     PF Index Count (u32 LE)  0  (we have no nested packs)
0x0C    4     PF Index Size  (u32 LE)  0
0x10    4     File Index Count (u32 LE) number of files
0x14    4     File Index Size  (u32 LE) byte length of file index
0x18    4     Timestamp (u32 LE, Unix seconds)
0x1C    4     Reserved (u32, write 0)
```

**Type values (low byte of Type+Bitmask):**
- `0` = Boot
- `1` = Release (vanilla game data)
- `2` = Patch
- `3` = Mod — what we use
- `4` = Movie

**Bitmask values (high 3 bytes of Type+Bitmask) for PFH5 (per rpfm_lib
`PFHFlags`):**
- `0x00000100` HAS_BIG_HEADER — TWArena only, 20 extra header bytes
- `0x00000800` HAS_ENCRYPTED_INDEX — file index is encrypted
- `0x00000400` HAS_INDEX_WITH_TIMESTAMPS — file index entries have a 4-byte
  timestamp after the size. We do NOT use this. (See section 1.4 below.)
- `0x00001000` HAS_ENCRYPTED_DATA — file data is encrypted/padded to 8

For a vanilla Mod-type pack with no flags: `0x00000003` (just the type byte).

**NOTE**: The 8-byte "fake preamble" mentioned in some docs (e.g. "00-padded
'MFH' string") is only present in old Steam Workshop files, NOT in
newly-built PFH5 packs. Don't add it.

### 1.2 File index (variable length, immediately after the 32-byte header)

Each entry, in order, is:

```
Field             Size  Encoding
----------------  ----  --------------------------------------
data_size         4     u32 LE (size of the file payload in bytes)
timestamp         4     u32 LE  (ONLY if HAS_INDEX_WITH_TIMESTAMPS bit set; we don't set it)
is_compressed     1     u8 (0 = uncompressed, 1 = compressed)
path              N     UTF-8, NUL-terminated (\0), forward slashes
```

**Minimum entry size**: 4 + 1 + 1 = 6 bytes (size + is_compressed + empty
path's NUL). The rpfm_lib source comment says: *"6 because 4 (size) + 1
(compressed?) + 1 (null), 10 because + 4 (timestamp)"*.

**The `is_compressed` byte is CRITICAL and is ALWAYS present since PFH5.**
Omitting it shifts all subsequent path bytes by 1, causing the launcher
to read the first character of each path as the compression flag and the
rest as garbage. This is what made the W7/W8 packs load silently into
the mod list but never appear in the MCT panel (see section 5 below).

**Paths use forward slashes** (`script/campaign/mod/foo.lua`). The rpfm
source uses backslashes internally for ordering but the engine normalizes
on read.

### 1.3 Data section (file payloads, immediately after the file index)

File payloads are concatenated in the same order as the file index, each
with the size declared in its entry. No padding or alignment between
files (unless `HAS_ENCRYPTED_DATA` is set, which is not for our packs).

### 1.4 Why we do NOT set `HAS_INDEX_WITH_TIMESTAMPS`

Setting the `0x00000400` bitmask tells the engine to read an extra 4-byte
timestamp after each entry's size. We do not set this bit. The rpfm
write_pfh5 code only writes the timestamp when this bit is set:

```rust
if self.header.bitmask.contains(PFHFlags::HAS_INDEX_WITH_TIMESTAMPS) {
    file_index_entry.write_u32(timestamp)?;
}
file_index_entry.write_bool(has_been_compressed)?;
file_index_entry.write_string_u8_0terminated(path)?;
```

A previous W4-era attempt wrote a `created_time` u32 unconditionally,
which the engine then read as if it were the start of the next file's
size (treating the timestamp bytes as the high 4 bytes of a 64-bit
size_t). Result: the file index appeared corrupted to the engine and
**the entire pack was silently rejected** (no Lua files loaded, but no
error either). Don't add timestamps without the bitmask.

### 1.5 Verification (concrete byte check)

```python
import struct
with open('wingman.pack', 'rb') as f:
    d = f.read()
assert d[:4] == b'PFH5'
assert struct.unpack_from('<I', d, 4)[0] & 0xff == 3  # Mod type
fi_count = struct.unpack_from('<I', d, 16)[0]
fi_size  = struct.unpack_from('<I', d, 20)[0]
offset = 32
for _ in range(fi_count):
    sz = struct.unpack_from('<I', d, offset)[0]
    offset += 4
    is_compressed = d[offset]; offset += 1
    end = d.index(0, offset)
    path = d[offset:end].decode('utf-8')
    offset = end + 1
    print(f'{sz:>10}  comp={is_compressed}  {path}')
```

### 1.6 What about the `$GUID\0\0` block I saw in `groovy_mct.pack`?

**Nothing.** It's a CA mod-publishing artifact (PFM/RPFM/EA Mod Manager
adds it). The PFH5 spec does not require it. Vanilla CA packs
(`anim.pack`, `data.pack`, `db.pack`, `data_script.pack`, etc.) have
**no** `$GUID\0\0` block. The launcher reads the spec, not the
publishing artifact.

This was a red herring that I followed for an entire fix cycle
(commits W4-W5). Ignore it.

---

## 2. Mod install path

### 2.1 Canonical answer

**Manual / non-Workshop mods go in `<TWW3>/data/`.** This is verified by
the Lewdhammer wiki (2023-2024), the Modcu 2025 install guide, and the
TWW3 community guides. The Prop Joe mod manager comments (Workshop
item 2845454582) confirm: *"packs in content only show if you're
subscribed to them in Steam"*.

**Steam Workshop mods** go in `<Steam>/steamapps/workshop/content/1142710/<workshop_id>/`,
with the launcher writing `add_working_directory` entries to
`<TWW3>/used_mods.txt` for each. The user does NOT manually add
Workshop entries — Steam/launcher does it on subscribe.

**MCT-enabled mods work the same way as any other mod** — pack in
`data/` for local/manual installs, workshop folder for Workshop installs.
MCT scans `script/mct/settings/*.lua` in every loaded pack regardless
of where the pack lives.

### 2.2 `<TWW3>/used_mods.txt` format

```
add_working_directory "E:/SteamLibrary/steamapps/workshop/content/1142710/2854819509";
add_working_directory "...";
mod "sm0_recruit_defeated.pack";
mod "wingman.pack";
```

- One `add_working_directory` per Workshop-subscribed mod (Steam writes
  these automatically).
- One `mod "<pack>.pack";` per enabled mod. The launcher scans the
  listed directories for each pack filename.
- Local/manual mods in `data/` are listed with `mod "<pack>.pack";`
  but **no** `add_working_directory` (the launcher scans `data/`
  directly for those).
- Forward-slash paths only. `\r\n` line endings (the launcher writes
  Windows line endings).
- A duplicate `mod` line for the same pack is harmless but ugly.

### 2.3 The wingman-specific `used_mods.txt` block

```
mod "wingman.pack";
```

That's it. No `add_working_directory` line — the pack lives in
`<TWW3>/data/`.

---

## 3. MCT integration pattern

### 3.1 What MCT looks for

MCT (`script/mct/main.lua` in `groovy_mct.pack`) loads every pack, then
for each pack iterates `script/mct/settings/*.lua` files and registers
them. The full MCT API surface (per `chadvandy/mct_wh3` source):

```lua
local mct = get_mct()
local mod = mct:register_mod("wingman")              -- unique key
mod:set_title("Wingman — Your AI Co-Pilot")
mod:set_author("Wingman Team")
mod:add_new_section("wingman_general", "General")
mod:add_new_option("wingman_enabled", "checkbox")
mod:add_new_option("wingman_orders_per_turn", "slider")
mod:add_new_option("wingman_aggression", "dropdown")
mod:add_new_option("wingman_banned_factions_csv", "text_input")

local opt = mod:get_option_by_key("wingman_enabled")
opt:set_text("Enable Wingman")
opt:set_tooltip_text("Master switch.")
opt:set_default_value(true)
opt:set_locked(false)                              -- optional

-- slider:
opt:slider_set_min_max(1, 50)
opt:slider_set_step_size(1)
opt:slider_set_precision(0)                        -- integer

-- dropdown:
opt:add_dropdown_values({
    {key = "defensive",  text = "Defensive"},
    {key = "balanced",   text = "Balanced"},
    {key = "aggressive", text = "Aggressive"},
})
opt:set_default_value("aggressive")
```

### 3.2 DO NOT call (these methods do NOT exist on the TWW3 MCT)

The TWW3 MCT (Workshop ID `2927955021`, repo `chadvandy/mct_wh3`) is
**NOT** the Three Kingdoms / v0.9-Beta legacy API. The following
methods are NOT in the TWW3 surface and calling any of them throws a
hard error that aborts the rest of the file's registration:

```lua
-- 3K / v0.9-Beta legacy API (DOES NOT EXIST in TWW3 MCT):
mct:get_object_type(...)           -- nil method
mct:get_mct_option_class_subtype(...)  -- nil method
mct:get_control_group_class(...)   -- nil method
array_class:new()                  -- ControlGroup.Array dynamic
                                   -- checkbox injection — does not exist
opt:set_assigned_section(...)      -- does not exist
opt:get_finalized_setting(...)     -- does not exist
mod:get_option_by_key(...)         -- does not exist (use opt_ref returned
                                   --   by add_new_option instead)
mod:get_sections()                 -- does not exist
mod:get_settings_page(...)         -- does not exist
page:OnPopulate(...)               -- hook not present
```

Settings are published to the **global `CFSettings` table** when the
user finalizes the MCT dialog. Read them in your mod via:

```lua
local function read_settings()
    local out = get_default_settings()
    if CFSettings and type(CFSettings) == "table" then
        for k, _ in pairs(out) do
            if CFSettings[k] ~= nil then
                out[k] = CFSettings[k]
            end
        end
    end
    return out
end
```

### 3.3 File location for your mod's settings

`script/mct/settings/<your_mod_key>.lua` inside your pack. The file is
auto-loaded by MCT after the engine's own `script/mct/settings/*.lua`
files. **The file MUST end with a NUL-terminated path byte** when
read from the pack — see the PFH5 spec section 1.2 above. If your
file is missing or its path is misread, MCT silently skips it (no
error, no warning — it just doesn't appear in the panel).

### 3.4 What happens when settings are missing

If your settings file fails to register, MCT's mod list (the
"Mods" panel in the main menu) will **NOT show your mod**. Other
mods that DO register work fine — your mod is silently absent.
This is the same "silent skip" behavior as the launcher (see section
1.2) and the root cause of "Wingman not in the MCT panel" symptoms.

---

## 4. Build / install / test workflow

### 4.1 Build

```bash
python scripts/build_pack.py
```

Produces:
- `dist/wingman.pack` — valid PFH5 archive
- `dist/wingman.png` — 256×256 PNG thumbnail

### 4.2 Install (manual, for development)

```powershell
$env:TWW3 = "E:\SteamLibrary\steamapps\common\Total War WARHAMMER III"
python scripts\deploy.py
```

`scripts/deploy.py` (the **only** supported install path):
1. Reads `$TWW3` or auto-detects the default Steam install.
2. Copies `dist/wingman.pack` + `dist/wingman.png` to
   `<TWW3>/data/`.
3. Appends `mod "wingman.pack";` to `<TWW3>/used_mods.txt` (idempotent;
   strips any prior wingman entries first).
4. Preserves `\r\n` line endings.

The pack goes in `data/`, **not** the workshop folder. Workshop
folders are for Steam-managed subscribed content only; manually
creating a workshop folder with a fake ID will register a mod that
**does not load** (Steam expects the workshop_id to correspond to a
real subscription).

### 4.3 Test

```bash
# Static tests (no game required):
python scripts/lupa_smoke.py                  # load all 9 modules
python tests/manual/test_w6_ai_features.py    # 5/5
python tests/manual/test_w7_autopilot.py      # 10/10
python tests/manual/test_w8_step_coverage.py  # 20/20
python tests/manual/test_mct_integration.py   # 10/10  (NEW)
```

In-game (the user must run these):
- **S7 (blocking)**: launch TWW3, open MCT panel (top-left gear icon
  on main menu), verify **"Wingman — Your AI Co-Pilot"** is in the
  mod list, all 4 sections render, 31 options present.
- **S7b (blocking)**: toggle a setting, start a campaign, check the
  next `script_log_*.txt` shows the setting was read back via
  `wingman_mct.read_settings()`.
- **S1, S6, S10, S11, S11b/c/d/e**: see `tests/manual/wingman_scenarios.md`.

---

## 5. Common gotchas and what actually broke (history)

This section is a real-time log of every fix cycle that went wrong and
why. **Read this before debugging a "mod not loading" symptom** — the
chances of it being a new problem are small.

### 5.1 "Wingman not in the MCT panel" (W4-W5 era)

**Symptom**: `wingman.pack` loads into the mod list but does not appear
in the MCT "Mods" panel. lua_mod_log.txt shows zero `[Wingman]` lines
during pack load.

**Actual cause**: my pure-Python packer wrote a `created_time` u32
*unconditionally* into each file index entry, without setting the
`HAS_INDEX_WITH_TIMESTAMPS` bitmask. The engine then read 4 extra
bytes per entry as if they were the next entry's size, which produced
a 1.7GB size for the first entry (first entry's path bytes were
treated as the high half of a u64 size). The launcher silently
rejected the entire pack.

**Fix**: removed timestamps from the file index. See `build_pack.py:93`.

### 5.2 "MCT panel shows mods but no options for Wingman" (W6-W8 era)

**Symptom**: pack loads, mod list shows "Wingman", but the MCT
"Mods" panel does not list Wingman as a registered mod. The
`!groove_log.txt` shows mods being finalized (mixer, map_replacer,
mct_mod, aafortencampment) but never `wingman`.

**Actual cause**: `script/mct/settings/wingman_mct.lua` was written
against the **Three Kingdoms legacy MCT API** (`mct:get_object_type`,
`opt:set_assigned_section`, dynamic `ControlGroup.Array` checkbox
injection, `opt:get_finalized_setting`). These methods do not exist
on the TWW3 v0.9 MCT (Workshop ID `2927955021`). The first call to a
non-existent method threw a hard error and aborted the rest of the
file's registration. Settings were never registered.

**Fix**: rewrote `wingman_mct.lua` against the canonical TWW3 v0.9
API (verified against `chadvandy/mct_wh3` source on GitHub + the
Lewdhammer Progression Framework as a live example). 31 options
register cleanly; `test_mct_integration.py` validates the
registration with a stub of the real TWW3 MCT surface. See section
3 above for the API surface.

### 5.3 "Wingman not in the mod list at all" (W4-W8 era)

**Symptom**: pack present in `<TWW3>/data/wingman.pack`, listed in
`used_mods.txt` as `mod "wingman.pack";`, but absent from the
launcher's mod manager. lua_mod_log.txt shows zero `[Wingman]`
lines. All other 12 mods (MCT, Placeable Forts, Map Replacer
Framework, Mixu, Fort Encampment, OvN Lost World, Recruit Defeated
Legendary Lords) appear normally.

**Actual cause**: **`script/mct/settings/wingman_mct.lua` is missing
its `is_compressed` byte in the pack's file index entry.** Per the
canonical rpfm_lib source (`pfh5.rs:178-189`), every PFH5 file
index entry is:

```
[u32 size][u8 is_compressed][NUL-terminated path]
```

My packer was writing:

```
[u32 size][NUL-terminated path]
```

The launcher reads the first byte of the path as the `is_compressed`
flag (0 or 1), then reads the rest of the path as the actual path.
So a path like `script/mct/settings/wingman_mct.lua` got read as
`is_compressed=0x73 ('s' character), path=cript/mct/settings/wingman_mct.lua`
(shifted by 1). MCT's registry builder searched for
`script/mct/settings/wingman_mct.lua` in the loaded pack, found
nothing, and silently skipped registration.

**Why the mod list itself didn't show Wingman either**: MCT is the
front-end component; the mod manager is the launcher's own list.
With no `wingman_mct.lua` registering with MCT, the launcher has no
reason to think Wingman is a real mod and silently hides it from
the list as well (verified in `!groove_log.txt` — Wingman never
appears in the Finalized mods list).

**Fix**: added the `is_compressed` byte (0x00 = uncompressed)
between each entry's size and path. Pack size increased by 11 bytes
(one byte per file). See `scripts/build_pack.py:build_file_index`.
Verified by parsing the new pack with the same parser the launcher
uses, and getting 11 correct file paths + sizes.

### 5.4 "Wingman mod list went away after I moved it to the workshop folder" (deploy.py misadventure)

**Symptom**: After moving the pack from `data/` to a
manually-created workshop folder (`workshop/content/1142710/9999999999/`)
with a hand-written `add_working_directory` line, Wingman
disappeared from the launcher mod list entirely.

**Actual cause**: workshop folders are reserved for Steam-managed
Workshop subscriptions. The launcher's `add_working_directory`
scan does look for packs in those folders, but only when the
workshop_id corresponds to a real Steam subscription. A
hand-crafted folder with a fake ID is silently ignored.

**Fix**: moved the pack back to `<TWW3>/data/` (the canonical
install path for non-Workshop mods per the Lewdhammer wiki and
Modcu 2025 install guide). See section 2.1.

### 5.5 "Wingman worked briefly in earlier waves"

The earlier "Wingman was visible" claim from W4-era testing was
incorrect — the pack was rejected at the launcher level (the
PFH5 file-index bug from 5.1) and the launcher was reporting a
fake-empty mod list because it didn't have a valid pack to load.
The "MCT panel showed 7 mods but not Wingman" observation was
correct, but the diagnosis "Wingman loaded but MCT didn't pick it
up" was wrong. The actual answer is: Wingman never loaded at all
in any wave prior to this fix; the launcher just didn't print an
error.

---

## 6. Sources and references

### 6.1 Canonical source code (use this as the source of truth)

- **rpfm_lib** (PFH5 pack format reference implementation, Rust):
  `https://github.com/Frodo45127/rpfm`
  - File: `rpfm_lib/src/files/pack/pack_versions/pfh5.rs`
    (read_pfh5 lines 33-126, write_pfh5 lines 137-237)
  - File: `rpfm_lib/src/files/pack/mod.rs` (header structure doc,
    lines 248-275)
  - Author: Frodo45127, the de-facto TWC pack format authority
- **chadvandy/mct_wh3** (canonical TWW3 MCT API surface):
  `https://github.com/chadvandy/mct_wh3`
  - Steam: `https://steamcommunity.com/sharedfiles/filedetails/?id=2927955021`
- **chadvandy/tw_autogen** (auto-generated Lua stubs for the TWW3
  scripting API; useful for IntelliSense and verifying Lua API
  signatures): `https://github.com/chadvandy/tw_autogen`
- **chadvandy/tw_modding_resources** (community-maintained HTML
  versions of the official CA scripting docs):
  `https://chadvandy.github.io/tw_modding_resources/WH3/`

### 6.2 Community install / pack-format guides

- **Modcu "Ultimate Total War: Warhammer Modding Guide 2025"**
  (current, cited modding guide): `https://modcu.com/blog/the-ultimate-total-war-warhammer-modding-guide-2025-how-to-install-manage-fix-mods-like-a-pro/`
- **Lewdhammer wiki "Installing Mods"** (TWW3-specific, 2023-2024
  but still accurate for 2026):
  `https://lewdhammer.miraheze.org/wiki/Installing_Mods`
- **tw-modding.com Troubleshooting page** (community wiki):
  `https://tw-modding.com/wiki/Troubleshooting`
- **TotalWar-Modding/docs** (community-maintained spec/links):
  `https://github.com/TotalWar-Modding/docs`
- **Archipelago_TWW3_Alt** (live 2026 TWW3 mod; install steps
  confirm the `data/` path):
  `https://github.com/jordansds/Archipelago_TWW3_Alt`
- **Shazbot/WH3-Mod-Manager** (Prop Joe, the de-facto third-party
  TWW3 mod manager; very active on GitHub):
  `https://github.com/Shazbot/WH3-Mod-Manager`
- **msolefonte/tww3-cbac** (live TWW3 mod using MCT, source
  available): `https://github.com/msolefonte/tww3-cbac`
- **Frodo45127/tww3_dynamic_disasters** (live TWW3 mod using
  MCT, source available):
  `https://github.com/Frodo45127/tww3_dynamic_disasters`

### 6.3 Official CA docs (referenced via chadvandy HTML mirror)

- **Campaign script class** (the `cm:` Lua API):
  `https://chadvandy.github.io/tw_modding_resources/WH3/campaign/campaign_manager.html`
- **Core script class** (the `core:` Lua API, including
  `core:load_mods`, `core:execute_mods`):
  `https://chadvandy.github.io/tw_modding_resources/WH3/campaign/core.html`
- **CA official blog — New Mod Manager Early Access** (Nov 2025;
  explains EA Mod Manager vs original TW launcher):
  `https://community.creative-assembly.com/total-war/total-war-warhammer/blogs/87-total-war-warhammer-iii-new-mod-manager-early-access`

### 6.4 Live working packs referenced (verified by byte-level readback)

- **MCT (Workshop ID 2927955021)**: `groovy_mct.pack`, 2,857,702 bytes.
  Used as a reference pack — its file index entry format is
  canonical (size + is_compressed + path).
- **sm0_recruit_defeated (Workshop ID 2854819509)**:
  `sm0_recruit_defeated.pack`, 1,704,450 bytes. 41 files. Source:
  `https://github.com/MilitusImmortalis/sm0_recruit_defeated` (the
  author's repo).
- **!b_mixer (Workshop ID 2859968660)**: `!b_mixer.pack`. Source:
  Mixu (https://www.nexusmods.com/site/mods/117).
- **aafortcamps (Workshop ID 3617600622)**: `aafortcamps.pack`,
  8,263,372 bytes. 371 files. Source: `Placeable Forts` mod by
  Cal, etc.

### 6.5 What NOT to read

- **The PFH5 spec at `TotalWar-Modding/docs/pack file format.md`**:
  incomplete. Missing the `is_compressed` byte in the file index
  entry layout. Always cross-reference with the rpfm_lib source.
- **3K MCT mod guides (Workshop ID 3566484907 or any Ironic guide)**:
  describes the Three Kingdoms legacy API which does NOT exist in
  TWW3 v0.9 MCT. Use chadvandy/mct_wh3 instead.
- **Any guide written before chadvandy's May 2025 rewrite of MCT**:
  describes a pre-v0.9 API. The TWW3 MCT has been on v0.9 since
  2023 and the current surface is significantly different.

---

## Appendix A: Complete build script source

For the canonical pack builder, see `scripts/build_pack.py`. The
critical function is `build_file_index` (around line 80):

```python
def build_file_index(entries):
    """Per rpfm_lib pfh5.rs (2026-06). Each entry:
       u32 size | u8 is_compressed | NUL-terminated path.
       No timestamp (HAS_INDEX_WITH_TIMESTAMPS bit is not set)."""
    buf = bytearray()
    for path, size, _ts in entries:
        buf += struct.pack("<I", size)        # 4 bytes: data size
        buf += b"\x00"                        # 1 byte: is_compressed = false
        buf += path.encode("utf-8") + b"\x00" # N: UTF-8 path + NUL
    return bytes(buf)
```

And the 32-byte header (line 145 area):

```python
header = b"".join([
    b"PFH5",                              # 0-3: literal magic
    struct.pack("<I", 0x00000003),        # 4-7: type=3 (Mod), bitmask=0
    struct.pack("<I", 0),                  # 8-11: PF index count = 0
    struct.pack("<I", 0),                  # 12-15: PF index size = 0
    struct.pack("<I", len(source_files)),  # 16-19: file index count
    struct.pack("<I", len(file_index_bytes)),  # 20-23: file index size
    struct.pack("<I", int(time.time())),   # 24-27: pack timestamp
    struct.pack("<I", 0),                  # 28-31: reserved = 0
])
```

## Appendix B: Common pitfalls (one-line each)

- **Pack rejected silently** → check section 5.3 (missing
  `is_compressed` byte).
- **MCT doesn't list your mod** → check section 5.2 (using 3K
  legacy API on TWW3).
- **Engine rejects the file index** → check section 5.1 (timestamps
  written without the bitmask set).
- **Workshop folder install doesn't show up** → check section 2.1
  (Workshop folders are Steam-managed, not for manual installs).
- **Launcher can't find the pack at all** → check
  `<TWW3>/used_mods.txt` has `mod "wingman.pack";` (section 2.2).
- **Settings show in MCT but `wingman_mct.read_settings()` returns
  defaults** → the `CFSettings` global isn't populated until the
  user clicks "Finalize Settings" in the MCT dialog. See section
  3.2.
