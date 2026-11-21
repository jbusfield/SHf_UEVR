-- Isolated regression checks: no gameplay modules are executed or game callbacks registered.
local ikSource, inputSource, utilsSource, baselineSource = ...
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
local managerCode = cut(utilsSource, 'local function unregisterUEVRCallback(', 'local function executeUEVRCallbacksWithBooleanResult(')
local function callbackManager()
    local env = setmetatable({M = {}, uevrCallbacks = {}}, {__index = _G})
    return assert(load(managerCode .. [[
        return {register = M.registerUEVRCallback, unregister = M.unregisterUEVRCallback,
            dispatch = executeUEVRCallbacks, entries = uevrCallbacks}
    ]], '@actual callback manager', 't', env))()
end
local function fixture(enabled, oldYaw, options)
    options = options or {}
    oldYaw = oldYaw or 0
    local Rig, events, stereo, preStereo, preTick, postTick, writes, logs = {}, {}, nil, nil, nil, nil, 0, {}
    local manager = callbackManager()
    local counts = {rootReads = 0, hmdReads = 0, positionWrites = 0, meshLocationReads = 0, meshRotationReads = 0}
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
        counts.positionWrites = counts.positionWrites + 1
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
    local env = setmetatable({Rig = Rig, M = {print = function(message) error(message) end},
        enableSnapTurnCorrection = enabled, _rigInstances = {rig, excluded}, activeSnapTurns = {},
        instanceDestroyedCallbackList = {}, getRigParams = function() return nil end,
        handsAnimation = {destroyAnimationHandler = function() end},
        getPawn = function() counts.rootReads = counts.rootReads + 1; return {RootComponent = root} end,
        input = {getEffectivePawnRotationMode = function() return 4 end, PawnRotationMode = {RIGHT_CONTROLLER = 1, LEFT_CONTROLLER = 2}},
        controllers = {getControllerRotation = function() counts.hmdReads = counts.hmdReads + 1; return hmdRotation end},
        kismet_math_library = {ComposeRotators = function(self, a, b) return {Pitch = a.Pitch or 0, Yaw = a.Yaw + b.Yaw, Roll = a.Roll or 0} end},
        mathLib = {vectorRotate = rotate}, print = function(message) logs[#logs + 1] = message end,
        uevrUtils = {getValid = function(object, path) return path and object[path[1]] or object end,
            getComponentRotation = function(object)
                if object == mesh then counts.meshRotationReads = counts.meshRotationReads + 1 end
                return object.rotation
            end,
            getComponentLocation = function(object)
                if object == mesh then counts.meshLocationReads = counts.meshLocationReads + 1 end
                return object.position
            end,
            destroyComponentSafe = function() end, clearInterval = function() end,
            vector = vec, rotator = function(p, y, r) return {Pitch = p, Yaw = y, Roll = r} end,
            clampAngle180 = function(angle) return (angle + 180) % 360 - 180 end,
            registerUEVRCallback = function(name, fn, priority)
                manager.register(name, fn, priority)
                if name == 'on_input_pre_snap_turn' or name == 'on_input_snap_turn' then
                    events[name] = function(...) return manager.dispatch(name, ...) end
                end
            end,
            unregisterUEVRCallback = manager.unregister,
            registerPreCalculateStereoViewCallback = function(fn, priority) manager.register('preCalculateStereoView', fn, priority) end,
            registerPostCalculateStereoViewCallback = function(fn, priority) manager.register('postCalculateStereoView', fn, priority) end,
            registerPreEngineTickCallback = function(fn, priority) manager.register('preEngineTick', fn, priority) end,
            registerPostEngineTickCallback = function(fn, priority) manager.register('postEngineTick', fn, priority) end}}, {__index = _G})
    local source = options.source or ikSource
    assert(load(cut(source, 'function Rig:updateEnhancedMeshRotation(', 'function Rig:create()') ..
        cut(source, 'function M.destroy(instance, skipUnregister)', 'local function getBoneDirCS'), '@snap correction', 't', env))()
    if enabled then
        preStereo = function(...) return manager.dispatch('preCalculateStereoView', ...) end
        stereo = function(...) return manager.dispatch('postCalculateStereoView', ...) end
        preTick = function(...) return manager.dispatch('preEngineTick', ...) end
        postTick = function(...) return manager.dispatch('postEngineTick', ...) end
    end
    function rig:destroyDebugMeshes() end
    return {rig = rig, mesh = mesh, state = state, excluded = excluded, springArm = springArm, root = root,
        events = events, stereo = stereo, writes = function() return writes end, logs = logs,
        preTick = preTick, postTick = postTick, preStereo = preStereo,
        counts = counts, active = env.activeSnapTurns,
        manager = manager,
        setHmd = function(rotation) hmdRotation = rotation end,
        moveParent = function(position, yaw)
            parent.position, parent.yaw = position, yaw
            if not mesh.bAbsoluteLocation then mesh.position = parent.position + rotate(mesh.RelativeLocation, {Yaw = yaw}) end
            if not mesh.bAbsoluteRotation then
                mesh.rotation = {Pitch = mesh.RelativeRotation.Pitch, Yaw = mesh.RelativeRotation.Yaw + yaw, Roll = mesh.RelativeRotation.Roll}
            end
        end,
        destroy = function() env.M.destroy(rig, true); env._rigInstances = {} end}
end
local off = fixture(false)
check(off.stereo == nil and off.preStereo == nil and off.preTick == nil and off.postTick == nil and next(off.events) == nil and #off.logs == 0, 'Disabled gate added behavior')
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

local function assertPosition(actual, expected, message)
    check(near(actual.X, expected.X) and near(actual.Y, expected.Y) and near(actual.Z, expected.Z), message)
end
for _, enhanced in ipairs({false, true}) do
    for _, delta in ipairs({-30, 30}) do
        local moving = fixture(true, 0, {coupling = 1, enhanced = enhanced})
        local offset = rotate(vec(10, 0, 20), {Yaw = delta})
        moving.events.on_input_pre_snap_turn(delta)
        moving.root.rotation.Yaw = delta; moving.moveParent(moving.root.position, delta)
        moving.events.on_input_snap_turn(delta)
        -- Movement/roomscale after engine tick, before each view. Root yaw can
        -- still counterturn while the head cache is stale; translation must follow.
        moving.root.rotation.Yaw = 0
        moving.root.position = vec(103, 201, 50.2); moving.moveParent(moving.root.position, 0)
        moving.preStereo(nil, 0)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Lost moving-root translation before first eye')
        check(near(moving.mesh.rotation.Yaw, -90 + delta), 'Root counterturn undid held yaw')
        moving.root.position = vec(104, 202, 50.4); moving.moveParent(moving.root.position, 0)
        moving.preStereo(nil, 1)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Lost per-view roomscale/stair translation')
        moving.setHmd({Yaw = delta}); moving.stereo(nil, 1)
        check(moving.rig.snapTurnPending ~= nil, 'Released while root yaw was still stale')
        moving.root.position = vec(105, 203, 50.6); moving.moveParent(moving.root.position, 0)
        moving.preTick()
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Lost translation before engine tick')
        -- Also account for movement arriving immediately before the handoff.
        moving.root.rotation.Yaw = delta
        moving.root.position = vec(106, 204, 50.8); moving.moveParent(moving.root.position, delta)
        moving.stereo(nil, 0)
        check(not moving.rig.snapTurnPending, 'Moving-root correction failed to release')
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Position jumped at moving handoff')
        moving.root.position = vec(107, 205, 51); moving.moveParent(moving.root.position, delta)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Root inheritance failed after moving handoff')
    end
end
local consecutive = fixture(true, 0, {coupling = 1, enhanced = true})
consecutive.events.on_input_pre_snap_turn(30)
consecutive.root.rotation.Yaw = 30; consecutive.moveParent(consecutive.root.position, 30)
consecutive.events.on_input_snap_turn(30)
consecutive.root.position = vec(103, 201, 51); consecutive.moveParent(consecutive.root.position, 30)
-- A second snap before any stereo refresh must first include that translation.
consecutive.events.on_input_pre_snap_turn(30)
consecutive.root.rotation.Yaw = 60; consecutive.moveParent(consecutive.root.position, 60)
consecutive.events.on_input_snap_turn(30)
assertPosition(consecutive.mesh.position, consecutive.root.position + rotate(vec(10, 0, 20), {Yaw = 60}), 'Consecutive moving snaps lost translation')
check(f.rig.snapTurnPending == nil and f.rig.enhancedStabilization and f.rig.coupling == 2, 'HMD baseline changed')

for _, lagEnabled in ipairs({false, true}) do
    for _, delta in ipairs({-30, 30}) do
        local moving = fixture(true, 0, {coupling = 2, enhanced = false})
        moving.springArm.bEnableCameraRotationLag = lagEnabled
        local offset = rotate(vec(10, 0, 20), {Yaw = delta})
        moving.events.on_input_pre_snap_turn(delta)
        moving.root.rotation.Yaw = delta
        moving.events.on_input_snap_turn(delta)
        moving.root.position = vec(103, 201, 50.2)
        moving.preStereo(nil, 0)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'HMD spring-arm hold lost locomotion before first eye')
        moving.stereo(nil, 0)
        check(moving.rig.snapTurnPending ~= nil, 'HMD hold released with stale tracking')
        moving.setHmd({Yaw = delta})
        moving.moveParent(moving.root.position + rotate(vec(5, 0, 0), {Yaw = delta}), delta)
        moving.preStereo(nil, 1); moving.stereo(nil, 1)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Refreshed HMD parent double-translated held arms')
        check(moving.rig.snapTurnPending ~= nil and not moving.springArm.bEnableCameraRotationLag, 'Spring-arm wait/lag suppression changed')
        moving.root.position = vec(105, 203, 50.5)
        moving.preTick()
        assertPosition(moving.mesh.position, moving.root.position + offset, 'HMD spring-arm hold lost next-tick locomotion')
        -- Keep moving throughout the extra engine tick needed to reset the cache.
        moving.root.position = vec(107, 204, 51)
        moving.moveParent(moving.root.position + rotate(vec(5, 0, 0), {Yaw = delta}), delta)
        moving.preStereo(nil, 0)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'HMD hold froze during cache-refresh frame')
        moving.postTick()
        check(not moving.rig.snapTurnPending, 'Moving HMD spring-arm hold never released')
        assertPosition(moving.mesh.position, moving.root.position + offset, 'Moving HMD jumped when spring-arm parenting resumed')
        check(near(moving.mesh.rotation.Yaw, -90 + delta), 'Moving HMD yaw changed at handoff')
        check(moving.springArm.bEnableCameraRotationLag == lagEnabled, 'Changed original spring-arm lag setting')
        check(not moving.mesh.bAbsoluteLocation and not moving.mesh.bAbsoluteRotation, 'HMD hold leaked absolute flags')
        moving.root.position = vec(109, 206, 52)
        moving.moveParent(moving.root.position + rotate(vec(5, 0, 0), {Yaw = delta}), delta)
        assertPosition(moving.mesh.position, moving.root.position + offset, 'HMD did not resume ordinary parent translation')
    end
