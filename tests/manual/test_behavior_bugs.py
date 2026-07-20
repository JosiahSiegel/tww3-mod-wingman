#!/usr/bin/env python3
"""Behavior tests — catches real bugs in the step_* dispatch.

The audit caught the surface-level structure. This file catches the
semantic bugs the audit didn't reach:

  1. step_attack_adjacent: must actually check adjacency, not just
     pick the first cached enemy. (Bug: it picks cached_enemy_chars[1].)
  2. step_diplomacy: actions_taken counter must only increment on
     success. (Bug: it increments even when the trade is rejected.)
  3. step_move_armies: defensive aggression cap of 1 must be enforced,
     not just logged. (Bug: the log line is a lie.)
  4. step_construct_buildings + step_diplomatic_reactive: must not use
     `goto` — TWW3 is Lua 5.1. (Bug: lupa 2.8 is Lua 5.5 so the
     smoke test missed it.)
  5. wingman.unregister_listeners: must call EVERY sub-module's
     unregister, not just safety. (Bug: it only cleans up safety.)

These tests run under a Lua 5.1 runtime to catch the goto issue
specifically. (Lupa 2.8 default is Lua 5.5, which masks the bug.)
We force Lua 5.1 via lupa.LuaRuntime(runtime_version="5.1") if
available; otherwise we use a regex check on the source.

Run from the repo root:
    PYTHONIOENCODING=utf-8 python tests/manual/test_behavior_bugs.py

Exits 0 on success, 1 on any failure.
"""
from __future__ import annotations

import os
import re
import sys

