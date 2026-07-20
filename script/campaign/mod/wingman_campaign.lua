--[[
Wingman — campaign handover driver.

Owns the FactionTurnStart / FactionTurnEnd / round-start lifecycle and is
the only module that actually invokes `cm:end_turn()`. Architecture is
locked: campaign handover is *simulated* by auto-ending the player's turn,
not by transferring faction ownership.

Public surface lives in the wingman_campaign table; everything else is
local. Listeners are registered with persistent=false so they cleanly
re-attach after save/load (T7 wires registration into wingman.init()).

All risky calls go through wingman_safety.safe_call / pcall so a broken
listener callback can never crash the campaign loader.

Lua 5.1 only. Never throws.
]]

wingman_campaign = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

wingman_campaign.MODULE_NAME = "wingman_campaign"

-- Names used by core:add_listener / core:remove_listener. Keep these in
-- sync with anything else that might register a listener on the same event.
wingman_campaign.LISTENER_NAMES = {
    "wingman_campaign_turn_start",
    "wingman_campaign_turn_end",
    "wingman_campaign_round_start",
}

-- Default delay for cm:end_turn when settings are missing or invalid.
local DEFAULT_END_TURN_DELAY = 2

-- ---------------------------------------------------------------------------
-- Module-private state
-- ---------------------------------------------------------------------------

local listeners_registered = false
local listeners_registration_ok = { turn_start = false, turn_end = false, round_start = false }

-- ---------------------------------------------------------------------------
-- Logging helpers
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

