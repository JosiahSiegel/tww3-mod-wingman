#!/usr/bin/env python3
"""wingman_listeners — central registry test.

Verifies that the new wingman_listeners module:
  1. Tracks every successful registration.
  2. Rejects bad inputs (non-string name/event, non-function callback).
  3. Is idempotent on re-registration of the same name.
  4. Bulk-removes every tracked listener on unregister_all().
  5. Isolates failures (a bad unregister doesn't break the next one).

These exist because before this module each file had its own pcall'd
core:add_listener call and its own `registered` local. A failure to
track a listener in one place meant it leaked across save/load.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_listener_helper.py

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


# Augment the engine stubs: we want core.add_listener to log every call so
# the test can assert that the helper actually invoked the engine, not
# just the local tracker. We also add a flag to make core.remove_listener
# fail on a specific name, to test the "failure isolation" path.
_EXTRA_STUBS = '''
_G.listener_call_log = {add = {}, remove = {}}
local _orig_add = core.add_listener
core.add_listener = function(self, name, evt, cond, cb, persist)
    table.insert(_G.listener_call_log.add, {name = name, event = evt})
    return _orig_add(self, name, evt, cond, cb, persist)
end
local _orig_remove = core.remove_listener
core.remove_listener = function(self, name)
    table.insert(_G.listener_call_log.remove, {name = name})
    if name == "FAKE-FAIL-REMOVE" then
        error("simulated engine failure on " .. tostring(name))
    end
    return _orig_remove(self, name)
end
'''


def _run() -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)

    try:
        lua.execute(lupa_smoke.ENGINE_STUBS)
        lua.execute(_EXTRA_STUBS)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: stub setup error: {exc!r}", file=sys.stderr)
        return 1

    for rel in lupa_smoke.SOURCE_FILES:
        abs_path = os.path.join(REPO_ROOT, rel).replace(os.sep, "/")
        pcall_expr = f"pcall(dofile, [=[{abs_path}]=])"
        result = lua.eval(pcall_expr)
        if not lupa_smoke._pcall_ok(result):
            err = ""
            if isinstance(result, tuple) and len(result) >= 2:
                err = repr(result[1])
            print(f"FAIL load {rel}: {err}")
            return 1
    print(f"OK loaded {len(lupa_smoke.SOURCE_FILES)} modules")

    # Capture the baseline. The lupa smoke + bootstrap registered a few
    # listeners via wingman.init; subsequent assertions work in deltas.
    baseline = lua.eval("wingman_listeners.count()")
    print(f"  baseline: {baseline} listeners already tracked from bootstrap")

    # --- Test 1: register a listener, count is baseline+1, is_registered true ---
    print("\n[1] count + is_registered + list_names reflect registrations")
    lua.execute('''
        wingman_listeners.register("test-listener-1", "FactionTurnStart", true,
            function(ctx) end, false)
    ''')
    if lua.eval("wingman_listeners.count()") != baseline + 1:
        print(f"FAIL: count after 1 register != baseline+1 (got {lua.eval('wingman_listeners.count()')})")
        return 1
    if not lua.eval('wingman_listeners.is_registered("test-listener-1")'):
        print("FAIL: is_registered(test-listener-1) is false")
        return 1
    print("  OK: register tracking works")

    # --- Test 2: re-registering same name is idempotent ---
    print("\n[2] re-registering the same name is idempotent (no engine double-add)")
    add_before = len(list(lua.eval("_G.listener_call_log.add").values()))
    lua.execute('''
        wingman_listeners.register("test-listener-1", "FactionTurnStart", true,
            function(ctx) end, false)
    ''')
    if lua.eval("wingman_listeners.count()") != baseline + 1:
        print(f"FAIL: count after re-register != baseline+1, got {lua.eval('wingman_listeners.count()')}")
        return 1
    add_after = len(list(lua.eval("_G.listener_call_log.add").values()))
    if add_after != add_before:
        print(f"FAIL: re-register invoked engine.add_listener ({add_before} -> {add_after})")
        return 1
    print("  OK: re-register is idempotent, engine.add_listener not re-called")

    # --- Test 3: invalid input returns false, does not throw ---
    print("\n[3] invalid input (empty name / non-function callback) is rejected")
    bad_name = lua.eval('wingman_listeners.register("", "X", true, function() end, false)')
    if bad_name is not False:
        print(f"FAIL: empty name should return false, got {bad_name!r}")
        return 1
    bad_cb = lua.eval('wingman_listeners.register("test-bad-cb", "X", true, "not-a-fn", false)')
    if bad_cb is not False:
        print(f"FAIL: non-function callback should return false, got {bad_cb!r}")
        return 1
    if lua.eval("wingman_listeners.count()") != baseline + 1:
        print(f"FAIL: count after bad inputs changed, got {lua.eval('wingman_listeners.count()')}")
        return 1
    print("  OK: invalid input rejected, tracker unchanged")

    # --- Test 4: unregister_all removes every tracked listener ---
    print("\n[4] unregister_all removes every tracked listener and survives failure")
    lua.execute('''
        wingman_listeners.register("test-listener-2", "FactionTurnEnd", true,
            function(ctx) end, false)
        wingman_listeners.register("test-listener-3", "PanelOpenedCampaign", true,
            function(ctx) end, false)
        wingman_listeners.register("FAKE-FAIL-REMOVE", "DilemmaChoiceMadeEvent", true,
            function(ctx) end, false)
    ''')
    pre = lua.eval("wingman_listeners.count()")
    if pre != baseline + 4:
        print(f"FAIL: pre-unregister count != baseline+4 (got {pre}, baseline={baseline})")
        return 1
    removed = lua.eval("wingman_listeners.unregister_all()")
    if removed != pre:
        print(f"FAIL: unregister_all returned {removed}, expected {pre}")
        return 1
    if lua.eval("wingman_listeners.count()") != 0:
        print(f"FAIL: tracker not cleared (count={lua.eval('wingman_listeners.count()')})")
        return 1
    print("  OK: unregister_all clears tracker")

    # --- Test 5: after unregister, re-register works (idempotency reset) ---
    print("\n[5] after unregister_all, same name can be re-registered")
    lua.execute('''
        wingman_listeners.register("test-listener-1", "FactionTurnStart", true,
            function(ctx) end, false)
    ''')
    if lua.eval("wingman_listeners.count()") != 1:
        print(f"FAIL: re-register after clear failed, count={lua.eval('wingman_listeners.count()')}")
        return 1
    print("  OK: re-register after clear works")

    print("\nALL 5 LISTENER-HELPER TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
