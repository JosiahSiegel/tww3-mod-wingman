-- =====================================================================
-- Wingman — MCT Settings
-- =====================================================================
-- Registers all Wingman mod configuration options with the
-- Mod Configuration Tool (MCT, Workshop ID 2927955021). Provides a
-- public API (`wingman_mct.*`) for the rest of the mod to read
-- settings at runtime.
--
-- Loaded by MCT automatically from
--   script/mct/settings/wingman_mct.lua
--
-- Safe when MCT is missing — logs a hard-dependency warning and
-- exports a defaults-only API so downstream code can still boot.
-- =====================================================================

---------------------------------------------------------------------
-- 0. Hard dependency check
---------------------------------------------------------------------
-- Bail if MCT isn't loaded; downstream code reads defaults via
-- wingman_mct.get_default_settings()
local mct = get_mct and get_mct() or nil
if not mct then
    out("[Wingman] WARNING: MCT (Mod Configuration Tool) is not loaded. Wingman requires MCT. Subscribe to Workshop item 2927955021.")
    -- Still expose a wingman_mct table so other modules can safely
    -- call is_available() / get_default_settings() without crashing.
    wingman_mct = {
        is_available = function() return false end,
        get_default_settings = function()
            return {
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
            }
        end,
        read_settings = function() return wingman_mct.get_default_settings() end,
        validate_settings = function(s) return s end,
        rebuild_ban_list = function() return false end,
        get_banned_factions = function() return {} end,
        get_all_options = function() return {} end,
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
}

-- Slider (min, max, step, default) — must match DEFAULT_SETTINGS
local SLIDER_RANGES = {
    wingman_auto_end_turn_delay_seconds = {min = 0,  max = 10,   step = 1, default = 2},
    wingman_periodic_break_interval     = {min = 0,  max = 100,  step = 1, default = 10},
    wingman_autoresolve_threshold       = {min = 0,  max = 100,  step = 1, default = 60},
    wingman_turn_cap_value              = {min = 1,  max = 500,  step = 1, default = 50},
    wingman_ai_orders_per_turn          = {min = 1,  max = 50,   step = 1, default = 12},
}

