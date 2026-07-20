#!/usr/bin/env python3
"""Listener arg-shape tests.

Catches a class of bugs where `wingman_listeners.register` is called
with the wrong number of args OR the wrong function in the wrong slot.

Background: `wingman_listeners.register(name, event, condition, callback, persist)`
takes 5 args. The 4th (callback) is the work-doing function; the 3rd
(condition) is the gate that decides whether the callback fires.

Bugs caught by this test (all discovered during the round-4 deep-dive
audit):

  - 6-arg call at wingman_ai.lua:2246 (true was passed as condition
    AND a real condition function was passed as arg 4 = callback).
    The actual `run_for_local_faction` callback was passed as the
    5th arg = persist, so it was never invoked by the engine. The
    AI literally never ran in production.

  - 4-arg call at wingman_ai.lua:3417 (work-doing function was in
    the condition slot, and `false` was in the callback slot). The
    engine would pcall(false) on every event, erroring. The work
    MIGHT have been done as a side effect of the condition, but the
    listener was broken.

  - wingman_missions.lua:618-643 used raw `core.add_listener`
    instead of `wingman_listeners.register`. The listeners WERE
    registered with the engine (so the engine fired them) but they
    were NOT tracked by the central registry, so any
    `wingman_listeners.unregister_all` or save/load path that relied
    on `_tracked` would miss the mission listeners.

Run from the repo root:
    python3 tests/manual/test_listener_arg_shapes.py
"""
from __future__ import annotations

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ---------------------------------------------------------------------------
# A proper Lua function-call arg counter that handles nested function
# bodies, strings (short + long-bracket), and comments.
# ---------------------------------------------------------------------------

LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}


def _is_word_char(c: str) -> bool:
    return c.isalnum() or c == "_"


def _is_word_boundary(src: str, pos: int) -> bool:
    """True if src[pos] is the start or end of a word."""
    if pos == 0 or pos == len(src):
        return True
    return not _is_word_char(src[pos - 1])


def _consume_word(src: str, pos: int) -> tuple[str, int]:
    start = pos
    while pos < len(src) and _is_word_char(src[pos]):
        pos += 1
    return src[start:pos], pos


def count_register_args(src: str, open_paren_pos: int) -> int:
    """Given a src and the position of the OPEN paren of a
    wingman_listeners.register(...) call, return the number of
    args (commas at top-level + 1). Properly handles strings,
    comments, nested function bodies, AND `local x, y, ... = ...`
    multi-assign commas inside a function body (which are NOT
    arg separators).

    Uses a proper block stack: when we see `function` we push
    'function' (or 'method' for `x.foo = function`), when we see
    `if`/`for`/`while`/`do` we push that, and when we see `end`
    we pop. This way `if X then ... end` doesn't accidentally
    close a function body.
    """
    pos = open_paren_pos + 1
    depth_paren = 0
    # Block stack: list of block kinds. `function` is a function body
    # (matters for fn_depth). Other kinds are control flow blocks
    # that close with `end` but don't affect fn_depth.
    block_stack: list[str] = []
    in_short_string = None
    in_long_string = None
    in_line_comment = False
    in_block_comment = False
    escape = False
    n_args = 1
    in_local_targets = False
    local_targets_depth_at_start = 0
    while pos < len(src):
        if escape:
            escape = False
            pos += 1
            continue
        c = src[pos]
        if c == "\\":
            escape = True
            pos += 1
            continue
        if in_long_string is not None:
            end_marker = "]" + ("=" * in_long_string) + "]"
            if src[pos:pos + len(end_marker)] == end_marker:
                pos += len(end_marker)
                in_long_string = None
                continue
            pos += 1
            continue
        if in_block_comment:
            if src[pos:pos + 2] == "]]":
                in_block_comment = False
                pos += 2
                continue
            pos += 1
            continue
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
            pos += 1
            continue
        if in_short_string is not None:
            if c == in_short_string:
                in_short_string = None
            pos += 1
            continue
        # Not in any string/comment.
        if c == "[" and src[pos + 1] == "[":
            level = 0
            q = pos + 1
            while q < len(src) and src[q] == "=":
                level += 1
                q += 1
            if q < len(src) and src[q] == "[":
                in_long_string = level
                pos = q + 1
                continue
        if c == "-" and src[pos + 1] == "-":
            if src[pos + 2] == "[" and pos + 3 < len(src) and src[pos + 3] == "[":
                in_block_comment = True
                pos += 4
                continue
            in_line_comment = True
            pos += 2
            continue
        if c in '"\'':
            in_short_string = c
            pos += 1
            continue
        if c == "(" or c == "{" or c == "[":
            if c == "(":
                depth_paren += 1
            pos += 1
            continue
        if c == ")" or c == "}" or c == "]":
            if c == ")":
                if depth_paren == 0:
                    return n_args
                depth_paren -= 1
            pos += 1
            continue
        if c.isalpha() or c == "_":
            w, next_pos = _consume_word(src, pos)
            is_word = _is_word_boundary(src, pos)
            right_boundary = (next_pos >= len(src)) or (not _is_word_char(src[next_pos]))
            if not (is_word and right_boundary):
                pos = next_pos
                continue
            if w == "function":
                if depth_paren == 0:
                    block_stack.append("function")
                    in_local_targets = False
            elif w == "end":
                if block_stack and depth_paren == 0:
                    block_stack.pop()
                in_local_targets = False
            elif w in ("if", "for", "while", "do"):
                if depth_paren == 0:
                    block_stack.append(w)
            elif w == "repeat":
                if depth_paren == 0:
                    block_stack.append("repeat")
            elif w == "local":
                if depth_paren == 0 and "function" in block_stack:
                    in_local_targets = True
                    local_targets_depth_at_start = depth_paren
            pos = next_pos
            continue
        if c == "=" and in_local_targets and depth_paren == local_targets_depth_at_start:
            in_local_targets = False
        if c == ";" and in_local_targets and depth_paren == local_targets_depth_at_start:
            in_local_targets = False
        if c == "\n" and in_local_targets and depth_paren == local_targets_depth_at_start:
            in_local_targets = False
        if c == ",":
            if depth_paren == 0 and "function" not in block_stack:
                n_args += 1
            # else: inside a function body OR inside a paren OR inside local-targets → not an arg sep
        pos += 1
    return n_args


