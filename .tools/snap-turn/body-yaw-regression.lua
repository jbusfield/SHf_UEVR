local source = ...
local function cut(first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a + #first, true))
    return source:sub(a, b - 1)
end
local update = cut('local function updateBodyYaw(delta)', 'updateBodyYaw = uevrUtils.profiler:wrap')
local checks, examples = 0, {}
for _, delta in ipairs({-90, -30, 30, 90}) do
    for _, yaw in ipairs({-175, 0, 175}) do
        local function fixture(rebase)
            local rootYaw = yaw
            local env = setmetatable({M = {PawnRotationMode = {NONE = 1, LOCKED = 4}, print = function(message) error(message) end},
                decoupledYaw = 0, bodyRotationOffset = yaw, lateYaw = false,
                currentHeadRotator = {Yaw = yaw}, rootComponent = {K2_SetWorldRotation = function() end},
                getPawnRotationMode = function() return 4 end, getAimMethod = function() return 2 end,
                smoothBodyRotationOffset = function(value) return value end,
                uevrUtils = {clampAngle180 = function(value) return (value + 180) % 360 - 180 end},
                setRootWorldYaw = function(value) rootYaw = value end}, {__index = _G})
            local fn = assert(load(update .. '\nreturn updateBodyYaw', '@actual updateBodyYaw', 't', env))()
            env.decoupledYaw = delta
            rootYaw = delta + yaw -- input.lua's immediate root write
            if rebase then env.currentHeadRotator.Yaw = yaw + delta end
            local afterSnap = rootYaw
            fn() -- early stereo body-yaw update, still using cached prior-view head
            local firstView = rootYaw
            env.currentHeadRotator.Yaw = yaw + delta -- final view callback catches up
            fn()
            return {afterSnap = afterSnap, firstView = firstView, refreshed = rootYaw}
        end
        local old, candidate = fixture(false), fixture(true)
        assert(old.firstView == yaw and old.refreshed == yaw + delta, 'Expected current body-yaw counterturn was not reproduced')
        assert(candidate.firstView == candidate.afterSnap and candidate.refreshed == candidate.afterSnap, 'Rebased cached head did not maintain coherent root yaw')
        checks = checks + 2
        if yaw == 0 then examples[#examples + 1] = {delta = delta, current = old, rebased = candidate} end
    end
end
return {checks = checks, examples = examples, note = 'Actual updateBodyYaw executed with isolated mocks; candidate cache rebase has not been applied to game scripts'}
