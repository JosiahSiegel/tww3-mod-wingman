--[[
Wingman — rule evaluators.

Owns the rule contract: every evaluator returns a structured result table
that the campaign driver can rank by priority:

    {
        outcome = "pass" | "breakpoint" | "victory" | "warning" | "error",
        reason  = string,   -- human/log readable
        data    = any,      -- optional payload (turn number, faction key, etc.)
    }

evaluate_all(context) runs every enabled evaluator in priority order and
returns the highest-priority non-pass result. Priority from highest to
lowest: error > victory > breakpoint > warning > pass.

Rules covered (v0.1):
  - Turn cap (settings: wingman_turn_cap_*).
  - Custom win (settlements owned + factions defeated CSV).
  - Faction restrictions (banned-faction watcher; ownership only).

Faction restriction violations NEVER destructively mutate campaign state —
they pause / warn per setting. The ban checker is a watcher, not an
enforcer.

Depends on:
  - wingman_state (settings, set_rule_progress / get_rule_progress).
  - wingman_safety.safe_call for risky cm calls.
  - wingman_mct.get_banned_factions (guarded; optional in v0.1).
  - TWW3 cm / campaign model APIs.

Lua 5.1 syntax. Defensive at every step; never throws.
]]

wingman_rules = wingman_rules or {}

-- ---------------------------------------------------------------------------
-- Constants — outcome strings + priority ordering
-- ---------------------------------------------------------------------------

local OUTCOME_PASS       = "pass"
local OUTCOME_BREAKPOINT = "breakpoint"
local OUTCOME_VICTORY    = "victory"
local OUTCOME_WARNING    = "warning"
local OUTCOME_ERROR      = "error"

