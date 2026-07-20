"""Realistic TWW3 engine stubs for tests.

The base lupa_smoke.ENGINE_STUBS is a minimal mock — just enough
to make the modules load. Tests using those stubs miss whole
classes of bugs because the engine surface doesn't match the
real TWW3 API shape.

This module provides a more realistic engine surface that mirrors
the real TWW3 modding API. Tests that need to exercise specific
real-world behavior (multi-faction interactions, region adjacency,
panel events with realistic payloads, etc.) should use the factories
here instead of building their own ad-hoc stubs.

Usage:
    import realistic_engine as re
    lua.execute(re.ENGINE_BLOCK)         # install into Lua state
    lua.execute(re.faction_block("wh_main_emp_empire", faction_state))
    lua.execute(re.region_block(...))
    ...
"""
from __future__ import annotations

from typing import Any


# ---------------------------------------------------------------------------
# Engine wiring: top-level cm/core that match the real TWW3 shape
# ---------------------------------------------------------------------------

# The base engine block. The default state is a "freshly loaded
# campaign with 1 local faction and no armies" — the same as what
# the real engine exposes at FactionTurnStart turn 1.
ENGINE_BLOCK = '''
--[[ Realistic TWW3 engine stubs. Mirrors the real modding API:
     - core: listener registry + UI root
     - cm: campaign model API (get_local_faction_name, get_faction,
       query_model, attack_army, etc.)
     - mission_manager: objective manager
     - out: logging routing
     - _G.engine_state: shared mutable state for tests
]]

_G.engine_state = {
    turn_number = 1,
    -- Map cqi -> char string (cqi is 1..N, char_str is "faction_cqi")
    characters = {},
    -- Map cqi -> { faction, region, has_military_force }
    char_meta = {},
    -- Map char_str -> "alive" | "dead"
    char_status = {},
    -- Map region_key -> { owning_faction, settlement, adjacent }
    regions = {},
    -- Map faction_key -> { alive, diplomacy_with: { [other]: "war"|"peace"|"trade" } }
    factions = {},
    -- Map force_cqi -> { commander_cqi, region }
    forces = {},
}

core = core or {}
core.add_listener = function(self, name, event, conditional, callback, persistent)
    -- No-op; tests that need listener behavior should stub explicitly.
    return true
end
core.remove_listener = function(self, name) return true end
core.get_ui_root = function(self)
    return setmetatable({}, {__index = function() return nil end})
end

cm = cm or {}
cm.is_multiplayer = function(self) return false end
cm.turn_number = function(self)
    return _G.engine_state.turn_number
end
cm.get_local_faction_name = function(self) return "wh_main_emp_empire" end
cm.get_faction = function(self, key)
    local f = _G.engine_state.factions[key]
    if not f or not f.alive then return nil end
    return _make_faction(key, f)
end
cm.attack_army = function(self, a, b) return true end
cm.end_turn = function(self)
    _G.engine_state.turn_number = _G.engine_state.turn_number + 1
    return true
end
cm.force_make_trade_agreement = function(self, faction_a, faction_b) return true end
cm.faction_has_pending_diplomacy_with = function(self, a, b) return false end
cm.trigger_diplomacy_response = function(self, ...) return true end
cm.are_factions_at_war = function(self, a, b)
    local fa = _G.engine_state.factions[a]
    if not fa or not fa.diplomacy_with then return false end
    return fa.diplomacy_with[b] == "war"
end
cm.are_regions_adjacent = function(self, ra, rb)
    local r = _G.engine_state.regions[ra]
    if not r or not r.adjacent then return false end
    for _, adj in ipairs(r.adjacent) do
        if adj == rb then return true end
    end
    return false
end
cm.char_lookup_str = function(self, cqi)
    return "char_" .. tostring(cqi)
end
cm.embed_agent_in_force = function(self, cs, target_cs) return true end
cm.force_add_trait = function(self, cs, trait) return true end
cm.heal_military_force = function(self, force) return true end
cm.force_stop_convalescing = function(self, char) return true end
cm.replenish_action_points = function(self, char) return true end
cm.add_building_to_settlement_queue = function(self, region, building) return true end
cm.instantly_research_all_technologies = function(self, faction) return true end
cm.instantly_upgrade_building_in_region = function(self, region, building) return true end
cm.grant_unit_to_character = function(self, char, unit) return true end
cm.pick_random_buildable = function(self, settlement, slot) return "main_building" end
cm.get_region = function(self, key) return _G.engine_state.regions[key] end

cm.query_model = function(self, model_type)
    if model_type == "region_list" then
        local keys = {}
        for k, _ in pairs(_G.engine_state.regions) do keys[#keys + 1] = k end
        return _make_list(keys)
    elseif model_type == "faction_list" then
        local keys = {}
        for k, f in pairs(_G.engine_state.factions) do
            if f.alive then keys[#keys + 1] = k end
        end
        return _make_list(keys)
    elseif model_type == "character_list" then
        local lfk = cm.get_local_faction_name(cm)
        local chars = {}
        for cqi, meta in pairs(_G.engine_state.char_meta) do
            if meta.faction == lfk and _G.engine_state.char_status["char_" .. cqi] == "alive" then
                chars[#chars + 1] = cqi
            end
        end
        return _make_list(chars)
    elseif model_type == "force_list" then
        local lfk = cm.get_local_faction_name(cm)
        local forces = {}
        for fcqi, f in pairs(_G.engine_state.forces) do
            local cmd_meta = _G.engine_state.char_meta[f.commander_cqi]
            if cmd_meta and cmd_meta.faction == lfk then
                forces[#forces + 1] = fcqi
            end
        end
        return _make_list(forces)
    end
    return nil
end

-- List/iterator helpers. TWW3 uses 1-based item_at — the buggy
-- list_characters in wingman_ai.lua iterated 0..count-1 which
-- skipped the first character. Tests using _make_list must use
-- 1-based indexing to catch regressions.
function _make_list(items)
    return {
        num_items = function(self) return #items end,
        item_at = function(self, i)
            local k = items[i]
            if k == nil then return nil end
            if _G.engine_state.regions[k] then
                return _make_region(k, _G.engine_state.regions[k])
            elseif _G.engine_state.factions[k] then
                return _make_faction(k, _G.engine_state.factions[k])
            elseif _G.engine_state.char_meta[k] then
                return _make_character(tonumber(k))
            elseif _G.engine_state.forces[k] then
                return _make_force(tonumber(k), _G.engine_state.forces[k])
            end
            return nil
        end,
        is_empty = function(self) return #items == 0 end,
    }
end

function _make_faction(key, f)
    return setmetatable({
        name = function(self) return key end,
        faction_is_alive = function(self) return f.alive end,
        character_list = function(self)
            local chars = {}
            for cqi, meta in pairs(_G.engine_state.char_meta) do
                if meta.faction == key then
                    chars[#chars + 1] = cqi
                end
            end
            return _make_list(chars)
        end,
    }, {__index = function(self, k)
        -- Allow faction.turn_x style reads (used by some test stubs).
        if k == "diplomacy" then return f.diplomacy_with or {} end
        if k == "is_player" then return key == cm.get_local_faction_name(cm) end
        return nil
    end})
end

function _make_character(cqi)
    local meta = _G.engine_state.char_meta[cqi]
    if not meta then return nil end
    local self = {
        cqi = function(self) return cqi end,
        command_queue_index = function(self) return cqi end,
        faction = function(self)
            return _make_faction(meta.faction, _G.engine_state.factions[meta.faction])
        end,
        has_military_force = function(self) return meta.has_military_force end,
        military_force = function(self)
            if not meta.has_military_force then return nil end
            for fcqi, f in pairs(_G.engine_state.forces) do
                if f.commander_cqi == cqi then
                    return _make_force(fcqi, f)
                end
            end
            return nil
        end,
        region = function(self) return _G.engine_state.regions[meta.region] end,
        is_valid_intervention_army = function(self) return false end,
        is_at_sea = function(self) return false end,
    }
    return self
end

function _make_force(fcqi, f)
    return {
        force_cqi = function(self) return fcqi end,
        is_null_interface = function(self) return false end,
        has_wound_threshold_reached = function(self) return false end,
        region = function(self) return _G.engine_state.regions[f.region] end,
        commander = function(self) return _make_character(f.commander_cqi) end,
        unit_list = function(self) return _make_list({}) end,
    }
end

function _make_region(key, r)
    return {
        name = function(self) return key end,
        key = function(self) return key end,
        owning_faction = function(self)
            if not r.owning_faction then return nil end
            return _make_faction(r.owning_faction, _G.engine_state.factions[r.owning_faction])
        end,
        settlement = function(self)
            if not r.settlement then return nil end
            return { logical_position_x = function(self) return 100 end,
                     logical_position_y = function(self) return 200 end,
                     name = function(self) return r.settlement end }
        end,
        adjacent_regions = function(self) return _make_list(r.adjacent or {}) end,
        is_abandoned = function(self) return r.owning_faction == nil end,
    }
end

-- mission_manager: real shape returns true on success, false on
-- "could not cancel" (already completed), nil on missing method.
mission_manager = mission_manager or {}
mission_manager.fail_custom_mission = function(self, k)
    if not k or k == "" then return false end
    return true
end
mission_manager.force_scripted_objective_success = function(self, k)
    if not k or k == "" then return false end
    return true
end
mission_manager.create_custom_objective_mission = function(self, ...)
    return "wingman.mission." .. tostring(math.random(1000000))
end

-- out: log routing (real TWW3 exposes out.tag.fight for mod log channels)
out = out or {}
out.tag = out.tag or {}
out.tag.fight = function(msg) _print(msg) end
out.text = out.text or {}
out.text.alert = function(msg) _print(msg) end

function _print(msg)
    -- Real TWW3 prints to the lua-script console; tests capture via
    -- print redirection if needed.
    if _G.test_log_capture then
        _G.test_log_capture[#_G.test_log_capture + 1] = tostring(msg)
    end
end
'''


