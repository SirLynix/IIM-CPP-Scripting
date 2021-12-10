
function Init()
    SetWindowTitle("Hello world")
end

local frameCount = 0
function OnFrame(elapsedTime)
    DrawCircle(400, 300)
    DrawCircle(800, 300)
end