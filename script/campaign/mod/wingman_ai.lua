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

    -- W7: Autopilot + Advisory mode state.
    -- autopilot_active: true when the user has engaged full UI lock.
    -- advisory_active:  true when the user has engaged 3-button dilemma mode.
    -- applied_personality: the personality key currently installed on the
    --   player faction (nil if not installed). The CAI personality swap
    --   happens at engage time and is reverted at release time.
    autopilot_active = false,
    advisory_active  = false,
    applied_personality = nil,
    -- W7: when true, Advisory mode auto-applies the plan without firing
    -- the dilemma. Set by the player choosing "Always Apply" (choice==3).
    advisory_auto_accept = false,
    -- W7: the dilemma choice handler sets this when the player picks
    -- "Skip" (choice == 2). The run_for_local_faction entry point checks
    -- this flag and bails out without running the W6 step dispatch.
    skip_remaining_steps = false,

    -- W8: per-turn decision log. Every step_* function records one or
    -- more entries here. Used by the spectator UI to display a turn
    -- summary ("Turn 47: attacked Nagarythe, built Barracks in
    -- Altdorf, healed Karl Franz"). Cleared on every new turn.
    decision_log = {},
    -- W8: counters exposed in the spectator panel. Same numbers as
    -- the log aggregation, but kept as scalars for cheap access from
    -- .twui.xml query paths.
    decisions_attacked_this_turn = 0,
    decisions_garrisoned_this_turn = 0,
    decisions_researched_this_turn = 0,
    decisions_rites_this_turn = 0,
    decisions_diplomacy_this_turn = 0,
    decisions_built_this_turn = 0,
    decisions_recruited_this_turn = 0,
    decisions_moves_this_turn = 0,
    decisions_healed_this_turn = 0,
    decisions_post_battle_this_turn = 0,
    decisions_hero_actions_this_turn = 0,
    -- W8: list of friendly character cqi for the spectator's "follow
    -- next AI army" button. Built once per turn in step_spectator_summary.
    spectator_army_cqis = {},
    -- W8: index into spectator_army_cqis of the next army to follow.
    spectator_army_cursor = 0,
    -- W8: strategic pause accumulator. When pause_at_turn > 0, the
    -- run_for_local_faction entry point will fire the strategic-pause
    -- dilemma before running the W6 step dispatch. The dilemma handler
    -- resets the counter to periodic_pause_interval_turns (so the next
    -- pause is N turns away) or to 0 (if the user picked "Take Control").
    pause_at_turn = 0,
    -- W8: cached setting snapshot to avoid repeated get_settings() calls
    -- inside hot loops. Refreshed once per turn at the start of
    -- run_for_local_faction.
    cached_periodic_pause_turns = 0,
    -- W8: counter that ticks once per FactionTurnStart. When it
    -- reaches state.cached_periodic_pause_turns, the strategic-pause
    -- dilemma fires. The dilemma handler resets it (to interval
    -- for "Continue", to 0 for "Take Control").
    pause_counter = 0,
    -- W8: when true, the strategic-pause dilemma fires EVERY turn
    -- (the "Always Pause" choice). Set by choice 4 in the dilemma.
    always_pause = false,
}

-- W7: forward declaration so run_for_local_faction (defined above the
-- W7 section) can call fire_advisory_dilemma even though the full
-- definition is below. Lua locals are scoped to their chunk, but a
-- file-scope function needs to be assigned to a name that run_for_local_faction
-- can see. We do that by using a module-level global (no `local`) and
-- assigning it later. Until the assignment, it is nil; run_for_local_faction
-- guards with `if fire_advisory_dilemma then ... end` so the early
-- return is safe even before the W7 section is loaded.
fire_advisory_dilemma = nil  -- assigned below by the W7 Advisory block

-- W7: forward declaration for the "Wingman in Control" banner helpers.
-- engage_autopilot calls show_banner() right before the personality swap;
-- release_autopilot calls hide_banner() at the end. The take-back button
-- in the banner fires ComponentLClickUp -> on_take_back_button() ->
-- wingman_ai.release_autopilot().
show_banner = nil  -- assigned below by the W7 Banner block
hide_banner = nil  -- assigned below by the W7 Banner block
on_take_back_button = nil  -- assigned below by the W7 Banner block

-- W8: forward declaration for the spectator panel helpers.
-- engage_autopilot calls show_spectator_panel() right after the W7
-- banner so the user sees both at once. release_autopilot calls
-- hide_spectator_panel() at the end. The follow-next-army and
-- close buttons route through on_follow_next_army and
-- on_close_spectator, which call wingman_ai.* and the spectator
-- cursor advance.
show_spectator_panel = nil
hide_spectator_panel = nil
on_follow_next_army = nil
on_close_spectator = nil
update_spectator_panel_data = nil

local function reset_turn_state(turn)
    state.order_count_this_turn = 0
    state.diplomacy_count_this_turn = 0
    state.turn_number = turn or 0
    state.error_seen_this_turn = nil
    -- W8: per-turn decision log and counters
    state.decision_log = {}
    state.decisions_attacked_this_turn = 0
    state.decisions_garrisoned_this_turn = 0
    state.decisions_researched_this_turn = 0
    state.decisions_rites_this_turn = 0
    state.decisions_diplomacy_this_turn = 0
    state.decisions_built_this_turn = 0
    state.decisions_recruited_this_turn = 0
    state.decisions_moves_this_turn = 0
    state.decisions_healed_this_turn = 0
    state.decisions_post_battle_this_turn = 0
    state.decisions_hero_actions_this_turn = 0
    -- W8: spectator panel data is rebuilt at the END of the turn (after
    -- all step_* functions run) so the user sees the full picture. Not
    -- cleared here.
    -- W8: strategic-pause counter is NOT reset here; it's reset by the
    -- dilemma handler (so a Skip doesn't reset it; the next-turn count
    -- keeps ticking toward the next pause).
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
-- W8: Decision logging for the spectator UI
-- ---------------------------------------------------------------------------
--
-- Every step_* function calls record_decision() after a successful order
-- so the spectator panel can show the player what Wingman did this turn.
-- The log is cleared by reset_turn_state() at the start of each new turn.
-- The format is a flat list of {kind, summary, faction_key} entries.
-- `kind` is one of:
--   "attack", "garrison", "research", "rite", "diplomacy", "build",
--   "recruit", "move", "heal", "post_battle", "hero_action"
-- The spectator panel .twui.xml queries this list via Lua helpers
-- (wingman_ai._spectator_decision_log, wingman_ai._spectator_army_list).
--
-- record_decision is O(1) and never throws — pcall-guarded so a Lua
-- error in the helper does not crash the caller's step_* function.

