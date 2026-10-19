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
local function fixture(enabled, oldYaw, options)
    options = options or {}
    oldYaw = oldYaw or 0
    local Rig, events, stereo, preTick, postTick, writes, logs = {}, {}, nil, nil, nil, 0, {}
    local coupling = options.coupling or 2
    local enhanced = options.enhanced ~= false
    local hmdRotation = {Pitch = 0, Yaw = oldYaw, Roll = 0}
    local root = {position = vec(100, 200, 50), rotation = {Pitch = 0, Yaw = 0, Roll = 0}}
    function root:K2_GetComponentRotation() return self.rotation end
    local parent = {position = coupling == 1 and root.position or vec(105, 200, 50), yaw = 0}
    local mesh = {position = vec(110, 200, 70), rotation = {Pitch = 0, Yaw = oldYaw - 90, Roll = 0},
        RelativeLocation = vec(coupling == 1 and 10 or 5, 0, 20), RelativeRotation = {Pitch = 0, Yaw = oldYaw - 90, Roll = 0},
        bAbsoluteLocation = false, bAbsoluteRotation = enhanced, bAbsoluteScale = false}
    function mesh:K2_SetWorldRotation(rotation)
        writes = writes + 1; self.rotation = rotation
        self.RelativeRotation = {Pitch = rotation.Pitch or 0, Yaw = rotation.Yaw - (self.bAbsoluteRotation and 0 or parent.yaw), Roll = rotation.Roll or 0}
    end
    function mesh:K2_SetRelativeRotation(rotation)
        self.RelativeRotation = rotation
        self.rotation = {Pitch = rotation.Pitch or 0, Yaw = rotation.Yaw + (self.bAbsoluteRotation and 0 or parent.yaw), Roll = rotation.Roll or 0}
    end
    function mesh:K2_SetWorldLocation(position)
        self.position = position
        self.RelativeLocation = self.bAbsoluteLocation and position or rotate(position - parent.position, {Yaw = -parent.yaw})
    end
    function mesh:K2_SetRelativeLocation(relative)
        self.RelativeLocation = relative
        self.position = self.bAbsoluteLocation and relative or parent.position + rotate(relative, {Yaw = parent.yaw})
    end
    function mesh:SetAbsolute(location, rotation, scale)
        self.bAbsoluteLocation, self.bAbsoluteRotation, self.bAbsoluteScale = location, rotation, scale
    end
    local state = {lastControllerRotWS = {}, lastValidPoleWS = {}, lastCtrlPoleWS = {}, smOutwardWS = {}, smUpperDirCS = {}}
    local springArm = {bEnableCameraRotationLag = true}
    local rig = setmetatable({enhancedStabilization = enhanced, coupling = coupling, meshList = {mesh},
        springArmList = coupling == 2 and not enhanced and {springArm} or nil,
        meshRotationOffset = {Yaw = -90}, activeSolvers = {{state = state}}}, {__index = Rig})
    local excluded = {enhancedStabilization = false, coupling = 99}
    local env = setmetatable({Rig = Rig, enableSnapTurnCorrection = enabled, _rigInstances = {rig, excluded},
        getPawn = function() return {RootComponent = root} end,
        input = {getEffectivePawnRotationMode = function() return 4 end, PawnRotationMode = {RIGHT_CONTROLLER = 1, LEFT_CONTROLLER = 2}},
        controllers = {getControllerRotation = function() return hmdRotation end},
        kismet_math_library = {ComposeRotators = function(self, a, b) return {Pitch = a.Pitch or 0, Yaw = a.Yaw + b.Yaw, Roll = a.Roll or 0} end},
        mathLib = {vectorRotate = rotate}, print = function(message) logs[#logs + 1] = message end,
        uevrUtils = {getValid = function(object, path) return path and object[path[1]] or object end,
            getComponentRotation = function(object) return object.rotation end,
            getComponentLocation = function(object) return object.position end,
            vector = vec, rotator = function(p, y, r) return {Pitch = p, Yaw = y, Roll = r} end,
            clampAngle180 = function(angle) return (angle + 180) % 360 - 180 end,
            registerUEVRCallback = function(name, fn) events[name] = fn end,
            registerPostCalculateStereoViewCallback = function(fn) stereo = fn end,
            registerPreEngineTickCallback = function(fn) preTick = fn end,
            registerPostEngineTickCallback = function(fn) postTick = fn end}}, {__index = _G})
    assert(load(correction, '@snap correction', 't', env))()
    return {rig = rig, mesh = mesh, state = state, excluded = excluded, springArm = springArm, root = root,
        events = events, stereo = stereo, writes = function() return writes end, logs = logs,
        preTick = preTick, postTick = postTick,
        setHmd = function(rotation) hmdRotation = rotation end,
        moveParent = function(position, yaw)
            parent.position, parent.yaw = position, yaw
            if not mesh.bAbsoluteLocation then mesh.position = parent.position + rotate(mesh.RelativeLocation, {Yaw = yaw}) end
            if not mesh.bAbsoluteRotation then
                mesh.rotation = {Pitch = mesh.RelativeRotation.Pitch, Yaw = mesh.RelativeRotation.Yaw + yaw, Roll = mesh.RelativeRotation.Roll}
            end
        end,
        destroy = function() env._rigInstances = {} end}
end
local off = fixture(false)
check(off.stereo == nil and off.preTick == nil and off.postTick == nil and next(off.events) == nil and #off.logs == 0, 'Disabled gate added behavior')
local f = fixture(true)
f.stereo(nil, 0)
check(f.writes() == 0, 'Corrected without snap')
f.events.on_input_snap_turn(90)
check(f.writes() == 1 and near(f.mesh.rotation.Yaw, 0), 'Did not carry orientation immediately')
check(near(f.mesh.position.X, 100) and near(f.mesh.position.Y, 210) and near(f.mesh.position.Z, 70), 'Did not carry position around pawn pivot')
check(f.rig.snapTurnPending and not f.excluded.snapTurnPending, 'Unsupported parent changed')
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

-- Exercise actual parent inheritance between the pre/post input notifications.
-- In particular, non-stabilized RootComponent arms already turn here and must
-- not receive a second yaw rotation from the correction.
for _, coupling in ipairs({1, 2}) do
    for _, enhanced in ipairs({false, true}) do
        for _, delta in ipairs({-90, 90}) do
            local m = fixture(true, 0, {coupling = coupling, enhanced = enhanced})
            local label = string.format('parent=%d stabilized=%s delta=%d: ', coupling, tostring(enhanced), delta)
            m.events.on_input_pre_snap_turn(delta)
            if coupling == 1 then
                m.root.rotation.Yaw = delta
                m.moveParent(m.root.position, delta)
            end
            m.events.on_input_snap_turn(delta)
            local expectedPosition = vec(100, 200, 50) + rotate(vec(10, 0, 20), {Yaw = delta})
            check(near(m.mesh.rotation.Yaw, -90 + delta), label .. 'missing/double orientation carry')
            check(near(m.mesh.position.X, expectedPosition.X) and near(m.mesh.position.Y, expectedPosition.Y), label .. 'missing/double position carry')
            m.stereo(nil, 0)
            check(m.rig.snapTurnPending ~= nil, label .. 'stale first view consumed correction')
            m.setHmd({Pitch = 0, Yaw = delta, Roll = 0})
            m.stereo(nil, 1)
            if coupling == 2 and not enhanced then
                check(m.rig.snapTurnPending and not m.springArm.bEnableCameraRotationLag, label .. 'released before spring-arm cache tick')
                m.postTick()
                check(m.rig.snapTurnPending ~= nil, label .. 'mistook current post-tick for a fresh full tick')
                m.preTick()
                m.moveParent(vec(100, 200, 50) + rotate(vec(5, 0, 0), {Yaw = delta}), delta)
                check(near(m.mesh.position.X, expectedPosition.X) and near(m.mesh.rotation.Yaw, -90 + delta), label .. 'parent propagation undid hold')
                m.postTick()
                check(m.springArm.bEnableCameraRotationLag, label .. 'did not restore lag setting')
            elseif coupling == 2 then
                -- Stabilized HMD translation follows the head directly.
                m.moveParent(vec(100, 200, 50) + rotate(vec(5, 0, 0), {Yaw = delta}), delta)
            end
            check(not m.rig.snapTurnPending, label .. 'tracking handoff failed')
            check(not m.mesh.bAbsoluteLocation and m.mesh.bAbsoluteRotation == enhanced, label .. 'changed original inheritance flags')
            check(near(m.mesh.rotation.Yaw, -90 + delta), label .. 'rotation jumped at handoff')
            check(near(m.mesh.position.X, expectedPosition.X) and near(m.mesh.position.Y, expectedPosition.Y), label .. 'position jumped at handoff')
        end
    end
end
local delayedRoot = fixture(true, 0, {coupling = 1, enhanced = false})
delayedRoot.events.on_input_pre_snap_turn(30); delayedRoot.events.on_input_snap_turn(30)
delayedRoot.setHmd({Yaw = 30}); delayedRoot.stereo(nil, 1)
check(delayedRoot.rig.snapTurnPending ~= nil, 'Released while body root still at pre-snap yaw')
delayedRoot.root.rotation.Yaw = 30; delayedRoot.moveParent(delayedRoot.root.position, 30); delayedRoot.stereo(nil, 0)
check(not delayedRoot.rig.snapTurnPending and near(delayedRoot.mesh.rotation.Yaw, -60), 'Did not release when root caught up')
local springTimeout = fixture(true, 0, {enhanced = false})
springTimeout.springArm.bEnableCameraRotationLag = false
springTimeout.events.on_input_pre_snap_turn(30); springTimeout.events.on_input_snap_turn(30)
for view = 1, 8 do springTimeout.stereo(nil, view % 2) end
check(not springTimeout.rig.snapTurnPending and not springTimeout.springArm.bEnableCameraRotationLag, 'Spring-arm timeout changed original disabled lag')
check(not springTimeout.mesh.bAbsoluteLocation and not springTimeout.mesh.bAbsoluteRotation, 'Spring-arm timeout leaked absolute transform flags')
local inputCallback = cut(inputSource, 'uevr.sdk.callbacks.on_xinput_get_state(function', '-- register_key_bind("F1"')
local function inputFixture(snap, yawChange, disabled)
    local fn, notifications, rootYaw, captured = nil, 0, nil, false
    local env = setmetatable({isDisabled = false, rootComponent = {}, status = {}, decoupledYaw = 45, bodyRotationOffset = 5,
        getParameter = function() return snap end, isRotationModeRotationDisabled = function() return disabled end,
        updateDecoupledYaw = function() return yawChange end, setRootWorldYaw = function(yaw) rootYaw = yaw end,
        uevr = {sdk = {callbacks = {on_xinput_get_state = function(callback) fn = callback end}}},
        uevrUtils = {executeUEVRCallbacks = function(name, delta)
            if name == 'on_input_pre_snap_turn' then
                check(rootYaw == nil and delta == yawChange, 'Snapshot happened after root inherited snap')
                captured = true
            else
                check(captured and rootYaw == 50 and name == 'on_input_snap_turn' and delta == yawChange, 'Post event out of order')
                notifications = notifications + 1
            end
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
