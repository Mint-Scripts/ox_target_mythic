-- This file is purely additive: it does not touch ox_target's targeting loop.

local api = require 'client.api'

local PlayerPedId = PlayerPedId
local GetEntityModel = GetEntityModel
local GetGameplayCamRot = GetGameplayCamRot
local GetGameplayCamCoord = GetGameplayCamCoord
local GetShapeTestResultIncludingMaterial = GetShapeTestResultIncludingMaterial
local StartExpensiveSynchronousShapeTestLosProbe = StartExpensiveSynchronousShapeTestLosProbe

---@param rotation vector3
---@return vector3
local function rotationToDirection(rotation)
    local x = math.rad(rotation.x)
    local z = math.rad(rotation.z)
    local cosX = math.abs(math.cos(x))
    return vec3(-math.sin(z) * cosX, math.cos(z) * cosX, math.sin(x))
end

---Raw camera raycast.
---@param distance number
---@param ignored? number entity to ignore (defaults to the player ped)
---@param flagOverride? number shapetest flags
---@return boolean hit, vector3 endCoords, number entity
local function rawLookingAt(distance, ignored, flagOverride)
    local camRot = GetGameplayCamRot(0)
    local camCoord = GetGameplayCamCoord()
    local dir = rotationToDirection(camRot)
    local destX = camCoord.x + dir.x * distance
    local destY = camCoord.y + dir.y * distance
    local destZ = camCoord.z + dir.z * distance

    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        camCoord.x, camCoord.y, camCoord.z, destX, destY, destZ,
        flagOverride or 27, ignored or PlayerPedId(), 0.2
    )

    local _, hit, endCoords, _, _, entity = GetShapeTestResultIncludingMaterial(handle)
    return hit == 1, endCoords, entity
end

---mythic-targeting compatible result: returns `{ entity =, endCoords = }` or `false`.
---@param distance? number defaults to 25.0
---@param ignored? number defaults to the player ped
---@param flagOverride? number defaults to 286 (the value the old component used)
local function getEntityPlayerIsLookingAt(distance, ignored, flagOverride)
    local hit, endCoords, entity = rawLookingAt(distance or 25.0, ignored, flagOverride or 286)
    if hit then
        return { entity = entity, endCoords = endCoords }
    end
    return false
end

local mythicBase
local Jobs, Inventory, Reputation

local function getBaseResource()
    if mythicBase and GetResourceState(mythicBase) == 'started' then return mythicBase end

    for _, name in ipairs({ 'mythic-base', 'prp-base' }) do
        if GetResourceState(name) == 'started' then
            mythicBase = name
            return name
        end
    end
end

local function fetchComponent(name)
    local base = getBaseResource()
    if not base then return end

    local ok, component = pcall(function() return exports[base]:FetchComponent(name) end)
    if ok then return component end
end

local function refreshComponents()
    Jobs = fetchComponent('Jobs') or Jobs
    Inventory = fetchComponent('Inventory') or Inventory
    Reputation = fetchComponent('Reputation') or Reputation
end

AddEventHandler('Core:Shared:Ready', function()
    CreateThread(function()
        Wait(250)
        refreshComponents()
    end)
end)

local function getCharacter()
    return LocalPlayer.state.Character
end

local function doesCharacterHaveTemp(tempJob)
    local character = getCharacter()
    if not character then return false end

    local ok, current = pcall(function() return character:GetData('TempJob') end)
    return ok and current ~= nil and current == tempJob
end

local function doesCharacterHaveState(state)
    local character = getCharacter()
    if not character then return false end

    local ok, states = pcall(function() return character:GetData('States') end)
    if not ok or type(states) ~= 'table' then return false end

    for i = 1, #states do
        if states[i] == state then return true end
    end

    return false
end

local function doesCharacterPassJobPermissions(jobPermissions)
    if type(jobPermissions) ~= 'table' then return true end

    if not Jobs then Jobs = fetchComponent('Jobs') end
    if not Jobs then return false end

    for _, v in ipairs(jobPermissions) do
        if v.job then
            if not v.reqOffDuty or (v.reqOffDuty and (not Jobs.Duty:Get(v.job))) then
                if Jobs.Permissions:HasJob(v.job, v.workplace, v.grade, v.gradeLevel, v.reqDuty, v.permissionKey) then
                    return true
                end
            end
        elseif v.permissionKey then
            if Jobs.Permissions:HasPermission(v.permissionKey) then
                return true
            end
        end
    end

    return false
end

local function hasItem(item, count)
    if not Inventory then Inventory = fetchComponent('Inventory') end
    if not Inventory then return false end
    return Inventory.Check.Player:HasItem(item, count or 1)
end

