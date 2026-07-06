#!/usr/bin/env python
"""CI smoke test: verify all Wingman Lua modules load + execute together.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python scripts/lupa_smoke.py

Exits 0 on success, 1 on any failure. Used as the "smoke before pack" gate
in .github/workflows/release.yml.

The Lua source files are loaded in dependency order (state -> safety ->
missions -> rules -> campaign -> battle -> init). After load, each public
bootstrap entry point is invoked; pcall must return truthy (or a truthy
tuple) for the test to pass.
"""
from __future__ import annotations

import os
import sys


REPO_ROOT_HINT = os.environ.get("REPO_ROOT")
if REPO_ROOT_HINT:
    REPO_ROOT = os.path.abspath(REPO_ROOT_HINT)
else:
    REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# Module load order matters: each later file depends on the previous.
# wingman_ai.lua (W5) comes before wingman_init because init registers the
# AI listener alongside the rest.
SOURCE_FILES = (
    "script/campaign/mod/wingman_state.lua",
    "script/campaign/mod/wingman_safety.lua",
    "script/campaign/mod/wingman_missions.lua",
    "script/campaign/mod/wingman_rules.lua",
    "script/campaign/mod/wingman_ai.lua",
    "script/campaign/mod/wingman_campaign.lua",
    "script/campaign/mod/wingman_battle.lua",
    "script/campaign/mod/wingman_init.lua",
    "script/battle/mod/wingman_battle_init.lua",
)

# Bootstrap functions to invoke after load. Each must return truthy.
BOOTSTRAP_FUNCTIONS = (
    "wingman.init",
    "wingman.register_listeners",
    "wingman.shutdown",
    "wingman.try_recover_from_error_safe",
)

# W5 AI Controller: after load + bootstrap, these calls must complete without
# raising. They exercise the AI safe-order path so any syntax/range bug fails
# the smoke gate.
POST_BOOTSTRAP_AI_CALLS = (
    # Returns a snapshot table; truthy.
    "wingman_ai._snapshot",
    # run_for_local_faction must return a number (orders count) without
    # throwing. The stubbed engine has no army list, so it should return 0.
    "wingman_ai.run_for_local_faction",
)


# Minimal TWW3 engine globals. Intentionally narrow: only the symbols the
# mod's modules touch during bootstrap. Add to this table as new modules
# reach for new engine APIs.
ENGINE_STUBS = '''
_G.out = setmetatable(
    {tag = {fight = function(self, s) end}},
    {__call = function(self, s) end}
)

function _G.find_uicomponent()
    return nil
end

_G.cm = {
    is_multiplayer = function(self) return false end,
    get_local_faction_name = function(self) return "wh_main_emp_empire" end,
    turn_number = function(self) return 1 end,
    add_first_tick_callback = function(self, cb) return true end,
    -- W5: AI controller stubs — no regions / no characters, so run_for
    -- should bail early and return 0.
    query_model = function(self)
        return {
            region_list  = function() return { num_items = function(self) return 0 end, item_at = function(self, i) return nil end } end,
            faction_list = function() return { num_items = function(self) return 0 end, item_at = function(self, i) return nil end } end,
        }
    end,
    get_faction = function(self, name) return nil end,
    char_lookup_str = function(self, cqi) return nil end,
    order_move_to_settlement = function(self, cs, rk) return true end,
    force_recruit_unit = function(self, sk, uk, fk) return true end,
    construct_building = function(self, sk, fk, slot) return true end,
    queue_building_for_faction = function(self, sk, fk, slot) return true end,
    end_turn = function(self) return true end,
}

_G.core = {
    add_listener = function(self, name, evt, cond, cb, persist) return true end,
    remove_listener = function(self, name) return true end,
    svr_save_registry_string = function(self, k, v) return true end,
    svr_load_registry_string = function(self, k) return "" end,
}

_G.mission_manager = nil

_G.wingman_mct = {
    is_available = function(self) return false end,
    get_default_settings = function(self)
        return {
            wingman_enabled = false,
            wingman_campaign_handover_enabled = false,
            wingman_battle_handover_enabled = false,
            wingman_debug_logging = false,
        }
    end,
    read_settings = function(self)
        return _G.wingman_mct.get_default_settings()
    end,
}
'''