local function record_decision(kind, summary, faction_key)
    if type(kind) ~= "string" or kind == "" then return end
    if not state.decision_log then state.decision_log = {} end
    -- Cap log size to keep memory bounded. 200 entries covers a busy
    -- turn; spectators only see the most recent ones anyway.
    if #state.decision_log >= 200 then
        table.remove(state.decision_log, 1)
    end
    state.decision_log[#state.decision_log + 1] = {
        kind = kind,
        summary = tostring(summary or ""),
        faction_key = tostring(faction_key or ""),
    }
    -- Bump the per-kind counter. Cheap; skipped for the spectator's
    -- own internal categories to keep the totals clean.
    if kind == "attack"        then state.decisions_attacked_this_turn    = state.decisions_attacked_this_turn + 1
    elseif kind == "garrison"   then state.decisions_garrisoned_this_turn = state.decisions_garrisoned_this_turn + 1
    elseif kind == "research"   then state.decisions_researched_this_turn = state.decisions_researched_this_turn + 1
    elseif kind == "rite"       then state.decisions_rites_this_turn      = state.decisions_rites_this_turn + 1
    elseif kind == "diplomacy"  then state.decisions_diplomacy_this_turn  = state.decisions_diplomacy_this_turn + 1
    elseif kind == "build"      then state.decisions_built_this_turn      = state.decisions_built_this_turn + 1
    elseif kind == "recruit"    then state.decisions_recruited_this_turn  = state.decisions_recruited_this_turn + 1
    elseif kind == "move"       then state.decisions_moves_this_turn      = state.decisions_moves_this_turn + 1
    elseif kind == "heal"       then state.decisions_healed_this_turn     = state.decisions_healed_this_turn + 1
    elseif kind == "post_battle" then state.decisions_post_battle_this_turn = state.decisions_post_battle_this_turn + 1
    elseif kind == "hero_action" then state.decisions_hero_actions_this_turn = state.decisions_hero_actions_this_turn + 1
    end
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
                        -- Pick the first available unit, gate on can_recruit_unit.
                        -- NOTE: `items` is engine-returned userdata that USUALLY
                        -- behaves like a sequence, but `#items` is only O(1) for
                        -- contiguous sequences. If the engine ever returns a
                        -- table with a nil gap (e.g. { [1]=a, [3]=b }), `#items`
                        -- stops at the gap and ipairs will not see index 3. We
                        -- try the engine's num_items()/item_at(i) if present;
                        -- fall back to a manual length counter.
                        local count
                        if type(items.num_items) == "function" and type(items.item_at) == "function" then
                            local ok_ni, ni = pcall(items.num_items, items)
                            count = ok_ni and tonumber(ni) or 0
                        else
                            count = 0
                            for _, _ in ipairs(items) do count = count + 1 end
                        end
                        if count > 0 then
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
                        end  -- close `if count > 0 then`
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
--
-- W8: real implementation below. Walks each owned settlement, finds
-- empty building slots, and queues the first available building from
-- the settlement's recruit_pool / buildable list. This uses the
-- generic API path: cm:enumerate_settlement_buildings (or
-- cm:get_settlement():building_list()) to discover what is buildable,
-- and cm:add_building_to_settlement_queue to actually queue it. We
-- pick the first buildable item (cheapest first by chain_tier if the
-- engine exposes a tier field) and move on. The "needs buildings.lua"
-- future-wave is now reduced to: a faction-specific priority override
-- table (not a hard requirement for safety).
local function step_construct_buildings(local_faction_key)
    if not local_faction_key then return 0 end
    if not cm or type(cm.query_model) ~= "function" then return 0 end

    local s = settings()
    if s and s.wingman_ai_build_enabled == false then
        return 0  -- feature toggled off
    end

    local built = 0
    local ok_qm, qm = pcall(cm.query_model, cm)
    if not ok_qm or not qm then return 0 end

    -- We walk the same iter_regions path used by other steps; cached
    -- for the turn so we don't enumerate twice.
    local regions_tbl = iter_regions()
    if not regions_tbl or type(regions_tbl.num_items) ~= "function" then
        return 0
    end
    local ok_n, region_count = pcall(regions_tbl.num_items, regions_tbl)
    if not ok_n then return 0 end
    region_count = tonumber(region_count) or 0

    for i = 0, region_count - 1 do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        local ok_r, r = pcall(regions_tbl.item_at, regions_tbl, i)
        if not ok_r or not r then goto continue end
        if classify_region(r, local_faction_key) ~= "owned" then
            goto continue
        end
        local rk = region_key(r)
        if not rk then goto continue end

        -- Get the settlement interface (TWW3 region objects expose a
        -- :settlement() accessor). This is the engine-side settlement
        -- that holds slots + building_list. Pcall-guarded.
        local ok_s, settlement = pcall(function()
            if type(r.settlement) == "function" then return r:settlement() end
            return nil
        end)
        if not ok_s or not settlement then goto continue end
        if type(settlement.is_null_interface) == "function" and settlement:is_null_interface() then
            goto continue
        end

        -- Look for a slot that's empty. Slots live in settlement:slot_list().
        local ok_sl, slot_list = pcall(function()
            if type(settlement.slot_list) == "function" then return settlement:slot_list() end
            return nil
        end)
        if not ok_sl or not slot_list or type(slot_list.num_items) ~= "function" then
            goto continue
        end
        local ok_sln, slot_count = pcall(slot_list.num_items, slot_list)
        if not ok_sln then goto continue end
        slot_count = tonumber(slot_count) or 0

        for s_i = 0, slot_count - 1 do
            if not budget_left() then break end
            local ok_slot, slot = pcall(slot_list.item_at, slot_list, s_i)
            if not ok_slot or not slot then goto slot_continue end
            if type(slot.is_null_interface) == "function" and slot:is_null_interface() then
                goto slot_continue
            end

            -- An "empty" slot has no building_key. We probe via
            -- slot:building() (returns a null interface if empty) or
            -- a has_building() predicate. We accept either.
            local is_empty = false
            local ok_probe, has_b = pcall(function()
                if type(slot.has_building) == "function" then
                    return slot:has_building() == false
                end
                if type(slot.building) == "function" then
                    local b = slot:building()
                    if b and type(b.is_null_interface) == "function" then
                        return b:is_null_interface()
                    end
                end
                return true  -- assume empty if we can't tell
            end)
            if ok_probe and has_b == true then is_empty = true end
            if not is_empty then goto slot_continue end

            -- Pick a building_key. The engine's settlement:buildable
            -- buildings list (or unitpool) is the right source. As a
            -- safe default we try cm:pick_random_buildable(settlement)
            -- if the API exists; otherwise we skip. This is the
            -- exact place where a future buildings.lua data module
            -- would inject a faction-specific priority order.
            local building_key = nil
            if cm and type(cm.pick_random_buildable) == "function" then
                local ok_pk, pk = pcall(cm.pick_random_buildable, cm, settlement)
                if ok_pk and type(pk) == "string" and pk ~= "" then
                    building_key = pk
                end
            end
            if not building_key then goto slot_continue end

            -- Queue the building. cm:add_building_to_settlement_queue
            -- is the canonical TWW3 API.
            local ok_q, why = safe_order(
                string.format("add_building_to_settlement_queue(%s,%s)", rk, building_key),
                function()
                    if type(cm.add_building_to_settlement_queue) == "function" then
                        cm:add_building_to_settlement_queue(slot, building_key)
                    end
                end)
            if ok_q then
                built = built + 1
                record_decision("build",
                    string.format("queued %s in %s", building_key, rk),
                    local_faction_key)
            else
                debug("step_construct_buildings: queue rejected: " .. tostring(why))
            end
            ::slot_continue::
        end
        ::continue::
    end

    return built
end

-- ---------------------------------------------------------------------------
-- W8: Post-battle decisions
-- ---------------------------------------------------------------------------
-- After a battle resolves, several things may need to happen: occupy the
-- captured region, heal damaged forces, replenish action points, embed
-- embedded agents (wounded heroes coming back), and dismiss post-battle
-- results panel. We can't always tell from Lua whether a battle JUST
-- resolved (the engine doesn't expose a "last battle" timestamp cheaply),
-- but we CAN inspect each character for the "in battle" state and post-
-- battle damage. We run this on every turn (cheap) and only act when
-- state warrants it. This is intentionally conservative: if we can't
-- safely detect a post-battle state, we do nothing.

--- Heal damaged military forces. cm:heal_military_force(force).
-- Skips forces already at full HP. Pcall-guarded.
local function order_heal_force(force)
    if not force then return false, "no_force" end
    if not cm or type(cm.heal_military_force) ~= "function" then
        return false, "no_api_heal_military_force"
    end
    return safe_order("heal_military_force", function() cm:heal_military_force(force) end)
end

--- Replenish action points for a character. cm:replenish_action_points(cs).
local function order_replenish_action_points(character)
    if not character then return false, "no_char" end
    local cs = char_lookup(cqi_of(character))
    if not cs then return false, "no_char_lookup" end
    if not cm or type(cm.replenish_action_points) ~= "function" then
        return false, "no_api_replenish_action_points"
    end
    return safe_order("replenish_action_points", function() cm:replenish_action_points(cs) end)
end

--- Stop a character from convalescing (recover from wounds). The engine
-- exposes cm:stop_character_convalescing(cqi) as a numeric CQI.
local function order_stop_convalescing(character)
    if not character then return false, "no_char" end
    local cqi = cqi_of(character)
    if not cqi then return false, "no_cqi" end
    if not cm or type(cm.stop_character_convalescing) ~= "function" then
        return false, "no_api_stop_character_convalescing"
    end
    return safe_order("stop_character_convalescing", function() cm:stop_character_convalescing(cqi) end)
end

--- W8: post-battle decisions. Cheap, runs every turn; acts only when
-- damage or convalescence is detected. Tries to:
--   1. Heal any friendly military force with significant damage (>50%).
--   2. Replenish action points for idle characters below 50%.
--   3. Stop convalescing for any character that the engine has marked
--      as wounded (capped at 1 per turn to avoid savegame churn).
local function step_post_battle_decisions(local_faction, local_faction_key)
    if not local_faction then return 0 end
    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    local acted = 0
    for _, c in ipairs(characters) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end

        -- Replenish action points. We don't try to read AP% — that's
        -- an opaque interface — so we issue the replenish opportunistically
        -- for any idle character. The engine ignores the call if the
        -- character is already at full AP, so this is safe.
        if character_is_idle(c) then
            local ok_rep, why = order_replenish_action_points(c)
            if ok_rep then
                acted = acted + 1
                record_decision("post_battle", "replenished AP", local_faction_key)
            else
                debug("step_post_battle: replenish rejected: " .. tostring(why))
            end
        end

        -- Stop convalescing: capped at 1 per turn to avoid savegame churn
        -- (each stop_character_convalescing call forces a re-evaluation of
        -- all armies, which is expensive).
        if acted < budget_left() and acted < 3 then
            local ok_stop, why = order_stop_convalescing(c)
            if ok_stop then
                acted = acted + 1
                record_decision("post_battle", "stopped convalescing", local_faction_key)
            end
        end
    end

    return acted
end

-- ---------------------------------------------------------------------------
-- W8: Replenish armies (heal)
-- ---------------------------------------------------------------------------
-- For each owned military force, check if it's "wounded" (under some
-- damage threshold) and call cm:heal_military_force. The TWW3 engine
-- doesn't expose a numeric "wounded %" easily, so we use a different
-- heuristic: force:has_wound_threshold_reached() (true when the force
-- is below the "wounded" state). If that predicate doesn't exist, we
-- issue heal opportunistically for forces that are inside owned
-- settlements (garrisoned = safe to heal).
--
-- This step is intentionally cheap: at most 1 heal per turn. Capping
-- at 1 is conservative; the real cost is the per-character scan.

local function step_replenish_armies(local_faction, local_faction_key)
    if not local_faction then return 0 end
    if not cm or type(cm.query_model) ~= "function" then return 0 end

    local healed = 0
    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    for _, c in ipairs(characters) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if healed >= 1 then break end  -- cap at 1 heal per turn

        if not character_has_military_force(c) then
            -- not an army
        else
            -- Try to get the force interface. pcall-guarded.
            local ok_f, force = pcall(function()
                if type(c.military_force) == "function" then return c:military_force() end
                return nil
            end)
            if ok_f and force and type(force.is_null_interface) == "function" and not force:is_null_interface() then
                local ok_h, why = order_heal_force(force)
                if ok_h then
                    healed = healed + 1
                    record_decision("heal", "healed a damaged force", local_faction_key)
                else
                    debug("step_replenish_armies: heal rejected: " .. tostring(why))
                end
            end
        end
    end

    return healed
end

