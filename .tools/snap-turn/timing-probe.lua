-- Temporary read-only timing capture. Stops and unregisters itself after two
-- snaps plus eight ticks, or 90 seconds. UObject references are not serialized.
local utils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local input = require('libs/input')
local ik = require('libs/ik')
local data = {version = 1, status = 'ready', rows = {}, snaps = 0}
local frame, elapsed, untilFrame = 0, 0, nil
local alive = true
local callbacks = {}
local rigRef = setmetatable({}, {__mode = 'v'})
local hand = utils.fname_from_string('hand_r')
local function xyz(v) return v and {v.X, v.Y, v.Z} or nil end
local function pose(component)
    if utils.getValid(component) == nil then return nil end
    local r = component:K2_GetComponentRotation()
    return {p = xyz(component:K2_GetComponentLocation()), yaw = r.Yaw, pitch = r.Pitch, roll = r.Roll}
end
local function save()
    json.dump_file('snap_timing_probe.json', data, 2)
end
local function stop(reason)
    if not alive then return end
    alive = false
    data.status = reason
    for _, entry in ipairs(callbacks) do utils.unregisterUEVRCallback(entry.name, entry.fn) end
    callbacks = {}
    rigRef[1] = nil
    save()
end
local function register(name, fn, priority)
    local guarded = function(...)
        if not alive then return end
        local ok, err = pcall(fn, ...)
        if not ok then data.error = tostring(err); stop('error') end
    end
    callbacks[#callbacks + 1] = {name = name, fn = guarded}
    utils.registerUEVRCallback(name, guarded, priority)
end
ik.registerOnMeshCreatedCallback(function(meshes, rig)
    if alive then rigRef[1] = rig end
end)
local function sample(stage, eye, cameraPosition, cameraRotation)
    if not untilFrame or #data.rows >= 384 then return end
    local pawn = uevr.api:get_local_pawn(0)
    local root = utils.getValid(pawn, {'RootComponent'})
    local mesh = ik.getCurrentMesh()
    local rig = rigRef[1]
    local row = {stage = stage, frame = frame, snap = data.snaps, eye = eye,
        time = elapsed, firstEye = input.getFirstStereoViewIndex(),
        root = pose(root), hmd = pose(controllers.getController(2, true)),
        right = pose(controllers.getController(1, true)), mesh = pose(mesh),
        rotationOffset = input.getRotationOffset(),
        parent = rig and rig.coupling, stabilized = rig and rig.enhancedStabilization,
        tickPhase = rig and rig.tickPhase, pending = rig and rig.snapTurnPending ~= nil,
        viewPosition = xyz(cameraPosition), viewYaw = cameraRotation and cameraRotation.Yaw}
    if utils.getValid(mesh) ~= nil then
        row.bone = xyz(mesh:GetBoneLocationByName(hand, 0))
        row.socket = xyz(mesh:GetSocketLocation(hand))
        row.relative = xyz(mesh.RelativeLocation)
        row.absoluteLocation, row.absoluteRotation = mesh.bAbsoluteLocation, mesh.bAbsoluteRotation
    end
    data.rows[#data.rows + 1] = row
end
register('on_input_pre_snap_turn', function(delta)
    data.snaps = data.snaps + 1
    untilFrame = frame + 8
    data.status = 'recording'
    sample('before_snap')
    data.rows[#data.rows].snapAngle = delta
end, 10000)
register('on_input_snap_turn', function() sample('after_snap') end, -10000)
register('preEngineTick', function(engine, dt)
    frame = frame + 1
    elapsed = elapsed + dt
    if elapsed >= 90 then stop('timeout'); return end
    if untilFrame and frame > untilFrame then
        if data.snaps >= 2 then stop('complete'); return end
        data.status = 'waiting_for_second_snap'
        untilFrame = nil
        save()
    end
    sample('pre_tick_before_ik')
end, 10000)
register('preEngineTick', function() sample('pre_tick_after_ik') end, -10000)
register('postEngineTick', function() sample('post_tick_before_ik') end, 10000)
register('postEngineTick', function() sample('post_tick_after_ik') end, -10000)
register('preCalculateStereoView', function(device, eye, scale, position, rotation)
    sample('pre_stereo', eye, position, rotation)
end, -10000)
register('postCalculateStereoView', function(device, eye, scale, position, rotation)
    sample('post_stereo_before_correction', eye, position, rotation)
end, 10000)
register('postCalculateStereoView', function(device, eye, scale, position, rotation)
    sample('post_stereo_after_correction', eye, position, rotation)
end, -10000)
register('on_pre_level_change', function() stop('level_change') end, 10000)
save()
