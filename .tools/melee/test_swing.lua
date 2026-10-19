-- Loads the real gesture detector and dev UI in an isolated mocked environment.
local function system()
    local bus, uiUpdates, values, widgets, events = {}, {}, {}, {}, {}
    local labels, colors, delayed = {}, {}, {}
    local preTick, manager
    local right, left, head = {X=0,Y=0,Z=0}, {X=0,Y=0,Z=0}, {X=0,Y=0,Z=0}
    local rotation = {Pitch=0,Yaw=0,Roll=0}
    local rightRotation = {Pitch=0,Yaw=0,Roll=0}
    -- Existing profiles have none of the newly introduced settings.
    local profile = {swing = {minThresholdSpeed=180, maxThresholdSpeed=320}}
    local function emit(event, ...)
        for _, fn in ipairs(bus[event] or {}) do fn(...) end
    end
    local utils = {
        registerUEVRCallback = function(event, fn)
            bus[event] = bus[event] or {}; table.insert(bus[event], fn)
        end,
        executeUEVRCallbacks = emit,
        registerOnPreInputGetStateCallback = function() end,
        print = function() end,
        delay = function(ms, fn) delayed[#delayed+1] = {ms=ms, fn=fn} end,
    }
    local config = {
        onUpdate = function(id, fn)
            uiUpdates[id] = uiUpdates[id] or {}; table.insert(uiUpdates[id], fn)
        end,
        setValue = function(id, value) values[id] = value end,
        setLabel = function(id, value) labels[id] = value end,
        setColor = function(id, value) colors[id] = value end,
        applyOptionsToConfigWidgets = function(items) return items end,
        createConfigPanel = function(label, path, items)
            for _, item in ipairs(items) do
                if item.id then widgets[item.id] = item; values[item.id] = item.initialValue end
            end
        end,
    }
    local modules = {
        ['libs/uevr_utils'] = utils, ['libs/configui'] = config,
        ['libs/controllers'] = {
            getControllerLocation = function(hand) return hand == 0 and left or hand == 1 and right or head end,
            getControllerRotation = function(hand) return hand == 1 and rightRotation or rotation end,
        },
        ['libs/core/params'] = {new = function()
            manager = {
                load = function() end,
                getFromActiveProfile = function(self, path)
                    local node = profile
                    for _, key in ipairs(path) do node = type(node) == 'table' and node[key] or nil end
                    return node
                end,
                setInActiveProfile = function(self, path, value)
                    local node = profile
                    for index = 1, #path - 1 do
                        node[path[index]] = node[path[index]] or {}; node = node[path[index]]
                    end
                    node[path[#path]] = value
                end,
                getAllActiveProfileParams = function() return profile end,
                initProfileHandler = function() end,
                getProfilePreConfigurationWidgets = function() return {} end,
                getProfilePostConfigurationWidgets = function() return {} end,
            }
            return manager
        end},
    }
    local env = setmetatable({
        Handed = {Left=0,Right=1}, LogLevel = {Error=0,Debug=4}, Once={EVER=1},
        doOnce = function(fn) return fn end,
        uevr = {sdk = {callbacks = {on_pre_engine_tick = function(fn) preTick = fn end}}},
        expandArray = function(fn, ...) return {expanded = fn(...)} end,
        spliceableInlineArray = function(items)
            local result = {}
            for _, item in ipairs(items) do
                if item.expanded then
                    for _, child in ipairs(item.expanded) do result[#result + 1] = child end
                else result[#result + 1] = item end
            end
            return result
        end,
    }, {__index = _G})
    env.require = function(name)
        if name == 'libs/config/gesture_config_dev' and not modules[name] then
            modules[name] = assert(load(uiSource, '@gesture_config_dev.lua', 't', env))()
        end
        assert(modules[name], name)
        return modules[name]
    end
    local gestures = assert(load(gestureSource, '@gestures.lua', 't', env))()
    gestures.registerSwingBeginCallback(function(strength, hand)
        events[#events + 1] = {name='begin', hand=hand, strength=strength}
    end, true, false)
    gestures.registerSwingEndCallback(function(strength, hand)
        events[#events + 1] = {name='end', hand=hand, strength=strength}
    end, true, false)
    gestures.init(true)
    local s = {gestures=gestures, events=events, widgets=widgets, values=values, rotation=rotation, rightRotation=rightRotation,
        labels=labels, colors=colors, delayed=delayed}
    function s.step(vx, vy, dt, leftSpeed)
        dt = dt or 0.01
        right.X, right.Y = right.X + (vx or 0)*dt, right.Y + (vy or 0)*dt
        left.X = left.X + (leftSpeed or 0)*dt
        preTick(nil, dt)
    end
    function s.sample(x, y, z, dt)
        right.X, right.Y, right.Z = x, y, z
        preTick(nil, dt)
    end
    function s.count(kind, hand)
        local total = 0
        for _, event in ipairs(events) do
            if event.name == kind and (hand == nil or event.hand == hand) then total = total + 1 end
        end
        return total
    end
    function s.update(id, value)
        for _, fn in ipairs(uiUpdates['uevr_gesture_'..id] or {}) do fn(value) end
    end
    function s.rest() for frame=1,10 do s.step(0) end end
    function s.idleRead() gestures.getSwingGestures(0.01, 1, right, head, rotation) end
    function s.fastRead()
        right.X = right.X + 2.2
        gestures.getSwingGestures(0.01, 1, right, head, rotation)
    end
    s.step(0)
    return s
end

local s = system()
s.step(200)
for frame=1,30 do s.step(frame % 2 == 0 and 170 or 190) end
assert(s.count('begin') == 1 and s.count('end') == 0, 'speed cutoff chatter must stay one stroke')
for frame=1,4 do s.step(20) end
s.step(220)
assert(s.count('begin') == 1 and s.count('end') == 0, 'a brief near-stop must not split the stroke')
s.rest()
assert(s.count('end') == 1, 'sustained rest must finish the stroke')
s.step(220)
assert(s.count('begin') == 2, 'a stroke after genuine rest must start normally')

s = system(); s.step(400); s.step(-250)
assert(s.count('begin') == 1, 'less than the reversal distance must not create another stroke')
s.step(-250)
assert(s.count('begin') == 2 and s.count('end') == 1, 'confirmed backswing must create a new stroke immediately')
assert(s.events[2].name == 'end' and s.events[3].name == 'begin', 'close the old window before opening the backswing')
assert(s.events[2].strength == 1 and s.events[3].strength < 1, 'preserve each stroke peak strength at reversal')

s = system(); s.step(220)
for frame=1,20 do s.step(-100); s.step(220) end
assert(s.count('begin') == 1, 'short reverse tracking fluctuations must not count as backswings')

s = system(); s.step(250)
for frame=1,40 do
    local angle = frame * math.pi / 40
    s.step(250*math.cos(angle), 250*math.sin(angle))
end
assert(s.count('begin') == 1 and s.count('end') == 0, 'a continuous curved stroke may turn through 180 degrees')

s = system(); s.step(250)
for frame=1,12 do
    s.rightRotation.Roll = frame*15
    s.step(250)
end
assert(s.count('begin') == 1, 'turning the blade over during continuing travel must not start another swing')
s.step(-250); s.step(-250)
assert(s.count('begin') == 2, 'the return stroke must register with the blade turned over')
s = system()
for frame=1,12 do s.rightRotation.Roll=frame*15; s.step(0) end
assert(s.count('begin') == 0, 'turning the blade in place must not count as a swing')

local capturedStarts = {}
if reversalFixture then
    s = system()
    s.update('swing_minThresholdSpeed',337)
    s.update('swing_maxThresholdSpeed',661)
    s.update('swing_reversalDotThreshold',0)
    s.update('swing_reversalMinDistance',1)
    for index, frame in ipairs(reversalFixture) do
        local before = s.count('begin')
        s.sample(frame[3], frame[4], frame[5], index == 1 and 0 or frame[2])
        if s.count('begin') > before then capturedStarts[#capturedStarts+1] = frame[1] end
    end
    assert(capturedStarts[1] and math.abs(capturedStarts[1]-48.46)<0.01, 'preserve the original captured swing')
    assert(capturedStarts[2] and capturedStarts[2]>48.63 and capturedStarts[2]<49.04,
        'recognize the captured sword return stroke instead of following its turnaround')
end

s = system(); s.step(220); s.rotation.Yaw = 90; s.step(220)
assert(s.count('end') == 1 and s.count('begin') == 1, 'snap turn must cancel without creating another swing')
s = system(); s.step(220); s.step(0,0,0)
assert(s.count('end') == 1, 'invalid tick duration must cancel the active stroke safely')

s = system()
local prefix = 'uevr_gesture_'
assert(s.widgets[prefix..'swing_test_count'].widgetType == 'input_text', 'show the requested text box')
assert(s.widgets[prefix..'swing_test_count'].disabled, 'the count display must not be editable')
assert(s.widgets[prefix..'swing_stopThresholdSpeed'].initialValue == 50, 'old profiles must inherit Stop Speed default')
assert(s.widgets[prefix..'swing_stopHoldTime'].initialValue == 0.08, 'old profiles must inherit rest confirmation default')
assert(s.widgets[prefix..'swing_test_reset'] == nil, 'do not add a reset button')
s.step(220); s.rest()
assert(s.values[prefix..'swing_test_count'] == '0', 'do not count gameplay swings while Test is disabled')
s.update('swing_test', true)
assert(s.values[prefix..'swing_test_count'] == '0', 'enabling Test starts from zero')
s.step(220)
for frame=1,20 do s.step(frame % 2 == 0 and 170 or 190) end
assert(s.values[prefix..'swing_test_count'] == '1', 'counter must report one continuing stroke through cutoff chatter')
s.rest()
assert(s.values[prefix..'swing_test_count'] == '1', 'swing end must not increment the count')
s.step(220); s.step(-250); s.step(-250)
assert(s.values[prefix..'swing_test_count'] == '3', 'count the next forward stroke and its deliberate backswing')
s.update('swing_test', false); s.rest(); s.step(220)
assert(s.values[prefix..'swing_test_count'] == '3', 'counter must freeze outside Test mode')
s.update('swing_test', true)
assert(s.values[prefix..'swing_test_count'] == '0', 'enabling Test again must reset the display')

s = system(); s.update('swing_test', true); s.step(0); s.step(220,0,0.01,220)
assert(s.count('begin',0) == 1 and s.count('begin',1) == 1, 'hands must maintain independent detector state')
assert(s.values[prefix..'swing_test_count'] == '2', 'count each hand that actually starts a swing in Test mode')

s = system(); s.update('swing_stopThresholdSpeed',100); s.update('swing_stopHoldTime',0.04)
s.step(220)
for frame=1,6 do s.step(80) end
assert(s.count('end') == 1, 'Stop Speed and hold-time UI changes must affect the live detector')

s = system(); s.update('swing_test',true)
local rightStatus = prefix..'swing_test_status_right'
local leftStatus = prefix..'swing_test_status_left'
s.step(220)
assert(s.labels[rightStatus] == 'Right Active' and s.colors[rightStatus] == '#00FF00FF', 'show the active swing window immediately')
for frame=1,7 do s.step(0) end
assert(s.labels[rightStatus] == 'Right Active', 'stay active during Stop Hold Time')
for frame=1,2 do s.step(0) end
assert(s.count('end',1) == 1 and s.labels[rightStatus] == 'Right Inactive' and s.colors[rightStatus] == '#FF0000FF',
    'show inactive immediately on swing end instead of flashing green for 500 ms')
assert(#s.delayed == 0, 'swing status must not schedule a momentary flash')
s.step(220,0,0.01,220)
for frame=1,9 do s.step(0,0,0.01,220) end
assert(s.labels[rightStatus] == 'Right Inactive' and s.labels[leftStatus] == 'Left Active', 'ending one hand must not clear the other hand')
s.update('swing_test',false)
assert(s.colors[rightStatus] == '#00000000' and s.colors[leftStatus] == '#00000000', 'hide both statuses when Test is disabled')

s = system(); s.update('swing_stopThresholdSpeed',2000); s.update('swing_stopHoldTime',0.04)
s.step(220); s.step(190)
assert(s.count('end') == 0, 'Stop Speed above Min Speed must be capped to preserve speed hysteresis')
for frame=1,5 do s.step(170) end
assert(s.count('end') == 1, 'a high Stop Speed must finish after sustained motion below Min Speed')

s = system(); s.idleRead(); collectgarbage('collect'); collectgarbage('stop')
local memoryBefore = collectgarbage('count')
local started = os.clock()
for frame=1,20000 do s.idleRead() end
for frame=1,20000 do s.fastRead() end
local duration = os.clock()-started
local growth = collectgarbage('count')-memoryBefore
collectgarbage('restart')
assert(growth < 8, 'detector must not allocate per tick: '..growth..' KB growth')
return {result=string.format('PASS: stroke continuity, rest/reversal, callback ordering, peak strength, independent hands, live settings, Test counter; 40,000 idle/active checks %.3f s / %.3f KB', duration, growth), capturedStarts=capturedStarts}
