-- Execute only mocked Lua functions: no game objects, hooks, or real callbacks.
local count = 0
local optimizationReport
local function check(condition, message)
    assert(condition, message)
    count = count + 1
end
local function near(actual, expected, message)
    check(type(actual) == 'number' and math.abs(actual - expected) < 0.00001,
        message .. ': got ' .. tostring(actual) .. ', expected ' .. expected)
end
for name, source in pairs(sources) do
    check(load(source, name, 't', {}) ~= nil, name .. ' compiles')
end
local enums = assert(load(sources.enums, 'enums', 't', {}))()
local start = assert(sources.input:find('local customHeightCallback = nil', 1, true))
local finish = assert(sources.input:find('local function getVRCameraOffsets()', start, true))
local heightCode = sources.input:sub(start, finish - 1)
local function legacyFunction(source)
    local first = assert(source:find('local function getVRCameraOffsets()', 1, true))
    local last = assert(source:find('--native stereo uses', first, true))
    return source:sub(first, last - 1):gsub('\r', '')
end
check(legacyFunction(sources.input) == legacyFunction(sources.preMesh), 'camera calculation unchanged by mesh optimization')
local function removeLiteral(source, text)
    local first, last = source:find(text, 1, true)
    assert(first, 'Expected added hook: ' .. text)
    return source:sub(1, first - 1) .. source:sub(last + 1)
end
local function withoutMeshFunctions(source)
    local first = source:find('local zeroMeshPositionDelta =', 1, true) or assert(source:find('local function getAnimationHeadDelta(', 1, true))
    local last = assert(source:find('local function getPawnRotationMode()', first, true))
    source = source:sub(1, first - 1) .. source:sub(last)
    first = source:find('-- Named protected-call target avoids a per-tick capturing closure.', 1, true) or assert(source:find('local function updateMeshRelativePosition(', 1, true))
    last = assert(source:find('function M.setAimRotationOffset(', first, true))
    return source:sub(1, first - 1) .. source:sub(last)
