---@name SpaceMap
---@author Forerunners
---@shared
---@model models/jaanus/wiretool/wiretool_input.mdl

---One chunk size
local chunkSize = 10000
local chunkHalf = chunkSize / 2

---Scan range (by global Z)
local scanRange = {3500000, 5500000}

---Sleep between chunks
local scanSleeping = 0.05

---Camera speed
local cameraSpeed = 2000

---Camera zoom speed
local cameraZoomSpeed = 50000

---Start Zoom
local cameraZoomStart = 200000

local ch = chip()
ch.CHUNK_OFFSET = Vector()

-- Utilities
---@enum PRETTY
local PRETTY = {
    Y = "Меркурий",
    V = "Венера",
    R = "Земля",
    M = "Марс",
    J = "Юпитер",
    S = "Сатурн",
    U = "Уран",
    N = "Нептун",
    O = "Луна"
}

---@enum PTYPE
local PTYPE = {
    ["infmap_planets/mercury_inside"] = "Y", -- Mercury
    ["infmap_planets/venus_inside"] = "V", -- Venus
    ["infmap/flatgrass"] = "R", -- Earth
    ["infmap_planets/mars_inside"] = "M", -- Mars
    ["infmap_planets/jupiter_inside"] = "J", -- Jupiter
    ["infmap_planets/saturn_inside"] = "S", -- Saturn
    ["infmap_planets/uranus_inside"] = "U", -- Uranus
    ["infmap_planets/neptune_inside"] = "N", -- Neptune
    ["infmap_planets/moon_inside"] = "O" -- Moon
}

---Get position chunk
---@param position Vector
---@return Vector chunk_offset
local function getChunkOffset(position)
    local chunk_offset = position / (chunkSize * 2)
    -- We are saving chunk offset, so we should make it pretty
    chunk_offset = Vector(
        math.round(chunk_offset.x),
        math.round(chunk_offset.y),
        math.round(chunk_offset.z)
    )
    return chunk_offset
end

---Unlocalize vector to chunk offset
---@param position Vector Position to unlocalize
---@param chunk Vector Chunk offset unlocalize position to
---@return Vector unlocalized Unlocalized position, in global InfMap coordinates
local function unlocalizeVector(position, chunk)
    return chunk * chunkSize * 2 + position
end


---Decodes planet ID and returns type and position
---@param id string ID of the planet
---@return PTYPE type, Vector planetPos
local function decodeId(id)
    -- fuck you starfall. you and your "complex regex"
    local type = string.match(id, "([YVRMJSUNO])")
    local function decodeCoord(coord)
        local minus, c = string.match(id, '(-?)(%x+)' .. coord)
        local num = tonumber(c, 16)
        return tonumber(minus .. tostring(num))
    end
    local x = decodeCoord('X')
    local y = decodeCoord('Y')
    local z = decodeCoord('Z')

    -- Because position in ID is chunk offset
    local planetPos = Vector(x, y, z) * chunkSize * 2
    return type, planetPos
end


---Encodes info about planet into ID
---@param type PTYPE Type of planet, will be a string with an identifing letter
---@param planetPos Vector Full planet position
---@return string id
local function encodeId(type, planetPos)
    local chunk_offset = getChunkOffset(planetPos)
    local function tohex(num) return string.format("%s%x", num < 0 and "-" or "", math.abs(num)) end
    local id = string.upper(string.format("%s%sX%sY%sZ", type, tohex(chunk_offset.x), tohex(chunk_offset.y), tohex(chunk_offset.z)))
    return id
end

---@class ScannedPlanet
---@field name string
---@field type PTYPE
---@field position Vector
---@field owner string?


---Already scanned planets
---@type table<string, ScannedPlanet>
local scanned = {
    --[[
    id = {
        name = ...,
        type = "N",
        position = Vector(...),
        owner = ... | nil
    }
    --]]
}

-- Decode and add planets from list to already scanned
-- Existing planets. This is planets, that's writed in list with owner and name
http.get("https://raw.githubusercontent.com/maxobur0001/SpaceMapSF/refs/heads/main/planet_registry.json", function(body)
    local existingPlanets = json.decode(body)
    for _, planet in ipairs(existingPlanets) do
        local type, planetPos = decodeId(planet.id)
        scanned[planet.id] = {
            name = planet.name or planet.id,
            type = type,
            position = planetPos,
            owner = planet.owner
        }
    end
end)

-- Find planets, that's already initialized
-- for _, planet in ipairs(find.byClass("infmap_planet")) do
--     planet
-- end


---Camera position. If you set scanRange to 4000000
---you can see that planets started to disappear
---@type Vector
local camPos = Vector(0, 0, scanRange[2])

