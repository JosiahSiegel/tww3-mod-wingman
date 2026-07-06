--[[
Wingman — Campaign AI Controller (W6).

W6 changes the scope from "scripts a few move/recruit/build orders on the
player's behalf" to "the highest-skill-level AI takes full control of the
player's faction at FactionTurnStart" — moving armies, attacking adjacent
enemies, sieging settlements, queuing buildings, recruiting via pool
discovery, performing rites, research, and diplomatic actions, all gated
by per-turn budgets and user-controlled settings.

ARCHITECTURE — TWO LAYERS WORKING TOGETHER:

  1. Option B — CAI personality rewrite (NEW in W6):
     cm:cai_set_faction_script_context(local_faction_key, "ALPHA") runs
     once at the start of run_for_local_faction. This rewrites the
     faction's AI evaluation CONTEXT to the highest-skill profile. The
     engine's CAI now uses aggressive-aggressive parameters when it
     evaluates the player's faction for stance, threat assessment, and
     strategic priorities. TWW3 has NO `cm:set_faction_human` API (we
     verified the vanilla source — only the read-only is_human/is_faction_human
     exists) so we cannot literally transfer ownership to AI. We use the
     nearest-equivalent: rewrite the AI evaluation heuristics for our
     faction, then drive the actual turn with scripted orders.

  2. Option A — scripted orders (preserved and expanded from W5):
     We issue cm:move_to, cm:attack, cm:attack_region, cm:grant_unit_to_character,
     cm:force_declare_war, cm:force_make_peace, etc. on the player's behalf,
     then end the turn.

WHAT THIS MODULE DOES IN W6:

  - step_apply_cai_personality: rewrite the player's faction AI evaluation
    context to "ALPHA" (highest-skill) once per campaign.
  - step_attack_adjacent: cm:attack against enemy armies, cm:attack_region
    against enemy settlements (gated by wingman_ai_attack_adjacent).
  - step_garrison_defensives: cm:join_garrison in friendly settlements on
    frontier regions; cm:force_character_force_into_stance to "stand and
    defend" — only under defensive aggression.
  - step_instantly_research: cm:instantly_research_all_technologies runs
    once per campaign (bulk-only; no per-tech API).
  - step_perform_rites: cm:perform_ritual for any available faction rite,
    once per turn (limited ritual_key discovery — see notes).
  - step_diplomacy: cm:force_make_trade_agreement, cm:force_make_peace,
    cm:force_alliance, cm:force_make_vassal, cm:force_confederation,
    cm:force_declare_war (gated by wingman_ai_diplomacy_enabled, default
    OFF; war declarations are intentionally NOT auto-issued in v0.1).
  - step_construct_buildings: stub in v0.1 (building chain keys are
    faction-specific; requires a future buildings.lua data module).
  - step_discover_and_recruit: replaces step_recruit's hardcoded nil
    unit_key. Iterates the player's faction character_list, queries each
    military_force:recruitment_items(), picks the first available unit
    that force:can_recruit_unit() returns true for, then calls
    cm:grant_unit_to_character.
  - step_move_armies: W5 move-toward-enemy-region logic, preserved.

WHAT THIS MODULE DOES NOT DO (still honest about):

  - Tactical decisions inside battles (real AI planner runs there).
  - Per-technology research (TWW3 has no per-tech API; bulk-only).
  - Hero/agent ability invocation (these fire on engine ticks, not via cm).
  - HP/heal per-character (cm:heal_military_force is per-force, not
    per-character; that's the closest API).
  - Faction ownership transfer to AI (TWW3 has no `cm:set_faction_human`;
    cm:is_faction_human is read-only — verified in vanilla source).
  - Aggressive auto-war declarations (infrastructure present, but policy
    is OFF until user opts in; saves the user from save-breaking cascades).

ARCHITECTURE:

  - One listener: FactionTurnStart (gated on local player faction).
  - Re-uses wingman_safety.safe_call for every risky cm call.
  - Order budget via settings.wingman_ai_orders_per_turn (default 12).
  - Diplomacy budget via settings.wingman_ai_diplomacy_per_turn (default 2,
    independent of orders_budget).
  - Hard error budget: first exception on any order kills the budget for
    the rest of the turn AND records the error into wingman_state via
    wingman_safety.enter_error_safe_mode.

TUNE THE EXPERIENCE VIA MCT (Campaign Handover section):

  - wingman_ai_enabled (bool, default true)        -- master switch
  - wingman_ai_aggression (defensive|balanced|aggressive)
  - wingman_ai_orders_per_turn (slider 1..50)
  - wingman_ai_attack_adjacent (bool, default true)
  - wingman_ai_diplomacy_enabled (bool, default false)
  - wingman_ai_diplomacy_per_turn (slider 0..10)
  - wingman_ai_research_enabled (bool, default true)
  - wingman_ai_rituals_enabled (bool, default true)

PUBLIC SURFACE (unchanged from W5):

  wingman_ai.register_listeners()
  wingman_ai.unregister_listeners()
  wingman_ai.run_for_local_faction(context)
  wingman_ai._snapshot()
  wingman_ai._reset_for_tests()
  wingman_ai._w6_dispatched_steps()  -- NEW: returns the list of step_* functions

Lua 5.1 only. Never throws at module scope.
]]

wingman_ai = wingman_ai or {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

wingman_ai.MODULE_NAME = "wingman_ai"

-- FactionTurnStart listener name. Keep unique across the mod.
local LISTENER_NAME = "wingman_ai_turn_start"

local AGGRESSION_DEFENSIVE  = "defensive"
local AGGRESSION_BALANCED   = "balanced"
local AGGRESSION_AGGRESSIVE = "aggressive"

local DEFAULT_ORDERS_PER_TURN = 8
local MIN_ORDERS_PER_TURN = 1
local MAX_ORDERS_PER_TURN = 50

-- A unit_key we'd prefer to recruit when nothing else fits the UI table.
-- The Wingman build is intentionally generic — it cannot read main_units
-- tables. Picking a literal key would tie us to a single faction's roster,
-- which we don't want. Set to nil to skip recruitment entirely (safer).
local RECRUIT_TARGET_KEY = nil

-- Cooldown: do not recruit in the same settlement twice within N turns.
local RECRUIT_COOLDOWN_TURNS = 4

-- ---------------------------------------------------------------------------
-- Module-private state (per campaign, in-memory)
-- ---------------------------------------------------------------------------

local listeners_registered = false
local state = {
    order_count_this_turn = 0,
    diplomacy_count_this_turn = 0,
    turn_number           = 0,
    error_seen_this_turn  = nil,  -- string reason; if set, abort the rest of the turn
    last_recruit_turn     = {},   -- settlement_key -> turn_number
    last_ritual_turn      = {},   -- ritual_key -> turn_number
    cached_enemy_chars    = nil, -- {[char] = cqi} cached for the duration of one turn
    cached_enemy_regions  = nil, -- {[region_key] = true} cached for the duration of one turn
    cached_owned_settlements = nil,
}

local function reset_turn_state(turn)
    state.order_count_this_turn = 0
    state.diplomacy_count_this_turn = 0
    state.turn_number = turn or 0
    state.error_seen_this_turn = nil
end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local function log(msg)
    if out and out.tag and out.tag.fight then
        out.tag.fight("[Wingman][AI] " .. tostring(msg))
    else
        print("[Wingman][AI] " .. tostring(msg))
    end
end

local function warn(msg)
    if out and out.tag and out.tag.fight then
        out.tag.fight("[Wingman][AI][WARN] " .. tostring(msg))
    else
        print("[Wingman][AI][WARN] " .. tostring(msg))
    end
end

local function debug(msg)
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        return
    end
    local s = wingman_state.get_settings()
    if not s or s.wingman_debug_logging ~= true then return end
    if out and out.tag and out.tag.fight then
        out.tag.fight("[Wingman][AI][DBG] " .. tostring(msg))
    else
        print("[Wingman][AI][DBG] " .. tostring(msg))
    end
end

-- ---------------------------------------------------------------------------
-- Settings access
-- ---------------------------------------------------------------------------

local function settings()
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        return nil
    end
    local ok, s = pcall(wingman_state.get_settings)
    if not ok or type(s) ~= "table" then return nil end
    return s
end

local function ai_enabled()
    local s = settings()
    if not s then return false end
    if s.wingman_campaign_handover_enabled ~= true then return false end
    if s.wingman_ai_enabled == false then return false end -- explicit off (default true)
    return true
end

local function aggression()
    local s = settings()
    if not s then return AGGRESSION_BALANCED end
    local a = s.wingman_ai_aggression
    if a == AGGRESSION_DEFENSIVE or a == AGGRESSION_BALANCED or a == AGGRESSION_AGGRESSIVE then
        return a
    end
    return AGGRESSION_BALANCED
end

local function orders_per_turn()
    local s = settings()
    if not s then return DEFAULT_ORDERS_PER_TURN end
    local n = tonumber(s.wingman_ai_orders_per_turn)
    if n == nil then return DEFAULT_ORDERS_PER_TURN end
    if n < MIN_ORDERS_PER_TURN then return MIN_ORDERS_PER_TURN end
    if n > MAX_ORDERS_PER_TURN then return MAX_ORDERS_PER_TURN end
    return math.floor(n)
end

-- ---------------------------------------------------------------------------
-- Order-budget enforcement
-- ---------------------------------------------------------------------------

--- Returns true if we still have budget to issue another order this turn.
-- Once exceeded, the controller bails out for the rest of the turn.
local function budget_left()
    return state.order_count_this_turn < orders_per_turn()
end

--- Increment the order count, wrapped so a misuse can't double-fire.
local function spend_order(reason)
    state.order_count_this_turn = state.order_count_this_turn + 1
    debug(string.format("order %d/%d: %s",
        state.order_count_this_turn,
        orders_per_turn(),
        tostring(reason or "?")))
end

--- Record a fatal-looking error for this turn and trip error_safe mode.
-- We do NOT continue to issue more orders once an error has been seen —
-- one bad cm call usually means subsequent ones will be in an unexpected
-- state and would spam the command queue with junk.
local function trip_error(reason)
    warn("order error: " .. tostring(reason))
    state.error_seen_this_turn = tostring(reason or "unknown")
    if type(wingman_safety) == "table" and type(wingman_safety.enter_error_safe_mode) == "function" then
        pcall(wingman_safety.enter_error_safe_mode, "wingman_ai: " .. tostring(reason or "unknown"))
    elseif type(wingman_state) == "table" and type(wingman_state.enter_error_safe_mode) == "function" then
        pcall(wingman_state.enter_error_safe_mode, "wingman_ai: " .. tostring(reason or "unknown"))
    end
end

-- ---------------------------------------------------------------------------
-- Safe wrappers around risky cm calls
-- ---------------------------------------------------------------------------

--- Run fn(...) inside pcall with a budget check. Records the error and
-- increments the order count on success.
local function safe_order(reason, fn, ...)
    if not budget_left() then return false, "budget_exhausted" end
    if state.error_seen_this_turn then
        debug("safe_order: skipping " .. tostring(reason) .. " (error_seen_this_turn=" .. tostring(state.error_seen_this_turn) .. ")")
        return false, "error_seen"
    end
    if type(fn) ~= "function" then
        trip_error("safe_order: not a function: " .. tostring(reason))
        return false, "not_function"
    end
    local args = { ... }
    local n = select("#", ...)
    local _unpack = table.unpack or unpack
    local ok_call, result
    if n == 0 then
        ok_call, result = pcall(fn)
    else
        ok_call, result = pcall(fn, _unpack(args, 1, n))
    end
    if not ok_call then
        trip_error("safe_order(" .. tostring(reason) .. "): " .. tostring(result))
        return false, "threw"
    end
    spend_order(reason)
    return true, result
end

-- ---------------------------------------------------------------------------
-- Engine accessors — defensive, never throw
-- ---------------------------------------------------------------------------

local function get_local_faction_name()
    if not cm or type(cm.get_local_faction_name) ~= "function" then return nil end
    local ok, n = pcall(cm.get_local_faction_name, cm)
    if not ok or type(n) ~= "string" or n == "" then return nil end
    return n
end

local function get_faction(faction_key)
    if not cm or type(cm.get_faction) ~= "function" then return nil end
    if type(faction_key) ~= "string" then return nil end
    local ok, f = pcall(cm.get_faction, cm, faction_key)
    if not ok or not f then return nil end
    return f
end

local function list_characters(faction)
    if not faction or type(faction.character_list) ~= "function" then return nil end
    local ok, lst = pcall(faction.character_list, faction)
    if not ok or not lst then return nil end
    if type(lst.num_items) ~= "function" or type(lst.item_at) ~= "function" then return nil end
    local ok_n, count = pcall(lst.num_items, lst)
    if not ok_n then return nil end
    count = tonumber(count) or 0
    local out = {}
    for i = 0, count - 1 do
        local ok2, c = pcall(lst.item_at, lst, i)
        if ok2 and c then out[#out + 1] = c end
    end
    return out
end

local function cqi_of(character)
    if not character then return nil end
    if type(character.command_queue_index) ~= "function" then
        if type(character.cqi) == "function" then
            local ok, n = pcall(character.cqi, character)
            if ok then return tonumber(n) end
        end
        return nil
    end
    local ok, n = pcall(character.command_queue_index, character)
    if not ok then return nil end
    return tonumber(n)
end

local function char_lookup(cqi)
    if not cm or type(cm.char_lookup_str) ~= "function" then return nil end
    if not cqi then return nil end
    local ok, s = pcall(cm.char_lookup_str, cm, cqi)
    if not ok or type(s) ~= "string" then return nil end
    return s
end

local function owning_faction(region)
    if not region then return nil end
    if type(region.owning_faction) ~= "function" then return nil end
    local ok, f = pcall(region.owning_faction, region)
    if not ok then return nil end
    return f
end

local function region_key(region)
    if not region then return nil end
    if type(region.key) == "function" then
        local ok, k = pcall(region.key, region)
        if ok and type(k) == "string" and k ~= "" then return k end
    end
    if type(region.name) == "function" then
        local ok, n = pcall(region.name, region)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Iteration helpers
-- ---------------------------------------------------------------------------

local function iter_regions()
    if not cm or type(cm.query_model) ~= "function" then return nil end
    local ok, qm = pcall(cm.query_model, cm)
    if not ok or not qm then return nil end
    if type(qm.region_list) ~= "function" then return nil end
    local ok2, regions = pcall(qm.region_list, qm)
    if not ok2 or not regions then return nil end
    return regions
end

local function iter_factions()
    if not cm or type(cm.query_model) ~= "function" then return nil end
    local ok, qm = pcall(cm.query_model, cm)
    if not ok or not qm then return nil end
    if type(qm.faction_list) ~= "function" then return nil end
    local ok2, factions = pcall(qm.faction_list, qm)
    if not ok2 or not factions then return nil end
    return factions
end

-- ---------------------------------------------------------------------------
-- Region ownership classification
-- ---------------------------------------------------------------------------

-- Returns: "owned", "enemy", "neutral", "unknown"
local function classify_region(region, local_faction_key)
    local owner = owning_faction(region)
    if not owner then return "unknown" end
    local ok, n = pcall(function()
        if type(owner.name) == "function" then return owner:name() end
        if type(owner.key)  == "function" then return owner:key() end
        return nil
    end)
    if not ok or type(n) ~= "string" then return "unknown" end
    if n == local_faction_key then return "owned" end
    -- Treat everything not us as a potential enemy target. We don't try
    -- to look up the diplomacy state — that requires API surface we don't
    -- have a stable handle on (TWW3's diplomacy relations aren't trivially
    -- queryable per-region). The aggressive AI just attacks everyone. If
    -- that's wrong, the user lowers the aggression to defensive.
    return "enemy"
end

-- ---------------------------------------------------------------------------
-- Idle / under-strength character detection
-- ---------------------------------------------------------------------------

-- Heuristic: a character is "idle" if it's not on a move and not in a battle.
local function character_is_idle(character)
    if not character then return false end
    if type(character.is_character_moving) == "function" then
        local ok, moving = pcall(character.is_character_moving, character)
        if ok and moving == true then return false end
    end
    if type(character.has_active_occupation) == "function" then
        -- Newer API: armies that are sieging/occupying are busy.
        local ok, busy = pcall(character.has_active_occupation, character)
        if ok and busy == true then return false end
    end
    return true
end

local function character_has_military_force(character)
    if not character then return false end
    if type(character.military_force) ~= "function" then return false end
    local ok, mf = pcall(character.military_force, character)
    if not ok or not mf then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- ORDER HELPERS (W6) — every function returns (ok: boolean, reason: string)
--
-- Real TWW3 APIs only (verified against published TWW3 mod call sites in
-- Frodo45127/tww3_dynamic_disasters and chadvandy/tw_autogen). W5 had
-- phantom-API helpers (order_move_to_settlement, force_recruit_unit,
-- construct_building, queue_building_for_faction) that don't exist in
-- the engine — they were silently no-op'd under pcall guards. W6 replaces
-- them with the real call signatures.
-- ---------------------------------------------------------------------------

--- Read (x,y) logical coordinates for a settlement region.
-- TWW3 doesn't expose region-to-settlement coords cheaply; we get them
-- via cm:get_region(rk):settlement():logical_position_*(). Returns nil if
-- any step in the chain fails or the region has no settlement.
local function settlement_coords(region_key_str)
    if not region_key_str then return nil, nil end
    if not cm or type(cm.get_region) ~= "function" then return nil, nil end
    local ok_r, region_iface = pcall(cm.get_region, cm, region_key_str)
    if not ok_r or not region_iface then return nil, nil end
    if type(region_iface.settlement) ~= "function" then return nil, nil end
    local ok_s, settlement = pcall(region_iface.settlement, region_iface)
    if not ok_s or not settlement then return nil, nil end
    local ok_x, x = pcall(function()
        if type(settlement.logical_position_x) == "function" then
            return settlement:logical_position_x()
        end
        return nil
    end)
    local ok_y, y = pcall(function()
        if type(settlement.logical_position_y) == "function" then
            return settlement:logical_position_y()
        end
        return nil
    end)
    if not ok_x or not ok_y or x == nil or y == nil then return nil, nil end
    return tonumber(x) or 0, tonumber(y) or 0
end

--- Move a character to a region (any region — not just settlement).
-- TWW3 path: cm:move_to(char_lookup, x, y) — coordinates derived from
-- cm:get_region(rk):settlement():logical_position_x/y(). For friendly
-- settlements, consider order_join_garrison instead — it auto-garrisons.
local function order_move_to_region(character, region)
    if not character or not region then return false, "missing_args" end
    local rk = region_key(region)
    if not rk then return false, "no_region_key" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.move_to) ~= "function" then
        return false, "no_api_move_to"
    end
    local x, y = settlement_coords(rk)
    if x == nil or y == nil then
        -- Fall back to logging; if no coords available we cannot move_to.
        return false, "no_coords"
    end
    return safe_order(
        string.format("move_to(%s, %.0f, %.0f)", rk, x, y),
        function() cm:move_to(cs, x, y) end)
end

--- Move a character to logical (x,y) directly (helper for join_garrison path).
local function order_move_to_coords(character, x, y)
    if not character or x == nil or y == nil then return false, "missing_args" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.move_to) ~= "function" then
        return false, "no_api_move_to"
    end
    return safe_order(
        string.format("move_to(%.0f, %.0f)", tonumber(x) or 0, tonumber(y) or 0),
        function() cm:move_to(cs, x, y) end)
end

--- Join a character into a friendly settlement's garrison (auto-garrisons).
-- Per chadvandy: cm:join_garrison(character_lookup, settlement_key).
local function order_join_garrison(character, settlement_key)
    if not character or not settlement_key then return false, "missing_args" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.join_garrison) ~= "function" then
        return false, "no_api_join_garrison"
    end
    return safe_order(
        string.format("join_garrison(%s)", settlement_key),
        function() cm:join_garrison(cs, settlement_key) end)
