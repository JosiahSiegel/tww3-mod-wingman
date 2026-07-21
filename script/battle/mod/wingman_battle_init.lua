--[[
Wingman — battle-mode bootstrap and scripted AI takeover.

Owns:
  - Reading the campaign-side settings out of the shared `core` registry
    (battle scripts do NOT have access to `cm`).
  - Applying the player's chosen AI plan bias (attack / defend / auto)
    to the player's battle alliance after deployment.
  - Optional instant autoresolve path (only when explicitly configured).
  - Battle-state evidence logging for the S2 / S9 manual scenarios.

Public surface lives in the wingman_battle_init table; everything else is
local. Co-pilot log voice. Never throws. Lua 5.1 only.

CRITICAL: `cm` is NOT available in the battle environment. Every helper
here uses `bm` or `core` and is pcall-wrapped because engine API names
shift across patches.
]]

wingman_battle_init = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local KEY_GLOBAL_SETTINGS = "wingman.v1.global_settings"

-- Phase strings vary by patch; we accept either the standard "Deployed"
-- phase or the older "deployment_complete" / "in_battle" aliases.
local DEPLOYED_PHASES = {
    "Deployed",
    "deployment_complete",
    "InBattle",
    "in_battle",
    "BattleStarted",
    "Battle",
}

local PHASE_START = {
    "Deployment",
    "PreBattle",
    "Loading",
    "LoadingBattle",
}

-- MODE_* and BIAS_* constants live in the campaign-side
-- wingman_constants module. The battle state is a separate Lua VM
-- and can't `require` directly, so we dofile the campaign-side file
-- from this mod's known install layout. The path is the same in
-- every TWW3 install (the script pack layout is fixed), so this is
-- safe to do unconditionally.
--
-- Pre-fix code duplicated the string values as wingman_battle_init.*
-- aliases. The duplication was kept in sync by a test, but a
-- constant added in one file but not the other would silently drift.
-- Now both states read the same source of truth.
local _constants_path = "script/campaign/mod/wingman_constants.lua"
local ok_constants, constants_or_err = pcall(dofile, _constants_path)
if not ok_constants or type(constants_or_err) ~= "table" then
    -- Defensive: if the campaign-side file can't be loaded, fall back
    -- to the historical string values so the battle side still works
    -- (engine ships, automation runs, just with the old hard-coded
    -- values). Logged as a warning so the operator notices.
    wingman_battle_init.MODE_SCRIPTED_AI              = "scripted_ai"
    wingman_battle_init.MODE_AUTORESOLVE_IF_FAVORABLE = "autoresolve_if_favorable"
    wingman_battle_init.MODE_PAUSE_TO_CHOOSE          = "pause_to_choose"
    wingman_battle_init.MODE_MANUAL_OBSERVE           = "manual_observe"
    wingman_battle_init.BIAS_AUTO   = "auto"
    wingman_battle_init.BIAS_ATTACK = "attack"
    wingman_battle_init.BIAS_DEFEND = "defend"
    if out and type(out.tag) == "table" and type(out.tag.fight) == "function" then
        out.tag.fight("[Wingman][BATTLE] constants load failed: " .. tostring(constants_or_err))
    end
else
    wingman_battle_init.MODE_SCRIPTED_AI              = constants_or_err.MODE_SCRIPTED_AI
    wingman_battle_init.MODE_AUTORESOLVE_IF_FAVORABLE = constants_or_err.MODE_AUTORESOLVE_IF_FAVORABLE
    wingman_battle_init.MODE_PAUSE_TO_CHOOSE          = constants_or_err.MODE_PAUSE_TO_CHOOSE
    wingman_battle_init.MODE_MANUAL_OBSERVE           = constants_or_err.MODE_MANUAL_OBSERVE
    wingman_battle_init.BIAS_AUTO   = constants_or_err.BIAS_AUTO
    wingman_battle_init.BIAS_ATTACK = constants_or_err.BIAS_ATTACK
    wingman_battle_init.BIAS_DEFEND = constants_or_err.BIAS_DEFEND
end