---Zoom for a camera. Why not just edit Z? Because ortho!
---@type number
local zoom = cameraZoomStart

local selected
if SERVER then

    -- Adjust wire inputs/outputs
    wire.adjustPorts(
        {
            CamX = { type = "number" },
            CamY = { type = "number" },
            -- i should use "Move" prefix, to make it sorted. don't beat me
            CamMoveForward = { type = "number" },
            CamMoveBackward = { type = "number" },
            CamMoveLeft = { type = "number" },
            CamMoveRight = { type = "number" },
            CamZoom = { type = "number" },
            CamZoomIn = { type = "number" },
            CamZoomOut = { type = "number" },
            CamGoto = { type = "string" },
            Select = { type = "number" },
            Scan = { type = "number" }
        },
        {
            Selected = "number",
            SelectedPosition = "vector",
            SelectedID = "string",
            SelectedName = "string",
            SelectedType = "string",
            SelectedOwner = "string",

            ScannedPosition = "vector",
            ScannedID = "string",
            ScannedType = "string",

            CamX = "number",
            CamY = "number",
            CamZoom = "number",
            Scanning = "number",
        }
    )
    -- Default outputs
    wire.ports.CamX = 0
    wire.ports.CamY = 0
    wire.ports.CamZoom = zoom
    wire.ports.Scanning = 0

    wire.ports.Selected = 0
    wire.ports.SelectedPosition = Vector()
    wire.ports.SelectedID = ""
    wire.ports.SelectedName = ""
    wire.ports.SelectedType = ""
    wire.ports.SelectedOwner = ""

    wire.ports.ScannedPosition = Vector()
    wire.ports.ScannedID = ""
    wire.ports.ScannedType = ""

    ---Prop, that scans a chunks
    ---@type Entity?
    local scanner

    ---Coroutine to scan
    ---@type fun()?
    local scanCoroutine

    ---Sync scanned table with clients
    local function syncScanned()
        net.start("scanned")
            net.writeTable(scanned)
        net.send(find.allPlayers())
    end

    ---Start scan by chunk
    local function startScan()
        -- If scanner valid, then scan in progress
        if isValid(scanner) then return end
        local position = camPos
        -- Give info to client, about starting a scanning for animation
        net.start("scanStarted")
            net.writeVector(position)
        net.send(find.allPlayers())
        -- "Hey wiremod, we are scanning"
        wire.ports.Scanning = 1
        local height = scanRange[2] - chunkHalf
        -- Prop as scanner. Props can initialize chunk with planets
        scanner = prop.create(position:setZ(height), Angle(), "models/Combine_Helicopter/helicopter_bomb01.mdl", true)
        scanner:setNoDraw(true)
        local maxHeight = scanRange[1] - chunkHalf
        -- Aaaaand coroutine. Why not timer? Timer is boring
        scanCoroutine = coroutine.wrap(function()
            -- For loop, we should get into a center of chunk
            for currentHeight=height, maxHeight, -chunkSize do
                if !isValid(scanner) then return false end
                position:setZ(currentHeight)
                scanner:setPos(position)
                -- I use find.byClass, because it faster than find.inSphere
                local planets = find.byClass("infmap_planet")
                -- Because it's can be called at almost every tick, small optimizations is all of our
                for i=1, #planets do
                    local planet = planets[i]
                    local planetPos = planet:getPos()
                    -- If position of planet in chunk with a scanner prop, then identify it
                    if planetPos:getDistance(position) <= chunkSize then
                        local mat = planet:getMaterial()
                        local ptype = PTYPE[mat]
                        local id = encodeId(ptype, planetPos)
                        if !scanned[id] then
                            scanned[id] = { name = id, position = planetPos, type = ptype }
                            -- wire hi
                            wire.ports.ScannedID = id
                            wire.ports.ScannedPosition = planetPos
                            wire.ports.ScannedType = ptype
                            wire.ports.Scanning = 0
                            syncScanned()
                            scanner:remove()
                            scanner = nil
                            return true
                        end
                    end
                end
                coroutine.wait(scanSleeping)
                coroutine.yield()
            end
            return false
        end)
    end

    hook.add("Think", "Scan", function()
        if !scanCoroutine then return end
        if scanCoroutine() ~= nil then
            if scanner and isValid(scanner) then
                wire.ports.Scanning = 0
                scanner:remove()
                scanner = nil
            end
            scanCoroutine = nil
        end
    end)

    local box = Vector(chunkSize, chunkSize, 0)
    local function selectPlanet()
        local position = camPos
        for id, planet in pairs(scanned) do
            local min = planet.position - box
            local max = planet.position + box
            if (position.x > min.x and position.y > min.y) and (position.x < max.x and position.y < max.y) then
                selected = selected ~= id and id or nil
                net.start("selectPlanet")
                    net.writeString(selected or "")
                net.send(find.allPlayers())
                wire.ports.Selected = selected and 1 or 0
                wire.ports.SelectedID = selected or ""
                wire.ports.SelectedName = selected and planet.name or ""
                wire.ports.SelectedPosition = selected and planet.position or Vector()
                return
            end
        end
    end

    hook.add("Think", "ContiniouslyWireInputs", function()
        local p = wire.ports
        local xMult = (p.CamMoveRight - p.CamMoveLeft)
        local yMult = (p.CamMoveForward - p.CamMoveBackward)
        if xMult ~= 0 or yMult ~= 0 then
            local speed = cameraSpeed / (200000 / zoom)
            local xSpeed = xMult * speed
            local ySpeed = yMult * speed
            local currentPos = Vector(camPos.x + xSpeed, camPos.y + ySpeed, 0)
            net.start("camPos")
                net.writeVector(currentPos)
            net.send(find.allPlayers())
            p.CamX = currentPos.x
            p.CamY = currentPos.y
            camPos.x = currentPos.x
            camPos.y = currentPos.y
        end

        local zoomMult = (p.CamZoomIn - p.CamZoomOut)
        if zoomMult ~= 0 then
            zoom = math.max(zoom + zoomMult * cameraZoomSpeed, 50000)
            p.CamZoom = zoom
            net.start("camZoom")
                net.writeInt(zoom, 24)
            net.send(find.allPlayers())
        end
    end)

    hook.add("Think", "SyncChipChunkOffset", function()
        local chunkOffset = getChunkOffset(ch:getPos())
        ch.CHUNK_OFFSET = chunkOffset
        net.start("chipOffset")
            net.writeVector(chunkOffset)
        net.send(find.allPlayers())
    end)

    hook.add("Input", "WireInputs", function(input, value)
        local p = wire.ports
        if input == "Scan" and value > 0 then
            startScan()

        elseif input == "Select" and value > 0 then
            selectPlanet()

        elseif table.hasValue({"CamX", "CamY"}, input) then
            p[input] = value
            net.start("camPos")
                net.writeVector(Vector(p.CamX, p.CamY, 0))
            net.send(find.allPlayers())

        elseif input == "CamZoom" then
            zoom = math.max(value, 50000)
            p.CamZoom = zoom
            net.start("camZoom")
                net.writeInt(zoom, 24)
            net.send(find.allPlayers())
        end
    end)