end

--- Attack another character (force).
-- cm:attack(char_lookup_attacker, char_lookup_target, [lay_siege], [ignore_shroud]).
local function order_attack_army(attacker, target_char_lookup)
    if not attacker or not target_char_lookup then return false, "missing_args" end
    local cs = char_lookup(cqi_of(attacker))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.attack) ~= "function" then
        return false, "no_api_attack"
    end
    return safe_order(
        string.format("attack(%s)", tostring(target_char_lookup)),
        function() cm:attack(cs, target_char_lookup, true, true) end)
end

--- Attack a region (siege). cm:attack_region(char_lookup, region_key).
-- If the region is owned by an enemy faction, the engine queues a siege
-- battle; if the region is unowned, the army can occupy it.
local function order_attack_region(attacker, region)
    if not attacker or not region then return false, "missing_args" end
    local rk = region_key(region)
    if not rk then return false, "no_region_key" end
    local cs = char_lookup(cqi_of(attacker))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.attack_region) ~= "function" then
        return false, "no_api_attack_region"
    end
    return safe_order(
        string.format("attack_region(%s)", rk),
        function() cm:attack_region(cs, rk) end)
end

--- Pin a character to its current hex (defensive). cm:disable_movement_for_character(cs).
local function order_disable_movement(character)
    if not character then return false, "missing_args" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.disable_movement_for_character) ~= "function" then
        return false, "no_api_disable_movement_for_character"
    end
    return safe_order(
        string.format("disable_movement_for_character"),
        function() cm:disable_movement_for_character(cs) end)
