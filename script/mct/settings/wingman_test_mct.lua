-- Minimal MCT test - matches canonical chadvandy mct.lua pattern exactly.
-- If THIS shows up in the MCT panel, the issue is in my full wingman_mct.lua.
-- If THIS doesn't show up either, the issue is structural (load order, mod key, etc).

local mct = get_mct()

local test_mod = mct:register_mod("wingman_test")
test_mod:set_workshop_id("wingman_test_id")
test_mod:set_version(mct:get_version_number(), mct:get_version())
test_mod:set_main_image("ui/mct/van_mct.png", 300, 300)
test_mod:set_description("Wingman minimal test mod")

local test_opt = test_mod:add_new_option("wingman_test_enabled", "checkbox")
test_opt:set_default_value(true)
test_opt:set_text("Wingman Test: Enabled")
test_opt:set_tooltip_text("If you see this, MCT integration works!")
test_opt:set_is_global(true)
