-- ==========================================
-- 1. 初始化 & 加载 WindUI
-- ==========================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local SAVE_FOLDER = "TowerMacro_Data"
local currentMacroName = nil
local allMacrosData = {} 
local recordings = {}
local isRecording = false
local isPlaying = false
local playTask = nil

local MacroIDCounter = 0
local InstanceMapping = {}
local isAutoReplayEnabled = false
local isAutoVoteEnabled = false
local isAutoStartEnabled = false 
local isAutoEarlyStartEnabled = false 
local selectedDifficulty = "Medium"
local hasAutoPlayedThisRound = false 
local lastRecordCount = 0

local liveCash = 0

pcall(function()
    if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
end)

local function loadAllMacros()
    local loadedNames = {"新建宏..."}
    pcall(function()
        local files = listfiles(SAVE_FOLDER)
        for _, file in ipairs(files) do
            local name = file:match("([^/\\]+)%.json$") 
            if name then
                table.insert(loadedNames, name)
                local content = readfile(file)
                local success, decoded = pcall(function() return HttpService:JSONDecode(content) end)
                if success and decoded then allMacrosData[name] = decoded end
            end
        end
    end)
    return loadedNames
end

task.spawn(function()
    while true do
        task.wait(0.05)
        local success, cashText = pcall(function()
            local ui = player.PlayerGui:FindFirstChild("GameUI")
            if ui then
                local bar = ui:FindFirstChild("CashBar")
                if bar then
                    local val = bar:FindFirstChild("CashValue")
                    if val and val:IsA("TextLabel") then return val.Text end
                end
            end
        end)
        if success and cashText then
            local cleanText = string.gsub(cashText, "[%$,%s]", "")
            local num = tonumber(cleanText)
            if num then liveCash = num end
        end
    end
end)

local function encodeArgs(args)
    local safeArgs = {}
    for i, v in ipairs(args) do
        if typeof(v) == "CFrame" then
            safeArgs[i] = { __type = "CFrame", pos = {v.X, v.Y, v.Z} }
        elseif typeof(v) == "Vector3" then
            safeArgs[i] = { __type = "Vector3", pos = {v.X, v.Y, v.Z} }
        elseif typeof(v) == "Instance" then
            safeArgs[i] = { __type = "Instance" }
        else
            safeArgs[i] = v
        end
    end
    return safeArgs
end

local function decodeArgs(safeArgs)
    local realArgs = {}
    for i, v in ipairs(safeArgs) do
        if type(v) == "table" and v.__type == "CFrame" then
            realArgs[i] = CFrame.new(v.pos[1], v.pos[2], v.pos[3])
        elseif type(v) == "table" and v.__type == "Vector3" then
            realArgs[i] = Vector3.new(v.pos[1], v.pos[2], v.pos[3])
        elseif type(v) == "table" and v.__type == "Instance" then
            realArgs[i] = nil 
        else
            realArgs[i] = v
        end
    end
    return realArgs
end

-- ==========================================
-- 2. WindUI 窗口
-- ==========================================
local Window = WindUI:CreateWindow({
    Title = "随机塔防1.0",
    Author = "WindUI 全兼容版",
    Icon = "shield",
    Background = "rbxassetid://79176013131678", 
    BackgroundImageTransparency = 0.3, 
    Transparent = true, 
})

local MainTab = Window:Tab({ Title = "宏控制", Icon = "settings" })
local statusParagraph = MainTab:Paragraph({ Title = "状态监控", Desc = "状态: 等待操作..." })
local function setStatus(text) pcall(function() statusParagraph:SetDesc(text) end) end