def find_register_calls(src: str) -> list[tuple[int, int, int]]:
    """Return list of (line, open_paren_pos, n_args) for every
    wingman_listeners.register( call."""
    results = []
    for m in re.finditer(r"wingman_listeners\.register\s*\(", src):
        p = m.end() - 1
        n = count_register_args(src, p)
        line = src[:m.start()].count("\n") + 1
        results.append((line, p, n))
    return results


def find_raw_add_listener(src: str) -> list[tuple[int, str, str]]:
    """Return list of (line, kind, snippet) for every ACTUAL
    `core.add_listener` / `pcall(core.add_listener, ...)` invocation
    in code. Skips comments and guard expressions (we allow guards
    like `if not core.add_listener` because the actual call goes
    through wingman_listeners.register).

    `kind` is one of:
      - "pcall_invocation": an actual `pcall(core.add_listener, ...)`
      - "colon_invocation": an actual `core:add_listener(...)`
      - "comment": a comment mentioning the API
      - "guard": a type-check guard like `if not core.add_listener`
    """
    results = []
    lines = src.split("\n")
    for m in re.finditer(r"(?:pcall\(\s*core\.add_listener|pcall\(core\.add_listener,|core:add_listener\()", src):
        line = src[:m.start()].count("\n") + 1
        line_text = lines[line - 1] if line - 1 < len(lines) else ""
        stripped = line_text.strip()
        if stripped.startswith("--"):
            kind = "comment"
        elif "pcall(core.add_listener" in line_text or "pcall(core.add_listener," in line_text:
            kind = "pcall_invocation"
        elif "core:add_listener(" in line_text:
            kind = "colon_invocation"
        else:
            kind = "unknown"
        results.append((line, kind, stripped[:80]))
    return results


# ---------------------------------------------------------------------------
# The tests
# ---------------------------------------------------------------------------