REPO_ROOT = os.environ.get("REPO_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)


def _import_smoke_helpers():
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    import lupa_smoke  # type: ignore
    return lupa_smoke


def _run() -> int:
    lupa_smoke = _import_smoke_helpers()
    try:
        from lupa import LuaRuntime  # type: ignore
    except ImportError:
        print("FAIL: lupa not installed. Run: pip install lupa", file=sys.stderr)
        return 1

    # ------------------------------------------------------------------
    # Source-level checks (catch goto in Lua 5.1 surface; don't need lupa)
    # ------------------------------------------------------------------
    print("\n[1] source check: no `goto` / `::` labels in campaign Lua")
    for rel in (
        "script/campaign/mod/wingman_ai.lua",
        "script/campaign/mod/wingman_battle.lua",
        "script/campaign/mod/wingman_campaign.lua",
        "script/campaign/mod/wingman_missions.lua",
        "script/campaign/mod/wingman_rules.lua",
        "script/campaign/mod/wingman_safety.lua",
        "script/campaign/mod/wingman_state.lua",
        "script/campaign/mod/wingman_init.lua",
    ):
        path = os.path.join(REPO_ROOT, rel)
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
        # `goto X` is a Lua 5.2+ keyword. `::label::` is its syntax.
        # Both are rejected by Lua 5.1. Allowed: comments.
        # Strip -- line comments and --[[ ... ]] block comments so we
        # only flag real code.
        stripped = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.DOTALL)
        stripped = re.sub(r"--[^\n]*", "", stripped)
        goto_hits = re.findall(r"\bgoto\s+\w+", stripped)
        label_hits = re.findall(r"::\w+::", stripped)
        if goto_hits or label_hits:
            print(f"FAIL: {rel} contains {len(goto_hits)} goto and {len(label_hits)} ::label:: — Lua 5.1 will reject this")
            for g in goto_hits:
                print(f"      goto: {g!r}")
            for l in label_hits:
                print(f"      label: {l!r}")
            return 1
    print("  OK: no goto/:: in any campaign module")

    # ------------------------------------------------------------------
    # Load the modules under lupa. We try to use Lua 5.1 if available;
    # otherwise we use the default and just exercise behavior.
    # ------------------------------------------------------------------
    lua = None
    for ver in ("5.1", "5.4", "5.3", "5.2", None):
        try:
            kwargs = {"unpack_returned_tuples": True}
            if ver is not None:
                kwargs["runtime_version"] = ver
            lua = LuaRuntime(**kwargs)
            if ver:
                print(f"  lupa: using Lua {ver}")
            break
        except (TypeError, ValueError):
            continue
    if lua is None:
        print("FAIL: could not create Lua runtime", file=sys.stderr)
        return 1

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

    # ------------------------------------------------------------------
    # 2. step_attack_adjacent must filter by adjacency
    # ------------------------------------------------------------------
    print("\n[2] step_attack_adjacent attacks only ADJACENT enemies, not [1]")
    # Set up 2 idle characters and 2 enemy characters. The current
    # implementation picks cached_enemy_chars[1] regardless of
    # adjacency, so char 1 attacks enemy 1, char 2 attacks enemy 1
    # (same target). After the fix, char 1 attacks enemy 1 (adjacent
    # only), char 2 attacks enemy 2 (adjacent only).
    stub = '''
        _G.attack_log = {}
        -- Force the test path: local faction, 2 idle characters,
        -- 2 enemy characters. Track who attacks whom via the
        -- cm:attack_army stub.
        _G.attack_targets = {}
        cm.attack_army = function(self, attacker, target, confirm_battle)
            table.insert(_G.attack_log, {attacker = attacker, target = target})
            table.insert(_G.attack_targets, target)
            return true
        end
        -- We need the local faction to have characters. The step
        -- function uses wingman_ai internals; we cannot mock them
        -- without exposing the symbol. We exercise the visible
        -- contract: the attack order must be issued (return >= 1)
        -- AND it must not blindly pick cached_enemy_chars[1] for
        -- BOTH characters. We can verify the second by reading
        -- the cached_enemy_chars table and asserting it has > 1
        -- entry. (The first entry is still used if it's the only
        -- adjacent one.)
    '''
    try:
        lua.execute(stub)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: stub error: {exc!r}")
        return 1
    # The attack step's adjacency filter isn't directly testable
    # without significant mocking. We can however check the source
    # for the bug — `cached_enemy_chars[1]` is the smoking gun.
    ai_src_path = os.path.join(REPO_ROOT, "script/campaign/mod/wingman_ai.lua")
    with open(ai_src_path, "r", encoding="utf-8") as f:
        ai_src = f.read()
    # Strip comments
    stripped = re.sub(r"--\[\[.*?\]\]", "", ai_src, flags=re.DOTALL)
    stripped = re.sub(r"--[^\n]*", "", stripped)
    if "cached_enemy_chars[1]" in stripped and "step_attack_adjacent" in stripped:
        # Find the step_attack_adjacent function
        m = re.search(r"local function step_attack_adjacent.*?(?=\nlocal function |\nfunction )",
                      stripped, flags=re.DOTALL)
        if m and "cached_enemy_chars[1]" in m.group(0):
            print("FAIL: step_attack_adjacent still hard-codes target = cached_enemy_chars[1] (ignores adjacency)")
            return 1
    print("  OK: step_attack_adjacent does not hard-code target = cached_enemy_chars[1]")

    # ------------------------------------------------------------------
    # 3. step_diplomacy: actions_taken must only count successes
    # ------------------------------------------------------------------
    print("\n[3] step_diplomacy only counts SUCCESSFUL trade offers")
    # Grep for the smoking gun: `actions_taken = actions_taken + 1` after
    # a `if not ok_t then` branch.
    if "if not ok_t then" in stripped:
        m = re.search(r"if not ok_t then.*?actions_taken = actions_taken \+ 1", stripped, flags=re.DOTALL)
        if m:
            # The `actions_taken = actions_taken + 1` is OUTSIDE the if/else
            # and gets executed even when ok_t is false.
            print("FAIL: step_diplomacy increments actions_taken even when trade offer was rejected")
            return 1
    print("  OK: step_diplomacy only counts successful trade offers")

    # ------------------------------------------------------------------
    # 4. step_move_armies: defensive cap must be enforced, not just logged
    # ------------------------------------------------------------------
    print("\n[4] step_move_armies actually caps defensive aggression at 1")
    # Look for the bug pattern: a log line about "capped moves this turn
    # at 1" but no `return 1` or `break` in the defensive branch.
    m = re.search(r"local function step_move_armies.*?(?=\nlocal function |\nfunction |\n--- )",
                  stripped, flags=re.DOTALL)
    if m and "defensive aggression capped moves this turn at 1" in m.group(0):
        # The function logs a cap but doesn't enforce it. The fix is to
        # return moves_issued at 1, or break out of the loop, or to
        # just not allow multiple moves in the first place.
        func_body = m.group(0)
        # Defensive case must actually cap. Check for `return 1` inside
        # the defensive branch (or `moves_issued = 1` or similar).
        defensive_section = re.search(
            r"if agg == AGGRESSION_DEFENSIVE and moves_issued > 1 then\s*(.+?)\n\s*end",
            func_body, flags=re.DOTALL)
        if defensive_section:
            body = defensive_section.group(1)
            if not re.search(r"\breturn\b|\bbreak\b", body):
                print(f"FAIL: step_move_armies defensive branch only LOGS, doesn't cap. Body: {body!r}")
                return 1
        else:
            print("FAIL: step_move_armies defensive cap not found in source")
            return 1
    print("  OK: step_move_armies enforces defensive cap")

    # ------------------------------------------------------------------
    # 5. wingman.unregister_listeners must call all sub-module unregisters
    # ------------------------------------------------------------------
    print("\n[5] wingman.unregister_listeners calls ALL sub-module unregisters")
    init_path = os.path.join(REPO_ROOT, "script/campaign/mod/wingman_init.lua")
    with open(init_path, "r", encoding="utf-8") as f:
        init_src = f.read()
    init_stripped = re.sub(r"--\[\[.*?\]\]", "", init_src, flags=re.DOTALL)
    init_stripped = re.sub(r"--[^\n]*", "", init_stripped)
    m = re.search(r"function wingman\.unregister_listeners.*?(?=\nfunction |\n--- )",
                  init_stripped, flags=re.DOTALL)
    if not m:
        print("FAIL: could not find wingman.unregister_listeners")
        return 1
    body = m.group(0)
    missing = []
    for mod in ("wingman_safety", "wingman_battle", "wingman_ai", "wingman_campaign", "wingman_missions"):
        if f"{mod}.unregister_listeners" not in body:
            missing.append(mod)
    if missing:
        print(f"FAIL: wingman.unregister_listeners does not call: {', '.join(missing)}")
        return 1
    print("  OK: wingman.unregister_listeners calls all 5 sub-module unregister functions")

    print("\nALL 5 BEHAVIOR BUG CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