local VERSION_STRING = "0.1.0-alpha"

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local state = {
    initialized = false,
    mode        = wingman_battle_init.MODE_MANUAL_OBSERVE,
    bias        = wingman_battle_init.BIAS_AUTO,
    enabled     = false,
    threshold   = 60,
    enable_dismiss = true,
}

-- ---------------------------------------------------------------------------
-- Logging — battle environment lacks `out.tag` in some patches; always
-- fall back to print.
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
    -- Battle env has no state, so we read the debug flag from settings.
    local s = state and state.settings
    if not s or s.wingman_debug_logging ~= true then return end
    log("[DBG] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Defensive registry helpers
-- ---------------------------------------------------------------------------

local function safe_load_registry(key)
    if not core or type(core.svr_load_registry_string) ~= "function" then return nil end
    local ok, val = pcall(core.svr_load_registry_string, core, key)
    if not ok then
        warn("svr_load_registry_string failed for " .. tostring(key) .. ": " .. tostring(val))
        return nil
    end
    return val
end

-- ---------------------------------------------------------------------------
-- JSON decode — battle env may lack json; fall back to a key:value parser
-- that understands the small flat shape we persist from campaign-side.
-- ---------------------------------------------------------------------------

local function decode_settings_string(raw)
    if type(raw) ~= "string" or raw == "" then return nil end

    if json and type(json.decode) == "function" then
        local ok, result = pcall(json.decode, raw)
        if ok and type(result) == "table" then return result end
    end

    -- Minimal flat-only fallback parser. Accepts strings of the form
    -- {"k":v,"k":"v","k":true,"k":false,"k":number}. Anything else is
    -- ignored rather than guessed at.
    local result = {}
    local pos = 1
    local len = #raw
    local function skip_ws()
        while pos <= len and raw:sub(pos, pos):match("[%s,]") do
            pos = pos + 1
        end
    end
    local function read_quoted_string()
        -- assumes pos is on the opening quote
        if raw:sub(pos, pos) ~= '"' then return nil end
        pos = pos + 1
        local buf = {}
        while pos <= len do
            local c = raw:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(buf) end
            if c == "\\" and pos < len then
                local nxt = raw:sub(pos + 1, pos + 1)
                if     nxt == "n" then buf[#buf + 1] = "\n"
                elseif nxt == "r" then buf[#buf + 1] = "\r"
                elseif nxt == "t" then buf[#buf + 1] = "\t"
                elseif nxt == "\\" then buf[#buf + 1] = "\\"
                elseif nxt == '"' then buf[#buf + 1] = '"'
                else buf[#buf + 1] = nxt end
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return nil
    end
    local function read_value()
        skip_ws()
        if pos > len then return nil end
        local c = raw:sub(pos, pos)
        if c == '"' then
            return read_quoted_string()
        elseif c == "t" and raw:sub(pos, pos + 3) == "true" then
            pos = pos + 4; return true
        elseif c == "f" and raw:sub(pos, pos + 4) == "false" then
            pos = pos + 5; return false
        elseif c == "n" and raw:sub(pos, pos + 3) == "null" then
            pos = pos + 4; return nil
        else
            -- number or bare token
            local s, e = raw:find("[^,}]*", pos)
            if not s then return nil end
            local tok = raw:sub(s, e):gsub("^%s+", ""):gsub("%s+$", "")
            pos = e + 1
            local n = tonumber(tok)
            if n then return n end
            return tok
        end
    end
    local function read_key()
        skip_ws()
        if pos > len then return nil end
        return read_quoted_string()
    end

    skip_ws()
    if raw:sub(pos, pos) ~= "{" then return nil end
    pos = pos + 1
    while pos <= len do
        skip_ws()
        if raw:sub(pos, pos) == "}" then pos = pos + 1; break end
        local k = read_key()
        if not k then return result end
        skip_ws()
        if raw:sub(pos, pos) ~= ":" then return result end
        pos = pos + 1
        local v = read_value()
        if k ~= nil then result[k] = v end
        skip_ws()
        if raw:sub(pos, pos) == "," then pos = pos + 1 end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Public: settings reader
-- ---------------------------------------------------------------------------

--- Read battle-relevant settings from the shared `core` registry.
-- Returns a validated table with defaults filled in for missing keys.
-- Never throws.
function wingman_battle_init.read_battle_settings()
    local raw = safe_load_registry(KEY_GLOBAL_SETTINGS)
    local parsed = decode_settings_string(raw)
    if type(parsed) ~= "table" then
        parsed = {}
    end

    -- Validate mode.
    local mode = parsed.wingman_battle_control_mode
    if mode ~= wingman_battle_init.MODE_SCRIPTED_AI
            and mode ~= wingman_battle_init.MODE_AUTORESOLVE_IF_FAVORABLE
            and mode ~= wingman_battle_init.MODE_PAUSE_TO_CHOOSE
            and mode ~= wingman_battle_init.MODE_MANUAL_OBSERVE then
        if mode ~= nil then
            warn("read_battle_settings: invalid mode '" .. tostring(mode) .. "', using default")
        end
        mode = wingman_battle_init.MODE_SCRIPTED_AI
    end

    -- Validate bias.
    local bias = parsed.wingman_battle_plan_bias
    if bias ~= wingman_battle_init.BIAS_AUTO
            and bias ~= wingman_battle_init.BIAS_ATTACK
            and bias ~= wingman_battle_init.BIAS_DEFEND then
        bias = wingman_battle_init.BIAS_AUTO
    end

    local threshold = tonumber(parsed.wingman_autoresolve_threshold)
    if threshold == nil or threshold < 0 or threshold > 100 then
        threshold = 60
    end

    local enabled = parsed.wingman_battle_handover_enabled == true

    return {
        wingman_enabled                       = parsed.wingman_enabled == true,
        wingman_battle_handover_enabled       = enabled,
        wingman_battle_control_mode           = mode,
        wingman_battle_plan_bias              = bias,
        wingman_autoresolve_threshold         = threshold,
        wingman_auto_dismiss_battle_results   = parsed.wingman_auto_dismiss_battle_results ~= false,
        wingman_debug_logging                 = parsed.wingman_debug_logging == true,
    }
end

-- ---------------------------------------------------------------------------
-- Public: init — call once after battle script load
-- ---------------------------------------------------------------------------

function wingman_battle_init.init()
    if state.initialized then
        debug("init: already initialized; reloading settings")
    end

    local settings = wingman_battle_init.read_battle_settings()
    state.settings         = settings
    state.mode             = settings.wingman_battle_control_mode
    state.bias             = settings.wingman_battle_plan_bias
    state.enabled          = settings.wingman_battle_handover_enabled
    state.threshold        = settings.wingman_autoresolve_threshold
    state.enable_dismiss   = settings.wingman_auto_dismiss_battle_results
    state.initialized      = true

    log(string.format("battle init ok. v%s mode=%s bias=%s enabled=%s threshold=%d",
        VERSION_STRING,
        tostring(state.mode),
        tostring(state.bias),
        tostring(state.enabled),
        tonumber(state.threshold) or 0))
    return true
end

-- ---------------------------------------------------------------------------
-- Public: log_battle_state — capture evidence for S2 / S9
-- ---------------------------------------------------------------------------

function wingman_battle_init.log_battle_state()
    if not state.initialized then wingman_battle_init.init() end

    local lines = {}
    lines[#lines + 1] = string.format("v=%s mode=%s bias=%s enabled=%s threshold=%d",
        VERSION_STRING,
        tostring(state.mode),
        tostring(state.bias),
        tostring(state.enabled),
        tonumber(state.threshold) or 0)

    -- bm is the only handle the battle env exposes for queries. Wrap every
    -- call so a missing API never aborts the log line.
    if bm then
        local ok_la, local_alliance = pcall(function()
            if type(bm.local_alliance) == "function" then
                return bm:local_alliance()
            end
        end)
        if ok_la then
            lines[#lines + 1] = "local_alliance=" .. tostring(local_alliance)
        else
            lines[#lines + 1] = "local_alliance=<unavailable>"
        end

        local ok_al, alliances = pcall(function()
            if type(bm.alliances) == "function" then
                return bm:alliances()
            end
        end)
        if ok_la and alliances then
            local count_ok, n = pcall(function()
                if type(alliances.num_items) == "function" then
                    return alliances:num_items()
                end
                if type(alliances.num_children) == "function" then
                    return alliances:num_children()
                end
                return -1
            end)
            lines[#lines + 1] = "alliance_count=" .. tostring(count_ok and n or -1)
        end

        local ok_phase, phase = pcall(function()
            if type(bm.current_phase) == "function" then return bm:current_phase() end
            if type(bm.get_current_phase) == "function" then return bm:get_current_phase() end
            return nil
        end)
        lines[#lines + 1] = "phase=" .. tostring(ok_phase and phase or "<unavailable>")
    else
        lines[#lines + 1] = "bm=<missing>"
    end

    log("battle_state: " .. table.concat(lines, " | "))
    return true
end

-- ---------------------------------------------------------------------------
-- Public: apply_ai_plan — force scripted AI plan on the player alliance
-- ---------------------------------------------------------------------------

--- Force the player's alliance onto the configured AI plan. Safe to call
-- repeatedly; only takes effect on the first invocation per phase.
function wingman_battle_init.apply_ai_plan()
    if not state.initialized then wingman_battle_init.init() end

    if not state.enabled then
        debug("apply_ai_plan: battle handover disabled in settings")
        return false, "disabled"
    end

    if state.mode == wingman_battle_init.MODE_MANUAL_OBSERVE then
        debug("apply_ai_plan: manual_observe mode; not touching the alliance")
        return false, "manual_observe"
    end

    if state.mode == wingman_battle_init.MODE_AUTORESOLVE_IF_FAVORABLE then
        -- For v0.1 the autoresolve decision is made on the campaign side;
        -- the battle environment only logs that it's aware.
        log("apply_ai_plan: autoresolve_if_favorable — battle env leaves decision to campaign side")
        return false, "autoresolve_mode"
    end

    if state.mode == wingman_battle_init.MODE_PAUSE_TO_CHOOSE then
        log("apply_ai_plan: pause_to_choose — waiting for player to pick")
        return false, "pause_mode"
    end

    -- Default + scripted_ai: apply the bias to the player alliance.
    if not bm then
        warn("apply_ai_plan: bm missing; cannot force AI plan")
        return false, "no_bm"
    end

    local ok_alliances, alliances = pcall(function()
        if type(bm.alliances) ~= "function" then return nil end
        return bm:alliances()
    end)
    if not ok_alliances or not alliances then
        warn("apply_ai_plan: bm:alliances() failed")
        return false, "no_alliances"
    end

    local ok_la, local_alliance_id = pcall(function()
        if type(bm.local_alliance) ~= "function" then return nil end
        return bm:local_alliance()
    end)
    if not ok_la or local_alliance_id == nil then
        warn("apply_ai_plan: bm:local_alliance() failed")
        return false, "no_local_alliance"
    end

    local ok_item, alliance = pcall(function()
        if type(alliances.item) ~= "function" then return nil end
        return alliances:item(local_alliance_id)
    end)
    if not ok_item or not alliance then
        warn("apply_ai_plan: alliances:item(" .. tostring(local_alliance_id) .. ") failed")
        return false, "no_alliance_item"
    end

    -- Bias dispatch. The plan_type_* APIs may have different names in
    -- future patches; if force_ai_plan_type_attack is missing, fall back
    -- to attack_any_enemy_within_range (older alias).
    local plan_fn
    local plan_label
    if state.bias == wingman_battle_init.BIAS_DEFEND then
        plan_fn = type(alliance.force_ai_plan_type_defend) == "function"
                  and alliance.force_ai_plan_type_defend
                  or  nil
        plan_label = "defend"
    elseif state.bias == wingman_battle_init.BIAS_ATTACK then
        plan_fn = type(alliance.force_ai_plan_type_attack) == "function"
                  and alliance.force_ai_plan_type_attack
                  or  nil
        plan_label = "attack"
    else
        -- auto: bias toward attack (the game will tone it down if needed).
        plan_fn = type(alliance.force_ai_plan_type_attack) == "function"
                  and alliance.force_ai_plan_type_attack
                  or  nil
        plan_label = "auto->attack"
    end

    if not plan_fn then
        warn("apply_ai_plan: alliance has no force_ai_plan_type_* method; this patch may not support scripted plan forcing")
        return false, "no_plan_api"
    end

    local ok_force, force_err = pcall(plan_fn, alliance)
    if not ok_force then
        warn("apply_ai_plan: force_ai_plan_type_" .. tostring(plan_label)
            .. " failed: " .. tostring(force_err))
        return false, "force_failed"
    end

    log(string.format("AI plan applied: %s (alliance=%d)",
        tostring(plan_label), tonumber(local_alliance_id) or -1))

    -- Optional 5-second verification callback: log whether the AI appears
    -- to be taking actions. bm:callback registers a delayed callback that
    -- fires once the battle has had time to start the AI tick.
    local ok_cb, cb_err = pcall(function()
        if type(bm.callback) ~= "function" then return nil end
        return bm:callback(function()
            local ok_ai, ai_planner = pcall(function()
                if type(bm.get_script_ai_planner) == "function" then
                    return bm:get_script_ai_planner()
                end
                return nil
            end)
            if ok_ai and ai_planner then
                log("scripted AI planner active — wingman is at the stick")
            else
                log("scripted AI planner probe failed — verify visually that units are acting")
            end
        end, 5000)
    end)
    if not ok_cb and cb_err ~= nil then
        debug("apply_ai_plan: bm:callback probe failed: " .. tostring(cb_err))
    end

    return true, plan_label
end

-- ---------------------------------------------------------------------------
-- Public: maybe_end_battle — instant autoresolve path. For v0.1 we only log;
-- the real autoresolve is decided on the campaign side and never reaches
-- the battle script because the pre-battle panel was short-circuited. If
-- the engine still launches the battle environment anyway, we leave the
-- player in control rather than trying to mutate mid-battle.
-- ---------------------------------------------------------------------------

function wingman_battle_init.maybe_end_battle()
    if not state.initialized then wingman_battle_init.init() end

    if not state.enabled then
        return false, "disabled"
    end

    if state.mode == wingman_battle_init.MODE_AUTORESOLVE_IF_FAVORABLE then
        log("maybe_end_battle: autoresolve mode — campaign side should have already decided; "
            .. "if you see this in battle, the pre-battle click missed and player is now in command")
        return false, "campaign_decides"
    end

    debug("maybe_end_battle: not in autoresolve mode; no-op")
    return false, "not_autoresolve"
end

-- ---------------------------------------------------------------------------
-- Phase-change callback wiring
-- ---------------------------------------------------------------------------

local function on_phase_change(prev, curr)
    if not curr then return end
    for _, p in ipairs(DEPLOYED_PHASES) do
        if curr == p then
            wingman_battle_init.log_battle_state()
            wingman_battle_init.apply_ai_plan()
            return
        end
    end
    for _, p in ipairs(PHASE_START) do
        if curr == p then
            wingman_battle_init.log_battle_state()
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Self-registration at file-load — guarded.
-- ---------------------------------------------------------------------------

if bm then
    -- Read settings immediately so logs from the very first frame are useful.
    local ok_pre, _ = pcall(wingman_battle_init.init)
    if not ok_pre then
        warn("self-init threw; battle init will run lazily on first phase callback")
    end

    -- Hook a phase-change callback if the API is available.
    local ok_hook, err_hook = pcall(function()
        if type(bm.register_phase_change_callback) == "function" then
            bm:register_phase_change_callback(function(prev, curr)
                local ok_cb, cb_err = pcall(on_phase_change, prev, curr)
                if not ok_cb then
                    warn("phase_change callback threw: " .. tostring(cb_err))
                end
            end)
        end
    end)
    if not ok_hook and err_hook ~= nil then
        debug("phase-change registration probe failed: " .. tostring(err_hook))
    end
else
    warn("battle script loaded outside battle environment (bm missing); wingman_battle_init disabled")
end

-- ---------------------------------------------------------------------------
-- Read-only snapshot for diagnostics
-- ---------------------------------------------------------------------------

function wingman_battle_init._snapshot()
    return {
        initialized    = state.initialized,
        mode           = state.mode,
        bias           = state.bias,
        enabled        = state.enabled,
        threshold      = state.threshold,
        enable_dismiss = state.enable_dismiss,
    }
end