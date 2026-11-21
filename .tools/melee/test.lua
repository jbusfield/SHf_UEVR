-- Run with source containing helpers/melee.lua. Only mocks execute this helper.
local callbacks, calls, damageResults, logs = {}, {}, {}, {}
local health, released, sweepHasEnemy = 500, 0, true
local paused, menu, interacting = false, false, false
local usingFocus, focusCharged, counterReady, nativeBusy, attackAllowed = false, false, false, false, true
local broadAttackState = false
local forceDeflect, breakOnTrace, weaponBroken
local anim = {AnimStateType=0, CanEnterAttack=false}
local staminaCosts = {}
local reads = {weapon = 0, pawn = 0, focus = 0, counter = 0, properties = 0}
local wallFirst, obstacleResponse, skipObstacle, failDamage = false, 2, false, false
local position = {X = 0, Y = 0, Z = 0}
local playerPosition = {X = 0, Y = 0, Z = 0}
local rotation = {Pitch = 0, Yaw = 0, Roll = 0}
local playerYaw = 0
local function name(value) return {to_string = function() return value end} end
local handActor = {get_address = function() return 6 end}
local character = {
    get_address = function() return 4 end, is_a = function() return true end,
    ActorHasTag = function() return false end, GetHealth = function() return health end,
    get_full_name = function() return 'Enemy' end, CustomTimeDilation = 1,
}
local function timeComponent(owner)
    return {
        IsDuringHitStopTimer = function() return owner.CustomTimeDilation < 1 end,
        OnHitStopTimerUp = function() owner.CustomTimeDilation = 1 end,
    }
end
character.NoceTime = timeComponent(character)
local otherCharacter = {}
for key, value in pairs(character) do otherCharacter[key] = value end
otherCharacter.get_address = function() return 7 end
otherCharacter.NoceTime = timeComponent(otherCharacter)
local currentTarget = character
local wall = {
    get_address = function() return 5 end, is_a = function() return false end,
    ActorHasTag = function() return skipObstacle end, get_full_name = function() return 'Obstacle' end,
}
local components = {
    [40] = {GetOwner = function() return currentTarget end, ComponentHasTag = function() return false end},
    [50] = {
        GetOwner = function() return wall end, ComponentHasTag = function() return false end,
        GetCollisionResponseToChannel = function(self, channel) assert(channel == 3); return obstacleResponse end,
    },
}
local mesh = {
    get_address = function() return 3 end, DoesSocketExist = function() return true end,
    GetSocketLocation = function() return position end, GetSocketRotation = function() return rotation end,
    GetAttachParent = function() return {GetOwner = function() return handActor end} end,
}
local weapon = {
    get_address = function() return 2 end,
    WeaponMesh = mesh, CounterComboName = name('Pipe_ComboCounter'), WeaponName = name('Pipe'),
    IsVisible = function() reads.weapon=reads.weapon+1; return true end, IsBroken = function() return weaponBroken == true end,
    GetDurability = function() return 400 end, GetWeaponMotionType = function() return 1 end,
    GetCanFocusAttack = function() return true end,
}
local trace = {get_address = function() return 11 end,
    GetIsEnable = function() return true end, ECollisionQueryChannel = 3, SkipAttackTraceTag = 'SkipAttackTrace'}
