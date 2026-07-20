--[[
Wingman — mission-manager builders.

Builds TWW3 missions for the rules engine:
  - Turn-cap mission with optional game_victory payload.
  - Scripted objectives per custom-win settlement / faction requirement.

Mission keys are persisted via wingman_state so settings changes can cancel
the old missions and rebuild cleanly.

Mission framework reference:
  - mission_manager:new(faction_key, mission_key, success_cb, fail_cb,
                        cancel_cb, expiry_cb)
  - mm:set_turn_limit(n)
  - mm:add_payload("game_victory") — only on a "victory" outcome mission
  - mm:add_new_scripted_objective(text, trigger, condition_fn, log_key)
  - mm:trigger() — start the mission
  - mission_manager:force_scripted_objective_success(mission_key)
  - mission_manager:fail_custom_mission(mission_key)

Defensive: every mission_manager call is pcall'd. Never crash the campaign.

Lua 5.1 only. No file-bottom auto-registration.
]]

wingman_missions = wingman_missions or {}

-- ---------------------------------------------------------------------------
-- Mission-key naming conventions. Keep these stable — saved keys reference
-- them across sessions.
-- ---------------------------------------------------------------------------

local function turn_cap_key(faction_key)
    return "wingman_turn_cap_" .. tostring(faction_key or "local")
end

local function settlement_objective_key(settlement)
    return "wingman_obj_settlement_" .. tostring(settlement)
end

local function defeat_objective_key(faction)
    return "wingman_obj_defeat_" .. tostring(faction)
end

-- ---------------------------------------------------------------------------
-- Logging — never fatal
-- ---------------------------------------------------------------------------

local function log(msg)
    if out and out.tag and out.tag.fight then
        out.tag.fight("[Wingman] " .. tostring(msg))
    else
        print("[Wingman] " .. tostring(msg))
    end
end

local function warn(msg)
    if out and out.tag and out.tag.fight then
        out.tag.fight("[Wingman][WARN] " .. tostring(msg))
    else
        print("[Wingman][WARN] " .. tostring(msg))
    end
end

local function debug_log(msg)
    if not wingman_state or type(wingman_state.get_settings) ~= "function" then
        return
    end
    local s = wingman_state.get_settings()
    if not s or s.wingman_debug_logging ~= true then return end
    log("[DBG][missions] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Settings / state / safety helpers — defensive, never throw
-- ---------------------------------------------------------------------------

local function get_settings()
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        return {}
    end
    local ok, s = pcall(wingman_state.get_settings)
    if not ok or type(s) ~= "table" then return {} end
    return s
end

local function get_local_faction_key()
    if not cm or type(cm.get_local_faction_name) ~= "function" then return nil end
    local ok, name = pcall(cm.get_local_faction_name, cm)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    return name
end

local function safe_call(label, fn, ...)
    if type(wingman_safety) == "table" and type(wingman_safety.safe_call) == "function" then
        return wingman_safety.safe_call(label, fn, ...)
    end
    -- Inline fallback if safety module isn't loaded yet (T3 ships first,
    -- but defense-in-depth is cheap).
    if type(fn) ~= "function" then return nil, false end
    local ok, result = pcall(fn, ...)
    if not ok then
        warn(string.format("safe_call[%s]: %s", tostring(label), tostring(result)))
        return nil, false
    end
    return result, true
end

local function get_or_init_mission_keys(faction_key)
    -- Stored shape: { turn_cap = "key", settlements = {...}, defeated = {...} }
    if type(wingman_state) ~= "table" or type(wingman_state.get_mission_keys) ~= "function" then
        return { turn_cap = nil, settlements = {}, defeated = {} }
    end
    local ok, keys = pcall(wingman_state.get_mission_keys)
    if not ok or type(keys) ~= "table" then
        return { turn_cap = nil, settlements = {}, defeated = {} }
    end
    if type(keys.settlements) ~= "table" then keys.settlements = {} end
    if type(keys.defeated)   ~= "table" then keys.defeated   = {} end
    keys.turn_cap = keys.turn_cap or nil
    return keys
end

local function save_mission_keys(keys)
    if type(wingman_state) ~= "table" or type(wingman_state.set_mission_keys) ~= "function" then
        return false
    end
    local ok, val = pcall(wingman_state.set_mission_keys, keys)
    if not ok then return false end
    return val == true
end

-- ---------------------------------------------------------------------------
-- mission_manager plumbing — guarded against missing global
-- ---------------------------------------------------------------------------

