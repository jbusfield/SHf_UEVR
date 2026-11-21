local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require("libs/configui")
local reticule = require("libs/reticule")
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local input = require('libs/input')
local pawnModule = require('libs/pawn')
local montage = require('libs/montage')
local interaction = require('libs/interaction')
local ui = require('libs/ui')
local remap = require('libs/remap')
local gestures = require('libs/gestures')
local ik = require('libs/ik')
local animation = require('libs/animation')
local collision = require('libs/collision')
local plugin = require('libs/core/plugin')
local mouse = require('libs/mouse')
local grip = require('libs/grip')
local prompts = require('libs/prompts')
local mechanisms = require('libs/mechanisms')
local GRIP_PRIORITY = require('helpers/grip_priority')


require("helpers/melee")
require("helpers/ik_materials")
local interactions = require("helpers/interactions")

uevrUtils.setLogLevel(LogLevel.Debug)
-- reticule.setLogLevel(LogLevel.Debug)
-- input.setLogLevel(LogLevel.Debug)
-- attachments.setLogLevel(LogLevel.Debug)
-- animation.setLogLevel(LogLevel.Debug)
-- ui.setLogLevel(LogLevel.Debug)
-- remap.setLogLevel(LogLevel.Debug)
-- hands.setLogLevel(LogLevel.Debug)
-- widgetModule.setLogLevel(LogLevel.Debug)
-- ik.setLogLevel(LogLevel.Debug)

uevrUtils.setDeveloperMode(true)
hands.enableConfigurationTool()
uevrUtils.profiler:toggle(true)
register_key_bind("F1", function()
    uevrUtils.profiler:report("alpha")
end)

ui.init()
montage.init()
interaction.init()
attachments.init()
attachments.setLaserColor("#00FF00FF")
reticule.init()
reticule.setHiddenWhenScopeActive(true)
pawnModule.init()
remap.init()
input.init()
gestures.init()
collision.init()
-- After helpers/interactions has made its mechanisms: loads their profiles and, in developer mode, the Mechanisms Dev Config.
mechanisms.init()

uevrUtils.set_2D_mode(false)

hands.setAutoCreateHands(false)
ik.setAutoCreateArms(false)

uevrUtils.set_roomscale_active(true)
-- Right-eye Lumen fix. With UEVR Native Stereo Fix on, the right eye's Lumen lighting goes stale after
-- streamed levels load or unload (missing bounce light indoors, missing soft shadowing outdoors).
uevrUtils.enableDistanceFieldStereoFix(true)


