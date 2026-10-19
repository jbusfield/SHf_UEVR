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
local gunstock = require('libs/gunstock')
local scopes = require('libs/scope')
local ik = require('libs/ik')
local animation = require('libs/animation')
local collision = require('libs/collision')
local laser = require('libs/laser')
local plugin = require('libs/core/plugin')
local mouse = require('libs/mouse')

require("helpers/melee")
-- require("helpers/curveball")
-- local portables = require("helpers/portables")
-- local ranged = require("helpers/ranged")
-- local weapons = require("helpers/weapons")
-- local flashlight = require("helpers/flashlight")
-- local body = require("helpers/body")
-- local alyxWheel = require("helpers/alyx_wheel")

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
gunstock.showConfiguration()
scopes.setDefaultPitchOffset(90.0)
ik.init()
collision.init()

hands.setAutoCreateHands(false)
ik.setAutoCreateArms(false)

--since weapons are attached to the hand sockets for this game
--only let the hands be affected by gunstock offsets
attachments.setGunstockOffsetsEnabled(false)
hands.setGunstockOffsetsEnabled(true)
ik.setGunstockOffsetsEnabled(true)

uevrUtils.set_roomscale_active(true)


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
    if uevrUtils.isInCutscene() or uevrUtils.isGamePaused() then return nil end
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
	local rightHandComponent, leftHandComponent = getHandComponents()
    local rightSocketName = "weapon_r"
    --print(weaponMesh, rightHandComponent, rightSocketName)
    return rightHandComponent and weaponMesh, rightHandComponent, rightSocketName, nil, nil, nil, defaultAttachOptions --, controllers.getController(Handed.Right)

end)

local function cleanup()
    status = {}
end

on_level_change = function(level, levelName)
	print("on_level_change ", level, levelName)
    cleanup()
    regenerateHands(configui.getValue("hands_type") or 1)
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

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
	local gripMouthLeft, gripEyesLeft, gripHeadLeft, gripEarLeft, triggerMouthLeft, triggerEyesLeft, triggerHeadLeft, triggerEarLeft = gestures.getHeadGestures(state, Handed.Left, true)
    if gripEarLeft then 
        uevrUtils.pressButton(state, XINPUT_GAMEPAD_START)
        uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
     end

	local gripPressed = uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
	if not gripPressed then
		status.healGestureLatched = false
	elseif gripMouthLeft and not status.healGestureLatched then
		status.healGestureLatched = true
		-- Execute UObject calls on the game thread, outside the XInput callback.
		status.consumeItemRequested = "Capsule"
	end
	if status.healGestureLatched then
		-- Keep the wheel closed until release, including when lowering the hand.
		uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
	end
end, 10)

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
	if status.isNarrow ~= isNarrow or status.narrowFace ~= face then
		status.isNarrow = isNarrow
		status.narrowFace = face
		input.setCurrentProfileByLabel(isNarrow and (face == "R" and "NarrowMoveR" or "NarrowMoveL") or "Default")
	end


    -- local interacting, interactionType = getInteraction(pawn)
    -- if status.interactionType ~= interactionType then
    --     status.interactionType = interactionType
    --     pawnModule.hideArmsBones(not interacting)
    -- end
end)


-------------- Fix for interaction Icons ------------------------------
uevr.sdk.callbacks.on_pre_engine_tick(function()
    -- Invincibility through the game's own component.
	local invincible = uevrUtils.getValid(pawn, {"NoceInvincible"})
	local token = uevrUtils.fname_from_string("UEVR_Invincible")
	if invincible ~= nil and not invincible:IsTokenInvincible(token) then
		invincible:StartInvincible(token)
	end

end)

--replace input config Player Controller Overrides with this for Pitch Yaw and Roll
-- "Default", "Fixed", "Pawn", "HMD"
uevr.sdk.callbacks.on_pre_engine_tick(function()
    if ui.isInputDisabled() or uevrUtils.isInCutscene() then return end

    local pc = uevr.api:get_player_controller(0)
    local head = controllers.getControllerRotation(2)
    if pc == nil or head == nil then return end

    local rotation = pc:GetControlRotation()
    rotation.Pitch = head.Pitch
    rotation.Yaw = pawn:K2_GetActorRotation().Yaw
    pc:SetControlRotation(rotation)
end)

uevrUtils.registerOnPostInputGetStateCallback(function(retval, user_index, state)
    if ui.isInputDisabled() or uevrUtils.isInCutscene() then return end

    -- After remapping, so stick-down still produces B.
    state.Gamepad.sThumbRY = 0

    -- if state.Gamepad.sThumbLY < -1000 then
    --     pawn.NocePlayerController:DoSimulateInputAction(3, false)
    -- end
end)
--------------- End of Fix for interaction Icons ------------------------------

configui.onUpdate("hands_type", function(value)
    regenerateHands(value)
end)

configui.onCreateOrUpdate("use_controller_mouse", function(value)
	mouse.setOverrideEnable(value)
end)

ui.registerWidgetChangeCallback("WBP_SavePoint_C", function(active, widget)
	regenerateHands(configui.getValue("hands_type") or 1)
    pawnModule.hideArmsBones(true)
end)

ui.registerWidgetChangeCallback("WBP_GimmickInput_C", function(active, widget)
	status.isGimmickInput = active
end)

configui.create(configDefinition)

local isPaused = false
register_key_bind("F2", function()
    isPaused = not isPaused
    uevrUtils.pauseGame(isPaused)
end)