local function mm_new(...)
    if type(mission_manager) ~= "function" then return nil end
    local ok, mm = pcall(mission_manager, ...)
    if not ok or not mm then return nil end
    return mm
end

local function mm_method(mm, method, ...)
    if not mm or type(mm[method]) ~= "function" then return nil end
    local ok, val = pcall(mm[method], mm, ...)
    if not ok then
        warn(string.format("mm:%s threw: %s", tostring(method), tostring(val)))
        return nil
    end
    return val
end

local function global_mm_method(method, ...)
    -- Pre-fix: checked `type(mission_manager) ~= "function"`. That's
    -- always true (mission_manager is a table, never a function), so
    -- the OR short-circuited to TRUE and we returned nil regardless
    -- of whether the method existed. Every call from `cancel_or_refresh`
    -- and `complete_victory` silently did nothing. The check should
    -- verify mission_manager is a TABLE and the requested method
    -- exists.
    if type(mission_manager) ~= "table" then return nil end
    if type(mission_manager[method]) ~= "function" then return nil end
    local ok, val = pcall(mission_manager[method], mission_manager, ...)
    if not ok then
        warn(string.format("mission_manager:%s threw: %s", tostring(method), tostring(val)))
        return nil
    end
    return val
end

-- ---------------------------------------------------------------------------
-- Mission callbacks — small no-ops; full behavior handled by event listeners
-- ---------------------------------------------------------------------------

local function on_mission_success(context)
    log("mission_succeeded: " .. tostring((context and context.string) or "?"))
    if type(wingman_state) == "table" and type(wingman_state.set_rule_progress) == "function" then
        pcall(wingman_state.set_rule_progress, {
            last_mission_event = "success",
            last_mission_key   = (context and context.string) or nil,
        })
    end
end

local function on_mission_fail(context)
    log("mission_failed: " .. tostring((context and context.string) or "?"))
    if type(wingman_state) == "table" and type(wingman_state.set_rule_progress) == "function" then
        pcall(wingman_state.set_rule_progress, {
            last_mission_event = "fail",
            last_mission_key   = (context and context.string) or nil,
        })
    end
end

local function on_mission_cancel(context)
    log("mission_cancelled: " .. tostring((context and context.string) or "?"))
end

local function on_mission_expire(context)
    log("mission_expired: " .. tostring((context and context.string) or "?"))
end

-- ---------------------------------------------------------------------------
-- Scripted-objective condition functions — close over a key check.
-- These closures are passed to mission_manager:add_new_scripted_objective
-- and are evaluated on each trigger event.
-- ---------------------------------------------------------------------------

local function make_settlement_condition(settlement_key, faction_key)
    return function(ctx)
        if not cm or type(cm.query_model) ~= "function" then return false end
        local ok, qm = pcall(cm.query_model, cm)
        if not ok or not qm then return false end
        if type(qm.region_list) ~= "function" then return false end
        local ok2, regions = pcall(qm.region_list, qm)
        if not ok2 or not regions then return false end
        if type(regions.item_at) ~= "function" then return false end
        local ok3, count = pcall(regions.num_items, regions)
        local n = ok3 and (tonumber(count) or 0) or 0
        for i = 1, n do
            local ok4, region = pcall(regions.item_at, regions, i)
            if ok4 and region then
                local ok_rk, rk = region.key and pcall(region.key, region) or false, nil
                if ok_rk and rk == settlement_key then
                    if type(region.owning_faction) == "function" then
                        local ok5, owner = pcall(region.owning_faction, region)
                        if ok5 and owner and type(owner.name) == "function" then
                            local ok6, owner_key = pcall(owner.name, owner)
                            if ok6 then
                                return owner_key == faction_key
                            end
                        end
                    end
                end
            end
        end
        return false
    end
end

local function make_defeat_condition(target_faction_key)
    return function(ctx)
        -- A faction is "defeated" if it's no longer in the faction list, or
        -- if its is_defeated() returns true. We probe via cm:query_model().
        if not cm or type(cm.query_model) ~= "function" then return false end
        local ok, qm = pcall(cm.query_model, cm)
        if not ok or not qm then return false end
        if type(qm.faction_list) ~= "function" then return false end
        local ok2, factions = pcall(qm.faction_list, qm)
        if not ok2 or not factions then return false end
        if type(factions.item_at) ~= "function" then return false end
        local ok3, count = pcall(factions.num_items, factions)
        local n = ok3 and (tonumber(count) or 0) or 0
        for i = 1, n do
            local ok4, f = pcall(factions.item_at, factions, i)
            if ok4 and f then
                local ok5, fk = f.name and pcall(f.name, f) or false, nil
                if ok5 and fk == target_faction_key then
                    -- Still alive.
                    if type(f.is_defeated) == "function" then
                        local ok6, defeated = pcall(f.is_defeated, f)
                        if ok6 then return defeated == true end
                    end
                    return false
                end
            end
        end
        -- Not found in faction_list => eliminated.
        return true
    end