local versionTxt = "v1.0.0"
local title = "Silent Hill f First Person Mod " .. versionTxt
local configDefinition = {
	{
		panelLabel = "Silent Hill f Config",
		saveFile = "silent_hill_f_config",
		layout = spliceableInlineArray
		{
			{ widgetType = "text", id = "title", label = title },
			{ widgetType = "indent", width = 20 }, { widgetType = "text", label = "General" }, { widgetType = "begin_rect", },
				{
					widgetType = "checkbox",
					id = "toggle_lumen",
					label = "Toggle Lumen",
					initialValue = false,
				},
				{
						widgetType = "combo",
                    id = "hands_type",
                    label = "Hands Type",
                    selections = {"Forearms", "IK Arms"},
                    initialValue = 1,
                },
				{
					widgetType = "checkbox",
					id = "use_controller_mouse",
					label = "Controller Based Mouse Movement in Menus",
					initialValue = true
				},
                {
                    widgetType = "checkbox",
                    id = "weighted_weapons",
                    label = "Weighted Weapons",
                    initialValue = true,
                },
                {
                    widgetType = "checkbox",
                    id = "attachment_lasers",
                    label = "Gun Lasers",
                    initialValue = true,
                },
                { widgetType = "indent", width = 20 },
                {
                    widgetType = "checkbox",
                    id = "attachment_emmissive_lasers",
                    label = "Emissive",
                    initialValue = true,
                },
				{ widgetType = "unindent", width = 20 },
                {
                    widgetType = "checkbox",
                    id = "left_arm_block_dodge",
                    label = "Left Arm Block/Dodge",
                    initialValue = true,
                },
                { widgetType = "indent", width = 20 },
                {
                    widgetType = "text",
                    id = "left_arm_block_dodge_info",
                    wrapped = true,
                    label = "Raise your left arm in front of your face with palm out to block or dodge",
                },
                { widgetType = "unindent", width = 20 },
                {
                    widgetType = "checkbox",
                    id = "physics_portables",
                    label = "Physics Based Portables",
                    initialValue = true,
                },
                {
                    widgetType = "checkbox",
                    id = "physical_item_grab",
                    label = "Physical Item Grab",
                    initialValue = true,
                },
                {
                    widgetType = "checkbox",
                    id = "grip_interact",
                    label = "Left Grip For Interaction Prompts",
                    initialValue = true,
                },
				{
					widgetType = "combo",
					id = "interaction_control_mode",
					label = "Interaction Controls",
					selections = {"Vanilla", "Vanilla+", "Mixed", "Full Immersion"},
					initialValue = 1,
					width = 200,
				},
				{ widgetType = "indent", width = 20 }, { widgetType = "text", label = "How to use" }, { widgetType = "begin_rect", },
                { widgetType = "indent", width = 10 },

				{ widgetType = "text", wrapped = true, label = "Melee: Swing your right controller while holding melee weapon", },
				{ widgetType = "text", wrapped = true, label = "Heavy Attack: Hold Right Trigger while swinging", },
				{ widgetType = "text", wrapped = true, label = "Focus Attack: Hold Left Trigger to charge Focus, then press RB when charged", },
				{ widgetType = "text", wrapped = true, label = "Counterattack: Press Right Trigger during the enemy's red counterattack cue", },
				{ widgetType = "text", wrapped = true, label = "Physical Item Grab: Grip with an empty hand while a food or drink item shows its pickup prompt. Release next to your ear to take it, release elsewhere to drop or throw it", },
				{ widgetType = "text", wrapped = true, label = "Interact: Left Grip while an interaction prompt shows LB", },

				{ widgetType = "begin_group", id = "interaction_info_vanilla_plus_group", isHidden = true },
					{ widgetType = "text", wrapped = true, label = "Jump: Right Stick forward", },
					{ widgetType = "text", wrapped = true, label = "Block/Dodge: Right Stick backward", },
				{ widgetType = "end_group", },

				{ widgetType = "begin_group", id = "interaction_info_mixed_group", isHidden = true },
					{ widgetType = "text", wrapped = true, label = "Inventory: Left Grip near ear", },
					{ widgetType = "text", wrapped = true, label = "Heal: Left Grip near mouth", },
					{ widgetType = "text", wrapped = true, label = "Rage: Left Trigger near eyes", },
				{ widgetType = "end_group", },

				{ widgetType = "begin_group", id = "interaction_info_full_group", isHidden = true },
					{ widgetType = "text", wrapped = true, label = "Inventory: Left Grip near ear", },
					{ widgetType = "text", wrapped = true, label = "Heal: Left Grip near mouth (no DPAD Down)", },
					{ widgetType = "text", wrapped = true, label = "Rage: Left Trigger near eyes (no L3+R3)", },
				{ widgetType = "end_group", },

                { widgetType = "unindent", width = 10 },
            	{ widgetType = "end_rect", additionalSize = 12, rounding = 5 }, { widgetType = "unindent", width = 20 },
				{ widgetType = "new_line" },
				expandArray(gestures.getConfigurationWidgets, {
					select = {
						{ id = "uevr_gesture_config_swipe_minThresholdSpeed", label = "Swing Effort Required", range = {100, 1000} },
					},
				}),
                {
                    widgetType = "combo",
                    id = "flashlight_location",
                    label = "Flashlight Location",
                    selections = {"Head", "Left Hand", "Right Hand"},
                    initialValue = 1,
                },
                { widgetType = "indent", width = 20 },
                {
                    widgetType = "drag_float3",
                    id = "flashlight_head_position",
                    label = "Flashlight Position",
                    speed = 0.1,
                    range = {-100, 100},
                    initialValue = {0, 0, 0},
                },
                {
                    widgetType = "drag_float3",
                    id = "flashlight_head_rotation",
                    label = "Flashlight Rotation",
                    speed = 0.5,
                    range = {-180, 180},
                    initialValue = {0, 0, 0},
                },
                {
                    widgetType = "drag_float3",
                    id = "flashlight_left_position",
                    label = "Flashlight Position",
                    speed = 0.1,
                    range = {-100, 100},
                    initialValue = {0, 0, 0},
                    isHidden = true,
                },
                {
                    widgetType = "drag_float3",
                    id = "flashlight_left_rotation",
                    label = "Flashlight Rotation",
                    speed = 0.5,
                    range = {-180, 180},
                    initialValue = {0, 0, 0},
                    isHidden = true,
                },
                {
                    widgetType = "drag_float3",
                    id = "flashlight_right_position",
                    label = "Flashlight Position",
                    speed = 0.1,
                    range = {-100, 100},
                    initialValue = {0, 0, 0},
                    isHidden = true,
                },
                {
                    widgetType = "drag_float3",
                    id = "flashlight_right_rotation",
                    label = "Flashlight Rotation",
                    speed = 0.5,
                    range = {-180, 180},
                    initialValue = {0, 0, 0},
                    isHidden = true,
                },
				{ widgetType = "unindent", width = 20 },
			{ widgetType = "end_rect", additionalSize = 12, rounding = 5 }, { widgetType = "unindent", width = 20 },
			{ widgetType = "new_line" },
			{ widgetType = "indent", width = 20 }, { widgetType = "text", label = "UI" }, { widgetType = "begin_rect", },
				expandArray(ui.getConfigurationWidgets),
			{ widgetType = "end_rect", additionalSize = 12, rounding = 5 }, { widgetType = "unindent", width = 20 },
			{ widgetType = "new_line" },
			{ widgetType = "indent", width = 20 }, { widgetType = "text", label = "Input" }, { widgetType = "begin_rect", },
				expandArray(input.getConfigurationWidgets),
			{ widgetType = "end_rect", additionalSize = 12, rounding = 5 }, { widgetType = "unindent", width = 20 },
			{ widgetType = "new_line" },
			{ widgetType = "indent", width = 20 }, { widgetType = "text", label = "Reticule" }, { widgetType = "begin_rect", },
				expandArray(reticule.getConfigurationWidgets,{{id="uevr_reticule_update_distance", initialValue=200},}),
			{ widgetType = "end_rect", additionalSize = 12, rounding = 5 }, { widgetType = "unindent", width = 20 },
			{ widgetType = "new_line" },
		}
	}
}

local status = {}

-- local function toggleLumen()
-- 	uevrUtils.set_cvar_int("r.Lumen.DiffuseIndirect.Allow", 0)
-- 	delay(50, function()
-- 		uevrUtils.set_cvar_int("r.Lumen.DiffuseIndirect.Allow", 1)
-- 	end)
-- end


local function updateBodyVisibility()
    local isVisible = uevrUtils.isInCutscene() or status.isGimmickInput == true
    if pawn.HeadComponent ~= nil then pawn.HeadComponent:SetRenderInMainPass(isVisible) end
    if pawn.HairComponent ~= nil then pawn.HairComponent:SetRenderInMainPass(isVisible) end
end

