--[[
Wingman — campaign bootstrap (T7 integration).

Entry point: wingman.init() runs on the first tick after a campaign is
created. It wires up state persistence, all sub-module listeners
(safety → battle → missions → campaign), and the player's faction
missions. Feature modules are loaded into globals by the campaign
script directory; this file integrates them in the correct order.

Order of operations (T7 architecture):
  1. MP guard — block and return if multiplayer
  2. wingman_state.init() — load global settings (MCT if available, else
     defaults) + in-save state, set mode
  3. Register safety, battle, missions, campaign listeners
  4. wingman_missions.init_for_faction(cm:get_local_faction_name())
  5. Log final status (mode + handover flags)

File-bottom registration uses cm:add_first_tick_callback so the order
in which the campaign script directory is loaded does not matter.

Lua 5.1 only. Defensive at every step; never crashes the campaign loader.
]]

wingman = wingman or {}

local VERSION_STRING = "0.1.0-alpha"

-- ---------------------------------------------------------------------------
-- Module-local state — T7 integration tracker. T7 expands this with the
-- fields required by the integration contract:
--   state.initialized        = true once init() has run end-to-end
--   state.tracked_listeners  = array of listener names registered so far
--   state.last_init_turn     = turn number at init, used by S6 diagnostics
-- ---------------------------------------------------------------------------

local state = {
    initialized        = false,
    tracked_listeners  = {},  -- array of listener names (e.g. "wingman_safety_listeners")
    last_init_turn     = nil,
    listeners_registered = false,
}

-- ---------------------------------------------------------------------------
-- Listener tracking — must be removed on shutdown / before re-registration
-- to avoid duplicates after save/load.
-- ---------------------------------------------------------------------------

local registered_listeners = {}   -- legacy array of { event = ..., name = ... }
local listeners_lock = false      -- prevents double-unregister races

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

-- ---------------------------------------------------------------------------
-- Track a listener so we can remove it on shutdown.
-- T7 spec: signature is track_listener(name) — single name arg. The legacy
-- (event, name) shape is kept in the internal `registered_listeners` table
-- for backward compatibility with the existing unregister_listeners path.
-- Wrapped in pcall for defensiveness.
-- ---------------------------------------------------------------------------

local function track_listener(event_name_or_name, listener_name)
    local ok, err = pcall(function()
        -- New (T7) shape: track_listener(name) — single argument
        if listener_name == nil then
            local name = event_name_or_name
            if type(name) ~= "string" or name == "" then return end
            -- Avoid duplicates
            for _, existing in ipairs(state.tracked_listeners) do
                if existing == name then return end
            end
            state.tracked_listeners[#state.tracked_listeners + 1] = name
        else
            -- Legacy (event, name) shape — keep registered_listeners working
            registered_listeners[#registered_listeners + 1] = {
                event = event_name_or_name,
                name  = listener_name,
            }
        end
    end)
    if not ok then
        warn("track_listener: " .. tostring(err))
    end
end

-- Public wrapper exposed on the module so external code (and the spec) can
-- call `wingman.track_listener(name)` without going through the local.
function wingman.track_listener(name)
    track_listener(name)
end

-- ---------------------------------------------------------------------------
-- Init entry — runs on first tick after campaign creation
-- ---------------------------------------------------------------------------

--- Initialize Wingman for a fresh campaign. Idempotent.
-- T7 sequence:
--   1. MP guard
--   2. Re-init path: re-load in-save state, re-register listeners
--   3. Full init: state.init, register_listeners (safety → battle → missions
--      → campaign), missions.init_for_faction(cm:get_local_faction_name())
--   4. Log final status (mode + handover flags)
function wingman.init()
    -- Always log first, even before MP guard, so we have evidence the script
    -- actually loaded (S7 / S10 rely on this).
    log("init: enter")

    -- Module-presence guard: every other module is required.
    if type(wingman_safety) ~= "table" or type(wingman_safety.mp_guard) ~= "function" then
        warn("init: wingman_safety module missing — cannot run")
        return false
    end
    if type(wingman_state) ~= "table" or type(wingman_state.init) ~= "function" then
        warn("init: wingman_state module missing — cannot run")
        return false
    end

    -- MP guard: every entry point exits when in MP. T7 / T10 evidence.
    if not wingman_safety.mp_guard("init") then
        log("init: disabled (multiplayer)")
        return false
    end

    -- Idempotent re-init: re-load in-save state and re-register listeners
    -- so save/load (S6) doesn't drop automation.
    if state.initialized then
        log("init: already initialized, re-loading")
        wingman_safety.safe_call("state.load", wingman_state.load)
        wingman.register_listeners()
        return true
    end

    -- Full init sequence.
    out("[Wingman] init starting. v" .. VERSION_STRING .. ".")

    if not wingman_safety.safe_call("state.init", wingman_state.init) then
        out("[Wingman] init FAILED at state.init")
        return false
    end

    -- Register all listeners (safety → battle → missions → campaign).
    wingman.register_listeners()

    -- Initialize missions for the player's faction (creates turn-cap +
    -- custom-win missions if settings say so).
    if cm and type(cm.get_local_faction_name) == "function" then
        local ok_fac, faction = pcall(cm.get_local_faction_name, cm)
        if ok_fac and faction and faction ~= "" then
            wingman_safety.safe_call("missions.init_for_faction", wingman_missions.init_for_faction, faction)
        end
    end

    state.initialized = true

    -- Record the turn we initialized at; useful for S6 diagnostics.
    if cm and type(cm.turn_number) == "function" then
        state.last_init_turn = wingman_safety.safe_call("turn_number", cm.turn_number, cm)
    end

    -- Mirror the legacy flag for any code paths that still check it.
    wingman._initialized = true

    -- Record init version in-save for cross-version diagnostics.
    if cm and type(cm.save_named_value) == "function" then
        pcall(cm.save_named_value, cm, "wingman.v1.last_init_version", VERSION_STRING)
    end

    -- Log final status — this is the canonical S7 / S10 evidence line.
    local settings = wingman_safety.safe_call("settings", wingman_state.get_settings) or {}
    out(string.format("[Wingman] init complete. mode=%s, campaign_handover=%s, battle_handover=%s",
        tostring(wingman_state.get_mode()),
        tostring(settings.wingman_campaign_handover_enabled),
        tostring(settings.wingman_battle_handover_enabled)))

    return true