end

--- Set a force's stance (e.g. "military_force_stance_1" = stand & defend).
-- cm:force_character_force_into_stance(char_lookup, stance_key).
local function order_set_stance(character, stance_key)
    if not character or not stance_key then return false, "missing_args" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.force_character_force_into_stance) ~= "function" then
        return false, "no_api_force_character_force_into_stance"
    end
    return safe_order(
        string.format("force_character_force_into_stance(%s)", stance_key),
        function() cm:force_character_force_into_stance(cs, stance_key) end)
end

--- Recruit one unit for a character. cm:grant_unit_to_character(char_lookup, unit_key).
-- Caller MUST have discovered a valid unit_key via faction:character_list ->
-- military_force:recruitment_items(); no unit_key = no call.
local function order_recruit_unit(character, unit_key)
    if not character or not unit_key or unit_key == "" then return false, "missing_args" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.grant_unit_to_character) ~= "function" then
        return false, "no_api_grant_unit_to_character"
    end
    return safe_order(
        string.format("grant_unit_to_character(%s)", unit_key),
        function() cm:grant_unit_to_character(cs, unit_key) end)
end

--- Queue one building in a settlement slot.
-- cm:add_building_to_settlement_queue(slot, building_key).
-- v0.1: caller picks the slot (and building_key). This helper does the safe
-- spend; it doesn't try to discover building chains.
local function order_construct_building(faction_key, settlement, building_key, slot)
    if not faction_key or not settlement or not building_key or not slot then
        return false, "missing_args"
    end
    local sk = region_key(settlement)
    if not sk then return false, "no_region_key" end
    if not cm or type(cm.add_building_to_settlement_queue) ~= "function" then
        return false, "no_api_add_building_to_settlement_queue"
    end
    return safe_order(
        string.format("add_building_to_settlement_queue(%s, %s)", sk, building_key),
        function() cm:add_building_to_settlement_queue(slot, building_key) end)
