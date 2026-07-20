#!/usr/bin/env python3
"""wingman_constants — central constants test.

Verifies the new constants module:
  1. Every MODE_* and AGGRESSION_* constant exists and is a non-empty string.
  2. The SETTINGS table has the keys that are used in 2+ files.
  3. The helper is_battle_mode / is_aggression accept valid values and
     reject others.

This is structural — the audit's P1 finding was that stringly-typed
mode constants were scattered across files, and a typo in one place
would silently break a comparison. Centralizing them turns typos
into `nil` errors.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_constants_module.py

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


def _run() -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)

    try:
        lua.execute(lupa_smoke.ENGINE_STUBS)
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

    # --- Test 1: every MODE_* / AGGRESSION_* constant exists and is non-empty ---
    print("\n[1] every MODE_* and AGGRESSION_* constant is a non-empty string")
    expected = [
        "MODE_SCRIPTED_AI", "MODE_AUTORESOLVE_IF_FAVORABLE",
        "MODE_PAUSE_TO_CHOOSE", "MODE_MANUAL_OBSERVE",
        "AGGRESSION_DEFENSIVE", "AGGRESSION_BALANCED", "AGGRESSION_AGGRESSIVE",
    ]
    for name in expected:
        val = lua.eval(f"wingman_constants.{name}")
        if not isinstance(val, str) or val == "":
            print(f"FAIL: wingman_constants.{name} should be a non-empty string, got {val!r}")
            return 1
    print(f"  OK: {len(expected)} constants present")

    # --- Test 2: SETTINGS table has the expected keys ---
    print("\n[2] SETTINGS table has the cross-file keys")
    expected_settings = [
        "WINGMAN_ENABLED",
        "WINGMAN_AI_ORDERS_PER_TURN",
        "WINGMAN_AI_DIFFICULTY",
        "WINGMAN_AI_AGGRESSION",
        "WINGMAN_BATTLE_CONTROL_MODE",
        "WINGMAN_DEBUG_LOGGING",
    ]
    for name in expected_settings:
        val = lua.eval(f"wingman_constants.SETTINGS.{name}")
        if not isinstance(val, str) or val == "":
            print(f"FAIL: wingman_constants.SETTINGS.{name} should be a non-empty string, got {val!r}")
            return 1
    print(f"  OK: {len(expected_settings)} setting keys present")

    # --- Test 3: is_battle_mode accepts valid, rejects invalid ---
    print("\n[3] is_battle_mode accepts valid, rejects invalid")
    valid = ("scripted_ai", "autoresolve_if_favorable", "pause_to_choose", "manual_observe")
    for v in valid:
        if not lua.eval(f'wingman_constants.is_battle_mode("{v}")'):
            print(f"FAIL: is_battle_mode({v!r}) should be true")
            return 1
    invalid = ("not_a_mode", "", "SCRIPTED_AI", "scripted-ai")
    for v in invalid:
        if lua.eval(f'wingman_constants.is_battle_mode("{v}")'):
            print(f"FAIL: is_battle_mode({v!r}) should be false")
            return 1
    print("  OK: 4 valid + 4 invalid correctly classified")

    # --- Test 4: is_aggression accepts valid, rejects invalid ---
    print("\n[4] is_aggression accepts valid, rejects invalid")
    valid = ("defensive", "balanced", "aggressive")
    for v in valid:
        if not lua.eval(f'wingman_constants.is_aggression("{v}")'):
            print(f"FAIL: is_aggression({v!r}) should be true")
            return 1
    invalid = ("AGGRESSIVE", "not_a_profile", "")
    for v in invalid:
        if lua.eval(f'wingman_constants.is_aggression("{v}")'):
            print(f"FAIL: is_aggression({v!r}) should be false")
            return 1
    print("  OK: 3 valid + 3 invalid correctly classified")

    # --- Test 5: DEFAULTS in wingman_state use the central constants ---
    print("\n[5] wingman_state.DEFAULTS uses central constants (no string drift)")
    default_battle_mode = lua.eval('wingman_state.DEFAULTS.wingman_battle_control_mode')
    if default_battle_mode != lua.eval('wingman_constants.MODE_SCRIPTED_AI'):
        print(f"FAIL: DEFAULTS.wingman_battle_control_mode ({default_battle_mode!r}) != MODE_SCRIPTED_AI")
        return 1
    default_aggression = lua.eval('wingman_state.DEFAULTS.wingman_ai_aggression')
    if default_aggression != lua.eval('wingman_constants.AGGRESSION_AGGRESSIVE'):
        print(f"FAIL: DEFAULTS.wingman_ai_aggression ({default_aggression!r}) != AGGRESSION_AGGRESSIVE")
        return 1
    print("  OK: DEFAULTS values match central constants")

    print("\nALL 5 CONSTANTS MODULE TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