end

-- ---------------------------------------------------------------------------
-- Listener registration — T7 wires all sub-modules here.
-- Order is deliberate:
--   1. safety   — catches any popup that opens during the rest of init
--   2. battle   — PendingBattle / BattleBeingFought / BattleCompleted
--   3. missions — MissionSucceeded / MissionFailed
--   4. campaign — orchestrator (FactionTurnStart, FactionTurnEnd, WorldStartRound)
-- Each module's own register_listeners() is idempotent.
-- ---------------------------------------------------------------------------

--- Wire all Wingman listeners across safety, battle, missions, campaign.
-- Idempotent: a second call is a no-op (state.listeners_registered gate).
-- Skips entirely if wingman_state is in error-safe mode (caller must run
-- wingman.try_recover_from_error_safe() to recover).
function wingman.register_listeners()
    -- Skip if in error-safe mode — don't re-register automation listeners
    -- until the user has explicitly toggled wingman off then on.
    local not_in_error, mode_check_ok = wingman_safety.safe_call(
        "init.guard",
        function() return wingman_state.get_mode() ~= wingman_state.MODE_ERROR_SAFE end)
    if not mode_check_ok or not not_in_error then
        out("[Wingman] init skipped: in error-safe mode")
        return false
    end

    if state.listeners_registered then
        out("[Wingman] listeners already registered")
        return true
    end

    -- Safety listeners first (so they catch any popup that opens during the rest)
    if wingman_safety.safe_call("register_safety", wingman_safety.register_listeners) then
        track_listener("wingman_safety_listeners")
    end

    -- Battle listeners (PendingBattle, BattleBeingFought, BattleCompleted)
    if wingman_safety.safe_call("register_battle", wingman_battle.register_listeners) then
        track_listener("wingman_battle_listeners")
    end

    -- Missions listeners (MissionSucceeded, MissionFailed)
    if wingman_safety.safe_call("register_missions", wingman_missions.register_listeners) then
        track_listener("wingman_missions_listeners")
    end

    -- AI controller listener (FactionTurnStart). MUST come before campaign
    -- so the AI's order spending happens in the same tick as the end-turn
    -- driver — engine will queue the orders first, then run end_turn right
    -- after, so the orders commit before the next faction's turn.
    if wingman_safety.safe_call("register_ai", wingman_ai.register_listeners) then
        track_listener("wingman_ai_listeners")
    end

    -- Campaign listeners LAST (so it can use the registered safety/battle/missions/AI)
    if wingman_safety.safe_call("register_campaign", wingman_campaign.register_listeners) then
        track_listener("wingman_campaign_listeners")
    end

    state.listeners_registered = true
    return true
end

--- Remove every listener we have registered, idempotently.
function wingman.unregister_listeners()
    if listeners_lock then return false end
    listeners_lock = true

    if core and type(core.remove_listener) == "function" then
        for i = #registered_listeners, 1, -1 do
            local rec = registered_listeners[i]
            pcall(core.remove_listener, core, rec.name)
        end
    end

    if wingman_safety and type(wingman_safety.unregister_listeners) == "function" then
        pcall(wingman_safety.unregister_listeners)
    end

    registered_listeners = {}
    listeners_lock = false
    wingman._initialized = false
    return true