local HandsType = {
	Forearms = 1,
	IKArms = 2,
}
local function regenerateHands(value)
	--detach attachments first so they dont get "lost" when hands are destroyed
	attachments.detachGripAttachments(Handed.Right)
	attachments.detachGripAttachments(Handed.Left)

    hands.setAutoCreateHands(value == HandsType.Forearms)
    ik.setAutoCreateArms(value == HandsType.IKArms)

    hands.destroyHands()
    ik.destroyAll()
end

local function getHandComponents()
    local rightHandComponent = nil
   	local leftHandComponent = nil
	local handsType = configui.getValue("hands_type")
    if handsType == HandsType.None then
        rightHandComponent = controllers.getController(Handed.Right)
        leftHandComponent = controllers.getController(Handed.Left)
    elseif handsType == HandsType.Forearms then
        rightHandComponent = hands.getHandComponent(Handed.Right)
        leftHandComponent = hands.getHandComponent(Handed.Left)
    elseif handsType == HandsType.IKArms then
        rightHandComponent = ik.getCurrentMesh()
		leftHandComponent = ik.getCurrentMesh()
    end

    return rightHandComponent, leftHandComponent
end

local function getWeaponMesh()
    if status.isOnLadder or uevrUtils.isInCutscene() or uevrUtils.isGamePaused() then return nil end

    local weaponMesh = uevrUtils.getValid(pawn, {"CurrentWeapon", "WeaponMesh"})
    if weaponMesh ~= nil then weaponMesh:SetVisibility(true, false) end
    return weaponMesh
end

local defaultAttachOptions = {
	detachFromOriginOnGrip = true,
	maintainWorldPositionOnDetachFromOrigin = false,
	detachFromParentOnRelease = true,
	maintainWorldPositionOnDetachFromParent = false,
	reattachToOriginOnRelease = true,
	restoreTransformToOriginOnReattach = true,
	useZeroTransformOnReattach = false,
	allowChildVisibilityHandling = false,
	allowChildHiddenInGameHandling = false,
	allowRenderInMainPassHandling = false,
}
attachments.registerOnGripUpdateCallback(function()

    local weaponMesh = getWeaponMesh()
    -- The fox arm's weapon mesh is empty (helpers/interactions): while the right hand has a grabbed item, the item takes the hand,
    -- and the fox arm comes back (with its melee) once the item is released. A visible weapon keeps the hand, dropping the item.
    if interactions.getHeldItemMesh(Handed.Right) ~= nil and interactions.isEmptyWeaponMesh(weaponMesh) then weaponMesh = nil end
	local rightHandComponent, leftHandComponent = getHandComponents()
    -- The claw forms drive their own right-arm bone chain, so the hand socket follows the form (see ArmForm).
    local rightSocketName = status.armForm and status.armForm.rightSocket or "weapon_r"
    --print(weaponMesh, rightHandComponent, rightSocketName)
    -- Held items (helpers/interactions) are attached by libs/grabbable's own grip callback, below this one, on these hand meshes
    -- and sockets; a weapon drawn into a hand holding one takes the hand, and the item is dropped. The left hand only holds items.
    return rightHandComponent and weaponMesh, rightHandComponent, rightSocketName, nil, leftHandComponent, "weapon_l", defaultAttachOptions --, controllers.getController(Handed.Right)

end)

------------------- Step-up suppression at walls -------------------
-- Pushing into an obstacle makes the engine try its automatic step-up on every frame. Each
-- failed try leaves the capsule up to a few units below its standing height and the next
-- stopped frame lifts it back, so the VR camera, which rides the capsule, bobs. Measured in
-- game on 2026-11-16: the bob also happens with the mod's input handling off, and it stopped
-- with MaxStepHeight at 0. So while the stick is pushed but the pawn is not moving, step-up is
-- off, with one try every STEP_RETRY_INTERVAL seconds so a stair met from a standstill still climbs.
-- Set to false to turn this fix off.
local suppressStepUpAtWalls = true
local BLOCKED_SPEED = 50        -- below this while pushing, step-up turns off
local FREE_SPEED = 100          -- above this, step-up turns back on
local STEP_RETRY_INTERVAL = 0.5 -- seconds between single-frame step-up tries while blocked
local MOVE_WALKING = 1

local function restoreStepUp()
	local stepUp = status.stepUp
	status.stepUp = nil
	if stepUp == nil or not stepUp.suppressed then return end
	local cmc = uevrUtils.getValid(stepUp.cmc)
	if cmc ~= nil then cmc.MaxStepHeight = stepUp.original end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local cmc = uevrUtils.getValid(pawn, {"CharacterMovement"})

	local stepUp = status.stepUp
	if stepUp ~= nil and (cmc == nil or stepUp.address ~= cmc:get_address()) then
		restoreStepUp()
		stepUp = nil
	end
	if cmc == nil or not suppressStepUpAtWalls then
		restoreStepUp()
		return
	end
	if stepUp == nil then
		-- A script reset while suppressed leaves 0 behind, so fall back to the class default
		local original = cmc.MaxStepHeight
		if original == nil or original <= 0 then
			local cdo = cmc:get_class():get_class_default_object()
			local default = cdo ~= nil and cdo.MaxStepHeight or nil
			if default == nil or default <= 0 then return end
			original = default
			cmc.MaxStepHeight = default
		end
		stepUp = {cmc = cmc, address = cmc:get_address(), original = original, suppressed = false, blockedTime = 0}
		status.stepUp = stepUp
	end

	local accel = cmc:GetCurrentAcceleration()
	local velocity = cmc.Velocity
	local pushing = accel ~= nil and velocity ~= nil and cmc.MovementMode == MOVE_WALKING and accel.X * accel.X + accel.Y * accel.Y > 1
	local speedSq = pushing and velocity.X * velocity.X + velocity.Y * velocity.Y or 0
	local limit = stepUp.suppressed and FREE_SPEED or BLOCKED_SPEED
	local suppress = pushing and speedSq < limit * limit
	if suppress then
		stepUp.blockedTime = stepUp.blockedTime + (delta or 0)
		if stepUp.blockedTime >= STEP_RETRY_INTERVAL then
			stepUp.blockedTime = 0
			suppress = false
		end
	else
		stepUp.blockedTime = 0
	end
	if suppress ~= stepUp.suppressed then
		stepUp.suppressed = suppress
		cmc.MaxStepHeight = suppress and 0 or stepUp.original
	end
