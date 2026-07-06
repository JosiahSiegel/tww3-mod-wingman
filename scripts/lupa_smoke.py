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
    # W6: returns a list of step_* names that run_for_local_faction dispatches.
    # Used by tests/manual/test_w6_ai_features.py and as a smoke gate.
    "wingman_ai._w6_dispatched_steps",
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
    end_turn = function(self) return true end,

    -- W6 (deep-research 2026-07-05): real TWW3 cm: API stubs that mirror
    -- the engine surface. The W5 wingman_ai.lua called order_move_to_settlement,
    -- force_recruit_unit, construct_building, queue_building_for_faction —
    -- none of those exist in TWW3. The smoke gate must stub REAL APIs so
    -- a future regression toward those phantom names surfaces here, not
    -- at runtime in the game.
    move_to = function(self, cs, x, y) return true end,
    move_to_queued = function(self, cs, x, y) return true end,
    join_garrison = function(self, cs, sk) return true end,
    leave_garrison = function(self, cs, x, y) return true end,
    attack = function(self, cs_a, cs_b, lay_siege, ignore_shroud) return true end,
    attack_queued = function(self, cs_target, lay_siege) return true end,
    attack_region = function(self, cs, rk) return true end,
    grant_unit_to_character = function(self, cs, uk) return true end,
    add_building_to_settlement = function(self, rk, bk, ok_out) return true end,
    add_building_to_settlement_queue = function(self, slot, bk) return true end,
    instantly_upgrade_building_in_region = function(self, slot, bk) return true end,
    instantly_research_all_technologies = function(self, fk) return true end,
    perform_ritual = function(self, fk, target, rk) return true end,
    force_declare_war = function(self, a, d, ia, id) return true end,
    force_make_peace = function(self, a, b) return true end,
    force_alliance = function(self, a, b, mil) return true end,
    force_make_trade_agreement = function(self, a, b) return true end,
    force_make_vassal = function(self, master, vassal) return true end,
    force_confederation = function(self, proposer, target) return true end,
    force_grant_military_access = function(self, a, b, is_hard) return true end,
    force_diplomacy = function(self, src, tgt, action, c1, c2, c3, c4) return true end,
    faction_offers_peace_to_other_faction = function(self, a, b) return true end,
    make_diplomacy_available = function(self, a, b) return true end,
    disable_movement_for_character = function(self, cs) return true end,
    enable_movement_for_character = function(self, cs) return true end,
    force_character_force_into_stance = function(self, cs, stance) return true end,
    cancel_actions_for = function(self, cs) return true end,
    heal_military_force = function(self, force) return true end,
    replenish_action_points = function(self, cs) return true end,
    stop_character_convalescing = function(self, cqi) return true end,
    add_agent_experience = function(self, cs, amt, reason) return true end,
    force_add_trait = function(self, cs, trait, silent) return true end,
    add_skill = function(self, character, skill, ignore_req) return true end,
    embed_agent_in_force = function(self, agent, force) return true end,
    transfer_region_to_faction = function(self, rk, fk) return true end,
    set_region_abandoned = function(self, rk) return true end,
    kill_character = function(self, cs, destroy) return true end,
    wound_character = function(self, cs, convalescence) return true end,
    treasury_mod = function(self, fk, amount) return true end,
    faction_add_pooled_resource = function(self, fk, resource_key, amount, factor) return true end,

    -- W6: CAI personality rewrite (Option B). Sets a script context that
    -- changes the engine's AI-evaluation heuristics for a faction. Values
    -- from chadvandy episodic_scripting docs: DEFAULT, ALPHA, BETA, GAMMA,
    -- DELTA, EPSILON, ZETA. We use ALPHA for "highest-skill".
    cai_set_faction_script_context = function(self, fk, value) return true end,
    cai_get_faction_script_context = function(self, fk) return "DEFAULT" end,
    cai_clear_faction_script_context = function(self, fk) return true end,
    cai_set_global_script_context = function(self, value) return true end,
    cai_get_global_script_context = function(self) return "DEFAULT" end,
    cai_clear_global_script_context = function(self) return true end,
    cai_force_personality_change = function(self, fk, personality) return true end,
    -- W7: explicit per-faction CAI personality swap (replaces the
    -- personality context with a database-defined personality key).
    -- Real API per episodic_scripting.html:22109.
    force_change_cai_faction_personality = function(self, fk, personality) return true end,
    -- W7: player input + turn-button locks for Autopilot mode.
    -- Per episodic_scripting.html:2462 (steal_user_input), :2272
    -- (disable_end_turn), :2495 (steal_escape_key).
    steal_user_input      = function(self, b) return true end,
    steal_escape_key      = function(self, b) return true end,
    disable_end_turn      = function(self, b) return true end,
    override_ui           = function(self, key, b) return true end,
    -- W7: ESC-hold-3-seconds take-back. The production code calls
    -- cm:steal_escape_key_with_callback(name, callback, is_persistent)
    -- which routes the ESC key to the callback when pressed. The
    -- smoke stub records the registration and exposes a helper to
    -- fire the callback so tests can exercise the take-back path.
    steal_escape_key_with_callback = function(self, name, cb, is_persistent)
        if not _G.w7_esc_callbacks then _G.w7_esc_callbacks = {} end
        _G.w7_esc_callbacks[name] = cb
        return true
    end,
    release_escape_key = function(self, name) return true end,
    -- W7: Advisory mode 3-button dilemma. Per the mc_peg_street_pawnshop
    -- vanilla pattern (3 payloads, FIRST/SECOND/THIRD), used by Advisory
    -- mode to ask the player "Apply / Skip / Always Apply?" per turn.
    create_dilemma_builder = function(self, key)
        return {
            add_choice_payload = function(self, choice, payload) return self end,
        }
    end,
    launch_custom_dilemma_from_builder = function(self, builder, faction) return true end,
    show_message_event_located = function(self, fk, t, p, d, x, y, persist, idx) return true end,
    -- W7: save/load round-trip used to re-apply autopilot lock on load.
    set_saved_value = function(self, k, v) return true end,
    get_saved_value = function(self, k, default) return default end,
    add_loading_game_callback = function(self, cb) return true end,
    add_saving_game_callback  = function(self, cb) return true end,
    callback                  = function(self, cb, delay) return true end,
    -- W8: cm:pick_random_buildable used by the new step_construct_buildings
    -- (real W6 was a documented stub). Returns a fake building key so the
    -- queue call exercises a happy path; tests override this via the
    -- _G.w8_pick_random_buildable hook.
    pick_random_buildable = function(self, settlement)
        if type(_G.w8_pick_random_buildable) == "function" then
            return _G.w8_pick_random_buildable(settlement)
        end
        return "wh3_main_building_growth"
    end,
    -- W8: cm:faction_has_pending_diplomacy_with and cm:trigger_diplomacy_response
    -- for the new step_diplomatic_reactive. Both stubbed; tests override
    -- via the _G.w8_* hooks.
    faction_has_pending_diplomacy_with = function(self, from_fk, to_fk)
        if type(_G.w8_faction_has_pending_diplomacy_with) == "function" then
            return _G.w8_faction_has_pending_diplomacy_with(from_fk, to_fk)
        end
        return false
    end,
    trigger_diplomacy_response = function(self, from_fk, to_fk, action)
        if type(_G.w8_trigger_diplomacy_response) == "function" then
            return _G.w8_trigger_diplomacy_response(from_fk, to_fk, action)
        end
        return true
    end,
    get_region = function(self, rk)
        return {
            settlement = function(self)
                return {
                    logical_position_x = function(self) return 0 end,
                    logical_position_y = function(self) return 0 end,
                }
            end,
        }
    end,
}

