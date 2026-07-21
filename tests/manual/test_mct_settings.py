#!/usr/bin/env python3
"""MCT settings tests.

Exercises the Mod Configuration Tool module (`wingman_mct.lua`):
- Default settings are non-empty and well-typed
- Dropdown options are strings
- Slider ranges are sane (min <= default <= max)
- CSV parsing is correct
- The constants in `wingman_battle_init.lua` stay in sync with
  `wingman_constants.lua` (the MODE_*/BIAS_* string values)

Also catches the bug class:
- Missing required keys
- Type mismatches (e.g. slider returns string when number expected)
- Out-of-range sliders
- CSV that doesn't round-trip

Run from the repo root:
    python3 tests/manual/test_mct_settings.py
"""
from __future__ import annotations

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _run() -> int:
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    import lupa_smoke  # type: ignore
    from lupa import LuaRuntime  # type: ignore

    lua = LuaRuntime(unpack_returned_tuples=True)
    # Use a custom mct that returns a table with a register_mod method
    # so the module loads fully and we can inspect DEFAULTS.
    lua.execute('''
        _G.mct = {
            register_mod = function(self, name)
                return setmetatable({}, {
                    __newindex = function(t, k, v) rawset(t, k, v) end,
                    __index    = function(t, k) return rawget(t, k) end,
                })
            end,
        }
        _G.get_mct = function() return _G.mct end
    ''')
    lua.execute(lupa_smoke.ENGINE_STUBS)
    # Load the MCT module
    mct_path = os.path.join(REPO_ROOT, "script", "mct", "settings", "wingman_mct.lua").replace(os.sep, "/")
    result = lua.eval(f"pcall(dofile, [=[{mct_path}]=])")
    if not lupa_smoke._pcall_ok(result):
        err = result[1] if isinstance(result, tuple) and len(result) >= 2 else "?"
        print(f"FAIL: wingman_mct.lua didn't load: {err}")
        return 1
    print("OK: wingman_mct.lua loaded under stub mct handle")

    # ---- 1. wingman_mct is the public API surface ----
    print("\n[1] wingman_mct is the public API surface")
    for name in ["is_available", "get_default_settings", "read_settings",
                "validate_settings", "rebuild_ban_list", "get_banned_factions",
                "get_all_options"]:
        t = lua.eval(f"type(wingman_mct.{name})")
        if t == "nil":
            print(f"  FAIL: wingman_mct.{name} is nil (expected a function)")
            return 1
    print("  OK: all expected public functions present")

    # ---- 2. Default settings are well-formed ----
    print("\n[2] Default settings are well-formed (no nils, all expected keys)")
    defaults = lua.eval("wingman_mct.get_default_settings()")
    defaults_dict = dict(defaults.items()) if hasattr(defaults, "items") else {}
    expected_keys = [
        "wingman_enabled", "wingman_debug_logging", "wingman_safety_level",
        "wingman_campaign_handover_enabled", "wingman_auto_end_turn_delay_seconds",
        "wingman_periodic_break_interval", "wingman_break_on_diplomacy_panel",
        "wingman_break_on_war_declaration", "wingman_break_on_pending_battle",
        "wingman_battle_handover_enabled", "wingman_battle_control_mode",
        "wingman_battle_plan_bias", "wingman_autoresolve_threshold",
        "wingman_auto_dismiss_battle_results",
        "wingman_turn_cap_enabled", "wingman_turn_cap_value", "wingman_turn_cap_outcome",
        "wingman_custom_win_enabled", "wingman_required_settlements_csv",
        "wingman_required_defeated_factions_csv",
        "wingman_faction_restrictions_enabled", "wingman_restriction_violation_action",
        "wingman_ai_enabled", "wingman_ai_aggression", "wingman_ai_orders_per_turn",
        "wingman_ai_attack_adjacent", "wingman_ai_diplomacy_enabled",
        "wingman_ai_diplomacy_per_turn", "wingman_ai_research_enabled",
        "wingman_ai_rituals_enabled", "wingman_banned_factions_csv",
    ]
    missing = [k for k in expected_keys if k not in defaults_dict]
    if missing:
        print(f"  FAIL: missing keys in defaults: {missing}")
        return 1
    print(f"  OK: all {len(expected_keys)} expected keys present in defaults")

    # ---- 3. Slider ranges are sane ----
    print("\n[3] Slider defaults are within their declared ranges")
    # Read SLIDER_RANGES from the module (via a Lua introspection helper)
    slider_ranges = lua.eval('''
        (function()
            -- wingman_mct's SLIDER_RANGES is local; we reconstruct from
            -- a known min/max test. To verify, just check that a few
            -- well-known defaults are within sane absolute bounds.
            local d = wingman_mct.get_default_settings()
            local checks = {
                wingman_auto_end_turn_delay_seconds = {lo = 0, hi = 10},
                wingman_periodic_break_interval     = {lo = 0, hi = 100},
                wingman_autoresolve_threshold       = {lo = 0, hi = 100},
                wingman_turn_cap_value              = {lo = 1, hi = 500},
                wingman_ai_orders_per_turn          = {lo = 1, hi = 50},
                wingman_ai_diplomacy_per_turn       = {lo = 0, hi = 10},
            }
            local bad = {}
            for k, b in pairs(checks) do
                local v = d[k]
                if type(v) ~= "number" or v < b.lo or v > b.hi then
                    bad[#bad+1] = string.format("%s=%s (expected %d..%d)", k, tostring(v), b.lo, b.hi)
                end
            end
            return bad
        end)()
    ''')
    bad_list = list(slider_ranges) if slider_ranges else []
    if bad_list:
        for b in bad_list:
            print(f"  FAIL: {b}")
        return 1
    print("  OK: all slider defaults are within sane bounds")

    # ---- 4. Dropdown defaults are valid option keys ----
    print("\n[4] Dropdown defaults are valid option keys")
    # The dropdown option keys are known; we just check that the default
    # values are non-empty strings.
    dropdown_keys = [
        "wingman_safety_level",
        "wingman_battle_control_mode",
        "wingman_battle_plan_bias",
        "wingman_turn_cap_outcome",
        "wingman_restriction_violation_action",
        "wingman_ai_aggression",
    ]
    for k in dropdown_keys:
        v = lua.eval(f"wingman_mct.get_default_settings().{k}")
        if not isinstance(v, str) or not v:
            print(f"  FAIL: {k} = {v!r} (expected a non-empty string)")
            return 1
    print(f"  OK: all {len(dropdown_keys)} dropdown defaults are non-empty strings")

    # ---- 5. validate_settings clamps out-of-range sliders ----
    print("\n[5] validate_settings clamps out-of-range sliders")
    clamped = lua.eval('''
        (function()
            local s = wingman_mct.get_default_settings()
            s.wingman_ai_orders_per_turn = 999
            s.wingman_autoresolve_threshold = -50
            s.wingman_ai_diplomacy_per_turn = 100
            local out = wingman_mct.validate_settings(s)
            return {
                orders  = out.wingman_ai_orders_per_turn,
                thresh  = out.wingman_autoresolve_threshold,
                diplo   = out.wingman_ai_diplomacy_per_turn,
            }
        end)()
    ''')
    clamped_dict = dict(clamped.items()) if hasattr(clamped, "items") else {}
    print(f"  clamped: {clamped_dict}")
    if not (1 <= clamped_dict.get("orders", 0) <= 50):
        print(f"  FAIL: orders clamp failed: {clamped_dict.get('orders')!r}")
        return 1
    if not (0 <= clamped_dict.get("thresh", -1) <= 100):
        print(f"  FAIL: threshold clamp failed: {clamped_dict.get('thresh')!r}")
        return 1
    if not (0 <= clamped_dict.get("diplo", -1) <= 10):
        print(f"  FAIL: diplomacy clamp failed: {clamped_dict.get('diplo')!r}")
        return 1
    print("  OK: all out-of-range sliders were clamped to valid bounds")

    # ---- 6. validate_settings normalizes invalid dropdown keys ----
    print("\n[6] validate_settings normalizes invalid dropdown keys")
    normalized = lua.eval('''
        (function()
            local s = wingman_mct.get_default_settings()
            s.wingman_safety_level = "garbage_value"
            s.wingman_battle_control_mode = "totally_invalid"
            local out = wingman_mct.validate_settings(s)
            return {
                safety   = out.wingman_safety_level,
                battle   = out.wingman_battle_control_mode,
            }
        end)()
    ''')
    norm_dict = dict(normalized.items()) if hasattr(normalized, "items") else {}
    print(f"  normalized: {norm_dict}")
    for k, v in norm_dict.items():
        if v in ("garbage_value", "totally_invalid", None, ""):
            print(f"  FAIL: {k} = {v!r} (expected the default to be restored)")
            return 1
    print("  OK: invalid dropdown keys were restored to defaults")

    # ---- 7. CSV parsing round-trips for banned factions ----
    # Use rebuild_ban_list (which is what the rules engine calls) plus
    # get_banned_factions (the consumer) — that's the canonical path.
    # validate_settings() does NOT parse the ban CSV; that's intentional
    # (the ban list is built lazily by the rules engine, not on every
    # validate call). We exercise the full path here.
    print("\n[7] CSV parsing round-trips for the banned factions list")
    lua.execute('''
        _G.CFSettings = {
            wingman_banned_factions_csv = "wh_main_emp_empire, wh_main_dwf_dwarfs,wh_main_vmp_vampire_counts",
        }
    ''')
    lua.eval("wingman_mct.rebuild_ban_list()")
    parsed = lua.eval("wingman_mct.get_banned_factions()")
    parsed_list = list(parsed.values()) if hasattr(parsed, "values") else list(parsed) if parsed else []
    print(f"  parsed: {parsed_list}")
    expected_csv = ["wh_main_emp_empire", "wh_main_dwf_dwarfs", "wh_main_vmp_vampire_counts"]
    if parsed_list != expected_csv:
        print(f"  FAIL: expected {expected_csv}, got {parsed_list}")
        return 1
    print("  OK: CSV parsing handles whitespace and gives a clean list")

    # Also test the required_settlements CSV (which IS parsed by
    # validate_settings) with the same input format.
    parsed_settlements = lua.eval('''
        (function()
            local s = wingman_mct.get_default_settings()
            s.wingman_required_settlements_csv = "wh_main_emp_altdorf, wh_main_dwf_karak_izor,emp_eicheschafen"
            local out = wingman_mct.validate_settings(s)
            return out.wingman_required_settlements
        end)()
    ''')
    parsed_settlements_list = list(parsed_settlements.values()) if hasattr(parsed_settlements, "values") else list(parsed_settlements) if parsed_settlements else []
    expected_settlements = ["wh_main_emp_altdorf", "wh_main_dwf_karak_izor", "emp_eicheschafen"]
    if parsed_settlements_list != expected_settlements:
        print(f"  FAIL: required_settlements expected {expected_settlements}, got {parsed_settlements_list}")
        return 1
    print("  OK: required_settlements CSV also parses correctly")

    # ---- 8. read_settings returns defaults when CFSettings is empty ----
    print("\n[8] read_settings returns defaults when CFSettings is empty")
    lua.execute('_G.CFSettings = nil')
    read_defaults = lua.eval("wingman_mct.read_settings()")
    read_dict = dict(read_defaults.items()) if hasattr(read_defaults, "items") else {}
    if "wingman_enabled" not in read_dict:
        print("  FAIL: read_settings did not return defaults when CFSettings is nil")
        return 1
    if read_dict["wingman_enabled"] is not False:
        print(f"  FAIL: wingman_enabled = {read_dict['wingman_enabled']!r} (expected false)")
        return 1
    print("  OK: read_settings returns defaults when CFSettings is nil")

    # ---- 9. read_settings merges CFSettings overrides ----
    print("\n[9] read_settings merges CFSettings overrides")
    lua.execute('''
        _G.CFSettings = {
            wingman_enabled = true,
            wingman_ai_orders_per_turn = 25,
        }
    ''')
    merged = lua.eval("wingman_mct.read_settings()")
    merged_dict = dict(merged.items()) if hasattr(merged, "items") else {}
    if not merged_dict.get("wingman_enabled"):
        print(f"  FAIL: wingman_enabled override not applied: {merged_dict.get('wingman_enabled')!r}")
        return 1
    if merged_dict.get("wingman_ai_orders_per_turn") != 25:
        print(f"  FAIL: orders_per_turn override not applied: {merged_dict.get('wingman_ai_orders_per_turn')!r}")
        return 1
    print("  OK: CFSettings overrides applied correctly")

    # ---- 10. The battle-side constants match the campaign-side constants ----
    # This is the architectural check: wingman_battle_init.lua duplicates
    # the MODE_*/BIAS_* string values from wingman_constants.lua. They
    # run in different Lua states, so they can't require each other,
    # but the string values must stay in sync.
    print("\n[10] wingman_battle_init constants stay in sync with wingman_constants")
    # Read the actual file content and parse out the constants.
    bi_path = os.path.join(REPO_ROOT, "script", "battle", "mod", "wingman_battle_init.lua")
    wc_path = os.path.join(REPO_ROOT, "script", "campaign", "mod", "wingman_constants.lua")
    bi_src = open(bi_path).read()
    wc_src = open(wc_path).read()

    def extract_mode_constants(src):
        """Extract the string values of MODE_*/BIAS_* constants."""
        out = {}
        for m in re.finditer(r'(wingman_(?:battle_init|constants))\.(MODE_[A-Z_]+|BIAS_[A-Z_]+)\s*=\s*"([^"]+)"', src):
            out[m.group(2)] = m.group(3)
        return out

    bi_consts = extract_mode_constants(bi_src)
    wc_consts = extract_mode_constants(wc_src)
    if not bi_consts:
        print("  FAIL: couldn't parse any constants from wingman_battle_init.lua")
        return 1
    if not wc_consts:
        print("  FAIL: couldn't parse any constants from wingman_constants.lua")
        return 1
    # Compare on the common key set
    common = set(bi_consts.keys()) & set(wc_consts.keys())
    if not common:
        print("  FAIL: no shared MODE_*/BIAS_* keys between the two files")
        return 1
    drift = []
    for k in sorted(common):
        if bi_consts[k] != wc_consts[k]:
            drift.append((k, bi_consts[k], wc_consts[k]))
    if drift:
        print("  FAIL: constant drift detected (battle_init vs constants):")
        for k, biv, wcv in drift:
            print(f"    {k}: battle_init={biv!r} constants={wcv!r}")
        return 1
    print(f"  OK: {len(common)} shared constants are in sync: {sorted(common)}")

    # ---- 11. wingman_mct is_available returns true when mct handle is present ----
    print("\n[11] is_available reflects mct handle presence")
    avail = lua.eval("wingman_mct.is_available()")
    if avail is not True:
        print(f"  FAIL: is_available() = {avail!r} (expected True with stub mct handle)")
        return 1
    print("  OK: is_available() = True")

    # ---- 12. get_all_options returns array of {key, value, type} ----
    print("\n[12] get_all_options returns array of {key, value, type}")
    options = lua.eval("wingman_mct.get_all_options()")
    options_list = list(options.values()) if hasattr(options, "values") else list(options) if options else []
    if not options_list or len(options_list) < 10:
        print(f"  FAIL: get_all_options returned {len(options_list)} entries (expected >= 10)")
        return 1
    # Each option is a table with key, value, type
    first = options_list[0]
    if hasattr(first, "items"):
        first_dict = dict(first.items())
    else:
        first_dict = first if isinstance(first, dict) else {}
    for f in ("key", "value", "type"):
        if f not in first_dict:
            print(f"  FAIL: option missing field {f!r}: {first_dict}")
            return 1
    print(f"  OK: get_all_options returned {len(options_list)} entries, each with key/value/type")

    # ---- 13. validate_settings fills in missing keys from defaults ----
    print("\n[13] validate_settings fills in missing keys from defaults")
    filled = lua.eval('''
        (function()
            local s = {wingman_enabled = true}  -- intentionally minimal
            local out = wingman_mct.validate_settings(s)
            return {
                enabled     = out.wingman_enabled,
                auto_end    = out.wingman_auto_end_turn_delay_seconds,
                orders      = out.wingman_ai_orders_per_turn,
                safety      = out.wingman_safety_level,
            }
        end)()
    ''')
    filled_dict = dict(filled.items()) if hasattr(filled, "items") else {}
    if filled_dict.get("enabled") is not True:
        print(f"  FAIL: enabled = {filled_dict.get('enabled')!r} (expected True, the caller-provided value)")
        return 1
    if filled_dict.get("auto_end") != 2:
        print(f"  FAIL: auto_end default not filled in: {filled_dict.get('auto_end')!r}")
        return 1
    if filled_dict.get("orders") != 12:
        print(f"  FAIL: orders default not filled in: {filled_dict.get('orders')!r}")
        return 1
    if filled_dict.get("safety") != "conservative":
        print(f"  FAIL: safety default not filled in: {filled_dict.get('safety')!r}")
        return 1
    print("  OK: missing keys filled in from defaults; caller-provided values preserved")

    print("\nALL MCT-SETTINGS CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