end
local hmdConsecutive = fixture(true, 0, {coupling = 2, enhanced = false})
hmdConsecutive.events.on_input_pre_snap_turn(30); hmdConsecutive.events.on_input_snap_turn(30)
hmdConsecutive.root.position = vec(103, 201, 51)
hmdConsecutive.events.on_input_pre_snap_turn(30); hmdConsecutive.events.on_input_snap_turn(30)
assertPosition(hmdConsecutive.mesh.position, hmdConsecutive.root.position + rotate(vec(10, 0, 20), {Yaw = 60}), 'Consecutive HMD snaps lost accumulated movement')
hmdConsecutive.setHmd({Yaw = 60}); hmdConsecutive.stereo(nil, 1); hmdConsecutive.preTick()
hmdConsecutive.moveParent(hmdConsecutive.root.position + rotate(vec(5, 0, 0), {Yaw = 60}), 60)
hmdConsecutive.postTick()
check(not hmdConsecutive.rig.snapTurnPending and hmdConsecutive.springArm.bEnableCameraRotationLag, 'Consecutive HMD snaps failed to restore lag')
assertPosition(hmdConsecutive.mesh.position, hmdConsecutive.root.position + rotate(vec(10, 0, 20), {Yaw = 60}), 'Consecutive moving HMD snaps jumped at handoff')