-- Higher number = higher priority. evaluate_all picks the max.
local OUTCOME_PRIORITY = {
    [OUTCOME_PASS]       = 0,
    [OUTCOME_WARNING]    = 1,
    [OUTCOME_BREAKPOINT] = 2,
    [OUTCOME_VICTORY]    = 3,
    [OUTCOME_ERROR]      = 4,
}

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
    log("[DBG][rules] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Settings / state helpers — defensive, never throw
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

local function get_current_turn()
    if not cm or type(cm.turn_number) ~= "function" then return 0 end
    local ok, t = pcall(cm.turn_number, cm)
    if not ok then return 0 end
    local n = tonumber(t)
    return n or 0
end

-- ---------------------------------------------------------------------------
-- CSV parser — splits, trims, lowercases, validates per-key shape.
--
-- Differs from validate_csv_keys in wingman_state:
--   - This returns a LIST, not a string (callers want to iterate).
--   - This is non-strict: invalid characters log a warning but the key is
--     kept, so the rule engine can report "missing: <weird_key>" instead of
--     silently dropping user data.
-- ---------------------------------------------------------------------------

--[[ Split a CSV string into a clean key list.
    value: raw CSV string (may be nil/empty).
    kind:  optional label for log context ("settlement" | "faction" | nil).
    Returns a list of lowercase, trimmed keys. May be empty. Never throws. ]]
function wingman_rules.parse_key_csv(value, kind)
    local result = {}
    if value == nil then return result end
    if type(value) ~= "string" then
        warn(string.format("parse_key_csv(%s): non-string value (%s)",
            tostring(kind or "?"), type(value)))
        return result
    end

    for raw in value:gmatch("[^,]+") do
        local key = raw:match("^%s*(.-)%s*$")
        if key and key ~= "" then
            key = key:lower()
            if not key:match("^[a-z0-9_]+$") then
                warn(string.format("parse_key_csv(%s): key '%s' has non-conformant chars; keeping anyway",
                    tostring(kind or "?"), tostring(key)))
            end
            result[#result + 1] = key
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Query helpers — guarded pcall around the cm query model.
-- ---------------------------------------------------------------------------

local function query_model()
    if not cm or type(cm.query_model) ~= "function" then return nil end
    local ok, qm = pcall(cm.query_model, cm)
    if not ok or not qm then return nil end
    return qm
end

--[[ Iterate region_list safely. Returns iterator closure or nil.
    Pre-fix: the closure called `pcall(regions.num_items, regions)` on
    EVERY iteration. `num_items` is constant for the lifetime of the
    list object — caching it once when the closure is created turns
    O(N) pcalls into O(1). For a campaign with 100+ regions this is
    ~200 fewer pcalls per turn-end evaluator pass. ]]
local function iter_regions()
    local qm = query_model()
    if not qm or type(qm.region_list) ~= "function" then return nil end
    local ok, regions = pcall(qm.region_list, qm)
    if not ok or not regions then return nil end
    -- Hoist the count out of the closure.
    local count = 0
    if type(regions.num_items) == "function" then
        local ok_c, c = pcall(regions.num_items, regions)
        if ok_c and type(c) == "number" then count = c end
    end
    local item_at = regions.item_at
    if type(item_at) ~= "function" then return nil end
    local i = 0
    return function()
        i = i + 1
        if i > count then return nil end
        local ok3, r = pcall(item_at, regions, i)
        if not ok3 or not r then return nil end
        return r
    end
end

--[[ Iterate faction_list safely. Returns iterator closure or nil.
    Same hoisting pattern as iter_regions — see comment above. ]]
local function iter_factions()
    local qm = query_model()
    if not qm or type(qm.faction_list) ~= "function" then return nil end
    local ok, factions = pcall(qm.faction_list, qm)
    if not ok or not factions then return nil end
    local count = 0
    if type(factions.num_items) == "function" then
        local ok_c, c = pcall(factions.num_items, factions)
        if ok_c and type(c) == "number" then count = c end
    end
    local item_at = factions.item_at
    if type(item_at) ~= "function" then return nil end
    local i = 0
    return function()
        i = i + 1
        if i > count then return nil end
        local ok3, f = pcall(item_at, factions, i)
        if not ok3 or not f then return nil end
        return f
    end
end

local function region_key(region)
    if not region then return nil end
    if type(region.key) == "function" then
        local ok, k = pcall(region.key, region)
        if ok and type(k) == "string" and k ~= "" then return k end
    end
    if type(region.name) == "function" then
        local ok, n = pcall(region.name, region)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return nil
end

local function region_owning_faction_key(region)
    if not region then return nil end
    local owner = nil
    if type(region.owning_faction) == "function" then
        local ok, f = pcall(region.owning_faction, region)
        if ok then owner = f end
    end
    if not owner then return nil end
    if type(owner.name) == "function" then
        local ok, n = pcall(owner.name, owner)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return nil
end

local function faction_key(faction)
    if not faction then return nil end
    if type(faction.name) == "function" then
        local ok, n = pcall(faction.name, faction)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    if type(faction) == "string" then return faction end
    return nil
end

local function faction_is_eliminated(faction_key_name)
    -- TWW3 exposes faction:has_been_defeated() in modern versions; older
    -- patches may not. Walk faction_list and check is_defeated if available;
    -- otherwise fall back to "no regions owned" as a proxy.
    for f in iter_factions() or function() return nil end do
        local k = faction_key(f)
        if k == faction_key_name then
            if type(f.is_defeated) == "function" then
                local ok, val = pcall(f.is_defeated, f)
                if ok then return val == true end
            end
            -- Proxy: a faction with zero owned regions is effectively eliminated.
            local owns_any = false
            for r in iter_regions() or function() return nil end do
                if region_owning_faction_key(r) == faction_key_name then
                    owns_any = true
                    break
                end
            end
            return not owns_any
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Rule evaluators
-- ---------------------------------------------------------------------------

--[[ Turn-cap evaluator. Reads wingman_turn_cap_* settings, compares the
    current turn to the cap, and emits a pass / breakpoint / victory result. ]]
function wingman_rules.evaluate_turn_cap(context)
    local s = get_settings()
    if s.wingman_turn_cap_enabled ~= true then
        return { outcome = OUTCOME_PASS, reason = "turn_cap_disabled" }
    end

    local cap = tonumber(s.wingman_turn_cap_value) or 50
    local outcome_kind = s.wingman_turn_cap_outcome or "breakpoint"
    if outcome_kind ~= "victory" and outcome_kind ~= "breakpoint" then
        outcome_kind = "breakpoint"
    end

    local turn = get_current_turn()
    if turn < cap then
        return {
            outcome = OUTCOME_PASS,
            reason  = "turn_cap_not_reached",
            data    = { turn = turn, cap = cap },
        }
    end

    if outcome_kind == "victory" then
        return {
            outcome = OUTCOME_VICTORY,
            reason  = "turn_cap_victory",
            data    = { turn = turn, cap = cap },
        }
    end

    return {
        outcome = OUTCOME_BREAKPOINT,
        reason  = "turn_cap_reached",
        data    = { turn = turn, cap = cap },
    }
end

--[[ Custom-win evaluator. Settlements-owned and factions-defeated lists
    must BOTH be satisfied (if both populated) for a victory result. Empty
    lists are treated as "no constraint" (skipped). ]]
function wingman_rules.evaluate_custom_win(context)
    local s = get_settings()
    if s.wingman_custom_win_enabled ~= true then
        return { outcome = OUTCOME_PASS, reason = "custom_win_disabled" }
    end

    local settlements = wingman_rules.parse_key_csv(
        s.wingman_required_settlements_csv, "settlement")
    local factions    = wingman_rules.parse_key_csv(
        s.wingman_required_defeated_factions_csv, "faction")

    if #settlements == 0 and #factions == 0 then
        -- Enabled but no objectives: don't fire victory, but flag as a
        -- warning so the player gets feedback.
        warn("custom_win enabled but both objective lists are empty")
        return {
            outcome = OUTCOME_WARNING,
            reason  = "custom_win_no_objectives",
            data    = {},
        }
    end

    local local_faction = get_local_faction_key()
    if not local_faction then
        warn("custom_win: local faction unknown; cannot evaluate ownership")
        return {
            outcome = OUTCOME_PASS,
            reason  = "custom_win_no_local_faction",
            data    = {},
        }
    end

    -- ---- Settlement check ----
    local missing_settlements = {}
    local settlement_owned = {}

    if #settlements > 0 then
        -- Build a set of regions owned by local faction this turn.
        local owned = {}
        for r in iter_regions() or function() return nil end do
            local rk = region_key(r)
            local ok_owner = region_owning_faction_key(r)
            if rk and ok_owner == local_faction then
                owned[rk] = true
            end
        end

        for _, sk in ipairs(settlements) do
            if owned[sk] then
                settlement_owned[#settlement_owned + 1] = sk
            else
                missing_settlements[#missing_settlements + 1] = sk
            end
        end

        if #missing_settlements > 0 then
            return {
                outcome = OUTCOME_PASS,
                reason  = "custom_win_settlements_missing",
                data    = {
                    missing    = missing_settlements,
                    owned      = settlement_owned,
                    kind       = "settlements",
                },
            }
        end
    end

    -- ---- Faction check ----
    local surviving_factions = {}
    local defeated_factions  = {}

    if #factions > 0 then
        for _, fk in ipairs(factions) do
            if faction_is_eliminated(fk) then
                defeated_factions[#defeated_factions + 1] = fk
            else
                surviving_factions[#surviving_factions + 1] = fk
            end
        end

        if #surviving_factions > 0 then
            return {
                outcome = OUTCOME_PASS,
                reason  = "custom_win_factions_surviving",
                data    = {
                    surviving = surviving_factions,
                    defeated  = defeated_factions,
                    kind      = "factions",
                },
            }
        end
    end

    return {
        outcome = OUTCOME_VICTORY,
        reason  = "custom_win_complete",
        data    = {
            settlements = settlement_owned,
            factions    = defeated_factions,
        },
    }
end

--[[ Faction-restrictions evaluator. Watches the player faction for any
    banned faction being owned (via confederation, inheritance, or any other
    transfer). Banned-faction check is for v0.1 simple ownership only — does
    NOT attempt to break alliances, kick the player out, or modify state. ]]
function wingman_rules.evaluate_faction_restrictions(context)
    local s = get_settings()
    if s.wingman_faction_restrictions_enabled ~= true then
        return { outcome = OUTCOME_PASS, reason = "faction_restrictions_disabled" }
    end

    -- Read the ban list dynamically from MCT (T2-owned). Guard for absence.
    local banned = {}
    if type(_G.wingman_mct) == "table" and type(_G.wingman_mct.get_banned_factions) == "function" then
        local ok, result = pcall(_G.wingman_mct.get_banned_factions)
        if ok and type(result) == "table" then
            banned = result
        else
            warn("faction_restrictions: get_banned_factions failed: " .. tostring(result))
        end
    end

    if #banned == 0 then
        return { outcome = OUTCOME_PASS, reason = "faction_restrictions_no_bans" }
    end

    -- Build a set of factions owned by the player this turn.
    local local_faction = get_local_faction_key()
    if not local_faction then
        warn("faction_restrictions: local faction unknown")
        return {
            outcome = OUTCOME_PASS,
            reason  = "faction_restrictions_no_local_faction",
            data    = { banned = banned },
        }
    end

    local owned_by_player = {}
    for r in iter_regions() or function() return nil end do
        local owner = region_owning_faction_key(r)
        if owner then owned_by_player[owner] = true end
    end
    -- The local faction itself owns at least itself.
    owned_by_player[local_faction] = true

    for _, banned_key in ipairs(banned) do
        if owned_by_player[banned_key] then
            -- Map action setting to outcome. v0.1: never destructively mutate.
            local action = s.wingman_restriction_violation_action or "warn_pause"
            local result_outcome = OUTCOME_WARNING
            local result_reason = "banned_faction_owned_warn"

            if action == "pause_disable" then
                result_outcome = OUTCOME_BREAKPOINT
                result_reason = "banned_faction_owned_pause"
            end

            return {
                outcome = result_outcome,
                reason  = result_reason,
                data    = { faction_key = banned_key, action = action },
            }
        end
    end

    return {
        outcome = OUTCOME_PASS,
        reason  = "faction_restrictions_clean",
        data    = { checked = #banned },
    }
end

-- ---------------------------------------------------------------------------
-- Aggregator — runs all enabled evaluators, returns highest-priority result
-- ---------------------------------------------------------------------------

--[[ Run every enabled evaluator in order and return the highest-priority
    non-pass result. Returns { outcome="pass", reason="all_rules_pass" } when
    everything passes. Never throws. ]]
function wingman_rules.evaluate_all(context)
    context = context or {}

    local evaluators = {
        { name = "turn_cap",             fn = wingman_rules.evaluate_turn_cap },
        { name = "custom_win",           fn = wingman_rules.evaluate_custom_win },
        { name = "faction_restrictions", fn = wingman_rules.evaluate_faction_restrictions },
    }

    local best = {
        outcome = OUTCOME_PASS,
        reason  = "all_rules_pass",
        data    = {},
    }

    for _, ev in ipairs(evaluators) do
        local ok, result = pcall(ev.fn, context)
        if not ok then
            warn(string.format("evaluator %s threw: %s", ev.name, tostring(result)))
            -- Treat a thrown evaluator as an error-result if it would beat pass.
            result = {
                outcome = OUTCOME_ERROR,
                reason  = ev.name .. "_evaluator_threw",
                data    = { err = tostring(result) },
            }
        end

        if type(result) ~= "table" or type(result.outcome) ~= "string" then
            warn(string.format("evaluator %s returned malformed result", ev.name))
            result = {
                outcome = OUTCOME_ERROR,
                reason  = ev.name .. "_malformed_result",
                data    = {},
            }
        end

        local p = OUTCOME_PRIORITY[result.outcome] or 0
        if p > (OUTCOME_PRIORITY[best.outcome] or 0) then
            best = result
            debug_log(string.format("evaluator %s produced higher-priority result: %s (%s)",
                ev.name, tostring(result.outcome), tostring(result.reason)))
        end

        -- Early exit: an error is the highest priority; no point running more.
        if best.outcome == OUTCOME_ERROR then break end
    end

    -- Snapshot for save/load (best-effort).
    if type(wingman_state) == "table" and type(wingman_state.set_rule_progress) == "function" then
        pcall(wingman_state.set_rule_progress, {
            last_outcome = best.outcome,
            last_reason  = best.reason,
            last_turn    = get_current_turn(),
        })
    end

    return best
end

-- ---------------------------------------------------------------------------
-- describe_result — human/log readable
-- ---------------------------------------------------------------------------

--[[ Format a result table for logging / display. ]]
function wingman_rules.describe_result(result)
    if type(result) ~= "table" then
        return "<invalid result>"
    end
    local outcome = result.outcome or "?"
    local reason  = result.reason  or "?"
    local data    = result.data
    local data_str = ""
    if type(data) == "table" then
        -- Serialize just one level deep so logs stay readable.
        local parts = {}
        for k, v in pairs(data) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
        data_str = " {" .. table.concat(parts, ", ") .. "}"
    elseif data ~= nil then
        data_str = " data=" .. tostring(data)
    end
    return string.format("outcome=%s reason=%s%s", outcome, reason, data_str)
end

-- ---------------------------------------------------------------------------
-- Save/load convenience
-- ---------------------------------------------------------------------------

--[[ Read the current rule-progress snapshot from wingman_state. ]]
function wingman_rules.get_rule_progress()
    if type(wingman_state) ~= "table" or type(wingman_state.get_rule_progress) ~= "function" then
        return nil
    end
    local ok, val = pcall(wingman_state.get_rule_progress)
    if not ok then return nil end
    return val
end

--[[ Persist a rule-progress snapshot via wingman_state. ]]
function wingman_rules.set_rule_progress(progress)
    if type(wingman_state) ~= "table" or type(wingman_state.set_rule_progress) ~= "function" then
        return false
    end
    local ok, val = pcall(wingman_state.set_rule_progress, progress)
    if not ok then return false end
    return val == true
end

-- ---------------------------------------------------------------------------
-- Constants re-export — let callers inspect outcomes without string typos
-- ---------------------------------------------------------------------------

wingman_rules.OUTCOME_PASS       = OUTCOME_PASS
wingman_rules.OUTCOME_BREAKPOINT = OUTCOME_BREAKPOINT
wingman_rules.OUTCOME_VICTORY    = OUTCOME_VICTORY
wingman_rules.OUTCOME_WARNING    = OUTCOME_WARNING
wingman_rules.OUTCOME_ERROR      = OUTCOME_ERROR