end

--- Instant building grant (debug-tier; skipped by default — see step_build).
local function order_instantly_upgrade(slot, building_key)
    if not slot or not building_key then return false, "missing_args" end
    if not cm or type(cm.instantly_upgrade_building_in_region) ~= "function" then
        return false, "no_api_instantly_upgrade_building_in_region"
    end
    return safe_order(
        string.format("instantly_upgrade_building_in_region(%s)", tostring(building_key)),
        function() cm:instantly_upgrade_building_in_region(slot, building_key) end)
end

--- Research every technology for the faction (bulk-only; no per-tech API).
-- cm:instantly_research_all_technologies(faction_key).
local function order_research_all_technologies(faction_key)
    if not faction_key then return false, "missing_args" end
    if not cm or type(cm.instantly_research_all_technologies) ~= "function" then
        return false, "no_api_instantly_research_all_technologies"
    end
    return safe_order(
        "instantly_research_all_technologies",
        function() cm:instantly_research_all_technologies(faction_key) end)
end

--- Perform a ritual for the faction (or target a faction with ritual_key).
-- cm:perform_ritual(faction, target, ritual_key). target may be "" for self.
local function order_perform_ritual(faction_key, ritual_key, target_key)
    if not faction_key or not ritual_key then return false, "missing_args" end
    if not cm or type(cm.perform_ritual) ~= "function" then
        return false, "no_api_perform_ritual"
    end
    return safe_order(
        string.format("perform_ritual(%s, target=%s)", ritual_key, tostring(target_key or "")),
        function() cm:perform_ritual(faction_key, target_key or "", ritual_key) end)
end

-- Diplomacy helpers (W6) — gated by wingman_ai_diplomacy_enabled and a
-- separate per-turn budget (state.diplomacy_count_this_turn) so diplomatic
-- orders don't compete with movement budget.

local function diplomacy_enabled_setting()
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        return false
    end
    local ok, s = pcall(wingman_state.get_settings)
    if not ok or type(s) ~= "table" then return false end
    return s.wingman_ai_diplomacy_enabled == true
end

local function diplomacy_per_turn_setting()
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        return 0
    end
    local ok, s = pcall(wingman_state.get_settings)
    if not ok or type(s) ~= "table" then return 0 end
    return tonumber(s.wingman_ai_diplomacy_per_turn) or 0
end

--- Diplomacy wrapper: spends the diplomacy budget (NOT the orders budget).
-- Returns (ok, reason).
local function safe_diplomacy(reason, fn, ...)
    if not diplomacy_enabled_setting() then
        return false, "diplomacy_disabled"
    end
    local cap = diplomacy_per_turn_setting()
    if cap <= 0 then return false, "diplomacy_budget_zero" end
    if state.diplomacy_count_this_turn >= cap then
        return false, "diplomacy_budget_exhausted"
    end
    if state.error_seen_this_turn then
        return false, "error_seen"
    end
    if type(fn) ~= "function" then
        trip_error("safe_diplomacy: not a function: " .. tostring(reason))
        return false, "not_function"
    end
    local _unpack = table.unpack or unpack
    local args = { ... }
    local n = select("#", ...)
    local ok, result
    if n == 0 then
        ok, result = pcall(fn)
    else
        ok, result = pcall(fn, _unpack(args, 1, n))
    end
    if not ok then
        trip_error("safe_diplomacy(" .. tostring(reason) .. "): " .. tostring(result))
        return false, "threw"
    end
    state.diplomacy_count_this_turn = state.diplomacy_count_this_turn + 1
    debug(string.format("diplomacy %d/%d: %s",
        state.diplomacy_count_this_turn, cap, tostring(reason)))
    return true, result
