--[[
Wingman — state persistence and mode machine.

Owns:
  - Schema-versioned save state (in-save via cm:save_named_value).
  - Cross-restart global settings (via core:svr_save_registry_string).
  - The mode machine: disabled -> campaign_handover <-> breakpoint <-> error_safe.
  - Validation + sanitization of persisted settings.

Public surface lives in the wingman_state table; everything else is local.

Lua 5.1 syntax only (no goto, no bitwise ops). All persistence calls are
wrapped in pcall so a broken save layer cannot break gameplay.
]]

wingman_state = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

wingman_state.MODE_DISABLED    = "disabled"
wingman_state.MODE_CAMPAIGN    = "campaign_handover"
wingman_state.MODE_BREAKPOINT  = "breakpoint"
wingman_state.MODE_ERROR_SAFE  = "error_safe"

wingman_state.SCHEMA_VERSION   = 1
wingman_state.VERSION_STRING   = "0.1.0-alpha"

-- Persistence key literals. Use these strings everywhere — never inline a key.
local KEY_GLOBAL_SETTINGS      = "wingman.v1.global_settings"
local KEY_LAST_ERROR           = "wingman.v1.last_error"
local KEY_SCHEMA_VERSION       = "wingman.v1.schema_version"
local KEY_MODE                 = "wingman.v1.mode"
local KEY_CAMPAIGN_ENABLED     = "wingman.v1.campaign_enabled"
local KEY_BATTLE_ENABLED       = "wingman.v1.battle_enabled"
local KEY_LAST_TURN            = "wingman.v1.last_processed_turn"
local KEY_BREAK_REASON         = "wingman.v1.break_reason"
local KEY_RULE_PROGRESS        = "wingman.v1.rule_progress"
local KEY_PENDING_BATTLE       = "wingman.v1.pending_battle"
local KEY_MISSION_KEYS         = "wingman.v1.mission_keys"

-- ---------------------------------------------------------------------------
-- Internal state — module-private, mutated only via setters
-- ---------------------------------------------------------------------------

local state = {
    initialized         = false,
    mode                = wingman_state.MODE_DISABLED,
    settings            = nil,        -- filled in init() from DEFAULTS + persisted overrides
    last_processed_turn = 0,
    break_reason        = nil,
    break_data          = nil,
    last_error          = nil,
    last_war_event_turn = 0,          -- safety helper: turn when FactionJoinsWar last fired for player
    pending_battle      = nil,
    mission_keys        = nil,
    rule_progress       = nil,
}

-- ---------------------------------------------------------------------------
-- Defaults — schema-of-record. Any new key must be added here and validated.
-- ---------------------------------------------------------------------------