local function hasItems(items)
    if not Inventory then Inventory = fetchComponent('Inventory') end
    if not Inventory then return false end
    return Inventory.Check.Player:HasItems(items)
end

local function hasAnyItems(items)
    if not Inventory then Inventory = fetchComponent('Inventory') end
    if not Inventory then return false end
    return Inventory.Check.Player:HasAnyItems(items)
end

local function getRepLevel(id)
    if not Reputation then Reputation = fetchComponent('Reputation') end
    if not Reputation then return 0 end
    return Reputation:GetLevel(id) or 0
end

-- Tracks the enabled/disabled state of zones registered through this layer so
-- ZonesToggle keeps working without recreating the zone.
local zoneEnabled = {}

local nameCounter = 0
local function nextName()
    nameCounter += 1
    return ('mythiccompat:%d'):format(nameCounter)
end

---Normalise a mythic icon (bare FontAwesome name, e.g. "gas-pump") to an ox class.
---@param icon? string
---@param fallback? string
---@return string
local function normalizeIcon(icon, fallback)
    icon = icon or fallback
    if type(icon) ~= 'string' or icon == '' then return 'fa-solid fa-circle' end
    -- Already a full class ("fa-solid fa-...") or a partial fa- class: leave it.
    if icon:find('%s') or icon:sub(1, 3) == 'fa-' then return icon end
    return 'fa-solid fa-' .. icon
end

---Build the entityData table the original mythic event handlers / isEnabled funcs expect.
---@param kind string 'vehicle'|'player'|'ped'|'object'|'entity'|'zone'
---@param entity? number
---@param coords? vector3
---@param zoneName? string
local function buildEntityData(kind, entity, coords, zoneName)
    if kind == 'zone' then
        return { type = 'zone', name = zoneName, id = zoneName, entity = entity, endCoords = coords }
    end

    if kind == 'player' then
        local serverId
        if entity and entity > 0 then
            local plyIdx = NetworkGetPlayerIndexFromPed(entity)
            if plyIdx ~= -1 then serverId = GetPlayerServerId(plyIdx) end
        end
        return { type = 'player', entity = entity, endCoords = coords, serverId = serverId }
    end

    return { type = kind, entity = entity, endCoords = coords }
end