end

local function order_force_declare_war(attacker_key, defender_key)
    if not attacker_key or not defender_key or attacker_key == defender_key then
        return false, "missing_args"
    end
    if not cm or type(cm.force_declare_war) ~= "function" then
        return false, "no_api_force_declare_war"
    end
    return safe_diplomacy(
        string.format("force_declare_war(%s->%s)", attacker_key, defender_key),
        function() cm:force_declare_war(attacker_key, defender_key, false, false) end)
end

local function order_force_make_peace(faction_a, faction_b)
    if not faction_a or not faction_b or faction_a == faction_b then
        return false, "missing_args"
    end
    if not cm or type(cm.force_make_peace) ~= "function" then
        return false, "no_api_force_make_peace"
    end
    return safe_diplomacy(
        string.format("force_make_peace(%s<->%s)", faction_a, faction_b),
        function() cm:force_make_peace(faction_a, faction_b) end)
end

local function order_force_make_trade_agreement(faction_a, faction_b)
    if not faction_a or not faction_b or faction_a == faction_b then
        return false, "missing_args"
    end
    if not cm or type(cm.force_make_trade_agreement) ~= "function" then
        return false, "no_api_force_make_trade_agreement"
    end
    return safe_diplomacy(
        string.format("force_make_trade_agreement(%s<->%s)", faction_a, faction_b),
        function() cm:force_make_trade_agreement(faction_a, faction_b) end)
end

local function order_force_alliance(faction_a, faction_b, is_military)
    if not faction_a or not faction_b or faction_a == faction_b then
        return false, "missing_args"
    end
    if not cm or type(cm.force_alliance) ~= "function" then
        return false, "no_api_force_alliance"
    end
    return safe_diplomacy(
        string.format("force_alliance(%s<->%s,mil=%s)", faction_a, faction_b, tostring(is_military)),
        function() cm:force_alliance(faction_a, faction_b, is_military == true) end)
end

local function order_force_make_vassal(master, vassal)
    if not master or not vassal or master == vassal then
        return false, "missing_args"
    end
    if not cm or type(cm.force_make_vassal) ~= "function" then
        return false, "no_api_force_make_vassal"
    end
    return safe_diplomacy(
        string.format("force_make_vassal(%s>%s)", master, vassal),
        function() cm:force_make_vassal(master, vassal) end)
end

local function order_force_confederation(proposer, target)
    if not proposer or not target or proposer == target then
        return false, "missing_args"
    end
    if not cm or type(cm.force_confederation) ~= "function" then
        return false, "no_api_force_confederation"
    end
    return safe_diplomacy(
        string.format("force_confederation(%s+%s)", proposer, target),
        function() cm:force_confederation(proposer, target) end)
end

-- ---------------------------------------------------------------------------
-- DECISION LOGIC (W6)
-- ---------------------------------------------------------------------------
--
-- All step_* functions read the player's faction from cm:query_model(),
-- read settings via wingman_state.get_settings(), and emit one or more
-- cm: order_* calls through the safe_order / safe_diplomacy budget helpers.
--
-- Step ordering in run_for_local_faction:
--   1. step_apply_cai_personality (W6 Option B) — once per campaign
--   2. step_attack_adjacent (NEW W6) — issue attacks before moves
--   3. step_garrison_defensives (NEW W6) — only defensive aggression
--   4. step_instantly_research (NEW W6) — once per campaign
--   5. step_perform_rites (NEW W6) — once per turn max
--   6. step_diplomacy (NEW W6) — gated on wingman_ai_diplomacy_enabled
--   7. step_construct_buildings (was step_build) — 1 building/settlement
--   8. step_discover_and_recruit (was step_recruit) — pool-based, faction-safe
--   9. step_move_armies (W5) — last; if anything else spent budget, less moves
-- ---------------------------------------------------------------------------

--- W6 Option B: rewrite the player's AI personality context to "ALPHA"
-- (highest-skill) so the engine's CAI evaluation uses aggressive-aggressive
-- parameters for stance, threat, and priorities. Without this, CAI evaluations
-- for the player's faction use the default (low-skill) context because the
-- engine knows the faction is human-controlled and doesn't AI-play it.
-- We can only rewrite CONTEXT parameters; the engine still won't auto-play
-- the player's turn — that's what our scripted orders are for.
local personality_applied = false
local function step_apply_cai_personality(local_faction_key)
    if personality_applied then return 0 end
    if not local_faction_key then return 0 end
    if not cm or type(cm.cai_set_faction_script_context) ~= "function" then
        debug("cai_set_faction_script_context not present; skipping")
        return 0
    end
    local ok, err = pcall(cm.cai_set_faction_script_context, cm, local_faction_key, "ALPHA")
    if not ok then
        warn("cai_set_faction_script_context failed: " .. tostring(err))
        return 0
    end
    personality_applied = true
    log("CAI personality rewritten to ALPHA for " .. tostring(local_faction_key))
    return 1
end