end)
------------------- End step-up suppression at walls -------------------

local function cleanup()
    restoreStepUp()
    status = {}
end

-- Manual saves are slots 1..GameSlotCount; autosaves start at 100. Cap at 99 to avoid overlap.
local function ensureSaveSlotLimit()
	local save = uevrUtils.find_first_of("Class /Script/GameNoce.NoceSaveSubsystem", false)
	if save ~= nil then
		plugin.setProperty(save, "CacheStorageSetting.GameSlotCount", 99)
	end
end
ensureSaveSlotLimit()

on_level_change = function(level, levelName)
	print("on_level_change ", level, levelName)
    cleanup()
    regenerateHands(configui.getValue("hands_type") or 1)
	ensureSaveSlotLimit()
	--toggleLumen()
end

-- Accept an inventory ID so each gesture can request its own consumable.
local function consumeItem(itemID)
	if type(itemID) ~= "string" or itemID == "" or itemID == "None" then return end
	if uevrUtils.isGamePaused() or uevrUtils.isInCutscene() or ui.isInputDisabled() then return end
	local playerState = uevrUtils.getValid(uevrUtils.get_player_controller(), {"PlayerState"})
	local inv = uevrUtils.getValid(playerState, {"InventoryComponent"})
	local abilitySystem = uevrUtils.getValid(playerState, {"AbilitySystemComponent"})
	local player = uevrUtils.getValid(pawn)
	if inv == nil or abilitySystem == nil or player == nil then return end
	if player:GetIsInEvent() or player:DuringUseShortcutItemMotion() then return end

	local abilityClass = uevrUtils.get_class("BlueprintGeneratedClass /Game/Character/Player/Base/GameplayAbility/Ability/GA_UseShortcutItem.GA_UseShortcutItem_C")
	if abilityClass == nil then return end
	local itemIDs = plugin.getProperty(inv, "AllConsumableIDs")
	local idIndex
	for i, id in ipairs(itemIDs or {}) do
		if id == itemID then
			idIndex = i - 1 -- Lua list is 1-based; the inventory ID index is 0-based.
			break
		end
	end
	if idIndex == nil or inv:GetConsumableTotalNum(idIndex) <= 0 then return end

	-- UseConsumable alone only removes inventory. The ability applies the item's
	-- effects and consumes it at the normal animation notify, without opening UI.
	-- Set the ability's requested ID directly; TryToUseConsumableItem takes a
	-- wheel slot, which would make gestures depend on the wheel configuration.
	local previousID = plugin.getProperty(inv, "LastUseConsumableID")
	plugin.setProperty(inv, "LastUseConsumableID", itemID)
	if plugin.getProperty(inv, "LastUseConsumableID") ~= itemID then return end
	if not abilitySystem:TryActivateAbilityByClass(abilityClass, false) then
		plugin.setProperty(inv, "LastUseConsumableID", previousID or "None")
	end
end

------------------- Soul Siphon prompt (A → RB) -------------------
-- The claw Attract Soul hint shows Interact (A). Show RB instead, and make physical RB press A
-- while the hint is up or the siphon is in progress (melee otherwise eats RB).
-- Always pass the claw hint's button to prompts so it can restore when Soul Siphon is not active;
-- only replace while HaveAttrackSoulTarget / siphon state (IsVisible alone stays true too often).
local SOUL_SIPHON_A_ICON = "PaperSprite /Game/UI/Base/Input/Platform/_XB1/UT_InputGuide_XB1_0.UT_InputGuide_XB1_0"
-- LightAttack's console icon (right bumper). TransformRB's icon is R3 (XB1_29), not RB.
local SOUL_SIPHON_RB_ICON = "PaperSprite /Game/UI/Base/Input/Platform/_XB1/UT_InputGuide_XB1_33.UT_InputGuide_XB1_33"

local function isSoulSiphonPromptActive()
	local p = uevrUtils.getValid(pawn)
	if p == nil then return false end
	if p.IsClawAttrackSoulState ~= nil and p:IsClawAttrackSoulState() then return true end
	local claw = uevrUtils.getValid(p, {"NocePlayerClawTransform"})
	return claw ~= nil and claw:HaveAttrackSoulTarget()
end

local function getSoulSiphonPromptImages()
	local image = uevrUtils.getValid(pawn, {"NocePlayerClawTransform", "ClawAttrackSoulHintWidget", "PromptButtonIcon"})
	return image ~= nil and {image} or nil
end

local function getSoulSiphonPromptReplacement(_, original)
	if not isSoulSiphonPromptActive() then return nil end
	local aIcon = prompts.loadAsset(SOUL_SIPHON_A_ICON)
	if aIcon == nil or original == nil or original:get_address() ~= aIcon:get_address() then return nil end
	return prompts.loadAsset(SOUL_SIPHON_RB_ICON)
end

