#!/usr/bin/env python3
"""wingman_state.json_encode — key ordering test.

Verifies that the JSON encoder's object-key sort is stable and
numeric-aware. The pre-fix code did `tostring(a) < tostring(b)`,
which produced wrong order for numeric keys:

    {1, 2, 10} -> "1", "10", "2"  (lexicographic — wrong)
    {1, 2, 10} -> "1", "2", "10"  (numeric — correct)

This matters for snapshot-diff tests, save migration, and any
debug-log comparison. The fix separates numeric and string keys
during sort: numbers sort by value, strings lexicographically,
with all numbers coming first.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_json_encode.py

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


def _enc(lua, table_src: str) -> str:
    """Run `wingman_state.json_encode({...})` for the given Lua table source."""
    expr = f"wingman_state.json_encode({table_src})"
    return lua.eval(expr)


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

    # --- Test 1: numeric keys sort by value, not lexicographic ---
    # The `name` string key forces object treatment (the array branch
    # would have tried to serialize this as a contiguous sequence, which
    # it isn't).
    print("\n[1] numeric keys {1, 2, 10} serialize in numeric order")
    out = _enc(lua, "{[1]='a', [2]='b', [10]='c', name='test'}")
    # Numeric keys serialize unquoted (1: not "1":) — the pre-existing
    # behavior. The fix is only about the *order* of the keys.
    if out != '{1:"a",2:"b",10:"c","name":"test"}':
        print(f"FAIL: expected numeric sort, got {out!r}")
        return 1
    print(f"  OK: {out}")

    # --- Test 2: mixed numeric + string keys: numbers first, then strings ---
    print("\n[2] mixed numeric + string keys: numbers first")
    out = _enc(lua, "{z=1, [1]='a', a=2, [2]='b'}")
    if out != '{1:"a",2:"b","a":2,"z":1}':
        print(f"FAIL: expected numbers first then strings lex, got {out!r}")
        return 1
    print(f"  OK: {out}")

    # --- Test 3: string keys sort lexicographically ---
    print("\n[3] string keys {zebra, apple, mango} sort lexicographically")
    out = _enc(lua, "{zebra=1, apple=2, mango=3}")
    if out != '{"apple":2,"mango":3,"zebra":1}':
        print(f"FAIL: expected lex sort, got {out!r}")
        return 1
    print(f"  OK: {out}")

    # --- Test 4: output is byte-stable across re-encodes (snapshot-friendly) ---
    print("\n[4] encoding is byte-stable across repeated calls")
    first = _enc(lua, "{count=12, name='karl', [3]='c', [10]='j', [2]='b'}")
    second = _enc(lua, "{count=12, name='karl', [3]='c', [10]='j', [2]='b'}")
    third = _enc(lua, "{count=12, name='karl', [3]='c', [10]='j', [2]='b'}")
    if first != second or second != third:
        print(f"FAIL: encoding not stable: {first!r} / {second!r} / {third!r}")
        return 1
    print(f"  OK: {first}")

    # --- Test 5: real wingman_state.settings shape ---
    print("\n[5] real settings dict serializes with deterministic order")
    out = _enc(
        lua,
        "{wingman_enabled=true, wingman_ai_max_orders_per_turn=8, "
        "wingman_ai_aggression=1, wingman_ai_orders_per_turn=4}"
    )
    expected = (
        '{"wingman_ai_aggression":1,"wingman_ai_max_orders_per_turn":8,'
        '"wingman_ai_orders_per_turn":4,"wingman_enabled":true}'
    )
    if out != expected:
        print(f"FAIL: unexpected order, got {out!r}\n  expected: {expected!r}")
        return 1
    print(f"  OK: {out}")

    print("\nALL 5 JSON ENCODER TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