local DEFAULTS = {
-- Exposed publicly at the end of the file as wingman_state.DEFAULTS so
-- tests and external consumers can read defaults without an internal
-- accessor.
    -- General
    wingman_enabled                       = false,
    wingman_debug_logging                 = false,
    wingman_safety_level                  = "conservative",

    -- Campaign Handover
    wingman_campaign_handover_enabled     = false,
    wingman_auto_end_turn_delay_seconds   = 2,
    wingman_periodic_break_interval       = 10,
    wingman_break_on_diplomacy_panel      = true,
    wingman_break_on_war_declaration      = true,
    wingman_break_on_pending_battle       = true,

    -- Battle Handover
    wingman_battle_handover_enabled       = false,
    wingman_battle_control_mode           = wingman_constants.MODE_SCRIPTED_AI,
    wingman_battle_plan_bias              = "auto",
    wingman_autoresolve_threshold         = 60,
    wingman_auto_dismiss_battle_results   = true,

    -- Rules
    wingman_turn_cap_enabled              = false,
    wingman_turn_cap_value                = 50,
    wingman_turn_cap_outcome              = "breakpoint",
    wingman_custom_win_enabled            = false,
    wingman_required_settlements_csv      = "",
    wingman_required_defeated_factions_csv = "",
    wingman_faction_restrictions_enabled  = false,
    wingman_restriction_violation_action  = "warn_pause",

    -- AI Controller (W5) — runs on the player's faction to keep the
    -- campaign moving when wingman_campaign_handover_enabled=true.
    wingman_ai_enabled                    = true,
    wingman_ai_aggression                 = wingman_constants.AGGRESSION_AGGRESSIVE,
    wingman_ai_orders_per_turn            = 12,

    -- AI Controller (W6) — high-skill behavioral surface.
    wingman_ai_attack_adjacent            = true,
    wingman_ai_diplomacy_enabled          = false,  -- opt-in: war declarations are user-visible
    wingman_ai_diplomacy_per_turn         = 2,
    wingman_ai_research_enabled           = true,
    wingman_ai_rituals_enabled            = true,

    -- AI Controller (W7) — Autopilot + Advisory modes.
    -- Autopilot mode = full UI lock + CAI personality rewrite + scripted
    -- orders. The player is locked out of the campaign UI until they take
    -- back control via the "Wingman in control" banner button (or via the
    -- periodic breakpoint). Advisory mode = per-turn 3-button dilemma;
    -- player decides whether the AI executes the plan each turn.
    --   - wingman_ai_mode: "off" (W6 behavior), "advisory", "autopilot"
    --   - wingman_ai_autopilot_personality: CAI personality key installed
    --     on the player faction when Autopilot engages. Default = same as
    --     the highest-skill "ALPHA" context for broad compatibility. Users
    --     can pick a faction-specific famous personality (e.g.
    --     "wh3_combi_empire_franz_endgame") for a more aggressive setup.
    --   - wingman_ai_takeback_hotkey: "esc" (default) or "none". The user
    --     can take back control by holding ESC for 3 seconds (engine
    --     pattern, see cm:steal_escape_key_with_callback in vanilla).
    --   - wingman_ai_advisory_dilemma_key: dilemma key from the mod's
    --     db/dilemma_tables row, used to fire the 3-button prompt. The
    --     default placeholder is overridden in the production mod.
    wingman_ai_mode                      = "off",
    wingman_ai_autopilot_personality     = "wh3_combi_legendary_default",
    wingman_ai_takeback_hotkey           = "esc",
    wingman_ai_advisory_dilemma_key      = "wingman_advisory_default",
    -- W8 settings.
    --   - wingman_ai_build_enabled: master toggle for step_construct_buildings.
    --     The W8 implementation now actually queues buildings (W6 was a
    --     documented stub). The user can still toggle it off to disable.
    --   - wingman_ai_periodic_pause_turns: how many turns between forced
    --     "take a break" pauses (0 = never). When the count hits the
    --     interval, the next FactionTurnStart fires a 4-button dilemma
    --     (Apply / Skip / Always Apply / Take Control). "Take Control"
    --     releases Autopilot. The user can also set this to 1 to pause
    --     every turn (effectively the same as Advisory mode).
    --   - wingman_ai_heal_enabled: master toggle for step_replenish_armies.
    --   - wingman_ai_post_battle_enabled: master toggle for step_post_battle_decisions.
    --   - wingman_ai_reactive_diplo_enabled: master toggle for step_diplomatic_reactive.
    wingman_ai_build_enabled             = true,
    wingman_ai_periodic_pause_turns      = 0,
    wingman_ai_heal_enabled              = true,
    wingman_ai_post_battle_enabled       = true,
    wingman_ai_reactive_diplo_enabled    = true,
}

-- Allowed values for enum-like settings. Unknown values revert to the default.
local ALLOWED_ENUMS = {
    wingman_safety_level                  = { conservative = true, balanced = true, permissive = true },
    wingman_battle_control_mode           = {
        scripted_ai             = true,
        autoresolve_if_favorable = true,
        pause_to_choose         = true,
        manual_observe          = true,
    },
    wingman_battle_plan_bias              = { auto = true, attack = true, defend = true },
    wingman_turn_cap_outcome              = { breakpoint = true, victory = true },
    wingman_restriction_violation_action  = { warn_pause = true, pause_disable = true },
    wingman_ai_aggression                 = {
        defensive  = true,
        balanced   = true,
        aggressive = true,
    },
}

-- Slider bounds. Clamp on validate.
local BOUNDS = {
    wingman_auto_end_turn_delay_seconds   = { min = 0,   max = 10 },
    wingman_periodic_break_interval       = { min = 0,   max = 100 },
    wingman_autoresolve_threshold         = { min = 0,   max = 100 },
    wingman_turn_cap_value                = { min = 1,   max = 500 },
    wingman_ai_orders_per_turn            = { min = 1,   max = 50 },
    wingman_ai_diplomacy_per_turn         = { min = 0,   max = 10 },
}

-- ---------------------------------------------------------------------------
-- Logging helpers — always non-fatal
-- ---------------------------------------------------------------------------

local function log(msg)
    if out and out.tag and out.tag.fight then
        -- Engine-tagged log path used by chadvandy examples.
        out.tag.fight("[Wingman] " .. tostring(msg))
    else
        -- Fallback for environments without `out`.
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

local function is_debug_logging()
    if not state.initialized then return false end
    local s = state.settings
    return s and s.wingman_debug_logging == true
end

local function debug(msg)
    if not is_debug_logging() then return end
    if out and out.tag and out.tag.fight then
        out.tag.fight("[Wingman][DBG] " .. tostring(msg))
    else
        print("[Wingman][DBG] " .. tostring(msg))
    end
end

-- ---------------------------------------------------------------------------
-- Persistence helpers — every call is pcall'd
-- ---------------------------------------------------------------------------

local function safe_save_registry(key, value)
    if not core or not core.svr_save_registry_string then return false end
    -- Pass core as self to mimic core:svr_save_registry_string(key, value).
    local ok, err = pcall(core.svr_save_registry_string, core, key, value)
    if not ok then
        warn("svr_save_registry_string failed for " .. tostring(key) .. ": " .. tostring(err))
        return false
    end
    return true
