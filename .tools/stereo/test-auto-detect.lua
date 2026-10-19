local sources = ...
local function check(ok, message)
    if not ok then error(message, 2) end
end
local function cut(source, first, last)
    local a = source:find(first, 1, true)
    local b = a and source:find(last, a + #first, true)
    check(a and b, 'Source section missing: ' .. first)
    return source:sub(a, b - 1)
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local detection = cut(sources.input, 'local eyeIndexDetection =', 'local function setParameter(')
local save = cut(sources.input, 'local function saveParameter(', 'local createConfigMonitor')
local api = cut(sources.input, 'function M.setFirstStereoViewIndex(', 'function M.setHeadOffset(')
local init = cut(sources.input, 'function M.init(', 'function M.getConfigurationWidgets(')
local coreEnv = setmetatable({require = function(name)
    if name == 'libs/uevr_utils' then return {deepCopyTable = copy, getNativeValue = function(v) return v end} end
    return {setSelections = function() end, setValue = function() end}
end}, {__index = _G})
local coreFn, coreError = load(sources.params, '@params.lua', 't', coreEnv)
check(coreFn ~= nil, coreError)
local Params = coreFn()

local function fixture(saved)
    coreEnv.json = {load_file = function() return copy(saved) end}
    local pm = Params.new('test', {firstStereoViewIndex = 1, autoDetectEyeIndices = true}, false)
    local env = setmetatable({M = {}, paramManager = pm,
        uevrUtils = {getDeveloperMode = function() return false end, executeUEVRCallbacks = function() end},
        getParameter = function(key) return pm:getFromActiveProfile(key) end,
        setParameter = function(key, value, persist) pm:setInActiveProfile(key, value, persist) end,
    }, {__index = _G})
    local fn, err = load(detection .. save .. api .. init .. [[
        return {api=M, observe=observeStereoViewIndex, advance=updateEyeIndexDetection,
            reset=resetEyeIndexDetection, state=function() return eyeIndexDetection end}
    ]], '@input.lua detection', 't', env)
    check(fn ~= nil, err)
    local f = fn()
    f.pm = pm
    f.api.init(false)
    return f
end
local function frame(f, indices)
    local initial = f.api.getFirstStereoViewIndex()
    for _, index in ipairs(indices) do
        f.observe(index)
        check(f.api.getFirstStereoViewIndex() == initial, 'Detection changed between eyes')
    end
    f.advance()
end
local function oldProfile(index)
    return {default = {firstStereoViewIndex = index}, _profileLabels = {default = 'Default'},
        _profileState = {currentEditingProfile = 'default'}}
end

local old = fixture(oldProfile(nil))
check(not old.api.getAutoDetectEyeIndices(), 'Old profile must default off')
check(old.pm.defaultParameters.autoDetectEyeIndices == false, 'Old project new profiles must default off')
frame(old, {0, 1}); frame(old, {0, 1})
check(old.api.getFirstStereoViewIndex() == 1, 'Disabled detector changed old behavior')
local manual = fixture(oldProfile(0))
frame(manual, {1, 2})
check(manual.api.getFirstStereoViewIndex() == 0, 'Disabled detector lost saved manual index')

local fresh = fixture(nil)
check(fresh.api.getAutoDetectEyeIndices(), 'New project must default on')
check(fresh.pm.defaultParameters.autoDetectEyeIndices == true, 'New project profiles must default on')
frame(fresh, {0, 1})
check(fresh.api.getFirstStereoViewIndex() == 1, 'One pair must not finalize detection')
frame(fresh, {0, 1})
check(fresh.api.getFirstStereoViewIndex() == 0, '0/1 was not detected')

local legacy = fixture(nil)
frame(legacy, {0, 1, 2})
check(legacy.api.getFirstStereoViewIndex() == 1 and legacy.state().done, 'Mono 0 confused 1/2 detection')
local mono = fixture(nil)
for _ = 1, 40 do frame(mono, {0}) end
check(mono.api.getFirstStereoViewIndex() == 1 and mono.state().frames == 32, 'Mono fallback must be bounded')
local afr = fixture(nil)
for _ = 1, 40 do frame(afr, {1}) end
check(afr.api.getFirstStereoViewIndex() == 1 and afr.state().frames == 32, 'AFR fallback must be bounded')
local noViews = fixture(nil)
for _ = 1, 40 do frame(noViews, {-1}) end
check(noViews.state().frames == 0, 'Ignored mono marker consumed detection budget')

fresh.api.setAutoDetectEyeIndices(false, true)
check(fresh.pm.isDirty and fresh.api.getFirstStereoViewIndex() == 1, 'Checkbox off must persist and restore fallback')
fresh.api.setAutoDetectEyeIndices(true, true)
frame(fresh, {0, 1}); frame(fresh, {0, 1})
check(fresh.api.getFirstStereoViewIndex() == 0, 'Checkbox on must restart detection')
fresh.pm:createProfile('legacy', 'Legacy')
fresh.pm:set({'legacy', 'autoDetectEyeIndices'}, true, true)
fresh.pm:setActiveProfile('legacy')
check(fresh.state().frames == 0, 'Profile switch must reset detection')
frame(fresh, {1, 2})
check(fresh.api.getFirstStereoViewIndex() == 1, 'Profile switch retained stale detection')
fresh.reset()
check(fresh.state().frames == 0 and not fresh.state().done, 'Level reset must reset detection')

local general = cut(sources.dev, 'id = widgetPrefix .. "general_tree"', 'id = widgetPrefix .. "aim_method_tree"')
check(general:find('label = "First Eye Index"', 1, true) ~= nil, 'Combo missing from General')
check(general:find('selections = {"Auto", "0", "1"}', 1, true) ~= nil, 'Wrong combo choices')
check(not general:find('Auto Detect Eye Indices', 1, true), 'Old checkbox remains')

local displayed, onSelect
local uiEnv = setmetatable({configDefaults = {}, widgetPrefix = 'test_',
    configui = {
        onUpdate = function(_, callback) onSelect = callback end,
        setValue = function(id, value, noCallbacks)
            check(id == 'test_firstEyeIndex' and noCallbacks, 'Wrong widget or feedback loop')
            displayed = value
        end,
    }, updateUIState = function() end, heightDefaults = {},
}, {__index = _G})
local uiFn, uiError = load(
    cut(sources.dev, 'local function getFirstEyeIndexSelection(', 'local helpText =') ..
    cut(sources.dev, 'configui.onUpdate(widgetPrefix .. "firstEyeIndex"', 'configui.onUpdate(widgetPrefix .. "headBones"') ..
    cut(sources.dev, 'local function setUIValue(', 'function M.init(') ..
    'return {refresh=updateUI, update=setUIValue}', '@eye index combo', 't', uiEnv)
check(uiFn ~= nil, uiError)
local ui = uiFn()
local selected = fixture(oldProfile(0))
uiEnv.updateSetting = function(key, value)
    if key == 'firstStereoViewIndex' then selected.api.setFirstStereoViewIndex(value, true)
    else selected.api.setAutoDetectEyeIndices(value, true) end
    ui.update(key, value)
end
ui.refresh({firstStereoViewIndex = 0})
check(displayed == 2, 'Saved manual 0 not displayed')
onSelect(1)
check(displayed == 1 and selected.api.getAutoDetectEyeIndices() and selected.pm.isDirty, 'Auto not saved/displayed')
check(selected.api.getFirstStereoViewIndex() == 0, 'Auto lost saved fallback')
onSelect(3)
check(displayed == 3 and not selected.api.getAutoDetectEyeIndices() and selected.api.getFirstStereoViewIndex() == 1, 'Manual 1 not saved/displayed')
onSelect(2)
check(displayed == 2 and not selected.api.getAutoDetectEyeIndices() and selected.api.getFirstStereoViewIndex() == 0, 'Manual 0 not saved/displayed')
onSelect(9)
check(displayed == 2 and selected.api.getFirstStereoViewIndex() == 0, 'Invalid combo value accepted')
ui.refresh({autoDetectEyeIndices = true, firstStereoViewIndex = 0})
check(displayed == 1, 'Auto profile not displayed')
ui.refresh({})
check(displayed == 3, 'Legacy profile inherited previous Auto/0 selection')
ui.refresh({firstStereoViewIndex = 0})
check(displayed == 2, 'Profile switch did not restore 0')
return 'PASS: old/new defaults; stereo detection; mono/AFR fallback; frame consistency; resets; combo selections, persistence and profile switching'
