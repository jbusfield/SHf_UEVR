-- Precedence of the systems that share the VR grips through libs/grip: the claim with the highest number owns a press.
-- Kept in one table so the order is visible and adjustable in one place.
local M = {
	LADDER = 1000,      -- interactions.lua (Physical Ladder): a grip that starts with a rung in reach while on a ladder
	ITEM_HELD = 200,    -- interactions.lua (Physical Item Grab): a press while an item is already flying or held
	MECHANISM = 95,     -- libs/mechanisms (Engage With: Grip): a grip that starts within reach of a mechanism's hand spot (doors,
	                    -- getting on a ladder, the log bundle). Above HEAD_GESTURE, so a grip at a thing beside the head works it.
	HEAD_GESTURE = 90,  -- main.lua: a left grip that starts at the ear (inventory) or mouth (heal), a right grip that starts at the ear
	ITEM_GRAB = 50,     -- interactions.lua (Physical Item Grab): grab what the game's interaction prompt is on
	INTERACT = 40,      -- interactions.lua (Grip Interact): a left grip presses A for anything else showing an interaction prompt
}

return M