# ---------------------------------------------------------------------------
# Builder helpers (Python-side) that emit Lua source to populate engine_state
# ---------------------------------------------------------------------------

def faction_block(faction_key: str, *, alive: bool = True,
                  diplomacy_with: dict[str, str] | None = None) -> str:
    """Emit Lua source to register a faction.

    diplomacy_with maps other_faction_key -> "war" | "peace" | "trade".
    """
    dip_lua = "{"
    if diplomacy_with:
        for k, v in diplomacy_with.items():
            dip_lua += f'["{k}"] = "{v}",'
    dip_lua += "}"
    return f'''
_G.engine_state.factions["{faction_key}"] = {{
    alive = {str(alive).lower()},
    diplomacy_with = {dip_lua},
}}
'''


def region_block(region_key: str, *, owning_faction: str | None = None,
                 settlement: str | None = None,
                 adjacent: list[str] | None = None) -> str:
    """Emit Lua source to register a region.

    `adjacent` is a list of region_keys that are adjacent to this one.
    """
    adj_lua = "{" + ",".join(f'"{k}"' for k in (adjacent or [])) + "}"
    return f'''
_G.engine_state.regions["{region_key}"] = {{
    owning_faction = {f'"{owning_faction}"' if owning_faction else "nil"},
    settlement = {f'"{settlement}"' if settlement else "nil"},
    adjacent = {adj_lua},
}}
'''


