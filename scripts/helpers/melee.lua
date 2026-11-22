local uevrUtils = require('libs/uevr_utils')
local attachments = require('libs/attachments')
local gestures = require('libs/gestures')
local plugin = require('libs/core/plugin')
local ui = require('libs/ui')

local M = {}
local ATTACK_ID = 22100 -- Separate from the animation notify's attack IDs.
local RADIUS_RATIO = 0.25 -- Keep the native capsule length, narrow its contact radius.
-- Native traces whose sphere around a character-mesh socket stands in for a long body part. The large claw's
-- ClawG_Default is 40 cm around hand_large_r; narrowed by RADIUS_RATIO it reaches none of the claw. Its capsule runs
-- along the VR hand mesh instead, from the wrist to the middle fingertip (53 cm); a 12 cm radius takes in the index
-- and ring fingertips. Keyed by trace family.
local REACH_CAPSULES = {ClawG = {base = 'hand_large_r', tip = 'middle_04_large_r', radius = 12}}
local MAX_FRAME_DELTA = 0.1
local MAX_POSE_STEP = 100 -- cm; reject tracking jumps and teleports.
local TRIGGER_THRESHOLD = 30 -- XInput's standard trigger dead zone.
local state = {}
local configurationCache = {}
local noOwnRecords = {} -- weapon names found to have no records of their own (see configureWeapon)
-- Input edges survive weapon/configuration resets; a held button is not a new press.
local controls = {rbDown = false, rtDown = false, heavyHeld = false}
local enabled = true
local library
local characterClass
local bodyPartData = {} -- enemy body-part data, per data asset address (see resolveBodyPart)
local HIT_OUTPUTS = {'OutHits.Component', 'OutHits.ImpactPoint', 'OutHits.Time', 'OutHits.BoneName'}
local WEAPON_PATH, MESH_PATH, TRACE_PATH = {'CurrentWeapon'}, {'WeaponMesh'}, {'NoceAttackTrace'}
local ANIM_PATH = {'PlayerAnimInstance'}

local function clearHitStop(character)
    local time = uevrUtils.getValid(character, {'NoceTime'})
    if time ~= nil and time:IsDuringHitStopTimer() then
        time:OnHitStopTimerUp()
    end
end

local function endSwing(preserveNativeAttack)
    local trace = uevrUtils.getValid(state.activeTrace)
    state.activeTrace = nil
    state.hitActors = nil
    if trace ~= nil then
        trace:EndTraceByAttackID(ATTACK_ID)
        if not preserveNativeAttack then trace:SetIsDuringAttack(false) end
    end
end
endSwing = uevrUtils.profiler:wrap('MELEE: endSwing', endSwing)

local function reset()
    endSwing(controls.nativeBusy)
    state = {}
    controls.focusReady, controls.counterReady, controls.specialPending = false, false, false
    controls.passRB, controls.passRT = false, false
end

local function resetLevel()
    reset()
    configurationCache, noOwnRecords, bodyPartData = {}, {}, {}
    library, characterClass = nil, nil
end

function M.setEnabled(value)
    enabled = value == true
    if not enabled then reset() end
end

local function isGameplayActive()
    return enabled and not uevrUtils.isGamePaused()
        and not uevrUtils.isInCutscene() and not ui.isInputDisabled()
end

function M.beginSwing()
    if isGameplayActive() and not controls.nativeBusy and not controls.specialPending then
        state.windowOpen = true
        state.swingHeavy = controls.heavyHeld
    end
end

function M.endSwing()
    state.windowOpen = false
    endSwing(controls.nativeBusy)
end

local function getHeldWeapon(player)
    local weapon = uevrUtils.getValid(player, WEAPON_PATH)
    local mesh = uevrUtils.getValid(weapon, MESH_PATH)
    local held = attachments.getCurrentGrippedAttachment(Handed.Right)
    if weapon == nil or mesh == nil or held == nil or mesh:get_address() ~= held:get_address() then return nil end
    if not weapon:IsVisible() or weapon:IsBroken() then return nil end
    return weapon, mesh