else
    -- rendertarget shit
    render.createRenderTarget("space")
    local mat = material.create("gmodscreenspace")
    mat:setTextureRenderTarget("$basetexture", "space")

    ---Rendered variable. Don't render view if there no screen
    local screenRendered = false

    ---Distance to undraw. For zfar parameter
    local dist = scanRange[2] - scanRange[1]

    ---Visual camera position, to lerp it
    local visualCamPos = camPos

    ---Render scene, to render planets on screen
    hook.add("RenderScene", "", function()
        if !screenRendered then return end
        -- This is a limit for renderView, to safe chip
        visualCamPos = math.lerpVector(0.2, visualCamPos, camPos)
        if cpuAverage() > cpuMax() / 2 then return end
        -- Draw in rendertarget to material, to except some bugs
        render.selectRenderTarget("space")
        do
            local half = zoom / 2
            -- idk about suppressing. is it working?
            render.suppressEngineLighting(true)
            render.setFogColor(Color(0, 0, 0))
            ---@type ViewData
            local data = {
                origin = unlocalizeVector(visualCamPos, -ch.CHUNK_OFFSET), angles = Angle(90, 90, 0),
                -- Orthogonal vision gives static sizes, without addiction to distance
                ortho = { left = -half, right = half, top = -half, bottom = half},
                -- To except some bugs, again
                x = 0, y = 0, w = 1024, h = 1024,
                -- ZFar to prevent world to draw
                aspect = 1, zfar = dist,
                drawhud = false, drawviewer = false, drawviewmodel = false
            }
            render.renderView(data)
        end
        render.selectRenderTarget()
        screenRendered = false
    end)

    ---Convert units to pixels
    ---@param units number
    ---@return number pixels
    local function unitsToPixels(units)
        return (units / zoom) * 512
    end

    ---Cycle value
    ---@param num number
    ---@param min number
    ---@param max number
    ---@return number cycledNum
    local function cycle(num, min, max)
        while num < min or num > max do
            if num < min then
                num = max - (min - num)
            elseif num > max then
                num = min + (num - max)
            end
        end
        return num
    end

    local scanPos
    local scanAnimProcess = 0
    hook.add("Render", "", function()
        screenRendered = true
        render.setMaterial(mat)
        render.drawTexturedRect(0, 0, 512, 512)

        local pixelOffsetX = unitsToPixels(visualCamPos.x)
        local pixelOffsetY = unitsToPixels(visualCamPos.y)
        local chunkWidth = unitsToPixels(chunkSize)
        do
            --- Chunks
            render.setColor(Color(30, 30, 30))
            local count = math.ceil(512 / chunkWidth) * 2
            for i=-count, count do
                local widthOffset = (chunkWidth * i * 2) + chunkWidth
                local y1 = 256 + cycle(pixelOffsetY, -512, 512) + widthOffset
                render.drawLine(0, y1, 512, y1)
                local x1 = 256 - cycle(pixelOffsetX, -512, 512) + widthOffset
                render.drawLine(x1, 0, x1, 512)
            end

            -- X/Y
            render.setColor(Color(200, 0, 0))
            local y = 256 + pixelOffsetY
            render.drawLine(0, y, 512, y)

            render.setColor(Color(0, 200, 0))
            local x = 256 - pixelOffsetX
            render.drawLine(x, 0, x, 512)
        end

        -- Crosshair
        do
            render.setColor(Color(255, 255, 255))
            render.drawRect(255, 255, 2, 2)
        end

        -- Current chip position
        do
            local currentPos = unlocalizeVector(ch:getPos(), ch.CHUNK_OFFSET)
            local pixelPosX = unitsToPixels(currentPos.x)
            local pixelPosY = unitsToPixels(currentPos.y)
            render.setColor(Color(255, 0, 0))
            render.drawRect(256 - (pixelOffsetX - pixelPosX) - 1, 256 + (pixelOffsetY - pixelPosY) - 1, 2, 2)
        end

        -- Planets
        do
            local double = chunkWidth * 2
            for id, v in pairs(scanned) do
                local currentPos = v.position
                local pixelPosX = unitsToPixels(currentPos.x)
                local pixelPosY = unitsToPixels(currentPos.y)
                local x = 256 - (pixelOffsetX - pixelPosX)
                local y = 256 + (pixelOffsetY - pixelPosY)
                render.setColor(id == selected and Color(0, 255, 0) or Color(255, 0, 0))
                render.drawRectOutline(x - chunkWidth + 1, y - chunkWidth + 1, double, double)
                local textX = x + chunkWidth - 1
                local textY = y + chunkWidth - 1
                local size = render.getTextSize(v.name)
                render.drawText(math.clamp(textX, 0, 512 - size), math.clamp(textY, 0, 496), v.name)
                if zoom > 800000 or (textX < 128 or textY < 128) or (textX > 384 or textY > 384) then goto cont end
                render.drawText(textX + 8, textY + 16, "Тип: " .. PRETTY[v.type])
                render.drawText(textX + 8, textY + 32, "Позиция: " .. tostring(currentPos))
                if v.owner then
                    render.drawText(textX + 8, textY + 48, "Владелец: " .. v.owner)
                end
                ::cont::
            end
        end

        -- Scan position
        if scanPos and scanAnimProcess < 1 then
            local pixelPosX = unitsToPixels(scanPos.x)
            local pixelPosY = unitsToPixels(scanPos.y)
            local sin = math.easeOutCubic(scanAnimProcess)
            local scanWidth = unitsToPixels(30000) * sin
            render.setColor(Color(255, 0, 0, (1 - sin) * 255))
            render.drawCircle(256 - (pixelOffsetX - pixelPosX) - 1, 256 + (pixelOffsetY - pixelPosY) - 1, scanWidth)
            scanAnimProcess = scanAnimProcess + 0.01
        end

        -- Cursor position
        render.setColor(Color(0, 255, 0))
        render.drawSimpleText(256, 256, tostring(camPos))
    end)


    net.receive("camPos", function()
        camPos = net.readVector():setZ(scanRange[2])
    end)

    net.receive("camZoom", function()
        zoom = math.max(net.readInt(24), 50000)
    end)

    net.receive("scanStarted", function()
        scanPos = net.readVector()
        scanAnimProcess = 0
    end)

    net.receive("scanned", function()
        scanned = net.readTable()
    end)

    net.receive("selectPlanet", function()
        selected = net.readString()
        selected = selected == "" and nil or selected
    end)

    net.receive("chipOffset", function()
        ch.CHUNK_OFFSET = net.readVector()
    end)
end
