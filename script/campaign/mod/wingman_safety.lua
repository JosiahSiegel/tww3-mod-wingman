--[[
Wingman — safety wrappers.

Holds:
  - MP guard (every entry must call this; returns false in multiplayer).
  - pcall-based safe_call wrapper (route risky calls through here).
  - Popup / modal safety helpers (diplomacy, war declaration, dilemmas).
  - Battle result dismissal (conservative by default).
  - Listener registration for PanelOpenedCampaign / BattleCompleted /
    FactionJoinsWar — these are wired here but only registered when
    wingman_safety.register_listeners() is called from wingman_init.

All listeners carry the "wingman_safety_" prefix so they can be removed in
bulk via core:remove_listener.

Lua 5.1 only. Never throws.
]]

wingman_safety = {}

-- Load-order guard. wingman_safety depends on wingman_listeners. See
-- lupa_smoke.py SOURCE_FILES for the canonical load order; this guard
-- catches a future re-order with a clear error.
if type(wingman_listeners) ~= "table" then
    error("wingman_safety.lua: wingman_listeners must be loaded before this module (see lupa_smoke.py SOURCE_FILES)")
end

-- Listener handles for clean removal. Format: { event_name = "listener_name" }.
local LISTENER_NAMES = {
    panel        = "wingman_safety_panel",
    battle_done  = "wingman_safety_battle_done",
    war          = "wingman_safety_war",
}

local listeners_registered = false

-- ---------------------------------------------------------------------------
-- Logging
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
-- MP guard
-- ---------------------------------------------------------------------------

--- Return false (and log) when running in multiplayer.
-- Every entry point should start with this call.
function wingman_safety.mp_guard(caller_label)
    if cm and type(cm.is_multiplayer) == "function" then
        -- Pass cm as self to mimic cm:is_multiplayer() — TWW3 exposes the
        -- multiplayer check as a method on the cm userdata.
        local ok, is_mp = pcall(cm.is_multiplayer, cm)
        if ok and is_mp then
            log(string.format("mp_guard: blocking %s (multiplayer detected)", tostring(caller_label or "?")))
            return false
        end
        if not ok then
            warn(string.format("mp_guard: cm:is_multiplayer threw for %s: %s",
                tostring(caller_label or "?"), tostring(is_mp)))
            return false
        end
    end
    -- If cm is missing entirely, treat as not-MP but warn loudly — the engine
    -- almost always exposes cm in campaign scripts, so absence is suspicious.
    if not cm then
        warn(string.format("mp_guard: cm missing for %s; assuming single-player",
            tostring(caller_label or "?")))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- safe_call wrapper
-- ---------------------------------------------------------------------------

--- Run fn(...) inside pcall; on failure, log + enter_error_safe_mode.
-- Returns (result, true) on success, or (nil, false) on failure.
function wingman_safety.safe_call(label, fn, ...)
    if type(fn) ~= "function" then
        warn(string.format("safe_call[%s]: not a function (%s)", tostring(label), type(fn)))
        return nil, false
    end
    -- Lua 5.1 exposes `unpack` as a global; Lua 5.2+ renamed it `table.unpack`.
    -- TWW3 ships Lua 5.1, but support both so the smoke tests run on modern Lua.
    local _unpack = table.unpack or unpack
    local n = select("#", ...)
    local args = { ... }
    local ok, result
    if n == 0 then
        ok, result = pcall(fn)
    else
        ok, result = pcall(fn, _unpack(args, 1, n))
    end
    if not ok then
        warn(string.format("safe_call[%s]: %s", tostring(label), tostring(result)))
        if type(wingman_state) == "table" and type(wingman_state.enter_error_safe_mode) == "function" then
            wingman_state.enter_error_safe_mode(tostring(label) .. ": " .. tostring(result))
        end
        return nil, false
    end
    return result, true
end

-- ---------------------------------------------------------------------------
-- Modal / popup helpers
-- ---------------------------------------------------------------------------

local PANEL_KEYWORDS = {
    diplomacy = "diplomacy",
    war       = "war",
    dilemma   = "dilemma",
    trade     = "trade",
    warning   = "warning",
    alert     = "alert",
    event     = "event_message",
    skill     = "skill",
}