end
getHeldWeapon = uevrUtils.profiler:wrap('MELEE: getHeldWeapon', getHeldWeapon)

-- A family's configuration made earlier for the same combo data and trace: true or false as configureWeapon returns,
-- or nil when there is none.
local function applyCachedConfiguration(family, mesh, dataAddress, traceAddress)
    local cached = configurationCache[family]
    if cached == nil or cached.dataAddress ~= dataAddress or cached.traceAddress ~= traceAddress then return nil end
    if cached.config.socket ~= nil and not mesh:DoesSocketExist(cached.config.socket) then return false end
    for key, value in pairs(cached.config) do state[key] = value end
    return true
end

-- A family's trace and light combo records (<family>_Default, <family>_ComboL), or nil. Read only these records; the
-- full combo map contains every weapon.
local function readRecords(trace, data, family)
    local settings = plugin.getProperty(trace, 'AttackTraceInfoMap[' .. family .. '_Default]')
    if settings == nil then return nil end
    local combo = plugin.getProperty(data, 'PlayerComboSettingMap[' .. family .. '_ComboL]')
    if combo == nil then return nil end
    return settings, combo
end

local function configureWeapon(player, weapon, mesh, trace)
    local data = uevrUtils.getValid(player, {'NocePlayerAttackInfo', 'PlayerComboDataAsset'})
    if data == nil then return false end
    local dataAddress, traceAddress = data:get_address(), trace:get_address()
    -- A weapon with records under its own name uses them: the large claw (WeaponName ClawG) is the fox arm's weapon, with
    -- its CounterComboName (Claw_ComboCounter), but has ClawG_Default and ClawG_ComboL. Other weapons use their motion
    -- family's records (e.g. Pipe_ComboL / Pipe_Default).
    local name = weapon.WeaponName:to_string()
    local motionFamily = weapon.CounterComboName:to_string():match('^([^_]+)_')
    local family, settings, combo = nil, nil, nil
    if not noOwnRecords[name] then
        local applied = applyCachedConfiguration(name, mesh, dataAddress, traceAddress)
        if applied ~= nil then return applied end
        settings, combo = readRecords(trace, data, name)
        if settings ~= nil then family = name else noOwnRecords[name] = true end
    end
    if family == nil then
        if motionFamily == nil then return false end
        local applied = applyCachedConfiguration(motionFamily, mesh, dataAddress, traceAddress)
        if applied ~= nil then return applied end
        family = motionFamily
        settings, combo = readRecords(trace, data, family)
    end
    if settings == nil then
        uevrUtils.print('[melee] No native melee settings for ' .. name, LogLevel.Warning)
        return false
    end
    local traceName = family .. '_Default'
    local comboName, heavyName = family .. '_ComboL', family .. '_ComboH'

    -- Body-part weapons (the claw) trace from a character-mesh socket and their weapon mesh is
    -- empty. The grip attaches that mesh to the VR hand socket, so its own transform is the pose.
    local socket = nil
    if settings.UseSocketInWeapon then
        socket = uevrUtils.fname_from_string(settings.Socket)
        if not mesh:DoesSocketExist(socket) then return false end
    end
    local config = {socket = socket, traceName = uevrUtils.fname_from_string(traceName),
        comboName = uevrUtils.fname_from_string(comboName), comboString = comboName, combo = combo,
        radius = settings.Radius * RADIUS_RATIO, halfHeight = settings.HalfHeight,
        objectTypes = plugin.getProperty(trace, 'ObjectTypes'),
        traceChannel = trace.ECollisionQueryChannel, skipTag = trace.SkipAttackTraceTag}
    local reach = REACH_CAPSULES[family]
    if reach ~= nil then
        config.reach = {base = uevrUtils.fname_from_string(reach.base), tip = uevrUtils.fname_from_string(reach.tip)}
        config.radius = reach.radius
    end
    config.light = {combo = combo, name = config.comboName, text = comboName,
        stamina = uevrUtils.fname_from_string(family == 'Pipe' and 'Pipe_LightAttack_1' or comboName), input = 1}
    local heavyCombo = plugin.getProperty(data, 'PlayerComboSettingMap[' .. heavyName .. ']')
    if heavyCombo ~= nil then
        config.heavy = {combo = heavyCombo, name = uevrUtils.fname_from_string(heavyName), text = heavyName,
            stamina = uevrUtils.fname_from_string(family == 'Pipe' and 'Pipe_HeavyAttack' or heavyName), input = 2}
    end
    local environmentTypes = plugin.getProperty(trace, 'EnvironmentObjectTypes')
    if type(config.objectTypes) ~= 'table' or type(environmentTypes) ~= 'table' then return false end
    for _, value in ipairs(environmentTypes) do table.insert(config.objectTypes, value) end
    library = uevrUtils.getValid(library) or uevrUtils.find_default_instance('Class /Script/GameNoce.NoceFunctionLibrary')
    characterClass = uevrUtils.getValid(characterClass) or uevrUtils.get_class('Class /Script/GameNoce.NoceCharacter')
    if library == nil or characterClass == nil then return false end
    configurationCache[family] = {dataAddress = dataAddress, traceAddress = traceAddress, config = config}
    for key, value in pairs(config) do state[key] = value end
    return true
