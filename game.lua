
function Init()
    SetWindowTitle("Hello world")
end

local frameCount = 0
function OnFrame(elapsedTime)
    frameCount = frameCount + 1
    SetWindowTitle("Frame #" .. frameCount)
end