local uevrUtils = require('libs/uevr_utils')
local attachments = require('libs/attachments')
local gestures = require('libs/gestures')
local plugin = require('libs/core/plugin')
local ui = require('libs/ui')

local M = {}
local ATTACK_ID = 22100 -- Separate from the animation notify's attack IDs.
local RADIUS_RATIO = 0.25 -- Keep the native capsule length, narrow its contact radius.
local MAX_FRAME_DELTA = 0.1
local MAX_POSE_STEP = 100 -- cm; reject tracking jumps and teleports.
local TRIGGER_THRESHOLD = 30 -- XInput's standard trigger dead zone.
local state = {}
local configurationCache = {}
-- Input edges survive weapon/configuration resets; a held button is not a new press.
local controls = {rbDown = false, rtDown = false, heavyHeld = false}
local enabled = true
local library
local characterClass
local stats = {swings = 0, contacts = 0, damageCalls = 0}
local HIT_OUTPUTS = {'OutHits.Component', 'OutHits.ImpactPoint', 'OutHits.Time'}
local WEAPON_PATH, MESH_PATH, TRACE_PATH = {'CurrentWeapon'}, {'WeaponMesh'}, {'NoceAttackTrace'}
local diagnosticBudget = 24 -- Bounded logging for the next physical-contact test.

local function diagnostic(message)
    if diagnosticBudget <= 0 then return end
    diagnosticBudget = diagnosticBudget - 1
    uevr.params.functions.log_info('[melee] ' .. message)
end

local function clearHitStop(character)
    local time = uevrUtils.getValid(character, {'NoceTime'})
    if time ~= nil and time:IsDuringHitStopTimer() then
        time:OnHitStopTimerUp()
    end
end

local function endSwing(preserveNativeAttack)
    local trace = uevrUtils.getValid(state.activeTrace)
    if trace ~= nil then
        diagnostic('swing ended; sweeps=' .. (state.sweeps or 0) .. ' contacts=' .. stats.contacts
            .. ' damageCalls=' .. stats.damageCalls)
    end
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
    configurationCache = {}
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
    if mesh == nil or held == nil or mesh:get_address() ~= held:get_address() then return end
    if not weapon:IsVisible() or weapon:IsBroken() then return end
    return weapon, mesh
end
getHeldWeapon = uevrUtils.profiler:wrap('MELEE: getHeldWeapon', getHeldWeapon)

local function configureWeapon(player, weapon, mesh, trace)
    -- Motion families share native combo/trace names (e.g. Pipe_ComboL / Pipe_Default).
    local family = weapon.CounterComboName:to_string():match('^([^_]+)_')
    local traceName = family and (family .. '_Default')
    local data = uevrUtils.getValid(player, {'NocePlayerAttackInfo', 'PlayerComboDataAsset'})
    if family == nil or data == nil then return false end
    local dataAddress, traceAddress = data:get_address(), trace:get_address()
    local cached = configurationCache[family]
    if cached ~= nil and cached.dataAddress == dataAddress and cached.traceAddress == traceAddress then
        if not mesh:DoesSocketExist(cached.config.socket) then return false end
        for key, value in pairs(cached.config) do state[key] = value end
        return true
    end

    local comboName, heavyName = family .. '_ComboL', family .. '_ComboH'
    -- Read only this family's records; the full combo map contains every weapon.
    local settings = plugin.getProperty(trace, 'AttackTraceInfoMap[' .. traceName .. ']')
    local combo = plugin.getProperty(data, 'PlayerComboSettingMap[' .. comboName .. ']')
    if settings == nil or combo == nil or not settings.UseSocketInWeapon then
        uevrUtils.print('[melee] No native melee settings for ' .. weapon.WeaponName:to_string(), LogLevel.Warning)
        return false
    end

    local socket = uevrUtils.fname_from_string(settings.Socket)
    if not mesh:DoesSocketExist(socket) then return false end
    local config = {socket = socket, traceName = uevrUtils.fname_from_string(traceName),
        comboName = uevrUtils.fname_from_string(comboName), comboString = comboName, combo = combo,
        radius = settings.Radius * RADIUS_RATIO, halfHeight = settings.HalfHeight,
        objectTypes = plugin.getProperty(trace, 'ObjectTypes'),
        traceChannel = trace.ECollisionQueryChannel, skipTag = trace.SkipAttackTraceTag}
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
    diagnostic('ready: ' .. comboName .. ' socket=' .. settings.Socket)
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