end

local function safe_load_registry(key)
    if not core or not core.svr_load_registry_string then return nil end
    local ok, val = pcall(core.svr_load_registry_string, core, key)
    if not ok then
        warn("svr_load_registry_string failed for " .. tostring(key) .. ": " .. tostring(val))
        return nil
    end
    return val
end

local function safe_save_named(key, value)
    if not cm or not cm.save_named_value then return false end
    local ok, err = pcall(cm.save_named_value, cm, key, value)
    if not ok then
        warn("cm:save_named_value failed for " .. tostring(key) .. ": " .. tostring(err))
        return false
    end
    return true
end

local function safe_load_named(key)
    if not cm or not cm.load_named_value then return nil end
    local ok, val = pcall(cm.load_named_value, cm, key)
    if not ok then
        warn("cm:load_named_value failed for " .. tostring(key) .. ": " .. tostring(val))
        return nil
    end
    return val
end

-- ---------------------------------------------------------------------------
-- JSON encode/decode — uses campaign's bundled helper if available, else a
-- minimal implementation. Settings are tiny so a fallback is acceptable.
-- ---------------------------------------------------------------------------

local function json_encode(value)
    -- Prefer campaign's json helper if exposed.
    if type(json_encode_native) == "function" then
        local ok, result = pcall(json_encode_native, value)
        if ok and type(result) == "string" then return result end
    end
    if json and json.encode and type(json.encode) == "function" then
        local ok, result = pcall(json.encode, value)
        if ok and type(result) == "string" then return result end
    end

    -- Minimal fallback: only handles the table shapes we actually persist
    -- (flat key/value, plus small tables of numbers for rule_progress).
    local function encode_string(s)
        s = tostring(s)
        s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
        s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. s .. '"'
    end

    local function encode_value(v, indent)
        local t = type(v)
        if t == "nil" then return "null"
        elseif t == "boolean" then return tostring(v)
        elseif t == "number" then return tostring(v)
        elseif t == "string" then return encode_string(v)
        elseif t == "table" then
            -- Decide array vs object: if all keys are sequential integers, array.
            local n = 0
            local is_array = true
            for k, _ in pairs(v) do
                n = n + 1
                if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                    is_array = false
                end
            end
            local parts = {}
            if is_array and n > 0 then
                for i = 1, n do
                    parts[#parts + 1] = encode_value(v[i], indent .. "  ")
                end
                return "[" .. table.concat(parts, ",") .. "]"
            else
                local keys = {}
                for k, _ in pairs(v) do keys[#keys + 1] = k end
                -- Sort keys for deterministic output. Numeric keys come
                -- first and sort by value; string keys sort
                -- lexicographically. Without this, the keys {1, 2, 10}
                -- would serialize as "1", "10", "2" because tostring()
                -- coerces all of them to strings.
                table.sort(keys, function(a, b)
                    local ta, tb = type(a), type(b)
                    if ta == "number" and tb == "number" then
                        return a < b
                    elseif ta == "number" then
                        return true
                    elseif tb == "number" then
                        return false
                    else
                        return tostring(a) < tostring(b)
                    end
                end)
                for _, k in ipairs(keys) do
                    local key_str
                    if type(k) == "number" then
                        key_str = tostring(k)
                    else
                        key_str = encode_string(tostring(k))
                    end
                    parts[#parts + 1] = key_str .. ":" .. encode_value(v[k], indent .. "  ")
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        else
            return encode_string(tostring(v))
        end
    end

    return encode_value(value, "")
end

-- Expose the encoder for tests + future callers. Read-only public alias.
wingman_state.json_encode = json_encode

local function json_decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    if json and json.decode and type(json.decode) == "function" then
        local ok, result = pcall(json.decode, s)
        if ok then return result end
    end
    -- No safe Lua JSON decoder in fallback path. Returning nil is honest;
    -- the caller must treat that as "fall back to defaults".
    warn("json_decode: no JSON implementation available; returning nil")
    return nil
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local function clamp_number(value, min, max, fallback)
    local n = tonumber(value)
    if n == nil then return fallback end
    if n < min then n = min end
    if n > max then n = max end
    return n
end

local function coerce_bool(value, fallback)
    if value == nil then return fallback end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then
        local s = value:lower()
        if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
        if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    end
    return fallback
end

local function validate_csv_keys(value)
    -- Returns (cleaned_csv_or_nil, list_of_warnings). Never throws.
    if value == nil then return "", {} end
    if type(value) ~= "string" then return "", { "non-string CSV ignored" } end

    local seen = {}
    local parts = {}
    local warnings = {}
    for raw in tostring(value):gmatch("[^,]+") do
        local key = raw:match("^%s*(.-)%s*$") -- trim
        if key and key ~= "" then
            key = key:lower()
            if not key:match("^[a-z0-9_]+$") then
                warnings[#warnings + 1] = "dropped non-conformant key: '" .. key .. "'"
            elseif not seen[key] then
                seen[key] = true
                parts[#parts + 1] = key
            end
        end
    end
    return table.concat(parts, ","), warnings
end

local function validate_settings(input)
    -- Returns a fresh, validated table merged over DEFAULTS.
    -- Drops unknown keys silently; logs warnings for malformed CSV.
    input = input or {}
    local out_settings = {}
    for k, v in pairs(DEFAULTS) do out_settings[k] = v end

    for k, v in pairs(input) do
        if DEFAULTS[k] == nil then
            debug("ignoring unknown setting: " .. tostring(k))
        else
            out_settings[k] = v
        end
    end

    -- Booleans
    for _, key in ipairs({
        "wingman_enabled",
        "wingman_debug_logging",
        "wingman_campaign_handover_enabled",
        "wingman_break_on_diplomacy_panel",
        "wingman_break_on_war_declaration",
        "wingman_break_on_pending_battle",
        "wingman_battle_handover_enabled",
        "wingman_auto_dismiss_battle_results",
        "wingman_turn_cap_enabled",
        "wingman_custom_win_enabled",
        "wingman_faction_restrictions_enabled",
        "wingman_ai_enabled",
        "wingman_ai_attack_adjacent",
        "wingman_ai_diplomacy_enabled",
        "wingman_ai_research_enabled",
        "wingman_ai_rituals_enabled",
    }) do
        out_settings[key] = coerce_bool(out_settings[key], DEFAULTS[key])
    end

    -- Sliders / numbers
    out_settings.wingman_auto_end_turn_delay_seconds =
        clamp_number(out_settings.wingman_auto_end_turn_delay_seconds,
            BOUNDS.wingman_auto_end_turn_delay_seconds.min,
            BOUNDS.wingman_auto_end_turn_delay_seconds.max,
            DEFAULTS.wingman_auto_end_turn_delay_seconds)
    out_settings.wingman_periodic_break_interval =
        clamp_number(out_settings.wingman_periodic_break_interval,
            BOUNDS.wingman_periodic_break_interval.min,
            BOUNDS.wingman_periodic_break_interval.max,
            DEFAULTS.wingman_periodic_break_interval)
    out_settings.wingman_autoresolve_threshold =
        clamp_number(out_settings.wingman_autoresolve_threshold,
            BOUNDS.wingman_autoresolve_threshold.min,
            BOUNDS.wingman_autoresolve_threshold.max,
            DEFAULTS.wingman_autoresolve_threshold)
    out_settings.wingman_turn_cap_value =
        clamp_number(out_settings.wingman_turn_cap_value,
            BOUNDS.wingman_turn_cap_value.min,
            BOUNDS.wingman_turn_cap_value.max,
            DEFAULTS.wingman_turn_cap_value)
    out_settings.wingman_ai_orders_per_turn =
        clamp_number(out_settings.wingman_ai_orders_per_turn,
            BOUNDS.wingman_ai_orders_per_turn.min,
            BOUNDS.wingman_ai_orders_per_turn.max,
            DEFAULTS.wingman_ai_orders_per_turn)
    out_settings.wingman_ai_diplomacy_per_turn =
        clamp_number(out_settings.wingman_ai_diplomacy_per_turn,
            BOUNDS.wingman_ai_diplomacy_per_turn.min,
            BOUNDS.wingman_ai_diplomacy_per_turn.max,
            DEFAULTS.wingman_ai_diplomacy_per_turn)

    -- Enums
    for k, allowed in pairs(ALLOWED_ENUMS) do
        local v = out_settings[k]
        if type(v) ~= "string" or not allowed[v] then
            warn("enum " .. tostring(k) .. " has invalid value '" .. tostring(v) .. "', using default")
            out_settings[k] = DEFAULTS[k]
        end
    end

    -- W7 string-allowlist. wingman_ai_mode is an enum-like setting that is
    -- not in ALLOWED_ENUMS because it is only valid after the W7 code is
    -- loaded; older save files may have nil here. Force-validate it.
    do
        local v = out_settings.wingman_ai_mode
        if type(v) ~= "string" or not (v == "off" or v == "advisory" or v == "autopilot") then
            out_settings.wingman_ai_mode = DEFAULTS.wingman_ai_mode
        end
    end

    -- W7 string keys (personality / hotkey / dilemma_key) — accept any
    -- non-empty string of reasonable length; revert to default otherwise.
    for _, key in ipairs({
        "wingman_ai_autopilot_personality",
        "wingman_ai_takeback_hotkey",
        "wingman_ai_advisory_dilemma_key",
    }) do
        local v = out_settings[key]
        if type(v) ~= "string" or v == "" or #v > 256 then
            out_settings[key] = DEFAULTS[key]
        end
    end

    -- W8 bool keys. Force-validate to true/false.
    for _, key in ipairs({
        "wingman_ai_build_enabled",
        "wingman_ai_heal_enabled",
        "wingman_ai_post_battle_enabled",
        "wingman_ai_reactive_diplo_enabled",
    }) do
        local v = out_settings[key]
        if v ~= true and v ~= false then
            out_settings[key] = DEFAULTS[key]
        end
    end

    -- W8: wingman_ai_periodic_pause_turns is a non-negative integer
    -- clamped to [0, 1000]. 0 = disabled.
    do
        local v = out_settings.wingman_ai_periodic_pause_turns
        local n = tonumber(v)
        if not n or n < 0 then n = 0 end
        if n > 1000 then n = 1000 end
        out_settings.wingman_ai_periodic_pause_turns = math.floor(n)
    end

    -- CSV keys
    do
        local cleaned, warnings = validate_csv_keys(out_settings.wingman_required_settlements_csv)
        out_settings.wingman_required_settlements_csv = cleaned
        for _, w in ipairs(warnings) do warn("settlements csv: " .. w) end
    end
    do
        local cleaned, warnings = validate_csv_keys(out_settings.wingman_required_defeated_factions_csv)
        out_settings.wingman_required_defeated_factions_csv = cleaned
        for _, w in ipairs(warnings) do warn("defeated factions csv: " .. w) end
    end

    return out_settings
end

-- ---------------------------------------------------------------------------
-- Defaults / settings population (no MCT direct dependency; bridge is wired
-- in T7). If MCT is unavailable we use DEFAULTS verbatim.
-- ---------------------------------------------------------------------------

local function read_settings_from_mct()
    -- T2 owns wingman_mct. Avoid a hard require so this module is loadable
    -- before T2 ships; rely on the global being present only if available.
    if type(_G.wingman_mct) == "table" and type(_G.wingman_mct.read_settings) == "function" then
        local ok, result = pcall(_G.wingman_mct.read_settings)
        if ok and type(result) == "table" then return result end
        warn("wingman_mct.read_settings failed: " .. tostring(result))
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Schema migrations
--
-- Add a new entry when SCHEMA_VERSION bumps. Each migration takes the
-- settings table from the previous version and returns the (possibly
-- reshaped) settings table for the new version. Migrations are applied
-- in order from saved_version+1 → current_version, so each function
-- only has to know about the immediately preceding version.
--
-- Example for a future v2 that renames a key:
--   wingman_state.MIGRATIONS[2] = function(s)
--       if s.wingman_ai_orders_per_turn ~= nil then
--           s.wingman_ai_max_orders_per_turn = s.wingman_ai_orders_per_turn
--           s.wingman_ai_orders_per_turn = nil
--       end
--       return s
--   end
--
-- v1 is the current schema; no migration needed yet. The empty table
-- entry makes the loop a no-op.
-- ---------------------------------------------------------------------------

wingman_state.MIGRATIONS = {
    -- [2] = function(s) ... end,  -- future v2 migration
}

local function apply_migrations(settings, from_version, to_version)
    if type(settings) ~= "table" then return settings end
    if from_version == to_version then return settings end
    for v = from_version + 1, to_version do
        local migrate = wingman_state.MIGRATIONS[v]
        if type(migrate) == "function" then
            local ok, result = pcall(migrate, settings)
            if ok and type(result) == "table" then
                settings = result
            else
                warn(string.format("migration v%d -> v%d failed: %s; keeping pre-migration settings",
                    v - 1, v, tostring(result)))
            end
        else
            -- No migration registered for this version bump. Add one to
            -- wingman_state.MIGRATIONS[N] before bumping SCHEMA_VERSION.
            warn(string.format("no migration registered for v%d -> v%d; keeping pre-migration settings",
                v - 1, v))
        end
    end
    return settings
end

--- Public: run the migration chain on a settings table.
-- Useful for tests and for one-off migration runs during campaign load.
function wingman_state.migrate_settings(settings, from_version, to_version)
    from_version = tonumber(from_version) or 1
    to_version = tonumber(to_version) or wingman_state.SCHEMA_VERSION
    return apply_migrations(settings, from_version, to_version)
end

local function load_global_settings()
    local persisted_raw = safe_load_registry(KEY_GLOBAL_SETTINGS)
    local persisted = json_decode(persisted_raw)

    -- Build from defaults, then layer persisted overrides, then layer MCT if present.
    local merged = {}
    for k, v in pairs(DEFAULTS) do merged[k] = v end

    if type(persisted) == "table" then
        -- Apply schema migrations before layering. The global settings
        -- schema is the same as the in-save schema — a single bump
        -- applies to both blobs. (If we ever need to bump them
        -- independently, switch to per-blob schema keys.)
        local saved_schema = tonumber(safe_load_named(KEY_SCHEMA_VERSION)) or 1
        if saved_schema < wingman_state.SCHEMA_VERSION then
            persisted = apply_migrations(persisted, saved_schema, wingman_state.SCHEMA_VERSION)
        end
        for k, v in pairs(persisted) do merged[k] = v end
    end

    local mct_settings = read_settings_from_mct()
    if type(mct_settings) == "table" then
        for k, v in pairs(mct_settings) do merged[k] = v end
    end

    return validate_settings(merged)
end

-- ---------------------------------------------------------------------------
-- Mode machine
-- ---------------------------------------------------------------------------

local function is_valid_mode(mode)
    return mode == wingman_state.MODE_DISABLED
        or mode == wingman_state.MODE_CAMPAIGN
        or mode == wingman_state.MODE_BREAKPOINT
        or mode == wingman_state.MODE_ERROR_SAFE
end

local function determine_initial_mode(settings, saved_mode)
    -- Saved mode wins if present and valid; otherwise derive from settings.
    if is_valid_mode(saved_mode) then
        return saved_mode
    end
    if settings and settings.wingman_enabled then
        return wingman_state.MODE_CAMPAIGN
    end
    return wingman_state.MODE_DISABLED
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialize state from defaults + persisted + MCT.
-- Safe to call once after the campaign world exists (first-tick callback).
function wingman_state.init()
    if state.initialized then
        debug("wingman_state.init called twice; ignoring")
        return true
    end

    state.settings = load_global_settings()

    local saved_mode = safe_load_named(KEY_MODE)
    state.mode = determine_initial_mode(state.settings, saved_mode)

    local saved_schema = safe_load_named(KEY_SCHEMA_VERSION)
    if saved_schema ~= nil and tonumber(saved_schema) ~= wingman_state.SCHEMA_VERSION then
        warn("schema mismatch: saved=" .. tostring(saved_schema)
            .. " current=" .. tostring(wingman_state.SCHEMA_VERSION)
            .. "; resetting transient in-save state")
        -- Reset transient in-save keys; keep settings and mode.
        -- (Per-version migrations for the settings blob itself run
        -- inside load_global_settings() via the MIGRATIONS table.)
        safe_save_named(KEY_LAST_TURN, 0)
        safe_save_named(KEY_BREAK_REASON, "")
        safe_save_named(KEY_RULE_PROGRESS, "")
        safe_save_named(KEY_PENDING_BATTLE, "")
        safe_save_named(KEY_MISSION_KEYS, "")
    end

    -- Hydrate transient in-save fields.
    local last_turn = tonumber(safe_load_named(KEY_LAST_TURN)) or 0
    state.last_processed_turn = last_turn

    local break_reason = safe_load_named(KEY_BREAK_REASON)
    if type(break_reason) == "string" and break_reason ~= "" then
        state.break_reason = break_reason
    end

    local pending_raw = safe_load_named(KEY_PENDING_BATTLE)
    if pending_raw and pending_raw ~= "" then
        local decoded = json_decode(pending_raw)
        if type(decoded) == "table" then state.pending_battle = decoded end
    end

    local mission_keys_raw = safe_load_named(KEY_MISSION_KEYS)
    if mission_keys_raw and mission_keys_raw ~= "" then
        local decoded = json_decode(mission_keys_raw)
        if type(decoded) == "table" then state.mission_keys = decoded end
    end

    local rule_progress_raw = safe_load_named(KEY_RULE_PROGRESS)
    if rule_progress_raw and rule_progress_raw ~= "" then
        local decoded = json_decode(rule_progress_raw)
        if type(decoded) == "table" then state.rule_progress = decoded end
    end

    local last_err_raw = safe_load_registry(KEY_LAST_ERROR)
    if type(last_err_raw) == "string" and last_err_raw ~= "" then
        state.last_error = last_err_raw
    end

    -- Persist schema version so we can detect on future loads.
    safe_save_named(KEY_SCHEMA_VERSION, wingman_state.SCHEMA_VERSION)

    state.initialized = true
    log(string.format("init ok. v%s mode=%s schema=%d",
        wingman_state.VERSION_STRING,
        tostring(state.mode),
        wingman_state.SCHEMA_VERSION))

    return true
end

--- Re-load in-save state. Used on campaign load before init() on a fresh
-- campaign; safe to call repeatedly.
function wingman_state.load()
    if not state.initialized then
        warn("wingman_state.load before init; auto-initializing")
        wingman_state.init()
        if not state.initialized then return wingman_state.MODE_DISABLED end
    end

    -- Validate schema and reset transient state if stale.
    local saved_schema = safe_load_named(KEY_SCHEMA_VERSION)
    if saved_schema ~= nil and tonumber(saved_schema) ~= wingman_state.SCHEMA_VERSION then
        warn("load: schema mismatch — resetting transient keys")
        safe_save_named(KEY_LAST_TURN, 0)
        safe_save_named(KEY_BREAK_REASON, "")
        safe_save_named(KEY_PENDING_BATTLE, "")
        safe_save_named(KEY_MISSION_KEYS, "")
        safe_save_named(KEY_RULE_PROGRESS, "")
        state.break_reason = nil
        state.last_processed_turn = 0
        state.pending_battle = nil
        state.mission_keys = nil
        state.rule_progress = nil
    end

    state.mode = determine_initial_mode(state.settings, safe_load_named(KEY_MODE))
    return state.mode
end

--- Persist current state.mode and key transient fields.
function wingman_state.save()
    if not state.initialized then
        warn("wingman_state.save before init")
        return false
    end

    safe_save_named(KEY_MODE, state.mode)
    safe_save_named(KEY_CAMPAIGN_ENABLED, state.settings and state.settings.wingman_campaign_handover_enabled)
    safe_save_named(KEY_BATTLE_ENABLED, state.settings and state.settings.wingman_battle_handover_enabled)
    safe_save_named(KEY_LAST_TURN, state.last_processed_turn)
    safe_save_named(KEY_BREAK_REASON, state.break_reason or "")

    if state.pending_battle then
        safe_save_named(KEY_PENDING_BATTLE, json_encode(state.pending_battle))
    else
        safe_save_named(KEY_PENDING_BATTLE, "")
    end

    if state.mission_keys then
        safe_save_named(KEY_MISSION_KEYS, json_encode(state.mission_keys))
    else
        safe_save_named(KEY_MISSION_KEYS, "")
    end

    if state.rule_progress then
        safe_save_named(KEY_RULE_PROGRESS, json_encode(state.rule_progress))
    else
        safe_save_named(KEY_RULE_PROGRESS, "")
    end

    if state.settings then
        safe_save_registry(KEY_GLOBAL_SETTINGS, json_encode(state.settings))
    end

    if state.last_error then
        safe_save_registry(KEY_LAST_ERROR, state.last_error)
    end

    return true
end

--- Return the current mode string.
function wingman_state.get_mode()
    if not state.initialized then return wingman_state.MODE_DISABLED end
    return state.mode
end

--- Transition to a new mode with an optional reason; persists immediately.
function wingman_state.set_mode(mode, reason)
    if not state.initialized then
        warn("wingman_state.set_mode before init")
        return false
    end
    if not is_valid_mode(mode) then
        warn("wingman_state.set_mode: invalid mode '" .. tostring(mode) .. "'")
        return false
    end
    if state.mode == mode then return true end

    local prev = state.mode
    state.mode = mode
    log(string.format("mode change: %s -> %s (%s)",
        tostring(prev), tostring(mode), tostring(reason or "n/a")))
    wingman_state.save()
    return true
end

--- Set the current mode to BREAKPOINT and record a reason.
function wingman_state.set_breakpoint(reason, data)
    if not state.initialized then
        warn("wingman_state.set_breakpoint before init")
        return false
    end
    state.break_reason = reason or "unspecified"
    state.break_data = data
    log(string.format("breakpoint: %s", tostring(state.break_reason)))
    return wingman_state.set_mode(wingman_state.MODE_BREAKPOINT, reason)
end

--- Convenience alias used by the campaign driver to hand control back.
function wingman_state.release_to_player(reason)
    return wingman_state.set_breakpoint(reason or "released_to_player")
end

--- Read-only view of the in-memory validated settings table.
function wingman_state.get_settings()
    if not state.initialized then
        -- Return a copy of defaults so callers never see nil.
        local copy = {}
        for k, v in pairs(DEFAULTS) do copy[k] = v end
        return copy
    end
    -- Return a shallow copy so callers can't mutate internal state.
    local copy = {}
    for k, v in pairs(state.settings) do copy[k] = v end
    return copy
end

--- Validate and replace in-memory settings, then persist globally.
function wingman_state.update_settings(new_settings)
    state.settings = validate_settings(new_settings or {})
    if state.initialized then
        safe_save_registry(KEY_GLOBAL_SETTINGS, json_encode(state.settings))
    end
    return state.settings
end

--- Record that a turn has been processed by automation; prevents re-runs.
function wingman_state.mark_turn_processed(turn_number)
    if not state.initialized then
        warn("wingman_state.mark_turn_processed before init")
        return false
    end
    local n = tonumber(turn_number)
    if n == nil then
        warn("mark_turn_processed: invalid turn number " .. tostring(turn_number))
        return false
    end
    if n < state.last_processed_turn then
        -- Ignore regressions; keep highest seen.
        return false
    end
    state.last_processed_turn = n
    wingman_state.save()
    return true
end

--- Has the given turn already been processed in this campaign?
function wingman_state.is_turn_already_processed(turn_number)
    if not state.initialized then return false end
    local n = tonumber(turn_number)
    if n == nil then return false end
    return n <= state.last_processed_turn
end

--- Switch to ERROR_SAFE and persist the last error.
function wingman_state.enter_error_safe_mode(reason)
    state.last_error = tostring(reason or "unspecified error")
    log(string.format("ERROR_SAFE: %s", state.last_error))
    safe_save_registry(KEY_LAST_ERROR, state.last_error)
    if not state.initialized then
        -- Even before init, record the error so a later init can pick it up.
        return false
    end
    return wingman_state.set_mode(wingman_state.MODE_ERROR_SAFE, "error_safe")
end

--- Read the last error message (string) or nil.
function wingman_state.get_error_message()
    if not state.initialized then return state.last_error end
    return state.last_error
end

--- Clear the last error and persist the cleared value.
function wingman_state.clear_error()
    state.last_error = nil
    safe_save_registry(KEY_LAST_ERROR, "")
end

--- Stash a payload describing the current pending battle (campaign-side).
function wingman_state.set_pending_battle(payload)
    if not state.initialized then return false end
    state.pending_battle = payload
    safe_save_named(KEY_PENDING_BATTLE, payload and json_encode(payload) or "")
    return true
end

--- Read the pending battle payload (or nil).
function wingman_state.get_pending_battle()
    if not state.initialized then return nil end
    return state.pending_battle
end

--- Stash rule-progress snapshot (used by wingman_rules).
function wingman_state.set_rule_progress(payload)
    if not state.initialized then return false end
    state.rule_progress = payload
    safe_save_named(KEY_RULE_PROGRESS, payload and json_encode(payload) or "")
    return true
end

function wingman_state.get_rule_progress()
    if not state.initialized then return nil end
    return state.rule_progress
end

--- Stash mission keys (used by wingman_missions).
function wingman_state.set_mission_keys(payload)
    if not state.initialized then return false end
    state.mission_keys = payload
    safe_save_named(KEY_MISSION_KEYS, payload and json_encode(payload) or "")
    return true
end

function wingman_state.get_mission_keys()
    if not state.initialized then return nil end
    return state.mission_keys
end

--- Track most recent turn when the player's faction joined a war.
function wingman_state.mark_war_event(turn_number)
    if not state.initialized then return false end
    local n = tonumber(turn_number) or 0
    state.last_war_event_turn = n
    return true
end

function wingman_state.get_last_war_event_turn()
    if not state.initialized then return 0 end
    return state.last_war_event_turn
end

-- ---------------------------------------------------------------------------
-- One-shot registry markers (W6) — track single-shot AI actions across save/load
-- so e.g. "research all techs" runs at most once per campaign, even after reload.
-- ---------------------------------------------------------------------------

local KEY_TECH_RESEARCH_DONE   = "wingman.v1.tech_research_done"
local KEY_RITUALS_DONE         = "wingman.v1.rituals_done"

function wingman_state.mark_tech_research_done(value)
    -- value defaults to true. No-op if state isn't initialized.
    if not state.initialized then return false end
    return safe_save_registry(KEY_TECH_RESEARCH_DONE, value ~= false and "1" or "0")
end

function wingman_state.was_tech_research_done()
    if not state.initialized then return false end
    local raw = safe_load_registry(KEY_TECH_RESEARCH_DONE)
    return raw == "1"
end

function wingman_state.mark_ritual_done(ritual_key)
    if not state.initialized or type(ritual_key) ~= "string" or ritual_key == "" then
        return false
    end
    -- Track via a JSON-encoded map of ritual_key -> "turn_window:turn".
    -- Keep at most 8 most-recent entries to bound storage.
    local existing_raw = safe_load_registry(KEY_RITUALS_DONE)
    local existing = json_decode(existing_raw)
    if type(existing) ~= "table" then existing = {} end
    local turn = 0
    if cm and type(cm.turn_number) == "function" then
        local ok, t = pcall(cm.turn_number, cm)
        if ok then turn = tonumber(t) or 0 end
    end
    existing[ritual_key] = tostring(turn)
    -- Bound: keep only keys whose turn is within last 30 turns of current.
    local cutoff = turn - 30
    for k, v in pairs(existing) do
        local n = tonumber(v) or 0
        if n < cutoff then existing[k] = nil end
    end
    safe_save_registry(KEY_RITUALS_DONE, json_encode(existing))
    return true
end

function wingman_state.was_ritual_done_recently(ritual_key, within_turns)
    if not state.initialized then return false end
    local existing_raw = safe_load_registry(KEY_RITUALS_DONE)
    local existing = json_decode(existing_raw)
    if type(existing) ~= "table" or type(existing[ritual_key]) ~= "string" then
        return false
    end
    local last_turn = tonumber(existing[ritual_key]) or 0
    local current_turn = 0
    if cm and type(cm.turn_number) == "function" then
        local ok, t = pcall(cm.turn_number, cm)
        if ok then current_turn = tonumber(t) or 0 end
    end
    return (current_turn - last_turn) <= (within_turns or 5)
end

-- Read-only snapshot for diagnostics. Not part of the public contract.
function wingman_state._snapshot()
    return {
        initialized         = state.initialized,
        mode                = state.mode,
        last_processed_turn = state.last_processed_turn,
        break_reason        = state.break_reason,
        last_error          = state.last_error,
    }
end

-- Expose DEFAULTS for tests + external consumers. Read-only alias.
wingman_state.DEFAULTS = DEFAULTS

