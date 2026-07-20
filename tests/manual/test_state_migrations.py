#!/usr/bin/env python3
"""wingman_state — schema migration tests.

These tests exist because v0.1 had no migration hook — the only
behavior on a saved-version mismatch was to nuke the transient
in-save keys silently. The next time a settings key is renamed or
re-shaped, players on long-running campaigns would lose their
preferences.

The new `wingman_state.MIGRATIONS` table + `migrate_settings(from, to)`
public function let us chain migrations between saved and current
schema versions. This test stubs a fake v1->v2 migration to verify:

  1. The migration chain applies in order (from+1 .. to).
  2. Each migration's return value feeds into the next.
  3. Missing migrations log a warning and fall back gracefully
     (return the pre-migration settings).
  4. Failed migrations are isolated (pcall'd) and don't corrupt
     the settings table.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_state_migrations.py

Exits 0 on success, 1 on any failure.
"""
from __future__ import annotations

import os
import sys

from lupa import LuaRuntime


HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))

# Reuse the engine stubs + the source-file order from the canonical smoke test.
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

    # --- Test 1: MIGRATIONS table exists and is empty for current schema ---
    print("\n[1] MIGRATIONS table exists and is empty (current schema is v1)")
    migrations = lua.eval("wingman_state.MIGRATIONS")
    # An empty Lua table is truthy but has no entries.
    if hasattr(migrations, "items"):
        items = list(migrations.items())
    else:
        items = list(migrations)
    if items:
        print(f"FAIL: MIGRATIONS should be empty for v1, got {items!r}")
        return 1
    print("  OK: MIGRATIONS is empty (v1 has no migrations)")

    # --- Test 2: migrate_settings(from, to) is a no-op when from == to ---
    print("\n[2] migrate_settings(1, 1) is a no-op (returns same table)")
    result = lua.eval('wingman_state.migrate_settings({foo="bar"}, 1, 1)')
    if hasattr(result, "items"):
        items = dict(result.items())
    else:
        items = dict(result)
    if items.get("foo") != "bar":
        print(f"FAIL: expected foo=bar, got {items!r}")
        return 1
    print("  OK: identity migration preserves settings")

    # --- Test 3: register a fake v1->v2 migration and verify it runs ---
    print("\n[3] register a v1->v2 migration that renames a key, verify it runs")
    lua.execute('''
        wingman_state.MIGRATIONS[2] = function(s)
            if s.wingman_ai_orders_per_turn ~= nil then
                s.wingman_ai_max_orders_per_turn = s.wingman_ai_orders_per_turn
                s.wingman_ai_orders_per_turn = nil
            end
            return s
        end
        -- chain v2->v3 to verify multi-step application
        wingman_state.MIGRATIONS[3] = function(s)
            s.wingman_ai_orders_per_turn = s.wingman_ai_max_orders_per_turn
            s.wingman_ai_max_orders_per_turn = nil
            s._schema_bumped_v3 = true
            return s
        end
    ''')
    result = lua.eval('wingman_state.migrate_settings({wingman_ai_orders_per_turn = 12}, 1, 3)')
    if hasattr(result, "items"):
        items = dict(result.items())
    else:
        items = dict(result)
    expected = {
        "wingman_ai_orders_per_turn": 12,
        "_schema_bumped_v3": True,
    }
    if items.get("wingman_ai_orders_per_turn") != 12:
        print(f"FAIL: expected orders_per_turn=12 (round-trip), got {items!r}")
        return 1
    if items.get("wingman_ai_max_orders_per_turn") is not None:
        print(f"FAIL: max_orders_per_turn should be unset after v3, got {items!r}")
        return 1
    if not items.get("_schema_bumped_v3"):
        print(f"FAIL: v3 marker missing, got {items!r}")
        return 1
    print("  OK: v1->v2->v3 chain applied in order, key round-tripped")

    # --- Test 4: missing migration (gap) logs warn and keeps pre-migration data ---
    print("\n[4] missing migration gap logs warn and keeps pre-migration data")
    # MIGRATIONS[4] is not registered; we should still get the v3 result.
    lua.execute('wingman_state.MIGRATIONS = {}')  # clear
    result = lua.eval('wingman_state.migrate_settings({keepme = "yes"}, 1, 4)')
    if hasattr(result, "items"):
        items = dict(result.items())
    else:
        items = dict(result)
    if items.get("keepme") != "yes":
        print(f"FAIL: settings should survive missing-migration gap, got {items!r}")
        return 1
    print("  OK: settings survive missing migration gap")

    # --- Test 5: a failing migration is isolated (pcall'd) ---
    print("\n[5] a migration that throws is isolated; later migrations still run")
    lua.execute('''
        wingman_state.MIGRATIONS = {}
        wingman_state.MIGRATIONS[2] = function(s) error("boom") end
        wingman_state.MIGRATIONS[3] = function(s) s.touched = true; return s end
    ''')
    result = lua.eval('wingman_state.migrate_settings({foo = "bar"}, 1, 3)')
    if hasattr(result, "items"):
        items = dict(result.items())
    else:
        items = dict(result)
    if items.get("foo") != "bar":
        print(f"FAIL: pre-migration key lost, got {items!r}")
        return 1
    if not items.get("touched"):
        print(f"FAIL: v3 migration should still run after v2 error, got {items!r}")
        return 1
    print("  OK: failing migration isolated, later migration still applied")

    print("\nALL 5 MIGRATION TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