local function damageContacts(player, weapon, previous, pose, damage)
    local ignored = {player, weapon}
    -- VR hands live on a separate actor, unlike the game's own character mesh.
    local parent = uevrUtils.getValid(weapon.WeaponMesh:GetAttachParent())
    local handActor = parent and uevrUtils.getValid(parent:GetOwner())
    if handActor ~= nil then ignored[#ignored + 1] = handActor end
    -- Keep FHitResult native: reconstructing its weak references in Lua loses body/bone data.
    local result = plugin.executeFunctionWithHandle(library, 'CapsuleTraceMultiForObjects', 'OutHits', HIT_OUTPUTS,
        player, previous.location, pose.location, state.radius, state.halfHeight, pose.rotation,
        state.objectTypes, false, ignored, 0, {}, true, {}, {}, 0)
    state.sweeps = (state.sweeps or 0) + 1
    if result == nil then
        if not state.reportedTraceError then
            state.reportedTraceError = true
            diagnostic('capsule trace returned no bridge response')
        end
        return
    end
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
        for _, contact in ipairs(ordered) do
            local component = hitComponent(contact.hit.Component)
            local target = component and uevrUtils.getValid(component:GetOwner())
            if target ~= nil and target:get_address() ~= player:get_address()
                and target:get_address() ~= weapon:get_address() then
                local skip = target:ActorHasTag(state.skipTag) or component:ComponentHasTag(state.skipTag)
                if skip then goto nextContact end
                if not target:is_a(characterClass) then
                    -- Object traces also return overlaps/ignored collision responses. Only
                    -- geometry that blocks the game's attack channel can stop the weapon.
                    local blocking = component:GetCollisionResponseToChannel(state.traceChannel) == 2
                    if not state.reportedObstacle then
                        state.reportedObstacle = true
                        diagnostic('environment contact: ' .. target:get_full_name() .. ' blocking=' .. tostring(blocking))
                    end
                    if blocking then break end
                    goto nextContact
                end
                local address = target:get_address()
                if not state.hitActors[address] then
                    state.hitActors[address] = true
                    stats.contacts = stats.contacts + 1
                    local dx = pose.location.X - previous.location.X
                    local dy = pose.location.Y - previous.location.Y
                    local dz = pose.location.Z - previous.location.Z
                    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
                    local point = contact.hit.ImpactPoint
                    local angle = library:CalculateDamageDirectionAngle(target, uevrUtils.vector(point))
                    local healthBefore = target:GetHealth()
                    local damageStart = os.clock()
                    local applied = plugin.executeFunctionWithOutputs(target, 'OnDamaged', {}, {
                        Instigator = player,
                        HitResult = plugin.handleParam(result.handle, nil, contact.index),
                        ComboName = state.comboString,
                        Angle = angle,
                        CloseHitLocation = point,
                        AttackDirection = length > 0 and {X = dx / length, Y = dy / length, Z = dz / length}
                            or {X = 0, Y = 0, Z = 0},
                        HealthDamage = damage.health,
                        WinceDamage = damage.wince,
                        WinceType = state.combo.WinceType,
                        IsForceWince = state.combo.IsForceWince,
                        IsInvertWinceDirection = state.combo.IsInvertWinceDirection,
                        WeaponName = weapon.WeaponName:to_string(),
                        WeaponMotionType = weapon:GetWeaponMotionType(),
                    })
                    if applied ~= nil then stats.damageCalls = stats.damageCalls + 1 end
                    -- Vanilla hit stop nearly freezes the enemy for 200 ms. A physical VR
                    -- weapon keeps moving, so let the native reaction proceed immediately.
                    clearHitStop(target)
                    diagnostic(string.format('damage: %s health=%.1f->%.1f call_ms=%.3f dilation=%.3f',
                        target:get_full_name(), healthBefore, target:GetHealth(),
                        (os.clock() - damageStart) * 1000, target.CustomTimeDilation))
                end
            end
            ::nextContact::
        end
    end)
    plugin.releaseHandle(result.handle)
    if not ok and not state.reportedError then
        state.reportedError = true
        diagnostic('contact processing failed: ' .. tostring(err))
    end
end
damageContacts = uevrUtils.profiler:wrap('MELEE: damageContacts', damageContacts)

local function getPose(mesh)
    local location = mesh:GetSocketLocation(state.socket)
    local rotation = mesh:GetSocketRotation(state.socket)
    -- Copy values: Unreal's returned structs must not be retained between ticks.
    return {
        location = {X = location.X, Y = location.Y, Z = location.Z},
        rotation = {Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = rotation.Roll},
    }
end
getPose = uevrUtils.profiler:wrap('MELEE: getPose', getPose)

