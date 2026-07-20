--[[
Wingman — central listener registry.

Owns:
  - The single tracked-listener table for the whole mod. Every
    core:add_listener call should route through this module so that
    wingman.shutdown can bulk-remove them on save/load and on game exit.
  - A defensive pcall wrapper so a broken engine call cannot take down
    the campaign loader.
  - A diagnostic surface (count, is_registered, list_names) for the
    W8 spectator panel and the W11 self-review tooling.

Every module in this mod that registers an event listener MUST call
`wingman_listeners.register(name, event, cond, cb, persist)` instead of
calling `core:add_listener` directly. This guarantees the listener is
tracked, pcall'd, and removable on shutdown.

The module depends on nothing. It is safe to load as the first
campaign-side module.

Lua 5.1 only. Never throws.
]]

wingman_listeners = {}

-- ---------------------------------------------------------------------------
-- Internal tracked-listener array. Order of insertion = order of registration.
-- Module-private; mutated only via register() / unregister() / unregister_all().
-- ---------------------------------------------------------------------------

local _tracked = {}        -- array of name strings
local _duplicates_skipped = 0  -- diagnostic counter

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

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Register a TWW3 event listener and track it for later bulk removal.
--
-- Mirrors the engine's `core:add_listener(name, event, condition, callback, persist)`
-- call. On success, the listener name is added to the tracked set; on
-- failure, the error is logged and false is returned (no throw).
--
-- Re-registering the same name is a no-op (idempotent). This avoids the
-- double-listener bug after save/load.
--
-- @param name      string  Unique listener name (used as the key for removal).
-- @param event     string  Engine event name ("FactionTurnStart", "PanelOpenedCampaign", ...).
-- @param condition any     Engine condition (typically `true`; or a function returning bool).
-- @param callback  function(context)  Lua handler invoked when the event fires.
-- @param persist   bool    Optional. If true, the listener survives save/load. Default false.
-- @return          bool    true on success (or idempotent skip), false on engine error.
function wingman_listeners.register(name, event, condition, callback, persist)
    if type(name) ~= "string" or name == "" then
        warn("register: invalid name (" .. tostring(name) .. ")")
        return false
    end
    if type(event) ~= "string" or event == "" then
        warn("register(" .. name .. "): invalid event (" .. tostring(event) .. ")")
        return false
    end
    if type(callback) ~= "function" then
        warn("register(" .. name .. "): callback is not a function (" .. type(callback) .. ")")
        return false
    end

    -- Idempotency: skip if already tracked.
    for _, existing in ipairs(_tracked) do
        if existing == name then
            _duplicates_skipped = _duplicates_skipped + 1
            return true
        end
    end

    if not core or type(core.add_listener) ~= "function" then
        warn("register(" .. name .. "): core.add_listener unavailable")
        return false
    end

    local ok, err = pcall(core.add_listener, core, name, event, condition, callback, persist and true or false)
    if not ok then
        warn("register(" .. name .. ") for " .. event .. " failed: " .. tostring(err))
        return false
    end

    _tracked[#_tracked + 1] = name
    return true
end

--- Unregister a single listener by name.
-- @param name  string  The listener name to remove.
-- @return      bool    true if removed, false if not registered or engine unavailable.
function wingman_listeners.unregister(name)
    if type(name) ~= "string" or name == "" then return false end
    if not core or type(core.remove_listener) ~= "function" then
        warn("unregister(" .. name .. "): core.remove_listener unavailable")
        return false
    end
    local ok, err = pcall(core.remove_listener, core, name)
    if not ok then
        warn("unregister(" .. name .. ") failed: " .. tostring(err))
        return false
    end
    -- Remove from tracked array
    for i, existing in ipairs(_tracked) do
        if existing == name then
            table.remove(_tracked, i)
            return true
        end
    end
    return true  -- engine said ok even if we didn't have it tracked
end

--- Unregister every tracked listener. Idempotent. Safe to call multiple times.
-- Failures are isolated: a failing engine call logs a warning and the
-- next listener is still attempted.
-- @return number  Count of remove attempts (success or failure). Equal to
--                 the number of tracked listeners at call time.
function wingman_listeners.unregister_all()
    if not core or type(core.remove_listener) ~= "function" then
        warn("unregister_all: core.remove_listener unavailable; clearing tracked only")
        local n = #_tracked
        _tracked = {}
        return n
    end
    local n_attempted = 0
    local snapshot = {}
    for i, name in ipairs(_tracked) do snapshot[i] = name end
    _tracked = {}
    for _, name in ipairs(snapshot) do
        local ok, err = pcall(core.remove_listener, core, name)
        if not ok then
            warn("unregister_all: " .. name .. " failed: " .. tostring(err))
        end
        n_attempted = n_attempted + 1
    end
    return n_attempted
end

--- Is a given listener name currently tracked by this registry?
-- @param name  string
-- @return      bool
function wingman_listeners.is_registered(name)
    if type(name) ~= "string" then return false end
    for _, existing in ipairs(_tracked) do
        if existing == name then return true end
    end
    return false
end

--- Number of currently-tracked listeners (diagnostic).
-- @return number
function wingman_listeners.count()
    return #_tracked
end

--- Snapshot of currently-tracked listener names (diagnostic).
-- Returns a NEW array (caller cannot mutate internal state).
-- @return table (array of strings)
function wingman_listeners.list_names()
    local out = {}
    for i, name in ipairs(_tracked) do out[i] = name end
    return out
end

--- Diagnostic counters.
-- @return number, number  tracked_count, duplicates_skipped
function wingman_listeners.diagnostics()
    return #_tracked, _duplicates_skipped
end

-- ---------------------------------------------------------------------------
-- Expose the underlying tracker (read-only) for the legacy `wingman_init`
-- path that stored the same data in its own table. This keeps backward
-- compatibility with the existing `state.tracked_listeners` debug surface.
-- ---------------------------------------------------------------------------

wingman_listeners._internal = {
    get_tracked = function() return _tracked end,
}