local idle = fixture(true)
local function frameCallbacks(f)
    local n = 0
    for _, name in ipairs({'preCalculateStereoView', 'postCalculateStereoView', 'preEngineTick', 'postEngineTick'}) do
        n = n + #(f.manager.entries[name] or {})
    end
    return n
end
check(frameCallbacks(idle) == 0, 'Idle snap-turn callbacks remain registered')
for _ = 1, 50 do idle.preStereo(); idle.stereo(); idle.preTick(); idle.postTick() end
check(idle.counts.rootReads == 0 and idle.counts.hmdReads == 0, 'Idle callbacks queried game transforms')
check(idle.counts.positionWrites == 0 and #idle.logs == 0, 'Idle callbacks wrote transforms or logged')

local stationary = fixture(true, 0, {coupling = 1, enhanced = false})
stationary.events.on_input_pre_snap_turn(30); stationary.events.on_input_snap_turn(30)
local positionWrites = stationary.counts.positionWrites
for _ = 1, 20 do stationary.preStereo(); stationary.preTick() end
check(stationary.counts.positionWrites == positionWrites, 'Repeated unchanged-root position writes')
stationary.root.position = vec(103, 201, 50.2)
stationary.preStereo()
check(stationary.counts.positionWrites == positionWrites + 1, 'Moved root did not produce exactly one position update')
stationary.preStereo(); stationary.preTick()
check(stationary.counts.positionWrites == positionWrites + 1, 'Repeated a position update without further movement')
stationary.root.rotation.Yaw = 30; stationary.moveParent(stationary.root.position, 30)
stationary.setHmd({Yaw = 30})
local locationReads, rotationReads = stationary.counts.meshLocationReads, stationary.counts.meshRotationReads
stationary.stereo()
check(stationary.counts.meshLocationReads == locationReads and stationary.counts.meshRotationReads == rotationReads, 'Handoff fetched unused mesh transforms')
check(next(stationary.active) == nil, 'Finished turn remained in active list')
check(frameCallbacks(stationary) == 0, 'Finished turn left frame callbacks registered')

local destroyed = fixture(true, 0, {coupling = 2, enhanced = false})
destroyed.events.on_input_pre_snap_turn(30); destroyed.events.on_input_snap_turn(30)
check(next(destroyed.active) ~= nil, 'Pending turn was not tracked')
destroyed.destroy()
check(next(destroyed.active) == nil and destroyed.rig.snapTurnPending == nil, 'Destroy retained active turn or stale mesh references')
check(frameCallbacks(destroyed) == 0, 'Destroy left temporary frame callbacks registered')
local rootReads, hmdReads = destroyed.counts.rootReads, destroyed.counts.hmdReads
destroyed.preStereo(); destroyed.stereo(); destroyed.preTick(); destroyed.postTick()
check(destroyed.counts.rootReads == rootReads and destroyed.counts.hmdReads == hmdReads, 'Destroyed turn still queried game state')

for _, mode in ipairs({{1, false, 3}, {1, true, 3}, {2, false, 4}, {2, true, 1}}) do
    local m = fixture(true, 0, {coupling = mode[1], enhanced = mode[2]})
    m.events.on_input_pre_snap_turn(30); m.events.on_input_snap_turn(30)
    check(frameCallbacks(m) == mode[3], 'Mode registered an unnecessary update phase')
    m.destroy()
end
local ordered = fixture(true)
local calls = {}
ordered.manager.register('postCalculateStereoView', function() calls[#calls + 1] = 'first' end, 0)
ordered.manager.register('postCalculateStereoView', function() calls[#calls + 1] = 'second' end, -1000000)
ordered.events.on_input_pre_snap_turn(30); ordered.events.on_input_snap_turn(30)
ordered.setHmd({Yaw = 30}); ordered.stereo()
check(table.concat(calls, ',') == 'first,second' and not ordered.rig.snapTurnPending, 'Self-removal skipped another stereo callback')
check(#ordered.manager.entries.postCalculateStereoView == 2, 'Self-removal deleted another handler')
ordered.stereo()
check(table.concat(calls, ',') == 'first,second,first,second', 'Other handlers failed after snap completion')
local interrupted = fixture(true)
calls = {}
interrupted.manager.register('postCalculateStereoView', function() interrupted.destroy(); calls[#calls + 1] = 'destroy' end, 0)
interrupted.manager.register('postCalculateStereoView', function() calls[#calls + 1] = 'other' end, -100)
interrupted.events.on_input_pre_snap_turn(30); interrupted.events.on_input_snap_turn(30); interrupted.stereo()
check(table.concat(calls, ',') == 'destroy,other', 'Destruction during dispatch skipped another handler')

if baselineSource then
    local function observations(source, coupling, enhanced, delta)
        local oldYaw = delta > 0 and 175 or -175
        local m = fixture(true, oldYaw, {coupling = coupling, enhanced = enhanced, source = source})
        local rows = {}
        local function record()
            rows[#rows + 1] = {m.mesh.position.X, m.mesh.position.Y, m.mesh.position.Z,
                m.mesh.rotation.Yaw, m.mesh.bAbsoluteLocation, m.mesh.bAbsoluteRotation,
                m.springArm.bEnableCameraRotationLag, m.rig.snapTurnPending ~= nil}
        end
        record(); m.events.on_input_pre_snap_turn(delta)
        m.root.rotation.Yaw = delta
        if coupling == 1 then m.moveParent(m.root.position, delta) end
        m.events.on_input_snap_turn(delta); record()
        m.root.position = vec(103, 201, 50.2)
        if coupling == 1 then m.moveParent(m.root.position, 0) end
        m.preStereo(nil, 0); m.stereo(nil, 0); record()
        local newYaw = (oldYaw + delta + 180) % 360 - 180
        m.setHmd({Yaw = newYaw}); m.root.rotation.Yaw = delta
        if coupling == 1 then m.moveParent(m.root.position, delta)
        else m.moveParent(m.root.position + rotate(vec(5, 0, 0), {Yaw = newYaw}), newYaw) end
        m.preStereo(nil, 1); m.stereo(nil, 1); record()
        m.root.position = vec(105, 202, 50.4); m.preTick(); record()
        if coupling == 1 then m.moveParent(m.root.position, delta)
        else m.moveParent(m.root.position + rotate(vec(5, 0, 0), {Yaw = newYaw}), newYaw) end
        m.preStereo(nil, 0); m.stereo(nil, 0); m.postTick(); record()
        m.destroy(); record()
        return rows
    end
    for _, coupling in ipairs({1, 2}) do
        for _, enhanced in ipairs({false, true}) do
            for _, delta in ipairs({-30, 30}) do
                local before = observations(baselineSource, coupling, enhanced, delta)
                local after = observations(ikSource, coupling, enhanced, delta)
                for row, values in ipairs(before) do
                    for column, value in ipairs(values) do
                        local actual = after[row][column]
                        check(type(value) == 'number' and near(value, actual) or value == actual,
                            'Confirmed baseline differs: mode=' .. coupling .. ' stabilization=' .. tostring(enhanced) .. ' row=' .. row .. ' column=' .. column)
                    end
                end
            end
        end
    end
end
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