def _pcall_ok(result) -> bool:
    """Return True if a pcall result indicates success.

    lupa returns pcall() as a tuple (success, value_or_error). When
    unpack_returned_tuples=True we receive the tuple directly. A single
    bool/str is also possible from legacy stub paths, so accept either.
    """
    if isinstance(result, tuple):
        if not result:
            return False
        ok = result[0]
        if ok:
            return True
        # If success is truthy and value is None, still pass.
        return False
    if isinstance(result, bool):
        return result
    # A returned string from pcall means the error path was taken.
    if isinstance(result, str):
        return False
    # Non-empty truthy return value → success.
    return bool(result)


def main() -> int:
    # Fail fast if lupa is missing rather than half-loading and crashing later.
    try:
        import lupa  # noqa: F401  (presence check)
        from lupa import LuaRuntime
    except ImportError:
        print("FAIL: lupa not installed. Run: pip install lupa", file=sys.stderr)
        return 1

    lua = LuaRuntime(unpack_returned_tuples=True)

    try:
        lua.execute(ENGINE_STUBS)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: engine stub setup error: {exc!r}", file=sys.stderr)
        return 1

    # --- Load each Lua module in order ----------------------------------
    for rel in SOURCE_FILES:
        abs_path = os.path.join(REPO_ROOT, rel).replace(os.sep, "/")
        if not os.path.isfile(abs_path):
            print(f"FAIL {rel}: file not found at {abs_path}")
            return 1
        # dofile via pcall; long-bracket string handles any path cleanly.
        pcall_expr = f"pcall(dofile, [=[{abs_path}]=])"
        result = lua.eval(pcall_expr)
        if _pcall_ok(result):
            print(f"OK   {rel}")
        else:
            err = ""
            if isinstance(result, tuple) and len(result) >= 2:
                err = repr(result[1])
            print(f"FAIL {rel}: {err}")
            return 1

    # --- Bootstrap entry points ------------------------------------------
    print("--- bootstrap ---")
    for fn in BOOTSTRAP_FUNCTIONS:
        # Resolve once for the global namespace and once defensively for
        # modules that stash the function under _G.* directly.
        candidates = (fn, f"_G.{fn}")
        ok = False
        last_err = ""
        for c in candidates:
            try:
                result = lua.eval(f"pcall({c})")
            except Exception as exc:  # noqa: BLE001
                last_err = repr(exc)
                continue
            if _pcall_ok(result):
                ok = True
                break
            if isinstance(result, tuple) and len(result) >= 2:
                last_err = repr(result[1])
        status = "OK  " if ok else "FAIL"
        print(f"  {status} {fn}")
        if not ok:
            if last_err:
                print(f"        {last_err}", file=sys.stderr)
            return 1

    print("---")
    print("--- W5 AI controller ---")
    for fn in POST_BOOTSTRAP_AI_CALLS:
        try:
            result = lua.eval(f"pcall({fn})")
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {fn}: {exc!r}")
            return 1
        if not _pcall_ok(result):
            err = ""
            if isinstance(result, tuple) and len(result) >= 2:
                err = repr(result[1])
            print(f"FAIL {fn}: {err}")
            return 1
        # For run_for_local_faction, ensure the returned value is a number
        # (so we exercise the "0 orders on empty engine" path).
        if fn.endswith("run_for_local_faction"):
            val = None
            if isinstance(result, tuple) and len(result) >= 2:
                val = result[1]
            elif not isinstance(result, bool):
                val = result
            if not isinstance(val, int):
                print(f"FAIL {fn}: expected number return, got {type(val).__name__} ({val!r})")
                return 1
            print(f"OK   {fn} (returned {val})")
        else:
            print(f"OK   {fn}")

    print("---")
    print("ALL CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