end

-- ---------------------------------------------------------------------------
-- Mission builders
-- ---------------------------------------------------------------------------

--[[ Create the turn-cap mission. Adds a game_victory payload only when
    the outcome setting is "victory"; otherwise it's a passive turn-counter.
    Returns the mission object or nil on failure. ]]
function wingman_missions.create_turn_cap_mission(faction_key, turn_limit)
    if not faction_key or type(faction_key) ~= "string" then
        warn("create_turn_cap_mission: missing faction_key")
        return nil
    end
    if not turn_limit or tonumber(turn_limit) == nil then
        warn("create_turn_cap_mission: missing turn_limit")
        return nil
    end

    local s = get_settings()
    local outcome = s.wingman_turn_cap_outcome or "breakpoint"
    if outcome ~= "victory" and outcome ~= "breakpoint" then
        outcome = "breakpoint"
    end

    local mkey = turn_cap_key(faction_key)

    local mm = mm_new(faction_key, mkey,
        on_mission_success, on_mission_fail, on_mission_cancel, on_mission_expire)
    if not mm then
        warn("create_turn_cap_mission: mission_manager:new returned nil")
        return nil
    end

    mm_method(mm, "set_turn_limit", tonumber(turn_limit))

    if outcome == "victory" then
        mm_method(mm, "add_payload", "game_victory")
    end

    -- Add a scripted objective so the player sees the goal in the UI.
    local label = string.format("Reach turn %d", tonumber(turn_limit))
    if outcome == "victory" then
        label = label .. " (victory)"
    else
        label = label .. " (breakpoint)"
    end

    mm_method(mm, "add_new_scripted_objective",
        label,
        "FactionTurnStart",
        function(ctx) return cm and cm.turn_number and (pcall(cm.turn_number, cm))
            and (select(2, pcall(cm.turn_number, cm)) or 0) >= tonumber(turn_limit) end,
        mkey .. "_objective")

    -- v0.1 safety: set_victory_mission is only sensible when outcome == victory.
    if outcome == "victory" then
        mm_method(mm, "set_victory_mission", true)
    end

    mm_method(mm, "trigger")

    -- Persist under the well-known turn_cap slot.
    local keys = get_or_init_mission_keys(faction_key)
    keys.turn_cap = mkey
    save_mission_keys(keys)

    log(string.format("create_turn_cap_mission: %s for %s turn %d outcome=%s",
        mkey, tostring(faction_key), tonumber(turn_limit), tostring(outcome)))
    return mm
end

--[[ Create scripted-objective missions for every settlement and defeated
    faction required for the custom-win rule. Each objective is its own
    scripted objective attached to a single parent mission keyed by
    faction_key.

    objectives: { settlements = {...}, defeated = {...} } ]]
