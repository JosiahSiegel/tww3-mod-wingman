#!/usr/bin/env python3
"""Behavior tests round 2 — more semantic bugs.

Catches bugs the first round missed:

  1. mp_guard: a thrown cm:is_multiplayer should NOT block the AI.
     (Bug: the function returned false on throw, treating transient
     engine errors as "this is multiplayer".)
  2. on_panel_opened / panel_key_blocks: substring matching causes
     false positives on innocuous panel names.
     (Bug: "warehouse", "warning", "award", "skill" all matched
     the war/diplomacy/trade/alert/skill keywords. The AI would
     pause on "skill_tree" panels, "warning_tooltip" panels, etc.)

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_behavior_bugs_2.py

Exits 0 on success, 1 on any failure.
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

    safety_path = os.path.join(REPO_ROOT, "script/campaign/mod/wingman_safety.lua")
    with open(safety_path, "r", encoding="utf-8") as f:
        safety_src = f.read()
    stripped = re.sub(r"--\[\[.*?\]\]", "", safety_src, flags=re.DOTALL)
    stripped = re.sub(r"--[^\n]*", "", stripped)

    # ------------------------------------------------------------------
    # 1. mp_guard: source-level + live test
    # ------------------------------------------------------------------
    print("\n[1] mp_guard: a thrown cm:is_multiplayer should be treated as single-player")
    m = re.search(r"function wingman_safety\.mp_guard.*?(?=\nfunction |\n--- )",
                  stripped, flags=re.DOTALL)
    if not m:
        print("FAIL: could not find mp_guard function")
        return 1
    body = m.group(0)
    # The bug pattern: `if not ok then` followed by `return false` inside
    # the same block. After the fix, a thrown error should be logged but
    # not return false.
    if re.search(r"if not ok then\s*\n\s*warn\([^)]*cm:is_multiplayer[^)]*\)\s*\n\s*return false", body):
        print("FAIL: mp_guard returns false on cm:is_multiplayer throw; should treat as single-player")
        return 1
    print("  OK: source: mp_guard does not return false on engine throw")

    # Live test
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

    # Stub cm.is_multiplayer to throw
    lua.execute('''
        cm = cm or {}
        cm.is_multiplayer = function(self) error("simulated engine failure") end
    ''')
    allowed = lua.eval('wingman_safety.mp_guard("test_throw")')
    if allowed is not True:
        print(f"FAIL: mp_guard returned {allowed!r} when cm:is_multiplayer threw; should return true (single-player)")
        return 1
    print("  OK: live: mp_guard returned true when cm:is_multiplayer threw")

    # Restore cm for subsequent tests
    lua.execute('''
        cm.is_multiplayer = nil
    ''')

    # ------------------------------------------------------------------
    # 2. on_panel_opened: source-level + live test
    # ------------------------------------------------------------------
    print("\n[2] on_panel_opened: substring matching must use word boundaries")
    m = re.search(r"function wingman_safety\.on_panel_opened.*?(?=\nfunction |\n--- )",
                  stripped, flags=re.DOTALL)
    if not m:
        print("FAIL: could not find on_panel_opened function")
        return 1
    body = m.group(0)
    has_loose_war = bool(re.search(r"find\([\"']war[\"'],\s*1,\s*true\)", body))
    has_loose_diplomacy = bool(re.search(r"find\([\"']diplomacy[\"'],\s*1,\s*true\)", body))
    if has_loose_war or has_loose_diplomacy:
        offenders = []
        if has_loose_war: offenders.append("find('war', 1, true)")
        if has_loose_diplomacy: offenders.append("find('diplomacy', 1, true)")
        print(f"FAIL: on_panel_opened uses loose substring matching: {', '.join(offenders)}")
        return 1
    print("  OK: source: on_panel_opened does not use loose substring matching")

    m2 = re.search(r"local function panel_key_blocks.*?(?=\nfunction |\n--- )",
                   stripped, flags=re.DOTALL)
    if m2:
        body2 = m2.group(0)
        if re.search(r"find\(kw,\s*1,\s*true\)", body2):
            print("FAIL: panel_key_blocks uses find(kw, 1, true) without anchoring")
            return 1
    print("  OK: source: panel_key_blocks uses anchored matching or no find at all")

    # Live: dispatch fake events and check breakpoint set
    lua.execute('''
        _G.test_breakpoints = {}
        wingman_state.set_breakpoint = function(reason, data)
            table.insert(_G.test_breakpoints, {reason = reason, data = data})
        end
    ''')

    def _dispatch(panel_key: str):
        lua.execute(f'_G.test_event = {{ panel = "{panel_key}" }}')
        lua.execute('_G.test_breakpoints = {}')
        lua.eval('wingman_safety.on_panel_opened(_G.test_event)')
        bps = lua.eval('_G.test_breakpoints')
        # lupa returns Lua tables; iterate the (k, v) pairs of the
        # array, which are (1, {reason=..., data=...}), (2, ...), etc.
        items = []
        for k, v in bps.items() if hasattr(bps, "items") else []:
            items.append(v)
        return items

    cases = [
        # (panel_key, should_pause, description)
        ("warehouse_full_alert",         False, "warehouse matches 'war' substring"),
        ("skill_tree_panel",             False, "skill_tree matches 'skill' keyword"),
        ("diplomacy",                    True,  "exact match for 'diplomacy'"),
        ("diplomacy_panel",              True,  "prefix match for 'diplomacy'"),
        ("war_declaration",              True,  "prefix match for 'war'"),
        ("warning_toast",                False, "warning matches 'war' substring"),
        ("achievement_award_panel",      False, "award matches 'war' substring"),
        ("treasury_overview",            False, "treasury matches 'trade' substring"),
        ("event_message_diplomatic",     True,  "event_message prefix"),
    ]
    for panel_key, should_pause, desc in cases:
        bps = _dispatch(panel_key)
        actually_paused = any(b["reason"] == "popup_blocking" for b in bps if b)
        if actually_paused != should_pause:
            tag = "PAUSED" if actually_paused else "NOT PAUSED"
            want = "PAUSE" if should_pause else "NOT PAUSE"
            print(f"FAIL: '{panel_key}' ({desc}): got {tag}, want {want}. breakpoints={bps!r}")
            return 1
        tag = "PAUSED" if actually_paused else "skipped"
        print(f"  OK: '{panel_key}' correctly {tag}")

    print("\nALL 9 BEHAVIOR BUG-2 CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
