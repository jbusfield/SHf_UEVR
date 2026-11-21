local uevrUtils = require('libs/uevr_utils')
local ik = require('libs/ik')
local plugin = require('libs/core/plugin')

local rigs = {}
local MATERIAL_OUTPUTS = {'ReturnValue'}

ik.registerOnMeshCreatedCallback(function(_, rig)
    rigs[rig] = {}
end)

ik.registerOnDestroyCallback(function(rig)
    rigs[rig] = nil
end)

local function address(object)
    return object ~= nil and object:get_address() or 0
end

local function syncMaterials()
    for rig, cache in pairs(rigs) do
        for _, template in pairs(rig.meshTemplates or {}) do
            local source = uevrUtils.getValid(template.instance)
            local target = uevrUtils.getValid(template.mesh)
            if target ~= nil then
                local sourceMesh = source ~= nil and source.SkeletalMesh or nil
                local targetMesh = target ~= nil and target.SkeletalMesh or nil
                -- Slot indices correspond only while both components use the same mesh.
                if sourceMesh ~= nil and address(sourceMesh) == address(targetMesh) then
                    -- One bridge call reads the effective array, including inherited
                    -- materials and M_Disable, without native Lua TArray marshaling.
                    local result = plugin.executeFunctionWithOutputs(source, 'GetMaterials', MATERIAL_OUTPUTS)
                    local materials = result and result.ReturnValue
                    if materials ~= nil then
                        local previous = cache[template]
                        if previous == nil or previous.source ~= address(source)
                            or previous.target ~= address(target) or previous.mesh ~= address(sourceMesh) then
                            previous = {source = address(source), target = address(target),
                                mesh = address(sourceMesh), materials = {}}
                            cache[template] = previous
                        end
                        -- The helper owns target materials after creation. Compare against
                        -- the last applied pointers instead of reflecting every target slot.
                        for slot = 1, #materials do
                            local material = materials[slot]
                            local materialAddress = address(material)
                            if previous.materials[slot] ~= materialAddress then
                                target:SetMaterial(slot - 1, material)
                                previous.materials[slot] = materialAddress
                            end
                        end
                    end
                else
                    cache[template] = nil
                end
            end
        end
    end
end

syncMaterials = uevrUtils.profiler:wrap('IK MATERIALS: syncMaterials', syncMaterials)
local timer = uevrUtils.setInterval(4000, syncMaterials)

uevr.params.sdk.callbacks.on_script_reset(function()
    uevrUtils.clearInterval(timer)
    rigs = {}
end)
