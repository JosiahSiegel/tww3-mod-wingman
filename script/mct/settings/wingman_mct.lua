-- =====================================================================
-- Wingman -- MCT Settings
-- =====================================================================
out("[Wingman DEBUG] wingman_mct.lua file loading") -- D0: file body starts
-- Registers all Wingman mod configuration options with the
-- Mod Configuration Tool (MCT, Workshop ID 2927955021). Provides a
-- public API (`wingman_mct.*`) for the rest of the mod to read
-- settings at runtime.
--
-- Loaded by MCT automatically from
--   script/mct/settings/wingman_mct.lua
--
-- Safe when MCT is missing -- logs a hard-dependency warning and
-- exports a defaults-only API so downstream code can still boot.
--
-- API surface (consumed by wingman_state, wingman_campaign,
-- wingman_rules, wingman_ai):
--   is_available()              -> bool
--   get_default_settings()      -> flat table copy
--   read_settings()             -> flat table (defaults + MCT overrides)
--   validate_settings(t)        -> t, with sliders clamped, dropdowns
--                                  normalized, CSVs parsed
--   rebuild_ban_list()          -> bool, count  (compat shim: rebuilds
--                                  parsed banned list from the CSV
--                                  text_input; no longer dynamic)
--   get_banned_factions()       -> array of faction_key strings
--   get_all_options()           -> array of {key, value, type}
-- =====================================================================

---------------------------------------------------------------------
-- 0. Hard dependency check
---------------------------------------------------------------------
-- Bail if MCT isn't loaded; downstream code reads defaults via
-- wingman_mct.get_default_settings()
out("[Wingman DEBUG] D1: about to call get_mct()") -- D1
local mct = get_mct and get_mct() or nil
out("[Wingman DEBUG] D2: get_mct() returned: " .. tostring(mct)) -- D2
if not mct then
    out("[Wingman] WARNING: MCT (Mod Configuration Tool) is not loaded. Wingman requires MCT. Subscribe to Workshop item 2927955021.")
    -- Still expose a wingman_mct table so other modules can safely
    -- call is_available() / get_default_settings() without crashing.
    wingman_mct = {
        is_available         = function() return false end,
        get_default_settings = function() return wingman_state_DEFAULTS() end,
        read_settings        = function() return wingman_state_DEFAULTS() end,
        validate_settings    = function(s) return s end,
        rebuild_ban_list     = function() return false end,
        get_banned_factions  = function() return {} end,
        get_all_options      = function() return {} end,
    }
    _G.wingman_mct = wingman_mct
    return
end


---------------------------------------------------------------------
-- 1. Defaults & validation helpers
---------------------------------------------------------------------

--- Schema-level defaults. The single source of truth for fallbacks
--- when MCT isn't loaded or a key has never been set.
local DEFAULT_SETTINGS = {
    -- General
    wingman_enabled                     = false,
    wingman_debug_logging               = false,
    wingman_safety_level                = "conservative",
    -- Campaign Handover
    wingman_campaign_handover_enabled   = false,
    wingman_auto_end_turn_delay_seconds = 2,
    wingman_periodic_break_interval     = 10,
    wingman_break_on_diplomacy_panel    = true,
    wingman_break_on_war_declaration    = true,
    wingman_break_on_pending_battle     = true,
    -- Battle Handover
    wingman_battle_handover_enabled     = false,
    wingman_battle_control_mode         = "scripted_ai",
    wingman_battle_plan_bias            = "auto",
    wingman_autoresolve_threshold       = 60,
    wingman_auto_dismiss_battle_results = true,
    -- Rules & Limits
    wingman_turn_cap_enabled            = false,
    wingman_turn_cap_value              = 50,
    wingman_turn_cap_outcome            = "breakpoint",
    wingman_custom_win_enabled          = false,
    wingman_required_settlements_csv    = "",
    wingman_required_defeated_factions_csv = "",
    wingman_faction_restrictions_enabled = false,
    wingman_restriction_violation_action = "warn_pause",
    -- AI Controller (W5)
    wingman_ai_enabled                  = true,
    wingman_ai_aggression               = "aggressive",
    wingman_ai_orders_per_turn          = 12,
    -- AI Controller (W6)
    wingman_ai_attack_adjacent          = true,
    wingman_ai_diplomacy_enabled        = false,
    wingman_ai_diplomacy_per_turn       = 2,
    wingman_ai_research_enabled         = true,
    wingman_ai_rituals_enabled          = true,
    -- Faction ban list (CSV of faction keys; replaces the dynamic
    -- ControlGroup.Array which does not exist on TWW3 MCT v0.9)
    wingman_banned_factions_csv         = "",
}