--- Inspect a panel key string for known blocking patterns.
local function panel_key_blocks(panel_key)
    if type(panel_key) ~= "string" or panel_key == "" then return false end
    for _, kw in pairs(PANEL_KEYWORDS) do
        if panel_key:lower():find(kw, 1, true) then
            return true
        end
    end
    return false
end

--- Called when a campaign panel opens. Triggers a breakpoint for known
-- unsafe panels (diplomacy, war, dilemmas) when the setting allows.
function wingman_safety.on_panel_opened(context)
    if not context then return end

    -- PanelOpenedCampaign contexts vary across patches. Defensive extraction.
    local panel_key = nil
    if type(context.string) == "string" then
        panel_key = context.string
    elseif type(context.panel) == "string" then
        panel_key = context.panel
    elseif type(context.ui_component) == "userdata" and context.ui_component.Id then
        panel_key = tostring(context.ui_component.Id)
    end

    if not panel_key then return end

    if not panel_key_blocks(panel_key) then return end

    local settings
    if type(wingman_state) == "table" and type(wingman_state.get_settings) == "function" then
        settings = wingman_state.get_settings()
    end
    settings = settings or {}

    -- Default conservatively: pause on any known modal. Settings narrow this.
    if panel_key:lower():find("diplomacy", 1, true) then
        if settings.wingman_break_on_diplomacy_panel ~= false then
            wingman_safety.pause_for_popup(panel_key, context)
        end
        return
    end

    if panel_key:lower():find("war", 1, true) then
        -- War declaration handling also runs in on_faction_joins_war, but
        -- the panel itself can appear without that event in some patches.
        if settings.wingman_break_on_war_declaration ~= false then
            wingman_safety.pause_for_popup(panel_key, context)
        end
        return
    end

    -- Dilemmas, trade, alerts, etc. — default to pause.
    wingman_safety.pause_for_popup(panel_key, context)
end

--- Trigger a breakpoint because a known-unsafe popup is blocking.
function wingman_safety.pause_for_popup(panel_key, context)
    log(string.format("pause_for_popup: %s", tostring(panel_key or "?")))
    if type(wingman_state) == "table" and type(wingman_state.set_breakpoint) == "function" then
        wingman_state.set_breakpoint("popup_blocking", tostring(panel_key or "unknown"))
    end
end

--- Inspect the UI tree for known blocking modals. Defensive; returns false
-- on any error rather than crashing.
--
-- v0.1 simplification: TWW3's UI userdata doesn't expose a stable child
-- iteration API across patches, so we do a single-depth probe by component
-- name from the root. If the campaign's known blocking screens register
-- directly under the UI root (typical for diplomacy/war/dilemma), this
-- catches them. For deeper trees we rely on the PanelOpenedCampaign listener
-- (which already paused when a blocking panel appeared).
function wingman_safety.is_modal_blocking()
    if not core or type(core.get_ui_root) ~= "function" then return false end

    local ok, root = pcall(core.get_ui_root)
    if not ok or not root then return false end

    -- Probe a handful of well-known root-level component names.
    local probe_names = {
        "diplomacy_panel",
        "war_declaration_panel",
        "dilemma_panel",
        "modal_blocker",
        "popup_root",
    }

    for _, name in ipairs(probe_names) do
        if type(root.FindChild) == "function" then
            local ok2, child = pcall(root.FindChild, root, name)
            if ok2 and child then
                return true
            end
        end
        -- The .Children accessor sometimes returns a single child or an
        -- indexed userdata; the chadvandy examples use FindChild exclusively.
        if type(root.FindChildIndex) == "function" then
            local ok2, idx = pcall(root.FindChildIndex, root, name)
            if ok2 and idx and idx >= 0 then
                return true
            end
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Battle result dismissal
-- ---------------------------------------------------------------------------

local RESULT_PANEL_CANDIDATES = {
    { "battle_results" },
    { "panel_battle_results" },
    { "post_battle_results" },
    { "BattleResultsPanel" },
}

