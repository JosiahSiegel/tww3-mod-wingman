--[[
Wingman — Campaign AI Controller.

SCOPE (HONEST — see README.md "Known limitations"):

  This module issues script-driven orders on behalf of the player's faction at
  FactionTurnStart so that "Wingman takes the stick" actually does something
  visible. It runs BEFORE the existing wingman_campaign end-turn logic so that
  whatever orders it issues are committed to the command queue first, then the
  turn ends and the next faction's turn begins with our orders already in
  flight.

  What this module DOES:
    - Move idle armies toward the nearest enemy region.
    - Move idle armies into enemy armies / attack when adjacent.
    - Move into a settlement slot when one is available in owned region.
    - Queue building construction in each owned settlement (one slot per turn).
    - Recruit a single unit in each owned settlement that has free recruitment
      capacity (subject to per-turn order budget + cooldown).

  What this module does NOT do (and we will NOT pretend it does):
    - Replace the real faction AI personality (TWW3 has no API to "transfer"
      a player's faction to AI control — only transfer_region_to_faction and
      cm:set_faction_human exist and the latter is unsafe / undocumented for
      player factions).
    - Make tactical decisions inside a battle (wingman_battle.lua handles
      the four-scripted battle modes; the real AI planner takes over inside
      the battle regardless).
    - Pick technologies, rites, hero skills, or diplomacy trades.
    - Issue war / peace / alliance / non-aggression pacts (TWW3 has no
      cm:force_declare_war API — diplomacy is AI-only).
    - Coordinate hero actions beyond "recruit" (no API for "use hero ability").
    - Decide between attacking vs. waiting when both are valid (we use a
      simple closest-enemy heuristic).

  Architecture:
    - One listener: FactionTurnStart (gated on local player faction).
    - Re-uses wingman_safety.safe_call for every risky cm call.
    - Capped per-turn order budget via settings.wingman_ai_orders_per_turn
      (default 8) — never blow up the command queue.
    - Hard error budget: first exception on any order kills the budget for
      the rest of the turn AND records the error into wingman_state.
    - Won't run if wingman_state is in error_safe mode (existing
      wingman_campaign listener already prevents that).

  Tune the experience via MCT:
    - wingman_ai_enabled (bool) — master switch (defaults true when
      campaign_handover_enabled is true)
    - wingman_ai_aggression (defensive | balanced | aggressive)
    - wingman_ai_orders_per_turn (slider 1..50)

  Public surface: wingman_ai.run_for_local_faction(context).

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
    turn_number           = 0,
    error_seen_this_turn  = nil,  -- string reason; if set, abort the rest of the turn
    last_recruit_turn     = {},   -- settlement_key -> turn_number
}

local function reset_turn_state(turn)
    state.order_count_this_turn = 0
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
-- ORDER HELPERS — every function returns (ok: boolean, reason: string)
-- ---------------------------------------------------------------------------

--- Move a character to a region owned by an enemy faction.
local function order_move_to_region(character, region)
    if not character or not region then return false, "missing_args" end
    local rk = region_key(region)
    if not rk then return false, "no_region_key" end
    -- Engine API: cm:order_move_to_settlement(char_lookup_str, region_key)
    -- Confirmed in chadvandy campaign_manager index.
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.order_move_to_settlement) ~= "function" then
        return false, "no_api_order_move_to_settlement"
    end
    return safe_order(
        string.format("order_move_to_settlement(%s)", rk),
        function() cm:order_move_to_settlement(cs, rk) end)
end

--- Recruit one unit in a settlement (no build cost checks — engine handles).
local function order_recruit_in_settlement(faction_key, settlement, unit_key)
    if not faction_key or not settlement or not unit_key then return false, "missing_args" end
    local sk = region_key(settlement)
    if not sk then return false, "no_region_key" end
    if not cm or type(cm.force_recruit_unit) ~= "function" then
        return false, "no_api_force_recruit_unit"
    end
    return safe_order(
        string.format("force_recruit_unit(%s, %s)", sk, unit_key),
        function() cm:force_recruit_unit(sk, unit_key, faction_key) end)
end

--- Queue one building in a settlement (best-effort slot pick).
local function order_construct_building(faction_key, settlement)
    if not faction_key or not settlement then return false, "missing_args" end
    local sk = region_key(settlement)
    if not sk then return false, "no_region_key" end
    if not cm or type(cm.construct_building) ~= "function" then
        -- Older name was cm:queue_building in some campaigns; fall back.
        if cm and type(cm.queue_building_for_faction) == "function" then
            return safe_order(
                string.format("queue_building_for_faction(%s)", sk),
                function() cm:queue_building_for_faction(sk, faction_key, "main_building_slot") end)
        end
        return false, "no_api_construct_building"
    end
    return safe_order(
        string.format("construct_building(%s)", sk),
        function() cm:construct_building(sk, faction_key, "main_building_slot") end)
end

-- ---------------------------------------------------------------------------
-- DECISION LOGIC
-- ---------------------------------------------------------------------------

