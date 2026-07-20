--[[
Wingman — campaign-side battle handover.

Owns:
  - The BattleBeingFought / BattleCompleted / PendingBattle listeners that
    decide what to do with the next manual battle the player is dragged
    into (force scripted AI, autoresolve when favorable, pause, or just
    watch).
  - The pending-battle payload stashed in wingman_state so the battle
    script can pick it up via the shared `core` registry when it boots.

Public surface lives in the wingman_battle table; everything else is local.

Co-pilot log voice. Never throws. Lua 5.1 only.
]]

wingman_battle = {}

-- ---------------------------------------------------------------------------
-- Constants — keep in sync with wingman_state DEFAULTS / schema-of-record.
-- ---------------------------------------------------------------------------

wingman_battle.MODE_SCRIPTED_AI             = "scripted_ai"
wingman_battle.MODE_AUTORESOLVE_IF_FAVORABLE = "autoresolve_if_favorable"
wingman_battle.MODE_PAUSE_TO_CHOOSE         = "pause_to_choose"
wingman_battle.MODE_MANUAL_OBSERVE          = "manual_observe"

wingman_battle.BIAS_AUTO   = "auto"
wingman_battle.BIAS_ATTACK = "attack"
wingman_battle.BIAS_DEFEND = "defend"

-- Persistence key literals — duplicated locally so this module is independently
-- loadable without having to wait for state. They must match wingman_state.
local KEY_PENDING_BATTLE   = "wingman.v1.pending_battle"
local KEY_LAST_BATTLE_RES  = "wingman.v1.last_battle_result"
local KEY_GLOBAL_SETTINGS  = "wingman.v1.global_settings"

