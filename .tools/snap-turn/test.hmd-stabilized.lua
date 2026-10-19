local ikSource, inputSource = ...
assert(load(ikSource, '@ik.lua', 't', {}))
assert(load(inputSource, '@input.lua', 't', {}))
local checks = 0
local function check(ok, message)
    assert(ok, message)
    checks = checks + 1
end
local function cut(source, first, last)
    local a = assert(source:find(first, 1, true), first)
    local b = assert(source:find(last, a + #first, true), last)
    return source:sub(a, b - 1)
end
local vecMeta = {}
local function vec(x, y, z) return setmetatable({X = x, Y = y, Z = z}, vecMeta) end
vecMeta.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
vecMeta.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function rotate(v, r)
    local c, s = math.cos(math.rad(r.Yaw)), math.sin(math.rad(r.Yaw))
    return vec(c * v.X - s * v.Y, s * v.X + c * v.Y, v.Z)
end
local function near(a, b) return math.abs(a - b) < 0.00001 end
local correction = cut(ikSource, 'function Rig:updateEnhancedMeshRotation(', 'function Rig:create()')
local function fixture(enabled, oldYaw)
    oldYaw = oldYaw or 0
    local Rig, events, stereo, writes, logs = {}, {}, nil, 0, {}
    local hmdRotation = {Pitch = 0, Yaw = oldYaw, Roll = 0}
    local parent = {position = vec(105, 200, 50), yaw = 0}
    local mesh = {position = vec(110, 200, 70), rotation = {Pitch = 0, Yaw = oldYaw - 90, Roll = 0}, RelativeLocation = vec(5, 0, 20)}
    function mesh:K2_SetWorldRotation(rotation) writes = writes + 1; self.rotation = rotation end
    function mesh:K2_SetWorldLocation(position) self.position = position; self.RelativeLocation = rotate(position - parent.position, {Yaw = -parent.yaw}) end
    function mesh:K2_SetRelativeLocation(relative) self.RelativeLocation = relative; self.position = parent.position + rotate(relative, {Yaw = parent.yaw}) end
    local state = {lastControllerRotWS = {}, lastValidPoleWS = {}, lastCtrlPoleWS = {}, smOutwardWS = {}, smUpperDirCS = {}}
    local rig = setmetatable({enhancedStabilization = true, coupling = 2, meshList = {mesh},
        meshRotationOffset = {Yaw = -90}, activeSolvers = {{state = state}}}, {__index = Rig})
    local excluded = {enhancedStabilization = false, coupling = 2}
    local rootRig = {enhancedStabilization = true, coupling = 1}
    local env = setmetatable({Rig = Rig, enableSnapTurnCorrection = enabled, _rigInstances = {rig, excluded, rootRig},
        getPawn = function() return {RootComponent = {position = vec(100, 200, 50)}} end,
        controllers = {getControllerRotation = function() return hmdRotation end},
        kismet_math_library = {ComposeRotators = function(self, a, b) return {Pitch = a.Pitch or 0, Yaw = a.Yaw + b.Yaw, Roll = a.Roll or 0} end},
        mathLib = {vectorRotate = rotate}, print = function(message) logs[#logs + 1] = message end,
        uevrUtils = {getValid = function(object, path) return path and object[path[1]] or object end,
            getComponentRotation = function(object) return object.rotation end,
            getComponentLocation = function(object) return object.position end,
            vector = vec, rotator = function(p, y, r) return {Pitch = p, Yaw = y, Roll = r} end,
            clampAngle180 = function(angle) return (angle + 180) % 360 - 180 end,
            registerUEVRCallback = function(name, fn) events[name] = fn end,
            registerPostCalculateStereoViewCallback = function(fn) stereo = fn end}}, {__index = _G})
    assert(load(correction, '@snap correction', 't', env))()
    return {rig = rig, mesh = mesh, state = state, excluded = excluded, rootRig = rootRig,
        events = events, stereo = stereo, writes = function() return writes end, logs = logs,
        setHmd = function(rotation) hmdRotation = rotation end,
        moveParent = function(position, yaw)
            parent.position, parent.yaw = position, yaw
            mesh.position = parent.position + rotate(mesh.RelativeLocation, {Yaw = yaw})
        end,
        destroy = function() env._rigInstances = {} end}
end
local off = fixture(false)
check(off.stereo == nil and next(off.events) == nil and #off.logs == 0, 'Disabled gate added behavior')
local f = fixture(true)
f.stereo(nil, 0)
check(f.writes() == 0, 'Corrected without snap')
f.events.on_input_snap_turn(90)
check(f.writes() == 1 and near(f.mesh.rotation.Yaw, 0), 'Did not carry orientation immediately')
check(near(f.mesh.position.X, 100) and near(f.mesh.position.Y, 210) and near(f.mesh.position.Z, 70), 'Did not carry position around pawn pivot')
check(f.rig.snapTurnPending and not f.excluded.snapTurnPending and not f.rootRig.snapTurnPending, 'Wrong rig scope')
check(f.state.lastControllerRotWS == nil and f.state.smOutwardWS == nil and f.state.lastValidPoleWS == nil and f.state.lastCtrlPoleWS == nil, 'Old world history survived')
check(f.state.smUpperDirCS ~= nil, 'Lost component-space history')
f.stereo(nil, 0)
check(f.rig.snapTurnPending and f.writes() == 1, 'Stale first eye consumed snap')
f.rig:updateEnhancedMeshRotation(f.mesh, nil, false)
check(f.writes() == 1, 'Normal update undid carry while tracking stale')
f.moveParent(vec(100, 205, 50), 90)
f.setHmd({Pitch = 0, Yaw = 90, Roll = 0}); f.stereo(nil, 1)
check(not f.rig.snapTurnPending and f.writes() == 2 and near(f.mesh.rotation.Yaw, 0), 'Did not hand off on refreshed second eye')
check(near(f.mesh.RelativeLocation.X, 5) and near(f.mesh.RelativeLocation.Y, 0), 'Did not restore parent-relative offset')
check(near(f.mesh.position.X, 100) and near(f.mesh.position.Y, 210), 'Double-transformed position at handoff')
f.stereo(nil, 0); f.stereo(nil, 1)
check(f.writes() == 2, 'Repeated correction')
local legacy = fixture(true)
legacy.events.on_input_snap_turn(-30); legacy.setHmd({Yaw = -30}); legacy.stereo(nil, 1)
check(not legacy.rig.snapTurnPending, 'Legacy 1/2 first eye did not release')
local wrap = fixture(true, 175)
wrap.events.on_input_snap_turn(30); wrap.setHmd({Yaw = -155}); wrap.stereo(nil, 1)
check(not wrap.rig.snapTurnPending and near(wrap.mesh.rotation.Yaw, -245), 'Yaw wrap failed')
local coalesced = fixture(true)
coalesced.events.on_input_snap_turn(30); coalesced.events.on_input_snap_turn(30)
coalesced.setHmd({Yaw = 30}); coalesced.stereo(nil, 0)
check(coalesced.rig.snapTurnPending ~= nil, 'Partial tracking update consumed two snaps')
coalesced.setHmd({Yaw = 60}); coalesced.stereo(nil, 1)
check(not coalesced.rig.snapTurnPending, 'Coalesced snaps never released')
local cancel = fixture(true)
cancel.events.on_input_snap_turn(30); cancel.events.on_input_snap_turn(-30); cancel.stereo(nil, 0)
check(not cancel.rig.snapTurnPending and near(cancel.mesh.position.X, 110) and near(cancel.mesh.position.Y, 200), 'Opposite snaps failed to cancel')
local missing = fixture(true)
missing.events.on_input_snap_turn(30); missing.setHmd(nil)
for eye = 1, 7 do missing.stereo(nil, eye % 2) end
check(missing.rig.snapTurnPending ~= nil, 'Tracking loss cleared carry early')
missing.stereo(nil, 1)
check(not missing.rig.snapTurnPending and near(missing.mesh.RelativeLocation.X, 5), 'Tracking loss did not bound wait/restore relative offset')
local gone = fixture(true)
gone.events.on_input_snap_turn(30); gone.destroy(); gone.stereo(nil, 1)
check(gone.writes() == 1, 'Destroyed rig was retained')
local noPose = fixture(true)
noPose.setHmd(nil); noPose.events.on_input_snap_turn(30)
check(noPose.writes() == 0 and not noPose.rig.snapTurnPending, 'Missing initial HMD pose created stale state')
local inputCallback = cut(inputSource, 'uevr.sdk.callbacks.on_xinput_get_state(function', '-- register_key_bind("F1"')
local function inputFixture(snap, yawChange, disabled)
    local fn, notifications, rootYaw = nil, 0, nil
    local env = setmetatable({isDisabled = false, rootComponent = {}, status = {}, decoupledYaw = 45, bodyRotationOffset = 5,
        getParameter = function() return snap end, isRotationModeRotationDisabled = function() return disabled end,
        updateDecoupledYaw = function() return yawChange end, setRootWorldYaw = function(yaw) rootYaw = yaw end,
        uevr = {sdk = {callbacks = {on_xinput_get_state = function(callback) fn = callback end}}},
        uevrUtils = {executeUEVRCallbacks = function(name, delta)
            check(rootYaw == 50 and name == 'on_input_snap_turn' and delta == yawChange, 'Event before root update')
            notifications = notifications + 1
        end}}, {__index = _G})
    assert(load(inputCallback, '@snap input', 't', env))(); fn(0, 0, {})
    return notifications
end
check(inputFixture(true, 30, false) == 1, 'Missing snap notification')
check(inputFixture(false, 2, false) == 0, 'Smooth turn emitted snap event')
check(inputFixture(true, 0, false) == 0, 'Held stick emitted snap event')
check(inputFixture(true, 30, true) == 0, 'Disabled rotation emitted snap event')
check(ikSource:find('if self.snapTurnPending then return end', ikSource:find('self.tickFn = function', 1, true), true) ~= nil, 'Solver does not wait for tracking')
return 'Lua syntax and ' .. checks .. ' isolated snap-turn checks passed; no game callbacks registered'