for _, method in ipairs({'SetIsDuringAttack', 'StartTraceByAttackID', 'EndTraceByAttackID', 'DoTraceByAttackID'}) do
    trace[method] = function(self, ...)
        calls[#calls + 1] = {method, ...}
        if method == 'DoTraceByAttackID' and forceDeflect then
            anim.AnimStateType, anim.CanEnterAttack = forceDeflect, true
            if breakOnTrace then weaponBroken=true end
        end
    end
end
local player = {
    get_address = function() return 1 end, CurrentWeapon = weapon, NoceAttackTrace = trace,
    PlayerAnimInstance = anim,
    get_full_name = function() return 'Player' end, GetStamina = function() return 70 end,
    NocePlayerAttackInfo = {PlayerComboDataAsset = {get_address = function() return 10 end}}, CustomTimeDilation = 1,
    GetIsInEvent = function() return false end, IsInteracting = function() return interacting end,
    GetAttack = function() return 1 end, GetExtraAttack = function() return 0 end,
    InAttackStateMachine = function() return broadAttackState or nativeBusy end,
    InFocusAttack = function() return nativeBusy end, InCounterState = function() return nativeBusy end,
    IsUsingFocus = function() reads.focus=reads.focus+1; return usingFocus end,
    InFocusCharged = function() return focusCharged end,
    HaveCounterTarget = function(self, hint) reads.counter=reads.counter+1; assert(hint == false); return counterReady end,
    CanAccepInputActionAttack = function() return attackAllowed end,
    CanAcceptInputByStaminaStatus = function(self, action) assert(action == 1 or action == 2); return attackAllowed end,
    NocePlayerStamina = {CostStamina = function(self, key) staminaCosts[#staminaCosts+1] = key end},
    K2_GetActorLocation = function() return playerPosition end,
    K2_GetActorRotation = function() return {Yaw = playerYaw} end,
}
player.NoceTime = timeComponent(player)
local livePawn = player
local grip = mesh
local modules = {
    ['libs/uevr_utils'] = {
        profiler = {wrap = function(self, name, fn) return fn end},
        getValid = function(object, path)
            for _, key in ipairs(path or {}) do object = object and object[key] end
            return object
        end,
        fname_from_string = function(value) return value end, get_class = function() return {} end,
        find_default_instance = function() return {CalculateDamageDirectionAngle = function() return 0 end} end,
        vector = function(value) return value end, rotator = function(value) return value end,
        isGamePaused = function() return paused end, isInCutscene = function() return false end,
        print = function() end,
        registerPreLevelChangeCallback = function(fn) callbacks.level = fn end,
        registerOnPostInputGetStateCallback = function(fn) callbacks.input = fn end,
        unpressButton = function(state) state.Gamepad.r1 = false end,
        isButtonPressed = function(state) return state.Gamepad.r1 == true end,
    },
    ['libs/attachments'] = {getCurrentGrippedAttachment = function() return grip end},
    ['libs/gestures'] = {
        registerSwingBeginCallback = function(fn, right, left)
            assert(right == true and left == false); callbacks.begin = fn
        end,
        registerSwingEndCallback = function(fn, right, left)
            assert(right == true and left == false); callbacks.finish = fn
        end,
    },
    ['libs/ui'] = {isInputDisabled = function() return menu end},
    ['libs/core/plugin'] = {
        getProperty = function(object, field)
            reads.properties=reads.properties+1
            if field == 'AttackTraceInfoMap' then
                return {Pipe_Default = {Socket = 'Socket_Pipe_Center', UseSocketInWeapon = true, Radius = 35, HalfHeight = 50}}
            elseif field == 'ObjectTypes' then return {3}
            elseif field == 'EnvironmentObjectTypes' then return {0, 1}
            elseif field == 'PlayerComboSettingMap' then
                return {Pipe_ComboL = {Attack = 175, ExtraAttack = 0, Wince = 15, WinceType = 2},
                    Pipe_ComboH = {Attack = 280, ExtraAttack = 0, Wince = 50, WinceType = 3}}
            elseif field == 'AttackTraceInfoMap[Pipe_Default]' then
                return {Socket = 'Socket_Pipe_Center', UseSocketInWeapon = true, Radius = 35, HalfHeight = 50}
            elseif field == 'PlayerComboSettingMap[Pipe_ComboL]' then
                return {Attack = 175, ExtraAttack = 0, Wince = 15, WinceType = 2}
            elseif field == 'PlayerComboSettingMap[Pipe_ComboH]' then
                return {Attack = 280, ExtraAttack = 0, Wince = 50, WinceType = 3}
            end
        end,
        executeFunction = function(object, method)
            assert(object == weapon and method == 'GetAttackInfo')
            return {AttackMultiplier = 1, ExtraAttackMultiplier = 1, WinceMultiplier = 1}
        end,
        executeFunctionWithHandle = function(object, method, keep, outputs, playerArg, start, finish,
            radius, height, orientation, types, complex, ignored)
            assert(method == 'CapsuleTraceMultiForObjects' and keep == 'OutHits')
            assert(radius == 8.75 and height == 50, 'use authored weapon capsule dimensions')
            assert(ignored[1] == player and ignored[2] == weapon and ignored[3] == handActor,
                'exclude the separate VR hand actor')
            local hits = {}
            if sweepHasEnemy then hits[1] = {Component = 40, ImpactPoint = {X = 0, Y = 0, Z = 0}, Time = 0.5} end
            if wallFirst then table.insert(hits, {Component = 50, ImpactPoint = {}, Time = 0.1}) end
            return {handle = 100, OutHits = hits}
        end,
        handleParam = function(handle, changes, index) return {nativeHandle = handle, index = index} end,
        executeFunctionWithOutputs = function(target, method, outputs, damage)
            assert(target == currentTarget and method == 'OnDamaged')
            assert(damage.HitResult.nativeHandle == 100 and damage.HitResult.index == 1)
            assert(damage.Instigator == player)
            local heavy = damage.ComboName == 'Pipe_ComboH'
            assert(heavy or damage.ComboName == 'Pipe_ComboL')
            assert(damage.HealthDamage == (heavy and 280 or 175) and damage.WinceDamage == (heavy and 50 or 15))
            if failDamage then error('simulated contact failure') end
            damageResults[#damageResults + 1] = damage
            health = health - damage.HealthDamage
            target.CustomTimeDilation, player.CustomTimeDilation = 0.01, 0.01
            return {}
        end,
        releaseHandle = function(handle) assert(handle == 100); released = released + 1 end,
    },
}
local env = setmetatable({
    require = function(key) assert(modules[key], key); return modules[key] end,
    Handed = {Left = 0, Right = 1}, LogLevel = {Warning = 1}, XINPUT_GAMEPAD_RIGHT_SHOULDER = 0x0200,
    uevr = {
        api = {get_local_pawn = function() reads.pawn=reads.pawn+1; return livePawn end,
            to_uobject = function(self, address) return components[address] end},
        sdk = {callbacks = {on_post_engine_tick = function(fn) callbacks.tick = fn end, on_lua_event = function() end}},
        params = {
            functions = {log_info = function(message) logs[#logs + 1] = message end,
                log_error = function(message) logs[#logs + 1] = message end},
            sdk = {callbacks = {on_script_reset = function(fn) callbacks.reset = fn end}},
        },
    },
}, {__index = _G})
local helper = assert(load(source, '@helpers/melee.lua', 't', env))()
local function tick(x) position.X = x; callbacks.tick(nil, 1 / 90) end
local function count(method)
    local total = 0
    for _, call in ipairs(calls) do if call[1] == method then total = total + 1 end end
    return total
end
local function prime()
    helper.setEnabled(false); helper.setEnabled(true)
    paused, menu, interacting, wallFirst, skipObstacle, failDamage = false, false, false, false, false, false
    usingFocus, focusCharged, counterReady, nativeBusy, attackAllowed = false, false, false, false, true
    broadAttackState = false
    forceDeflect, breakOnTrace, weaponBroken = nil, false, false
    anim.AnimStateType, anim.CanEnterAttack = 0, false
    staminaCosts = {}
    health, released, sweepHasEnemy, obstacleResponse = 500, 0, true, 2
    playerPosition.X, playerYaw, grip = 0, 0, mesh
    currentTarget = character
    livePawn = player
    calls, damageResults = {}, {}
    callbacks.input(0,0,{Gamepad={r1=false,bRightTrigger=0,bLeftTrigger=0}})
    tick(0); tick(1)
    assert(#calls == 0, 'slow weapon movement must not attack')
end

prime(); tick(4)
assert(#calls == 0, 'fast weapon movement outside the gesture window must not attack')
callbacks.begin(1, 0); tick(7)
assert(#calls == 0, 'left-hand gestures must not open the pipe window')
callbacks.begin(1, 1); tick(10); tick(11); callbacks.begin(1, 1); tick(12)
assert(health == 325 and #damageResults == 1, 'one damage application per gesture window')
assert(count('StartTraceByAttackID') == 1 and count('DoTraceByAttackID') == 3, 'slow movement remains active until gesture end')
callbacks.finish(0, 1)
assert(count('EndTraceByAttackID') == 1, 'gesture end immediately closes the native window')
tick(15)
assert(count('DoTraceByAttackID') == 3, 'no traces after the end callback')
assert(released == 3, 'release every native hit array')
assert(character.CustomTimeDilation == 1 and player.CustomTimeDilation == 1, 'clear vanilla hit stop on both characters')

prime(); callbacks.begin(1, 1); tick(4); callbacks.finish(0, 1)
callbacks.begin(1, 1); tick(5)
assert(health == 150 and #damageResults == 2, 'a new detector-confirmed stroke must not be blocked by a melee cooldown')

prime(); callbacks.begin(1, 1); tick(4); currentTarget = otherCharacter; tick(5)
assert(#damageResults == 2, 'the repeat-hit guard must not block a different enemy')

prime(); callbacks.begin(1, 1); sweepHasEnemy = false; tick(4); sweepHasEnemy = true; tick(5)
assert(health == 325, 'slow contact while the gesture window is open must register')

helper.setEnabled(false); helper.setEnabled(true); calls, damageResults = {}, {}; health = 500
callbacks.begin(1, 1); tick(0); tick(3)
assert(health == 325, 'first weapon configuration must preserve an already-open gesture window')

for _, deflect in ipairs({7,8}) do
    prime();forceDeflect,breakOnTrace=deflect,true
    callbacks.begin(1,1);tick(4)
    assert(health==325 and weaponBroken, 'breaking blow retains native contact/durability and damage')
    assert(anim.AnimStateType==0 and not anim.CanEnterAttack, 'physical break must not queue an animation recoil')
    tick(5)
    assert(count('EndTraceByAttackID')==1 and #damageResults==1, 'broken weapon closes its window without another hit')
end
prime();forceDeflect=8;anim.AnimStateType,anim.CanEnterAttack=1,true
callbacks.begin(1,1);tick(4)
assert(anim.AnimStateType==1 and anim.CanEnterAttack, 'retain requests that existed before the physical contact')
prime();forceDeflect=17;callbacks.begin(1,1);tick(4)
assert(anim.AnimStateType==17 and anim.CanEnterAttack, 'do not suppress a non-deflection native request')

prime(); playerPosition.X = 10; tick(11)
assert(#calls == 0, 'walking cannot attack outside a gesture window')
playerYaw = 90; tick(20)
assert(#calls == 0, 'snap turns must not start a swing')
tick(200)
assert(#calls == 0, 'tracking jumps must not start a swing')

prime(); callbacks.begin(1, 1); tick(4); tick(200)
assert(count('DoTraceByAttackID') == 1, 'skip discontinuous tracking without a contact query')
tick(203)
assert(count('DoTraceByAttackID') == 2 and #damageResults == 1, 'tracking discontinuity must preserve window hit deduplication')

for _, case in ipairs({{2, false, 500}, {1, false, 325}, {0, false, 325}, {2, true, 325}}) do
    prime(); wallFirst, obstacleResponse, skipObstacle = true, case[1], case[2]; callbacks.begin(1, 1); tick(4)
    assert(health == case[3], 'only attack-blocking, untagged geometry should stop damage')
end

prime(); failDamage = true; callbacks.begin(1, 1); tick(4)
assert(released == 1, 'damage errors still release native hit data')

prime(); callbacks.begin(1, 1); tick(4); paused = true; tick(7)
assert(count('EndTraceByAttackID') == 1, 'pause closes an active attack')
prime(); callbacks.begin(1, 1); tick(4); grip = nil; tick(7)
assert(count('EndTraceByAttackID') == 1, 'release closes an active attack')
prime(); callbacks.begin(1, 1); tick(4); callbacks.level()
assert(count('EndTraceByAttackID') == 1, 'level change closes an active attack')
prime(); callbacks.begin(1, 1); tick(4); callbacks.reset()
assert(count('EndTraceByAttackID') == 1, 'script reset closes an active attack')

for _, method in ipairs({'GetIsInEvent', 'IsInteracting'}) do
    prime(); callbacks.begin(1, 1); tick(4)
    local savedMethod = player[method]
    player[method] = nil
    tick(7)
    assert(count('EndTraceByAttackID') == 1, 'unsupported pawns must close the melee window without calling a missing method')
    local unsupportedInput = {Gamepad = {bRightTrigger = 255, r1 = true}}
    callbacks.input(0, 0, unsupportedInput)
    assert(unsupportedInput.Gamepad.bRightTrigger == 255 and unsupportedInput.Gamepad.r1,
        'leave input untouched when the possessed pawn lacks a gameplay method')
    player[method] = savedMethod
end

prime()
local input = {Gamepad = {bRightTrigger = 255, r1 = true, b = true}}
callbacks.input(0, 0, input)
assert(input.Gamepad.bRightTrigger == 0 and not input.Gamepad.r1 and input.Gamepad.b, 'consume animated attacks only')
menu = true; input.Gamepad.bRightTrigger = 255; input.Gamepad.r1 = true; callbacks.input(0, 0, input)
assert(input.Gamepad.bRightTrigger == 255 and input.Gamepad.r1, 'preserve menu input')

local function input(rt, rb, lt)
    local value = {Gamepad={bRightTrigger=rt or 0, r1=rb == true, bLeftTrigger=lt or 0}}
    callbacks.input(0,0,value)
    return value.Gamepad
end

if performanceOnly then
    prime()
    local before = {}; for key, value in pairs(reads) do before[key]=value end
    for frame=1,1000 do tick(1); input(0) end
    local idle = {}; for key, value in pairs(reads) do idle[key]=value-before[key] end
    local propertyReads = reads.properties
    for swap=1,5 do helper.setEnabled(false); helper.setEnabled(true); tick(1) end
    return {idle=idle, reconfigureProperties=reads.properties-propertyReads}
end

prime(); input(255); callbacks.begin(1,1); tick(4); tick(5)
assert(health == 220 and damageResults[1].ComboName == 'Pipe_ComboH', 'RT selects native heavy damage and stagger')
assert(#staminaCosts == 1 and staminaCosts[1] == 'Pipe_HeavyAttack', 'charge native heavy stamina once per swing')
input(0); currentTarget = otherCharacter; tick(6)
assert(damageResults[2].ComboName == 'Pipe_ComboH', 'releasing RT during a stroke must not change its attack type')
callbacks.finish(0,1); callbacks.begin(1,1); tick(7)
assert(damageResults[3].ComboName == 'Pipe_ComboL' and staminaCosts[2] == 'Pipe_LightAttack_1', 'the next unmodified swing is light')

prime(); attackAllowed = false; callbacks.begin(1,1); tick(4)
assert(#damageResults == 0 and #staminaCosts == 0, 'respect native attack/stamina restrictions')

prime(); broadAttackState=true; tick(2); callbacks.begin(1,1); tick(4)
assert(health == 325, 'a broad attack-state flag without a focus/counter attack must not block physical melee')
currentTarget=otherCharacter; tick(5)
assert(#damageResults == 2, 'a continuing physical swing must not cancel itself because of the broad attack-state flag')

prime(); usingFocus=true; tick(2)
assert(not input(0,true,255).r1, 'LT plus RB before charge must not trigger a focused attack')
focusCharged=true; tick(3)
assert(not input(0,true,255).r1, 'holding RB while charge finishes must not manufacture a press')
input(0,false,255)
assert(input(0,true,255).r1, 'preserve a fresh RB press when focus is charged')
tick(4); callbacks.begin(1,1); nativeBusy=true; tick(5)
assert(#damageResults == 0, 'vanilla focus attack must not also cause physical damage')
nativeBusy=false; usingFocus=false; focusCharged=false; input(0,false,0); tick(6)
assert(#damageResults == 0, 'finishing a vanilla attack must not reopen the old physical window')
callbacks.begin(1,1); tick(8)
assert(#damageResults == 1, 'a fresh physical swing resumes after vanilla combat')

prime(); counterReady=true; tick(2)
assert(input(255,false,0).bRightTrigger == 255, 'a valid counter RT press must pass without LT')
nativeBusy=true; tick(3); callbacks.begin(1,1); tick(4)
assert(#damageResults == 0, 'vanilla counter motion must not cause a physical heavy hit')

prime(); assert(input(255).bRightTrigger == 0, 'normal RT must select physical heavy without an animated heavy')
counterReady=true; tick(2)
assert(input(255).bRightTrigger == 0, 'a held heavy modifier must not automatically counter when a window opens')
input(0)
assert(input(255).bRightTrigger == 255, 'a new press inside the counter window must pass')

prime(); callbacks.begin(1,1); tick(4)
counterReady=true; tick(5); input(255)
nativeBusy=true; local before=#calls; tick(6)
assert(count('EndTraceByAttackID') == 1, 'native special takeover closes our trace ID')
for index=before+1,#calls do
    assert(not (calls[index][1] == 'SetIsDuringAttack' and calls[index][2] == false), 'do not clear the vanilla attack flag during takeover')
end

prime(); input(255); menu=true; input(0,true); menu=false; tick(3)
assert(not input(0,true).r1, 'holding RB across a menu must not preserve a stale special input')

prime()
local before = {}; for key, value in pairs(reads) do before[key]=value end
for frame=1,1000 do tick(1); input(0) end
assert(reads.weapon-before.weapon == 1000 and reads.pawn-before.pawn == 1000,
    'idle input must reuse tick validation instead of reading the pawn/weapon twice')
assert(reads.focus == before.focus, 'do not poll focus readiness when LT is not held')
assert(reads.counter-before.counter == 1000, 'counter readiness must still update every tick')
local propertyReads = reads.properties
helper.setEnabled(false); helper.setEnabled(true); tick(1)
assert(reads.properties == propertyReads, 'reuse the same family settings after ordinary reset/regrip')
callbacks.level(); tick(1)
assert(reads.properties > propertyReads, 'level changes must invalidate cached settings')
propertyReads = reads.properties
local originalData = player.NocePlayerAttackInfo.PlayerComboDataAsset
player.NocePlayerAttackInfo.PlayerComboDataAsset = {get_address = function() return 12 end}
helper.setEnabled(false); helper.setEnabled(true); tick(1)
assert(reads.properties > propertyReads, 'a new combo data asset must not reuse old settings')
player.NocePlayerAttackInfo.PlayerComboDataAsset = originalData
prime(); propertyReads=reads.properties
local originalTraceAddress = trace.get_address
trace.get_address = function() return 13 end
tick(1)
assert(reads.properties > propertyReads, 'a replacement trace component must refresh cached settings')
trace.get_address = originalTraceAddress
propertyReads = reads.properties
callbacks.reset(); tick(1)
assert(reads.properties > propertyReads, 'script reset must invalidate cached settings')

prime(); grip=nil
assert(input(255,true).bRightTrigger == 255, 'releasing the grip must preserve input before the next engine tick')
prime(); livePawn={get_address=function() return 999 end}
assert(input(255,true).r1, 'a possession change between ticks must preserve input for the new pawn')
prime(); player.CurrentWeapon=nil
assert(input(255,true).r1, 'a weapon change between ticks must not use a stale input route')
player.CurrentWeapon=weapon
return 'PASS: light/heavy native data and stamina, focus/counter input edges, native animation ownership, gesture windows, deduplication, contact cleanup and lifecycle'