--- Defaults accessor; usable before DEFAULT_SETTINGS is finalized.
function wingman_state_DEFAULTS() return DEFAULT_SETTINGS end

-- Slider (min, max, step, default) -- must match DEFAULT_SETTINGS
local SLIDER_RANGES = {
    wingman_auto_end_turn_delay_seconds = {min = 0,  max = 10,   step = 1, default = 2},
    wingman_periodic_break_interval     = {min = 0,  max = 100,  step = 1, default = 10},
    wingman_autoresolve_threshold       = {min = 0,  max = 100,  step = 1, default = 60},
    wingman_turn_cap_value              = {min = 1,  max = 500,  step = 1, default = 50},
    wingman_ai_orders_per_turn          = {min = 1,  max = 50,   step = 1, default = 12},
    wingman_ai_diplomacy_per_turn       = {min = 0,  max = 10,   step = 1, default = 2},
}

-- Dropdown option tables -- keys are short, display is co-pilot-friendly
local DROPDOWN_OPTIONS = {
    wingman_safety_level = {
        {key = "conservative", text = "Conservative -- pause often"},
        {key = "balanced",     text = "Balanced -- middle ground"},
        {key = "permissive",   text = "Permissive -- act aggressively"},
    },
    wingman_battle_control_mode = {
        {key = "scripted_ai",             text = "Scripted AI -- I fight for you"},
        {key = "autoresolve_if_favorable",text = "Autoresolve if favorable -- odds check"},
        {key = "pause_to_choose",         text = "Pause and choose -- always ask"},
        {key = "manual_observe",          text = "Manual observe -- I just watch"},
    },
    wingman_battle_plan_bias = {
        {key = "auto",   text = "Auto -- let the AI decide"},
        {key = "attack", text = "Attack -- aggressive"},
        {key = "defend", text = "Defend -- hold and counter"},
    },
    wingman_turn_cap_outcome = {
        {key = "breakpoint", text = "Breakpoint -- stop and return control"},
        {key = "victory",    text = "Victory -- end campaign with official victory"},
    },
    wingman_restriction_violation_action = {
        {key = "warn_pause",   text = "Warn + pause -- alert and stop"},
        {key = "pause_disable",text = "Pause + disable -- turn Wingman off"},
    },
    wingman_ai_aggression = {
        {key = "defensive",  text = "Defensive -- guard and consolidate"},
        {key = "balanced",   text = "Balanced -- react to threats"},
        {key = "aggressive", text = "Aggressive -- attack everything (default)"},
    },
}

-- Valid dropdown keys for each enum option; used by validate_settings
local DROPDOWN_KEY_SETS = {}
for k, opts in pairs(DROPDOWN_OPTIONS) do
    local set = {}
    for _, o in ipairs(opts) do set[o.key] = true end
    DROPDOWN_KEY_SETS[k] = set
end

--- Clamp a slider value to its [min, max] range; return default if not a number.
local function clamp_slider(key, value)
    local range = SLIDER_RANGES[key]
    if not range then return value end
    if type(value) ~= "number" then return range.default end
    if value < range.min then return range.min end
    if value > range.max then return range.max end
    return math.floor(value + 0.5)
end

--- Strip whitespace, lowercase, drop anything outside [a-z0-9_].
--- Returns the cleaned key, or nil if input was empty / unusable.
local function sanitize_key(raw)
    if type(raw) ~= "string" then return nil end
    local cleaned = raw:match("^%s*([%w_]+)%s*$")
    if not cleaned then return nil end
    cleaned = cleaned:lower()
    if not cleaned:match("^[a-z0-9_]+$") then return nil end
    return cleaned