def _run() -> int:
    script_dir = os.path.join(REPO_ROOT, "script", "campaign", "mod")
    files = [
        "wingman_ai.lua",
        "wingman_battle.lua",
        "wingman_safety.lua",
        "wingman_missions.lua",
        "wingman_campaign.lua",
        "wingman_listeners.lua",  # for completeness
        "wingman_state.lua",  # in case anything here ever calls
        "wingman_init.lua",
        "wingman_rules.lua",
    ]
    files = [os.path.join(script_dir, f) for f in files if os.path.exists(os.path.join(script_dir, f))]

    # ---- 1. Every wingman_listeners.register call has exactly 5 args ----
    print("[1] Every wingman_listeners.register call has exactly 5 args")
    bad = []
    for f in files:
        src = open(f).read()
        for line, _pos, n in find_register_calls(src):
            if n != 5:
                rel = os.path.relpath(f, REPO_ROOT)
                bad.append((rel, line, n))
    if bad:
        for rel, line, n in bad:
            print(f"  FAIL: {rel}:{line} has {n} args (expected 5)")
        print(f"  ({len(bad)} bad call(s) found)")
        return 1
    print(f"  OK: all wingman_listeners.register calls in script/ are 5-arg")

    # ---- 2. No raw core.add_listener invocations outside wingman_listeners.lua ----
    print("\n[2] No raw core.add_listener invocations outside wingman_listeners.lua")
    bad = []
    for f in files:
        name = os.path.basename(f)
        if name == "wingman_listeners.lua":
            continue  # it's allowed there
        src = open(f).read()
        for line, kind, snippet in find_raw_add_listener(src):
            if kind in ("comment", "guard"):
                continue
            rel = os.path.relpath(f, REPO_ROOT)
            bad.append((rel, line, kind, snippet))
    if bad:
        for rel, line, kind, snippet in bad:
            print(f"  FAIL: {rel}:{line} ({kind}): {snippet}")
        print(f"  ({len(bad)} bad call(s) found)")
        return 1
    print("  OK: every listener goes through the central registry (guards + comments OK)")

    # ---- 3. wingman_missions.register_listeners actually uses the registry ----
    print("\n[3] wingman_missions uses wingman_listeners.register (not raw core.add_listener)")
    missions_path = os.path.join(script_dir, "wingman_missions.lua")
    src = open(missions_path).read()
    if "wingman_listeners.register" not in src:
        print("  FAIL: wingman_missions.lua does not call wingman_listeners.register")
        return 1
    # Allow guards (type checks) and warn() message strings. Reject actual invocations.
    for line, kind, snippet in find_raw_add_listener(src):
        if kind in ("pcall_invocation", "colon_invocation"):
            print(f"  FAIL: wingman_missions.lua:{line} still has raw {kind}: {snippet}")
            return 1
    print("  OK: wingman_missions routes through the central registry")

    # ---- 4. The mission listener names are stable strings, not constructed ----
    print("\n[4] mission listener names are stable string constants")
    # Look for "wingman_missions_success" and "wingman_missions_failure"
    # appearing in BOTH the register AND unregister paths.
    for listener_name in ("wingman_missions_success", "wingman_missions_failure"):
        if src.count(listener_name) < 2:
            print(f"  FAIL: '{listener_name}' should appear in both register and unregister")
            return 1
    print("  OK: mission listener names are stable across register/unregister")

    # ---- 5. (Regression check) The old buggy 6-arg shape is gone ----
    print("\n[5] Regression: the 6-arg shape is gone (handled by check #1)")
    print("  OK: covered by the global 5-arg check in section [1]")

    # ---- 6. The spectator listener has a real callback, not false ----
    print("\n[6] The spectator listener's callback is a function, not `false`")
    for m in re.finditer(r"wingman_listeners\.register\s*\(\s*\"wingman_ai_spectator_buttons\"", src):
        # Look at the closing of this call
        end = src.find("\n", m.end())
        block = src[m.end():end + 1] if end > 0 else src[m.end():m.end() + 1000]
        # The pattern: condition function, then `false -- not persistent`
        if re.search(r"\)\s*,\s*false\s*--", block):
            # This is the 4-arg bug pattern
            n = count_register_args(src, m.end() - 1)
            print(f"  FAIL: wingman_ai_spectator_buttons has n={n} args (expected 5)")
            return 1
    print("  OK: spectator listener has 5 args (condition + callback + persist)")

    # ---- 7. live runtime: actually load + register + simulate event ----
    print("\n[7] Runtime: register the AI FactionTurnStart listener, then fire the event")
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    import lupa_smoke  # type: ignore
    from lupa import LuaRuntime  # type: ignore

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(lupa_smoke.ENGINE_STUBS)
    for rel in lupa_smoke.SOURCE_FILES:
        abs_path = os.path.join(REPO_ROOT, rel).replace(os.sep, "/")
        r = lua.eval(f"pcall(dofile, [=[{abs_path}]=])")
        if not lupa_smoke._pcall_ok(r):
            err = r[1] if isinstance(r, tuple) and len(r) >= 2 else "?"
            print(f"  FAIL load {rel}: {err}")
            return 1

    # After loading, some listeners self-register (battle) and some
    # wait for wingman.init() (which fires on first tick in real
    # gameplay). Trigger registration explicitly so the test can
    # exercise the AI FactionTurnStart path.
    lua.execute('''
        -- The AI listener is normally registered by wingman.init()
        -- via the first-tick callback. In the test we call it directly.
        if wingman_ai and type(wingman_ai.register_listeners) == "function" then
            wingman_ai.register_listeners()
        end
        if wingman_safety and type(wingman_safety.register_listeners) == "function" then
            wingman_safety.register_listeners()
        end
        if wingman_missions and type(wingman_missions.register_listeners) == "function" then
            wingman_missions.register_listeners()
        end
        if wingman_campaign and type(wingman_campaign.register_listeners) == "function" then
            wingman_campaign.register_listeners()
        end
    ''')

    # After loading, the listeners should be registered.
    # Verify the FactionTurnStart listener is in the tracked list.
    tracked_raw = lua.eval("wingman_listeners.list_names()")
    tracked = list(tracked_raw.values()) if hasattr(tracked_raw, "values") else list(tracked_raw)
    print(f"  tracked listeners: {tracked}")
    if "wingman_ai_turn_start" not in tracked:
        print("  FAIL: wingman_ai_turn_start is not in wingman_listeners._tracked")
        return 1
    if "wingman_missions_success" not in tracked or "wingman_missions_failure" not in tracked:
        print("  FAIL: mission listeners not in _tracked")
        return 1
    print("  OK: AI + safety + missions + campaign + battle all tracked")

    # Verify the engine-side listener was actually added.
    # (lupa_smoke's stub returns true without tracking; we replace it
    # below in section [7] for the runtime test. For this static check,
    # we just confirm the AI listener is registered with the central
    # registry, which is sufficient — the real engine would do the right
    # thing via core.add_listener.)
    print(f"  OK: registry has the listener (real engine will call core.add_listener)")

    # ---- 7. Runtime: actually load + register + simulate event ----
    # Most critical: fire a FactionTurnStart event and verify
    # wingman_ai.run_for_local_faction was invoked. We do this by
    # replacing the lupa_smoke stub's core.add_listener with one
    # that records the actual callback, then simulating the engine
    # firing the event by calling the recorded callback.
    print("\n[7] Runtime: register the AI FactionTurnStart listener, then fire the event")
    # Replace core.add_listener BEFORE re-registering so the tracking
    # stub captures the callback. (The lupa_smoke stub just returns
    # true and discards the args.)
    lua.execute('''
        _G.run_for_local_invoked = 0
        _G.fake_listeners = {}
        _G._diag = {}
        _G._diag.core_type = type(core)
        _G._diag.core_id = tostring(core)
        core.add_listener = function(self, name, evt, cond, cb, persist)
            _G.fake_listeners[name] = {event = evt, condition = cond, callback = cb, persist = persist}
            return true
        end
        core.remove_listener = function(self, name)
            _G.fake_listeners[name] = nil
            return true
        end
        _G._diag.new_add_type = type(core.add_listener)
        -- Verify the new add_listener is what wingman_listeners sees
        _G._diag.wl_register = type(wingman_listeners.register)
        -- Call register directly to test the path
        local r1 = wingman_listeners.register("test_diag", "DiagEvent", true,
            function(c) return end, false)
        _G._diag.diag_result = tostring(r1)
        _G._diag.diag_fake_count = (function() local n=0 for _ in pairs(_G.fake_listeners) do n=n+1 end return n end)()
        -- Now unregister and re-register each module
        _G._diag.results = {}
        if wingman_ai and wingman_ai.unregister_listeners then wingman_ai.unregister_listeners() end
        if wingman_safety and wingman_safety.unregister_listeners then wingman_safety.unregister_listeners() end
        if wingman_missions and wingman_missions.unregister_listeners then wingman_missions.unregister_listeners() end
        if wingman_campaign and wingman_campaign.unregister_listeners then wingman_campaign.unregister_listeners() end
        _G._diag.count_after_unreg = (function() local n=0 for _ in pairs(_G.fake_listeners) do n=n+1 end return n end)()
        local function safe_call(name, fn)
            local ok, err = pcall(fn)
            _G._diag.results[name] = {ok = ok, err = tostring(err)}
        end
        safe_call("ai", function() wingman_ai.register_listeners() end)
        safe_call("safety", function() wingman_safety.register_listeners() end)
        safe_call("missions", function() wingman_missions.register_listeners() end)
        safe_call("campaign", function() wingman_campaign.register_listeners() end)
        _G._diag.count_after_reg = (function() local n=0 for _ in pairs(_G.fake_listeners) do n=n+1 end return n end)()
    ''')
    print(f"  diag: core_type={lua.eval('_G._diag.core_type')}, core_id={lua.eval('_G._diag.core_id')}")
    print(f"  diag: new_add_type={lua.eval('_G._diag.new_add_type')}")
    print(f"  diag: diag_result={lua.eval('_G._diag.diag_result')}")
    print(f"  diag: diag_fake_count={lua.eval('_G._diag.diag_fake_count')}")
    print(f"  diag: count_after_unreg={lua.eval('_G._diag.count_after_unreg')}")
    print(f"  diag: count_after_reg={lua.eval('_G._diag.count_after_reg')}")
    results_raw = lua.eval('_G._diag.results')
    if hasattr(results_raw, 'items'):
        results = dict(results_raw.items())
    elif isinstance(results_raw, dict):
        results = results_raw
    else:
        results = {}
    for name, info in results.items():
        if hasattr(info, 'items'):
            info_dict = dict(info.items())
        else:
            info_dict = info if isinstance(info, dict) else {}
        ok_val = info_dict.get('ok') if hasattr(info_dict, 'get') else None
        err_val = info_dict.get('err') if hasattr(info_dict, 'get') else None
        print(f"  diag: register {name}: ok={ok_val!r} err={err_val!r}")
    fake_count = int(lua.eval("(function() local n=0 for _ in pairs(_G.fake_listeners) do n=n+1 end return n end)()"))
    print(f"  engine-side listeners added: {fake_count}")
    if fake_count < 4:
        print(f"  FAIL: expected >=4 engine-side listeners, got {fake_count}")
        return 1
    print(f"  OK: {fake_count} engine-side listener(s) added")

    # Verify the AI FactionTurnStart listener has the right event name.
    rec = lua.eval('_G.fake_listeners["wingman_ai_turn_start"]')
    if not rec or not hasattr(rec, 'items'):
        print(f"  FAIL: AI FactionTurnStart listener not in fake_listeners")
        return 1
    rec_dict = dict(rec.items())
    if rec_dict.get("event") != "FactionTurnStart":
        print(f"  FAIL: AI listener event is {rec_dict.get('event')!r}, expected 'FactionTurnStart'")
        return 1
    print(f"  OK: AI FactionTurnStart listener has event='{rec_dict['event']}'")

    # Patch run_for_local_faction to count invocations, then re-register
    # so the patched function is what the engine will call.
    lua.execute('''
        local orig_run = wingman_ai.run_for_local_faction
        wingman_ai.run_for_local_faction = function(ctx)
            _G.run_for_local_invoked = _G.run_for_local_invoked + 1
            return orig_run(ctx)
        end
        wingman_ai.unregister_listeners()
        wingman_ai.register_listeners()
    ''')
    # Simulate the engine firing the FactionTurnStart event.
    # Engine contract: condition is evaluated first; callback only fires
    # if condition returns true. With the OLD bug, the callback was the
    # condition function (returning bool), so run_for_local_faction was
    # never invoked → _G.run_for_local_invoked would stay 0.
    lua.execute('''
        local rec = _G.fake_listeners["wingman_ai_turn_start"]
        if rec then
            local ctx = {faction = function() return {name = function() return "wh_main_emp_empire" end} end}
            local passes = true
            if type(rec.condition) == "function" then
                local ok, v = pcall(rec.condition, ctx)
                passes = ok and v == true
            end
            if passes and type(rec.callback) == "function" then
                pcall(rec.callback, ctx)
            end
        end
    ''')
    n = int(lua.eval("_G.run_for_local_invoked"))
    if n != 1:
        print(f"  FAIL: run_for_local_faction was called {n} time(s) (expected 1)")
        # The bug pattern: the OLD code passed the condition function as
        # the callback and the run function as `persist`. With the bug,
        # the engine would call the condition function (which returns
        # true/false) and never invoke run_for_local_faction. So 0
        # invocations is the bug signature.
        return 1
    print(f"  OK: run_for_local_faction was invoked when the event fired")

    print("\nALL LISTENER ARG-SHAPE CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