end
configureWeapon = uevrUtils.profiler:wrap('MELEE: configureWeapon', configureWeapon)

local function hitComponent(reference)
    if type(reference) == 'userdata' then return uevrUtils.getValid(reference) end
    if type(reference) == 'table' then reference = reference.address or reference.value end
    if type(reference) == 'string' then reference = tonumber(reference) end
    if type(reference) == 'number' and reference > 0 then
        return uevrUtils.getValid(uevr.api:to_uobject(reference))
    end
end

-- The bone of the first contact from index `from` on that hit the target. The sweep often reaches the capsule (no bone)
-- before the mesh.
local function contactBone(ordered, from, address)
    for i = from, #ordered do
        local hit = ordered[i].hit
        if hit.BoneName ~= nil and hit.BoneName ~= 'None' then
            local component = hitComponent(hit.Component)
            local owner = component and uevrUtils.getValid(component:GetOwner())
            if owner ~= nil and owner:get_address() == address then return hit.BoneName end
        end
    end
end

-- An enemy's body-part data asset, read once. Bone keys are lowercased: the game compares FNames, which ignore case
-- (the map's "Head" is the mesh's "head").
local function assetData(asset, read)
    local address = asset:get_address()
    if bodyPartData[address] == nil then bodyPartData[address] = read(asset) end
    return bodyPartData[address]
end

local function readBoneMap(mapping)
    local bones = {}
    for bone, entry in pairs(plugin.getProperty(mapping, 'BoneNameBodyPartMap') or {}) do
        bones[string.lower(bone)] = entry.BodyPart
    end
    return bones
end

