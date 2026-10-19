local sources = ...
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function near(a,b,message) check(math.abs(a-b)<1e-7, message .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end
local function extract(source)
    local first = source:find('local zeroMeshPositionDelta =',1,true) or assert(source:find('local function getAnimationHeadDelta(',1,true))
    local last = assert(source:find('local function getPawnRotationMode()',first,true))
    local helpers = source:sub(first,last-1)
    first = source:find('-- Named protected-call target avoids a per-tick capturing closure.',1,true) or assert(source:find('local function updateMeshRelativePosition(',1,true))
    last = assert(source:find('function M.setAimRotationOffset(',first,true))
    return helpers .. source:sub(first,last-1) .. '\nreturn M'
end
local function fixture(source, animation, eye)
    local stats = {names=0,quats=0,rotates=0,vectors=0,sockets=0,rootRotations=0,events=0,errors=0}
    local vecmeta = {__mul=function(v,s) return setmetatable({X=v.X*s,Y=v.Y*s,Z=v.Z*s},getmetatable(v)) end}
    local function vector(a,b,c)
        stats.vectors=stats.vectors+1
        if type(a)=='table' then b,c,a=a.Y,a.Z,a.X end
        return setmetatable({X=a or 0,Y=b or 0,Z=c or 0},vecmeta)
    end
    local settings={adjustForAnimation=animation,adjustForEyeOffset=eye,headBoneName='Head',rootBoneName='Root',eyeOffset=3,useMeshHeightForHeadOffset=true}
    local mesh={RelativeLocation={X=0,Y=0,Z=-85},head={X=20,Y=10,Z=155},base={X=2,Y=3,Z=1}}
    function mesh:GetSocketLocation(name)
        stats.sockets=stats.sockets+1
        if name=='Head' or name=='Head2' then return self.head else return self.base end
    end
    local root={yaw=20}
    function root:K2_GetComponentRotation() stats.rootRotations=stats.rootRotations+1; return {Yaw=self.yaw} end
    local pawn={BaseRotationOffset={X=0,Y=0,Z=0.70710678118655,W=0.70710678118655},BaseTranslationOffset={X=4}}
    local state={pawn=pawn}
    local meshes={mesh}
    local env=setmetatable({M={},status=state,rootComponent=root,decoupledYaw=0,
        currentHeadRotator={Pitch=5,Yaw=12,Roll=0},
        getParameter=function(key) return settings[key] end,
        paramManager={getAllActiveProfileParams=function() return settings end},
        getBodyMesh=function() return meshes end,
        uevrUtils={vector=vector,rotator=function(p,y,r) return {Pitch=p,Yaw=y,Roll=r} end,
            profiler={wrap=function(_,_,fn) return fn end},getValid=function(v) return v end,
            fname_from_string=function(s) stats.names=stats.names+1; return s end,
            setComponentRelativeLocation=function(m,x,y) m.RelativeLocation.X=x; m.RelativeLocation.Y=y end,
            executeUEVRCallbacks=function(_,x,y) stats.events=stats.events+1; stats.x,stats.y=x,y end},
        kismet_math_library={
            Quat_Rotator=function(_,q) stats.quats=stats.quats+1; return {Yaw=math.atan(2*(q.W*q.Z+q.X*q.Y),1-2*(q.Y*q.Y+q.Z*q.Z))*180/math.pi} end,
            RotateAngleAxis=function(_,v,angle,axis)
                stats.rotates=stats.rotates+1
                -- Independent Rodrigues formula, matching Unreal's unit-Z rotation.
                local c,s=math.cos(angle*math.pi/180),math.sin(angle*math.pi/180)
                local dot=axis.X*v.X+axis.Y*v.Y+axis.Z*v.Z
                return vector(v.X*c+(axis.Y*v.Z-axis.Z*v.Y)*s+axis.X*dot*(1-c),v.Y*c+(axis.Z*v.X-axis.X*v.Z)*s+axis.Y*dot*(1-c),v.Z*c+(axis.X*v.Y-axis.Y*v.X)*s+axis.Z*dot*(1-c))
            end,
            Conv_RotatorToVector=function(_,r) local p,y=r.Pitch*math.pi/180,r.Yaw*math.pi/180; return vector(math.cos(p)*math.cos(y),math.cos(p)*math.sin(y),math.sin(p)) end,
        },
    },{__index=_G})
    env.M.getHeadOffset=function() return vector(8,-6,-15) end
    env.M.print=function() stats.errors=stats.errors+1 end
    assert(load(extract(source),'mesh','t',env))()
    return {env=env,api=env.M,stats=stats,mesh=mesh,root=root,pawn=pawn,settings=settings,meshes=meshes,state=state}
end
local report
for _,animation in ipairs({false,true}) do for _,eye in ipairs({false,true}) do
    local old,new=fixture(sources.preMesh,animation,eye),fixture(sources.input,animation,eye)
    for tick=1,120 do
        for _,h in ipairs({old,new}) do
            h.root.yaw=tick*7-400
            h.mesh.head.X=20+math.sin(tick)*7
            h.mesh.head.Z=155+math.cos(tick)*11
            if tick==30 then h.settings.headBoneName='Head2' end
            if tick==50 then h.pawn.BaseRotationOffset.Z=0.3; h.pawn.BaseRotationOffset.W=math.sqrt(0.91) end
            if tick==70 then h.pawn.BaseRotationOffset=nil end
            if tick==90 then h.pawn.BaseRotationOffset={X=0,Y=0,Z=0,W=1} end
            h.api.updateMeshRelativePosition()
        end
        near(new.mesh.RelativeLocation.X,old.mesh.RelativeLocation.X,'mesh X matches')
        near(new.mesh.RelativeLocation.Y,old.mesh.RelativeLocation.Y,'mesh Y matches')
        near(new.mesh.RelativeLocation.Z,old.mesh.RelativeLocation.Z,'mesh Z unchanged')
        near(new.state.meshZOffset,old.state.meshZOffset,'height calibration matches')
        near(new.stats.x,old.stats.x,'callback X matches')
        near(new.stats.y,old.stats.y,'callback Y matches')
    end
    near(new.stats.events,old.stats.events,'callback frequency unchanged')
    near(new.stats.errors,0,'no protected-call errors')
    if animation then
        near(new.stats.names,3,'only changed bone names are converted')
        near(new.stats.quats,3,'only changed quaternion values are converted')
        near(new.stats.rotates,0,'Z rotation uses no reflected engine math call')
        near(new.stats.sockets,240,'both socket positions sampled each tick')
        report=string.format('Mesh path per 120 ticks: name conversions %d -> %d, quaternion conversions %d -> %d, RotateAngleAxis calls %d -> %d; socket samples remain %d.',old.stats.names,new.stats.names,old.stats.quats,new.stats.quats,old.stats.rotates,new.stats.rotates,new.stats.sockets)
    end
    new.api.updateMeshRelativePosition(true)
    near(new.mesh.RelativeLocation.X,0,'disable clears X')
    near(new.mesh.RelativeLocation.Y,0,'disable clears Y')
    near(new.mesh.RelativeLocation.Z,-85,'disable preserves Z')
    new.state.meshRelativePositionDisabled=true
    local events=new.stats.events
    new.api.updateMeshRelativePosition()
    near(new.stats.events,events,'disabled positioning emits no updates')
end end
local h=fixture(sources.input,true,false)
h.api.updateMeshRelativePosition()
h.mesh.RelativeLocation.X=999; h.mesh.RelativeLocation.Y=999
h.api.updateMeshRelativePosition()
check(h.mesh.RelativeLocation.X~=999 and h.mesh.RelativeLocation.Y~=999,'game mesh writes are still overridden each tick')
h.root.K2_GetComponentRotation=function() error('level transition') end
h.api.updateMeshRelativePosition()
near(h.stats.errors,1,'root failure remains protected')
return 'PASS: ' .. checks .. ' mesh checks. ' .. report