end
local unchanged = sources.input:gsub('\r', '')
local docFirst = assert(unchanged:find('\n\tinput.setHeightSource(', 1, true))
local docLast = assert(unchanged:find('\n\tinput.init((optional)', docFirst, true))
unchanged = unchanged:sub(1, docFirst - 1) .. unchanged:sub(docLast)
local first = assert(unchanged:find('-- Height sources only replace', 1, true))
local last = assert(unchanged:find('local function getVRCameraOffsets()', first, true))
unchanged = unchanged:sub(1, first - 1) .. unchanged:sub(last)
unchanged = removeLiteral(unchanged, '\nM.HeightSource = inputEnums.HeightSource')
unchanged = removeLiteral(unchanged, '\n\t\tinput.HeightSource - ROOT_COMPONENT (default), PAWN_BONE, CUSTOM')
local defaultsFirst = assert(unchanged:find('\n\theightSource = M.HeightSource.ROOT_COMPONENT,', 1, true))
local defaultsLast = assert(unchanged:find('\n\theightBoneFollow = false,', defaultsFirst, true))
unchanged = unchanged:sub(1, defaultsFirst - 1) .. unchanged:sub(defaultsLast + #'\n\theightBoneFollow = false,')
unchanged = removeLiteral(unchanged, '\n\tif key == "heightSource" or key == "heightBoneName" then\n\t\tM.resetHeightSource()\n\tend')
unchanged = removeLiteral(unchanged, '\n\t\tz = applyHeightSource(z)')
unchanged = removeLiteral(unchanged, '\n\tupdateHeightSource(delta)')
unchanged = removeLiteral(unchanged, '\n\tM.resetHeightSource()')
check(withoutMeshFunctions(sources.input) == withoutMeshFunctions(sources.preMesh), 'mesh optimization leaves all other functions unchanged')

local function fixture(params, code)
    params = params or {}
    local metrics = {names = 0, indices = 0, sockets = 0, meshLists = 0, settings = 0}
    local root = {CapsuleHalfHeight = 80, z = 1000}
    local mesh = {z = 1060, validBone = true}
    function mesh:GetBoneIndex(name) metrics.indices = metrics.indices + 1; return self.validBone and name == 'Head' and 0 or -1 end
    function mesh:GetSocketLocation() metrics.sockets = metrics.sockets + 1; return {Z = self.z} end
    local pawn = {}
    local state = {pawn = pawn}
    local profileCallbacks, events = {}, {}
    local env = setmetatable({
        M = {HeightSource = enums.HeightSource}, status = state,
        rootComponent = root, bodyMesh = mesh, isDisabled = false,
        getParameter = function(key) metrics.settings = metrics.settings + 1; return params[key] end,
        saveParameter = function(key, value) params[key] = value; env.M.resetHeightSource() end,
        getRootOffsetEnabled = function() return params.useRootOffset ~= false end,
        getBodyMesh = function() metrics.meshLists = metrics.meshLists + 1; return {mesh} end,
        uevrUtils = {
            profiler = {wrap = function(_, _, fn) return fn end},
            getValid = function(value) if value and not value.invalid then return value end end,
            getComponentLocation = function(value) return {Z = value.z} end,
            fname_from_string = function(value) metrics.names = metrics.names + 1; return value end,
            registerUEVRCallback = function(name, callback) events[name] = callback end,
        },
        paramManager = {
            getAllActiveProfileParams = function() return params end,
            registerProfileChangeCallback = function(_, callback) profileCallbacks[#profileCallbacks+1] = callback end,
        },
    }, {__index = _G})
    -- This closure must capture the already initialized environment.
    env.saveParameter = function(key, value) params[key] = value; env.M.resetHeightSource() end
    local make = assert(load((code or heightCode) .. '\nreturn {update = updateHeightSource, apply = applyHeightSource}', 'height', 't', env))
    local h = make()
    h.params, h.root, h.mesh, h.pawn, h.state, h.env = params, root, mesh, pawn, state, env
    h.api, h.events, h.profileCallbacks = env.M, events, profileCallbacks
    h.metrics = metrics
    function h:tick(n, delta)
        for _ = 1, (n or 1) do self.update(delta or 0.05) end
        return self.apply(self.root.z + self.root.CapsuleHalfHeight + 7)
    end
    return h
end

local h = fixture()
local calls = 0
h.api.registerCustomHeightCallback(function() calls = calls + 1; return 0 end)
near(h:tick(), 1087, 'missing setting defaults to legacy root height')
near(calls, 0, 'root mode never calls a custom provider')
check(h.state.heightSourceState == nil, 'root mode allocates no tracking state')
h.params.heightSource = enums.HeightSource.CUSTOM
h.api.registerCustomHeightCallback(function(pawn, root, defaultHeight, delta)
    check(pawn == h.pawn and root == h.root and defaultHeight == 80 and delta == 0.05, 'custom context and units')
    calls = calls + 1
    return 12
end)
near(h:tick(), 1019, 'custom replaces height and retains offsets')
near(h.apply(1087), 1019, 'first eye uses cached custom height')
near(h.apply(1087), 1019, 'second eye uses identical cached custom height')
near(calls, 1, 'custom called once per tick, never per eye')
for _, bad in ipairs({false, '12', math.huge, 0/0}) do
    h.api.registerCustomHeightCallback(function() return bad end)
    near(h:tick(), 1087, 'invalid custom result falls back')
end
h.api.registerCustomHeightCallback(function() error('provider error') end)
near(h:tick(), 1087, 'custom error falls back')
h.api.registerCustomHeightCallback(function() return nil end)
near(h:tick(), 1087, 'nil custom result falls back')
h.api.registerCustomHeightCallback(nil)
near(h:tick(), 1087, 'unregistered provider falls back')

h = fixture({heightSource = 2, heightBoneName = 'Head', heightBoneSmoothTime = 0})
near(h:tick(), 1067, 'bone selects actual bone height and retains offsets')
for _, z in ipairs({1053, 1068, 1040, 1075, 1060}) do
    h.mesh.z = z
    near(h:tick(5), 1067, 'idle and running movement below threshold is ignored')
end
h.mesh.z = 1000
near(h:tick(), 1067, 'brief large dip does not activate')
h.mesh.z = 1060
near(h:tick(), 1067, 'return cancels pending dip')
h.mesh.z = 1000
near(h:tick(4), 1007, 'sustained crawl latches lower height')
local deeper = fixture({heightSource = 2, heightBoneName = 'Head', heightBoneSmoothTime = 0})
deeper:tick()
deeper.mesh.z = 1000
near(deeper:tick(4), 1007, 'deeper posture starts in crawl')
deeper.mesh.z = 940
near(deeper:tick(4), 947, 'another substantial displacement updates held height')
deeper.mesh.z = 1000
near(deeper:tick(4), 947, 'partial return retains hysteresis until near standing')
h.mesh.z = 1010
near(h:tick(5), 1007, 'crawl bob does not move latched camera')
h.mesh.z = 1040
near(h:tick(5), 1007, 'hysteresis retains crawl between exit and enter thresholds')
h.mesh.z = 1050
near(h:tick(), 1007, 'exit requires confirmation')
near(h:tick(4), 1067, 'return inside exit threshold restores standing height')
h.mesh.z = 1000
h.params.heightBoneFollow = true
near(h:tick(4), 1007, 'follow mode activates after confirmation')
h.mesh.z = 1010
near(h:tick(), 1017, 'optional follow mode follows active bone')
h.params.heightBoneUseThreshold = false
h.mesh.z = 1020
near(h:tick(), 1027, 'threshold disabled follows directly')
h.root.z, h.mesh.z = 1500, 1520
near(h:tick(), 1527, 'world movement is not smoothed or thresholded')
h.params.heightBoneSmoothTime = 0.2
h.mesh.z = 1500
local smoothed = h:tick()
check(smoothed > 1507 and smoothed < 1527, 'animation height is smoothed')
h.mesh.validBone = false
h.mesh.SkeletalMesh = {} -- a changed asset can remove the selected bone
near(h:tick(), 1587, 'missing bone falls back without stale height')
h.mesh.validBone = true
h.mesh.z = 1560
h.api.resetHeightSource()
near(h:tick(), 1567, 'explicit standing recalibration resets filter')
h.mesh.z = 1500
h.params.heightBoneUseThreshold = true
h.params.heightBoneSmoothTime = 0
near(h:tick(4), 1507, 'threshold can be enabled again')
h.profileCallbacks[1]()
h.mesh.z = 1550
near(h:tick(), 1557, 'profile change recalibrates independently')
h.events.reset_input_height_source()
check(h.state.heightSourceState == nil, 'UI recalibration clears state')

-- A pure capsule-center shift with unchanged head/feet must not lower twice.
h = fixture({heightSource = 2, heightBoneName = 'Head', heightBoneSmoothTime = 0})
near(h:tick(), 1067, 'capsule reference initial')
h.root.z, h.root.CapsuleHalfHeight = 960, 40
near(h.apply(1007), 1067, 'capsule resize between tick and stereo preserves reference')
near(h:tick(5), 1067, 'capsule resize alone preserves bone world height')
h.mesh.z = 1000
near(h:tick(4), 1007, 'capsule resize plus crawl uses bone once')
h.env.isDisabled = true
local old = h.state.heightSourceState
h.mesh.z = 1060
h:tick(4)
check(h.state.heightSourceState == old, 'disabled input does not run height tracking')

-- Compare against the user's version captured immediately before optimization.
local preoptStart = assert(sources.preopt:find('local customHeightCallback = nil', 1, true))
local preoptFinish = assert(sources.preopt:find('local function getVRCameraOffsets()', preoptStart, true))
local preoptCode = sources.preopt:sub(preoptStart, preoptFinish - 1)
local function withoutHeightBlock(source)
    local first = assert(source:find('local customHeightCallback = nil', 1, true))
    local last = assert(source:find('local function getVRCameraOffsets()', first, true))
    return source:sub(1, first - 1) .. source:sub(last)
end
check(withoutMeshFunctions(withoutHeightBlock(sources.input)) == withoutMeshFunctions(withoutHeightBlock(sources.preMesh)), 'optimizations are confined to height and mesh source functions')
for _, follow in ipairs({false, true}) do
    for _, threshold in ipairs({false, true}) do
        local old = fixture({heightSource=2, heightBoneName='Head', heightBoneFollow=follow, heightBoneUseThreshold=threshold, heightBoneSmoothTime=0.12}, preoptCode)
        local optimized = fixture({heightSource=2, heightBoneName='Head', heightBoneFollow=follow, heightBoneUseThreshold=threshold, heightBoneSmoothTime=0.12})
        for tick = 1, 120 do
            local offset = tick < 20 and math.sin(tick) * 10 or (tick < 75 and -60 + math.sin(tick)*4 or 0)
            old.mesh.z, optimized.mesh.z = 1060 + offset, 1060 + offset
            near(optimized:tick(), old:tick(), 'optimized motion matches previous output')
        end
        near(optimized.metrics.names, 1, 'bone name conversion cached across 120 ticks')
        near(optimized.metrics.indices, 1, 'bone index lookup cached across 120 ticks')
        near(optimized.metrics.sockets, 120, 'animation position is still sampled every tick')
        near(optimized.metrics.meshLists, 0, 'optimized sampling creates no temporary mesh lists')
        near(optimized.metrics.settings, 0, 'height settings avoid key-path lookups')
        near(old.metrics.names, 120, 'previous version converted bone name every tick')
        optimizationReport = string.format('Per 120 ticks: FName conversions %d -> %d; bone-index lookups %d -> %d; temporary mesh lists %d -> %d; height parameter-path lookups %d -> %d. Position samples remain %d.',
            old.metrics.names, optimized.metrics.names, old.metrics.indices, optimized.metrics.indices,
            old.metrics.meshLists, optimized.metrics.meshLists, old.metrics.settings, optimized.metrics.settings,
            optimized.metrics.sockets)
    end
end
h = fixture({heightSource=2, heightBoneName='Head', heightBoneSmoothTime=0})
h:tick(5)
h.mesh.SkeletalMesh = {}
h.mesh.validBone = false
near(h:tick(5), 1087, 'asset swap to missing bone safely falls back')
near(h.metrics.indices, 2, 'negative lookup is cached for the replacement asset')
h.mesh.SkeletalMesh = {}
h.mesh.validBone = true
near(h:tick(), 1067, 'another asset swap restores a valid bone')
near(h.metrics.indices, 3, 'asset replacement invalidates bone cache')
h.params.heightBoneName = 'missing'
near(h:tick(5), 1087, 'bone name edit invalidates cache without explicit reset')
near(h.metrics.indices, 4, 'changed bone is resolved once')
h.params.heightBoneName = 'Head'
near(h:tick(), 1067, 'editing back to valid bone restores height')
h.env.bodyMesh = nil
h.env.pawnModule = {getBodyMesh = function() return nil end}
near(h:tick(), 1087, 'temporarily missing mesh falls back')
h.env.bodyMesh = h.mesh
h.mesh.invalid = true
near(h:tick(), 1087, 'cached UObject validity is still checked')
h.mesh.invalid = false
h.api.resetHeightSource()
h:tick()
near(h.metrics.indices, 6, 'standing recalibration rebuilds cache')

-- Load the complete developer UI with inert config/pawn services.
local widgets, values, updates, creates, intervals, listeners = {}, {}, {}, {}, {}, {}
local heightWrites, boneQueries = 0, 0
local params = {rootOffset = {X=0,Y=0,Z=0}, headOffset = {X=0,Y=0,Z=0}}
local currentMesh = {}
local boneNames = {'root', 'Head', 'neck'}
local ui = {}
local function addHandler(list, id, callback)
    list[id] = list[id] or {}
    table.insert(list[id], callback)
end
local function emit(id, value)
    values[id] = value
    for _, callback in ipairs(updates[id] or {}) do callback(value) end
end
ui.onUpdate = function(id, callback) addHandler(updates, id, callback) end
ui.onCreate = function(id, callback) addHandler(creates, id, callback) end
ui.onCreateOrUpdate = function(id, callback) ui.onUpdate(id, callback); ui.onCreate(id, callback) end
ui.getValue = function(id) return values[id] end
ui.setValue = function(id, value, silent) if silent then values[id] = value else emit(id, value) end end
ui.setSelections = function(id, selections) if widgets[id] then widgets[id].selections = selections end end
ui.hideWidget = function(id, hidden) if widgets[id] then widgets[id].isHidden = hidden end end
ui.setHidden = ui.hideWidget
ui.applyOptionsToConfigWidgets = function(layout) return layout end
ui.create = function(definition)
    for _, panel in ipairs(definition) do
        for _, widget in ipairs(panel.layout) do
            if widget.id then widgets[widget.id] = widget; values[widget.id] = widget.initialValue end
        end
    end
    for id in pairs(widgets) do
        for _, callback in ipairs(creates[id] or {}) do callback(values[id]) end
    end
end
local profile = {
    getAllActiveProfileParams = function() return params end,
    getProfilePreConfigurationWidgets = function() return {} end,
    getProfilePostConfigurationWidgets = function() return {} end,
    initProfileHandler = function(self, _, callback) self.callback = callback; callback(params) end,
}
local utils = {
    getValid = function(value) return value end,
    getBoneNames = function() boneQueries = boneQueries + 1; return boneNames end,
    getNativeValue = function(value) return value end,
    indexOf = function(list, value) for i,v in ipairs(list) do if v == value then return i end end end,
    getObjectPropertyDescriptors = function() return {} end,
    registerLevelChangeCallback = function() end,
    registerUEVRCallback = function(name, callback) addHandler(listeners, name, callback) end,
    executeUEVRCallbacks = function(name, key, value, persist)
        if name == 'on_input_config_param_change' and key:sub(1,6) == 'height' then
            params[key] = value
            if persist then heightWrites = heightWrites + 1 end
        end
        for _, callback in ipairs(listeners[name] or {}) do callback(key, value, persist) end
    end,
}
local dependencies = {
    ['libs/uevr_utils'] = utils, ['libs/configui'] = ui,
    ['libs/body_yaw'] = {getConfigurationWidgets = function() return {} end},
    ['libs/pawn'] = {getBodyMesh = function() return currentMesh end},
    ['libs/enums/input'] = enums,
}
local env = setmetatable({
    require = function(name) return assert(dependencies[name], name) end,
    setInterval = function(_, callback) intervals[#intervals+1] = callback end,
    expandArray = function(fn, ...) return {expanded = fn(...)} end,
    spliceableInlineArray = function(layout)
        local flat = {}
        for _, item in ipairs(layout) do
            if item.expanded then for _, widget in ipairs(item.expanded) do flat[#flat+1] = widget end
            else flat[#flat+1] = item end
        end
        return flat
    end,
}, {__index = _G})
local config = assert(load(sources.ui, 'input_config_dev', 't', env))()
config.init(profile)
local prefix = 'uevr_input_'
near(values[prefix .. 'heightSource'], 1, 'old profile displays RootComponent')
near(heightWrites, 0, 'UI initialization never persists height defaults')
near(boneQueries, 0, 'default UI does not query a height bone')
check(widgets[prefix .. 'height_bone_group'].isHidden, 'bone settings hidden by default')
check(widgets[prefix .. 'height_custom_group'].isHidden, 'custom help hidden by default')
local layout = config.getConfigurationWidgets()
local sourceIndex, offsetIndex
for i,w in ipairs(layout) do
    if w.id == prefix .. 'heightSource' then sourceIndex = i end
    if w.id == prefix .. 'useRootOffset' then offsetIndex = i end
end
check(sourceIndex and offsetIndex and sourceIndex < offsetIndex, 'Height Source precedes HMD checkbox')
check(table.concat(widgets[prefix .. 'heightSource'].selections, ',') == 'RootComponent,Pawn Bone,Custom', 'source order')
emit(prefix .. 'heightSource', 2)
check(not widgets[prefix .. 'height_bone_group'].isHidden, 'Pawn Bone reveals bone settings')
check(widgets[prefix .. 'height_custom_group'].isHidden, 'Pawn Bone hides custom help')
near(#widgets[prefix .. 'heightBoneName'].selections, 4, 'bone picker includes None and configured body bones')
emit(prefix .. 'heightBoneName', 3)
check(params.heightBoneName == 'Head', 'bone selection persists its name, not an index')
local writesBefore = heightWrites
boneNames = {'Head', 'neck', 'root'}
currentMesh = {}
intervals[1]()
near(values[prefix .. 'heightBoneName'], 2, 'mesh refresh preserves selected bone after reorder')
near(heightWrites, writesBefore, 'mesh refresh never overwrites profile bone')
emit(prefix .. 'heightBoneUseThreshold', false)
check(widgets[prefix .. 'height_threshold_group'].isHidden, 'disabling hysteresis hides threshold settings')
emit(prefix .. 'heightBoneSmoothTime', 0.3)
near(params.heightBoneSmoothTime, 0.3, 'numeric settings are saved')
check(params.heightBoneUseThreshold == false, 'false settings are preserved')
emit(prefix .. 'heightSource', 3)
check(widgets[prefix .. 'height_bone_group'].isHidden and not widgets[prefix .. 'height_custom_group'].isHidden, 'Custom visibility')
params = {rootOffset = {X=0,Y=0,Z=0}, headOffset = {X=0,Y=0,Z=0}}
writesBefore = heightWrites
profile.callback(params)
near(values[prefix .. 'heightSource'], 1, 'switching to legacy profile resets displayed source')
near(values[prefix .. 'heightBoneEnterThreshold'], 30, 'legacy profile gets display-only threshold defaults')
check(values[prefix .. 'heightBoneUseThreshold'] == true, 'legacy profile gets display-only checkbox default')
near(heightWrites, writesBefore, 'profile switching does not persist new settings')
params.heightSource, params.heightBoneName = 2, 'neck'
profile.callback(params)
near(values[prefix .. 'heightBoneName'], 3, 'profile restores bone by name')
near(heightWrites, writesBefore, 'restoring bone profile is read-only')
local meshResult = assert(load(sources.meshTests, 'mesh-tests', 't', _G))(sources)
return 'PASS: ' .. count .. ' height-source checks (mocked Lua only). ' .. optimizationReport .. ' ' .. meshResult