def character_block(cqi: int, *, faction: str, region: str,
                    has_military_force: bool = False,
                    status: str = "alive") -> str:
    """Emit Lua source to register a character.

    `status` is "alive" (default) or "dead" (any other value).
    """
    return f'''
_G.engine_state.char_meta[{cqi}] = {{
    faction = "{faction}",
    region = "{region}",
    has_military_force = {str(has_military_force).lower()},
}}
_G.engine_state.char_status["char_{cqi}"] = "{status}"
'''


def force_block(force_cqi: int, *, commander_cqi: int, region: str) -> str:
    """Emit Lua source to register a military force."""
    return f'''
_G.engine_state.forces[{force_cqi}] = {{
    commander_cqi = {commander_cqi},
    region = "{region}",
}}
'''


# ---------------------------------------------------------------------------
# Test scenarios — pre-built Lua source for common multi-turn setups
# ---------------------------------------------------------------------------

def scenario_minimal_empire_two_regions() -> str:
    """2 regions, 1 owned by the player, 1 by an AI; 2 characters
    (1 lord with army, 1 agent without). Used to exercise the full
    step dispatch including W6, W7, W8.
    """
    return (
        faction_block("wh_main_emp_empire", alive=True,
                      diplomacy_with={"wh_main_dwf_dwarfs": "peace"})
        + faction_block("wh_main_dwf_dwarfs", alive=True,
                        diplomacy_with={"wh_main_emp_empire": "peace"})
        + region_block("emp_altdorf", owning_faction="wh_main_emp_empire",
                       settlement="altdorf", adjacent=["emp_eicheschafen"])
        + region_block("emp_eicheschafen", owning_faction="wh_main_emp_empire",
                       settlement="eicheschafen", adjacent=["emp_altdorf"])
        + region_block("dwf_karak_izor", owning_faction="wh_main_dwf_dwarfs",
                       settlement="karak_izor", adjacent=["emp_altdorf"])
        + character_block(1, faction="wh_main_emp_empire",
                          region="emp_altdorf", has_military_force=True)
        + character_block(2, faction="wh_main_emp_empire",
                          region="emp_altdorf", has_military_force=False)
        + force_block(100, commander_cqi=1, region="emp_altdorf")
    )