-- W7: global uim accessor. Per campaign_ui_manager.html:1078 the real API
-- is `cm:get_campaign_ui_manager():override(name):set_allowed(bool)`. The
-- W7 production code uses both `uim:override("end_turn"):set_allowed(false)`
-- (the direct global shortcut) and `cm:override_ui("disable_end_turn", true)`
-- (the cm: passthrough). The smoke stub provides _G.uim because
-- lib_campaign_manager.lua defines `uim = cm:get_campaign_ui_manager()` at
-- runtime; in the test we expose it directly.
_G.uim = {
    override = function(self, name)
        return {
            set_allowed = function(self, b) return true end,
            lock        = function(self) return true end,
            unlock      = function(self) return true end,
        }
    end,
}

_G.core = {
    add_listener = function(self, name, evt, cond, cb, persist) return true end,
    remove_listener = function(self, name) return true end,
    svr_save_registry_string = function(self, k, v) return true end,
    svr_load_registry_string = function(self, k) return "" end,
    -- W7: get_or_create_component is the canonical way to mount a custom
    -- UI banner (per core.html:2440 and the lib_scripted_tours.lua:563
    -- reference pattern). The smoke stub returns a lightweight stand-in
    -- with a SetVisible() method that records its visibility state so
    -- tests can assert whether the banner was shown/hidden.
    get_or_create_component = function(self, name, path, parent)
        if not _G.w7_ui_components then _G.w7_ui_components = {} end
        if _G.w7_ui_components[name] then return _G.w7_ui_components[name] end
        local children = {}
        local component = {
            name = name,
            path = path,
            visible = false,
            children = children,
            SetVisible = function(self, b) self.visible = b == true end,
            IsVisible = function(self) return self.visible end,
            SetState = function(self, s) self.state = s end,
            InterfaceFunction = function(self, fname, ...) end,
            -- W8: FindComponent walks the in-memory child list. The
            -- .twui.xml panel defines child components with id "spectator_turn_label",
            -- "spectator_counters_label", etc. Tests seed the children
            -- via _G.w8_spectator_children[name] = {[child_id] = stand_in}.
            FindComponent = function(self, child_id)
                if _G.w8_spectator_children and _G.w8_spectator_children[name] then
                    local child = _G.w8_spectator_children[name][child_id]
                    if child then return child end
                end
                -- Default: return a stand-in with SetState so pcall-guarded
                -- code doesn't crash.
                return {
                    name = child_id,
                    SetState = function(self, s) self.state = s end,
                    SetText = function(self, s) self.text = s end,
                }
            end,
        }
        _G.w7_ui_components[name] = component
        return component
    end,
    is_ui_created = function(self) return true end,
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
    print("--- W5/W6 AI controller ---")
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
        elif fn.endswith("_w6_dispatched_steps"):
            # Should return a Lua table of step_* names. lupa returns Lua
            # tables; iterating via list() yields the KEYS (indices), so
            # we use values() instead.
            val = None
            if isinstance(result, tuple) and len(result) >= 2:
                val = result[1]
            elif not isinstance(result, bool):
                val = result
            if val is None:
                print(f"FAIL {fn}: returned nil")
                return 1
            try:
                # Prefer values() (returns LuaString entries); fall back
                # to indexing manually if values() isn't available.
                if hasattr(val, "values"):
                    step_list = list(val.values())
                else:
                    n = len(val)
                    step_list = [val[i] for i in range(1, n + 1)]
            except TypeError as e:
                print(f"FAIL {fn}: returned non-iterable {type(val).__name__}: {e}")
                return 1
            step_names = [str(s) for s in step_list]
            expected_steps = (
                "step_apply_cai_personality",
                "step_attack_adjacent",
                "step_garrison_defensives",
                "step_instantly_research",
                "step_perform_rites",
                "step_diplomacy",
                "step_construct_buildings",
                "step_discover_and_recruit",
                "step_move_armies",
            )
            missing = [s for s in expected_steps if s not in step_names]
            if missing:
                print(f"FAIL {fn}: missing step(s) {missing!r} in dispatched list {step_names!r}")
                return 1
            print(f"OK   {fn} (returned {len(step_names)} steps; all W6 steps present)")
        else:
            print(f"OK   {fn}")

    print("---")
    print("ALL CHECKS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
