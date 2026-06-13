local utils = require 'client.utils'
local playerItems = utils.getItems()
local character = nil

local function setPlayerItems(inventory)
    table.wipe(playerItems)
    if not inventory then return end
    for _, item in pairs(inventory) do
        if item and item.name then
            playerItems[item.name] = (playerItems[item.name] or 0) + (item.count or 0)
        end
    end
end

local usingOxInventory = utils.hasExport('ox_inventory.Items')

if not usingOxInventory then
    setPlayerItems()
end

AddEventHandler('mythic-characters:client:Spawned', function(char)
    character = char
end)

AddEventHandler('mythic-characters:client:CharacterUpdated', function(char)
    character = char
end)

AddEventHandler('mythic-inventory:client:UpdateInventory', function(inventory)
    setPlayerItems(inventory)
end)

---@diagnostic disable-next-line: duplicate-set-field
function utils.hasPlayerGotGroup(filter)
    if not character then return false end

    local _type = type(filter)

    if _type == 'string' then
        if character.SID == filter or tostring(character.SID) == tostring(filter) then return true end
        for _, job in pairs(character.Jobs or {}) do
            if job.Name == filter then return true end
        end
    elseif _type == 'table' then
        local tabletype = table.type(filter)

        if tabletype == 'hash' then
            for name, grade in pairs(filter) do
                if tostring(character.SID) == name then return true end
                for _, job in pairs(character.Jobs or {}) do
                    if job.Name == name and job.Grade.Level >= grade then return true end
                end
            end
        elseif tabletype == 'array' then
            for i = 1, #filter do
                local name = filter[i]
                if tostring(character.SID) == name then return true end
                for _, job in pairs(character.Jobs or {}) do
                    if job.Name == name then return true end
                end
            end
        end
    end
end