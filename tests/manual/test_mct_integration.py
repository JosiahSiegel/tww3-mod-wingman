#!/usr/bin/env python
"""MCT integration test: verify script/mct/settings/wingman_mct.lua
registers cleanly against the canonical TWW3 MCT v0.9 API surface
(verified against chadvandy/mct_wh3 source on GitHub).

This test exists because the previous wingman_mct.lua was written
against a Three Kingdoms / v0.9-Beta legacy API that does NOT exist
on TWW3 MCT (mct:get_object_type, array_class, set_assigned_section,
get_option_by_key, get_finalized_setting, dynamic checkbox injection).
That file loaded with no errors but no options were visible in the
MCT panel. This test stubs ONLY the real TWW3 MCT surface and asserts
that every option Wingman registers (a) calls only methods that exist
on the real mod handle, and (b) leaves a clearly-named record of each
option so we can verify the registration count + types.

Run from the repo root:
    python tests/manual/test_mct_integration.py

Exits 0 on success, 1 on any failure.

REQUIREMENTS
    pip install lupa
    (See scripts/lupa_smoke.py for cross-Python lupa discovery.)
"""

from __future__ import annotations

import os
import subprocess
import sys


REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)

MCT_SETTINGS_FILE = "script/mct/settings/wingman_mct.lua"


# ---------------------------------------------------------------------
# Helpers for working with Lua tables from lupa.
# ---------------------------------------------------------------------
def lua_table_values(t):
    """Return a Python list of all values from a Lua table, in the
    natural Lua iteration order."""
    if t is None:
        return []
    if hasattr(t, "values"):
        return list(t.values())
    out = []
    n = len(t) if hasattr(t, "__len__") else 0
    for i in range(1, n + 1):
        out.append(t[i])
    return out


def lua_record_to_list(rec):
    """Convert a Lua table record (e.g. {"register_mod", "wingman"})
    into a Python list of its positional fields."""
    if rec is None:
        return []
    return [str(x) for x in lua_table_values(rec)]


