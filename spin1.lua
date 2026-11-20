-- 创建 ScreenGui
local player = game:GetService("Players").LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oldGui = playerGui:FindFirstChild("SummonSpamGui")
if oldGui then oldGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SummonSpamGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- 创建按钮
local button = Instance.new("TextButton")
button.Name = "SummonButton"
button.Size = UDim2.new(0, 160, 0, 50)
button.Position = UDim2.new(1, -180, 0, 20)
button.AnchorPoint = Vector2.new(0, 0)
button.BackgroundColor3 = Color3.fromRGB(30, 144, 255)
button.TextColor3 = Color3.fromRGB(255, 255, 255)
button.Text = "开始连点 (OFF)"
button.TextScaled = true
button.Font = Enum.Font.GothamBold
button.BorderSizePixel = 0
button.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = button

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Thickness = 2
stroke.Parent = button

-- 状态与循环
local running = false
local thread = nil

local function doSummon()
    local args = {10}
    local ok, err = pcall(function()
        game:GetService("ReplicatedStorage")
            :WaitForChild("Remotes")
            :WaitForChild("Functions")
            :WaitForChild("RequestSummon")
            :InvokeServer(unpack(args))
    end)
    if not ok then
        warn("[SummonSpam] 调用失败: " .. tostring(err))
    end
end

local function loop()
    while running do
        doSummon()
        task.wait(0.5)
    end
end

button.MouseButton1Click:Connect(function()
    running = not running
    if running then
        button.Text = "连点中... (ON)"
        button.BackgroundColor3 = Color3.fromRGB(34, 139, 34)
        thread = task.spawn(loop)
    else
        button.Text = "开始连点 (OFF)"
        button.BackgroundColor3 = Color3.fromRGB(30, 144, 255)
        if thread then
            task.cancel(thread)
            thread = nil
        end
    end
end)