local getSoulSiphonPromptIcon, setSoulSiphonPromptIcon = prompts.brushResource()
prompts.new({
	interval = 250,
	getPrompts = getSoulSiphonPromptImages,
	get = getSoulSiphonPromptIcon,
	set = setSoulSiphonPromptIcon,
	getReplacement = getSoulSiphonPromptReplacement,
	enabled = true,
})
------------------- End Soul Siphon prompt -------------------

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
	local gripMouthLeft, gripEyesLeft, gripHeadLeft, gripEarLeft, triggerMouthLeft, triggerEyesLeft, triggerHeadLeft, triggerEarLeft = gestures.getHeadGestures(state, Handed.Left, true)
	if triggerEarLeft then 
		uevrUtils.pressButton(state, XINPUT_GAMEPAD_BACK)
		state.Gamepad.bLeftTrigger = 0
	end
	-- A press owned by Physical Item Grab (helpers/interactions) is left as it is: grabbable reads the grip after this callback and
	-- grip.lua hides it from the game, so carrying an item past the ear or mouth must not open the inventory or heal.
	-- The same goes for a press Grip Interact owns (it is holding A for the game's prompt).
	local isItemGrabPress = grip.isOwner(Handed.Left, interactions.GRIP_OWNERS[Handed.Left]) or grip.isOwner(Handed.Left, interactions.GRIP_INTERACT_OWNER)
	if gripEarLeft and not isItemGrabPress then 
        uevrUtils.pressButton(state, XINPUT_GAMEPAD_START)
        uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
     end

	local gripPressed = uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
	if not gripPressed then
		status.healGestureLatched = false
	elseif gripMouthLeft and not status.healGestureLatched and not isItemGrabPress then
		status.healGestureLatched = true
		-- Execute UObject calls on the game thread, outside the XInput callback.
		status.consumeItemRequested = "Capsule"
	end
	if status.healGestureLatched then
		-- Keep the wheel closed until release, including when lowering the hand.
		uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
	end

	if not uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_RIGHT_SHOULDER) then
		status.holsterGripLatched = false
	end
	local isHolstering = gestures.detectGestureWithState(gestures.Gesture.HOLSTER, state, Handed.Right, false)
	if isHolstering then
		status.holsterToggleRequested = true
		-- The right grip is the game's light attack (RB): keep this press from the game until release, or drawing a weapon
		-- with it still held triggers a vanilla attack. Hidden in the post-input callback so the mod's own grip readers see it.
		status.holsterGripLatched = true
	end

	-- Right grip at the right ear: DPAD right, with the grip itself kept from the game (as the left ear does). Not for a press
	-- Physical Item Grab owns: an item carried to that ear is being taken.
	local _, _, _, gripEarRight = gestures.getHeadGestures(state, Handed.Right, true)
	if gripEarRight and not grip.isOwner(Handed.Right, interactions.GRIP_OWNERS[Handed.Right]) then
		uevrUtils.pressButton(state, XINPUT_GAMEPAD_DPAD_RIGHT)
		uevrUtils.unpressButton(state, XINPUT_GAMEPAD_RIGHT_SHOULDER)
		uevrUtils.triggerHapticVibration(uevrUtils.getHandedness(), 0, 0.05, 1000, 0.3)
	elseif isSoulSiphonPromptActive() and uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_RIGHT_SHOULDER) then
		uevrUtils.pressButton(state, XINPUT_GAMEPAD_A)
		uevrUtils.unpressButton(state, XINPUT_GAMEPAD_RIGHT_SHOULDER)
	end

end, 10)

uevrUtils.registerOnPostInputGetStateCallback(function(retval, user_index, state)
	if status.holsterGripLatched then
		uevrUtils.unpressButton(state, XINPUT_GAMEPAD_RIGHT_SHOULDER)
	end
end)

-- Grip arbitration (libs/grip): a left grip that starts at the ear (inventory) or at the mouth (heal), or a right grip that starts
-- at the ear (DPAD right), belongs to that gesture, so Physical Item Grab doesn't grab the item the prompt is on; an item already
-- in the hand keeps the grip (see helpers/grip_priority). The game still sees these presses as before.
grip.registerClaim("head_gesture", function(hand, state)
	local gripMouth, _, _, gripEar = gestures.getHeadGestures(state, hand, true)
	if gripEar or (hand == Handed.Left and gripMouth) then return GRIP_PRIORITY.HEAD_GESTURE end
	return nil
end, {hide = grip.Hide.None})

-- ENoceInteractType
local InteractType = {
	None                 = 0,
	Vault                = 1, -- Valut in dump
	ClimbWall_Up         = 2,
	ClimbWall_Down       = 3,
	ClimbLowWall_Up      = 4,
	ClimbLowWall_Down    = 5,
	NarrowMoveShort_FaceR = 6,
	NarrowMoveShort_FaceL = 7,
	NarrowMove_FaceR     = 8,
	NarrowMove_FaceL     = 9,
	Ladder               = 10,
	CrawlMoveShort       = 11,
	OpenShoji            = 12,
	RingBell             = 13,
	PushPlank            = 14,
	PullUpWellBucket     = 15,
	SpinTheWheel         = 16,
	Telephone            = 17,
	KatanaAlter          = 18,
	BadgeOffer           = 19,
}

local InteractTypeName = {
	[0] = "None",
	[1] = "Vault",
	[2] = "ClimbWall_Up",
	[3] = "ClimbWall_Down",
	[4] = "ClimbLowWall_Up",
	[5] = "ClimbLowWall_Down",
	[6] = "NarrowMoveShort_FaceR",
	[7] = "NarrowMoveShort_FaceL",
	[8] = "NarrowMove_FaceR",
	[9] = "NarrowMove_FaceL",
	[10] = "Ladder",
	[11] = "CrawlMoveShort",
	[12] = "OpenShoji",
	[13] = "RingBell",
	[14] = "PushPlank",
	[15] = "PullUpWellBucket",
	[16] = "SpinTheWheel",
	[17] = "Telephone",
	[18] = "KatanaAlter",
	[19] = "BadgeOffer",
}