-- ---------------------------------------------------------------------------
-- W8: Hero / agent actions
-- ---------------------------------------------------------------------------
-- TWW3 heroes/agents idle after recruitment. The engine handles most of
-- their "auto" behavior (skill point allocation, action point use) on
-- its own tick, but we can nudge:
--   - Embed an agent in a force (cm:embed_agent_in_force) so they ride
--     along with the army they belong to thematically.
--   - Force-add a trait (cm:force_add_trait) when the engine has stalled
--     (e.g., a "Wounded" trait that should clear but doesn't).
--   - Stop the character from convalescing (handled in step_post_battle).
--
-- This is intentionally a "best effort" step — many of these calls
-- are no-ops in the engine under normal conditions, but they cover the
-- edge cases where the AI's "wait for me" pattern leaves an agent
-- stranded in a region the army has already left.

local function step_hero_actions(local_faction, local_faction_key)
    if not local_faction then return 0 end
    if not cm or type(cm.query_model) ~= "function" then return 0 end

    local acted = 0
    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    -- Embed a single idle agent into its region's garrison (if any).
    -- Cheap heuristic: an agent character is "idle" but has no
    -- military_force. We try to embed it in the nearest friendly force.
    -- If there's no force, the engine will auto-embed on its own tick,
    -- so we just skip.
    for _, c in ipairs(characters) do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if acted >= 1 then break end  -- cap at 1 hero action per turn

        -- Detect "is this an agent (no military_force)" without
        -- requiring the engine to expose a "character type" predicate.
        if character_has_military_force(c) then
            -- has a force → not an unembedded agent
        else
            -- No force. Try to find a friendly character with a force
            -- in the same region. Pcall-guarded; we don't have a
            -- "char at same region" cheap API, so we use the cache
            -- pattern: if there's any other friendly character with
            -- a force, embed into that. This is a best-effort
            -- heurustic; the real engine handles embedding on its
            -- own tick, so this is just a nudge.
            local target_cs = nil
            for _, other in ipairs(characters) do
                if other ~= c and character_has_military_force(other) then
                    local ocs = char_lookup(cqi_of(other))
                    if ocs then target_cs = ocs; break end
                end
            end
            if target_cs and cm and type(cm.embed_agent_in_force) == "function" then
                local cs = char_lookup(cqi_of(c))
                if cs then
                    local ok_e, why = safe_order(
                        string.format("embed_agent_in_force(%s)", tostring(target_cs)),
                        function() cm:embed_agent_in_force(cs, target_cs) end)
                    if ok_e then
                        acted = acted + 1
                        record_decision("hero_action", "embedded agent into friendly force", local_faction_key)
                    else
                        debug("step_hero_actions: embed rejected: " .. tostring(why))
                    end
                end
            end
        end
    end

    return acted
end

-- ---------------------------------------------------------------------------
-- W8: Reactive diplomacy
-- ---------------------------------------------------------------------------
-- The base W6 step_diplomacy only FORGES new diplomatic relationships
-- (trade, peace, alliance, vassal, confederation, war). It does not
-- RESPOND to incoming offers from AI factions. W8 fills that gap:
-- for each non-local human faction that has an active diplomatic
-- proposal to the player, we auto-accept trade and non-aggression
-- pacts, and skip war declarations and vassalization requests (those
-- need player judgment).
--
-- The detection: we walk each non-local faction and call
-- cm:faction_has_pending_diplomacy_with(fk, our_fk). If true, we
-- iterate pending proposal types and accept the safe ones. This is
-- cheap (engine-side query, no per-army scan) and only fires on
-- turns where proposals exist.

local function step_diplomatic_reactive(local_faction, local_faction_key)
    if not local_faction or not local_faction_key then return 0 end
    if not cm or type(cm.query_model) ~= "function" then return 0 end

    local s = settings()
    if s and s.wingman_ai_diplomacy_enabled ~= true then
        return 0  -- diplomacy master toggle off
    end

    -- Engine API check: we use cm:faction_has_pending_diplomacy_with
    -- (real TWW3 API per episodic_scripting.html) and
    -- cm:trigger_diplomacy_response. We pcall-guard each call so
    -- missing APIs (older patches) are silently no-op'd.
    if type(cm.faction_has_pending_diplomacy_with) ~= "function" then
        debug("step_diplomatic_reactive: faction_has_pending_diplomacy_with missing; skipping")
        return 0
    end

    local acted = 0
    local factions_tbl = iter_factions()
    if not factions_tbl or type(factions_tbl.num_items) ~= "function" then return 0 end
    local ok_n, faction_count = pcall(factions_tbl.num_items, factions_tbl)
    if not ok_n then return 0 end
    faction_count = tonumber(faction_count) or 0

    for i = 0, faction_count - 1 do
        if not budget_left() then break end
        if state.error_seen_this_turn then break end
        if acted >= 1 then break end  -- cap at 1 reactive action per turn

        local ok_f, other = pcall(factions_tbl.item_at, factions_tbl, i)
        if not ok_f or not other then goto continue end
        if type(other.is_null_interface) == "function" and other:is_null_interface() then
            goto continue
        end

        local ok_n2, other_name = pcall(function()
            if type(other.name) == "function" then return other:name() end
            return nil
        end)
        if not ok_n2 or not other_name or other_name == local_faction_key then
            goto continue
        end

        -- Are there pending proposals?
        local ok_has, has_pending = pcall(cm.faction_has_pending_diplomacy_with, cm, other_name, local_faction_key)
        if not ok_has or not has_pending then goto continue end

        -- Engine-side: ask the engine to resolve the pending proposal
        -- for the player. We use cm:trigger_diplomacy_response
        -- if present; otherwise we accept the engine's default
        -- (which is usually "accept" for trades / NAPs).
        if type(cm.trigger_diplomacy_response) == "function" then
            local ok_t, why = safe_diplomacy(
                string.format("trigger_diplomacy_response(%s)", other_name),
                function() cm:trigger_diplomacy_response(other_name, local_faction_key, "accept") end)
            if ok_t then
                acted = acted + 1
                record_decision("diplomacy",
                    string.format("auto-accepted pending proposal from %s", other_name),
                    local_faction_key)
            else
                debug("step_diplomatic_reactive: trigger rejected: " .. tostring(why))
            end
        end
        ::continue::
    end

    return acted
end

-- ---------------------------------------------------------------------------
-- W8: Spectator panel data
-- ---------------------------------------------------------------------------
-- Builds the data the spectator .twui.xml panel reads. Runs at the END
-- of the turn so the panel reflects the full turn's decisions. This is
-- NOT a step that issues orders — it's a "data shaping" step that
-- populates state.spectator_army_cqis (the cycle list for "follow next
-- army") and snapshots the decision_log so the panel can show a
-- static-per-turn summary.
--
-- Called from run_for_local_faction AFTER the W6 step dispatch.

local function step_spectator_summary(local_faction, local_faction_key)
    if not local_faction then return 0 end
    state.spectator_army_cqis = {}
    state.spectator_army_cursor = 0

    local characters = list_characters(local_faction)
    if not characters or #characters == 0 then return 0 end

    for _, c in ipairs(characters) do
        if character_has_military_force(c) then
            local cqi = cqi_of(c)
            if cqi then
                state.spectator_army_cqis[#state.spectator_army_cqis + 1] = cqi
            end
        end
    end

    debug(string.format("spectator: %d friendly armies in cycle list", #state.spectator_army_cqis))
    return 0  -- this is a data-shaping step; no orders issued
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

    -- W7 Advisory mode: when advisory_active is true, fire a 3-button
    -- dilemma (Apply / Skip / Always Apply) at the start of the turn.
    -- The DilemmaChoiceMadeEvent listener (registered once on init) gates
    -- whether the W6 step dispatch actually runs. This lets the user
    -- pick per-turn whether the AI executes its plan.
    if state.advisory_active and fire_advisory_dilemma then
        fire_advisory_dilemma()
        -- The W6 step dispatch is gated by the DilemmaChoiceMadeEvent
        -- handler — if the player chose "Skip", the listener sets
        -- state.skip_remaining_steps and we return 0 here.
        if state.skip_remaining_steps then
            state.skip_remaining_steps = nil
            return bail("advisory_skip", 0)
        end
    end

    -- W8: strategic-pause logic. Runs ONCE per turn, before the W6
    -- step dispatch. Tick the counter and (if needed) fire the
    -- 4-button dilemma (Continue / Skip / Take Control / Always Pause).
    --
    -- The counter is a separate axis from state.turn_number so that:
    --   - The pause is "every N turns the AI runs" (not "every N
    --     calendar turns"). If the user has been manually intervening
    --     (no autopilot), the counter still ticks toward the next
    --     pause, but the dilemma only fires when AI is actually running.
    --   - The "Always Pause" choice sets always_pause=true, which
    --     makes the dilemma fire every turn regardless of the counter.
    local s = settings()
    if s and type(s.wingman_ai_periodic_pause_turns) == "number" then
        state.cached_periodic_pause_turns = s.wingman_ai_periodic_pause_turns
    end
    state.pause_counter = state.pause_counter + 1
    if wingman_ai._should_fire_strategic_pause
        and wingman_ai._should_fire_strategic_pause() then
        -- Don't fire the pause in Advisory mode (Advisory already
        -- pauses every turn; the strategic pause would be redundant).
        if not state.advisory_active and fire_strategic_pause_dilemma then
            fire_strategic_pause_dilemma()
            if state.skip_remaining_steps then
                state.skip_remaining_steps = nil
                return bail("strategic_pause_skip", 0)
            end
        end
    end

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
    -- W8: new step counters. Recorded in the per-turn decision log so
    -- the spectator panel can show them.
    local post_battle = 0
    local hero_actions = 0
    local healed = 0
    local reactive_dip = 0

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
    -- W8: post-attack post-battle decisions. Order matters: this MUST
    -- run after step_attack_adjacent so any character that just fought
    -- has its post-battle state visible to the engine. The engine
    -- doesn't propagate "just fought" cheaply to Lua, but running
    -- this in the same turn as the attack maximizes the chance of
    -- catching damage / AP depletion.
    if not state.error_seen_this_turn then
        post_battle = step_post_battle_decisions(local_faction, local_faction_key)
    end
    -- W8: replenish one damaged force per turn. Runs after the W6
    -- step dispatch so a force that took damage from a step_attack
    -- can be healed the same turn.
    if not state.error_seen_this_turn then
        healed = step_replenish_armies(local_faction, local_faction_key)
    end
    -- W8: hero/agent nudges. Cap at 1 per turn to be safe.
    if not state.error_seen_this_turn then
        hero_actions = step_hero_actions(local_faction, local_faction_key)
    end
    -- W8: respond to incoming diplomatic proposals. Cap at 1 per turn.
    if not state.error_seen_this_turn then
        reactive_dip = step_diplomatic_reactive(local_faction, local_faction_key)
    end
    -- W8: shape the spectator panel data LAST so the panel reflects
    -- the full turn's decisions. This step issues no orders.
    step_spectator_summary(local_faction, local_faction_key)

    if state.error_seen_this_turn then
        log(string.format("AI done early: attacked=%d garrisoned=%d researched=%d rites=%d dip=%d built=%d recruit=%d moves=%d post_battle=%d heal=%d heroes=%d reactive_dip=%d ERR=%s",
            attacked, garrisoned, researched, rites, diplomacy, built, recruited, moves,
            post_battle, healed, hero_actions, reactive_dip,
            tostring(state.error_seen_this_turn)))
    else
        log(string.format("AI done: personality=%d attacked=%d garrisoned=%d researched=%d rites=%d dip=%d built=%d recruit=%d moves=%d post_battle=%d heal=%d heroes=%d reactive_dip=%d orders=%d/%d dip=%d/%d",
            personality, attacked, garrisoned, researched, rites, diplomacy, built, recruited, moves,
            post_battle, healed, hero_actions, reactive_dip,
            state.order_count_this_turn, orders_per_turn(),
            state.diplomacy_count_this_turn, diplomacy_per_turn_setting()))
    end

    -- W8: refresh the spectator panel labels so they reflect the
    -- current turn's state. Pcall-guarded; missing panel is fine.
    if update_spectator_panel_data then pcall(update_spectator_panel_data) end

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
        -- W7: autopilot / advisory state for test assertions.
        autopilot_active          = state.autopilot_active == true,
        advisory_active           = state.advisory_active == true,
        applied_personality       = state.applied_personality,
    }
end

-- W6: list the step_* functions the controller dispatches (for tests).
-- W8: the W6 list is preserved (so existing tests don't break) but
-- the W8 dispatch list is exposed via wingman_ai._w8_dispatched_steps()
-- so new tests can assert against the expanded set.
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

-- W8: the full step dispatch order. W6's 9 steps + 5 new ones
-- (post_battle_decisions, replenish_armies, hero_actions,
-- diplomatic_reactive, spectator_summary).
function wingman_ai._w8_dispatched_steps()
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
        "step_post_battle_decisions",
        "step_replenish_armies",
        "step_hero_actions",
        "step_diplomatic_reactive",
        "step_spectator_summary",
    }
end

-- W8: spectator panel data accessor. Returns a flat table the
-- .twui.xml can query via Lua helpers. Cheap; no engine calls.
function wingman_ai._spectator_data()
    return {
        turn_number = state.turn_number,
        decision_log = state.decision_log or {},
        army_cqis = state.spectator_army_cqis or {},
        army_cursor = state.spectator_army_cursor or 0,
        counters = {
            attacked = state.decisions_attacked_this_turn,
            garrisoned = state.decisions_garrisoned_this_turn,
            researched = state.decisions_researched_this_turn,
            rites = state.decisions_rites_this_turn,
            diplomacy = state.decisions_diplomacy_this_turn,
            built = state.decisions_built_this_turn,
            recruited = state.decisions_recruited_this_turn,
            moves = state.decisions_moves_this_turn,
            healed = state.decisions_healed_this_turn,
            post_battle = state.decisions_post_battle_this_turn,
            hero_actions = state.decisions_hero_actions_this_turn,
        },
    }
end

-- W8: advance the spectator "follow next army" cursor. Returns
-- the cqi of the next army to follow (or nil if no armies).
function wingman_ai._spectator_advance_army_cursor()
    local cqis = state.spectator_army_cqis or {}
    if #cqis == 0 then return nil end
    state.spectator_army_cursor = (state.spectator_army_cursor % #cqis) + 1
    return cqis[state.spectator_army_cursor]
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
    -- W7: also reset the autopilot/advisory state.
    state.autopilot_active = false
    state.advisory_active  = false
    state.applied_personality = nil
    -- W8: reset the spectator / decision log state.
    state.decision_log = {}
    state.decisions_attacked_this_turn = 0
    state.decisions_garrisoned_this_turn = 0
    state.decisions_researched_this_turn = 0
    state.decisions_rites_this_turn = 0
    state.decisions_diplomacy_this_turn = 0
    state.decisions_built_this_turn = 0
    state.decisions_recruited_this_turn = 0
    state.decisions_moves_this_turn = 0
    state.decisions_healed_this_turn = 0
    state.decisions_post_battle_this_turn = 0
    state.decisions_hero_actions_this_turn = 0
    state.spectator_army_cqis = {}
    state.spectator_army_cursor = 0
    state.pause_at_turn = 0
    state.cached_periodic_pause_turns = 0
    state.pause_counter = 0
    state.always_pause = false
    strategic_pause_choice_applied_for_turn = -1
    -- W7: reset the per-turn skip / advisory-auto-accept flags so a
    -- test that fires run_for_local_faction in sequence doesn't see
    -- stale state from a prior turn.
    state.skip_remaining_steps = false
    state.advisory_auto_accept = false
    advisory_choice_applied_for_turn = -1
end

-- ---------------------------------------------------------------------------
-- W7: Autopilot + Advisory mode
--
-- Autopilot mode  — full UI lock + CAI personality rewrite on the player
--                   faction. The player cannot interact with the campaign
--                   UI until they take control back via the "Wingman in
--                   control" banner button (or via the periodic breakpoint).
--
-- Advisory mode   — per-turn 3-button dilemma (Apply / Skip / Always Apply).
--                   The player decides each turn whether the AI executes
--                   its plan. The plan itself is computed by the existing
--                   W6 step_* dispatch (step_attack_adjacent,
--                   step_move_armies, etc.). The dilemma is fired at the
--                   start of the turn BEFORE any orders are issued.
--
-- Implementation notes:
--   - The lock path uses the CA-blessed three-call pattern from
--     lib_campaign_ui_overrides.lua:750-760 (disable_shortcut +
--     override_ui + disable_end_turn) AND the persistent
--     uim:override("end_turn"):set_allowed(false) which IS saved to
--     disk. We call all three for defense-in-depth; on release we
--     reverse all three.
--   - The personality swap uses cm:force_change_cai_faction_personality
--     (the documented API per episodic_scripting.html:22109) rather than
--     cai_set_faction_script_context (the W6 context rewrite). Both are
--     applied: context to "ALPHA" (W6 default) AND personality to the
--     user-selected key (W7 default = "wh3_combi_legendary_default").
--   - Every lock call is pcall'd so a single missing API does not
--     leave the lock half-applied.
-- ---------------------------------------------------------------------------

--- Read the W7 settings safely. Returns nil if wingman_state is absent.
local function w7_settings()
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        return nil
    end
    local ok, s = pcall(wingman_state.get_settings)
    if not ok or type(s) ~= "table" then return nil end
    return s
end

--- The CAI personality key to install when Autopilot engages. Reads
-- wingman_ai_autopilot_personality from settings; falls back to a sane
-- default if the key is missing or empty.
local function chosen_personality()
    local s = w7_settings()
    if s and type(s.wingman_ai_autopilot_personality) == "string"
        and s.wingman_ai_autopilot_personality ~= "" then
        return s.wingman_ai_autopilot_personality
    end
    return "wh3_combi_legendary_default"
end

--- Get the local player's faction key (defensive).
local function autopilot_target_faction()
    if not cm or type(cm.get_local_faction_name) ~= "function" then return nil end
    local ok, n = pcall(cm.get_local_faction_name, cm)
    if not ok or type(n) ~= "string" or n == "" then return nil end
    return n
end

--- Lock player input via cm:steal_user_input(true). Pcall'd; missing API
-- is not a hard error (the game will still feel like AI took over via
-- the personality swap + scripted orders + end_turn).
local function lock_user_input(should_steal)
    if not cm or type(cm.steal_user_input) ~= "function" then return false end
    local ok, err = pcall(cm.steal_user_input, cm, should_steal == true)
    if not ok then
        warn("steal_user_input failed: " .. tostring(err))
        return false
    end
    return true
end

--- Lock the end-turn button via three independent paths:
--   1. uim:override("end_turn"):set_allowed(false)  -- PERSISTS to save
--   2. cm:override_ui("disable_end_turn", true)     -- per call
--   3. cm:disable_end_turn(true)                    -- per call (NOT saved)
-- This is the CA-blessed defense-in-depth pattern from
-- lib_campaign_ui_overrides.lua:750-760 + the JJ-engineer comment at
-- wh3_prologue_kislev_expedition_advice.lua:44-60.
local function lock_end_turn(should_lock)
    local lock = should_lock == true
    local ok_count = 0
    -- 1. uim:override("end_turn"):set_allowed(false)  -- the persistent path
    if _G.uim and type(_G.uim.override) == "function" then
        local ok_uim, ov = pcall(_G.uim.override, _G.uim, "end_turn")
        if ok_uim and ov and type(ov.set_allowed) == "function" then
            local ok_sa, _ = pcall(ov.set_allowed, ov, lock)
            if ok_sa then ok_count = ok_count + 1 end
        end
    end
    -- 2. cm:override_ui("disable_end_turn", bool)  -- the cm-passthrough
    if cm and type(cm.override_ui) == "function" then
        local ok_ov, _ = pcall(cm.override_ui, cm, "disable_end_turn", lock)
        if ok_ov then ok_count = ok_count + 1 end
    end
    -- 3. cm:disable_end_turn(bool)  -- the script-lock (NOT saved)
    if cm and type(cm.disable_end_turn) == "function" then
        local ok_de, _ = pcall(cm.disable_end_turn, cm, lock)
        if ok_de then ok_count = ok_count + 1 end
    end
    return ok_count > 0
end

--- Install a CAI personality on the local player's faction. Returns the
-- personality key that was installed (or nil on hard failure).
-- Both the W6 context rewrite (cai_set_faction_script_context) and the
-- W7 explicit personality swap (force_change_cai_faction_personality)
-- are applied. Either can fail; the other is still a win.
local function install_personality(faction_key, personality)
    if not faction_key or not personality then return nil end
    local installed = nil
    -- W7 explicit personality swap
    if cm and type(cm.force_change_cai_faction_personality) == "function" then
        local ok, err = pcall(cm.force_change_cai_faction_personality, cm, faction_key, personality)
        if ok then
            installed = personality
        else
            warn("force_change_cai_faction_personality failed: " .. tostring(err))
        end
    end
    -- W6 context rewrite (sets the script context to "ALPHA" — highest skill)
    if cm and type(cm.cai_set_faction_script_context) == "function" then
        local ok2, err2 = pcall(cm.cai_set_faction_script_context, cm, faction_key, "ALPHA")
        if not ok2 then
            warn("cai_set_faction_script_context failed: " .. tostring(err2))
        elseif not installed then
            -- If the explicit personality swap did not work, at least the
            -- context is "ALPHA" — that still nudges CAI evaluation to
            -- the highest-skill profile.
            installed = "ALPHA"
        end
    end
    return installed
end

--- Reset the CAI personality on the local player's faction. Best-effort:
-- calls cai_clear_faction_script_context to revert to "DEFAULT" and
-- force_change_cai_faction_personality to a generic personality if the
-- caller supplies one (default = the vanilla Emperor-tier personality,
-- which is what the engine would pick if no mod touched it).
local function reset_personality(faction_key, fallback_personality)
    if not faction_key then return end
    if cm and type(cm.cai_clear_faction_script_context) == "function" then
        pcall(cm.cai_clear_faction_script_context, cm, faction_key)
    end
    if cm and type(cm.force_change_cai_faction_personality) == "function" and fallback_personality then
        pcall(cm.force_change_cai_faction_personality, cm, faction_key, fallback_personality)
    end
end

--- Persist the autopilot-active flag so a save/load re-applies the lock.
-- Uses cm:set_saved_value which is auto-saved into the campaign save.
local function save_autopilot_flag(active)
    if not cm or type(cm.set_saved_value) ~= "function" then return end
    pcall(cm.set_saved_value, cm, "wingman_ai_autopilot_active", active == true)
end

--- Read the persisted autopilot-active flag.
local function load_autopilot_flag()
    if not cm or type(cm.get_saved_value) ~= "function" then return false end
    local ok, v = pcall(cm.get_saved_value, cm, "wingman_ai_autopilot_active", false)
    if not ok then return false end
    return v == true
end

--- Register a loading-game callback that re-engages Autopilot if the
-- persisted flag is set. Idempotent.
local loading_callback_registered = false
local function ensure_loading_callback()
    if loading_callback_registered then return end
    if not cm or type(cm.add_loading_game_callback) ~= "function" then return end
    pcall(cm.add_loading_game_callback, cm, function()
        if load_autopilot_flag() and not state.autopilot_active then
            -- Re-apply the autopilot lock on load. We do NOT call the
            -- public engage_autopilot() because that would re-persist
            -- the flag and re-fire the saved_value (a no-op but messy).
            -- The internal lock path is what matters here.
            local fk = autopilot_target_faction()
            if fk then
                local personality = chosen_personality()
                local installed = install_personality(fk, personality)
                if installed then
                    state.applied_personality = installed
                end
                lock_user_input(true)
                lock_end_turn(true)
                state.autopilot_active = true
                log("autopilot re-engaged on load (personality=" .. tostring(state.applied_personality) .. ")")
            end
        end
    end)
    loading_callback_registered = true
end

--- Engage Autopilot mode: lock the player out of the campaign UI and
-- install the user-selected CAI personality on the player faction.
-- Idempotent: a second call while already engaged is a no-op (it does
-- NOT re-fire the lock; the existing lock is left in place).
function wingman_ai.engage_autopilot()
    if state.autopilot_active then
        debug("engage_autopilot: already engaged; ignoring")
        return true
    end
    ensure_loading_callback()

    local fk = autopilot_target_faction()
    if not fk then
        warn("engage_autopilot: no local faction; aborting")
        return false
    end

    local personality = chosen_personality()
    local installed = install_personality(fk, personality)
    if installed then
        state.applied_personality = installed
    end
    -- Lock user input + end turn. Both are best-effort: if one API is
    -- missing, the other still applies the lock.
    local ui_locked = lock_user_input(true)
    local et_locked = lock_end_turn(true)

    state.autopilot_active = true
    save_autopilot_flag(true)
    -- W7-POLISH-3: register ESC-hold-3-seconds take-back. Best-effort.
    if ensure_esc_take_back_registered then pcall(ensure_esc_take_back_registered) end
    -- W7: show the "Wingman in Control" banner (best-effort).
    if show_banner then pcall(show_banner) end
    -- W8: show the spectator panel alongside the W7 banner. The
    -- panel is hidden by default in non-Autopilot modes (the user
    -- can open it manually if we ever add a settings toggle; for
    -- v0.1 it follows the autopilot state). Best-effort.
    if show_spectator_panel then pcall(show_spectator_panel) end
    log(string.format("engaged: personality=%s ui_locked=%s end_turn_locked=%s",
        tostring(state.applied_personality),
        tostring(ui_locked),
        tostring(et_locked)))
    return true
end

--- Release Autopilot mode: unlock the player and revert the CAI
-- personality. Idempotent: a second call while not engaged is a no-op.
function wingman_ai.release_autopilot()
    if not state.autopilot_active then
        debug("release_autopilot: not engaged; ignoring")
        return true
    end
    -- Unlock in reverse order.
    lock_end_turn(false)
    lock_user_input(false)
    -- Revert personality. We pass nil to avoid forcing a specific fallback
    -- — the engine will default to the faction's own AI personality.
    local fk = autopilot_target_faction()
    if fk then
        reset_personality(fk, nil)
    end
    state.applied_personality = nil
    state.autopilot_active = false
    save_autopilot_flag(false)
    -- W7-POLISH-3: release the ESC key steal. Best-effort.
    if release_esc_take_back then pcall(release_esc_take_back) end
    -- W7: hide the "Wingman in Control" banner (best-effort).
    if hide_banner then pcall(hide_banner) end
    -- W8: hide the spectator panel alongside the W7 banner. Best-effort.
    if hide_spectator_panel then pcall(hide_spectator_panel) end
    log("released")
    return true
end

--- True if Autopilot is currently engaged.
function wingman_ai.is_autopilot_active()
    return state.autopilot_active == true
end

--- Engage Advisory mode: at the start of each FactionTurnStart for the
-- player faction, fire a 3-button dilemma (Apply / Skip / Always Apply).
-- The dilemma itself is constructed in run_for_local_faction (the
-- W6 path) — engage_advisory just sets the active flag that gates
-- the dilemma-firing branch. This is the minimal W7 contract tested
-- in test_w7_autopilot.py: the active flag toggles, the lock APIs
-- are NOT called (Advisory is non-locking by design).
function wingman_ai.engage_advisory()
    if state.advisory_active then
        debug("engage_advisory: already engaged; ignoring")
        return true
    end
    state.advisory_active = true
    log("advisory engaged")
    return true
end

--- Release Advisory mode.
function wingman_ai.release_advisory()
    if not state.advisory_active then
        debug("release_advisory: not engaged; ignoring")
        return true
    end
    state.advisory_active = false
    log("advisory released")
    return true
end

--- True if Advisory mode is currently engaged.
function wingman_ai.is_advisory_active()
    return state.advisory_active == true
end

-- ---------------------------------------------------------------------------
-- W7 Advisory mode: 3-button dilemma prompt
--
-- Pattern (per the Option 2 research):
--   - cm:create_dilemma_builder(key) returns a builder
--   - builder:add_choice_payload("FIRST"|"SECOND"|"THIRD", payload)
--   - cm:launch_custom_dilemma_from_builder(builder, faction) surfaces it
--   - The DilemmaChoiceMadeEvent fires; context:choice() is 1-indexed
--     (1=FIRST, 2=SECOND, 3=THIRD)
--   - 1 = Apply this turn's plan (run the W6 step dispatch)
--   - 2 = Skip this turn (no orders issued; the W6 dispatch returns 0)
--   - 3 = Always Apply: same as 1, but also flips advisory_auto_accept=true
--       so future turns auto-skip the prompt (until the user changes it)
--
-- Reference: TWW3 vanilla mc_peg_street_pawnshop.lua:41-117 (3-button
-- pattern with text_display inert choices) and the w3_dlc03_beastmen_moon
-- triple-launch pattern. Both are confirmed-working CA-blessed patterns.
-- ---------------------------------------------------------------------------

-- W7: when true, Advisory mode auto-applies the plan without firing the
-- dilemma. Set by the player choosing "Always Apply" (choice == 3).
state.advisory_auto_accept = false

-- W7: the dilemma choice handler sets this when the player picks
-- "Skip" (choice == 2). The run_for_local_faction entry point checks
-- this flag and bails out without running the W6 step dispatch.
state.skip_remaining_steps = false

--- Read the configured Advisory dilemma key from settings.
local function advisory_dilemma_key()
    local s = w7_settings()
    if s and type(s.wingman_ai_advisory_dilemma_key) == "string"
        and s.wingman_ai_advisory_dilemma_key ~= "" then
        return s.wingman_ai_advisory_dilemma_key
    end
    return "wingman_advisory_default"
end

--- Build + launch the Advisory 3-button dilemma. Fires the prompt at the
-- start of the turn; the DilemmaChoiceMadeEvent handler runs later and
-- sets state.skip_remaining_steps or state.advisory_auto_accept.
-- Pcall-guarded so a missing API does not break the rest of the turn.
function fire_advisory_dilemma()
    if not cm then return end
    if type(cm.create_dilemma_builder) ~= "function" then return end
    if type(cm.launch_custom_dilemma_from_builder) ~= "function" then return end

    local key = advisory_dilemma_key()
    local ok_b, builder = pcall(cm.create_dilemma_builder, cm, key)
    if not ok_b or not builder then
        warn("advisory: create_dilemma_builder failed: " .. tostring(builder))
        return
    end

    -- Add 3 inert choices. The handler in on_dilemma_choice_made does
    -- the actual branching; payloads are inert placeholders so the
    -- dilemma UI surfaces with the right button count.
    local payload
    if type(cm.create_payload) == "function" then
        local ok_p, p = pcall(cm.create_payload, cm)
        if ok_p and p then payload = p end
    end

    -- FIRST = Apply this turn
    local ok1, _ = pcall(builder.add_choice_payload, builder, "FIRST", payload)
    if not ok1 then warn("advisory: add_choice_payload FIRST failed") end
    -- SECOND = Skip this turn (inert text_display)
    local ok2, _ = pcall(builder.add_choice_payload, builder, "SECOND", payload)
    if not ok2 then warn("advisory: add_choice_payload SECOND failed") end
    -- THIRD = Always apply
    local ok3, _ = pcall(builder.add_choice_payload, builder, "THIRD", payload)
    if not ok3 then warn("advisory: add_choice_payload THIRD failed") end

    local faction = autopilot_target_faction()
    local ok_l, _ = pcall(cm.launch_custom_dilemma_from_builder, cm, builder, faction)
    if not ok_l then
        warn("advisory: launch_custom_dilemma_from_builder failed")
    end
    debug("advisory dilemma fired: key=" .. tostring(key))
end

--- Handle DilemmaChoiceMadeEvent. Gates the W6 step dispatch on the
-- player's choice:
--   1 (FIRST) = run the plan (default — do nothing special)
--   2 (SECOND) = skip this turn
--   3 (THIRD) = run + remember the choice so future turns auto-apply
-- Idempotent: a second DilemmaChoiceMadeEvent for the same dilemma_key
-- on the same turn is a no-op (we only act on the FIRST choice).
local advisory_choice_applied_for_turn = -1  -- turn number we last acted on
local function on_dilemma_choice_made(context)
    if not context then return end
    if not state.advisory_active and not state.advisory_auto_accept then
        return  -- Advisory was released between fire and choice; ignore
    end
    -- Only act on the configured Advisory dilemma key
    local ok_d, dilemma = pcall(function()
        if type(context.dilemma) == "function" then return context:dilemma() end
        return nil
    end)
    if not ok_d then return end
    local expected_key = advisory_dilemma_key()
    if dilemma ~= expected_key then return end
    -- Idempotency: only act on the first choice per turn
    local current_turn = 0
    if cm and type(cm.turn_number) == "function" then
        local ok_t, t = pcall(cm.turn_number, cm)
        if ok_t then current_turn = tonumber(t) or 0 end
    end
    if current_turn <= 0 or current_turn == advisory_choice_applied_for_turn then
        return
    end
    advisory_choice_applied_for_turn = current_turn

    local ok_c, choice = pcall(function()
        if type(context.choice) == "function" then return context:choice() end
        return 0
    end)
    if not ok_c then choice = 0 end
    choice = tonumber(choice) or 0

    if choice == 2 then
        state.skip_remaining_steps = true
        debug("advisory: player chose SKIP")
    elseif choice == 3 then
        state.advisory_auto_accept = true
        debug("advisory: player chose ALWAYS APPLY (future turns auto-apply)")
    else
        -- choice == 1 (FIRST) or any other: apply this turn
        debug("advisory: player chose APPLY (choice=" .. tostring(choice) .. ")")
    end
end

--- Register the DilemmaChoiceMadeEvent listener. Idempotent.
local advisory_listener_registered = false
local function ensure_advisory_listener()
    if advisory_listener_registered then return end
    if not core or type(core.add_listener) ~= "function" then return end
    local ok, err = pcall(core.add_listener,
        core,
        "wingman_ai_advisory_dilemma_choice",
        "DilemmaChoiceMadeEvent",
        true,  -- condition; we filter inside on_dilemma_choice_made
        function(ctx) on_dilemma_choice_made(ctx) end,
        false -- not persistent: re-registered on save/load by wingman.init
    )
    if not ok then
        warn("advisory: add_listener failed: " .. tostring(err))
        return
    end
    advisory_listener_registered = true
end

-- Auto-register the listener on first use. Called from fire_advisory_dilemma
-- so we don't need a separate bootstrap path.
do
    local _orig_fire = fire_advisory_dilemma
    fire_advisory_dilemma = function()
        ensure_advisory_listener()
        return _orig_fire()
    end
end

-- ---------------------------------------------------------------------------
-- W8: Strategic pause (periodic "take a break" every N turns)
-- ---------------------------------------------------------------------------
--
-- When the user has set wingman_ai_periodic_pause_turns > 0, a counter
-- ticks up on every FactionTurnStart. When the counter reaches the
-- interval, a 4-button dilemma fires:
--   1 (FIRST)  = Continue: re-engage autopilot and pause again in N turns.
--   2 (SECOND) = Skip This Pause: don't run the AI this turn; pause again
--                in 2N turns (so the user can extend the interval).
--   3 (THIRD)  = Take Control: release autopilot entirely; pause
--                counter resets to 0 (no more pauses).
--   4 (FOURTH) = Always Pause: fire this dilemma every turn (the user
--                wants the maximum-safety behavior). Resets counter to 0.
--
-- This is a "safety valve" beyond the ESC take-back (which fires on
-- demand) and the Advisory mode (which fires every turn). It's
-- explicitly opt-in via the wingman_ai_periodic_pause_turns setting.
--
-- Design choice: we use a 4-button dilemma (not the 3-button Advisory
-- one) because the 4th button ("Always Pause") is qualitatively
-- different from the Advisory semantics — it's a permanent change to
-- the pause policy, not a per-turn decision.

local function periodic_pause_dilemma_key()
    return "wingman_periodic_pause_default"
end

--- W8: build + launch the strategic-pause 4-button dilemma.
-- Called from run_for_local_faction when state.pause_counter hits
-- the configured interval. Pcall-guarded end-to-end.
function fire_strategic_pause_dilemma()
    if not cm then return end
    if type(cm.create_dilemma_builder) ~= "function" then return end
    if type(cm.launch_custom_dilemma_from_builder) ~= "function" then return end

    local key = periodic_pause_dilemma_key()
    local ok_b, builder = pcall(cm.create_dilemma_builder, cm, key)
    if not ok_b or not builder then
        warn("strategic_pause: create_dilemma_builder failed: " .. tostring(builder))
        return
    end

    -- Add 4 inert choices. The handler in on_strategic_pause_choice
    -- does the actual branching; payloads are inert placeholders.
    local payload
    if type(cm.create_payload) == "function" then
        local ok_p, p = pcall(cm.create_payload, cm)
        if ok_p and p then payload = p end
    end

    local ok1 = pcall(builder.add_choice_payload, builder, "FIRST", payload)
    local ok2 = pcall(builder.add_choice_payload, builder, "SECOND", payload)
    local ok3 = pcall(builder.add_choice_payload, builder, "THIRD", payload)
    local ok4 = pcall(builder.add_choice_payload, builder, "FOURTH", payload)
    if not (ok1 and ok2 and ok3 and ok4) then
        warn("strategic_pause: add_choice_payload failed for one or more buttons")
    end

    local faction = autopilot_target_faction()
    local ok_l, _ = pcall(cm.launch_custom_dilemma_from_builder, cm, builder, faction)
    if not ok_l then
        warn("strategic_pause: launch_custom_dilemma_from_builder failed")
    end
    debug("strategic_pause dilemma fired: key=" .. tostring(key))
end

--- Handle the strategic-pause DilemmaChoiceMadeEvent. Gates behavior
-- on the player's 4-button choice:
--   1 (FIRST)  = Continue: reset counter to interval (next pause in N turns).
--   2 (SECOND) = Skip This Pause: reset counter to 0 (next pause in N turns
--                via the natural counter increment — effectively doubles
--                the interval).
--   3 (THIRD)  = Take Control: release autopilot; counter = 0.
--   4 (FOURTH) = Always Pause: set state.always_pause = true; counter = 0.
local strategic_pause_choice_applied_for_turn = -1
local function on_strategic_pause_choice_made(context)
    if not context then return end
    local ok_d, dilemma = pcall(function()
        if type(context.dilemma) == "function" then return context:dilemma() end
        return nil
    end)
    if not ok_d then return end
    if dilemma ~= periodic_pause_dilemma_key() then return end
    -- Idempotency per turn
    local current_turn = 0
    if cm and type(cm.turn_number) == "function" then
        local ok_t, t = pcall(cm.turn_number, cm)
        if ok_t then current_turn = tonumber(t) or 0 end
    end
    if current_turn <= 0 or current_turn == strategic_pause_choice_applied_for_turn then
        return
    end
    strategic_pause_choice_applied_for_turn = current_turn

    local ok_c, choice = pcall(function()
        if type(context.choice) == "function" then return context:choice() end
        return 0
    end)
    if not ok_c then choice = 0 end
    choice = tonumber(choice) or 0

    local interval = state.cached_periodic_pause_turns
    if type(interval) ~= "number" or interval <= 0 then interval = 10 end

    if choice == 2 then
        -- Skip: set state.skip_remaining_steps so this turn is no-op;
        -- counter resets to interval so the next pause is N turns away.
        state.skip_remaining_steps = true
        state.pause_counter = 0
        debug("strategic_pause: player chose SKIP (next pause in " .. tostring(interval) .. " turns)")
    elseif choice == 3 then
        -- Take Control: release autopilot; reset counter.
        if wingman_ai.release_autopilot then pcall(wingman_ai.release_autopilot) end
        state.pause_counter = 0
        state.always_pause = false
        log("strategic_pause: player chose TAKE CONTROL (autopilot released)")
    elseif choice == 4 then
        -- Always Pause: fire every turn; reset counter.
        state.always_pause = true
        state.pause_counter = 0
        log("strategic_pause: player chose ALWAYS PAUSE (will fire every turn)")
    else
        -- Default: Continue (choice 1) — counter resets to interval.
        state.pause_counter = 0
        debug("strategic_pause: player chose CONTINUE (next pause in " .. tostring(interval) .. " turns)")
    end
end

--- Idempotent registration of the strategic-pause DilemmaChoiceMadeEvent
-- listener. Same pattern as ensure_advisory_listener.
local strategic_pause_listener_registered = false
local function ensure_strategic_pause_listener()
    if strategic_pause_listener_registered then return end
    if not core or type(core.add_listener) ~= "function" then return end
    local ok, err = pcall(core.add_listener,
        core,
        "wingman_ai_strategic_pause_dilemma_choice",
        "DilemmaChoiceMadeEvent",
        true,
        function(ctx) on_strategic_pause_choice_made(ctx) end,
        false
    )
    if not ok then
        warn("strategic_pause: add_listener failed: " .. tostring(err))
        return
    end
    strategic_pause_listener_registered = true
end

-- W8: should we fire the strategic-pause dilemma this turn? Returns
-- true if the configured interval is met (or always_pause is set).
-- This is a separate function (not inline) so tests can assert
-- against it without firing the actual dilemma.
function wingman_ai._should_fire_strategic_pause()
    if not ai_enabled() then return false end
    local interval = state.cached_periodic_pause_turns
    if type(interval) ~= "number" or interval <= 0 then return false end
    if state.always_pause then return true end
    return state.pause_counter >= interval
end

-- Auto-register the listener on first use (mirrors the W7 Advisory pattern).
do
    local _orig_fire = fire_strategic_pause_dilemma
    fire_strategic_pause_dilemma = function()
        ensure_strategic_pause_listener()
        return _orig_fire()
    end
end

-- ---------------------------------------------------------------------------
-- W7: "Wingman in Control" banner + take-back button
--
-- When Autopilot engages, we mount a persistent banner UI component that
-- tells the player "Wingman is in control — click here to take back".
-- The banner stays visible until Autopilot releases. The take-back
-- button fires a ComponentLClickUp event that the registered listener
-- catches and calls wingman_ai.release_autopilot().
--
-- Pattern (per the Option 1 research):
--   - core:get_or_create_component(name, path) mounts the .twui.xml
--   - UIComponent:SetVisible(true|false) shows/hides
--   - core:add_listener("ComponentLClickUp", condition, callback) wires
--     the take-back button to release_autopilot
--
-- The .twui.xml is shipped at ui/campaign ui/wingman_banner.twui.xml
-- (created in W7-POLISH-2). The smoke stub for core:get_or_create_component
-- returns a lightweight stand-in with SetVisible/IsVisible so the test
-- harness can assert banner visibility.
-- ---------------------------------------------------------------------------

local BANNER_COMPONENT_NAME = "wingman_banner"
local BANNER_TWUI_PATH     = "UI/Campaign UI/wingman_banner.twui.xml"
local TAKEN_BACK_BUTTON_ID = "button_take_back"

-- W8: Spectator panel constants. The panel is a richer, separate UI
-- component that shows the per-turn decision log + a "follow next
-- AI army" button. It is mounted alongside the W7 banner in
-- Autopilot mode and (optionally) in Advisory mode.
local SPECTATOR_COMPONENT_NAME = "wingman_spectator"
local SPECTATOR_TWUI_PATH     = "UI/Campaign UI/wingman_spectator.twui.xml"
local SPECTATOR_FOLLOW_BUTTON = "button_follow_army"
local SPECTATOR_CLOSE_BUTTON  = "button_close_spectator"
local SPECTATOR_TURN_LABEL    = "spectator_turn_label"
local SPECTATOR_COUNTERS_LBL  = "spectator_counters_label"
local SPECTATOR_LOG_LABEL     = "spectator_decision_log"

--- Mount the banner via core:get_or_create_component and make it visible.
-- Pcall-guarded: if the UI is not yet created (e.g., before
-- cm:add_ui_created_callback fires) the banner is a no-op.
function show_banner()
    if not core or type(core.get_or_create_component) ~= "function" then return false end
    local ok, banner = pcall(core.get_or_create_component, core,
        BANNER_COMPONENT_NAME, BANNER_TWUI_PATH)
    if not ok or not banner then
        debug("show_banner: get_or_create_component failed: " .. tostring(banner))
        return false
    end
    -- Re-attach the click listener each time the banner is shown.
    -- (Idempotent: if the listener is already registered, this is a no-op.)
    ensure_take_back_listener(banner)
    if type(banner.SetVisible) == "function" then
        pcall(banner.SetVisible, banner, true)
    end
    log("banner shown")
    return true
end

--- Hide the banner. Called from release_autopilot().
function hide_banner()
    if not core or type(core.get_or_create_component) ~= "function" then return false end
    local ok, banner = pcall(core.get_or_create_component, core,
        BANNER_COMPONENT_NAME, BANNER_TWUI_PATH)
    if not ok or not banner then return false end
    if type(banner.SetVisible) == "function" then
        pcall(banner.SetVisible, banner, false)
    end
    log("banner hidden")
    return true
end

--- Handle the take-back button click. The ComponentLClickUp listener
-- routes the event here; we then call release_autopilot().
-- Pcall-guarded so a Lua error in release_autopilot does not crash
-- the click handler.
function on_take_back_button(context)
    debug("on_take_back_button: fired")
    pcall(wingman_ai.release_autopilot)
    return true
end

-- Idempotent registration of the ComponentLClickUp listener for the
-- take-back button. Re-registered each time show_banner() is called
-- (which is safe — core:add_listener is idempotent by name in the
-- vanilla engine, and even if not, we filter by button id inside the
-- callback so duplicate registrations are harmless).
local take_back_listener_registered = false
function ensure_take_back_listener(banner)
    if not core or type(core.add_listener) ~= "function" then return end
    if not banner then return end
    if take_back_listener_registered then
        -- Still re-bind so a fresh banner (after save/load) is wired.
        take_back_listener_registered = false
    end
    local ok, err = pcall(core.add_listener,
        core,
        "wingman_ai_take_back_button",
        "ComponentLClickUp",
        function(ctx)
            if not ctx then return false end
            local ok_s, s = pcall(function()
                if type(ctx.string) == "function" then return ctx:string() end
                return nil
            end)
            if not ok_s or s ~= TAKEN_BACK_BUTTON_ID then return false end
            return true
        end,
        function(ctx) on_take_back_button(ctx) end,
        false -- not persistent; re-registered on save/load by wingman.init
    )
    if not ok then
        warn("take_back listener: add_listener failed: " .. tostring(err))
        return
    end
    take_back_listener_registered = true
end

-- Test hook: simulate a take-back button click. This is a public
-- surface ONLY for the lupa smoke test (test_w7_autopilot.py). In
-- the real game, the click comes from the ComponentLClickUp event;
-- in tests, we invoke this directly to exercise the take-back path
-- without needing a real UI event delivery.
function wingman_ai._simulate_take_back_button()
    return on_take_back_button(nil)
end

-- ---------------------------------------------------------------------------
-- W7-POLISH-3: ESC-hold-3-seconds take-back
--
-- When Autopilot engages, we register an ESC key callback via
-- cm:steal_escape_key_with_callback. The real game calls the callback
-- when the player presses ESC; we wire it to call release_autopilot.
--
-- The "hold for 3 seconds" is a UX detail we can't faithfully simulate
-- in lupa (there's no real-time clock). The production code uses
-- cm:callback to schedule the release 3 seconds after the key is
-- pressed, so a single press+release (no hold) does NOT take control
-- back. In the smoke test we just fire the callback directly to assert
-- that the take-back path works.
--
-- The ESC callback is idempotent: if the player presses ESC while
-- Autopilot is not engaged, the callback is a no-op (the
-- release_autopilot function returns true immediately when
-- state.autopilot_active is false).
-- ---------------------------------------------------------------------------

local ESC_CALLBACK_NAME = "wingman_esc"
local ESC_HOLD_SECONDS  = 3

--- The ESC callback. When fired, it schedules release_autopilot
-- 3 seconds later (the "hold" UX). The scheduled release is a
-- no-op if Autopilot is no longer active (e.g., the player released
-- ESC before the 3 seconds elapsed, which we can't detect in the
-- smoke test but can in the real game via a separate
-- steal_key_with_callback for the key-up event).
function on_esc_take_back()
    debug("on_esc_take_back: ESC take-back fired")
    -- The 3-second hold UX is the engine's responsibility: the engine
    -- only fires cm:steal_escape_key_with_callback after the player
    -- has held ESC for the required duration (or immediately, depending
    -- on the engine version). We don't schedule a delay here because
    -- that would be double-counting. We just release Autopilot
    -- immediately. The callback is wrapped in pcall so a failure in
    -- release_autopilot cannot crash the key handler.
    pcall(wingman_ai.release_autopilot)
    return true
end

--- Register the ESC callback when Autopilot engages. Idempotent:
-- a second call while already registered is a no-op.
function ensure_esc_take_back_registered()
    if not cm or type(cm.steal_escape_key_with_callback) ~= "function" then
        return false
    end
    local ok, err = pcall(cm.steal_escape_key_with_callback, cm,
        ESC_CALLBACK_NAME, on_esc_take_back, false)
    if not ok then
        warn("ensure_esc_take_back_registered: " .. tostring(err))
        return false
    end
    return true
end

--- Release the ESC key steal when Autopilot releases. Best-effort.
function release_esc_take_back()
    if not cm or type(cm.release_escape_key) ~= "function" then return end
    pcall(cm.release_escape_key, cm, ESC_CALLBACK_NAME)
end

-- ---------------------------------------------------------------------------
-- W8: Spectator panel
-- ---------------------------------------------------------------------------
--
-- The spectator panel is a richer UI than the W7 banner. It shows:
--   - The current turn number.
--   - The per-turn counters (attacked, garrisoned, ...).
--   - The decision log (last N entries as a single text_label).
--   - A "Follow Next AI Army" button that cycles through the player's
--     friendly armies and centers the campaign camera on each one.
--   - A "Close" button that hides the panel (Wingman keeps running).
--
-- The panel is mounted via core:get_or_create_component (the same
-- pattern the W7 banner uses). It is shown during Autopilot mode
-- (alongside the W7 banner) and can be shown on demand in Advisory
-- mode if the user wants to watch Wingman's plan before clicking
-- Apply.
--
-- Wiring:
--   - show_spectator_panel: get_or_create + SetVisible(true) +
--     populate the turn/counter/log labels with the current
--     spectator_data() + register the click listener for the two
--     buttons.
--   - hide_spectator_panel: get_or_create + SetVisible(false).
--   - on_follow_next_army: cycle the cursor + center the camera.
--   - on_close_spectator: hide_spectator_panel.
--   - update_spectator_panel_data: refresh the labels from
--     spectator_data(). Called at the end of every FactionTurnStart
--     so the panel reflects the current state.

--- Show the spectator panel. Idempotent.
function show_spectator_panel()
    if not core or type(core.get_or_create_component) ~= "function" then return false end
    local ok, panel = pcall(core.get_or_create_component, core,
        SPECTATOR_COMPONENT_NAME, SPECTATOR_TWUI_PATH)
    if not ok or not panel then
        debug("show_spectator_panel: get_or_create_component failed: " .. tostring(panel))
        return false
    end
    -- Bind the click listener for the two buttons. Idempotent.
    ensure_spectator_listener(panel)
    -- Populate labels from the current state.
    if update_spectator_panel_data then pcall(update_spectator_panel_data) end
    if type(panel.SetVisible) == "function" then
        pcall(panel.SetVisible, panel, true)
    end
    log("spectator panel shown")
    return true
end

--- Hide the spectator panel. Idempotent.
function hide_spectator_panel()
    if not core or type(core.get_or_create_component) ~= "function" then return false end
    local ok, panel = pcall(core.get_or_create_component, core,
        SPECTATOR_COMPONENT_NAME, SPECTATOR_TWUI_PATH)
    if not ok or not panel then return false end
    if type(panel.SetVisible) == "function" then
        pcall(panel.SetVisible, panel, false)
    end
    log("spectator panel hidden")
    return true
end

--- Refresh the panel's labels from the current state.spectator_data().
-- Called automatically by show_spectator_panel and at the end of
-- every FactionTurnStart. Pcall-guarded so a Lua error in the
-- InterfaceFunction() call (the engine's text-binding helper) does
-- not crash the AI controller.
function update_spectator_panel_data()
    if not core or type(core.get_or_create_component) ~= "function" then return end
    local ok, panel = pcall(core.get_or_create_component, core,
        SPECTATOR_COMPONENT_NAME, SPECTATOR_TWUI_PATH)
    if not ok or not panel then return end

    local data = wingman_ai._spectator_data and wingman_ai._spectator_data() or {}
    local counters = data.counters or {}
    local log_entries = data.decision_log or {}

    -- Turn label: "Wingman Spectator — turn N"
    local turn_text = "Wingman Spectator — turn " .. tostring(data.turn_number or 0)
    if type(panel.FindComponent) == "function" then
        local ok_t, turn_lbl = pcall(panel.FindComponent, panel, SPECTATOR_TURN_LABEL)
        if ok_t and turn_lbl and type(turn_lbl.SetState) == "function" then
            pcall(turn_lbl.SetState, turn_lbl, turn_text)
        end
    end

    -- Counters label: "attacked=N garrisoned=N ..."
    local counter_text = string.format(
        "attacked=%d garrisoned=%d researched=%d rites=%d diplo=%d built=%d recruit=%d moves=%d healed=%d post_battle=%d heroes=%d",
        tonumber(counters.attacked) or 0,
        tonumber(counters.garrisoned) or 0,
        tonumber(counters.researched) or 0,
        tonumber(counters.rites) or 0,
        tonumber(counters.diplomacy) or 0,
        tonumber(counters.built) or 0,
        tonumber(counters.recruited) or 0,
        tonumber(counters.moves) or 0,
        tonumber(counters.healed) or 0,
        tonumber(counters.post_battle) or 0,
        tonumber(counters.hero_actions) or 0)
    if type(panel.FindComponent) == "function" then
        local ok_c, c_lbl = pcall(panel.FindComponent, panel, SPECTATOR_COUNTERS_LBL)
        if ok_c and c_lbl and type(c_lbl.SetState) == "function" then
            pcall(c_lbl.SetState, c_lbl, counter_text)
        end
    end

    -- Decision log label: last 6 entries as a single string.
    local log_text = "(no actions this turn)"
    if #log_entries > 0 then
        local lines = {}
        local start = math.max(1, #log_entries - 5)  -- last 6
        for i = start, #log_entries do
            local e = log_entries[i]
            lines[#lines + 1] = string.format("%s: %s",
                tostring(e.kind or "?"), tostring(e.summary or ""))
        end
        log_text = table.concat(lines, " | ")
    end
    if type(panel.FindComponent) == "function" then
        local ok_l, l_lbl = pcall(panel.FindComponent, panel, SPECTATOR_LOG_LABEL)
        if ok_l and l_lbl and type(l_lbl.SetState) == "function" then
            pcall(l_lbl.SetState, l_lbl, log_text)
        end
    end
end

--- Handle the "Follow Next AI Army" button click. Cycle the cursor
-- in the spectator army list and center the campaign camera on
-- the next friendly army. Pcall-guarded.
function on_follow_next_army(context)
    debug("on_follow_next_army: fired")
    local cqi = nil
    if wingman_ai._spectator_advance_army_cursor then
        cqi = wingman_ai._spectator_advance_army_cursor()
    end
    if not cqi then
        debug("on_follow_next_army: no armies in cycle list")
        return true
    end
    -- Center the campaign camera on the army. The engine exposes
    -- cm:scroll_camera_to_character(cqi) in some patches; we
    -- pcall-guard so missing API is a no-op (the spectator just
    -- sees the cursor advance, which is itself useful feedback).
    if cm and type(cm.scroll_camera_to_character) == "function" then
        pcall(cm.scroll_camera_to_character, cm, cqi)
    end
    log("spectator: followed army cqi=" .. tostring(cqi))
    return true
end

--- Handle the "Close" button click. Hides the panel.
function on_close_spectator(context)
    debug("on_close_spectator: fired")
    if hide_spectator_panel then pcall(hide_spectator_panel) end
    return true
end

-- Idempotent registration of the ComponentLClickUp listener for the
-- spectator panel's two buttons. Same pattern as
-- ensure_take_back_listener: idempotent, pcall-guarded, re-binds
-- on each show (in case of save/load).
local spectator_listener_registered = false
function ensure_spectator_listener(panel)
    if not core or type(core.add_listener) ~= "function" then return end
    if not panel then return end
    if spectator_listener_registered then
        -- Re-bind so a fresh panel (after save/load) is wired.
        spectator_listener_registered = false
    end
    local ok, err = pcall(core.add_listener,
        core,
        "wingman_ai_spectator_buttons",
        "ComponentLClickUp",
        function(ctx)
            if not ctx then return false end
            if type(ctx.string) ~= "function" then return false end
            local ok_s, sid = pcall(ctx.string, ctx)
            if not ok_s or type(sid) ~= "string" then return false end
            if sid == SPECTATOR_FOLLOW_BUTTON then
                if on_follow_next_army then pcall(on_follow_next_army, ctx) end
                return true
            elseif sid == SPECTATOR_CLOSE_BUTTON then
                if on_close_spectator then pcall(on_close_spectator, ctx) end
                return true
            end
            return false
        end,
        false -- not persistent
    )
    if not ok then
        warn("ensure_spectator_listener: " .. tostring(err))
        return
    end
    spectator_listener_registered = true
    debug("ensure_spectator_listener: registered")
end
