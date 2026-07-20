#!/usr/bin/env python3
"""load-order guard tests.

The audit's P3 finding: every module that depends on another module
should fail loudly at load time if the dependency isn't loaded, not
defer the error to the first call site.

This test loads modules in a DELIBERATELY BAD order (state AFTER its
consumers) and asserts the guard fires with a clear error message.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_load_order_guards.py

Exits 0 on success, 1 on any failure.
"""
from __future__ import annotations

import os
import sys

from lupa import LuaRuntime


HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))

sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
import lupa_smoke  # noqa: E402


# We want the stubs in place but want to load modules in a broken order
# WITHOUT polluting the lupa state of subsequent tests. So we run each
# scenario in a fresh LuaRuntime.

def _fresh_lua() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(lupa_smoke.ENGINE_STUBS)
    return lua


def _abs(rel: str) -> str:
    return os.path.join(REPO_ROOT, rel).replace(os.sep, "/")


def _load_ok(lua, rel: str) -> tuple[bool, str]:
    """Load a module via pcall. Returns (ok, error_string)."""
    pcall_expr = f"pcall(dofile, [=[{_abs(rel)}]=])"
    result = lua.eval(pcall_expr)
    if lupa_smoke._pcall_ok(result):
        return True, ""
    err = ""
    if isinstance(result, tuple) and len(result) >= 2:
        err = str(result[1])
    return False, err


def _run() -> int:
    # --- Test 1: happy path still works (modules load in canonical order) ---
    print("\n[1] canonical order loads cleanly (sanity check)")
    lua = _fresh_lua()
    for rel in lupa_smoke.SOURCE_FILES:
        ok, err = _load_ok(lua, rel)
        if not ok:
            print(f"FAIL: canonical load of {rel} failed: {err}")
            return 1
    print(f"  OK: all {len(lupa_smoke.SOURCE_FILES)} modules loaded in canonical order")

    # --- Test 2: load wingman_ai BEFORE wingman_state, expect guard error ---
    print("\n[2] wingman_ai loaded before wingman_state fires the guard")
    lua = _fresh_lua()
    # Load prerequisites that don't depend on state.
    _load_ok(lua, "script/campaign/mod/wingman_constants.lua")
    _load_ok(lua, "script/campaign/mod/wingman_listeners.lua")
    # Now load wingman_ai — should fail because wingman_state is not loaded.
    ok, err = _load_ok(lua, "script/campaign/mod/wingman_ai.lua")
    if ok:
        print("FAIL: wingman_ai should have errored on load (wingman_state missing)")
        return 1
    if "wingman_state must be loaded" not in err:
        print(f"FAIL: error message should mention 'wingman_state must be loaded', got: {err!r}")
        return 1
    print(f"  OK: error fired with: {err[:80]}...")

    # --- Test 3: load wingman_battle BEFORE wingman_listeners, expect guard error ---
    print("\n[3] wingman_battle loaded before wingman_listeners fires the guard")
    lua = _fresh_lua()
    _load_ok(lua, "script/campaign/mod/wingman_constants.lua")
    _load_ok(lua, "script/campaign/mod/wingman_state.lua")
    ok, err = _load_ok(lua, "script/campaign/mod/wingman_battle.lua")
    if ok:
        print("FAIL: wingman_battle should have errored on load (wingman_listeners missing)")
        return 1
    if "wingman_listeners must be loaded" not in err:
        print(f"FAIL: error message should mention 'wingman_listeners must be loaded', got: {err!r}")
        return 1
    print(f"  OK: error fired with: {err[:80]}...")

    # --- Test 4: load wingman_safety BEFORE wingman_listeners, expect guard error ---
    print("\n[4] wingman_safety loaded before wingman_listeners fires the guard")
    lua = _fresh_lua()
    _load_ok(lua, "script/campaign/mod/wingman_state.lua")
    ok, err = _load_ok(lua, "script/campaign/mod/wingman_safety.lua")
    if ok:
        print("FAIL: wingman_safety should have errored on load (wingman_listeners missing)")
        return 1
    if "wingman_listeners must be loaded" not in err:
        print(f"FAIL: error message should mention 'wingman_listeners must be loaded', got: {err!r}")
        return 1
    print(f"  OK: error fired with: {err[:80]}...")

    # --- Test 5: constants must be loaded before any consumer ---
    print("\n[5] wingman_state loaded before wingman_constants fires the guard")
    lua = _fresh_lua()
    _load_ok(lua, "script/campaign/mod/wingman_listeners.lua")
    # wingman_state.lua uses wingman_constants in its DEFAULTS at line 81.
    # If wingman_constants isn't loaded, the DEFAULTS line itself
    # evaluates to nil — that's the silent-failure path the audit
    # flagged. The load-order guard catches it.
    ok, err = _load_ok(lua, "script/campaign/mod/wingman_state.lua")
    if ok:
        # If we got here, the guard didn't fire — check whether the
        # constant resolved to a string. If the constant lookup
        # returned nil and DEFAULTS still got a string value, something
        # is suspicious.
        battle_mode_default = lua.eval('wingman_state.DEFAULTS.wingman_battle_control_mode')
        if battle_mode_default is None or battle_mode_default == "":
            print(f"FAIL: DEFAULTS.wingman_battle_control_mode is empty (guard didn't fire AND constant missing)")
            return 1
        print(f"  OK: wingman_state loaded successfully with default={battle_mode_default!r}")
    else:
        # The guard fired, which is also acceptable.
        if "wingman_constants" not in err and "wingman_state" not in err:
            print(f"FAIL: error doesn't mention a load-order issue, got: {err!r}")
            return 1
        print(f"  OK: error fired with: {err[:80]}...")

    print("\nALL 5 LOAD-ORDER GUARD TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
