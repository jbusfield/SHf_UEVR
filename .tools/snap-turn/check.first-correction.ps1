$ErrorActionPreference = 'Stop'
$projectDir = Split-Path (Split-Path $PSScriptRoot)
$ikSource = [IO.File]::ReadAllText((Join-Path $projectDir 'scripts/libs/ik.lua'))
$inputSource = [IO.File]::ReadAllText((Join-Path $projectDir 'scripts/libs/input.lua'))
$code = "local ikSource = [====[$ikSource]====]`nlocal inputSource = [====[$inputSource]====]`n"
$code += @'
assert(load(ikSource, '@ik.lua', 't', {}))
assert(load(inputSource, '@input.lua', 't', {}))
local function cut(source, first, last)
    local a = assert(source:find(first, 1, true), first)
    local b = assert(source:find(last, a + #first, true), last)
    return source:sub(a, b - 1)
end
local correction = cut(ikSource, 'function Rig:updateEnhancedMeshRotation(', 'function Rig:create()')
local inputCallback = cut(inputSource, 'uevr.sdk.callbacks.on_xinput_get_state(function', '-- register_key_bind("F1"')
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function fixture(enabled, firstEye)
    local events, stereo, writes = {}, nil, 0
    local hmdRotation = {Yaw = 75}
    local mesh = {K2_SetWorldRotation = function(self, rotation) writes = writes + 1; self.rotation = rotation end}
    local state = {lastControllerRotWS = {}, lastValidPoleWS = {}, lastCtrlPoleWS = {}, smOutwardWS = {}, smUpperDirCS = {}}
    local Rig = {}
    local rig = setmetatable({enhancedStabilization = true, coupling = 2, meshList = {mesh},
        meshRotationOffset = {}, activeSolvers = {{state = state}}}, {__index = Rig})
    local excluded = {enhancedStabilization = false, coupling = 2}
    local rootRig = {enhancedStabilization = true, coupling = 1}
    local env = setmetatable({Rig = Rig, enableSnapTurnCorrection = enabled,
        _rigInstances = {rig, excluded, rootRig},
        input = {getFirstStereoViewIndex = function() return firstEye end},
        controllers = {getControllerRotation = function() return hmdRotation end},
        kismet_math_library = {ComposeRotators = function(self, offset, rotation) return rotation end},
        uevrUtils = {getValid = function(object) return object end,
            registerUEVRCallback = function(name, fn) events[name] = fn end,
            registerPostCalculateStereoViewCallback = function(fn) stereo = fn end}}, {__index = _G})
    assert(load(correction, '@snap correction', 't', env))()
    return {rig = rig, mesh = mesh, state = state, excluded = excluded, rootRig = rootRig,
        events = events, stereo = stereo, writes = function() return writes end,
        setHmd = function(rotation) hmdRotation = rotation end,
        destroy = function() env._rigInstances = {} end}
end
local off = fixture(false, 0)
check(off.stereo == nil and next(off.events) == nil, 'Disabled gate registered callbacks')
for _, firstEye in ipairs({0, 1}) do
    local f = fixture(true, firstEye)
    f.stereo(nil, firstEye)
    check(f.writes() == 0, 'Corrected without a snap')
    f.events.on_input_snap_turn(30)
    check(f.rig.snapTurnPending and not f.excluded.snapTurnPending and not f.rootRig.snapTurnPending, 'Wrong rig scope')
    f.stereo(nil, firstEye + 1)
    check(f.writes() == 0 and f.rig.snapTurnPending, 'Corrected on second eye')
    f.stereo(nil, firstEye)
    check(f.writes() == 1 and f.mesh.rotation.Yaw == 75 and not f.rig.snapTurnPending, 'Snap was not carried exactly once')
    check(f.state.lastControllerRotWS == nil and f.state.smOutwardWS == nil and f.state.lastValidPoleWS == nil and f.state.lastCtrlPoleWS == nil, 'Old world history survived')
    check(f.state.smUpperDirCS ~= nil, 'Component-space history was cleared')
    f.stereo(nil, firstEye + 1); f.stereo(nil, firstEye)
    check(f.writes() == 1, 'Snap applied more than once')
    f.events.on_input_snap_turn(-30); f.events.on_input_snap_turn(30)
    f.setHmd(nil); f.stereo(nil, firstEye)
    check(f.rig.snapTurnPending and f.writes() == 1, 'Lost snap with missing HMD pose')
    f.setHmd({Yaw = -175}); f.stereo(nil, firstEye)
    check(f.writes() == 2 and f.mesh.rotation.Yaw == -175, 'Failed recovery/coalesced snaps at yaw wrap')
    f.events.on_input_snap_turn(30); f.destroy(); f.stereo(nil, firstEye)
    check(f.writes() == 2, 'Destroyed rig was retained by callback')
end
local function inputFixture(snap, yawChange, disabled)
    local fn, notifications, rootYaw = nil, 0, nil
    local env = setmetatable({isDisabled = false, rootComponent = {}, status = {}, decoupledYaw = 45, bodyRotationOffset = 5,
        getParameter = function() return snap end,
        isRotationModeRotationDisabled = function() return disabled end,
        updateDecoupledYaw = function() return yawChange end,
        setRootWorldYaw = function(yaw) rootYaw = yaw end,
        uevr = {sdk = {callbacks = {on_xinput_get_state = function(callback) fn = callback end}}},
        uevrUtils = {executeUEVRCallbacks = function(name, delta)
            check(rootYaw == 50 and name == 'on_input_snap_turn' and delta == yawChange, 'Event before root update')
            notifications = notifications + 1
        end}}, {__index = _G})
    assert(load(inputCallback, '@snap input', 't', env))()
    fn(0, 0, {})
    return notifications
end
check(inputFixture(true, 30, false) == 1, 'Missing snap notification')
check(inputFixture(false, 2, false) == 0, 'Smooth turn emitted snap event')
check(inputFixture(true, 0, false) == 0, 'Held/released stick emitted snap event')
check(inputFixture(true, 30, true) == 0, 'Disabled rotation emitted snap event')
return 'Lua syntax and ' .. checks .. ' isolated snap-turn checks passed; no game callbacks registered'
'@
$body = @{code = $code; timeout = 10000} | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Uri 'http://localhost:8899/api/lua/exec' -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
$result | ConvertTo-Json -Depth 10
if (-not $result.success) { throw 'Snap-turn checks failed' }
