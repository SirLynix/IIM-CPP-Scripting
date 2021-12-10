
function Init()
    SetWindowTitle("Hello world")
end

local frameCount = 0
function OnFrame()
    frameCount = frameCount + 1
    SetWindowTitle("Frame #" .. frameCount)
end