end

-- ---------------------------------------------------------------------------
-- Shutdown — disable automation safely
-- ---------------------------------------------------------------------------

--- Disable Wingman and persist a safe state. Reason is logged.
-- T7: removes every listener we registered (via the per-module
-- unregister_listeners calls), then switches mode to DISABLED and saves.
function wingman.shutdown(reason)
    out("[Wingman] shutdown: " .. tostring(reason or "unspecified"))

    -- Unregister in reverse order (campaign first since it's the orchestrator)
    -- Each call goes through safe_call so one failing module can't break the rest.
    if wingman_campaign and type(wingman_campaign.unregister_listeners) == "function" then
        wingman_safety.safe_call("unregister_campaign", wingman_campaign.unregister_listeners)
    end
    if wingman_ai and type(wingman_ai.unregister_listeners) == "function" then
        wingman_safety.safe_call("unregister_ai", wingman_ai.unregister_listeners)
    end
    if wingman_missions and type(wingman_missions.unregister_listeners) == "function" then
        wingman_safety.safe_call("unregister_missions", wingman_missions.unregister_listeners)
    end
    if wingman_battle and type(wingman_battle.unregister_listeners) == "function" then
        wingman_safety.safe_call("unregister_battle", wingman_battle.unregister_listeners)
    end
    if wingman_safety and type(wingman_safety.unregister_listeners) == "function" then
        wingman_safety.safe_call("unregister_safety", wingman_safety.unregister_listeners)
    end

    -- Also clear the legacy registered_listeners table for any
    -- core:add_listener / core:remove_listener pairs we tracked there.
    if core and type(core.remove_listener) == "function" then
        for i = #registered_listeners, 1, -1 do
            local rec = registered_listeners[i]
            if rec and rec.name then
                pcall(core.remove_listener, core, rec.name)
            end
        end
    end

    -- Reset state
    state.initialized = false
    state.listeners_registered = false
    state.tracked_listeners = {}
    registered_listeners = {}
    wingman._initialized = false

    if wingman_state and type(wingman_state.set_mode) == "function" then
        wingman_safety.safe_call("set_disabled", wingman_state.set_mode,
            wingman_state.MODE_DISABLED, "shutdown: " .. tostring(reason or ""))
    end

    if wingman_state and type(wingman_state.save) == "function" then
        wingman_safety.safe_call("save", wingman_state.save)
    end
end

-- ---------------------------------------------------------------------------
-- Recovery from error-safe mode
-- ---------------------------------------------------------------------------

--- Attempt to leave error-safe mode after the user toggled wingman_enabled
-- off then on. Idempotent; returns false if not in error-safe mode.
function wingman.try_recover_from_error_safe()
    if not wingman_state or type(wingman_state.get_mode) ~= "function" then
        return false
    end
    if wingman_state.get_mode() ~= wingman_state.MODE_ERROR_SAFE then
        return false  -- nothing to recover from
    end
    out("[Wingman] recovering from error-safe mode")
    if type(wingman_state.clear_error) == "function" then
        wingman_safety.safe_call("clear_error", wingman_state.clear_error)
    end
    if type(wingman_state.set_mode) == "function" then
        wingman_safety.safe_call("set_mode_disabled", wingman_state.set_mode,
            wingman_state.MODE_DISABLED, "manual_recovery")
    end
    if type(wingman_state.save) == "function" then
        wingman_safety.safe_call("save", wingman_state.save)
    end
    -- Re-init to register listeners
    state.initialized = false
    state.listeners_registered = false
    state.tracked_listeners = {}
    wingman._initialized = false
    return wingman.init()
end

-- ---------------------------------------------------------------------------
-- First-tick registration
-- ---------------------------------------------------------------------------
-- Defer to first tick so cm:model() / cm:get_local_faction() are guaranteed
-- to exist by the time wingman.init runs.

if cm and type(cm.add_first_tick_callback) == "function" then
    local ok_reg, err_reg = pcall(cm.add_first_tick_callback, cm, function()
        wingman.init()
    end)
    if not ok_reg then
        -- Fall back to a direct call so we still try to init; better than
        -- silent no-op if the engine renames the API in a future patch.
        warn("add_first_tick_callback failed: " .. tostring(err_reg) .. "; calling init directly")
        wingman.init()
    end
else
    -- No cm available at file-load time; TWW3 campaign scripts always have cm,
    -- but if a future engine change moves script load order we'll still try.
    warn("cm.add_first_tick_callback missing; calling init directly")
    wingman.init()
end