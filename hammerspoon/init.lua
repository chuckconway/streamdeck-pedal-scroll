-- Stream Deck Pedal Scroll Control
-- HTTP server that receives commands from the Stream Deck plugin

local speeds = {
    { name = "Slow",   delta = 2,  interval = 0.020 },
    { name = "Medium", delta = 5,  interval = 0.015 },
    { name = "Fast",   delta = 15, interval = 0.010 },
}

local currentSpeed = 1
local scrollTimer = nil
local scrollDirection = 0

local function stopScrolling()
    if scrollTimer then
        scrollTimer:stop()
        scrollTimer = nil
    end
end

local function startScrolling(direction)
    stopScrolling()
    scrollDirection = direction
    local speed = speeds[currentSpeed]
    scrollTimer = hs.timer.doEvery(speed.interval, function()
        hs.eventtap.scrollWheel({ 0, scrollDirection * speed.delta }, {}, "pixel")
    end)
end

local function cycleSpeed()
    currentSpeed = (currentSpeed % #speeds) + 1
    local speed = speeds[currentSpeed]
    hs.alert.show("Scroll: " .. speed.name, 0.8)
    if scrollTimer then
        startScrolling(scrollDirection)
    end
end

-- HTTP server on port 27183
local server = hs.httpserver.new(false, false)
server:setPort(27183)
server:setCallback(function(method, path)
    if path == "/scroll/up" then
        startScrolling(1)
        return "ok", 200, {}
    elseif path == "/scroll/down" then
        startScrolling(-1)
        return "ok", 200, {}
    elseif path == "/scroll/stop" then
        stopScrolling()
        return "ok", 200, {}
    elseif path == "/scroll/speed" then
        cycleSpeed()
        return "ok", 200, {}
    else
        return "not found", 404, {}
    end
end)
server:start()
hs.alert.show("Pedal scroll ready (port 27183)", 1)