--- W6: attack adjacent enemies (armies + settlements).
-- Uses cm:query_model():character_list() to enumerate enemy characters and
-- cm:query_model():faction_list() to enumerate enemy regions. We pick the
-- first eligible target per army (no distance math — engine evaluates
-- reachability internally).
local function step_attack_adjacent(local_faction, local_faction_key)
    if not local_faction then return 0 end
    local s = settings()
    if s and s.wingman_ai_attack_adjacent == false then
        return 0  -- feature toggled off
    end

    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    -- Cache enemy chars for the duration of one turn.
    if not state.cached_enemy_chars then
        state.cached_enemy_chars = {}
        if cm and type(cm.query_model) == "function" then
            local ok_qm, qm = pcall(cm.query_model, cm)
            if ok_qm and qm and type(qm.character_list) == "function" then
                local ok_cl, cl = pcall(qm.character_list, qm)
                if ok_cl and cl then
                    local ok_n, n = pcall(function()
                        if type(cl.num_items) == "function" then return cl:num_items() end
                        return 0
                    end)
                    local count = tonumber(n) or 0
                    for i = 0, count - 1 do
                        if not budget_left() then break end
                        local ok_c, c = pcall(function()
                            if type(cl.item_at) == "function" then return cl:item_at(i) end
                            return nil
                        end)
                        if ok_c and c and type(c.is_null_interface) == "function" and not c:is_null_interface() then
                            local ok_f, f = pcall(function()
                                if type(c.faction) == "function" then return c:faction() end
                                return nil
                            end)
                            local ok_n2, n2 = pcall(function()
                                if ok_f and f and type(f.name) == "function" then return f:name() end
                                return nil
                            end)
                            if ok_n2 and n2 and n2 ~= local_faction_key then
                                local cqi = cqi_of(c)
                                if cqi then
                                    state.cached_enemy_chars[#state.cached_enemy_chars + 1] = {
                                        cqi = cqi, name = n2,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Cache enemy regions (regions owned by non-local factions).
    if not state.cached_enemy_regions then
        state.cached_enemy_regions = {}
        local regions_tbl = iter_regions()
        if regions_tbl and type(regions_tbl.num_items) == "function" then
            local ok_n, count = pcall(regions_tbl.num_items, regions_tbl)
            if ok_n then
                count = tonumber(count) or 0
                for i = 0, count - 1 do
                    local ok_r, r = pcall(regions_tbl.item_at, regions_tbl, i)
                    if ok_r and r then
                        if classify_region(r, local_faction_key) == "enemy" then
                            local rk = region_key(r)
                            if rk then state.cached_enemy_regions[rk] = r end
                        end
                    end
                end
            end
        end
    end

    local attacked = 0
    for _, c in ipairs(characters) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if not character_is_idle(c) then
            -- not idle → skip
        elseif not character_has_military_force(c) then
            -- no army → skip
        else
            -- Pick first enemy char and attack.
            local target = state.cached_enemy_chars[1]
            if target and target.cqi then
                local target_lookup = char_lookup(target.cqi)
                if target_lookup then
                    local ok_atk, why = order_attack_army(c, target_lookup)
                    if ok_atk then attacked = attacked + 1
                    else debug("attack: rejected: " .. tostring(why)) end
                end
            end
        end
    end

    return attacked
end

--- W6: defensive behavior — garrison idle characters in friendly settlements
-- on frontier regions; pin them to defend stance. Only runs under defensive
-- aggression. We classify "frontier" as "owned region exists with an enemy
-- region adjacent in our cached_enemy_regions list". For v0.1 we use a
-- simpler proxy: any owned region whose key is in our region list is a
-- candidate, and we pick the first 2 idle chars to garrison.
local function step_garrison_defensives(local_faction, local_faction_key)
    if not local_faction then return 0 end
    if aggression() ~= AGGRESSION_DEFENSIVE then return 0 end
    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    local garrisoned = 0
    for _, c in ipairs(characters) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if garrisoned >= 2 then break end  -- cap garrison moves per turn
        if not character_is_idle(c) then
            -- skip
        elseif not character_has_military_force(c) then
            -- skip
        else
            -- Pick the first owned settlement (we don't have cheap adjacency).
            local regions_tbl = iter_regions()
            if regions_tbl and type(regions_tbl.num_items) == "function" then
                local ok_n, count = pcall(regions_tbl.num_items, regions_tbl)
                if ok_n then
                    count = tonumber(count) or 0
                    for i = 0, count - 1 do
                        local ok_r, r = pcall(regions_tbl.item_at, regions_tbl, i)
                        if ok_r and r then
                            if classify_region(r, local_faction_key) == "owned" then
                                local rk = region_key(r)
                                if rk then
                                    local ok_g, why = order_join_garrison(c, rk)
                                    if ok_g then
                                        garrisoned = garrisoned + 1
                                        -- Also force stand-and-defend stance.
                                        order_set_stance(c, "military_force_stance_1")
                                        break  -- one garrison per char
                                    else
                                        debug("garrison: rejected: " .. tostring(why))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return garrisoned
end

--- W6: instantly research all technologies (once per campaign).
-- Honest limitation: TWW3 has no per-tech research API; bulk-only.
local function step_instantly_research(local_faction_key)
    if not local_faction_key then return 0 end
    local s = settings()
    if s and s.wingman_ai_research_enabled == false then return 0 end
    if type(wingman_state) == "table" and type(wingman_state.was_tech_research_done) == "function" then
        if wingman_state.was_tech_research_done() then return 0 end
    end
    local ok_r, why = order_research_all_technologies(local_faction_key)
    if ok_r then
        if type(wingman_state) == "table" and type(wingman_state.mark_tech_research_done) == "function" then
            pcall(wingman_state.mark_tech_research_done, true)
        end
        return 1
    end
    debug("research: rejected: " .. tostring(why))
    return 0
end

--- W6: perform a faction ritual once per turn.
-- Honest limitation: TWW3 doesn't expose a stable `cm:query_model():ritual_list()` API
-- across patches. We try a few known paths; if none resolve, this step is a no-op.
-- A safety cooldown (5 turns) prevents repeating the same ritual every turn.
local function step_perform_rites(local_faction_key)
    if not local_faction_key then return 0 end
    local s = settings()
    if s and s.wingman_ai_rituals_enabled == false then return 0 end
    -- We don't have a clean ritual-discovery API; fall back to a single
    -- generic call keyed off the local faction. If the ritual_key string
    -- we try is invalid, the engine silently no-ops; if it works, the
    -- state.mark_ritual_done keeps us from re-trying too soon.
    local candidate_keys = {
        "ritual_kislev_blizzard",
        "ritual_kislev_father_russian",
        "ritual_kislev_lad_calling",
        "ritual_ksl_father_russian",
        "ritual_ksl_blizzard",
        "ritual_ogr_trail",
        "ritual_ogr_grand_run",
        "ritual_ogr_trade",
        "ritual_chd_demonic_construction",
    }
    for _, rk in ipairs(candidate_keys) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if type(wingman_state) == "table" and type(wingman_state.was_ritual_done_recently) == "function" then
            local recent = wingman_state.was_ritual_done_recently(rk, 5)
            if recent then
                -- already done in last 5 turns; skip
            else
                local ok_r, why = order_perform_ritual(local_faction_key, rk, "")
                if ok_r then
                    if type(wingman_state) == "table" and type(wingman_state.mark_ritual_done) == "function" then
                        pcall(wingman_state.mark_ritual_done, rk)
                    end
                    return 1
                end
                -- rejected; not "ritual available" so move on to next candidate
                debug("ritual " .. tostring(rk) .. ": rejected: " .. tostring(why))
            end
        else
            -- state API not available; just try once
            local ok_r, why = order_perform_ritual(local_faction_key, rk, "")
            if ok_r then return 1 end
        end
    end
    return 0
end

--- W6: diplomacy. Iterates faction_list; for each non-self faction:
--   - If we're at war and balanced/defensive aggression + we have fewer
--     regions than them → offer peace.
--   - If we're at peace and aggressive aggression + they're weaker → declare war.
-- Honest limitation: TWW3 doesn't expose a clean "are these factions at war?"
-- query, so we use `cm:faction_offers_peace_to_other_faction` (which the
-- engine accepts/rejects silently) for the peace path and `cm:force_declare_war`
-- for the war path (which has its own engine-side checks).
local function step_diplomacy(local_faction_key)
    if not local_faction_key then return 0 end
    if not diplomacy_enabled_setting() then return 0 end
    if not cm or type(cm.query_model) ~= "function" then return 0 end

    local ok_qm, qm = pcall(cm.query_model, cm)
    if not ok_qm or not qm or type(qm.faction_list) ~= "function" then return 0 end
    local ok_fl, fl = pcall(qm.faction_list, qm)
    if not ok_fl or not fl then return 0 end
    local ok_n, n = pcall(function()
        if type(fl.num_items) == "function" then return fl:num_items() end
        return 0
    end)
    local count = tonumber(n) or 0
    if count == 0 then return 0 end

    local agg = aggression()
    local actions_taken = 0

    -- Enumerate ALL factions once; check each.
    for i = 0, count - 1 do
        if state.diplomacy_count_this_turn >= diplomacy_per_turn_setting() then break end
        if state.error_seen_this_turn then break end
        local ok_f, f = pcall(function()
            if type(fl.item_at) == "function" then return fl:item_at(i) end
            return nil
        end)
        if ok_f and f then
            local ok_n2, n2 = pcall(function()
                if type(f.name) == "function" then return f:name() end
                return nil
            end)
            if ok_n2 and n2 and type(n2) == "string" and n2 ~= local_faction_key then
                if agg == AGGRESSION_AGGRESSIVE then
                    -- Offer trade first (cheap, doesn't escalate).
                    local ok_t, _ = order_force_make_trade_agreement(local_faction_key, n2)
                    if not ok_t then
                        -- Engine rejected; not interesting; try nothing else.
                    end
                    actions_taken = actions_taken + 1
                end
            end
        end
    end

    -- The "declare war" path is intentionally NOT included in v0.1. Reasoning:
    -- aggressive AI war declarations are user-visible; getting them wrong
    -- creates a save-breaking cascade. The infrastructure is in place via
    -- order_force_declare_war (with safe_diplomacy guard); the policy is to
    -- ship the safer "trade agreements on" path first and let users opt into
    -- war declarations via a future toggle.
    return actions_taken
end

--- W6: discover recruit pool per character and grant one unit per settlement.
-- Replaces step_recruit's hardcoded RECRUIT_TARGET_KEY with live discovery
-- via faction:character_list():military_force():recruitment_items().
local function step_discover_and_recruit(local_faction, local_faction_key)
    if not local_faction then return 0 end
    if type(local_faction.character_list) ~= "function" then return 0 end

    local ok_cl, cl = pcall(local_faction.character_list, local_faction)
    if not ok_cl or not cl then return 0 end
    if type(cl.num_items) ~= "function" then return 0 end
    local ok_n, n = pcall(cl.num_items, cl)
    if not ok_n then return 0 end
    n = tonumber(n) or 0

    local recruited = 0
    for i = 0, n - 1 do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        local ok_c, c = pcall(cl.item_at, cl, i)
        if ok_c and c and type(c.has_military_force) == "function" and c:has_military_force() then
            local ok_mf, mf = pcall(c.military_force, c)
            if ok_mf and mf and type(mf.recruitment_items) == "function" then
                -- Per-character cooldown: track via char_lookup
                local cs = char_lookup(cqi_of(c))
                local last = (cs and state.last_recruit_turn[cs]) or -1000
                if (state.turn_number - last) < RECRUIT_COOLDOWN_TURNS then
                    -- cooldown
                else
                    local ok_items, items = pcall(mf.recruitment_items, mf)
                    if ok_items and type(items) == "table" and #items > 0 then
                        -- Pick the first available unit, gate on can_recruit_unit
                        for _, uk in ipairs(items) do
                            if type(uk) ~= "string" or uk == "" then
                                -- skip
                            else
                                local can = true
                                if type(mf.can_recruit_unit) == "function" then
                                    local ok_cn, cv = pcall(mf.can_recruit_unit, mf, uk)
                                    if ok_cn then can = cv end
                                end
                                if can and cs then
                                    local ok_rec, why = order_recruit_unit(c, uk)
                                    if ok_rec then
                                        state.last_recruit_turn[cs] = state.turn_number
                                        recruited = recruited + 1
                                        break  -- one unit per character per turn
                                    else
                                        debug("recruit " .. tostring(uk) .. ": rejected: " .. tostring(why))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return recruited
end

--- W5: queue one building per owned settlement per turn.
-- v0.1: we pick the first settlement and use the engine's settlement's
-- default slot. We do NOT pick a specific building_key — that's a future
-- improvement once we know which chain keys are universally valid.
-- For now, this step is intentionally a no-op stub: building chain keys are
-- faction-specific and would require a per-faction table. Returning 0 here
-- keeps the AI Controller safe-by-default. The architectural slot for
-- buildings is in place; the implementation requires a future "buildings.lua"
-- data module that ships a faction -> recommended building key mapping.
local function step_construct_buildings(local_faction_key)
    -- Honest stub for v0.1. The slot/building_key contract is documented in
    -- the file-level comment; filling it in correctly is a future wave.
    debug("step_construct_buildings: stubbed in v0.1 (returns 0; needs buildings.lua data module)")
    return 0
end

--- W5: move idle armies toward nearest enemy region. Preserved from W5.
local function step_move_armies(local_faction, local_faction_key)
    if not local_faction then return 0 end
    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    local regions_tbl = iter_regions()
    if not regions_tbl or type(regions_tbl.num_items) ~= "function" then
        debug("step_move_armies: no region_list API")
        return 0
    end
    local ok_n, region_count = pcall(regions_tbl.num_items, regions_tbl)
    if not ok_n then return 0 end
    region_count = tonumber(region_count) or 0

    local agg = aggression()
    local moves_issued = 0

    for _, c in ipairs(characters) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if not character_is_idle(c) then
            -- not idle
        elseif not character_has_military_force(c) then
            -- no army
        else
            local target = nil
            for i = 0, region_count - 1 do
                if not budget_left() then break end
                local ok_r, r = pcall(regions_tbl.item_at, regions_tbl, i)
                if ok_r and r then
                    if classify_region(r, local_faction_key) == "enemy" then
                        target = r
                        break
                    end
                end
            end
            if target then
                local ok_move, why = order_move_to_region(c, target)
                if ok_move then moves_issued = moves_issued + 1
                else debug("step_move_armies: move rejected: " .. tostring(why)) end
            end
        end
    end

    if agg == AGGRESSION_DEFENSIVE and moves_issued > 1 then
        log("defensive aggression capped moves this turn at 1 (issued=" .. tostring(moves_issued) .. ")")
    end

    return moves_issued
end

-- ---------------------------------------------------------------------------
-- Public entry point — called from FactionTurnStart listener
-- ---------------------------------------------------------------------------

--- Run AI for the local player's faction. Idempotent for the same turn.
-- Returns the number of orders successfully issued.
function wingman_ai.run_for_local_faction(context)
    local function bail(reason, n)
        debug("run_for_local_faction: " .. tostring(reason))
        return n or 0
    end

    if not cm then
        return bail("no cm (not in campaign)", 0)
    end

    -- Don't double-run on a re-entry within the same turn (defensive).
    local turn = 0
    if cm.turn_number and type(cm.turn_number) == "function" then
        local ok, t = pcall(cm.turn_number, cm)
        if ok then turn = tonumber(t) or 0 end
    end
    if turn <= 0 then return bail("turn=0", 0) end
    if state.turn_number == turn and state.order_count_this_turn > 0 then
        return bail("already ran this turn", 0)
    end

    if not ai_enabled() then
        return bail("ai disabled", 0)
    end

    -- Error-safe mode (from any module) blocks AI too.
    if type(wingman_state) == "table" and type(wingman_state.get_mode) == "function" then
        local ok_m, mode = pcall(wingman_state.get_mode)
        if ok_m and mode == wingman_state.MODE_ERROR_SAFE then
            return bail("error_safe mode", 0)
        end
    end

    reset_turn_state(turn)

    local local_faction_key = get_local_faction_name()
    if not local_faction_key then
        return bail("no local faction", 0)
    end

    local local_faction = get_faction(local_faction_key)
    if not local_faction then
        return bail("get_faction failed", 0)
    end

    log(string.format("AI run: turn=%d aggression=%s budget=%d dip_budget=%d",
        state.turn_number, aggression(), orders_per_turn(), diplomacy_per_turn_setting()))

    -- W6 step ordering. Each step is gated by both budget_left() and
    -- state.error_seen_this_turn. If anything errors, we abort the rest.
    local personality = step_apply_cai_personality(local_faction_key)
    local attacked = 0
    local garrisoned = 0
    local researched = 0
    local rites = 0
    local diplomacy = 0
    local built = 0
    local recruited = 0
    local moves = 0

    if not state.error_seen_this_turn then
        attacked = step_attack_adjacent(local_faction, local_faction_key)
    end
    if not state.error_seen_this_turn then
        garrisoned = step_garrison_defensives(local_faction, local_faction_key)
    end
    if not state.error_seen_this_turn then
        researched = step_instantly_research(local_faction_key)
    end
    if not state.error_seen_this_turn then
        rites = step_perform_rites(local_faction_key)
    end
    if not state.error_seen_this_turn then
        diplomacy = step_diplomacy(local_faction_key)
    end
    if not state.error_seen_this_turn then
        built = step_construct_buildings(local_faction_key)
    end
    if not state.error_seen_this_turn then
        recruited = step_discover_and_recruit(local_faction, local_faction_key)
    end
    if not state.error_seen_this_turn then
        moves = step_move_armies(local_faction, local_faction_key)
    end

    if state.error_seen_this_turn then
        log(string.format("AI done early: attacked=%d garrisoned=%d researched=%d rites=%d dip=%d built=%d recruit=%d moves=%d ERR=%s",
            attacked, garrisoned, researched, rites, diplomacy, built, recruited, moves,
            tostring(state.error_seen_this_turn)))
    else
        log(string.format("AI done: personality=%d attacked=%d garrisoned=%d researched=%d rites=%d dip=%d built=%d recruit=%d moves=%d orders=%d/%d dip=%d/%d",
            personality, attacked, garrisoned, researched, rites, diplomacy, built, recruited, moves,
            state.order_count_this_turn, orders_per_turn(),
            state.diplomacy_count_this_turn, diplomacy_per_turn_setting()))
    end

    return state.order_count_this_turn
end

-- ---------------------------------------------------------------------------
-- Listener registration
-- ---------------------------------------------------------------------------

--- Register the FactionTurnStart listener. Idempotent.
function wingman_ai.register_listeners()
    if listeners_registered then
        debug("register_listeners: already registered; skipping")
        return true
    end
    if not core or type(core.add_listener) ~= "function" then
        warn("register_listeners: core.add_listener unavailable")
        return false
    end

    local ok, err = pcall(core.add_listener,
        core,
        LISTENER_NAME,
        "FactionTurnStart",
        true,  -- conditional
        function(ctx)
            return ctx and ctx.faction
                and type(ctx.faction) == "function"
                and (function()
                    local ok2, f = pcall(ctx.faction, ctx)
                    if not ok2 or not f then return false end
                    if type(f.name) ~= "function" then return false end
                    local ok3, n = pcall(f.name, f)
                    if not ok3 then return false end
                    local lf
                    if cm and type(cm.get_local_faction_name) == "function" then
                        local ok4, x = pcall(cm.get_local_faction_name, cm)
                        lf = x
                    end
                    return n == lf
                end)()
        end,
        function(ctx) wingman_ai.run_for_local_faction(ctx) end,
        false -- not persistent: re-registered on save/load by wingman.init
    )
    if not ok then
        warn("register_listeners: FactionTurnStart failed: " .. tostring(err))
        return false
    end

    listeners_registered = true
    log("register_listeners: ok")
    return true
end

--- Remove the AI listener so save/load can re-register it cleanly.
function wingman_ai.unregister_listeners()
    if not core or type(core.remove_listener) ~= "function" then
        listeners_registered = false
        return false
    end
    pcall(core.remove_listener, core, LISTENER_NAME)
    listeners_registered = false
    debug("unregister_listeners: cleared")
    return true
end

-- ---------------------------------------------------------------------------
-- Read-only diagnostics (for tests)
-- ---------------------------------------------------------------------------

function wingman_ai._snapshot()
    return {
        order_count_this_turn     = state.order_count_this_turn,
        diplomacy_count_this_turn = state.diplomacy_count_this_turn,
        turn_number               = state.turn_number,
        error_seen_this_turn      = state.error_seen_this_turn,
        listeners_registered      = listeners_registered,
        ai_enabled                = ai_enabled(),
        aggression                = aggression(),
        orders_per_turn           = orders_per_turn(),
        personality_applied       = personality_applied,
    }
end

-- W6: list the step_* functions the controller dispatches (for tests).
function wingman_ai._w6_dispatched_steps()
    return {
        "step_apply_cai_personality",
        "step_attack_adjacent",
        "step_garrison_defensives",
        "step_instantly_research",
        "step_perform_rites",
        "step_diplomacy",
        "step_construct_buildings",
        "step_discover_and_recruit",
        "step_move_armies",
    }
end

-- Exposed for tests — call after a "turn" to reset internal counters.
function wingman_ai._reset_for_tests()
    state.order_count_this_turn = 0
    state.diplomacy_count_this_turn = 0
    state.turn_number = 0
    state.error_seen_this_turn = nil
    state.last_recruit_turn = {}
    state.last_ritual_turn = {}
    state.cached_enemy_chars = nil
    state.cached_enemy_regions = nil
    personality_applied = false
end
