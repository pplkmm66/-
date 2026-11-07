-- 服务引用
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- 等待远程事件（沿用你原来的路径）
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LuckyWheel = Remotes:WaitForChild("LuckyWheel")

-- 创建屏幕 GUI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoSpinGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

-- 创建右上角开关按钮
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ToggleButton"
toggleBtn.Size = UDim2.new(0, 120, 0, 40)
toggleBtn.Position = UDim2.new(1, -130, 0, 10) -- 右上角，留出边距
toggleBtn.AnchorPoint = Vector2.new(0, 0)
toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50) -- 默认红色（关闭状态）
toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleBtn.Font = Enum.Font.SourceSansBold
toggleBtn.TextSize = 18
toggleBtn.Text = "自动抽奖：关"
toggleBtn.Parent = screenGui

-- 状态变量
local isSpinning = false
local spinCooldown = 0.5 -- 每次抽取的间隔秒数，可按需调整

-- 抽奖函数（包装你原来的调用）
local function doSpin()
    local args = { "spin" }
    -- 使用 pcall 防止远程调用出错导致循环中断
    local success, err = pcall(function()
        LuckyWheel:InvokeServer(unpack(args))
    end)
    if not success then
        warn("抽奖调用失败: " .. tostring(err))
    end
end

-- 持续抽奖的循环（在独立协程中运行）
local function startAutoSpin()
    -- 如果已经有循环在跑，直接返回
    if isSpinning then return end
    isSpinning = true

    -- 更新按钮外观
    toggleBtn.Text = "自动抽奖：开"
    toggleBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 50) -- 绿色

    -- 启动后台任务
    task.spawn(function()
        while isSpinning do
            doSpin()
            task.wait(spinCooldown)
        end
    end)
end

local function stopAutoSpin()
    isSpinning = false
    toggleBtn.Text = "自动抽奖：关"
    toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
end

-- 按钮点击切换
toggleBtn.MouseButton1Click:Connect(function()
    if isSpinning then
        stopAutoSpin()
    else
        startAutoSpin()
    end
end)