-- returns interacting, type (InteractType.*), name
local function getInteraction(pawn)
	pawn = pawn or uevrUtils.getValid(pawn) or uevr.api:get_local_pawn(0)
	if pawn == nil or pawn.IsInteracting == nil or not pawn:IsInteracting() then
		return false, InteractType.None, InteractTypeName[0]
	end
	-- CacheInteractType sticks after exit; only trust while IsInteracting.
	local t = pawn.GetCacheInteractionType and pawn:GetCacheInteractionType() or InteractType.None
	if type(t) == "table" and t.value ~= nil then
		t = t.value
	end
	return true, t, InteractTypeName[t] or tostring(t)
end

local NarrowMove = {
	Short_FaceR = InteractType.NarrowMoveShort_FaceR,
	Short_FaceL = InteractType.NarrowMoveShort_FaceL,
	FaceR       = InteractType.NarrowMove_FaceR,
	FaceL       = InteractType.NarrowMove_FaceL,
}

local function getNarrowMoveType(pawn)
	local interacting, t = getInteraction(pawn)
	if not interacting then
		return nil
	end
	return t
end

-- returns isNarrow, face ("L" | "R" | nil)
local function isNarrowMove(pawn)
	local t = getNarrowMoveType(pawn)
	if t == NarrowMove.Short_FaceR or t == NarrowMove.FaceR then
		return true, "R"
	elseif t == NarrowMove.Short_FaceL or t == NarrowMove.FaceL then
		return true, "L"
	end
	return false, nil
end

-- The claw pawn's body mesh has separate right-arm bone chains for the fox arm ("_small_r") and the
-- large claw ("_large_r"). Each form has its own IK profile, Forearms profile and right-hand socket.
-- There is no large-claw Forearms profile yet, so that form uses "Fox Arm".
local ArmForm = {
	Default   = { pawnProfile = "Default", ikProfile = "Default",       handsProfile = "Main",    rightSocket = "weapon_r",       inputProfile = "Default" },
	Claw      = { pawnProfile = "Fox Arm", ikProfile = "Fox Arm",       handsProfile = "Fox Arm", rightSocket = "weapon_small_r", inputProfile = "Fox" },
	ClawLarge = { pawnProfile = "Fox Arm Large", ikProfile = "Fox Arm Large", handsProfile = "Fox Arm Large", rightSocket = "weapon_large_r", inputProfile = "Fox" },
}

-- returns an ArmForm entry, or nil while there is no valid pawn
local function getArmForm(pawn)
	pawn = uevrUtils.getValid(pawn)
	if pawn == nil then return nil end
	if pawn.IsClawG ~= nil and pawn:IsClawG() then return ArmForm.ClawLarge end
	if pawn.IsClaw ~= nil and pawn:IsClaw() then return ArmForm.Claw end
	return ArmForm.Default
end

-- true  = flee also requires CameraMode.FaceTarget (clean exit; ForceBattling sticks otherwise)
-- false = flee is ForceBattling alone (no camera tag call)
local checkCameraFaceTarget = true

-- Ch01 Shiro chase: IsRunTo (opening run) OR ForceBattling flee → cutscene override, not FP.
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, deltaTime)
	if status.consumeItemRequested then
		local itemID = status.consumeItemRequested
		status.consumeItemRequested = nil
		consumeItem(itemID)
	end
	if status.holsterToggleRequested then
		status.holsterToggleRequested = nil
		-- Holster gesture toggles: put away the weapon in hand (or being switched to), otherwise draw the last used one.
		local inv = uevrUtils.getValid(uevrUtils.get_player_controller(), {"PlayerState", "InventoryComponent"})
		if inv ~= nil then
			if inv:GetEquippedOrTargetWeaponIndex() >= 0 then
				inv:UnEquipCurrentWeapon()
				uevrUtils.triggerHapticVibration(uevrUtils.getHandedness(), 0, 0.05, 1000, 0.3)
			elseif inv:HasAnyWeapon() then
				inv:TryEquipLastUsedWeapon()
				uevrUtils.triggerHapticVibration(uevrUtils.getHandedness(), 0, 0.05, 1000, 0.3)
				-- Attach the drawn weapon now instead of leaving it off the hand until the grip-update timer.
				attachments.forceGripUpdate()
			end
		end
	end
	-- PlaySequenceState / CS_Seamless (post-fence flee, etc.)
	local inEvent = pawn ~= nil and pawn.GetIsInEvent ~= nil and pawn:GetIsInEvent()
	if status.isInEvent ~= inEvent then
		status.isInEvent = inEvent
		if inEvent then
			uevrUtils.setIsInCutsceneOverride(true)
			ui.forceUpdate()
		elseif not status.isForced then
			delay(1000, function()
				if not status.isForced and not status.isInEvent then
					uevrUtils.setIsInCutsceneOverride(nil)
				end
			end)
		end
	end

	if pawn ~= nil then
		local walkTo = pawn.NoceWalkToComponent
		-- Opening: IsRunTo. Flee: ForceBattling, optionally gated by FaceTarget.
		local isForced = walkTo ~= nil and walkTo.IsRunTo
		if not isForced and pawn.ForceBattling == true then
			if checkCameraFaceTarget then
				local cam = pawn.ATPCCamera
				local camTag = cam ~= nil and cam.GetCurrentCameraModeTag ~= nil and cam:GetCurrentCameraModeTag()
				isForced = uevrUtils.stringFromTag(camTag) == "CameraMode.FaceTarget"
			else
				isForced = true
			end
		end
		if status.isForced ~= isForced then
			status.isForced = isForced
			if isForced then
				uevrUtils.setIsInCutsceneOverride(true)
			elseif not status.isInEvent then
				uevrUtils.setIsInCutsceneOverride(nil)
			end
		end
		if isForced and pawn.RecordCachedSprintInput ~= nil then
			pawn:RecordCachedSprintInput()
		end

        updateBodyVisibility()
	end
end)