local function debug(msg)
    -- Respect in-memory debug setting if state is loaded.
    local ok_state = type(wingman_state) == "table" and type(wingman_state.get_settings) == "function"
    if not ok_state then return end
    local settings = wingman_state.get_settings()
    if not settings or settings.wingman_debug_logging ~= true then return end
    log("[DBG] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Defensive engine accessors
-- ---------------------------------------------------------------------------

--- Safely read cm:turn_number(); returns 0 on any error.
local function safe_turn_number()
    if not cm or type(cm.turn_number) ~= "function" then return 0 end
    local ok, n = pcall(cm.turn_number, cm)
    if not ok then return 0 end
    return tonumber(n) or 0
end

--- Safely read cm:get_local_faction_name(); returns nil on any error.
local function safe_local_faction_name()
    if not cm or type(cm.get_local_faction_name) ~= "function" then return nil end
    local ok, name = pcall(cm.get_local_faction_name, cm)
    if not ok then return nil end
    return name
end

--- Safely read cm:is_faction_human(name); returns false on any error.
local function safe_is_faction_human(name)
    if not cm or type(cm.is_faction_human) ~= "function" then return false end
    local ok, val = pcall(cm.is_faction_human, cm, name)
    if not ok then return false end
    return val == true
end

--- Safely schedule a delayed callback; returns false if cm:callback is unavailable.
local function safe_callback(fn, delay)
    if not cm or type(cm.callback) ~= "function" then return false end
    local ok, err = pcall(cm.callback, cm, fn, delay)
    if not ok then
        warn("cm:callback failed: " .. tostring(err))
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Settings access
-- ---------------------------------------------------------------------------

local function read_settings()
    if type(wingman_state) ~= "table" or type(wingman_state.get_settings) ~= "function" then
        warn("wingman_state unavailable; cannot read settings")
        return nil
    end
    return wingman_state.get_settings()
end

local function resolve_delay(settings)
    if not settings then return DEFAULT_END_TURN_DELAY end
    local n = tonumber(settings.wingman_auto_end_turn_delay_seconds)
    if n == nil then return DEFAULT_END_TURN_DELAY end
    if n < 0 then return 0 end
    return math.floor(n)
end

-- ---------------------------------------------------------------------------
-- State guards
-- ---------------------------------------------------------------------------

local function state_ok()
    return type(wingman_state) == "table"
        and type(wingman_state.get_mode) == "function"
        and type(wingman_state.is_turn_already_processed) == "function"
        and type(wingman_state.set_breakpoint) == "function"
        and type(wingman_state.mark_turn_processed) == "function"
        and type(wingman_state.set_mode) == "function"
        and type(wingman_state.enter_error_safe_mode) == "function"
        and type(wingman_state.update_settings) == "function"
end

local function safety_ok()
    return type(wingman_safety) == "table"
        and type(wingman_safety.mp_guard) == "function"
        and type(wingman_safety.is_modal_blocking) == "function"
        and type(wingman_safety.is_war_declared_event_pending) == "function"
        and type(wingman_safety.safe_call) == "function"
end

-- ---------------------------------------------------------------------------
-- Rule evaluation shim
-- ---------------------------------------------------------------------------

--- Evaluate wingman_rules.evaluate_all if the module is loaded; otherwise
-- return a "pass" stub. Returns a table with at least `outcome` and
-- optionally `reason` / `data`. Never throws.
local function evaluate_rules(context)
    if type(wingman_rules) == "table" and type(wingman_rules.evaluate_all) == "function" then
        local safe = type(wingman_safety) == "table" and type(wingman_safety.safe_call) == "function"
        if safe then
            local result, ok = wingman_safety.safe_call("rules.evaluate_all", wingman_rules.evaluate_all, context)
            if not ok or type(result) ~= "table" then
                warn("wingman_rules.evaluate_all failed; treating as pass")
                return { outcome = "pass", reason = "rules_call_failed" }
            end
            return result
        end
        local ok, result = pcall(wingman_rules.evaluate_all, context)
        if not ok or type(result) ~= "table" then
            warn("wingman_rules.evaluate_all threw; treating as pass")
            return { outcome = "pass", reason = "rules_threw" }
        end
        return result
    end
    -- T5 (rules and missions) hasn't shipped yet — don't block automation on
    -- the missing module; downstream tasks will evaluate against real state.
    return { outcome = "pass", reason = "rules_module_not_loaded" }
end

-- ---------------------------------------------------------------------------
-- Mode/state helpers
-- ---------------------------------------------------------------------------

local function handle_rule_outcome(rule_result, turn)
    if type(rule_result) ~= "table" then
        warn("rule_result not a table; treating as pass")
        return true -- continue
    end
    local outcome = rule_result.outcome
    if outcome == "pass" then
        debug("rules: pass (" .. tostring(rule_result.reason or "n/a") .. ")")
        return true
    end
    if outcome == "warning" then
        warn("rules: warning (" .. tostring(rule_result.reason or "n/a") .. "); continuing")
        return true
    end
    if outcome == "breakpoint" then
        log(string.format("rules: breakpoint (%s) at turn %d",
            tostring(rule_result.reason or "rule_breakpoint"), tonumber(turn) or 0))
        wingman_state.set_breakpoint("rule_breakpoint",
            rule_result.reason or rule_result.data or "unspecified")
        return false
    end
    if outcome == "victory" then
        log(string.format("rules: victory (%s); not ending turn",
            tostring(rule_result.reason or "rule_victory")))
        -- T5 mission manager will pick this up from rule_progress; do not end turn.
        return false
    end
    if outcome == "error" then
        warn("rules: error outcome: " .. tostring(rule_result.reason or "unknown"))
        if type(wingman_safety) == "table" and type(wingman_safety.enter_error_safe_mode) == "function" then
            wingman_safety.enter_error_safe_mode("rule_error: " .. tostring(rule_result.reason or "unknown"))
        else
            wingman_state.enter_error_safe_mode("rule_error: " .. tostring(rule_result.reason or "unknown"))
        end
        return false
    end
    warn("rule outcome unrecognized: " .. tostring(outcome) .. "; treating as pass")
    return true
end

-- ---------------------------------------------------------------------------
-- Public functions
-- ---------------------------------------------------------------------------

--- Register the campaign handover listeners. Idempotent.
--[[ doc ]]
function wingman_campaign.register_listeners()
    if listeners_registered then
        debug("register_listeners: already registered; skipping")
        return true
    end

    -- Listener 1: FactionTurnStart — main entry, gated on player + mode + setting.
    local ok_ts = wingman_listeners.register(
        wingman_campaign.LISTENER_NAMES[1], "FactionTurnStart", true,
        function(context) wingman_campaign.on_faction_turn_start(context) end, false)
    listeners_registration_ok.turn_start = ok_ts

    -- Listener 2: FactionTurnEnd — player cleanup.
    local ok_te = wingman_listeners.register(
        wingman_campaign.LISTENER_NAMES[2], "FactionTurnEnd", true,
        function(context) wingman_campaign.on_faction_turn_end(context) end, false)
    listeners_registration_ok.turn_end = ok_te

    -- Listener 3: Round-start — refresh MCT settings + rules. WorldStartRound
    -- is the canonical "new turn-cycle" event in WH3 episodic scripting.
    local ok_rs = wingman_listeners.register(
        wingman_campaign.LISTENER_NAMES[3], "WorldStartRound", true,
        function(context) wingman_campaign.on_round_start(context) end, false)
    listeners_registration_ok.round_start = ok_rs == true

    listeners_registered = listeners_registration_ok.turn_start
        or listeners_registration_ok.turn_end
        or listeners_registration_ok.round_start

    log(string.format("register_listeners: turn_start=%s turn_end=%s round_start=%s",
        tostring(listeners_registration_ok.turn_start),
        tostring(listeners_registration_ok.turn_end),
        tostring(listeners_registration_ok.round_start)))
    return listeners_registered
end

--- Remove all campaign handover listeners so a save/load can re-register cleanly.
--[[ doc ]]
function wingman_campaign.unregister_listeners()
    if not core or type(core.remove_listener) ~= "function" then
        listeners_registered = false
        listeners_registration_ok.turn_start = false
        listeners_registration_ok.turn_end = false
        listeners_registration_ok.round_start = false
        return false
    end

    for i, name in ipairs(wingman_campaign.LISTENER_NAMES) do
        wingman_listeners.unregister(name)
    end

    listeners_registered = false
    listeners_registration_ok.turn_start = false
    listeners_registration_ok.turn_end = false
    listeners_registration_ok.round_start = false
    debug("unregister_listeners: cleared")
    return true
end

--- Player FactionTurnStart entry point.
-- Guards, evaluates rules, schedules end-turn.
--[[ doc ]]
function wingman_campaign.on_faction_turn_start(context)
    -- Defense: required dependencies present.
    if not state_ok() then
        warn("on_faction_turn_start: wingman_state not available; ignoring")
        return
    end
    if not safety_ok() then
        warn("on_faction_turn_start: wingman_safety not available; ignoring")
        return
    end

    -- Only the local player's turn is meaningful here.
    local local_name = safe_local_faction_name()
    if not local_name then
        debug("on_faction_turn_start: no local faction name yet")
        return
    end

    -- Resolve which faction this event was for. Defensive because
    -- context:faction() may not be present in every patch.
    local event_faction_name = nil
    if type(context) == "table" and type(context.faction) == "function" then
        local ok, f = pcall(context.faction, context)
        if ok and f and type(f.name) == "function" then
            local ok2, n = pcall(f.name, f)
            if ok2 then event_faction_name = n end
        end
    end

    -- If we can identify the event faction, require it to be the local one.
    -- (The condition function already filters this, but we double-check here
    -- so a misconfigured listener can't end the wrong player's turn.)
    if event_faction_name and event_faction_name ~= local_name then
        return
    end

    -- MP guard: never automate in multiplayer.
    if not wingman_safety.mp_guard("campaign.on_faction_turn_start") then
        return
    end

    -- Mode guard: only act in CAMPAIGN handover mode.
    local mode = wingman_state.get_mode()
    if mode ~= wingman_state.MODE_CAMPAIGN then
        debug("on_faction_turn_start: mode=" .. tostring(mode) .. " (not CAMPAIGN); ignoring")
        return
    end

    local turn = safe_turn_number()

    -- Already-processed guard: prevents re-running within the same turn
    -- (defensive against duplicate listeners after save/load).
    if wingman_state.is_turn_already_processed(turn) then
        log(string.format("[Wingman] turn %d already processed this round", tonumber(turn) or 0))
        return
    end

    -- Safety: a known-unsafe popup or war event blocks auto-turn.
    if wingman_safety.is_modal_blocking() then
        log("on_faction_turn_start: modal blocking; pausing")
        wingman_state.set_breakpoint("modal_blocking", turn)
        return
    end
    if wingman_safety.is_war_declared_event_pending() then
        log("on_faction_turn_start: war event pending; pausing")
        wingman_state.set_breakpoint("war_declared_pending", turn)
        return
    end

    -- Settings: campaign handover must be enabled.
    local settings = read_settings()
    if not settings then return end
    if settings.wingman_campaign_handover_enabled ~= true then
        debug("on_faction_turn_start: campaign handover setting disabled")
        wingman_state.set_mode(wingman_state.MODE_DISABLED, "campaign_handover_setting_off")
        return
    end

    -- Periodic break: hand control back every N turns for review.
    local interval = tonumber(settings.wingman_periodic_break_interval) or 0
    if interval > 0 and turn >= interval and (turn % interval) == 0 then
        log(string.format("on_faction_turn_start: periodic break at turn %d (interval=%d)",
            tonumber(turn) or 0, interval))
        wingman_state.set_breakpoint("periodic_break", turn)
        return
    end

    -- Rule evaluation: defer gracefully if T5 hasn't shipped wingman_rules.
    local rule_result = evaluate_rules(context)
    if not handle_rule_outcome(rule_result, turn) then
        return -- rule produced a non-pass outcome (breakpoint/victory/error)
    end

    -- Schedule the end-turn (or run immediately if delay <= 0).
    local delay = resolve_delay(settings)
    if delay <= 0 then
        wingman_campaign.do_end_turn()
        return
    end

    local scheduled = safe_callback(function() wingman_campaign.do_end_turn() end, delay)
    if not scheduled then
        -- cm:callback unavailable — fall back to immediate end_turn so we
        -- don't stall the campaign. Surface a warning so QA sees it.
        warn("on_faction_turn_start: cm:callback unavailable; running end_turn immediately")
        wingman_campaign.do_end_turn()
        return
    end

    log(string.format("[Wingman] scheduled end_turn in %ds for turn %d",
        tonumber(delay) or 0, tonumber(turn) or 0))
end

--- Actual cm:end_turn invocation. Wrapped in safe_call.
--[[ doc ]]
function wingman_campaign.do_end_turn()
    if not state_ok() or not safety_ok() then
        warn("do_end_turn: dependencies unavailable; skipping")
        return
    end
    if not cm or type(cm.end_turn) ~= "function" then
        warn("do_end_turn: cm.end_turn unavailable; skipping")
        wingman_safety.enter_error_safe_mode("do_end_turn: cm.end_turn unavailable")
        return
    end

    local turn = safe_turn_number()
    -- safe_call passes cm as `self` because end_turn is a colon method.
    local _, ok = wingman_safety.safe_call("cm:end_turn", cm.end_turn, cm)
    if not ok then
        warn("do_end_turn: cm:end_turn failed; entering error-safe mode")
        wingman_safety.enter_error_safe_mode("end_turn failed at turn " .. tostring(turn))
        return
    end

    local marked = wingman_state.mark_turn_processed(turn)
    if not marked then
        debug("do_end_turn: mark_turn_processed returned false (regression or pre-init?)")
    end
    log(string.format("[Wingman] cm:end_turn ok. turn=%d", tonumber(turn) or 0))
end

--- Player FactionTurnEnd entry point. Cleanup hook.
--[[ doc ]]
function wingman_campaign.on_faction_turn_end(context)
    if not state_ok() then
        warn("on_faction_turn_end: wingman_state unavailable; ignoring")
        return
    end

    local turn = safe_turn_number()
    -- Defensive: mark processed in case do_end_turn's mark was skipped
    -- (e.g. callback schedule didn't fire but the turn did end).
    if turn > 0 and not wingman_state.is_turn_already_processed(turn) then
        wingman_state.mark_turn_processed(turn)
    end
    log(string.format("[Wingman] turn %d ended.", tonumber(turn) or 0))
end

--- Round-start hook. Refreshes MCT settings + state on each new round.
--[[ doc ]]
function wingman_campaign.on_round_start(context)
    if not state_ok() then
        warn("on_round_start: wingman_state unavailable; ignoring")
        return
    end

    -- Pull fresh settings from MCT if available.
    if type(wingman_mct) == "table" and type(wingman_mct.read_settings) == "function" then
        local ok_read, fresh = pcall(wingman_mct.read_settings)
        if ok_read and type(fresh) == "table" then
            local ok_apply, applied = pcall(wingman_state.update_settings, fresh)
            if not ok_apply then
                warn("on_round_start: update_settings threw: " .. tostring(applied))
            end
        else
            debug("on_round_start: wingman_mct.read_settings unavailable or returned non-table")
        end
    else
        debug("on_round_start: wingman_mct not loaded yet; keeping current settings")
    end

    log("[Wingman] round start, settings refreshed")
end