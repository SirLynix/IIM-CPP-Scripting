
function Init()
    window:SetTitle("Hello world")
end

local frameCount = 0

local x = 400
local y = 300
local speed = 100

function OnFrame(elapsedTime)
    if IsKeyPressed("up") then
        y = y - speed * elapsedTime
    end
    if IsKeyPressed("down") then
        y = y + speed * elapsedTime
    end

    if IsKeyPressed("left") then
        x = x - speed * elapsedTime
    end

    if IsKeyPressed("right") then
        x = x + speed * elapsedTime
    end


    DrawCircle(x, y)
end