-- The body part and group a contact hits, chosen as the game's hit processing chooses them: the hit bone, or its nearest
-- listed parent, gives the part; the highest-Priority active group listing that part wins. A group listing only part 0
-- takes any part, and a CheckAngle group needs the hit angle inside its range. Returns part, group name, group record.
local function resolveBodyPart(target, bone, angle)
    local component = uevrUtils.getValid(target, {'BodyPartGroupComponent'})
    local groupAsset = component and uevrUtils.getValid(component.BodyPartGroup)
    if groupAsset == nil then return 0 end
    local part = 0
    local mapping, mesh = uevrUtils.getValid(component.BoneNameToBodyPartMapping), uevrUtils.getValid(target.Mesh)
    if mapping ~= nil then
        local bones = assetData(mapping, readBoneMap)
        while bone ~= nil and bone ~= 'None' do
            local found = bones[string.lower(bone)]
            if found ~= nil then part = found; break end
            bone = mesh and mesh:GetParentBone(uevrUtils.fname_from_string(bone)):to_string()
        end
    end
    local records = assetData(groupAsset, function() return {} end)
    local bestName, best = nil, nil
    for _, name in ipairs(plugin.getProperty(component, 'ActiveBodyPartGroups') or {}) do
        if records[name] == nil then records[name] = plugin.getProperty(groupAsset, 'BodyPartGroupMap[' .. name .. ']') or false end
        local group = records[name]
        if group then
            local parts = group.BodyParts or {}
            local matches = #parts == 1 and parts[1] == 0
            for _, listed in ipairs(parts) do matches = matches or listed == part end
            if matches and (best == nil or group.Priority > best.Priority) and (not group.CheckAngle
                or (angle >= group.AngleSetting.MinAngle and angle <= group.AngleSetting.MaxAngle)) then
                bestName, best = name, group
            end
        end
    end
    return part, bestName, best
end
resolveBodyPart = uevrUtils.profiler:wrap('MELEE: resolveBodyPart', resolveBodyPart)

-- A factor drawn uniformly from 1 - rate to 1 + rate, the game's damage spread.
local function spread(rate)
    return 1 - rate + math.random() * 2 * rate
end

-- Health and wince damage of one contact, as the game's native hit processing computes them (traced in
-- SHf-Win64-Shipping.exe 2026-11-22: health at RVA 0x4C6F250, wince at 0x4C6FD50). The cheat manager's ratios are
-- left out; the shipping game has no cheat manager, so they are 1.
local function contactDamage(player, target, weapon, attack, group)
    local combo, values = state.combo, state.values
    local bodyDamage, bodyWince = 1, 1
    if group then bodyDamage, bodyWince = group.DamageMultiplier, group.WinceMultiplier end
    local health = (values.Attack * bodyDamage * attack.AttackMultiplier
        + (values.ExtraAttack + player:GetExtraAttack()) * attack.ExtraAttackMultiplier)
        * player:GetAttack() * spread(combo.AttackFloatRate) * player:GetFocusAttackRatioHealth()
    if target.IsBreakDown ~= nil and target:IsBreakDown() then health = health * player:GetEnemyBreakDownAttackRatio() end
    -- This contact broke the weapon: the native trace earlier in the tick charged its durability to 0.
    if weapon:GetCanBeBroken() and weapon:GetDurability() <= 0 and player:IsWeaponBreakForceKnockBack() then
        health = health * player:GetWeaponBreakAttackRatio()
    end
    local wince = (values.Wince * bodyWince * attack.WinceMultiplier + values.ExtraWince)
        * spread(combo.WinceFloatRate) * player:GetWince() * player:GetFocusAttackRatioWince()
    return health, wince
end
contactDamage = uevrUtils.profiler:wrap('MELEE: contactDamage', contactDamage)