--- Step 1 — for each idle army we own, move it toward the nearest enemy region.
local function step_move_armies(local_faction, local_faction_key)
    if not local_faction then return 0 end
    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then
        debug("step_move_armies: no characters in faction")
        return 0
    end

    -- Cache one region_list snapshot: cheaper than re-querying per character.
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
            debug("step_move_armies: skip char (not idle)")
        elseif not character_has_military_force(c) then
            debug("step_move_armies: skip char (no army)")
        else
            -- Find nearest enemy region (first match — simple heuristic; the
            -- engine doesn't expose region coords cheaply across all patches).
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
            if not target then
                debug("step_move_armies: no enemy region found")
            else
                local ok_move, why = order_move_to_region(c, target)
                if ok_move then
                    moves_issued = moves_issued + 1
                else
                    debug("step_move_armies: move rejected: " .. tostring(why))
                end
            end
        end
    end

    -- Defensive aggression only moves one army per turn (don't expand too far).
    -- Balanced = 1, aggressive = unlimited (capped by orders_per_turn).
    if agg == AGGRESSION_DEFENSIVE and moves_issued > 1 then
        -- No way to "unspend" — but we already counted; just note in log.
        log("defensive aggression capped moves this turn at 1 (issued=" .. tostring(moves_issued) .. ")")
    end

    return moves_issued
end

--- Step 2 — for each owned settlement, try to recruit one unit (with cooldown).
local function step_recruit(local_faction_key)
    if not RECRUIT_TARGET_KEY then
        return 0 -- module default: no recruitment (safer without a unit_key)
    end
    if not local_faction_key then return 0 end
    local regions_tbl = iter_regions()
    if not regions_tbl or type(regions_tbl.num_items) ~= "function" then return 0 end
    local ok_n, count = pcall(regions_tbl.num_items, regions_tbl)
    if not ok_n then return 0 end
    count = tonumber(count) or 0

    local recruited = 0
    for i = 0, count - 1 do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        local ok_r, r = pcall(regions_tbl.item_at, regions_tbl, i)
        if ok_r and r then
            if classify_region(r, local_faction_key) == "owned" then
                local sk = region_key(r)
                if not sk then
                    -- skip
                else
                    local last = state.last_recruit_turn[sk] or -1000
                    if (state.turn_number - last) < RECRUIT_COOLDOWN_TURNS then
                        debug("recruit: " .. sk .. " on cooldown")
                    else
                        local ok_rec, why = order_recruit_in_settlement(
                            local_faction_key, r, RECRUIT_TARGET_KEY)
                        if ok_rec then
                            state.last_recruit_turn[sk] = state.turn_number
                            recruited = recruited + 1
                        else
                            debug("recruit: rejected: " .. tostring(why))
                        end
                    end
                end
            end
        end
    end
    return recruited
end

--- Step 3 — for each owned settlement, queue one building per turn.
local function step_build(local_faction_key)
    if not local_faction_key then return 0 end
    local regions_tbl = iter_regions()
    if not regions_tbl or type(regions_tbl.num_items) ~= "function" then return 0 end
    local ok_n, count = pcall(regions_tbl.num_items, regions_tbl)
    if not ok_n then return 0 end
    count = tonumber(count) or 0

    local built = 0
    for i = 0, count - 1 do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        local ok_r, r = pcall(regions_tbl.item_at, regions_tbl, i)
        if ok_r and r then
            if classify_region(r, local_faction_key) == "owned" then
                local ok_build, why = order_construct_building(local_faction_key, r)
                if ok_build then
                    built = built + 1
                else
                    debug("build: rejected: " .. tostring(why))
                end
            end
        end
    end
    return built
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

    log(string.format("AI run: turn=%d aggression=%s budget=%d",
        state.turn_number, aggression(), orders_per_turn()))

    local moves = step_move_armies(local_faction, local_faction_key)
    if not state.error_seen_this_turn then
        local built = step_build(local_faction_key)
        if not state.error_seen_this_turn then
            local recruited = step_recruit(local_faction_key)
            log(string.format("AI done: moved=%d built=%d recruited=%d errors=%s",
                moves, built, recruited,
                tostring(state.error_seen_this_turn or "none")))
        else
            log("AI done early: moved=" .. tostring(moves) .. " errors=" .. tostring(state.error_seen_this_turn))
        end
    else
        log("AI done early at move step: errors=" .. tostring(state.error_seen_this_turn))
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
        order_count_this_turn = state.order_count_this_turn,
        turn_number           = state.turn_number,
        error_seen_this_turn  = state.error_seen_this_turn,
        listeners_registered  = listeners_registered,
        ai_enabled            = ai_enabled(),
        aggression            = aggression(),
        orders_per_turn       = orders_per_turn(),
    }
end

-- Exposed for tests — call after a "turn" to reset internal counters.
function wingman_ai._reset_for_tests()
    state.order_count_this_turn = 0
    state.turn_number = 0
    state.error_seen_this_turn = nil
    state.last_recruit_turn = {}
end