-- Dropdown option tables — keys are short, display is co-pilot-friendly
local DROPDOWN_OPTIONS = {
    wingman_safety_level = {
        {key = "conservative", text = "Conservative — pause often"},
        {key = "balanced",     text = "Balanced — middle ground"},
        {key = "permissive",   text = "Permissive — act aggressively"},
    },
    wingman_battle_control_mode = {
        {key = "scripted_ai",             text = "Scripted AI — I fight for you"},
        {key = "autoresolve_if_favorable",text = "Autoresolve if favorable — odds check"},
        {key = "pause_to_choose",         text = "Pause and choose — always ask"},
        {key = "manual_observe",          text = "Manual observe — I just watch"},
    },
    wingman_battle_plan_bias = {
        {key = "auto",   text = "Auto — let the AI decide"},
        {key = "attack", text = "Attack — aggressive"},
        {key = "defend", text = "Defend — hold and counter"},
    },
    wingman_turn_cap_outcome = {
        {key = "breakpoint", text = "Breakpoint — stop and return control"},
        {key = "victory",    text = "Victory — end campaign with official victory"},
    },
    wingman_restriction_violation_action = {
        {key = "warn_pause",   text = "Warn + pause — alert and stop"},
        {key = "pause_disable",text = "Pause + disable — turn Wingman off"},
    },
    wingman_ai_aggression = {
        {key = "defensive",  text = "Defensive — guard and consolidate"},
        {key = "balanced",   text = "Balanced — react to threats"},
        {key = "aggressive", text = "Aggressive — attack everything (default)"},
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
    local out = {}
    if type(value) ~= "string" or value == "" then return out end
    for raw in (value .. ","):gmatch("([^,]*),") do
        local k = sanitize_key(raw)
        if k and k ~= "" then
            out[#out + 1] = k
        elseif raw:match("%S") then
            out("[Wingman] WARNING: CSV key '" .. raw .. "' ignored — only [a-z0-9_] allowed.")
        end
    end
    return out
end


---------------------------------------------------------------------
-- 2. Module registration with MCT
---------------------------------------------------------------------

--- Registered mod handle. Stays valid for the entire game session.
local wingman_mod = mct:register_mod("wingman")
wingman_mod:set_title("Wingman — Your AI Co-Pilot")
wingman_mod:set_author("Wingman Team")
-- NOTE: MCT does not expose set_workshop_id() on mct_mod; the
-- dependency linkage (Workshop ID 2927955021) is declared at the
-- pack level (manifest in T9), not via this API.

-- Sections
wingman_mod:add_new_section("wingman_section_general", "General")
wingman_mod:add_new_section("wingman_section_campaign", "Campaign Handover")
wingman_mod:add_new_section("wingman_section_battle", "Battle Handover")
wingman_mod:add_new_section("wingman_section_rules", "Rules & Limits")


---------------------------------------------------------------------
-- 3. Helper: register an option in a named section with defaults
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

local function add_option(key, text, tooltip)
    local otype = OPTION_TYPE_BY_KEY[key]
    local opt = wingman_mod:add_new_option(key, otype)
    opt:set_text(text)
    if tooltip and tooltip ~= "" then
        opt:set_tooltip_text(tooltip)
    end
    return opt, otype
end


---------------------------------------------------------------------
-- 4. Section: General
---------------------------------------------------------------------
do
    local opt = wingman_mod:add_new_option("wingman_enabled", "checkbox")
    opt:set_text("Enable Wingman")
    opt:set_tooltip_text("Take the stick — let me handle your turns. Master switch for all Wingman automation.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_enabled)

    local opt = wingman_mod:add_new_option("wingman_debug_logging", "checkbox")
    opt:set_text("Verbose logging")
    opt:set_tooltip_text("Show me my work — verbose logs for troubleshooting.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_debug_logging)

    local opt = wingman_mod:add_new_option("wingman_safety_level", "dropdown")
    opt:set_text("Safety level")
    opt:set_tooltip_text("How careful should I be? Conservative = pause often. Balanced = middle ground. Permissive = act aggressively.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_safety_level)
    opt:add_dropdown_values(DROPDOWN_OPTIONS.wingman_safety_level)
end


---------------------------------------------------------------------
-- 5. Section: Campaign Handover
---------------------------------------------------------------------
do
    local opt = wingman_mod:add_new_option("wingman_campaign_handover_enabled", "checkbox")
    opt:set_text("Enable campaign handover")
    opt:set_tooltip_text("Play your campaign for you — I'll auto-end your turns so AI factions take over while you watch.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_campaign_handover_enabled)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_auto_end_turn_delay_seconds", "slider")
    opt:set_text("End-turn delay (seconds)")
    opt:set_tooltip_text("Wait N seconds before ending your turn — gives UI time to settle so I don't crash on popups.")
    opt:set_default_value(SLIDER_RANGES.wingman_auto_end_turn_delay_seconds.default)
    opt:slider_set_min_max(
        SLIDER_RANGES.wingman_auto_end_turn_delay_seconds.min,
        SLIDER_RANGES.wingman_auto_end_turn_delay_seconds.max)
    opt:slider_set_step_size(SLIDER_RANGES.wingman_auto_end_turn_delay_seconds.step)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_periodic_break_interval", "slider")
    opt:set_text("Periodic breakpoint (turns)")
    opt:set_tooltip_text("Every N turns, hand back to you for a quick review. Set to 0 to never break.")
    opt:set_default_value(SLIDER_RANGES.wingman_periodic_break_interval.default)
    opt:slider_set_min_max(
        SLIDER_RANGES.wingman_periodic_break_interval.min,
        SLIDER_RANGES.wingman_periodic_break_interval.max)
    opt:slider_set_step_size(SLIDER_RANGES.wingman_periodic_break_interval.step)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_break_on_diplomacy_panel", "checkbox")
    opt:set_text("Break on diplomacy panel")
    opt:set_tooltip_text("Pause when a diplomacy panel pops up — those tend to crash if I click blindly.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_break_on_diplomacy_panel)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_break_on_war_declaration", "checkbox")
    opt:set_text("Break on war declaration")
    opt:set_tooltip_text("Pause when war is declared on you — let you handle the alert.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_break_on_war_declaration)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_break_on_pending_battle", "checkbox")
    opt:set_text("Break on pending battle")
    opt:set_tooltip_text("Pause when a battle needs your decision.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_break_on_pending_battle)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_ai_enabled", "checkbox")
    opt:set_text("AI controls your faction")
    opt:set_tooltip_text("When I'm in the cockpit, I actively move your armies, queue buildings, recruit, and attack — using scripted orders on your own faction (highest-skill-attitude by default). Disabled = I still hand the turn back, but I won't move anything for you.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_ai_enabled)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_ai_aggression", "dropdown")
    opt:set_text("AI aggression")
    opt:set_tooltip_text("How aggressive should your AI faction play? Defensive consolidates; balanced reacts; aggressive attacks every enemy it can see.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_ai_aggression)
    opt:add_dropdown_values(DROPDOWN_OPTIONS.wingman_ai_aggression)
    opt:set_assigned_section("wingman_section_campaign")

    local opt = wingman_mod:add_new_option("wingman_ai_orders_per_turn", "slider")
    opt:set_text("AI orders per turn (cap)")
    opt:set_tooltip_text("Maximum scripted orders I issue on your behalf each turn (moves + recruit + build). Default 12 — lower if a specific mod interactions gets cranky, higher to let the AI run wild.")
    opt:set_default_value(SLIDER_RANGES.wingman_ai_orders_per_turn.default)
    opt:slider_set_min_max(
        SLIDER_RANGES.wingman_ai_orders_per_turn.min,
        SLIDER_RANGES.wingman_ai_orders_per_turn.max)
    opt:slider_set_step_size(SLIDER_RANGES.wingman_ai_orders_per_turn.step)
    opt:set_assigned_section("wingman_section_campaign")
end


---------------------------------------------------------------------
-- 6. Section: Battle Handover
---------------------------------------------------------------------
do
    local opt = wingman_mod:add_new_option("wingman_battle_handover_enabled", "checkbox")
    opt:set_text("Enable battle handover")
    opt:set_tooltip_text("Take over your battles.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_battle_handover_enabled)
    opt:set_assigned_section("wingman_section_battle")

    local opt = wingman_mod:add_new_option("wingman_battle_control_mode", "dropdown")
    opt:set_text("Battle control mode")
    opt:set_tooltip_text("How should I handle battles? scripted_ai = I fight for you. autoresolve_if_favorable = autoresolve when odds favor us. pause_to_choose = always ask. manual_observe = I just watch.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_battle_control_mode)
    opt:add_dropdown_values(DROPDOWN_OPTIONS.wingman_battle_control_mode)
    opt:set_assigned_section("wingman_section_battle")

    local opt = wingman_mod:add_new_option("wingman_battle_plan_bias", "dropdown")
    opt:set_text("Battle plan bias")
    opt:set_tooltip_text("When I fight for you, what style? auto = let the AI decide. attack = aggressive. defend = hold and counter.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_battle_plan_bias)
    opt:add_dropdown_values(DROPDOWN_OPTIONS.wingman_battle_plan_bias)
    opt:set_assigned_section("wingman_section_battle")

    local opt = wingman_mod:add_new_option("wingman_autoresolve_threshold", "slider")
    opt:set_text("Autoresolve threshold (%)")
    opt:set_tooltip_text("Only autoresolve if our win chance is above this %. Below it, pause instead. Used when control mode = autoresolve_if_favorable.")
    opt:set_default_value(SLIDER_RANGES.wingman_autoresolve_threshold.default)
    opt:slider_set_min_max(
        SLIDER_RANGES.wingman_autoresolve_threshold.min,
        SLIDER_RANGES.wingman_autoresolve_threshold.max)
    opt:slider_set_step_size(SLIDER_RANGES.wingman_autoresolve_threshold.step)
    opt:set_assigned_section("wingman_section_battle")

    local opt = wingman_mod:add_new_option("wingman_auto_dismiss_battle_results", "checkbox")
    opt:set_text("Auto-dismiss battle results")
    opt:set_tooltip_text("Auto-dismiss the post-battle results screen so I can keep your campaign moving.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_auto_dismiss_battle_results)
    opt:set_assigned_section("wingman_section_battle")
end


---------------------------------------------------------------------
-- 7. Section: Rules & Limits
---------------------------------------------------------------------
do
    local opt = wingman_mod:add_new_option("wingman_turn_cap_enabled", "checkbox")
    opt:set_text("Enable turn cap")
    opt:set_tooltip_text("Set a hard turn limit. When reached, I hand control back (or declare victory — see next option).")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_turn_cap_enabled)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_turn_cap_value", "slider")
    opt:set_text("Turn cap value")
    opt:set_tooltip_text("The turn number to cap at.")
    opt:set_default_value(SLIDER_RANGES.wingman_turn_cap_value.default)
    opt:slider_set_min_max(
        SLIDER_RANGES.wingman_turn_cap_value.min,
        SLIDER_RANGES.wingman_turn_cap_value.max)
    opt:slider_set_step_size(SLIDER_RANGES.wingman_turn_cap_value.step)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_turn_cap_outcome", "dropdown")
    opt:set_text("Turn cap outcome")
    opt:set_tooltip_text("What happens at the turn cap. breakpoint = stop and return control. victory = end campaign with the official victory screen.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_turn_cap_outcome)
    opt:add_dropdown_values(DROPDOWN_OPTIONS.wingman_turn_cap_outcome)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_custom_win_enabled", "checkbox")
    opt:set_text("Enable custom victory")
    opt:set_tooltip_text("Enable a custom victory condition I track for you.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_custom_win_enabled)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_required_settlements_csv", "text_input")
    opt:set_text("Required settlements (CSV)")
    opt:set_tooltip_text("Settlements/regions you must own to win. Comma-separated faction/region keys, e.g. 'wh_main_altdorf,wh_main_kislev_city'. Unknown keys log a warning and are ignored.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_required_settlements_csv)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_required_defeated_factions_csv", "text_input")
    opt:set_text("Required defeated factions (CSV)")
    opt:set_tooltip_text("Factions that must be destroyed for victory. Comma-separated keys.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_required_defeated_factions_csv)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_faction_restrictions_enabled", "checkbox")
    opt:set_text("Enable faction restrictions")
    opt:set_tooltip_text("Watch for banned factions — if you confederate or inherit one, I'll warn you.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_faction_restrictions_enabled)
    opt:set_assigned_section("wingman_section_rules")

    local opt = wingman_mod:add_new_option("wingman_restriction_violation_action", "dropdown")
    opt:set_text("Violation action")
    opt:set_tooltip_text("What to do on a restriction violation. warn_pause = alert and stop. pause_disable = disable Wingman entirely.")
    opt:set_default_value(DEFAULT_SETTINGS.wingman_restriction_violation_action)
    opt:add_dropdown_values(DROPDOWN_OPTIONS.wingman_restriction_violation_action)
    opt:set_assigned_section("wingman_section_rules")
end


---------------------------------------------------------------------
-- 8. Faction ban dynamic UI  (Pattern A from MCT research)
---------------------------------------------------------------------
-- A single MCT.ControlGroup.Array that, on panel open, populates
-- itself with one checkbox per in-world faction (keyed "ban_<key>").
-- Dynamic: the world may not exist at load time — we mark the array
-- as "needs rebuild" and rebuild it lazily in OnPopulate.

local array_class    = mct:get_object_type("control_groups", "array")
local checkbox_class = mct:get_mct_option_class_subtype("checkbox")

---@type MCT.ControlGroup.Array
local ban_array = array_class and array_class:new() or nil
if ban_array then
    ban_array:set_key("wingman_banned_factions_array")
end

local ban_array_dirty = true
local ban_checkboxes = {} -- by faction_key -> mct_option

-- The Rules & Limits section is where the ban array displays.
local rules_section = (function()
    local ok, sections = pcall(function()
        return wingman_mod:get_sections()
    end)
    if not ok or type(sections) ~= "table" then return nil end
    for key, s in pairs(sections) do
        if key == "wingman_section_rules" or (s.get_key and s:get_key() == "wingman_section_rules") then
            return s
        end
    end
    return nil
end)()


--- Wire the panel-open rebuild hook. We attach OnPopulate to the
--- Rules & Limits settings page so that opening the section
--- re-populates the ban list from the current world.
local function attach_populate_hook()
    if not rules_section then return end
    local page = rules_section:get_settings_page and rules_section:get_settings_page()
    if not page then return end

    ---@diagnostic disable-next-line: duplicate-set-field
    function page:OnPopulate(uic)
        if not ban_array_dirty then return end
        wingman_mct.rebuild_ban_list()
        if ban_array then
            local col = find_uicomponent(uic, "settings_column_1")
            local box = col and find_uicomponent(col, "list_clip", "list_box") or nil
            if box then
                ban_array:display(box)
            end
        end
        ban_array_dirty = false
    end
end

attach_populate_hook()


---------------------------------------------------------------------
-- 9. Public API
---------------------------------------------------------------------

--- Return MCT availability.
local function is_available()
    return mct ~= nil
end

--- Return the default settings table (always available).
local function get_default_settings()
    -- Return a shallow copy so callers cannot mutate our defaults.
    local copy = {}
    for k, v in pairs(DEFAULT_SETTINGS) do copy[k] = v end
    return copy
end

--- Read the current finalized settings from MCT, falling back to
--- defaults for any missing key.
local function read_settings()
    local out = get_default_settings()
    for k, _ in pairs(out) do
        local opt = wingman_mod:get_option_by_key(k)
        if opt then
            local v = opt:get_finalized_setting()
            if v ~= nil then out[k] = v end
        end
    end

    -- Faction bans come from the dynamic array; read them here so
    -- read_settings() returns a fully-populated table.
    out.wingman_banned_factions = wingman_mct.get_banned_factions()

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
        elseif type(v) ~= "boolean" and (OPTION_TYPE_BY_KEY[k] == "checkbox") then
            settings[k] = DEFAULT_SETTINGS[k]
        end
    end

    -- Fill in any missing keys from defaults
    for k, v in pairs(DEFAULT_SETTINGS) do
        if settings[k] == nil then settings[k] = v end
    end

    -- Reconstruct sanitized CSV arrays (these mirror the raw csv setting)
    settings.wingman_required_settlements = parse_key_csv(settings.wingman_required_settlements_csv)
    settings.wingman_required_defeated_factions = parse_key_csv(settings.wingman_required_defeated_factions_csv)

    return settings
end

--- Rebuild the dynamic faction ban list from the current world.
--- Safe to call when cm or the world is not yet ready.
local function rebuild_ban_list()
    if not ban_array then return false end

    -- Clear prior checkboxes (best-effort — control group may not
    -- expose a public clear(); in that case we simply stop here and
    -- ask the user to restart the panel for a fresh build).
    if ban_array.clear then
        local ok, err = pcall(function() ban_array:clear() end)
        if not ok then
            out("[Wingman] WARNING: ban_array:clear() failed: " .. tostring(err))
        end
    end
    ban_checkboxes = {}

    -- Guard: cm / world / faction_manager may not exist at load time.
    if not (cm and cm:model and cm:model()) then
        return false, "cm:model() not yet ready"
    end
    local ok, world = pcall(function() return cm:model():world() end)
    if not ok or not world then
        return false, "cm:model():world() unavailable"
    end
    local ok2, fm = pcall(function() return world:faction_manager() end)
    if not ok2 or not fm then
        return false, "faction_manager unavailable"
    end

    local count = 0
    for i = 0, (fm:num_factions() or 0) - 1 do
        local f = fm:faction_at and fm:faction_at(i)
        if f then
            local faction_key = f:name() or "unknown_" .. tostring(i)
            local display    = f:get_name and f:get_name() or faction_key
            local cb = checkbox_class and checkbox_class:new(wingman_mod, "ban_" .. faction_key)
            if cb then
                cb:set_text(display .. "  (" .. faction_key .. ")")
                cb:set_tooltip_text(faction_key)
                cb:set_default_value(false)
                count = count + 1
                ban_checkboxes[faction_key] = cb
                if ban_array.add_control then
                    local ok_add, err_add = pcall(function() ban_array:add_control(cb, count) end)
                    if not ok_add then
                        out("[Wingman] WARNING: ban_array:add_control failed: " .. tostring(err_add))
                    end
                end
            end
        end
    end

    ban_array_dirty = false
    return true, count
end

--- Return the list of banned faction keys.
local function get_banned_factions()
    local banned = {}
    if not ban_array then return banned end
    local options = ban_array.get_options and ban_array:get_options() or {}
    for _, opt in ipairs(options) do
        local key = opt:get_key and opt:get_key() or ""
        if key:match("^ban_") and opt:get_finalized_setting() == true then
            banned[#banned + 1] = (key:gsub("^ban_", ""))
        end
    end
    -- Fallback path: if the array has no options (panel never opened),
    -- read from the cached checkbox table.
    if #banned == 0 then
        for k, cb in pairs(ban_checkboxes) do
            if cb:get_finalized_setting and cb:get_finalized_setting() == true then
                banned[#banned + 1] = k
            end
        end
    end
    return banned
end

--- Return a flat list of (key, value, type) for the rules engine.
local function get_all_options()
    local out = {}
    for k, def in pairs(DEFAULT_SETTINGS) do
        local opt = wingman_mod:get_option_by_key(k)
        local val = opt and opt:get_finalized_setting() or def
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