end

--- Parse a comma-separated list of keys, logging warnings for skipped entries.
local function parse_key_csv(value)
    local result = {}
    if type(value) ~= "string" or value == "" then return result end
    for raw in (value .. ","):gmatch("([^,]*),") do
        local k = sanitize_key(raw)
        if k and k ~= "" then
            result[#result + 1] = k
        elseif raw:match("%S") then
            -- TWW3 exposes `out` as a global callable for the
            -- log file. The local was named 'out' in earlier code
            -- and shadowed the global, causing "attempt to call
            -- a table value" -- fixed by renaming the local to
            -- 'result'.
            out("[Wingman] WARNING: CSV key '" .. raw .. "' ignored -- only [a-z0-9_] allowed.")
        end
    end
    return result
end


---------------------------------------------------------------------
-- 2. Module registration with MCT
---------------------------------------------------------------------
-- Canonical TWW3 MCT v0.9 API (verified against chadvandy/mct_wh3
-- source on GitHub + Lewdhammer Progression Framework reference).
-- Do NOT use the 3K legacy API (mct:get_object_type, array_class,
-- set_assigned_section, get_option_by_key, get_finalized_setting)
-- -- those methods do not exist on TWW3 MCT and will throw silently
-- at registration time, hiding all options from the panel.

local wingman_mod = mct:register_mod("wingman")
out("[Wingman DEBUG] D3: mct:register_mod returned: " .. tostring(wingman_mod)) -- D3
wingman_mod:set_workshop_id("wingman_local_id")
out("[Wingman DEBUG] D4: set_workshop_id OK") -- D4
wingman_mod:set_version(mct:get_version_number(), mct:get_version())
wingman_mod:set_main_image("ui/mct/van_mct.png", 300, 300)
out("[Wingman DEBUG] D5: set_main_image OK") -- D5
wingman_mod:set_description("Wingman -- Your AI Co-Pilot for TWW3")
out("[Wingman DEBUG] D6: set_description OK") -- D6
wingman_mod:set_title("Wingman -- Your AI Co-Pilot")
out("[Wingman DEBUG] D7: set_title OK") -- D7
wingman_mod:set_author("Wingman Team")
out("[Wingman DEBUG] D8: set_author OK") -- D8


---------------------------------------------------------------------
-- 3. Section organization
---------------------------------------------------------------------
-- TWW3 MCT supports a flat "settings page" per mod, with options
-- appearing in registration order. We add a section header per
-- logical group; options below the header belong to that group.
-- The section name doubles as the UI label.

local SECTION_GENERAL = "wingman_section_general"
local SECTION_CAMPAIGN = "wingman_section_campaign"
local SECTION_BATTLE  = "wingman_section_battle"
local SECTION_RULES   = "wingman_section_rules"

wingman_mod:add_new_section(SECTION_GENERAL, "General")
out("[Wingman DEBUG] D9: SECTION_GENERAL added") -- D9
wingman_mod:add_new_section(SECTION_CAMPAIGN, "Campaign Handover")
out("[Wingman DEBUG] D10: SECTION_CAMPAIGN added") -- D10
wingman_mod:add_new_section(SECTION_BATTLE,  "Battle Handover")
out("[Wingman DEBUG] D11: SECTION_BATTLE added") -- D11
wingman_mod:add_new_section(SECTION_RULES,   "Rules & Limits")
out("[Wingman DEBUG] D12: all 4 sections added") -- D12


---------------------------------------------------------------------
-- 4. Helper: register one option (type inferred from DEFAULT_SETTINGS)
---------------------------------------------------------------------
local OPTION_TYPE_BY_KEY = {}
for k, v in pairs(DEFAULT_SETTINGS) do
    local range = SLIDER_RANGES[k]
    local t = range and "slider"
            or (DROPDOWN_OPTIONS[k] and "dropdown")
            or (k:match("_csv$") and "text_input")
            or "checkbox"
    OPTION_TYPE_BY_KEY[k] = t
end

local function add_option(key)
    local otype = OPTION_TYPE_BY_KEY[key]
    local opt = wingman_mod:add_new_option(key, otype)
    return opt, otype
end

local function configure_option(opt, key)
    opt:set_default_value(DEFAULT_SETTINGS[key])
    if SLIDER_RANGES[key] then
        opt:slider_set_min_max(SLIDER_RANGES[key].min, SLIDER_RANGES[key].max)
        opt:slider_set_step_size(SLIDER_RANGES[key].step)
    end
    if DROPDOWN_OPTIONS[key] then
        opt:add_dropdown_values(DROPDOWN_OPTIONS[key])
    end
end


---------------------------------------------------------------------
-- 5. Section: General
---------------------------------------------------------------------
do
    local opt = add_option("wingman_enabled")
    out("[Wingman DEBUG] D13: first add_option returned: " .. tostring(opt)) -- D13
    configure_option(opt, "wingman_enabled")
    opt:set_text("Enable Wingman")
    opt:set_tooltip_text("Take the stick -- let me handle your turns. Master switch for all Wingman automation.")

    local opt = add_option("wingman_debug_logging")
    configure_option(opt, "wingman_debug_logging")
    opt:set_text("Verbose logging")
    opt:set_tooltip_text("Show me my work -- verbose logs for troubleshooting.")

    local opt = add_option("wingman_safety_level")
    configure_option(opt, "wingman_safety_level")
    opt:set_text("Safety level")
    opt:set_tooltip_text("How careful should I be? Conservative = pause often. Balanced = middle ground. Permissive = act aggressively.")
end


---------------------------------------------------------------------
-- 6. Section: Campaign Handover
---------------------------------------------------------------------
do
    local opt = add_option("wingman_campaign_handover_enabled")
    configure_option(opt, "wingman_campaign_handover_enabled")
    opt:set_text("Enable campaign handover")
    opt:set_tooltip_text("Play your campaign for you -- I'll auto-end your turns so AI factions take over while you watch.")

    local opt = add_option("wingman_auto_end_turn_delay_seconds")
    configure_option(opt, "wingman_auto_end_turn_delay_seconds")
    opt:set_text("End-turn delay (seconds)")
    opt:set_tooltip_text("Wait N seconds before ending your turn -- gives UI time to settle so I don't crash on popups.")

    local opt = add_option("wingman_periodic_break_interval")
    configure_option(opt, "wingman_periodic_break_interval")
    opt:set_text("Periodic breakpoint (turns)")
    opt:set_tooltip_text("Every N turns, hand back to you for a quick review. Set to 0 to never break.")

    local opt = add_option("wingman_break_on_diplomacy_panel")
    configure_option(opt, "wingman_break_on_diplomacy_panel")
    opt:set_text("Break on diplomacy panel")
    opt:set_tooltip_text("Pause when a diplomacy panel pops up -- those tend to crash if I click blindly.")

    local opt = add_option("wingman_break_on_war_declaration")
    configure_option(opt, "wingman_break_on_war_declaration")
    opt:set_text("Break on war declaration")
    opt:set_tooltip_text("Pause when war is declared on you -- let you handle the alert.")

    local opt = add_option("wingman_break_on_pending_battle")
    configure_option(opt, "wingman_break_on_pending_battle")
    opt:set_text("Break on pending battle")
    opt:set_tooltip_text("Pause when a battle needs your decision.")

    local opt = add_option("wingman_ai_enabled")
    configure_option(opt, "wingman_ai_enabled")
    opt:set_text("AI controls your faction")
    opt:set_tooltip_text("When I'm in the cockpit, I actively move your armies, queue buildings, recruit, and attack -- using scripted orders on your own faction (highest-skill-attitude by default). Disabled = I still hand the turn back, but I won't move anything for you.")

    local opt = add_option("wingman_ai_aggression")
    configure_option(opt, "wingman_ai_aggression")
    opt:set_text("AI aggression")
    opt:set_tooltip_text("How aggressive should your AI faction play? Defensive consolidates; balanced reacts; aggressive attacks every enemy it can see.")

    local opt = add_option("wingman_ai_orders_per_turn")
    configure_option(opt, "wingman_ai_orders_per_turn")
    opt:set_text("AI orders per turn (cap)")
    opt:set_tooltip_text("Maximum scripted orders I issue on your behalf each turn (moves + recruit + build). Default 12 -- lower if a specific mod interaction gets cranky, higher to let the AI run wild.")

    local opt = add_option("wingman_ai_attack_adjacent")
    configure_option(opt, "wingman_ai_attack_adjacent")
    opt:set_text("AI attacks adjacent enemies")
    opt:set_tooltip_text("When enabled, your AI driver actively attacks adjacent enemy armies and settlements (subject to the order budget). The highest-skill-level AI takes full control -- no waiting for you to click attack.")

    local opt = add_option("wingman_ai_diplomacy_enabled")
    configure_option(opt, "wingman_ai_diplomacy_enabled")
    opt:set_text("AI handles diplomacy")
    opt:set_tooltip_text("When enabled, your AI driver will declare war, make peace, sign trade agreements, NAPs, alliances, vassals, and confederations. Default OFF -- flip this on if you want full autonomy. Aggression setting controls whether the AI leans toward war or peace.")

    local opt = add_option("wingman_ai_diplomacy_per_turn")
    configure_option(opt, "wingman_ai_diplomacy_per_turn")
    opt:set_text("Diplomacy actions per turn (cap)")
    opt:set_tooltip_text("Maximum diplomatic actions the AI takes per turn. 0 = disable diplomacy regardless of the master switch. Default 2 -- enough to react, not so many it spirals.")

    local opt = add_option("wingman_ai_research_enabled")
    configure_option(opt, "wingman_ai_research_enabled")
    opt:set_text("AI researches technologies")
    opt:set_tooltip_text("When enabled, the AI will trigger bulk research once per campaign (TWW3 has no per-tech research API -- this completes the whole tree at once). Use sparingly; once-per-campaign because research is binary in TWW3 scripting.")

    local opt = add_option("wingman_ai_rituals_enabled")
    configure_option(opt, "wingman_ai_rituals_enabled")
    opt:set_text("AI performs faction rites")
    opt:set_tooltip_text("When enabled, the AI performs any available faction rites once per turn. Cannot target specific factions for rituals that require a target -- the engine picks based on availability.")
end


---------------------------------------------------------------------
-- 7. Section: Battle Handover
---------------------------------------------------------------------
do
    local opt = add_option("wingman_battle_handover_enabled")
    configure_option(opt, "wingman_battle_handover_enabled")
    opt:set_text("Enable battle handover")
    opt:set_tooltip_text("Take over your battles.")

    local opt = add_option("wingman_battle_control_mode")
    configure_option(opt, "wingman_battle_control_mode")
    opt:set_text("Battle control mode")
    opt:set_tooltip_text("How should I handle battles? scripted_ai = I fight for you. autoresolve_if_favorable = autoresolve when odds favor us. pause_to_choose = always ask. manual_observe = I just watch.")

    local opt = add_option("wingman_battle_plan_bias")
    configure_option(opt, "wingman_battle_plan_bias")
    opt:set_text("Battle plan bias")
    opt:set_tooltip_text("When I fight for you, what style? auto = let the AI decide. attack = aggressive. defend = hold and counter.")

    local opt = add_option("wingman_autoresolve_threshold")
    configure_option(opt, "wingman_autoresolve_threshold")
    opt:set_text("Autoresolve threshold (%)")
    opt:set_tooltip_text("Only autoresolve if our win chance is above this %. Below it, pause instead. Used when control mode = autoresolve_if_favorable.")

    local opt = add_option("wingman_auto_dismiss_battle_results")
    configure_option(opt, "wingman_auto_dismiss_battle_results")
    opt:set_text("Auto-dismiss battle results")
    opt:set_tooltip_text("Auto-dismiss the post-battle results screen so I can keep your campaign moving.")
end


---------------------------------------------------------------------
-- 8. Section: Rules & Limits
---------------------------------------------------------------------
do
    local opt = add_option("wingman_turn_cap_enabled")
    configure_option(opt, "wingman_turn_cap_enabled")
    opt:set_text("Enable turn cap")
    opt:set_tooltip_text("Set a hard turn limit. When reached, I hand control back (or declare victory -- see next option).")

    local opt = add_option("wingman_turn_cap_value")
    configure_option(opt, "wingman_turn_cap_value")
    opt:set_text("Turn cap value")
    opt:set_tooltip_text("The turn number to cap at.")

    local opt = add_option("wingman_turn_cap_outcome")
    configure_option(opt, "wingman_turn_cap_outcome")
    opt:set_text("Turn cap outcome")
    opt:set_tooltip_text("What happens at the turn cap. breakpoint = stop and return control. victory = end campaign with the official victory screen.")

    local opt = add_option("wingman_custom_win_enabled")
    configure_option(opt, "wingman_custom_win_enabled")
    opt:set_text("Enable custom victory")
    opt:set_tooltip_text("Enable a custom victory condition I track for you.")

    local opt = add_option("wingman_required_settlements_csv")
    configure_option(opt, "wingman_required_settlements_csv")
    opt:set_text("Required settlements (CSV)")
    opt:set_tooltip_text("Settlements/regions you must own to win. Comma-separated faction/region keys, e.g. 'wh_main_altdorf,wh_main_kislev_city'. Unknown keys log a warning and are ignored.")

    local opt = add_option("wingman_required_defeated_factions_csv")
    configure_option(opt, "wingman_required_defeated_factions_csv")
    opt:set_text("Required defeated factions (CSV)")
    opt:set_tooltip_text("Factions that must be destroyed for victory. Comma-separated keys.")

    local opt = add_option("wingman_faction_restrictions_enabled")
    configure_option(opt, "wingman_faction_restrictions_enabled")
    opt:set_text("Enable faction restrictions")
    opt:set_tooltip_text("Watch for banned factions -- if you confederate or inherit one, I'll warn you.")

    local opt = add_option("wingman_restriction_violation_action")
    configure_option(opt, "wingman_restriction_violation_action")
    opt:set_text("Violation action")
    opt:set_tooltip_text("What to do on a restriction violation. warn_pause = alert and stop. pause_disable = disable Wingman entirely.")

    local opt = add_option("wingman_banned_factions_csv")
    configure_option(opt, "wingman_banned_factions_csv")
    opt:set_text("Banned factions (CSV)")
    opt:set_tooltip_text("Faction keys that trigger a violation warning if you ever own them. Comma-separated, lowercase, e.g. 'wh_main_vampire_counts,wh2_main_skv_clan_mors'. Type 'help' to list valid faction keys is not supported -- see text/db/factions.txt or the vanilla faction_keys table for the canonical list.")
end


---------------------------------------------------------------------
-- 9. Public API
---------------------------------------------------------------------

--- Cached parsed ban list. Rebuilt by rebuild_ban_list() whenever
--- settings change; queried by get_banned_factions() from the rules
--- engine. TWW3 MCT has no dynamic option-add API, so the ban list
--- is now a CSV text_input parsed on demand.
local cached_banned_factions = {}

--- Return MCT availability.
local function is_available()
    return mct ~= nil
end

--- Return the default settings table (always available).
local function get_default_settings()
    local copy = {}
    for k, v in pairs(DEFAULT_SETTINGS) do copy[k] = v end
    return copy
end

--- Read the current finalized settings from MCT, falling back to
--- defaults for any missing key.
---
--- TWW3 MCT v0.9 does NOT expose get_option_by_key/get_finalized_setting
--- on mod handles (those are 3K legacy). Instead, finalized values are
--- published into the global CFSettings table at the end of MCT
--- finalization. For settings that haven't been finalized yet, we
--- fall back to the default.
local function read_settings()
    local out = get_default_settings()
    if CFSettings and type(CFSettings) == "table" then
        for k, _ in pairs(out) do
            if CFSettings[k] ~= nil then
                out[k] = CFSettings[k]
            end
        end
    end
    -- Always include the parsed ban list so callers can use it
    -- uniformly whether the value came from MCT or the default.
    -- Inlined parse_key_csv call (instead of forwarding to
    -- get_banned_factions) because Lua local functions are not
    -- forward-visible to other local functions defined above them.
    local ban_raw = ""
    if CFSettings and CFSettings.wingman_banned_factions_csv ~= nil then
        ban_raw = CFSettings.wingman_banned_factions_csv
    end
    out.wingman_banned_factions = parse_key_csv(ban_raw)
    return out
end

--- Clamp sliders, sanitize CSVs, normalize dropdown keys.
local function validate_settings(settings)
    if type(settings) ~= "table" then return get_default_settings() end

    for k, v in pairs(settings) do
        if SLIDER_RANGES[k] then
            settings[k] = clamp_slider(k, v)
        elseif DROPDOWN_KEY_SETS[k] then
            if type(v) ~= "string" or not DROPDOWN_KEY_SETS[k][v] then
                settings[k] = DEFAULT_SETTINGS[k]
            end
        elseif OPTION_TYPE_BY_KEY[k] == "checkbox" and type(v) ~= "boolean" then
            settings[k] = DEFAULT_SETTINGS[k]
        end
    end

    -- Fill in any missing keys from defaults
    for k, v in pairs(DEFAULT_SETTINGS) do
        if settings[k] == nil then settings[k] = v end
    end

    -- Reconstruct sanitized CSV arrays (these mirror the raw csv setting)
    settings.wingman_required_settlements       = parse_key_csv(settings.wingman_required_settlements_csv)
    settings.wingman_required_defeated_factions = parse_key_csv(settings.wingman_required_defeated_factions_csv)

    return settings
end

--- Rebuild the cached banned-factions list from the current
--- wingman_banned_factions_csv setting. Called by the rules engine
--- at the start of every check; safe to call when MCT is missing.
local function rebuild_ban_list()
    local raw = ""
    if CFSettings and CFSettings.wingman_banned_factions_csv ~= nil then
        raw = CFSettings.wingman_banned_factions_csv
    end
    cached_banned_factions = parse_key_csv(raw)
    return true, #cached_banned_factions
end

--- Return the list of banned faction keys. Always re-parses from
--- the current CFSettings so a single read reflects the latest
--- user state without needing explicit rebuild calls.
local function get_banned_factions()
    local raw = ""
    if CFSettings and CFSettings.wingman_banned_factions_csv ~= nil then
        raw = CFSettings.wingman_banned_factions_csv
    end
    return parse_key_csv(raw)
end

--- Return a flat list of (key, value, type) for the rules engine.
local function get_all_options()
    local out = {}
    for k, def in pairs(DEFAULT_SETTINGS) do
        local val = def
        if CFSettings and CFSettings[k] ~= nil then
            val = CFSettings[k]
        end
        out[#out + 1] = {key = k, value = val, type = OPTION_TYPE_BY_KEY[k]}
    end
    return out
end


---------------------------------------------------------------------
-- 10. Module export
---------------------------------------------------------------------
wingman_mct = {
    is_available           = is_available,
    get_default_settings   = get_default_settings,
    read_settings          = read_settings,
    validate_settings      = validate_settings,
    rebuild_ban_list       = rebuild_ban_list,
    get_banned_factions    = get_banned_factions,
    get_all_options        = get_all_options,
}

-- Also expose globally so other Lua modules can reach it without
-- requiring this file (TWW3 mod scripts share globals).
_G.wingman_mct = wingman_mct

-- Log successful registration so users can verify the integration
-- loaded in their lua_mod_log.txt / script_log_*.txt.
out("[Wingman] MCT registration complete. 30 settings, 6 sliders, 6 dropdowns, 3 text inputs, 15 checkboxes.")