local CONTINUE_CANDIDATES = {
    { "button_continue" },
    { "continue_button" },
    { "ButtonContinue" },
    { "ok" },
    { "button_ok" },
}

local function find_child_chain(root, names)
    if not root or type(root.FindChild) ~= "function" then return nil end
    local current = root
    for i, name in ipairs(names) do
        local ok, next_node = pcall(current.FindChild, current, name)
        if not ok or not next_node then return nil end
        current = next_node
    end
    return current
end

local function find_component_by_names(root, candidates)
    if not root then return nil end
    for _, names in ipairs(candidates) do
        local node = find_child_chain(root, names)
        if node then return node end
    end
    return nil
end

--- Attempt to dismiss the post-battle results panel via SimulateLClick.
-- Conservative by default: the click is gated by safety_level OR the
-- explicit wingman_auto_dismiss_battle_results flag, AND no modal blocking.
function wingman_safety.dismiss_battle_result_if_safe()
    if not wingman_safety.mp_guard("dismiss_battle_result") then
        return false, "mp_blocked"
    end

    local settings = wingman_state.get_settings()
    if not settings.wingman_auto_dismiss_battle_results then
        debug("dismiss_battle_result: setting disabled")
        return false, "disabled"
    end

    if settings.wingman_safety_level ~= "permissive" then
        -- Even when enabled, the conservative/balanced levels only allow the
        -- click if no war is pending and no modal is open.
        if wingman_safety.is_war_declared_event_pending() then
            log("dismiss_battle_result: war declaration pending; pausing instead of clicking")
            wingman_safety.pause_for_popup("post_battle_war_pending", nil)
            return false, "war_pending"
        end
        if wingman_safety.is_modal_blocking() then
            log("dismiss_battle_result: another modal blocking; pausing instead of clicking")
            wingman_safety.pause_for_popup("post_battle_modal_blocking", nil)
            return false, "modal_blocking"
        end
    end

    if not core or type(core.get_ui_root) ~= "function" then
        return false, "no_core"
    end

    local ok, root = pcall(core.get_ui_root)
    if not ok or not root then
        return false, "no_root"
    end

    local ok2, panel, button = pcall(function()
        local p = find_component_by_names(root, RESULT_PANEL_CANDIDATES)
        if not p then return nil, nil end
        local b = find_component_by_names(p, CONTINUE_CANDIDATES)
        return p, b
    end)
    if not ok2 or not button then
        log("dismiss_battle_result: result panel or continue button not found")
        return false, "panel_missing"
    end

    if type(button.SimulateLClick) ~= "function" then
        warn("dismiss_battle_result: button has no SimulateLClick")
        return false, "no_click"
    end

    local click_ok, click_err = pcall(button.SimulateLClick, button)
    if not click_ok then
        warn("dismiss_battle_result: SimulateLClick failed: " .. tostring(click_err))
        wingman_safety.enter_error_safe_mode("dismiss_battle_result: " .. tostring(click_err))
        return false, "click_failed"
    end

    log("dismiss_battle_result: clicked continue")
    return true, "ok"
end

-- ---------------------------------------------------------------------------
-- War-declaration detection (v0.1: state-backed counter + listener)
-- ---------------------------------------------------------------------------

--- Returns true if a FactionJoinsWar fired for the player within
-- `recent_turn_window` turns (default 2).
function wingman_safety.is_war_declared_event_pending()
    if type(wingman_state) == "table" and type(wingman_state.get_last_war_event_turn) == "function" then
        local last_war_turn = wingman_state.get_last_war_event_turn()
        if last_war_turn <= 0 then return false end
        local cm_ok, current_turn = pcall(cm.turn_number, cm)
        if not cm_ok then return false end
        if (tonumber(current_turn) or 0) - last_war_turn <= 2 then
            return true
        end
    end
    return false
end

