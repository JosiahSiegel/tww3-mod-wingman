-- Minimal MCT test - matches canonical chadvandy mct.lua pattern exactly.
-- If THIS shows up in the MCT panel, the issue is in my full wingman_mct.lua.
-- If THIS doesn't show up either, the issue is structural (load order, mod key, etc).

out("[WingmanTest DEBUG] T0: wingman_test_mct.lua body starting")
local mct = get_mct()
out("[WingmanTest DEBUG] T1: get_mct() returned: " .. tostring(mct))

local test_mod = mct:register_mod("wingman_test")
out("[WingmanTest DEBUG] T2: register_mod returned: " .. tostring(test_mod))
test_mod:set_workshop_id("wingman_test_id")
out("[WingmanTest DEBUG] T3: set_workshop_id OK")
test_mod:set_version(mct:get_version_number(), mct:get_version())
out("[WingmanTest DEBUG] T4: set_version OK")
test_mod:set_main_image("ui/mct/van_mct.png", 300, 300)
out("[WingmanTest DEBUG] T5: set_main_image OK")
test_mod:set_description("Wingman minimal test mod")
out("[WingmanTest DEBUG] T6: set_description OK")

local test_opt = test_mod:add_new_option("wingman_test_enabled", "checkbox")
out("[WingmanTest DEBUG] T7: add_new_option returned: " .. tostring(test_opt))
test_opt:set_default_value(true)
out("[WingmanTest DEBUG] T8: set_default_value OK")
test_opt:set_text("Wingman Test: Enabled")
out("[WingmanTest DEBUG] T9: set_text OK")
test_opt:set_tooltip_text("If you see this, MCT integration works!")
out("[WingmanTest DEBUG] T10: set_tooltip_text OK")
test_opt:set_is_global(true)
out("[WingmanTest DEBUG] T11: set_is_global OK - body complete")
