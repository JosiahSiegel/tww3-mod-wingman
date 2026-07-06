-- Absolute minimum test: just register_mod with no other code.
-- If this doesn't work, the issue is at the launcher/VFS level.
local mct = get_mct()
local mod = mct:register_mod("wingman_absolute_min")