local function checkNativeAttack(player)
    return player:InAttackStateMachine() or player:InCounterState() or player:InFocusAttack()
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
    if state.playerAddress ~= playerAddress or state.weaponAddress ~= weaponAddress
        or state.meshAddress ~= meshAddress or state.traceAddress ~= traceAddress then
        -- Gesture begin can arrive before the first weapon configuration.
        local opening = state.weaponAddress == nil and state.windowOpen
        local heavy = state.swingHeavy
        reset()
        state.playerAddress, state.weaponAddress = playerAddress, weaponAddress
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
        local selected = state.swingHeavy and state.heavy or not state.swingHeavy and state.light
        if selected == nil or not player:CanAccepInputActionAttack(false)
            or not player:CanAcceptInputByStaminaStatus(selected.input) then
            state.windowOpen = false
            return
        end
        state.combo, state.comboName, state.comboString = selected.combo, selected.name, selected.text
        local stamina = uevrUtils.getValid(player, {'NocePlayerStamina'})
        if stamina ~= nil then stamina:CostStamina(selected.stamina) end
        -- Native attack ID state prevents repeated damage while a swing stays in contact.
        trace:SetIsDuringAttack(true)
        trace:StartTraceByAttackID(ATTACK_ID)
        state.activeTrace = trace
        state.hitActors = {}
        state.sweeps = 0
        state.reportedObstacle = false
        stats.swings = stats.swings + 1
        diagnostic('swing ' .. stats.swings .. ' began')
    end
    local attack = plugin.executeFunction(weapon, 'GetAttackInfo', weapon:GetDurability(), 0, 0, 0)
    if attack == nil then return end
    local damage = {
        health = state.combo.Attack * player:GetAttack() * attack.AttackMultiplier
            + state.combo.ExtraAttack * player:GetExtraAttack() * attack.ExtraAttackMultiplier,
        wince = state.combo.Wince * attack.WinceMultiplier,
    }
    -- Native trace retains durability, environment contact and deflection handling.
    trace:DoTraceByAttackID(ATTACK_ID, state.comboName, state.traceName,
        uevrUtils.vector(previous.location), uevrUtils.rotator(previous.rotation),
        uevrUtils.vector(pose.location), uevrUtils.rotator(pose.rotation), RADIUS_RATIO)
    -- OnHit's damage listener exists only during the vanilla attack state. Forward real
    -- physical contacts to the same character damage entry point without entering that state.
    damageContacts(player, weapon, previous, pose, damage)
    clearHitStop(player)
end
update = uevrUtils.profiler:wrap('MELEE: update', update)

-- Gesture callbacks own the window, as in DI2/FK. Physical contacts inside it
-- drive native damage; neither window boundary waits for an attack animation.
gestures.registerSwingBeginCallback(function(strength, hand)
    if hand == Handed.Right then M.beginSwing() end
end, true, false)

gestures.registerSwingEndCallback(function(strength, hand)
    if hand == Handed.Right then M.endSwing() end
end, true, false)

-- Use the weapon's updated socket pose after the engine tick.
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    update(delta)
end)

local function updateInput(retval, user_index, inputState)
    local rbDown = uevrUtils.isButtonPressed(inputState, XINPUT_GAMEPAD_RIGHT_SHOULDER)
    local rtDown = inputState.Gamepad.bRightTrigger > TRIGGER_THRESHOLD
    local rbPressed, rtPressed = rbDown and not controls.rbDown, rtDown and not controls.rtDown
    controls.rbDown, controls.rtDown, controls.heavyHeld = rbDown, rtDown, rtDown
    controls.focusHeld = (inputState.Gamepad.bLeftTrigger or 0) > TRIGGER_THRESHOLD
    if not rbDown then controls.passRB = false end
    if not rtDown then controls.passRT = false end
    -- Releases are already represented by the raw input. Idle input needs no UObject reads.
    if not rbDown and not rtDown then return end
    if not isGameplayActive() then controls.passRB, controls.passRT = false, false; return end
    if state.configured ~= true then controls.passRB, controls.passRT = false, false; return end
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

uevr.sdk.callbacks.on_lua_event(function(event)
    if event == 'SHf_MeleeStatus' then
        uevr.params.functions.log_info('[melee] configured=' .. tostring(state.configured)
            .. ' swinging=' .. tostring(state.activeTrace ~= nil) .. ' swings=' .. stats.swings
            .. ' contacts=' .. stats.contacts .. ' damageCalls=' .. stats.damageCalls)
    end
end)

return M