# ---------------------------------------------------------------------
# Engine stub for the TWW3 MCT v0.9 surface.
# We intentionally implement ONLY the methods that chadvandy/mct_wh3
# exposes (verified by reading its source on GitHub). The stub records
# every method call so the test can assert the exact registration
# shape.
# ---------------------------------------------------------------------
ENGINE_STUBS = r'''
-- Recorded calls to the mod handle.
_G.mct_calls = {}

-- Recorded options: key -> {type, text, tooltip, default, min, max, step, dropdown}
_G.mct_options = {}

-- Recorded sections: name -> display_label
_G.mct_sections = {}

-- Finalized settings (CFSettings). Tests mutate this between read_settings()
-- calls to verify the API surface reads from CFSettings.
_G.CFSettings = {}

local mod_handle = nil

-- Real TWW3 MCT handle factory. Stubs ONLY the methods that the real
-- mod handle exposes. Anything not in this table is a missing API
-- and will raise a hard error when called (so regressions surface
-- here, not silently in the game).
local function make_option(key, otype)
    if _G.mct_options[key] then
        error("[TEST-FAIL] duplicate option key: " .. key)
    end
    local rec = {
        type = otype,
        text = nil,
        tooltip = nil,
        default = nil,
        min = nil,
        max = nil,
        step = nil,
        dropdown = nil,
    }
    _G.mct_options[key] = rec
    return {
        set_text          = function(self, t) rec.text = t end,
        set_tooltip_text  = function(self, t) rec.tooltip = t end,
        set_default_value = function(self, v) rec.default = v end,
        slider_set_min_max= function(self, mn, mx) rec.min = mn; rec.max = mx end,
        slider_set_step_size = function(self, s) rec.step = s end,
        add_dropdown_values = function(self, list) rec.dropdown = list end,
    }
end

local ModClass = {}
ModClass.__index = ModClass

function ModClass:set_title(t)  _G.mct_calls[#_G.mct_calls + 1] = {"set_title", t} end
function ModClass:set_author(a) _G.mct_calls[#_G.mct_calls + 1] = {"set_author", a} end
function ModClass:set_version(v, sv) _G.mct_calls[#_G.mct_calls + 1] = {"set_version", v, sv} end
function ModClass:set_workshop_id(w) _G.mct_calls[#_G.mct_calls + 1] = {"set_workshop_id", w} end
function ModClass:set_main_image(p, w, h) _G.mct_calls[#_G.mct_calls + 1] = {"set_main_image", p, w, h} end
function ModClass:set_description(d) _G.mct_calls[#_G.mct_calls + 1] = {"set_description", d} end
function ModClass:add_new_section(name, label)
    _G.mct_calls[#_G.mct_calls + 1] = {"add_new_section", name, label}
    _G.mct_sections[name] = label
end
function ModClass:add_new_option(key, otype)
    _G.mct_calls[#_G.mct_calls + 1] = {"add_new_option", key, otype}
    return make_option(key, otype)
end

-- Methods that MUST NOT exist on the real TWW3 MCT handle. We define
-- them here ONLY so the test detects the regression via the _G.mct_calls
-- log, not via a silent error. If the test file calls any of these
-- the test will fail because no method is defined.
for _, banned in ipairs({
    "set_assigned_section",
    "get_option_by_key",
    "get_finalized_setting",
    "get_sections",
    "get_settings_page",
    "OnPopulate",
}) do
    ModClass[banned] = function(self, ...)
        _G.mct_calls[#_G.mct_calls + 1] = {"BANNED_API_CALL", banned}
        error("[TEST-FAIL] wingman_mct called banned API: " .. banned)
    end
end

-- Methods that were used by the 3K-legacy wingman_mct.lua but MUST
-- NOT be called against the real TWW3 MCT mct: handle.
local MctRootBanned = {
    "get_object_type",
    "get_mct_option_class_subtype",
    "get_control_group_class",
}
for _, banned in ipairs(MctRootBanned) do
    _G.MctRootBanned = _G.MctRootBanned or {}
    _G.MctRootBanned[banned] = banned
end

local MctRoot = {}
MctRoot.__index = MctRoot
function MctRoot:register_mod(key)
    _G.mct_calls[#_G.mct_calls + 1] = {"register_mod", key}
    if mod_handle then error("[TEST-FAIL] duplicate register_mod call") end
    mod_handle = setmetatable({key = key}, ModClass)
    return mod_handle
end
-- Stub the banned methods to detect regression.
for _, banned in ipairs(MctRootBanned) do
    MctRoot[banned] = function(self, ...)
        _G.mct_calls[#_G.mct_calls + 1] = {"BANNED_API_CALL", "mct:" .. banned}
        error("[TEST-FAIL] wingman_mct called banned root API: mct:" .. banned)
    end
end

-- The smoke test entry point. Returns the MctRoot handle.
function _G.get_mct()
    _G.mct_calls[#_G.mct_calls + 1] = {"get_mct"}
    return setmetatable({}, MctRoot)
end

-- Provide an out() so the registration log line doesn't crash the test.
_G.out = setmetatable({}, {__call = function(self, s) end})
'''


def _pcall_ok(result) -> bool:
    if isinstance(result, tuple):
        return bool(result) and bool(result[0])
    if isinstance(result, bool):
        return result
    if isinstance(result, str):
        return False
    return bool(result)


def _pcall_err(result) -> str:
    if isinstance(result, tuple) and len(result) >= 2:
        return repr(result[1])
    return repr(result)


def _find_python_with_lupa() -> list[str]:
    candidates = []
    probes = [
        ["py", "-3.11", "-c", "import lupa; print(lupa.__file__)"],
        ["py", "-3.12", "-c", "import lupa; print(lupa.__file__)"],
        ["py", "-3.13", "-c", "import lupa; print(lupa.__file__)"],
        ["py",          "-c", "import lupa; print(lupa.__file__)"],
        ["python3",     "-c", "import lupa; print(lupa.__file__)"],
        ["python",      "-c", "import lupa; print(lupa.__file__)"],
    ]
    for cmd in probes:
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                r2 = subprocess.run(
                    [cmd[0]] + cmd[1:-2] + ["-c", "import sys; print(sys.executable)"],
                    capture_output=True, text=True, timeout=10,
                )
                if r2.returncode == 0:
                    exe = r2.stdout.strip().splitlines()[-1]
                    if exe and exe not in candidates:
                        candidates.append(exe)
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            continue
    return candidates