MainTab:Section({ Title = "宏管理" })
local macroDropdown = MainTab:Dropdown({
    Title = "选择已有宏", Values = loadAllMacros(), Value = "新建宏...",
    Callback = function(Option)
        if Option == "新建宏..." then currentMacroName = nil; recordings = {}; setStatus("状态: 未选择宏")
        else currentMacroName = Option; recordings = allMacrosData[currentMacroName] or {}; setStatus("状态: 已加载 ["..currentMacroName.."]，动作数: "..#recordings) end
    end,
})

MainTab:Input({
    Title = "新建宏名称", Placeholder = "输入名称后回车创建",
    Callback = function(Text)
        if Text == "" or allMacrosData[Text] then return end
        allMacrosData[Text] = {}
        pcall(function() writefile(SAVE_FOLDER .. "/" .. Text .. ".json", "[]") end)
        currentMacroName = Text; recordings = {}; setStatus("状态: 成功新建 ["..Text.."]")
        pcall(function() local newOptions = loadAllMacros(); macroDropdown:Refresh(newOptions); macroDropdown:Set(Text) end)
    end,
})

MainTab:Section({ Title = "录制与回放" })
local recordToggle = MainTab:Toggle({
    Title = "开启录制", Value = false,
    Callback = function(Value)
        if Value then
            if isPlaying then stopPlayback() end
            isAutoVoteEnabled = false; isAutoReplayEnabled = false; isAutoStartEnabled = false; isAutoEarlyStartEnabled = false
            if not currentMacroName or currentMacroName == "新建宏..." then recordToggle:Set(false); return end
            isRecording = true; recordings = {}; MacroIDCounter = 0; InstanceMapping = {}; lastRecordCount = 0
            setStatus("状态: 🔴 正在录制中...")
        else
            isRecording = false; setStatus("状态: 保存成功，共 "..#recordings.." 个动作")
            if currentMacroName then
                allMacrosData[currentMacroName] = recordings
                pcall(function() writefile(SAVE_FOLDER .. "/" .. currentMacroName .. ".json", HttpService:JSONEncode(recordings)) end)
            end
        end
    end,
})

local playToggle = MainTab:Toggle({
    Title = "开启回放 (单次跑完自动关闭)", Value = false,
    Callback = function(Value)
        if Value then
            if isRecording then playToggle:Set(false); return end
            if #recordings == 0 then playToggle:Set(false); return end
            startPlayback()
        else stopPlayback() end
    end,
})

local AutoTab = Window:Tab({ Title = "自动化", Icon = "zap" })
AutoTab:Section({ Title = "挂机功能" })

AutoTab:Toggle({ 
    Title = "自动重播", 
    Value = false, 
    Callback = function(v) 
        if isRecording and v then return end
        isAutoReplayEnabled = v
        if v then hasAutoPlayedThisRound = false end 
    end 
})

AutoTab:Toggle({ 
    Title = "出现【EARLY START】时自动回放", 
    Value = false, 
    Callback = function(v) 
        if isRecording and v then return end
        isAutoStartEnabled = v 
    end 
})

AutoTab:Toggle({ 
    Title = "自动点击提前开始", 
    Value = false, 
    Callback = function(v) 
        if isRecording and v then return end
        isAutoEarlyStartEnabled = v 
    end 
})

AutoTab:Toggle({ 
    Title = "自动投票", 
    Value = false, 
    Callback = function(v) 
        if isRecording and v then return end
        isAutoVoteEnabled = v 
    end 
})
AutoTab:Dropdown({ Title = "投票难度", Values = {"Easy", "Medium", "Hard", "Insane"}, Value = "Medium", Callback = function(o) selectedDifficulty = o end })

-- ==========================================
-- 3. 底层拦截 (修复：兼容 TowerAction 等特殊面板)
-- ==========================================
local oldRemote
oldRemote = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    local name = self.Name
    local args = {...}

    if isRecording and (method == "FireServer" or method == "InvokeServer") then
        -- 将 TowerAction 也加入到抓取关键字中
        if string.find(name, "Place") or string.find(name, "Upgrade") or string.find(name, "Sell") or string.find(name, "TowerAction") then
            local cashAtThisMoment = liveCash
            
            if string.find(name, "Place") then
                MacroIDCounter = MacroIDCounter + 1
                table.insert(recordings, { MacroID = MacroIDCounter, Type = "Place", CashBefore = cashAtThisMoment, SafeArgs = encodeArgs(args) })
            else
                -- 升级、卖塔、特殊动作
                local towerInstance = args[1]
                local foundID = nil
                for macroId, inst in pairs(InstanceMapping) do 
                    if inst == towerInstance then foundID = macroId; break end 
                end
                
                table.insert(recordings, { 
                    MacroID = foundID or 999, 
                    Type = "Action", -- 统一打包成动作
                    RemoteName = name, -- 记录是哪个具体函数
                    CashBefore = cashAtThisMoment,
                    SafeArgs = encodeArgs(args)
                })
            end
            task.spawn(function() setStatus("状态: 🔴 已录动作 ("..#recordings..")") end)
        end
    end
    
    return oldRemote(self, ...)
end)

workspace.DescendantAdded:Connect(function(obj)
    if isRecording and obj.Parent and obj.Parent.Name == "Towers" then InstanceMapping[MacroIDCounter] = obj end
end)

-- ==========================================
-- 4. 极限精准回放
-- ==========================================
function startPlayback()
    if isRecording or isPlaying or #recordings == 0 then return end
    isPlaying = true
    if playToggle then playToggle:Set(true) end
    setStatus("状态: 🟢 正在执行回放...")
    
    playTask = task.spawn(function()
        local playInstanceMapping = {}; local playIDCounter = 0
        local listenerConn = workspace.DescendantAdded:Connect(function(obj)
            if isPlaying and obj.Parent and obj.Parent.Name == "Towers" then playIDCounter = playIDCounter + 1; playInstanceMapping[playIDCounter] = obj end
        end)

        local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
        local PlaceRemote = Remotes:WaitForChild("PlaceTower")
        local UpgradeRemote = Remotes:WaitForChild("UpgradeTower")
        local SellRemote = Remotes:WaitForChild("SellTower")
        local TowerActionRemote = Remotes:FindFirstChild("TowerAction") -- 动态寻找

        for i, act in ipairs(recordings) do
            if not isPlaying or isRecording then break end
            
            local actionSuccess = false
            local attempts = 0
            local waitStartTime = os.clock() 
            
            while not actionSuccess and isPlaying and not isRecording do
                attempts = attempts + 1
                local requiredCash = act.CashBefore or 0
                
                local canExecute = false
                if act.Type == "Sell" or act.RemoteName == "SellTower" or liveCash >= requiredCash then canExecute = true end
                
                if canExecute then
                    setStatus("状态: 🟢 执行 ["..i.."/"..#recordings.."]")
                    
                    if act.Type == "Place" then
                        pcall(function() PlaceRemote:InvokeServer(unpack(decodeArgs(act.SafeArgs))) end)
                        task.wait(0.05) 
                        actionSuccess = true 
                        waitStartTime = os.clock()
                        
                    elseif act.Type == "Action" then
                        local oldTower = act.SafeArgs[1]
                        local targetID = act.MacroID
                        local targetTower = playInstanceMapping[targetID]
                        
                        if targetTower and targetTower.Parent then
                            local finalArgs = decodeArgs(act.SafeArgs)
                            finalArgs[1] = targetTower -- 替换为当前的塔实例
                            
                            pcall(function()
                                -- 根据录制时的 Remote 名字分发调用
                                if act.RemoteName == "UpgradeTower" then
                                    UpgradeRemote:InvokeServer(unpack(finalArgs))
                                elseif act.RemoteName == "SellTower" then
                                    SellRemote:InvokeServer(unpack(finalArgs))
                                elseif act.RemoteName == "TowerAction" and TowerActionRemote then
                                    TowerActionRemote:InvokeServer(unpack(finalArgs))
                                end
                            end)
                            task.wait(0.05)
                            actionSuccess = true
                            waitStartTime = os.clock()
                        else
                            setStatus("状态: 🟡 等待塔生成... ["..i.."]")
                            task.wait(0.05)
                            
                            if os.clock() - waitStartTime > 2 then
                                setStatus("状态: 🟠 超时补发! ["..i.."]")
                                waitStartTime = os.clock() 
                                if i > 1 then
                                    local prevAct = recordings[i-1]
                                    if prevAct.Type == "Place" then
                                        pcall(function() PlaceRemote:InvokeServer(unpack(decodeArgs(prevAct.SafeArgs))) end)
                                    end
                                end
                            end
                        end
                    end
                else
                    setStatus("状态: 🟡 等钱 ["..i.."]")
                    task.wait(0.01) 
                    if os.clock() - waitStartTime > 30 then actionSuccess = true end
                end
            end
        end

        if listenerConn then listenerConn:Disconnect() end
        if isPlaying then stopPlayback() end
    end)
end

function stopPlayback()
    if not isPlaying then return end
    isPlaying = false
    if playTask then task.cancel(playTask); playTask = nil end
    if playToggle then playToggle:Set(false) end
    setStatus("状态: 🟡 回放结束/已停止")
end

-- ==========================================
-- 5. 自动化后台 (UI 监控与发包)
-- ==========================================
task.spawn(function()
    local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes", 10)
    local VoteDiffRemote = Remotes and Remotes:WaitForChild("VoteDifficulty", 10)
    local EndChoiceRemote = Remotes and Remotes:WaitForChild("EndChoice", 10)
    local StartWaveRemote = Remotes and Remotes:WaitForChild("StartWave", 10)
    
    while task.wait(0.1) do
        if not isRecording then
            if isAutoVoteEnabled and VoteDiffRemote then pcall(function() VoteDiffRemote:FireServer(selectedDifficulty) end) end
            if isAutoReplayEnabled and EndChoiceRemote then pcall(function() EndChoiceRemote:InvokeServer("Replay") end); hasAutoPlayedThisRound = false end
            if isAutoEarlyStartEnabled and StartWaveRemote then pcall(function() StartWaveRemote:FireServer() end) end

            if isAutoStartEnabled and not hasAutoPlayedThisRound then
                local foundEarlyStart = false
                for _, gui in pairs(player.PlayerGui:GetDescendants()) do
                    if gui:IsA("TextLabel") or gui:IsA("TextButton") then
                        if gui.Visible and string.find(string.upper(gui.Text), "EARLY START") then
                            foundEarlyStart = true
                            break
                        end
                    end
                end

                if foundEarlyStart then
                    hasAutoPlayedThisRound = true
                    setStatus("状态: 🟢 发现[EARLY START]，3.2秒后放塔...")
                    task.wait(3.2)
                    if not isRecording then
                        if isPlaying then stopPlayback(); task.wait(0.2) end
                        startPlayback()
                    end
                end
            end
        end
    end
end)