function wingman_missions.create_custom_objective_missions(faction_key, objectives)
    if not faction_key or type(faction_key) ~= "string" then
        warn("create_custom_objective_missions: missing faction_key")
        return nil
    end
    objectives = objectives or {}
    local settlements = objectives.settlements or {}
    local defeated    = objectives.defeated    or {}

    if #settlements == 0 and #defeated == 0 then
        debug_log("create_custom_objective_missions: empty objectives; skipping")
        return nil
    end

    -- One parent mission per faction, housing all objectives.
    local mkey = "wingman_custom_win_" .. tostring(faction_key)
    local mm = mm_new(faction_key, mkey,
        on_mission_success, on_mission_fail, on_mission_cancel, on_mission_expire)
    if not mm then
        warn("create_custom_objective_missions: mission_manager:new returned nil")
        return nil
    end

    local keys = get_or_init_mission_keys(faction_key)
    keys.settlements = keys.settlements or {}
    keys.defeated    = keys.defeated    or {}

    -- Settlement objectives
    for _, settlement in ipairs(settlements) do
        local ok = safe_call("add_objective_settlement_" .. tostring(settlement),
            function()
                return mm:add_new_scripted_objective(
                    string.format("Own %s", tostring(settlement)),
                    "FactionTurnStart",
                    make_settlement_condition(settlement, faction_key),
                    settlement_objective_key(settlement))
            end)
        if ok ~= nil then
            keys.settlements[#keys.settlements + 1] = settlement_objective_key(settlement)
        end
    end

    -- Faction-defeat objectives
    for _, target in ipairs(defeated) do
        local ok = safe_call("add_objective_defeat_" .. tostring(target),
            function()
                return mm:add_new_scripted_objective(
                    string.format("Defeat %s", tostring(target)),
                    "FactionTurnStart",
                    make_defeat_condition(target),
                    defeat_objective_key(target))
            end)
        if ok ~= nil then
            keys.defeated[#keys.defeated + 1] = defeat_objective_key(target)
        end
    end

    mm_method(mm, "trigger")
    save_mission_keys(keys)

    log(string.format("create_custom_objective_missions: %s settlements=%d defeated=%d",
        mkey, #keys.settlements, #keys.defeated))
    return mm
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--[[ Build / rebuild missions for the local faction based on current
    settings. Cancels existing missions first so settings changes don't
    leave stale missions around. ]]
function wingman_missions.init_for_faction(faction_key)
    if not wingman_safety or type(wingman_safety.mp_guard) ~= "function"
            or not wingman_safety.mp_guard("wingman_missions.init_for_faction") then
        return false
    end

    faction_key = faction_key or get_local_faction_key()
    if not faction_key then
        warn("init_for_faction: no faction_key available")
        return false
    end

    -- Always cancel/refresh first so we never stack missions across
    -- settings edits.
    wingman_missions.cancel_or_refresh()

    local s = get_settings()

    -- Turn-cap mission
    if s.wingman_turn_cap_enabled == true then
        local cap = tonumber(s.wingman_turn_cap_value) or 50
        safe_call("init_turn_cap", function()
            wingman_missions.create_turn_cap_mission(faction_key, cap)
        end)
    end

    -- Custom-win objectives
    if s.wingman_custom_win_enabled == true then
        local settlements = {}
        local defeated    = {}
        if type(wingman_rules) == "table" and type(wingman_rules.parse_key_csv) == "function" then
            settlements = wingman_rules.parse_key_csv(
                s.wingman_required_settlements_csv, "settlement")
            defeated = wingman_rules.parse_key_csv(
                s.wingman_required_defeated_factions_csv, "faction")
        end
        if #settlements > 0 or #defeated > 0 then
            safe_call("init_custom_win", function()
                wingman_missions.create_custom_objective_missions(faction_key, {
                    settlements = settlements,
                    defeated    = defeated,
                })
            end)
        end
    end

    log("init_for_faction: done for " .. tostring(faction_key))
    return true
end

--[[ Cancel every stored mission key, then clear the persisted list.
    Used on settings changes and on shutdown. ]]
function wingman_missions.cancel_or_refresh()
    if type(wingman_state) ~= "table" or type(wingman_state.get_mission_keys) ~= "function" then
        return false
    end
    local ok, keys = pcall(wingman_state.get_mission_keys)
    if not ok or type(keys) ~= "table" then
        return false
    end

    local cancelled = 0
    if keys.turn_cap and keys.turn_cap ~= "" then
        -- Pre-fix: counted any non-nil return, including `false` from
        -- the engine. A `false` return means "could not cancel" (e.g.,
        -- mission already completed or never started). Counting those
        -- as cancellations broke the log accuracy and made the counter
        -- a misleading diagnostic. Truthy check is the correct intent.
        if global_mm_method("fail_custom_mission", keys.turn_cap) then
            cancelled = cancelled + 1
        end
    end

    local function cancel_list(list)
        if type(list) ~= "table" then return 0 end
        local n = 0
        for _, k in ipairs(list) do
            if k and k ~= "" then
                if global_mm_method("fail_custom_mission", k) then
                    n = n + 1
                end
            end
        end
        return n
    end

    cancelled = cancelled + cancel_list(keys.settlements)
    cancelled = cancelled + cancel_list(keys.defeated)

    -- Clear persisted state.
    if type(wingman_state.set_mission_keys) == "function" then
        pcall(wingman_state.set_mission_keys, {
            turn_cap    = nil,
            settlements = {},
            defeated    = {},
        })
    end

    log(string.format("cancel_or_refresh: cancelled=%d", cancelled))
    return true
end

--[[ Force scripted-objective success for the missions tied to a victory.
    Called when a rule evaluator returns outcome="victory". ]]
function wingman_missions.complete_victory(faction_key, reason)
    faction_key = faction_key or get_local_faction_key()
    reason = reason or "wingman_victory"

    log(string.format("complete_victory: faction=%s reason=%s",
        tostring(faction_key or "?"), tostring(reason)))

    if not wingman_safety or type(wingman_safety.mp_guard) ~= "function"
            or not wingman_safety.mp_guard("wingman_missions.complete_victory") then
        return false
    end

    if not faction_key then return false end

    -- Turn-cap mission (if outcome was victory).
    local s = get_settings()
    if s.wingman_turn_cap_enabled == true and (s.wingman_turn_cap_outcome or "breakpoint") == "victory" then
        local mkey = turn_cap_key(faction_key)
        safe_call("force_success_turn_cap", function()
            return global_mm_method("force_scripted_objective_success", mkey)
        end)
    end

    -- Custom-win objectives.
    if type(wingman_state) == "table" and type(wingman_state.get_mission_keys) == "function" then
        local ok, keys = pcall(wingman_state.get_mission_keys)
        if ok and type(keys) == "table" then
            local function force_list(list)
                if type(list) ~= "table" then return end
                for _, k in ipairs(list) do
                    if k and k ~= "" then
                        safe_call("force_success_" .. tostring(k), function()
                            return global_mm_method("force_scripted_objective_success", k)
                        end)
                    end
                end
            end
            force_list(keys.settlements)
            force_list(keys.defeated)
        end
    end

    log("[Wingman] victory condition met. reason=" .. tostring(reason))
    return true
end

-- ---------------------------------------------------------------------------
-- Listener callbacks — defined but not auto-registered.
-- wingman_init / wingman_campaign can register these via core:add_listener
-- using the "wingman_missions_" prefix.
-- ---------------------------------------------------------------------------

--[[ Listener callback for MissionSucceeded. ]]
function wingman_missions.on_mission_succeeded(context)
    if not context then return end
    local key = context.string or context.mission_key
    if not key or type(key) ~= "string" or not key:match("^wingman_") then return end
    on_mission_success(context)

    -- Clear the matching entry from persisted mission_keys.
    if type(wingman_state) == "table" and type(wingman_state.get_mission_keys) == "function" then
        local ok, keys = pcall(wingman_state.get_mission_keys)
        if ok and type(keys) == "table" then
            if keys.turn_cap == key then keys.turn_cap = nil end
            local function trim(list)
                if type(list) ~= "table" then return end
                local out = {}
                for _, v in ipairs(list) do
                    if v ~= key then out[#out + 1] = v end
                end
                -- Replace contents in-place to avoid alias issues.
                for i = 1, #list do list[i] = nil end
                for i, v in ipairs(out) do list[i] = v end
            end
            trim(keys.settlements)
            trim(keys.defeated)
            if type(wingman_state.set_mission_keys) == "function" then
                pcall(wingman_state.set_mission_keys, keys)
            end
        end
    end
end

--[[ Listener callback for MissionFailed. ]]
function wingman_missions.on_mission_failed(context)
    if not context then return end
    local key = context.string or context.mission_key
    if not key or type(key) ~= "string" or not key:match("^wingman_") then return end
    on_mission_fail(context)
end

--[[ Listener registration helper. Idempotent. ]]
function wingman_missions.register_listeners()
    if type(core) ~= "table" or type(core.add_listener) ~= "function" then
        warn("register_listeners: core.add_listener unavailable")
        return false
    end

    pcall(core.add_listener, core,
        "wingman_missions_success",
        "MissionSucceeded",
        true,
        function(context) wingman_missions.on_mission_succeeded(context) end,
        false)

    pcall(core.add_listener, core,
        "wingman_missions_failure",
        "MissionFailed",
        true,
        function(context) wingman_missions.on_mission_failed(context) end,
        false)

    return true
end

--[[ Mirror of register_listeners for shutdown/save-reload. ]]
function wingman_missions.unregister_listeners()
    if type(core) ~= "table" or type(core.remove_listener) ~= "function" then
        return false
    end
    pcall(core.remove_listener, core, "wingman_missions_success")
    pcall(core.remove_listener, core, "wingman_missions_failure")
    return true
end