local function damageContacts(player, weapon, previous, pose, attack)
    local ignored = {player, weapon}
    -- VR hands live on a separate actor, unlike the game's own character mesh.
    local parent = uevrUtils.getValid(weapon.WeaponMesh:GetAttachParent())
    local handActor = parent and uevrUtils.getValid(parent:GetOwner())
    if handActor ~= nil then ignored[#ignored + 1] = handActor end
    -- Keep FHitResult native: reconstructing its weak references in Lua loses body/bone data.
    local result = plugin.executeFunctionWithHandle(library, 'CapsuleTraceMultiForObjects', 'OutHits', HIT_OUTPUTS,
        player, previous.location, pose.location, state.radius, pose.halfHeight or state.halfHeight, pose.rotation,
        state.objectTypes, false, ignored, 0, {}, true, {}, {}, 0)
    if result == nil then return end
    if type(result.handle) ~= 'number' or type(result.OutHits) ~= 'table' then
        plugin.releaseHandle(result.handle)
        return
    end
    local ok, err = pcall(function()
        -- Preserve indices into the native array while visiting contacts in sweep order.
        local ordered = {}
        for index, hit in ipairs(result.OutHits) do
            ordered[#ordered + 1] = {index = index, hit = hit}
        end
        table.sort(ordered, function(a, b) return (a.hit.Time or 0) < (b.hit.Time or 0) end)
        for position, contact in ipairs(ordered) do
            local component = hitComponent(contact.hit.Component)
            local target = component and uevrUtils.getValid(component:GetOwner())
            if component ~= nil and target ~= nil and target:get_address() ~= player:get_address()
                and target:get_address() ~= weapon:get_address() then
                local skip = target:ActorHasTag(state.skipTag) or component:ComponentHasTag(state.skipTag)
                if skip then goto nextContact end
                if not target:is_a(characterClass) then
                    -- Object traces also return overlaps/ignored collision responses. Only
                    -- geometry that blocks the game's attack channel can stop the weapon.
                    if component:GetCollisionResponseToChannel(state.traceChannel) == 2 then break end
                    goto nextContact
                end
                local address = target:get_address()
                if not state.hitActors[address] then
                    state.hitActors[address] = true
                    local dx = pose.location.X - previous.location.X
                    local dy = pose.location.Y - previous.location.Y
                    local dz = pose.location.Z - previous.location.Z
                    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
                    local point = contact.hit.ImpactPoint
                    local angle = library:CalculateDamageDirectionAngle(target, uevrUtils.vector(point))
                    local part, groupName, group = resolveBodyPart(target, contactBone(ordered, position, address), angle)
                    local health, wince = contactDamage(player, target, weapon, attack, group)
                    plugin.executeFunctionWithOutputs(target, 'OnDamaged', {}, {
                        Instigator = player,
                        HitResult = plugin.handleParam(result.handle, nil, contact.index),
                        ComboName = state.comboString,
                        Angle = angle,
                        BodyPart = part,
                        BodyPartGroup = groupName or 'None',
                        CloseHitLocation = point,
                        AttackDirection = length > 0 and {X = dx / length, Y = dy / length, Z = dz / length}
                            or {X = 0, Y = 0, Z = 0},
                        HealthDamage = health,
                        WinceDamage = wince,
                        WinceType = state.combo.WinceType,
                        IsForceWince = state.combo.IsForceWince,
                        IsInvertWinceDirection = state.combo.IsInvertWinceDirection,
                        WeaponName = weapon.WeaponName:to_string(),
                        WeaponMotionType = weapon:GetWeaponMotionType(),
                    })
                    -- Vanilla hit stop nearly freezes the enemy for 200 ms. A physical VR
                    -- weapon keeps moving, so let the native reaction proceed immediately.
                    clearHitStop(target)
                end
            end
            ::nextContact::
        end
    end)
    plugin.releaseHandle(result.handle)
    -- Once per swing: a failure here would otherwise repeat every tick of the swing.
    if not ok and not state.reportedError then
        state.reportedError = true
        uevr.params.functions.log_error('[melee] contact processing failed: ' .. tostring(err))
    end
end
damageContacts = uevrUtils.profiler:wrap('MELEE: damageContacts', damageContacts)

-- The reach capsule (see REACH_CAPSULES) on the VR hand mesh the weapon mesh is gripped to: centred between the wrist
-- and the fingertip, with its axis (the capsule's Z) along them.
local function getReachPose(mesh)
    local hand = uevrUtils.getValid(mesh:GetAttachParent())
    if hand == nil then return nil end
    -- The hands are rebuilt when the arm form changes, under the same weapon mesh.
    local address = hand:get_address()
    if state.reachHand ~= address then
        state.reachHand = address
        state.reachHandValid = hand:DoesSocketExist(state.reach.base) and hand:DoesSocketExist(state.reach.tip)
    end
    if not state.reachHandValid then return nil end
    -- Copy each returned struct before the next call.
    local base = hand:GetSocketLocation(state.reach.base)
    local bx, by, bz = base.X, base.Y, base.Z
    local tip = hand:GetSocketLocation(state.reach.tip)
    local dx, dy, dz = tip.X - bx, tip.Y - by, tip.Z - bz
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length <= 0 then return nil end
    -- Pitching a rotator 90 degrees down puts its Z axis where its X axis pointed.
    return {
        location = {X = bx + dx * 0.5, Y = by + dy * 0.5, Z = bz + dz * 0.5},
        rotation = {Pitch = math.deg(math.asin(dz / length)) - 90, Yaw = math.deg(math.atan(dy, dx)), Roll = 0},
        halfHeight = length * 0.5 + state.radius,
    }
end

local function getPose(mesh)
    if state.reach ~= nil then
        local pose = getReachPose(mesh)
        if pose ~= nil then return pose end
    end
    local location, rotation
    if state.socket ~= nil then
        location = mesh:GetSocketLocation(state.socket)
        rotation = mesh:GetSocketRotation(state.socket)
    else
        -- No socket in the weapon mesh: the mesh itself sits on the hand socket (see configureWeapon).
        location = mesh:K2_GetComponentLocation()
        rotation = mesh:K2_GetComponentRotation()
    end
    -- Copy values: Unreal's returned structs must not be retained between ticks.
    return {
        location = {X = location.X, Y = location.Y, Z = location.Z},
        rotation = {Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = rotation.Roll},
    }
end
getPose = uevrUtils.profiler:wrap('MELEE: getPose', getPose)

local function checkNativeAttack(player)
    -- The broad attack-state flag can be true while idle and accepting attacks.
    -- Only native special attacks take ownership of the physical swing window.
    return player:InCounterState() or player:InFocusAttack()
end
checkNativeAttack = uevrUtils.profiler:wrap('MELEE: checkNativeAttack', checkNativeAttack)

local function checkFocusReady(player, weapon)
    return player:IsUsingFocus() and player:InFocusCharged() and weapon:GetCanFocusAttack()
end
checkFocusReady = uevrUtils.profiler:wrap('MELEE: checkFocusReady', checkFocusReady)

local function checkCounterReady(player)
    return player:HaveCounterTarget(false)
end
checkCounterReady = uevrUtils.profiler:wrap('MELEE: checkCounterReady', checkCounterReady)

local function updateCombatState(player, weapon)
    -- Read UObject state on the game thread. The input callback only consumes cached flags.
    controls.nativeBusy = checkNativeAttack(player)
    -- The input route requires LT, so there is no focus input to accept without it.
    controls.focusReady = controls.focusHeld and checkFocusReady(player, weapon) or false
    controls.counterReady = checkCounterReady(player)
end
updateCombatState = uevrUtils.profiler:wrap('MELEE: updateCombatState', updateCombatState)

local function update(delta)
    local player = uevrUtils.getValid(uevr.api:get_local_pawn(0))
    if not isGameplayActive() or player == nil or delta <= 0 or delta > MAX_FRAME_DELTA then
        reset()
        return
    end
    if player.GetIsInEvent == nil or player.IsInteracting == nil
        or player:GetIsInEvent() or player:IsInteracting() then
        reset()
        return
    end
    local weapon, mesh = getHeldWeapon(player)
    local trace = uevrUtils.getValid(player, TRACE_PATH)
    if weapon == nil or trace == nil or not trace:GetIsEnable() then
        reset()
        return
    end

    local playerAddress, weaponAddress = player:get_address(), weapon:get_address()
    local meshAddress, traceAddress = mesh:get_address(), trace:get_address()
    -- The claw keeps its weapon between forms; only its name changes (Claw / ClawG, see configureWeapon).
    local weaponName = weapon.WeaponName:to_string()
    if state.playerAddress ~= playerAddress or state.weaponAddress ~= weaponAddress
        or state.meshAddress ~= meshAddress or state.traceAddress ~= traceAddress or state.weaponName ~= weaponName then
        -- Gesture begin can arrive before the first weapon configuration.
        local opening = state.weaponAddress == nil and state.windowOpen
        local heavy = state.swingHeavy
        reset()
        state.playerAddress, state.weaponAddress, state.weaponName = playerAddress, weaponAddress, weaponName
        state.meshAddress, state.traceAddress = meshAddress, traceAddress
        state.configured = configureWeapon(player, weapon, mesh, trace)
        state.windowOpen = opening
        state.swingHeavy = heavy
    end
    if not state.configured then return end

    updateCombatState(player, weapon)
    if controls.nativeBusy or controls.specialPending then
        controls.specialPending = false
        state.windowOpen = false
        state.previous = nil
        -- End only our trace ID; a vanilla attack may already own the shared attack flag.
        endSwing(controls.nativeBusy)
        return
    end

    local pose = getPose(mesh)
    local previous = state.previous
    state.previous = pose
    if previous == nil then return end
    local dx = pose.location.X - previous.location.X
    local dy = pose.location.Y - previous.location.Y
    local dz = pose.location.Z - previous.location.Z
    if dx * dx + dy * dy + dz * dz > MAX_POSE_STEP * MAX_POSE_STEP then return end
    if not state.windowOpen then return end

    if state.activeTrace == nil then
        -- A heavy swing with no heavy combo is rejected, not played as a light one.
        local selected
        if state.swingHeavy then selected = state.heavy else selected = state.light end
        if selected == nil or not player:CanAccepInputActionAttack(false)
            or not player:CanAcceptInputByStaminaStatus(selected.input) then
            state.windowOpen = false
            return
        end
        state.combo, state.comboName, state.comboString = selected.combo, selected.name, selected.text
        -- The weapon's own record replaces the combo's attack and wince values, as in the native damage code. Bridge:
        -- native UEVR Lua returns none of this function's out parameters (nil, nil, nil when probed 2026-11-22).
        state.values = selected.combo
        local override = plugin.executeFunction(weapon, 'GetOverrideComboInfo', selected.text, false, {})
        if override ~= nil and override.OutFound then state.values = override.OutComboInfo end
        local stamina = uevrUtils.getValid(player, {'NocePlayerStamina'})
        if stamina ~= nil then stamina:CostStamina(selected.stamina) end
        -- Native attack ID state prevents repeated damage while a swing stays in contact.
        trace:SetIsDuringAttack(true)
        trace:StartTraceByAttackID(ATTACK_ID)
        state.activeTrace = trace
        state.hitActors = {}
        state.reportedError = false
    end
    local attack = plugin.executeFunction(weapon, 'GetAttackInfo', weapon:GetDurability(), 0, 0, 0)
    if attack == nil then return end
    -- Native trace retains durability, environment contact and deflection handling.
    -- OnDeflect also queues an animated recoil when a weapon breaks. Physical melee
    -- has no animation attack state to finish that recoil, so retain the pre-trace request.
    local anim = uevrUtils.getValid(player, ANIM_PATH)
    local previousType = anim and anim.AnimStateType
    local previousAttack = anim and anim.CanEnterAttack
    trace:DoTraceByAttackID(ATTACK_ID, state.comboName, state.traceName,
        uevrUtils.vector(previous.location), uevrUtils.rotator(previous.rotation),
        uevrUtils.vector(pose.location), uevrUtils.rotator(pose.rotation), RADIUS_RATIO)
    if anim ~= nil and anim.CanEnterAttack then
        local queuedType = anim.AnimStateType
        if (queuedType == 7 or queuedType == 8) -- Deflect_L / Deflect_H
            and (queuedType ~= previousType or not previousAttack) then
            anim.AnimStateType, anim.CanEnterAttack = previousType, previousAttack
        end
    end
    -- The game applies damage only to hits of its own attack notifies' traces. Forward real physical contacts to the
    -- same character damage entry point, with the damage its native hit processing would compute (contactDamage).
    damageContacts(player, weapon, previous, pose, attack)
    clearHitStop(player)
end
update = uevrUtils.profiler:wrap('MELEE: update', update)

-- Gesture callbacks own the window, as in DI2/FK. Physical contacts inside it
-- drive native damage; neither window boundary waits for an attack animation.
gestures.registerSwingBeginCallback(function(_, hand)
    if hand == Handed.Right then M.beginSwing() end
end, true, false)

gestures.registerSwingEndCallback(function(_, hand)
    if hand == Handed.Right then M.endSwing() end
end, true, false)

-- Use the weapon's updated socket pose after the engine tick.
uevr.sdk.callbacks.on_post_engine_tick(function(_, delta)
    update(delta)
end)

local function updateInput(_, _, inputState)
    local rbDown = uevrUtils.isButtonPressed(inputState, XINPUT_GAMEPAD_RIGHT_SHOULDER)
    local rtDown = inputState.Gamepad.bRightTrigger > TRIGGER_THRESHOLD
    local rbPressed, rtPressed = rbDown and not controls.rbDown, rtDown and not controls.rtDown
    controls.rbDown, controls.rtDown, controls.heavyHeld = rbDown, rtDown, rtDown
    controls.focusHeld = (inputState.Gamepad.bLeftTrigger or 0) > TRIGGER_THRESHOLD
    if not rbDown then controls.passRB = false end
    if not rtDown then controls.passRT = false end
    -- Releases are already represented by the raw input. Idle input needs no UObject reads.
    if not rbDown and not rtDown then return end
    if not isGameplayActive() or state.configured ~= true then
        controls.passRB, controls.passRT = false, false
        return
    end
    local player = uevr.api:get_local_pawn(0)
    local held = attachments.getCurrentGrippedAttachment(Handed.Right)
    if player == nil or player:get_address() ~= state.playerAddress
        or held == nil or held:get_address() ~= state.meshAddress then
        controls.passRB, controls.passRT = false, false
        return
    end
    -- Recheck entry conditions on a new press, not on every held-input sample.
    if rbPressed or rtPressed then
        local weapon = getHeldWeapon(player)
        if player.GetIsInEvent == nil or player.IsInteracting == nil
            or player:GetIsInEvent() or player:IsInteracting()
            or weapon == nil or weapon:get_address() ~= state.weaponAddress then
            controls.passRB, controls.passRT = false, false
            return
        end
    end
    if rbPressed then
        controls.passRB = controls.focusReady and (inputState.Gamepad.bLeftTrigger or 0) > TRIGGER_THRESHOLD
        if controls.passRB then controls.specialPending = true; state.windowOpen = false end
    end
    if rtPressed then
        controls.passRT = controls.counterReady
        if controls.passRT then controls.specialPending = true; state.windowOpen = false end
    end
    -- Preserve each accepted vanilla press/hold/release. Holding a suppressed button
    -- as readiness changes must never manufacture another rising edge.
    if not controls.passRB then uevrUtils.unpressButton(inputState, XINPUT_GAMEPAD_RIGHT_SHOULDER) end
    if not controls.passRT then inputState.Gamepad.bRightTrigger = 0 end
end
updateInput = uevrUtils.profiler:wrap('MELEE: updateInput', updateInput)
uevrUtils.registerOnPostInputGetStateCallback(updateInput)

uevrUtils.registerPreLevelChangeCallback(resetLevel)
uevr.params.sdk.callbacks.on_script_reset(resetLevel)

return M