def main() -> int:
    try:
        import lupa  # noqa: F401
        from lupa import LuaRuntime
    except ImportError:
        here = sys.executable or "python"
        msg = [
            f"FAIL: lupa is not importable from this Python ({here}).",
            "",
            "Quick fix — use the Python that has lupa installed:",
        ]
        for alt in _find_python_with_lupa():
            if alt and alt != here:
                msg.append(f"    {alt} tests/manual/test_mct_integration.py")
        msg.extend([
            "",
            "Or install lupa into the Python that `python` resolves to:",
            f"    {here} -m pip install lupa",
        ])
        print("\n".join(msg), file=sys.stderr)
        return 1

    lua = LuaRuntime(unpack_returned_tuples=True)
    failures: list[str] = []

    try:
        lua.execute(ENGINE_STUBS)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: engine stub setup error: {exc!r}", file=sys.stderr)
        return 1

    abs_path = os.path.join(REPO_ROOT, MCT_SETTINGS_FILE).replace(os.sep, "/")
    if not os.path.isfile(abs_path):
        print(f"FAIL: {MCT_SETTINGS_FILE} not found at {abs_path}", file=sys.stderr)
        return 1

    print("--- 1. Load wingman_mct.lua ---")
    result = lua.eval(f"pcall(dofile, [=[{abs_path}]=])")
    if not _pcall_ok(result):
        print(f"FAIL: load error: {_pcall_err(result)}", file=sys.stderr)
        return 1
    print("OK   loaded")

    # -----------------------------------------------------------------
    # 2. Assert the registration happened.
    # -----------------------------------------------------------------
    print("--- 2. Registration ---")
    register_calls_raw = lua.eval("_G.mct_calls") or []
    register_calls = [lua_record_to_list(c) for c in lua_table_values(register_calls_raw)]

    reg_mod_calls = [c for c in register_calls if c and c[0] == "register_mod"]
    if len(reg_mod_calls) != 1:
        failures.append(f"expected 1 register_mod call, got {len(reg_mod_calls)}")
    else:
        if reg_mod_calls[0][1] != "wingman":
            failures.append(f"register_mod key != 'wingman': got {reg_mod_calls[0][1]!r}")
        else:
            print("OK   register_mod('wingman')")

    banned_calls = [c for c in register_calls if c and c[0] == "BANNED_API_CALL"]
    if banned_calls:
        for bc in banned_calls:
            failures.append(f"wingman_mct called banned API: {bc[1]}")
    else:
        print("OK   no banned 3K-legacy API calls")

    # -----------------------------------------------------------------
    # 3. Assert all expected options are present.
    # -----------------------------------------------------------------
    print("--- 3. Options ---")
    expected_options = {
        "wingman_enabled":                       "checkbox",
        "wingman_debug_logging":                 "checkbox",
        "wingman_safety_level":                  "dropdown",
        "wingman_campaign_handover_enabled":     "checkbox",
        "wingman_auto_end_turn_delay_seconds":   "slider",
        "wingman_periodic_break_interval":       "slider",
        "wingman_break_on_diplomacy_panel":      "checkbox",
        "wingman_break_on_war_declaration":      "checkbox",
        "wingman_break_on_pending_battle":       "checkbox",
        "wingman_ai_enabled":                    "checkbox",
        "wingman_ai_aggression":                 "dropdown",
        "wingman_ai_orders_per_turn":            "slider",
        "wingman_ai_attack_adjacent":            "checkbox",
        "wingman_ai_diplomacy_enabled":          "checkbox",
        "wingman_ai_diplomacy_per_turn":         "slider",
        "wingman_ai_research_enabled":           "checkbox",
        "wingman_ai_rituals_enabled":            "checkbox",
        "wingman_battle_handover_enabled":       "checkbox",
        "wingman_battle_control_mode":           "dropdown",
        "wingman_battle_plan_bias":              "dropdown",
        "wingman_autoresolve_threshold":         "slider",
        "wingman_auto_dismiss_battle_results":   "checkbox",
        "wingman_turn_cap_enabled":              "checkbox",
        "wingman_turn_cap_value":                "slider",
        "wingman_turn_cap_outcome":              "dropdown",
        "wingman_custom_win_enabled":            "checkbox",
        "wingman_required_settlements_csv":      "text_input",
        "wingman_required_defeated_factions_csv":"text_input",
        "wingman_faction_restrictions_enabled":  "checkbox",
        "wingman_restriction_violation_action":  "dropdown",
        "wingman_banned_factions_csv":           "text_input",
    }

    actual_options = lua.eval("_G.mct_options") or {}
    # NOTE: Python's len() on a lupa Lua table returns 0 when the
    # table lives in a global proxy (the length metadata is lost).
    # Use the Lua-side pairs count instead, which is the source of
    # truth on a per-call basis.
    actual_option_count = int(lua.eval("(function() local n=0 for k,_ in pairs(_G.mct_options) do n=n+1 end return n end)()"))
    if actual_option_count != len(expected_options):
        failures.append(
            f"option count mismatch: expected {len(expected_options)}, "
            f"got {actual_option_count}"
        )
    print(f"OK   {actual_option_count} options registered")

    actual_keys = {str(k) for k in actual_options.keys()}
    missing = [k for k in expected_options if k not in actual_keys]
    if missing:
        failures.append(f"missing options: {missing}")
    else:
        print("OK   all expected options present")

    extra = [k for k in actual_keys if k not in expected_options]
    if extra:
        failures.append(f"unexpected options: {extra}")
    else:
        print("OK   no unexpected options")

    # Type checks
    type_mismatches = []
    for key, expected_type in expected_options.items():
        rec = actual_options[key]
        actual_type = rec.type if hasattr(rec, "type") else None
        if actual_type != expected_type:
            type_mismatches.append(f"{key}: expected {expected_type}, got {actual_type}")
    if type_mismatches:
        for tm in type_mismatches:
            failures.append(f"option type mismatch: {tm}")
    else:
        print("OK   all option types correct")

    # Every option should have set_default_value set.
    missing_default = []
    for key in expected_options:
        rec = actual_options[key]
        default = rec.default if hasattr(rec, "default") else None
        if default is None:
            missing_default.append(key)
    if missing_default:
        failures.append(f"options missing default: {missing_default}")
    else:
        print(f"OK   all {len(expected_options)} options have defaults set")

    # Sliders should have min/max/step set.
    slider_options = [k for k, t in expected_options.items() if t == "slider"]
    slider_issues = []
    for key in slider_options:
        rec = actual_options[key]
        mn = rec.min if hasattr(rec, "min") else None
        mx = rec.max if hasattr(rec, "max") else None
        st = rec.step if hasattr(rec, "step") else None
        if mn is None or mx is None or st is None:
            slider_issues.append(f"{key}: min={mn} max={mx} step={st}")
    if slider_issues:
        for si in slider_issues:
            failures.append(f"slider missing range/step: {si}")
    else:
        print(f"OK   all {len(slider_options)} sliders have min/max/step")

    # Dropdowns should have a non-empty dropdown list.
    dropdown_options = [k for k, t in expected_options.items() if t == "dropdown"]
    dropdown_issues = []
    for key in dropdown_options:
        rec = actual_options[key]
        dd = rec.dropdown if hasattr(rec, "dropdown") else None
        if not dd or len(dd) == 0:
            dropdown_issues.append(key)
    if dropdown_issues:
        for di in dropdown_issues:
            failures.append(f"dropdown missing values: {di}")
    else:
        print(f"OK   all {len(dropdown_options)} dropdowns have values")

    # -----------------------------------------------------------------
    # 4. Assert the public API surface is exported.
    # -----------------------------------------------------------------
    print("--- 4. Public API ---")
    required_api = (
        "is_available",
        "get_default_settings",
        "read_settings",
        "validate_settings",
        "rebuild_ban_list",
        "get_banned_factions",
        "get_all_options",
    )
    api_missing = []
    for fn in required_api:
        present = bool(lua.eval(f"type(_G.wingman_mct.{fn}) == 'function'"))
        if not present:
            api_missing.append(fn)
    if api_missing:
        for fn in api_missing:
            failures.append(f"wingman_mct.{fn} missing or not a function")
    else:
        print(f"OK   all {len(required_api)} public API methods exported")

    # -----------------------------------------------------------------
    # 5. is_available() returns true (MCT is loaded in this test).
    # -----------------------------------------------------------------
    is_avail = bool(lua.eval("_G.wingman_mct.is_available()"))
    if not is_avail:
        failures.append("is_available() should be true when MCT stub is loaded")
    else:
        print("OK   is_available() == true")

    # -----------------------------------------------------------------
    # 6. read_settings() returns a table with all expected keys.
    # -----------------------------------------------------------------
    print("--- 5. read_settings() ---")
    key_count = int(lua.eval("((function(t) local n=0 for k,_ in pairs(t) do n=n+1 end return n end)(_G.wingman_mct.read_settings()))"))
    if key_count < len(expected_options):
        failures.append(f"read_settings() returned {key_count} keys; expected at least {len(expected_options)}")
    else:
        print(f"OK   read_settings() returned {key_count} keys (>= {len(expected_options)} expected)")

    # -----------------------------------------------------------------
    # 7. Mutate CFSettings, then read_settings() must reflect it.
    # -----------------------------------------------------------------
    print("--- 6. CFSettings round-trip ---")
    lua.execute('_G.CFSettings["wingman_debug_logging"] = true')
    lua.execute('_G.CFSettings["wingman_safety_level"] = "permissive"')
    lua.execute('_G.CFSettings["wingman_auto_end_turn_delay_seconds"] = 7')
    dlog = bool(lua.eval("_G.wingman_mct.read_settings().wingman_debug_logging"))
    saf  = str(lua.eval("_G.wingman_mct.read_settings().wingman_safety_level"))
    delay = int(lua.eval("_G.wingman_mct.read_settings().wingman_auto_end_turn_delay_seconds"))
    round_trip_ok = (dlog is True) and (saf == "permissive") and (delay == 7)
    if not round_trip_ok:
        failures.append(f"CFSettings round-trip: dlog={dlog!r} saf={saf!r} delay={delay!r}")
    else:
        print("OK   read_settings() reflects CFSettings mutations (debug=1, safety=permissive, delay=7)")

    # -----------------------------------------------------------------
    # 8. validate_settings() clamps sliders + normalizes dropdowns.
    # -----------------------------------------------------------------
    print("--- 7. validate_settings() ---")
    val_table = lua.eval("""
        _G.wingman_mct.validate_settings({
            wingman_auto_end_turn_delay_seconds = 9999,
            wingman_safety_level = "bogus",
        })
    """)
    delay_clamped = int(val_table.wingman_auto_end_turn_delay_seconds)
    if delay_clamped != 10:  # max is 10
        failures.append(f"validate clamp: expected 10, got {delay_clamped!r}")
    else:
        print("OK   slider clamped to max (10)")

    safety = str(val_table.wingman_safety_level)
    if safety != "conservative":
        failures.append(f"validate normalize: expected 'conservative' (default), got {safety!r}")
    else:
        print("OK   invalid dropdown normalized to default 'conservative'")

    # -----------------------------------------------------------------
    # 9. get_banned_factions() reads from CFSettings CSV.
    # -----------------------------------------------------------------
    print("--- 8. get_banned_factions() ---")
    lua.execute('_G.CFSettings["wingman_banned_factions_csv"] = "wh_main_vampire_counts,wh2_main_skv_clan_mors, bad-key,wh_dlc09_tmb_khemri"')
    n_banned = int(lua.eval("((function(t) local n=0 for _ in pairs(t) do n=n+1 end return n end)(_G.wingman_mct.get_banned_factions()))"))
    if n_banned != 3:
        failures.append(f"get_banned_factions: expected 3 valid keys, got {n_banned}")
    else:
        keys = [
            str(lua.eval("_G.wingman_mct.get_banned_factions()[1]")),
            str(lua.eval("_G.wingman_mct.get_banned_factions()[2]")),
            str(lua.eval("_G.wingman_mct.get_banned_factions()[3]")),
        ]
        expected_keys = [
            "wh_main_vampire_counts",
            "wh2_main_skv_clan_mors",
            "wh_dlc09_tmb_khemri",
        ]
        if keys != expected_keys:
            failures.append(f"get_banned_factions: expected {expected_keys}, got {keys}")
        else:
            print(f"OK   parsed 3 valid keys; rejected 'bad-key'")

    lua.execute('_G.CFSettings["wingman_banned_factions_csv"] = ""')
    n = int(lua.eval("((function(t) local n=0 for _ in pairs(t) do n=n+1 end return n end)(_G.wingman_mct.get_banned_factions()))"))
    if n != 0:
        failures.append(f"empty CSV: expected 0 keys, got {n}")
    else:
        print("OK   empty CSV -> empty ban list")

    # -----------------------------------------------------------------
    # 10. Sections: at least the 4 expected ones are registered.
    # -----------------------------------------------------------------
    print("--- 9. Sections ---")
    sections = lua.eval("_G.mct_sections") or {}
    expected_section_names = {
        "wingman_section_general",
        "wingman_section_campaign",
        "wingman_section_battle",
        "wingman_section_rules",
    }
    actual_section_names = {str(k) for k in sections.keys()}
    missing_sections = expected_section_names - actual_section_names
    if missing_sections:
        failures.append(f"missing sections: {missing_sections}")
    else:
        print(f"OK   all 4 sections registered")

    print("---")
    if failures:
        print(f"FAIL: {len(failures)} assertion(s) failed:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("ALL CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