def scenario_no_ai() -> str:
    """Bare campaign: 1 faction, 1 region, 0 characters. Used to verify
    graceful no-op when there's nothing to do.
    """
    return (
        faction_block("wh_main_emp_empire", alive=True)
        + region_block("emp_altdorf", owning_faction="wh_main_emp_empire",
                       settlement="altdorf")
    )


# ---------------------------------------------------------------------------
# Event payload fixtures — match real TWW3 event context shapes
# ---------------------------------------------------------------------------

# The actual `context` table the engine passes to listeners for
# FactionTurnStart. Real shape: { faction = function(self) ... }
FACTION_TURN_START_EVENT = '''
local context = {
    faction = function(self)
        return _make_faction(cm.get_local_faction_name(cm),
            _G.engine_state.factions[cm.get_local_faction_name(cm)])
    end,
    turn_number = function(self) return _G.engine_state.turn_number end,
}
'''

# Real shape of a PanelOpenedCampaign context. The engine passes
# a UI component with a "key" string we extract to determine if
# it's a known modal panel.
def panel_opened_event(panel_key: str) -> str:
    """Return Lua source for a PanelOpenedCampaign context."""
    return f'''
local context = {{
    panel = "{panel_key}",
    ui_component = {{
        Id = function(self) return "{panel_key}" end,
        Visible = function(self) return true end,
    }},
}}
'''

# Real shape of a BattleBeingFought / BattleCompleted context.
# (Used by wingman_battle.lua's listeners.)
BATTLE_BEING_FOUGHT_EVENT = '''
local context = {
    engagement = function(self)
        return {
            attacker = function(self) return _make_character(1) end,
            defender = function(self) return _make_character(99) end,
            has_attacker_won = function(self) return nil end,  -- in-progress
            is_at_sea = function(self) return false end,
            attacker_alliance = function(self) return 1 end,
            defender_alliance = function(self) return 2 end,
            battle_type = function(self) return "land_battle" end,
        }
    end,
}
'''