---Translate a mythic menuArray into an array of native ox_target options.
---@param menuArray table
---@param fallbackIcon? string
---@param kind string
---@param zoneName? string
---@param defaultDistance? number
---@return table
local function translate(menuArray, fallbackIcon, kind, zoneName, defaultDistance)
    local result = {}
    if type(menuArray) ~= 'table' then return result end

    for i = 1, #menuArray do
        local mItem = menuArray[i]

        -- Mythic resources are inconsistent about the label field: the ported
        -- VehicleMenu/PlayerMenu use `text`, but most external resources
        -- (mythic-dealerships, etc.) use `label`. Accept either.
        local option = {
            name = mItem.name or nextName(),
            icon = normalizeIcon(mItem.icon, fallbackIcon),
            label = mItem.text or mItem.label or '',
            distance = mItem.minDist or mItem.distance or defaultDistance or 7,
        }

        option.canInteract = function(entity, distance, coords, name, bone)
            -- Zone toggled off via ZonesToggle.
            if kind == 'zone' and zoneName and zoneEnabled[zoneName] == false then
                return false
            end

            local entityData = buildEntityData(kind, entity, coords, zoneName)

            if mItem.minDist and distance and distance > mItem.minDist then return false end
            if mItem.tempjob ~= nil and not doesCharacterHaveTemp(mItem.tempjob) then return false end
            if mItem.jobPerms ~= nil and not doesCharacterPassJobPermissions(mItem.jobPerms) then return false end
            if mItem.state ~= nil and not doesCharacterHaveState(mItem.state) then return false end

            -- mythic only applied the model filter to vehicles.
            if kind == 'vehicle' and mItem.model ~= nil then
                if not (entity and entity > 0 and GetEntityModel(entity) == mItem.model) then return false end
            end

            if mItem.item ~= nil and not hasItem(mItem.item, mItem.itemCount or 1) then return false end
            if mItem.items ~= nil and not hasItems(mItem.items) then return false end
            if mItem.anyItems ~= nil and not hasAnyItems(mItem.anyItems) then return false end
            if mItem.rep ~= nil and not (mItem.rep.level <= getRepLevel(mItem.rep.id)) then return false end

            if mItem.isEnabled ~= nil then
                local ok, resp = pcall(mItem.isEnabled, mItem.data, entityData)
                if not ok or not resp then return false end
            end

            -- Dynamic label. canInteract runs immediately before the NUI payload is
            -- built, so updating the label here is reflected in the menu.
            if mItem.textFunc then
                local ok, text = pcall(mItem.textFunc, mItem.data, entityData)
                if ok and text then option.label = text end
            end

            return true
        end

        option.onSelect = function(data)
            local entity = data and data.entity or 0
            local coords = data and data.coords
            local entityData = buildEntityData(kind, entity, coords, zoneName)

            if mItem.event then
                TriggerEvent(mItem.event, entityData, mItem.data)
            elseif mItem.serverEvent then
                TriggerServerEvent(mItem.serverEvent, entityData, mItem.data)
            elseif type(mItem.onSelect) == 'function' then
                pcall(mItem.onSelect, entityData, mItem.data)
            end
        end

        -- These closures are raw Lua functions created inside ox_target itself,
        -- but they get registered under the *invoking* Mythic resource's name, so
        -- addTarget() skips its `resource == 'ox_target'` sanitisation. ox_target
        -- json.encode()s the whole option list to the NUI when a target is shown,
        -- and raw functions blow up with "type 'function' is not supported by JSON".
        -- Round-trip them through msgpack (same as upstream does for its own
        -- options) so they become funcref proxies: still callable in Lua, but
        -- serialisable. canInteract/onSelect are the only function fields on the
        -- option that reach the NUI payload.
        option.canInteract = msgpack.unpack(msgpack.pack(option.canInteract))
        option.onSelect = msgpack.unpack(msgpack.pack(option.onSelect))

        result[#result + 1] = option
    end

    return result
end

local function AddObject(modelHash, icon, menuArray, proximity)
    if not modelHash then return end
    api.addModel(modelHash, translate(menuArray, normalizeIcon(icon), 'object', nil, proximity or 3))
end

local function RemoveObject(modelHash)
    if modelHash then api.removeModel(modelHash) end
end

local function AddEntity(entityId, icon, menuArray, proximity)
    if not entityId then return end
    api.addLocalEntity(entityId, translate(menuArray, normalizeIcon(icon), 'entity', nil, proximity or 3))
end

local function RemoveEntity(entityId)
    if entityId then api.removeLocalEntity(entityId) end
end

local function AddPed(entityId, icon, menuArray, proximity)
    if not entityId then return end
    api.addLocalEntity(entityId, translate(menuArray, normalizeIcon(icon), 'ped', nil, proximity or 3))
end

local function RemovePed(entityId)
    if entityId then api.removeLocalEntity(entityId) end
end

local function AddPedModel(modelId, icon, menuArray, proximity)
    if not modelId then return end
    api.addModel(modelId, translate(menuArray, normalizeIcon(icon), 'ped', nil, proximity or 3))
end

local function RemovePedModel(modelId)
    if modelId then api.removeModel(modelId) end
end

local function AddGlobalPed(menuArray)
    api.addGlobalPed(translate(menuArray, 'fa-solid fa-user', 'ped', nil, 3))
end

local function RemoveGlobalPed(menuIndexOrName)
    -- mythic removed by numeric index; ox removes by option name. Only the
    -- name-based form can be honoured here.
    if type(menuIndexOrName) == 'string' then
        api.removeGlobalPed(menuIndexOrName)
    end
end

local function toVec3(coords)
    if type(coords) == 'vector3' then return coords end
    return vec3(coords.x, coords.y, coords.z or 0.0)
end

local function ZonesAddBox(zoneId, icon, center, length, width, options, menuArray, proximity, enabled)
    if not zoneId then return end

    api.removeZone(zoneId, true) -- de-dupe (e.g. resource restart re-registering)
    zoneEnabled[zoneId] = enabled ~= false

    options = options or {}
    center = toVec3(center)

    local minZ, maxZ = options.minZ, options.maxZ
    local height = (minZ and maxZ) and math.abs(maxZ - minZ) or 4.0
    local coords = (minZ and maxZ) and vec3(center.x, center.y, (minZ + maxZ) / 2) or center

    api.addBoxZone({
        name = zoneId,
        coords = coords,
        size = vec3(width or 2.0, length or 2.0, height),
        rotation = options.heading or 0.0,
        debug = options.debugPoly or false,
        options = translate(menuArray, normalizeIcon(icon), 'zone', zoneId, proximity or 10.0),
    })
end

local function ZonesAddCircle(zoneId, icon, center, radius, options, menuArray, proximity, enabled)
    if not zoneId then return end

    api.removeZone(zoneId, true)
    zoneEnabled[zoneId] = enabled ~= false
    options = options or {}

    api.addSphereZone({
        name = zoneId,
        coords = toVec3(center),
        radius = radius or 2.0,
        debug = options.debugPoly or false,
        options = translate(menuArray, normalizeIcon(icon), 'zone', zoneId, proximity or 10.0),
    })
end

local function ZonesAddPoly(zoneId, icon, points, options, menuArray, proximity, enabled)
    if not zoneId then return end

    api.removeZone(zoneId, true)
    zoneEnabled[zoneId] = enabled ~= false
    options = options or {}

    local minZ, maxZ = options.minZ, options.maxZ
    local thickness = (minZ and maxZ) and math.abs(maxZ - minZ) or 4.0

    api.addPolyZone({
        name = zoneId,
        points = points,
        thickness = thickness,
        debug = options.debugPoly or false,
        options = translate(menuArray, normalizeIcon(icon), 'zone', zoneId, proximity or 10.0),
    })
end

local function ZonesRemoveZone(zoneId)
    if not zoneId then return end
    zoneEnabled[zoneId] = nil
    api.removeZone(zoneId, true)
end

local function ZonesToggle(zoneId, toggle)
    if zoneId then zoneEnabled[zoneId] = toggle and true or false end
end

local function ZonesIsEnabled(zoneId)
    return zoneId ~= nil and zoneEnabled[zoneId] ~= false
end

local function ZonesIsCoordInZone(zoneId, coords)
    if not zoneId or not coords then return false end

    for _, zone in pairs(lib.zones.getAllZones()) do
        if zone.name == zoneId and zone:contains(coords) then
            return zoneId
        end
    end

    return false
end

local function ZonesRefresh()
    -- ox_target manages zones live; nothing to rebuild.
end

exports('GetEntityPlayerIsLookingAt', getEntityPlayerIsLookingAt)
exports('AddObject', AddObject)
exports('RemoveObject', RemoveObject)
exports('AddEntity', AddEntity)
exports('RemoveEntity', RemoveEntity)
exports('AddPed', AddPed)
exports('RemovePed', RemovePed)
exports('AddPedModel', AddPedModel)
exports('RemovePedModel', RemovePedModel)
exports('AddGlobalPed', AddGlobalPed)
exports('RemoveGlobalPed', RemoveGlobalPed)
exports('ZonesAddBox', ZonesAddBox)
exports('ZonesAddCircle', ZonesAddCircle)
exports('ZonesAddPoly', ZonesAddPoly)
exports('ZonesRemoveZone', ZonesRemoveZone)
exports('ZonesToggle', ZonesToggle)
exports('ZonesIsEnabled', ZonesIsEnabled)
exports('ZonesIsCoordInZone', ZonesIsCoordInZone)
exports('ZonesRefresh', ZonesRefresh)

-- Methods are called with `:` (Targeting:Method()), so they receive `self` first.
local TARGETING = {
    GetEntityPlayerIsLookingAt = function(self, distance, ignored, flagOverride)
        return getEntityPlayerIsLookingAt(distance, ignored, flagOverride)
    end,
    AddObject = function(self, ...) return AddObject(...) end,
    RemoveObject = function(self, ...) return RemoveObject(...) end,
    AddEntity = function(self, ...) return AddEntity(...) end,
    RemoveEntity = function(self, ...) return RemoveEntity(...) end,
    AddPed = function(self, ...) return AddPed(...) end,
    RemovePed = function(self, ...) return RemovePed(...) end,
    AddPedModel = function(self, ...) return AddPedModel(...) end,
    RemovePedModel = function(self, ...) return RemovePedModel(...) end,
    AddGlobalPed = function(self, ...) return AddGlobalPed(...) end,
    RemoveGlobalPed = function(self, ...) return RemoveGlobalPed(...) end,
}

TARGETING.Zones = {
    AddBox = function(self, ...) return ZonesAddBox(...) end,
    AddCircle = function(self, ...) return ZonesAddCircle(...) end,
    AddPoly = function(self, ...) return ZonesAddPoly(...) end,
    RemoveZone = function(self, ...) return ZonesRemoveZone(...) end,
    Toggle = function(self, ...) return ZonesToggle(...) end,
    IsEnabled = function(self, ...) return ZonesIsEnabled(...) end,
    IsCoordInZone = function(self, ...) return ZonesIsCoordInZone(...) end,
    Refresh = function(self, ...) return ZonesRefresh(...) end,
}

local function registerComponent()
    for _, base in ipairs({ 'mythic-base' }) do
        if GetResourceState(base) == 'started' then
            pcall(function() exports[base]:RegisterComponent('Targeting', TARGETING) end)
        end
    end
end

-- The base resource fires this on every resource start once its exports are ready.
AddEventHandler('Proxy:Shared:RegisterReady', registerComponent)

-- Also attempt once on load, in case the base was already fully started.
CreateThread(function()
    Wait(1000)
    registerComponent()
end)

return {
    translate = translate,
    getEntityPlayerIsLookingAt = getEntityPlayerIsLookingAt,
    normalizeIcon = normalizeIcon,
}