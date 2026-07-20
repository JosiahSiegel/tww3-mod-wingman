--[[
Wingman — shared constants.

This module centralizes every stringly-typed constant that is used in
more than one Lua file. Each constant lives in exactly one place so
that:

  - A rename is a single-file edit.
  - A typo in a string comparison becomes a `nil` error (Lua) instead
    of a silent mismatch.
  - A new constant only needs to be added to the central list, not
    hunted for in every consumer.

Naming convention: UPPER_SNAKE_CASE. All strings are the wire-format
values (the same string the user sees in the saved settings file, the
same string the MCT UI shows). Helpers under `*_LIST` are arrays
derived from the single source of truth and used in validation/UI
generation.

This module has no dependencies and may be loaded as the first
campaign-side module. Lua 5.1 only. Never throws.
]]

wingman_constants = {}

-- ---------------------------------------------------------------------------
-- Battle control modes (used by wingman_battle + wingman_state + MCT)
-- ---------------------------------------------------------------------------

wingman_constants.MODE_SCRIPTED_AI             = "scripted_ai"
wingman_constants.MODE_AUTORESOLVE_IF_FAVORABLE = "autoresolve_if_favorable"
wingman_constants.MODE_PAUSE_TO_CHOOSE         = "pause_to_choose"
wingman_constants.MODE_MANUAL_OBSERVE          = "manual_observe"

wingman_constants.BATTLE_MODES = {
    "scripted_ai",
    "autoresolve_if_favorable",
    "pause_to_choose",
    "manual_observe",
}

-- ---------------------------------------------------------------------------
-- Aggression profile (used by wingman_ai + wingman_state + MCT)
-- ---------------------------------------------------------------------------

wingman_constants.AGGRESSION_DEFENSIVE  = "defensive"
wingman_constants.AGGRESSION_BALANCED   = "balanced"
wingman_constants.AGGRESSION_AGGRESSIVE = "aggressive"

wingman_constants.AGGRESSION_PROFILES = {
    "defensive",
    "balanced",
    "aggressive",
}

-- ---------------------------------------------------------------------------
-- Setting key names (used by DEFAULTS, BOUNDS, validate_settings, MCT, and
-- every module that reads settings). Centralized so a rename is one edit.
--
-- Only includes settings used in 2+ files. Settings used in exactly one
-- file stay local to that file to avoid noise.
-- ---------------------------------------------------------------------------

wingman_constants.SETTINGS = {
    WINGMAN_ENABLED                 = "wingman_enabled",
    WINGMAN_AI_ORDERS_PER_TURN      = "wingman_ai_orders_per_turn",
    WINGMAN_AI_DIFFICULTY           = "wingman_ai_difficulty",
    WINGMAN_AI_AGGRESSION           = "wingman_ai_aggression",
    WINGMAN_BATTLE_CONTROL_MODE     = "wingman_battle_control_mode",
    WINGMAN_DEBUG_LOGGING           = "wingman_debug_logging",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- True if `value` is a valid battle control mode.
function wingman_constants.is_battle_mode(value)
    for _, m in ipairs(wingman_constants.BATTLE_MODES) do
        if m == value then return true end
    end
    return false
end

--- True if `value` is a valid aggression profile.
function wingman_constants.is_aggression(value)
    for _, p in ipairs(wingman_constants.AGGRESSION_PROFILES) do
        if p == value then return true end
    end
    return false
end