setInterval(1000, function()
	local isNarrow, face = isNarrowMove(pawn)
	local armForm = getArmForm(pawn)
	-- Narrow movement keeps its sideways profiles; otherwise the arm form picks the profile (both claws use "Fox").
	-- Without a valid pawn the current profile stays. Only switch on change: each switch resets the height source.
	local inputProfile = status.isOnLadder and "Ladder" or isNarrow and (face == "R" and "NarrowMoveR" or "NarrowMoveL") or (armForm and armForm.inputProfile)
	if inputProfile ~= nil and status.inputProfile ~= inputProfile then
		status.inputProfile = inputProfile
		input.setCurrentProfileByLabel(inputProfile, {transitionTime = 0.3})
	end
	if armForm ~= nil and status.armForm ~= armForm then
		status.armForm = armForm
		ik.setCurrentProfileByLabel(armForm.ikProfile)
		hands.setAutoCreateProfile(armForm.handsProfile, "Shared")
		pawnModule.setCurrentProfileByLabel(armForm.pawnProfile)
		-- Arms keep the bones of the profile they were created with, so rebuild them for the new form.
		regenerateHands(configui.getValue("hands_type") or 1)
	end

    -- local interacting, interactionType = getInteraction(pawn)
    -- if status.interactionType ~= interactionType then
    --     status.interactionType = interactionType
    --     pawnModule.hideArmsBones(not interacting)
    -- end
end)


local unlimitedAwaken = false

uevr.sdk.callbacks.on_pre_engine_tick(function()
    -- Invincibility through the game's own component.
	local invincible = uevrUtils.getValid(pawn, {"NoceInvincible"})
	local token = uevrUtils.fname_from_string("UEVR_Invincible")
	if invincible ~= nil and not invincible:IsTokenInvincible(token) then
		invincible:StartInvincible(token)
	end

	-- Keep Kudzu Seal / Awaken (ClawTransform) full so the mode never runs out.
	if unlimitedAwaken then
		local claw = uevrUtils.getValid(pawn, {"NocePlayerClawTransform"})
		if claw ~= nil and not claw:IsClawTransformFull() then
			claw:FillClawTransformToFull()
		end
	end
end)

-- A sprint turns the body toward the stick, but the yaw lock below stops the body turning, so
-- stick-back mid-sprint retries the turn-around forever. While the sprint is still in a moving
-- anim state the stick is held neutral; once it winds down (JogEnd) stick-back is a plain backpedal.
local holdStickForSprintStop = false

--replace input config Player Controller Overrides with this for Pitch Yaw and Roll
-- "Default", "Fixed", "Pawn", "HMD"
uevr.sdk.callbacks.on_pre_engine_tick(function()
    holdStickForSprintStop = false
    if pawn == nil then return end
    if ui.isInputDisabled() or uevrUtils.isInCutscene() then return end

    if pawn.IsInRunning ~= nil and pawn:IsInRunning() then
        local anim = uevrUtils.getValid(pawn, {"PlayerAnimInstance"})
        local stateName = anim ~= nil and anim.ActiveStateName or nil
        if stateName ~= nil then
            local name = stateName:to_string():gsub("%z", "")
            holdStickForSprintStop = name == "JogStart" or name == "Sprint"
        end
    end

    local pc = uevr.api:get_player_controller(0)
    local head = controllers.getControllerRotation(2)
    if pc == nil or head == nil then return end

	local interacting, interactType = getInteraction(pawn)
	status.isOnLadder = interacting and interactType == InteractType.Ladder
	-- On a ladder the weapon is back in the pawn's own hand, which climbs (the Ladder mechanism's Animate Steps), so it is hidden
	-- on every tick there. getWeaponMesh shows it again once the player is off the ladder.
	if status.wasOnLadder ~= status.isOnLadder then
		local weaponMesh = uevrUtils.getValid(pawn, {"CurrentWeapon", "WeaponMesh"})
		if weaponMesh ~= nil then weaponMesh:SetHiddenInGame(status.isOnLadder, false) end
		collision.disableCollisionByLabel("Left Ladder", not status.isOnLadder)
		collision.disableCollisionByLabel("Right Ladder", not status.isOnLadder)
		status.wasOnLadder = status.isOnLadder
	end

    local rotation = pc:GetControlRotation()
    -- On a ladder the game's camera hangs on an arm behind the player (measured 2026-11-17: 140 cm behind and 44 cm below at
    -- +20 pitch; the game clamps the pitch to +20/-33 there) and swings around the head with the control pitch, so the view rose
    -- a step when the head tilted down and sank when it tilted up. There the pitch is held level.
    rotation.Pitch = status.isOnLadder and 0 or head.Pitch
    rotation.Yaw = pawn:K2_GetActorRotation().Yaw
    pc:SetControlRotation(rotation)
end)

uevrUtils.registerOnPostInputGetStateCallback(function(retval, user_index, state)
    if ui.isInputDisabled() or uevrUtils.isInCutscene() then return end

    -- After remapping, so stick-down still produces B.
    state.Gamepad.sThumbRY = 0
    -- On a ladder the game's look input turns the pawn (it follows the control yaw), so the game gets no right-stick X there.
    if status.isOnLadder then state.Gamepad.sThumbRX = 0 end

    if state.Gamepad.sThumbLY < -8000 then
        -- Stick back: drop L3 so a sprint (and its spin toward the stick) cannot start.
        uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_THUMB)
        -- Stick pulled back during a sprint: deliver neutral so the game ends the sprint first.
        if holdStickForSprintStop then
            state.Gamepad.sThumbLX = 0
            state.Gamepad.sThumbLY = 0
        end
    end
end)

configui.onUpdate("hands_type", function(value)
    regenerateHands(value)
end)

configui.onCreateOrUpdate("use_controller_mouse", function(value)
	mouse.setOverrideEnable(value)
end)

configui.onCreateOrUpdate("physical_item_grab", function(value)
	interactions.setItemGrabEnabled(value)
end)

