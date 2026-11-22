local uevrUtils = require('libs/uevr_utils')
local grabbable = require('libs/grabbable')
local mechanisms = require('libs/mechanisms')
local accessories = require('libs/accessories')
local hands = require('libs/hands')
local ik = require('libs/ik')
local configui = require('libs/configui')
local gestures = require('libs/gestures')
local ui = require('libs/ui')
local grip = require('libs/grip')
local prompts = require('libs/prompts')
local widgetModule = require('libs/widget')
local GRIP_PRIORITY = require('helpers/grip_priority')

local M = {}

------------------- Physical item grab -------------------
-- Silent Hill f settings for libs/grabbable: a grip on the consumable the game's interaction prompt is on (food, drinks and other
-- consumable pickups) flies it into that hand; releasing throws or drops it with real physics, and releasing at that hand's ear
-- takes it with the game's own pickup. The right hand only grabs with no weapon in it (libs/grabbable leaves a hand alone while
-- main.lua's grip callback has something in it). A grip with no prompt on a grabbable item is not claimed, so the grips work as
-- before.
--
-- A pickup is two actors: the interactable (BP_Interact_Pickup_C: the triggers, the prompt, the pickup logic) and, as its child
-- actor, the pickup itself (NocePickupBase), which has the mesh. The interactable is the item that is grabbed and moved, so the
-- prompt and the pickup go wherever the item is dropped; the mesh comes from the child (grabbable's getMesh option).
-- Key items, letters and weapons are left to the game's own pickup: a thrown key item could be lost.

-- Owner names of each hand's grip claims, for main.lua's checks of who owns a press.
M.GRIP_OWNERS = {[Handed.Left] = "item_grab", [Handed.Right] = "item_grab_right"}

local PICKUP_INTERACT_CLASS = "BlueprintGeneratedClass /Game/Blueprint/InteractUnit/BP_Interact_Pickup.BP_Interact_Pickup_C"
local CONSUMABLE_CLASS = "Class /Script/GameNoce.NocePickupConsumable"
local BOX_CLASS = "Class /Script/Engine.BoxComponent"
local MOVABLE = 2 -- EComponentMobility
local SNAP_TO_TARGET = 2 -- EAttachmentRule
-- The physics box is never thinner than this (cm, half size): a chocolate bar's bounds are about half a centimeter thick.
local BODY_MIN_EXTENT = 2
local HANDS = {Handed.Left, Handed.Right}

-- bodies: interactable address -> {actor, body}, the physics boxes made for dropped items
-- hiddenPickups: pickup address -> pickup, the child actors hidden while their item is in a hand
-- pendingCollect: interactables released at the ear, picked up on the next tick
-- moved: interactable address -> {actor, wait, rest, offset, home}, items in a hand or released and not yet at rest; an item is
--   removed once it has come to rest, so this only ever holds the few items in play
local status = {bodies = {}, hiddenPickups = {}, pendingCollect = {}, moved = {}, interactionsEnabled = true}

grabbable.useRealPhysics(true)

-- The fox arm is a weapon (BP_Wep_Melee_Claw_C) whose mesh component has no mesh: main.lua attaches it to the right hand because
-- melee traces from it, but nothing shows there, so that hand still grabs (grabbable's isHandFree), and main.lua gives the hand to a
-- grabbed item until it is released. True for the current weapon's mesh when it has no mesh asset, so a visible weapon never counts.
function M.isEmptyWeaponMesh(component)
	local weaponMesh = uevrUtils.getValid(pawn, {"CurrentWeapon", "WeaponMesh"})
	if component == nil or weaponMesh == nil or component:get_address() ~= weaponMesh:get_address() then return false end
	return weaponMesh.SkinnedAsset == nil and weaponMesh.SkeletalMesh == nil
end
M.isEmptyWeaponMesh = uevrUtils.profiler:wrap('INTERACTIONS: isEmptyWeaponMesh', M.isEmptyWeaponMesh)

local function getPickup(actor)
	return uevrUtils.getValid(actor, {"NocePickupBase"})
end
getPickup = uevrUtils.profiler:wrap('INTERACTIONS: getPickup', getPickup)

local function getMesh(actor)
	return uevrUtils.getValid(actor, {"NocePickupBase", "StaticMesh"})
end
getMesh = uevrUtils.profiler:wrap('INTERACTIONS: getMesh', getMesh)

-- A consumable pickup that hasn't been taken (the game keeps a taken one around, hidden, for a few seconds) and can be moved.
local function isGrabbable(actor)
	local interactClass = uevrUtils.get_class(PICKUP_INTERACT_CLASS)
	if interactClass == nil or not actor:is_a(interactClass) then return false end
	if actor.ReadyToDestroy == true then return false end
	local pickup = getPickup(actor)
	local consumableClass = uevrUtils.get_class(CONSUMABLE_CLASS)
	if pickup == nil or consumableClass == nil or not pickup:is_a(consumableClass) then return false end
	local mesh = uevrUtils.getValid(pickup, {"StaticMesh"})
	if mesh == nil or mesh.StaticMesh == nil then return false end
	local root = uevrUtils.getValid(actor, {"RootComponent"})
	return root ~= nil and root.Mobility == MOVABLE
end
isGrabbable = uevrUtils.profiler:wrap('INTERACTIONS: isGrabbable', isGrabbable)

-- What the game's interaction prompt (button and text) is on. The player's interact component doesn't track pickups, so this is
-- the pickup that says it is showing its prompt. Only asked when a grip press starts.
local function getInteractTarget()
	for _, actor in ipairs(uevrUtils.find_all_of(PICKUP_INTERACT_CLASS, false) or {}) do
		if uevrUtils.getValid(actor) ~= nil and actor.IsShowingPrompt == true and not actor.bActorIsBeingDestroyed then return actor end
	end
	return nil
end
getInteractTarget = uevrUtils.profiler:wrap('INTERACTIONS: getInteractTarget', getInteractTarget)

-- Menus, cutscenes and a paused game keep the grips.
local function canClaim()
	return not (uevrUtils.isInCutscene() or uevrUtils.isGamePaused() or ui.isInputDisabled())
end
canClaim = uevrUtils.profiler:wrap('INTERACTIONS: canClaim', canClaim)

------------------- Dropped item physics -------------------
-- The item meshes have no collision of their own and the interactable's shapes are its triggers (a 120 cm box and a 3 m sphere),
-- so a dropped item simulates on a box made here to the size of its mesh (libs/grabbable's managed physics, through getBody).
-- The box is attached to the item's mesh, has no collision except while grabbable simulates it, and is kept for the item's next drop.
local function destroyBody(key)
	local entry = status.bodies[key]
	status.bodies[key] = nil
	if entry ~= nil and uevrUtils.getValid(entry.body) ~= nil then uevrUtils.destroyComponent(entry.body, true) end
end
destroyBody = uevrUtils.profiler:wrap('INTERACTIONS: destroyBody', destroyBody)

-- On a script reset or level change. A box that is still simulating (detached, with its item following it) is left alone:
-- grabbable settles it in its own reset, which runs after this one, moving the item to the box one last time as it does. A box
-- destroyed before that reads as being at the world origin, and the item was put there (a dried carcass dropped just before a
-- script reset ended up at 0, 0, 0). getBody finds a box left like this on the item's mesh again, so it is reused, not leaked.
local function destroyAllBodies()
	for key, entry in pairs(status.bodies) do
		local body = uevrUtils.getValid(entry.body)
		if body ~= nil and body.AttachParent ~= nil then destroyBody(key) end
	end
	status.bodies = {}
end
destroyAllBodies = uevrUtils.profiler:wrap('INTERACTIONS: destroyAllBodies', destroyAllBodies)

local function getBody(actor, mesh)
	-- Boxes of items that are gone (taken, or unloaded with their part of the world).
	for key, entry in pairs(status.bodies) do
		if uevrUtils.getValid(entry.actor) == nil or uevrUtils.getValid(entry.body) == nil then destroyBody(key) end
	end
	local key = actor:get_address()
	if status.bodies[key] ~= nil then return status.bodies[key].body end
	-- A box an earlier run of this script left on the mesh (see destroyAllBodies); the game's pickups have no box of their own there.
	local boxClass = uevrUtils.get_class(BOX_CLASS)
	for i = 0, mesh:GetNumChildrenComponents() - 1 do
		local child = mesh:GetChildComponent(i)
		if child ~= nil and boxClass ~= nil and child:is_a(boxClass) then
			status.bodies[key] = {actor = actor, body = child}
			return child
		end
	end
	local bounds = mesh.StaticMesh.ExtendedBounds
	if bounds == nil then return nil end
	local body = uevrUtils.create_component_of_class(BOX_CLASS)
	if body == nil then return nil end
	local extent, origin = bounds.BoxExtent, bounds.Origin
	body:SetBoxExtent(uevrUtils.vector(math.max(extent.X, BODY_MIN_EXTENT), math.max(extent.Y, BODY_MIN_EXTENT), math.max(extent.Z, BODY_MIN_EXTENT)), false)
	body:SetHiddenInGame(true, false)
	body:SetGenerateOverlapEvents(false)
	-- The terrain is static meshes that collide as their triangles (no simple shapes), a surface with no thickness, and a box this
	-- thin passes through it between two physics steps when it falls fast. Continuous collision detection sweeps it instead.
	body:SetUseCCD(true, uevrUtils.fname_from_string("None"))
	-- grabbable puts a settled body back on the collision profile it had, so that profile is no collision.
	body:SetCollisionProfileName(uevrUtils.fname_from_string("NoCollision"), true)
	body:K2_AttachToComponent(mesh, uevrUtils.fname_from_string("None"), SNAP_TO_TARGET, SNAP_TO_TARGET, SNAP_TO_TARGET, false)
	body:K2_SetRelativeLocationAndRotation(uevrUtils.vector(origin.X, origin.Y, origin.Z), uevrUtils.rotator(0, 0, 0), false, reusable_hit_result, true)
	status.bodies[key] = {actor = actor, body = body}
	return body
end
getBody = uevrUtils.profiler:wrap('INTERACTIONS: getBody', getBody)
------------------- End dropped item physics -------------------

local itemGrab = grabbable.new({
	hands = HANDS,
	names = M.GRIP_OWNERS,
	claimPriority = GRIP_PRIORITY.ITEM_GRAB,
	heldPriority = GRIP_PRIORITY.ITEM_HELD,
	isGrabbable = isGrabbable,
	getMesh = getMesh,
	canClaim = canClaim,
	toggleGrip = false,
	getInteractTarget = getInteractTarget,
	isCollectGesture = function(state, hand)
		local _, _, _, gripEar = gestures.getHeadGestures(state, hand, true)
		return gripEar
	end,
	-- Called from the input callback; the pickup itself runs on the next engine tick (below).
	collectCallback = function(actor)
		status.pendingCollect[#status.pendingCollect + 1] = actor
	end,
	-- A short buzz on the hand once the item is in the inventory.
	collectHaptic = {duration = 0.08, amplitude = 0.5},
	physics = {
		getBody = getBody,
		linearDamping = 0.5,
		angularDamping = 2,
	},
	-- A weapon drawn into a hand holding an item takes the hand.
	dropWhenHandTaken = true,
	-- The fox arm's empty weapon mesh doesn't make the hand busy (see isEmptyWeaponMesh).
	isHandFree = function(_, attachment)
		return M.isEmptyWeaponMesh(attachment)
	end,
})

-- The game's own pickup. It works from any distance and returns false even when it takes the item; ReadyToDestroy says it did.
-- The game then keeps the (hidden) actor for a few seconds before destroying it, but grabbable counts an item as collected once
-- it is gone, so a taken item is destroyed here. An item the game didn't take (e.g. the inventory is full) is left for grabbable
-- to drop.
local function collectPending()
	local pending = status.pendingCollect
	status.pendingCollect = {}
	local character = uevrUtils.getValid(pawn)
	for _, item in ipairs(pending) do
		local actor = uevrUtils.getValid(item)
		if character ~= nil and actor ~= nil and not actor.bActorIsBeingDestroyed then
			actor:RequestInstantFeedback(character)
			if actor.ReadyToDestroy == true and not actor.bActorIsBeingDestroyed then
				destroyBody(actor:get_address())
				actor:K2_DestroyActor()
			end
		end
	end
end
collectPending = uevrUtils.profiler:wrap('INTERACTIONS: collectPending', collectPending)

-- grabbable hides the item it holds, which is the interactable; its mesh is on the child pickup actor, which that doesn't hide.
-- So the child is hidden while its interactable is hidden in a hand, and shown again when the item leaves the hand.
local function updateHiddenPickups()
	local wanted = {}
	for _, hand in ipairs(HANDS) do
		local actor = itemGrab:getHeldActor(hand)
		if actor ~= nil and actor.bHidden == true then
			local pickup = getPickup(actor)
			if pickup ~= nil then wanted[pickup:get_address()] = pickup end
		end
	end
	for key, pickup in pairs(wanted) do
		if status.hiddenPickups[key] == nil then
			pickup:SetActorHiddenInGame(true)
			status.hiddenPickups[key] = pickup
		end
	end
	for key, pickup in pairs(status.hiddenPickups) do
		if wanted[key] == nil then
			status.hiddenPickups[key] = nil
			if uevrUtils.getValid(pickup) ~= nil and not pickup.bActorIsBeingDestroyed then pickup:SetActorHiddenInGame(false) end
		end
	end
end
updateHiddenPickups = uevrUtils.profiler:wrap('INTERACTIONS: updateHiddenPickups', updateHiddenPickups)

-- The game only shows an item's prompt while it has a clear line of sight to the item's icon position, and it works that position
-- out where the item was placed. An item dropped somewhere else then counts as blocked from view and gets no prompt, so it can't be
-- grabbed or picked up again. So an item released from a hand is checked a few times a second: when the game's icon position is no
-- longer where it was relative to the item, the game works it out again (UpdateIconPosition). The game's own value is what is
-- compared, not a record kept here of how the item moved. Once the position has needed no correction for ICON_REST_TIME the item
-- has come to rest and is no longer checked (until it is next in a hand), so nothing is kept for items lying around.
local ICON_CHECK_INTERVAL = 0.25 -- seconds
local ICON_TOLERANCE = 1 -- cm, summed over the axes
local ICON_REST_TIME = 3 -- seconds

-- True when the icon position had to be corrected.
local function updateIconPosition(entry, actor, at)
	local icon, offset = actor.IconPosition, entry.offset
	if icon == nil then return false end
	if offset ~= nil and math.abs(icon.X - at.X - offset.x) + math.abs(icon.Y - at.Y - offset.y) + math.abs(icon.Z - at.Z - offset.z) <= ICON_TOLERANCE then return false end
	if actor.UpdateIconPosition ~= nil then actor:UpdateIconPosition() end
	icon = actor.IconPosition
	-- Where the game puts the icon relative to the item (15 cm above it), whatever that turns out to be for this item.
	entry.offset = {x = icon.X - at.X, y = icon.Y - at.Y, z = icon.Z - at.Z}
	return true
end
updateIconPosition = uevrUtils.profiler:wrap('INTERACTIONS: updateIconPosition', updateIconPosition)
-- Safety net for an item that still gets through the ground: one that has fallen this far below where it was released is put back
-- there (where the hand let go of it, so it may hang in the air), rather than being lost under the world.
local FALL_LIMIT = 15000 -- cm
local RETURN_TIMEOUT = 2 -- seconds to wait for grabbable to put the stopped physics box back on the item

-- grabbable moves a dropped item with its physics box every tick, so the box is stopped first: grabbable puts a box that has gone to
-- sleep back on the item (a box that only stopped simulating still counts as awake). The item is moved once that has happened.
local function returnFallenItem(key, entry, actor, delta)
	local body = status.bodies[key] ~= nil and uevrUtils.getValid(status.bodies[key].body) or nil
	entry.returnWait = (entry.returnWait or 0) + delta
	if body ~= nil and body.AttachParent == nil and entry.returnWait < RETURN_TIMEOUT then
		if not entry.returning then
			body:SetSimulatePhysics(false)
			body:PutRigidBodyToSleep(uevrUtils.fname_from_string("None"))
		end
		entry.returning = true
		return
	end
	actor:K2_SetActorLocation(uevrUtils.vector(entry.home.x, entry.home.y, entry.home.z), false, reusable_hit_result, true)
	entry.returning, entry.returnWait = nil, nil
end
returnFallenItem = uevrUtils.profiler:wrap('INTERACTIONS: returnFallenItem', returnFallenItem)

local function updateIconPositions(delta)
	local held = {}
	for _, hand in ipairs(HANDS) do
		local actor = itemGrab:getHeldActor(hand)
		if actor ~= nil then
			local key = actor:get_address()
			held[key] = true
			if status.moved[key] == nil then status.moved[key] = {actor = actor, wait = 0, rest = 0} end
		end
	end
	for key, entry in pairs(status.moved) do
		local actor = uevrUtils.getValid(entry.actor)
		if actor == nil or actor.bActorIsBeingDestroyed then
			status.moved[key] = nil
		elseif held[key] then
			-- In a hand (or flying to it): it is checked as soon as it is released.
			entry.wait, entry.rest, entry.home, entry.returning, entry.returnWait = ICON_CHECK_INTERVAL, 0, nil, nil, nil
		else
			entry.wait = entry.wait + delta
			if entry.wait >= ICON_CHECK_INTERVAL then
				local elapsed = entry.wait
				entry.wait = 0
				local at = actor:K2_GetActorLocation()
				-- Where it left the hand.
				if entry.home == nil then entry.home = {x = at.X, y = at.Y, z = at.Z} end
				if entry.returning or at.Z < entry.home.z - FALL_LIMIT then
					returnFallenItem(key, entry, actor, elapsed)
					entry.rest = 0
				elseif updateIconPosition(entry, actor, at) then
					entry.rest = 0
				else
					-- At rest with its icon in place: after ICON_REST_TIME of that, the item is forgotten.
					entry.rest = entry.rest + elapsed
					if entry.rest >= ICON_REST_TIME then status.moved[key] = nil end
				end
			end
		end
	end
end
updateIconPositions = uevrUtils.profiler:wrap('INTERACTIONS: updateIconPositions', updateIconPositions)

uevrUtils.registerPostEngineTickCallback(function(_, delta)
	if #status.pendingCollect > 0 then collectPending() end
	if status.enabled or next(status.hiddenPickups) ~= nil then updateHiddenPickups() end
	if status.enabled or next(status.moved) ~= nil then updateIconPositions(delta) end
end)

function M.setItemGrabEnabled(value)
	status.enabled = value == true
	itemGrab:setEnabled(status.enabled)
end

-- The copy of an item in hand (hidden during its flight), from the start of a grab until it leaves the hand, for main.lua's grip
-- callback.
function M.getHeldItemMesh(hand)
	return itemGrab:getHeldMesh(hand)
end
M.getHeldItemMesh = uevrUtils.profiler:wrap('INTERACTIONS: getHeldItemMesh', M.getHeldItemMesh)

-- grabbable shows the items it was holding again on a script reset; their child pickups are shown again here.
local function reset()
	destroyAllBodies()
	for _, pickup in pairs(status.hiddenPickups) do
		if uevrUtils.getValid(pickup) ~= nil and not pickup.bActorIsBeingDestroyed then pickup:SetActorHiddenInGame(false) end
	end
	status.hiddenPickups, status.pendingCollect, status.moved = {}, {}, {}
end
reset = uevrUtils.profiler:wrap('INTERACTIONS: reset', reset)

uevrUtils.registerLevelChangeCallback(reset)
uevr.params.sdk.callbacks.on_script_reset(reset)
------------------- End physical item grab -------------------

------------------- Grip interact -------------------
-- Silent Hill f settings for libs/grip's registerInteract: while the game shows its interact button (A) on something, the prompt
-- shows LB instead and the left grip presses A, without opening the item wheel. A grabbable item's prompt shows LB too; Physical
-- Item Grab's claim is higher, so that grip grabs it.
--
-- Every interaction prompt is one of a few pooled WBP_InteractIcon_C widgets (three were seen), kept for the whole session. One
-- widget at a time is in its Prompt state (the others show a dot or nothing), and that widget is the target: the player's interact
-- component does name the object, but as a weak pointer, which reads as nil from Lua. The game makes another widget when it needs
-- one, so the list is read again every few seconds (a per-class list lookup, not an object scan).
M.GRIP_INTERACT_OWNER = "grip_interact"

local INTERACT_ICON_CLASS = "Class /Script/GameNoce.NoceInteractIconBase"
local INTERACT_A_ICON = "PaperSprite /Game/UI/Base/Input/Platform/_XB1/UT_InputGuide_XB1_0.UT_InputGuide_XB1_0"
local INTERACT_LB_ICON = "PaperSprite /Game/UI/Base/Input/Platform/_XB1/UT_InputGuide_XB1_32.UT_InputGuide_XB1_32"
local INTERACT_ICON_PROMPT = 0 -- ENoceInteractIconState: Prompt (1 is Hint, the dot; 2 Hidden; 3 Forbit)
local INTERACT_ICON_RESCAN = 2 -- seconds

-- The icon widget showing the game's interact button, or nil.
local function getActivePromptWidget()
	local now = os.clock()
	if status.promptIcons == nil or now - status.promptIconsTime >= INTERACT_ICON_RESCAN then
		status.promptIcons, status.promptIconsTime = uevrUtils.find_all_of(INTERACT_ICON_CLASS, false) or {}, now
	end
	for _, widget in ipairs(status.promptIcons) do
		widget = uevrUtils.getValid(widget)
		if widget ~= nil and widget.CurrentState == INTERACT_ICON_PROMPT then return widget end
	end
	return nil
end
getActivePromptWidget = uevrUtils.profiler:wrap('INTERACTIONS: getActivePromptWidget', getActivePromptWidget)

local getPromptIcon, setPromptIcon = prompts.brushResource()
local gripInteract = grip.registerInteract({
	name = M.GRIP_INTERACT_OWNER,
	priority = GRIP_PRIORITY.INTERACT,
	button = XINPUT_GAMEPAD_A,
	getInteractTarget = getActivePromptWidget,
	canClaim = canClaim,
	prompt = {
		getPrompts = function(widget) return uevrUtils.getValid(widget, {"PromptButtonIcon"}) end,
		get = getPromptIcon,
		set = setPromptIcon,
		from = function() return prompts.loadAsset(INTERACT_A_ICON) end,
		to = function() return prompts.loadAsset(INTERACT_LB_ICON) end,
	},
})

function M.setGripInteractEnabled(value)
	if gripInteract ~= nil then gripInteract:setEnabled(value == true) end
end
------------------- End grip interact -------------------

------------------- Mechanism prompt -------------------
-- Silent Hill f settings for libs/mechanisms' prompt option: the things worked by hand (the log bundles and doors below) show a
-- sentence in place of a button, and the left grip does nothing special there. libs/mechanisms decides when (while a mechanism has
-- its actor); this is how the game's prompt widget is changed.
--
-- The button can't be hidden by visibility (the game sets it again every frame), so it is made transparent, which stays. The
-- widget's own text block can't carry the sentence: the game asks each object for its prompt text and writes it (empty, for these)
-- over anything put there. So the sentence is a text block of the mod's own, added to the prompt widget's canvas where the button
-- sits (both are centred on the canvas origin), with the game's prompt font and color. One per pooled widget, made on first use.
local MECHANISM_PROMPT_TEXT = "Reach out your hand to interact"
-- For a mechanism whose Engage With is Grip.
local MECHANISM_GRIP_PROMPT_TEXT = "Grip to interact"

local function showMechanismPrompt(prompt, text)
	local image = uevrUtils.getValid(prompt, {"PromptButtonIcon"})
	if image ~= nil and image.ColorAndOpacity.A ~= 0 then image:SetOpacity(0) end
	status.promptLabels = status.promptLabels or {}
	local key = prompt:get_address()
	local label = status.promptLabels[key]
	-- libs/widget removes its text blocks before a level change, so a label can have lost its block.
	if label == nil or uevrUtils.getValid(label.textBlock) == nil then
		label = widgetModule.Text.new(text or "")
		if not label:addToWidget(prompt, {align = widgetModule.Text.ALIGN.TOP_LEFT, alignment = uevrUtils.vector2D(0.5, 0.5), offset = uevrUtils.vector2D(0, 0)}) then return end
		local gameText = uevrUtils.getValid(prompt, {"PromptText"})
		if gameText ~= nil then
			label.textBlock:SetFont(gameText.Font)
			label.textBlock:SetColorAndOpacity(gameText.ColorAndOpacity)
		end
		status.promptLabels[key] = label
	end
	if label.text ~= (text or "") then label:setText(text) end
	if label.hidden ~= false then label:setVisible(true) end
end
showMechanismPrompt = uevrUtils.profiler:wrap('INTERACTIONS: showMechanismPrompt', showMechanismPrompt)

local function hideMechanismPrompt(prompt)
	local image = uevrUtils.getValid(prompt, {"PromptButtonIcon"})
	if image ~= nil and image.ColorAndOpacity.A == 0 then image:SetOpacity(1) end
	local label = status.promptLabels ~= nil and status.promptLabels[prompt:get_address()] or nil
	if label ~= nil and label.hidden ~= true then label:setVisible(false) end
end
hideMechanismPrompt = uevrUtils.profiler:wrap('INTERACTIONS: hideMechanismPrompt', hideMechanismPrompt)

-- Shared by the mechanisms below. The prompt of the object a mechanism found is the one widget in its Prompt state: a mechanism
-- only finds an object that is showing its prompt, and the game shows one button at a time.
local mechanismPrompt = {
	getPrompt = getActivePromptWidget,
	show = showMechanismPrompt,
	hide = hideMechanismPrompt,
	text = MECHANISM_PROMPT_TEXT,
	gripText = MECHANISM_GRIP_PROMPT_TEXT,
}
------------------- End mechanism prompt -------------------

------------------- Physical push -------------------
-- Silent Hill f settings for libs/mechanisms: the log bundles that block a path (BP_PushPlank_C) are pushed with one or both hands
-- instead of holding A. The game moves a bundle while A is held for CheckDuration (5.5 seconds: it shakes at 0.7, starts moving
-- at 3.5, and is out of the way at 5.5), and letting go earlier puts it back at the start. So while the hands are on the bundle
-- A is held for the player, and the game's own animation, sounds and result are unchanged.
--
-- The bundle to push is the one showing its prompt: the game shows it once the player stands in the bundle's trigger, facing it.
-- The hands then have to reach the push surface below, which is fixed to the bundle's actor (x toward the player's side, z up from
-- the floor). The player is stopped about a meter from the actor, so reaching the surface takes an arm's stretch forward.
-- Once pushing, the game moves the player up to the bundle and along with it, so letting go is judged against the head: a hand
-- keeps pushing while it is at least keepReach ahead of the head toward the bundle. Both hands pulled back gives the push up.
local PUSH_PLANK_CLASS = "BlueprintGeneratedClass /Game/Blueprint/Level/Gimmick/PushPlank/BP_PushPlank.BP_PushPlank_C"

-- The bundle's class is only loaded with the parts of the world that have a bundle, and is loaded again as a new object after the
-- game reloads. uevrUtils.getClassIfLoaded gives it only while the game has it loaded, without loading it or looking it up by name.

local function findPushPlank()
	local class = uevrUtils.getClassIfLoaded(PUSH_PLANK_CLASS)
	if class ~= nil then
		for _, actor in ipairs(UEVR_UObjectHook.get_objects_by_class(class, false) or {}) do
			if uevrUtils.getValid(actor) ~= nil and actor.IsShowingPrompt == true and actor.Succeed ~= true and not actor.bActorIsBeingDestroyed then return actor end
		end
	end
	return nil
end
findPushPlank = uevrUtils.profiler:wrap('INTERACTIONS: findPushPlank', findPushPlank)

-- "moving" once the bundle's animation starts it sliding (3.5 seconds in), "brace" before that.
local function getPushPlankPhase(actor)
	local mesh = uevrUtils.getValid(actor, {"SkeletalMesh"})
	local anim = mesh ~= nil and mesh:GetAnimInstance() or nil
	return anim ~= nil and anim.CanCount == true and "moving" or "brace"
end
getPushPlankPhase = uevrUtils.profiler:wrap('INTERACTIONS: getPushPlankPhase', getPushPlankPhase)

-- The bundle's hand spots are the accessories saved under this key (added and tuned in the Mechanisms Dev Config): where a hand's
-- spot is on the bundle is where it starts the push, and where it is put while pushing. A hand with no spot saved for it uses the
-- push surface in the definition.
local PUSH_PLANK_ACCESSORY_KEY = "PushPlank"

-- The nearest bundle within 5 meters, prompt or not: for testing its hand spots in the Mechanisms Dev Config.
local function findNearestPushPlank()
	local player = uevrUtils.getValid(pawn)
	local class = uevrUtils.getClassIfLoaded(PUSH_PLANK_CLASS)
	if player == nil or class == nil then return nil end
	local location = player:K2_GetActorLocation()
	local best, bestDistance = nil, 500
	for _, actor in ipairs(UEVR_UObjectHook.get_objects_by_class(class, false) or {}) do
		if uevrUtils.getValid(actor) ~= nil and not actor.bActorIsBeingDestroyed then
			local distance = uevrUtils.distanceBetween(location, actor:K2_GetActorLocation())
			if distance < bestDistance then best, bestDistance = actor, distance end
		end
	end
	return best
end
findNearestPushPlank = uevrUtils.profiler:wrap('INTERACTIONS: findNearestPushPlank', findNearestPushPlank)

local pushPlank = mechanisms.new({
	name = "push_plank",
	label = "Log Bundle",
	kind = "push",
	prompt = mechanismPrompt,
	find = findPushPlank,
	findNearest = findNearestPushPlank,
	isAllowed = canClaim,
	-- One hand on the bundle starts the push; the other can join or stay off.
	hands = 1,
	accessoryKey = PUSH_PLANK_ACCESSORY_KEY,
	contactDistance = 30,
	surface = {origin = {50, 0, 110}, normal = {1, 0, 0}, radius = 80},
	enterDistance = 10,
	exitDistance = 70,
	exitMargin = 40,
	maxDepth = 150,
	keepReach = 25,
	driver = mechanisms.holdButtonDriver({
		button = XINPUT_GAMEPAD_A,
		isActive = function(actor) return actor.IsCurrentUsing == true end,
		isDone = function(actor) return actor.Succeed == true end,
		getProgress = function(actor)
			local total = tonumber(actor.CheckDuration) or 0
			return total > 0 and (tonumber(actor.CurrentDuration) or 0) / total or 0
		end,
		getPhase = getPushPlankPhase,
	}),
})

function M.setPhysicalPushEnabled(value)
	if pushPlank ~= nil then pushPlank:setEnabled(value == true) end
end

M.setPhysicalPushEnabled(true)
------------------- End physical push -------------------

------------------- Physical ladder -------------------
-- Silent Hill f's facts for libs/mechanisms' Ladder type (the game adapter's ladder table, below). The ladders are the "Ladder"
-- mechanism of the Mechanisms Dev Config, of type Ladder: pressing A to get on as before (Getting on), then on the ladder a grip on the
-- rungs takes hold, and pulling down with it climbs (pushing up climbs down); the stick still climbs as before. The ladder climbed is
-- the one the game says it is using (the adapter's isBusy: IsCurrentUsing).
--
-- Measured live on BP_LadderIndicator_A_C (2026-11-17):
-- - The actor's origin is on the rung line at the top (Ladder_Top). Its forward axis runs along the rungs (the rails, Ladder_l and
--   Ladder_r, are 23 cm either side), and the player stands 44 cm along its right axis. Ladder_Down is the bottom, 253 cm lower.
-- - At rest the player's montage is ClimbLadder_Idle_L or _R. A stick step plays ClimbLadder_Up_Loop_* or ClimbLadder_Down_Loop_*,
--   moves the player 21.6 cm in about 0.6 s, and switches the idle side.
-- - A location written at rest holds, and the next step starts from it (a step down from 5 cm up ended 5 cm up).
-- - The lowest rest is 83 cm above Ladder_Down. The highest rest was not measured: hand climbing stops 100 cm below Ladder_Top (as on
--   Hogwarts Legacy's ladders), and a pull past that pushes the stick up, so the game's own steps take the player the rest of the way.
-- - ISM_Crossbar has one instance per rung, evenly spaced from Ladder_Top (the top rung) down to Ladder_Down (the bottom one): 12
--   rungs, 23 cm apart. The ladders stand upright.
local LADDER_LOWEST_REST_ABOVE_BOTTOM = 83 -- cm, the player's actor location above Ladder_Down
local LADDER_HIGHEST_REST_BELOW_TOP = 100 -- cm, below Ladder_Top

-- The player's current montage's full name, read again only when the montage changes (asked on every tick while climbing).
local function getPlayerMontageName()
	local montage = uevrUtils.getValid(pawn, {"NoceMontageStateMonitor", "PlayAnimMontage"})
	if montage == nil then return nil end
	local address = montage:get_address()
	if status.montageAddress ~= address then status.montageAddress, status.montageName = address, montage:get_full_name() end
	return status.montageName
end
getPlayerMontageName = uevrUtils.profiler:wrap('INTERACTIONS: getPlayerMontageName', getPlayerMontageName)

local function getComponentZ(actor, name)
	local component = uevrUtils.getValid(actor, {name})
	return component ~= nil and component:K2_GetComponentLocation().Z or nil
end
getComponentZ = uevrUtils.profiler:wrap('INTERACTIONS: getComponentZ', getComponentZ)

-- The ladder's rungs: how many, the top one's world height, and the spacing (the library keeps them per ladder).
local function getLadderRungs(actor)
	local crossbars = uevrUtils.getValid(actor, {"ISM_Crossbar"})
	local count = crossbars ~= nil and tonumber(crossbars:GetInstanceCount()) or nil
	local bottom, top = getComponentZ(actor, "Ladder_Down"), getComponentZ(actor, "Ladder_Top")
	if count == nil or count < 2 or bottom == nil or top == nil or top <= bottom then return nil end
	return count, top, (top - bottom) / (count - 1)
end
getLadderRungs = uevrUtils.profiler:wrap('INTERACTIONS: getLadderRungs', getLadderRungs)

-- Steps played with the hands (the Climbing stage's Animate Steps With Hands). Measured live on 2026-11-18:
-- - A step is root motion: ABP_Pl_Hina_C's RootMotionMode is from montages only, and ClimbLadder_Up_Loop_L's sequence has root
--   motion on. Each _Loop_ montage is 0.5 s.
-- - On the ladder the movement mode is Flying. A step held still at play rate 0 left its last velocity carrying the player on, far
--   past the ladder's top, so a held step also stops the movement, on every tick.
-- - Held still with StopMovementImmediately, the player stayed put, and Montage_SetPosition changed only the pose.
-- - Played on at rate 1 from 0.45 s it moved the player 1 cm more and the game rested on the other side, as after its own step.
--   From 0 s it moved the whole step (23 cm), so a step is played on from just before its end.
-- - The stick does nothing while a step is held.
local LADDER_STEP_LENGTH = 21.6 -- cm, one of the game's steps
local LADDER_STEP_END_MARGIN = 0.02 -- s before its end that a step is played on from

-- A step's montage and the player's anim instance, or nil while either is gone.
local function getLadderStepParts(step)
	local montage = uevrUtils.getValid(step)
	local mesh = uevrUtils.getValid(pawn, {"Mesh"})
	local animInstance = mesh ~= nil and uevrUtils.getValid(mesh:GetAnimInstance()) or nil
	if montage == nil or animInstance == nil then return nil, nil end
	return montage, animInstance
end
getLadderStepParts = uevrUtils.profiler:wrap('INTERACTIONS: getLadderStepParts', getLadderStepParts)

-- A step's first tick. The game starts it at rate 1 in its tick, before the hold in the post-engine tick, so its root motion lifted
-- the player 2.4 to 3.0 cm for one rendered frame before the hold wrote the body back where the hands put it: an up/down stutter
-- (measured per frame on 2026-11-18: 8 of 8 steps started by the hands). From the stick push for a step until it plays on (or
-- doesn't come), the player's anim instance ignores root motion (ERootMotionMode IgnoreRootMotion, 1), so only the hands move the
-- body. The game's own mode (from montages only, 3) is put back before the step plays on, so it finishes and rests as before.
local ROOT_MOTION_IGNORE = 1

local function startLadderStep()
	local mesh = uevrUtils.getValid(pawn, {"Mesh"})
	local animInstance = mesh ~= nil and uevrUtils.getValid(mesh:GetAnimInstance()) or nil
	if animInstance == nil then return end
	local saved = status.ladderRootMotion
	if saved == nil or uevrUtils.getValid(saved.instance) ~= animInstance then
		status.ladderRootMotion = {instance = animInstance, mode = animInstance.RootMotionMode}
	end
	animInstance:SetRootMotionMode(ROOT_MOTION_IGNORE)
end
startLadderStep = uevrUtils.profiler:wrap('INTERACTIONS: startLadderStep', startLadderStep)

-- Puts back the root motion mode startLadderStep found (after a step, a step that didn't come, or a script reset).
local function restoreLadderRootMotion()
	local saved = status.ladderRootMotion
	status.ladderRootMotion = nil
	if saved == nil then return end
	local animInstance = uevrUtils.getValid(saved.instance)
	if animInstance ~= nil and saved.mode ~= nil then animInstance:SetRootMotionMode(saved.mode) end
end
restoreLadderRootMotion = uevrUtils.profiler:wrap('INTERACTIONS: restoreLadderRootMotion', restoreLadderRootMotion)

uevr.params.sdk.callbacks.on_script_reset(restoreLadderRootMotion)

-- The game's climbing step now playing, and its way (1 up, -1 down).
local function getLadderStep()
	local name = getPlayerMontageName()
	if name == nil then return nil end
	local direction = nil
	if string.find(name, "ClimbLadder_Up_Loop", 1, true) ~= nil then
		direction = 1
	elseif string.find(name, "ClimbLadder_Down_Loop", 1, true) ~= nil then
		direction = -1
	end
	if direction == nil then return nil end
	return uevrUtils.getValid(pawn, {"NoceMontageStateMonitor", "PlayAnimMontage"}), direction
end
getLadderStep = uevrUtils.profiler:wrap('INTERACTIONS: getLadderStep', getLadderStep)

-- Keeps the step still at phase (0 to 1) of it, and the player from moving on by the step's last velocity. The game's own play
-- rate is kept for playing it on.
-- Called on every tick while a step is held, so only what changed is written: a rate above 0 (or unread) is a step not held
-- yet (a new one, or one the game started again), which is stopped and has its length read; the position is written when the
-- phase changes or the step is new. The movement is stopped on every tick (see above).
local function holdLadderStep(_, step, phase)
	local montage, animInstance = getLadderStepParts(step)
	if montage == nil or animInstance == nil then return end
	local rate = tonumber(animInstance:Montage_GetPlayRate(montage))
	local isNew = rate == nil or rate > 0 or status.ladderStepLength == nil
	if isNew then
		if rate ~= nil and rate > 0 then status.ladderStepRate = rate end
		animInstance:Montage_SetPlayRate(montage, 0)
		status.ladderStepLength = tonumber(montage:GetPlayLength()) or 0
	end
	local position = (tonumber(phase) or 0) * status.ladderStepLength
	if isNew or status.ladderStepPosition ~= position then
		status.ladderStepPosition = position
		animInstance:Montage_SetPosition(montage, position)
	end
	local movement = uevrUtils.getValid(pawn, {"CharacterMovement"})
	if movement ~= nil then movement:StopMovementImmediately() end
end
holdLadderStep = uevrUtils.profiler:wrap('INTERACTIONS: holdLadderStep', holdLadderStep)

-- Plays the step on from just before its end, at the game's rate, so the game finishes it and rests as after its own.
local function finishLadderStep(_, step)
	restoreLadderRootMotion()
	local rate = status.ladderStepRate or 1
	status.ladderStepRate = nil
	local montage, animInstance = getLadderStepParts(step)
	if montage == nil or animInstance == nil then return end
	animInstance:Montage_SetPosition(montage, math.max(0, montage:GetPlayLength() - LADDER_STEP_END_MARGIN))
	animInstance:Montage_SetPlayRate(montage, rate)
end
finishLadderStep = uevrUtils.profiler:wrap('INTERACTIONS: finishLadderStep', finishLadderStep)

-- The game adapter's ladder table (mechanisms.setGameAdapter, below).
local ladderFacts = {
	-- The others leave a ladder grip alone: main.lua's grip gestures are at the ear and mouth, and melee does nothing while the
	-- player is interacting.
	gripPriority = GRIP_PRIORITY.LADDER,
	isIdle = function()
		local name = getPlayerMontageName()
		return name ~= nil and string.find(name, "ClimbLadder_Idle", 1, true) ~= nil
	end,
	getRange = function(actor)
		local bottom, top = getComponentZ(actor, "Ladder_Down"), getComponentZ(actor, "Ladder_Top")
		if bottom == nil or top == nil then return nil end
		return bottom + LADDER_LOWEST_REST_ABOVE_BOTTOM, top - LADDER_HIGHEST_REST_BELOW_TOP
	end,
	getRungs = getLadderRungs,
	-- The rungs run along the actor's forward axis (x), so the rung plane faces along y, and the player is on its right (+y).
	getFrame = function(actor) return actor, "y", 1 end,
	-- For Animate Steps With Hands (see above).
	getStep = getLadderStep,
	holdStep = holdLadderStep,
	finishStep = finishLadderStep,
	startStep = startLadderStep,
	cancelStep = restoreLadderRootMotion,
	stepLength = LADDER_STEP_LENGTH,
}

-- A hand holding a ladder's rungs uses the Climbing stage's Grip Animation (the Mechanisms Dev Config) in place of the pose
-- libs/accessories gives it from its hand spot. With Default nothing is set here, so the hand spot's Grip Animation applies. When
-- the stage's stops applying (the hand lets go, or Default is chosen), the hand goes back to the last pose libs/accessories gave
-- it (nil: whatever it holds, or nothing). The stage's choice is read once as the hand takes hold, so a change in the config UI
-- applies from the next grab.
local handsAnimation = require('libs/hands_animation')
status.ladderGripPose = {}
status.ladderGripMechanism = {}
status.ladderGripChoice = {}
status.accessoryGripPose = {}
status.accessoryGripPoseChanged = {}

-- libs/accessories sets a hand's pose as it is put on or taken off a hand spot: kept for going back to, and the stage's is set
-- again on the next tick in case it was just replaced.
uevrUtils.registerUEVRCallback("on_accessory_animation", function(handed, anim)
	status.accessoryGripPose[handed] = anim
	status.accessoryGripPoseChanged[handed] = true
end)

uevrUtils.registerPostEngineTickCallback(function()
	-- Physical Interactions off: nothing to do once a pose that was applied has been put back.
	if not status.interactionsEnabled and next(status.ladderGripPose) == nil then return end
	for _, hand in ipairs(HANDS) do
		-- What the hand is on changes only as it grabs or lets go: the stage's choice is read then, not on every tick.
		local mechanism = mechanisms.getEngagedMechanism(hand)
		if mechanism ~= status.ladderGripMechanism[hand] then
			status.ladderGripMechanism[hand] = mechanism
			local choice = nil
			if mechanism ~= nil and mechanism:getType() == "ladder" and mechanism:getStage() == "climb" then
				choice = mechanism:getGripAnimation()
			end
			status.ladderGripChoice[hand] = choice
		end
		local pose = status.ladderGripChoice[hand]
		local applied = status.ladderGripPose[hand]
		if pose ~= nil and (pose ~= applied or status.accessoryGripPoseChanged[hand]) then
			status.ladderGripPose[hand] = pose
			handsAnimation.setHoldingAttachment(hand, pose)
		elseif pose == nil and applied ~= nil then
			status.ladderGripPose[hand] = nil
			handsAnimation.setHoldingAttachment(hand, status.accessoryGripPose[hand])
		end
		status.accessoryGripPoseChanged[hand] = nil
	end
end)
------------------- End physical ladder -------------------

------------------- Mechanisms made in the config UI -------------------
-- Everything else worked by hand (the doors, and whatever is added later) has no code here: each is a saved entry of
-- libs/mechanisms, added and edited in the Mechanisms Dev Config (stand at it and press Add Mechanism Here). This is all the
-- library has to be told about Silent Hill f for that: how the game says an interactable (NoceInteractableBase) is on offer, in
-- use and finished.
--
-- Hands on a mechanism: libs/accessories puts a hand that is working one on its mesh, at the hand spot it reached, so the hand
-- stays on the logs or the door as they move. This is the same path Atomic Heart's steering wheel uses; libs/mechanisms says
-- what each hand is on (mechanisms.getAccessoryTarget).

-- Not while the hands are being rebuilt: an attach then would be lost, with the accessory still counted as attached.
local function areHandsReady(hand)
	local handsType = configui.getValue("hands_type") or 1
	if handsType == 1 and #hands.getHandComponentsForHand(hand) == 0 then return false end
	if handsType == 2 and not ik.exists() then return false end
	return true
end
areHandsReady = uevrUtils.profiler:wrap('INTERACTIONS: areHandsReady', areHandsReady)

mechanisms.setGameAdapter({
	-- For the config UI's "In front of you": every interactable derives from this.
	baseClass = "Class /Script/GameNoce.NoceInteractableBase",
	-- On offer: showing its prompt (the game shows one at a time, once the player stands in its trigger facing it), and not already
	-- in use, opened (doors) or done (the log bundles).
	isOffered = function(actor)
		return actor.IsShowingPrompt == true and actor.IsCurrentUsing ~= true and actor.IsDoorOpened ~= true and actor.Succeed ~= true
	end,
	isBusy = function(actor) return actor.IsCurrentUsing == true end,
	-- A door is finished once the game has stopped using it and it is open. Things with no opened state never say so: their
	-- hands let go by their entry's release setting, or when the game stops using them.
	isFinished = function(actor) return actor.IsCurrentUsing ~= true and actor.IsDoorOpened == true end,
	isAllowed = canClaim,
	isHandReady = areHandsReady,
	-- Scan optimize (below): mechanisms scan while the game shows its interact button (checked by mechanisms with prompt.getPrompt),
	-- and also while the player is interacting (a ladder too).
	isScanNeeded = function()
		local player = uevrUtils.getValid(pawn)
		return player ~= nil and player.IsInteracting ~= nil and player:IsInteracting() == true
	end,
	prompt = mechanismPrompt,
	-- Every mechanism's Engage With: Grip claim, the log bundle's too (see helpers/grip_priority).
	engageGripPriority = GRIP_PRIORITY.MECHANISM,
	-- For mechanisms of type Ladder (see Physical ladder).
	ladder = ladderFacts,
	-- Hand spots are on a ladder's bottom (Ladder_Down), so they are the same height above the floor on ladders of any height (its
	-- root is at its top, see Physical ladder); else on the thing's skeletal mesh (a spot on one of its bones moves with it), or on
	-- its root when it has none (the doors that won't open are only a prompt trigger in front of a static door). The well's
	-- skeletal mesh is SK_Env_AF_Well_001.
	getAccessoryComponent = function(actor)
		return uevrUtils.getValid(actor, {"Ladder_Down"}) or uevrUtils.getValid(actor, {"SkeletalMesh"})
			or uevrUtils.getValid(actor, {"SK_Env_AF_Well_001"}) or uevrUtils.getValid(actor, {"RootComponent"})
	end,
})

-- Every mechanism made from a saved entry (doors, ladders, ...).
function M.setPhysicalEntriesEnabled(value)
	mechanisms.setEntriesEnabled(value == true)
end

M.setPhysicalEntriesEnabled(true)

-- The config UI's Physical Interactions: off, libs/mechanisms does nothing at all.
function M.setPhysicalInteractionsEnabled(value)
	status.interactionsEnabled = value == true
	mechanisms.setActive(status.interactionsEnabled)
end

-- Scan optimize: mechanisms not in use only look for their actors while the game shows a prompt or the adapter's isScanNeeded
-- says so. Set false if a
-- door, log bundle or ladder is found late or not at all.
local scanOptimize = true
mechanisms.setScanOptimize(scanOptimize)
------------------- End mechanisms made in the config UI -------------------

return M