-- Listener names — prefixed so wingman_init can sweep them on shutdown.
local LISTENER_NAMES = {
    pending       = "wingman_battle_pending",
    battle_start  = "wingman_battle_start",
    battle_done   = "wingman_battle_done",
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
    local ok_state = type(wingman_state) == "table" and type(wingman_state.get_settings) == "function"
    if not ok_state then return end
    local settings = wingman_state.get_settings()
    if not settings or settings.wingman_debug_logging ~= true then return end
    log("[DBG] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Defensive persistence helpers — every call goes through pcall.
-- Battle completion may fire after a campaign quit, so we deliberately do not
-- hard-require wingman_state. Each helper probes for the API first.
-- ---------------------------------------------------------------------------

local function safe_save_named(key, value)
    if not cm or type(cm.save_named_value) ~= "function" then return false end
    local ok, err = pcall(cm.save_named_value, cm, key, value)
    if not ok then
        warn("save_named_value failed for " .. tostring(key) .. ": " .. tostring(err))
        return false
    end
    return true
end

local function safe_load_registry(key)
    if not core or type(core.svr_load_registry_string) ~= "function" then return nil end
    local ok, val = pcall(core.svr_load_registry_string, core, key)
    if not ok then
        warn("svr_load_registry_string failed for " .. tostring(key) .. ": " .. tostring(val))
        return nil
    end
    return val
end

local function safe_save_registry(key, value)
    if not core or type(core.svr_save_registry_string) ~= "function" then return false end
    local ok, err = pcall(core.svr_save_registry_string, core, key, value)
    if not ok then
        warn("svr_save_registry_string failed for " .. tostring(key) .. ": " .. tostring(err))
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Settings reading — prefer wingman_state, fall back to a frozen defaults
-- table so listeners never crash on missing keys.
-- ---------------------------------------------------------------------------

local function current_turn_or_zero()
    if not cm or type(cm.turn_number) ~= "function" then return 0 end
    local ok, v = pcall(cm.turn_number, cm)
    if not ok then return 0 end
    return tonumber(v) or 0
end

-- ---------------------------------------------------------------------------
-- Settings reading — prefer wingman_state, fall back to registry.
-- ---------------------------------------------------------------------------

local function load_settings()
    if type(wingman_state) == "table" and type(wingman_state.get_settings) == "function" then
        return wingman_state.get_settings()
    end
    -- No state available — return a frozen defaults table so callers can
    -- still index into known keys without crashing. We do NOT touch the
    -- persisted registry directly because that would risk an out-of-sync
    -- contract with wingman_state; the safe path is to no-op automation.
    warn("load_settings: wingman_state unavailable; battle handover disabled")
    return {
        wingman_enabled                       = false,
        wingman_battle_handover_enabled       = false,
        wingman_battle_control_mode           = wingman_battle.MODE_SCRIPTED_AI,
        wingman_battle_plan_bias              = wingman_battle.BIAS_AUTO,
        wingman_autoresolve_threshold         = 60,
        wingman_auto_dismiss_battle_results   = true,
        wingman_break_on_pending_battle       = true,
        wingman_debug_logging                 = false,
    }
end

-- ---------------------------------------------------------------------------
-- Pre-battle panel probing — best-effort autoresolve click.
-- In TWW3 there's no stable public `force_autoresolve` API. The community
-- pattern is to short-circuit the pre-battle panel by clicking its
-- autoresolve button. We try a few candidate component chains; if none
-- resolve, we log + leave the breakpoint active. The threshold check
-- above is the real logic — the click is just the execution step.
-- ---------------------------------------------------------------------------

local AUTORESOLVE_CANDIDATES = {
    { "pre_battle_panel", "button_autoresolve" },
    { "pre_battle_panel", "autoresolve_button" },
    { "pre_battle_panel", "ButtonAutoresolve" },
    { "pre_battle_panel", "auto_resolve_button" },
    { "pre_battle_panel", "dy_autoresolve" },
    { "pre_battle_panel", "Autoresolve" },
    { "PreBattlePanel",    "Autoresolve" },
    { "PreBattlePanel",    "AutoResolve" },
}

local function find_child_chain(root, names)
    if not root or type(root.FindChild) ~= "function" then return nil end
    local current = root
    for i = 1, #names do
        local ok, next_node = pcall(current.FindChild, current, names[i])
        if not ok or not next_node then return nil end
        current = next_node
    end
    return current
end

local function find_autoresolve_button(root)
    if not root then return nil end
    for _, names in ipairs(AUTORESOLVE_CANDIDATES) do
        local node = find_child_chain(root, names)
        if node then return node end
    end
    return nil
end

local function try_click_autoresolve(reason)
    if not core or type(core.get_ui_root) ~= "function" then
        warn("autoresolve click: core.get_ui_root unavailable")
        return false, "no_core"
    end
    local ok, root = pcall(core.get_ui_root)
    if not ok or not root then
        warn("autoresolve click: ui_root unavailable")
        return false, "no_root"
    end
    local ok2, button = pcall(find_autoresolve_button, root)
    if not ok2 or not button then
        log("autoresolve click: button not found in pre-battle panel (UI path may have changed)")
        return false, "panel_missing"
    end
    if type(button.SimulateLClick) ~= "function" then
        warn("autoresolve click: button has no SimulateLClick")
        return false, "no_click"
    end
    local click_ok, click_err = pcall(button.SimulateLClick, button)
    if not click_ok then
        warn("autoresolve click: SimulateLClick failed: " .. tostring(click_err))
        return false, "click_failed"
    end
    log(string.format("autoresolve_if_favorable: forced autoresolve (%s)", tostring(reason or "?")))
    return true, "ok"
end

-- ---------------------------------------------------------------------------
-- Pending-battle cache probes — these are the v0.1 documented public APIs.
-- Every call is pcall-wrapped because patches have moved them around.
-- ---------------------------------------------------------------------------

local function read_cache_value(method_name)
    if not cm or type(cm[method_name]) ~= "function" then return nil end
    local ok, v = pcall(cm[method_name], cm)
    if not ok then return nil end
    return v
end

local function predict_favorable(threshold_percent)
    -- Compute a coarse "is this battle favorable?" verdict from public cache
    -- methods. Returns (favorable:bool, info:table). Both are best-effort;
    -- the boolean drives the autoresolve decision, the table is logged.
    local threshold = tonumber(threshold_percent) or 60

    local human_victory  = read_cache_value("pending_battle_cache_human_victory")
    local attacker_value = tonumber(read_cache_value("pending_battle_cache_attacker_value")) or nil
    local defender_value = tonumber(read_cache_value("pending_battle_cache_defender_value")) or nil
    local attacker_win   = read_cache_value("pending_battle_cache_attacker_victory")
    local defender_win   = read_cache_value("pending_battle_cache_defender_victory")

    local info = {
        threshold       = threshold,
        human_victory   = human_victory,
        attacker_value  = attacker_value,
        defender_value  = defender_value,
        attacker_victory = attacker_win,
        defender_victory = defender_win,
    }

    -- Human-victory bool is the strongest signal: it is true when the game
    -- predicts the human-controlled side wins. v0.1 treats it as the
    -- primary decision. We still log the value/defender ratio for evidence.
    if human_victory == true then
        info.reason = "human_victory_cache_true"
        return true, info
    end

    -- Fallback: compute ratio from attacker/defender values. Player is
    -- usually attacker, but the engine reports both sides symmetrically so
    -- we look at whichever ratio is more favorable.
    if attacker_value and defender_value and defender_value > 0 and attacker_value > 0 then
        local ratio_pct
        -- If we (human) are attacker, higher defender_value relative to
        -- attacker_value is BAD for us. If we are defender, the inverse.
        -- The cache APIs don't tell us which side we are; v0.1 uses the
        -- simpler "either side > threshold%" heuristic and logs both.
        local max_side = math.max(attacker_value, defender_value)
        local min_side = math.min(attacker_value, defender_value)
        if min_side > 0 then
            ratio_pct = (max_side / min_side) * 100.0
            info.ratio_pct = ratio_pct
        end
        -- The ratio here is misleading without knowing our side; treat it
        -- as advisory only. We only force autoresolve if the explicit
        -- human_victory cache said yes — v0.1 conservative behavior.
        info.reason = "ratio_advisory_only"
        return false, info
    end

    info.reason = "no_cache_signal"
    return false, info
end

-- ---------------------------------------------------------------------------
-- Public helpers — payload plumbing.
-- ---------------------------------------------------------------------------

--- Serialize the battle handover preference for the battle environment.
-- Stored both in state and in the shared `core` registry so battle scripts
-- can read it without going through `cm`.
function wingman_battle.queue_battle_handover(battle_context)
    local settings = load_settings()
    local payload = {
        mode      = settings.wingman_battle_control_mode or wingman_battle.MODE_SCRIPTED_AI,
        bias      = settings.wingman_battle_plan_bias or wingman_battle.BIAS_AUTO,
        threshold = settings.wingman_autoresolve_threshold or 60,
        queued_at = current_turn_or_zero(),
        enable_dismiss = settings.wingman_auto_dismiss_battle_results == true,
    }

    -- Persist through wingman_state when available; this is the canonical
    -- savegame-bound copy.
    if type(wingman_state) == "table" and type(wingman_state.set_pending_battle) == "function" then
        wingman_state.set_pending_battle(payload)
    end

    -- Also write to the shared registry so the battle script can read it
    -- without touching cm. We use the same JSON the state module would
    -- produce; encoding falls back to a minimal tostring if json libs are
    -- unavailable in this environment.
    local ok_json, encoded = pcall(function()
        if type(json_encode) == "function" then return json_encode(payload) end
        if json and type(json.encode) == "function" then return json.encode(payload) end
        -- Minimal fallback: only this flat table, never nested.
        local parts = {}
        for k, v in pairs(payload) do
            local key = tostring(k):gsub('"', '\\"')
            local val
            if type(v) == "string" then
                val = '"' .. tostring(v):gsub('"', '\\"') .. '"'
            else
                val = tostring(v)
            end
            parts[#parts + 1] = '"' .. key .. '":' .. val
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end)
    if ok_json and type(encoded) == "string" then
        safe_save_registry(KEY_PENDING_BATTLE, encoded)
    end

    debug("queue_battle_handover: " .. tostring(payload.mode)
        .. " bias=" .. tostring(payload.bias)
        .. " threshold=" .. tostring(payload.threshold))
    return payload
end

--- Reset the pending-battle payload everywhere it's stored.
function wingman_battle.clear_pending_battle()
    if type(wingman_state) == "table" and type(wingman_state.set_pending_battle) == "function" then
        wingman_state.set_pending_battle(nil)
    end
    safe_save_registry(KEY_PENDING_BATTLE, "")
    safe_save_named(KEY_PENDING_BATTLE, nil)
    return true
end

-- ---------------------------------------------------------------------------
-- Listener callbacks
-- ---------------------------------------------------------------------------

--- PendingBattle — fires before the pre-battle panel is shown.
-- This is the right place to evaluate the autoresolve-if-favorable policy
-- because the cache APIs are still populated.
function wingman_battle.on_pending_battle(context)
    if not wingman_safety or type(wingman_safety.mp_guard) ~= "function"
            or not wingman_safety.mp_guard("on_pending_battle") then
        return
    end

    local settings = load_settings()
    if not settings.wingman_enabled or not settings.wingman_battle_handover_enabled then
        debug("on_pending_battle: battle handover disabled in settings")
        return
    end

    -- If the battle already autoresolved we don't need to intervene.
    if context and type(context.is_autoresolved) == "function" then
        local ok, was_auto = pcall(context.is_autoresolved, context)
        if ok and was_auto then
            debug("on_pending_battle: already autoresolved; no intervention")
            return
        end
    end

    local mode = settings.wingman_battle_control_mode or wingman_battle.MODE_SCRIPTED_AI

    -- Dispatch on mode.
    if mode == wingman_battle.MODE_AUTORESOLVE_IF_FAVORABLE then
        local favorable, info = predict_favorable(settings.wingman_autoresolve_threshold)
        debug("on_pending_battle: autoresolve probe "
            .. "human_victory=" .. tostring(info.human_victory)
            .. " attacker_value=" .. tostring(info.attacker_value)
            .. " defender_value=" .. tostring(info.defender_value)
            .. " reason=" .. tostring(info.reason))

        if favorable then
            -- Stash the pending payload (mode = autoresolve) so the battle
            -- environment knows not to apply scripted AI if the click fails
            -- and we fall through to manual play.
            if type(wingman_state) == "table" and type(wingman_state.set_breakpoint) == "function" then
                wingman_state.set_breakpoint("battle_autoresolve_forced", info)
            end
            local clicked, status = try_click_autoresolve(info.reason)
            if clicked then
                -- Still record the queued handover in case the click is
                -- processed after the listener returns.
                wingman_battle.queue_battle_handover(context)
                return
            end
            warn("autoresolve_if_favorable: click failed (" .. tostring(status)
                .. "); leaving breakpoint active so player can choose")
            -- Fall through to pause-for-player behavior below.
            if type(wingman_state) == "table" and type(wingman_state.set_breakpoint) == "function" then
                wingman_state.set_breakpoint("battle_unfavorable", info)
            end
            return
        end

        -- Not favorable — pause so player can decide.
        log("autoresolve_if_favorable: odds not in our favor; pausing for player")
        if settings.wingman_break_on_pending_battle ~= false
                and type(wingman_state) == "table"
                and type(wingman_state.set_breakpoint) == "function" then
            wingman_state.set_breakpoint("battle_unfavorable", info)
        end
        return
    end

    if mode == wingman_battle.MODE_PAUSE_TO_CHOOSE then
        log("pause_to_choose: handing the wheel back so you can pick")
        if settings.wingman_break_on_pending_battle ~= false
                and type(wingman_state) == "table"
                and type(wingman_state.set_breakpoint) == "function" then
            wingman_state.set_breakpoint("battle_pause", context)
        end
        return
    end

    if mode == wingman_battle.MODE_MANUAL_OBSERVE then
        log("manual_observe: watching but not touching — your call")
        return
    end

    -- Default + scripted_ai: queue the battle for the battle environment
    -- to take over via the scripted AI planner.
    wingman_battle.queue_battle_handover(context)
    log(string.format("scripted_ai queued. bias=%s threshold=%d",
        tostring(settings.wingman_battle_plan_bias),
        tonumber(settings.wingman_autoresolve_threshold) or 0))
end

--- BattleBeingFought — fires when the battle script is starting.
-- We use this to confirm the queued payload is in place and to clear it
-- after the battle environment has had a chance to read it.
function wingman_battle.on_battle_being_fought(context)
    if not wingman_safety or type(wingman_safety.mp_guard) ~= "function"
            or not wingman_safety.mp_guard("on_battle_being_fought") then
        return
    end

    local settings = load_settings()
    if not settings.wingman_enabled or not settings.wingman_battle_handover_enabled then
        debug("on_battle_being_fought: battle handover disabled in settings")
        return
    end

    -- If the battle was autoresolved (cache predicted before panel opened),
    -- BattleBeingFought still fires but we shouldn't queue scripted AI.
    if context and type(context.is_autoresolved) == "function" then
        local ok, was_auto = pcall(context.is_autoresolved, context)
        if ok and was_auto then
            debug("on_battle_being_fought: autoresolved; no scripted AI takeover")
            wingman_battle.clear_pending_battle()
            return
        end
    end

    -- Make sure the payload is persisted right up to the moment the battle
    -- script boots. queue_battle_handover is idempotent.
    local payload = wingman_battle.queue_battle_handover(context)

    -- wingman_safety already listens to BattleCompleted and will clear the
    -- pending payload; we still wipe here as a defensive backstop in case
    -- the engine dispatches the events out of order on a given patch.
    log(string.format("on_battle_being_fought: payload ready (mode=%s bias=%s)",
        tostring(payload and payload.mode or "?"),
        tostring(payload and payload.bias or "?")))
end

--- BattleCompleted — fired by the engine after a battle ends. wingman_safety
-- also listens for this event to dismiss the results panel; we keep our
-- role narrow here (clear pending state, log evidence) so the dismissal
-- path lives in exactly one place.
function wingman_battle.on_battle_completed(context)
    if not wingman_safety or type(wingman_safety.mp_guard) ~= "function"
            or not wingman_safety.mp_guard("on_battle_completed") then
        return
    end

    -- Capture minimal result info for evidence logging. We do not parse the
    -- context deeply; chadvandy's BattleCompleted context varies by patch.
    local payload_str = safe_load_registry(KEY_PENDING_BATTLE) or ""
    safe_save_registry(KEY_LAST_BATTLE_RES,
        (context and tostring(context)) or "")
    debug("on_battle_completed: pending_payload_present="
        .. tostring(payload_str ~= nil and payload_str ~= ""))

    -- Clear pending state. wingman_safety.on_battle_completed also clears
    -- it; calling twice is idempotent and the worst case is a redundant
    -- save_named_value, which is already pcall-wrapped.
    wingman_battle.clear_pending_battle()
    log("on_battle_completed: pending battle cleared; safety module owns dismiss path")
end

-- ---------------------------------------------------------------------------
-- Listener registration — called by wingman_init (T7 wires this).
-- ---------------------------------------------------------------------------

function wingman_battle.register_listeners()
    if listeners_registered then
        debug("register_listeners: already registered; skipping")
        return true
    end

    local ok_pending = wingman_listeners.register(
        LISTENER_NAMES.pending, "PendingBattle", true,
        function(context) wingman_battle.on_pending_battle(context) end, false)
    local ok_start = wingman_listeners.register(
        LISTENER_NAMES.battle_start, "BattleBeingFought", true,
        function(context) wingman_battle.on_battle_being_fought(context) end, false)
    local ok_done = wingman_listeners.register(
        LISTENER_NAMES.battle_done, "BattleCompleted", true,
        function(context) wingman_battle.on_battle_completed(context) end, false)

    listeners_registered = ok_pending or ok_start or ok_done
    log(string.format("register_listeners: pending=%s start=%s done=%s",
        tostring(ok_pending), tostring(ok_start), tostring(ok_done)))
    return listeners_registered
end

function wingman_battle.unregister_listeners()
    for _, name in pairs(LISTENER_NAMES) do
        wingman_listeners.unregister(name)
    end
    listeners_registered = false
    debug("unregister_listeners: cleared")
    return true
end

-- ---------------------------------------------------------------------------
-- Self-registration at file-load — guarded so a missing `core` is a no-op.
-- T7's wingman_init also calls register_listeners() after state init, so
-- this just makes the module useful even if init hasn't run yet (e.g. for
-- early-fail testing). If core doesn't expose add_listener at load time
-- we stay silent and rely on the explicit call later.
-- ---------------------------------------------------------------------------

if core and type(core.add_listener) == "function" then
    local ok_auto, err_auto = pcall(wingman_battle.register_listeners)
    if not ok_auto then
        warn("self-register failed: " .. tostring(err_auto))
    end
end

-- Read-only snapshot for diagnostics.
function wingman_battle._snapshot()
    return {
        listeners_registered = listeners_registered,
        pending_payload      = safe_load_registry(KEY_PENDING_BATTLE),
    }
end