configui.onCreateOrUpdate("grip_interact", function(value)
	interactions.setGripInteractEnabled(value)
end)

ui.registerWidgetChangeCallback("WBP_SavePoint_C", function(active, widget)
	regenerateHands(configui.getValue("hands_type") or 1)
    pawnModule.hideArmsBones(true)
end)

ui.registerWidgetChangeCallback("WBP_GimmickInput_C", function(active, widget)
	status.isGimmickInput = active
end)

-- In LS_SC0101_L2_M, shots whose camera has a 37.5 degree FOV play in 2D screen mode.
-- Checked only when the view target changes. LevelSequenceActor is a native class, so the
-- class lookup always succeeds and is cached.
local function isTwoDSequenceLoaded()
	for _, actor in ipairs(uevrUtils.find_all_of("Class /Script/LevelSequence.LevelSequenceActor") or {}) do
		local player = actor.SequencePlayer
		local name = player ~= nil and player:GetSequenceName() or nil
		if name ~= nil and name:gsub("%z", "") == "LS_SC0101_L2_M" then return true end
	end
	return false
end

local function updateCutscene2D(target)
	local camera = target ~= nil and target.CameraComponent or nil
	local use2D = camera ~= nil and math.abs(camera.FieldOfView - 37.5) < 0.1 and isTwoDSequenceLoaded()
	if use2D == (status.isCutscene2D == true) then return end
	status.isCutscene2D = use2D
	uevrUtils.set_2D_mode(use2D)
end

-- A level sequence with a fade track restores the camera fade it saved when it started,
-- on the frame it stops. If ui.lua's WBP_SimpleFade camera fade was black at that moment,
-- the cutscene ends on a held black fade. The view target returns to the pawn on that same
-- frame, so clear the fade then, unless ui.lua currently wants one.
-- Read the camera manager's ViewTarget.Target, not pc:GetViewTarget(): during the blend back
-- to the pawn, GetViewTarget() already returns the pawn (the pending target) seconds before
-- the sequence stops, while ViewTarget.Target switches on the frame it stops.
uevr.sdk.callbacks.on_pre_engine_tick(function()
	local pc = uevr.api:get_player_controller(0)
	local camMan = pc ~= nil and pc.PlayerCameraManager or nil
	if camMan == nil then return end
	local target = camMan.ViewTarget.Target
	local address = target ~= nil and target:get_address() or nil
	if address == status.lastViewTargetAddress then return end
	status.lastViewTargetAddress = address
	updateCutscene2D(target)
	if target ~= nil and pawn ~= nil and address == pawn:get_address() and not ui.isFadeCameraEnabled() then
		uevrUtils.stopFadeCamera()
	end
end)

-- Journal text is on page widgets. The game stacks a new one on each entry switch and
-- then hides them, expecting the scene-captured book to show. That capture is blank in VR.
-- Keep only the current page; fast switching otherwise leaves every previous page up.
-- The game hides a page only when it creates it, and its page functions are Blueprint
-- functions that cannot be hooked, so the tick below only checks and fixes when needed.
local function showCurrentJournalPage(overlay, keep)
	if overlay == nil or keep == nil then return false end
	if overlay.RenderOpacity >= 1 and keep:GetVisibility() == 4 then return false end
	overlay:SetRenderOpacity(1)
	local keepAddress = keep ~= nil and keep:get_address() or nil
	for i = 0, overlay:GetChildrenCount() - 1 do
		local child = overlay:GetChildAt(i)
		if child ~= nil then
			child:SetVisibility(keepAddress ~= nil and child:get_address() == keepAddress and 4 or 1)
		end
	end
	return true
end

-- The page overlays are laid out for drawing onto the 3D book, not side by side: their slot
-- paddings put them closer together than one page width, so the right page covers the left
-- page's edge and split illustrations break at the seam. Move the right page to meet the left.
local function alignJournalPages(book)
	local left, right = book.Left, book.Right
	if left == nil or right == nil or left.Slot == nil or right.Slot == nil then return end
	local offset = right:GetDesiredSize().X - (right.Slot.Padding.Left - left.Slot.Padding.Left)
	if math.abs(right.RenderTransform.Translation.X - offset) > 0.5 then
		right:SetRenderTranslation(uevrUtils.vector_2(offset, 0))
	end
end

-- The notebook is a child of the pause menu, not a viewport widget, so ui never reports it.
-- Track the pause menu instead and reach the notebook through it.
ui.registerWidgetChangeCallback("WBP_Pause_C", function(active, widget)
	status.pauseMenu = active and widget or nil
end)

uevr.sdk.callbacks.on_post_engine_tick(function()
	local pauseMenu = uevrUtils.getValid(status.pauseMenu)
	if pauseMenu == nil then return end
	local notebook = uevrUtils.getValid(pauseMenu, {"NotebookWidget"})
	local current = uevrUtils.getValid(pauseMenu, {"CurrentWidget"})
	if notebook == nil or current == nil or current:get_address() ~= notebook:get_address() then return end
	local book = uevrUtils.getValid(notebook, {"Book"})
	if book == nil then return end
	local leftChanged = showCurrentJournalPage(book.Left, book.LeftWidget)
	local rightChanged = showCurrentJournalPage(book.Right, book.RightWidget)
	if leftChanged or rightChanged then alignJournalPages(book) end
end)

configui.onUpdate("toggle_lumen", function(value)
    uevrUtils.set_cvar_int("r.Lumen.DiffuseIndirect.Allow", value and 0 or 1)
end)


configui.create(configDefinition)

local isPaused = false
register_key_bind("F2", function()
    isPaused = not isPaused
    uevrUtils.pauseGame(isPaused)
end)

register_key_bind("F3", function()
    unlimitedAwaken = true
    delay(1000, function()
        unlimitedAwaken = false
    end)
end)