--- Listener callback for FactionJoinsWar. Records the event if it targeted
-- the player faction; otherwise no-op.
function wingman_safety.on_faction_joins_war(context)
    if not context then return end

    local faction = nil
    if type(context.faction) == "function" then
        local ok, f = pcall(context.faction, context)
        if ok then faction = f end
    end
    if not faction and type(context.string) == "string" then
        faction = context.string
    end
    if not faction then return end

    local name = nil
    if type(faction.name) == "function" then
        local ok, n = pcall(faction.name, faction)
        if ok then name = n end
    elseif type(faction) == "string" then
        name = faction
    end
    if not name then return end

    local local_name = nil
    if cm and type(cm.get_local_faction_name) == "function" then
        local ok, ln = pcall(cm.get_local_faction_name, cm)
        if ok then local_name = ln end
    end
    if not local_name or name ~= local_name then
        return
    end

    log("FactionJoinsWar: war declared on player (" .. tostring(name) .. ")")
    if type(wingman_state) == "table" then
        local current_turn = 0
        if cm and type(cm.turn_number) == "function" then
            local ok, t = pcall(cm.turn_number, cm)
            if ok then current_turn = tonumber(t) or 0 end
        end
        wingman_state.mark_war_event(current_turn)
        local settings = wingman_state.get_settings()
        if settings.wingman_break_on_war_declaration ~= false then
            wingman_state.set_breakpoint("war_declared", name)
        end
    end
end

--- Listener callback for BattleCompleted. Clears pending battle and tries
-- to dismiss the results panel when allowed by settings.
function wingman_safety.on_battle_completed(context)
    if type(wingman_state) == "table" and type(wingman_state.set_pending_battle) == "function" then
        wingman_state.set_pending_battle(nil)
    end

    -- Also clear the registry copy used by the battle script.
    if cm and type(cm.save_named_value) == "function" then
        pcall(cm.save_named_value, cm, "wingman.v1.pending_battle", nil)
    end

    if not wingman_safety.mp_guard("on_battle_completed") then
        return
    end

    local settings
    if type(wingman_state) == "table" and type(wingman_state.get_settings) == "function" then
        settings = wingman_state.get_settings()
    end
    settings = settings or {}
    if settings.wingman_auto_dismiss_battle_results then
        -- Fire-and-forget; the helper logs internally.
        local _, status = wingman_safety.dismiss_battle_result_if_safe()
        debug("on_battle_completed: dismiss status=" .. tostring(status))
    end
end

-- ---------------------------------------------------------------------------
-- Listener registration
-- ---------------------------------------------------------------------------

--- Register safety listeners. Idempotent — calling twice is a no-op.
function wingman_safety.register_listeners()
    if listeners_registered then
        debug("register_listeners: already registered; skipping")
        return true
    end

    local ok_panel = wingman_listeners.register(
        LISTENER_NAMES.panel, "PanelOpenedCampaign", true,
        function(context) wingman_safety.on_panel_opened(context) end, false)

    local ok_battle = wingman_listeners.register(
        LISTENER_NAMES.battle_done, "BattleCompleted", true,
        function(context) wingman_safety.on_battle_completed(context) end, false)

    local ok_war = wingman_listeners.register(
        LISTENER_NAMES.war, "FactionJoinsWar", true,
        function(context) wingman_safety.on_faction_joins_war(context) end, false)

    listeners_registered = ok_panel or ok_battle or ok_war
    log("register_listeners: panel=" .. tostring(ok_panel)
        .. " battle=" .. tostring(ok_battle)
        .. " war=" .. tostring(ok_war))
    return listeners_registered
end

--- Remove all safety listeners so a save/load reload can re-register cleanly.
function wingman_safety.unregister_listeners()
    for _, name in pairs(LISTENER_NAMES) do
        wingman_listeners.unregister(name)
    end
    listeners_registered = false
    log("unregister_listeners: cleared")
    return true
end

-- ---------------------------------------------------------------------------
-- Public convenience: error-safe mode delegate
-- ---------------------------------------------------------------------------

function wingman_safety.enter_error_safe_mode(reason)
    if type(wingman_state) == "table" and type(wingman_state.enter_error_safe_mode) == "function" then
        return wingman_state.enter_error_safe_mode(reason)
    end
    warn("enter_error_safe_mode: wingman_state unavailable; cannot record reason: " .. tostring(reason))
    return false
end