--==============================================================
-- 随机塔防 宏录制/回放 v2.7 (完美 UI 背景收尾版)
--==============================================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local Workspace   = game:GetService("Workspace")
local player      = Players.LocalPlayer
local playerGui   = player:WaitForChild("PlayerGui")

local SAVE_FOLDER = "TD2_Macro_Data"
local CONFIG_FILE = "TD2_Macro_Data/config.json" 

--==================== Remotes ====================
local Remotes             = RS:WaitForChild("Remotes", 30)
local Functions           = Remotes and Remotes:WaitForChild("Functions", 30)
local Events              = Remotes and Remotes:WaitForChild("Events", 30)
local RequestPlacement    = Functions and Functions:WaitForChild("RequestPlacement", 30)
local RequestTowerUpgrade = Functions and Functions:WaitForChild("RequestTowerUpgrade", 30)
local RequestTowerSell    = Functions and Functions:WaitForChild("RequestTowerSell", 30)
local CastDifficultyVote  = Events and Events:WaitForChild("CastDifficultyVote", 30)
local ReadyUp             = Events and Events:WaitForChild("ReadyUp", 30)
local ResultsAction       = Events and Events:WaitForChild("ResultsAction", 30)

--==================== 状态 ====================
local currentMacroName = nil
local recordings       = {}
local allMacrosData    = {}
local isRecording      = false
local isPlaying        = false
local playThread       = nil
local liveCash         = 0
local uidMap           = {}
local readyFrameRef    = nil
local verbose          = true
local dbLines          = {}
local dbgParagraph     = nil
local lastDbRefresh    = 0

local autoVote           = false
local autoReady          = false
local autoPlayOnReady    = false
local autoRejoin         = false
local autoPickItem       = false 
local replayDelay        = 3
local selectedDifficulty = "Medium"

local CASH_WAIT_MAX = 25   
local PLACE_RETRY   = 2    
local ACTION_GAP    = 0.08 

local startPlayback, stopPlayback   

--==================== 工具 ====================
local function guid()
    local ok, id = pcall(function() return HttpService:GenerateGUID(false) end)
    if ok and type(id) == "string" and #id >= 32 then return id:lower() end
    return string.format("%08x-%04x-4%03x-%04x-%012x",
        math.random(0, 0x7fffffff), math.random(0, 0xffff), math.random(0, 0xfff),
        math.random(0x8000, 0xbfff), math.random(0, 0xffffffff))
end

local function readCash()
    local ok, text = pcall(function()
        local core   = playerGui:FindFirstChild("CoreGui")
        local border = core and core:FindFirstChild("UIBorder")
        local mc     = border and border:FindFirstChild("MoneyCount")
        local m      = mc and mc:FindFirstChild("Money")
        return m and m.Text
    end)
    if not ok or not text then return nil end
    local s = tostring(text):gsub("[%$,%s]", ""):upper()
    local num, suf = s:match("^([%d%.]+)([KMB]?)$")
    local v = tonumber(num)
    if not v then return nil end
    if suf == "K" then v = v * 1e3
    elseif suf == "M" then v = v * 1e6
    elseif suf == "B" then v = v * 1e9 end
    return math.floor(v)
end

local function findByName(root, name)
    if not root then return nil end
    local direct = root:FindFirstChild(name)
    if direct then return direct end
    for _, d in ipairs(root:GetDescendants()) do
        if d.Name == name then return d end
    end
    return nil
end

local function isVisibleDeep(obj)
    local o = obj
    while o and o ~= playerGui do
        if o:IsA("GuiObject") and not o.Visible then return false end
        o = o.Parent
    end
    return true
end

local function log(msg)
    local line = ("[%s] %s"):format(os.date("%H:%M:%S"), msg)
    table.insert(dbLines, line)
    while #dbLines > 14 do table.remove(dbLines, 1) end
    if verbose then print(line) end
    if dbgParagraph and os.clock() - lastDbRefresh > 0.5 then
        lastDbRefresh = os.clock()
        pcall(function() dbgParagraph:SetDesc(table.concat(dbLines, "\n")) end)
    end
end

--==================== 存档 & 状态记忆 ====================
pcall(function()
    if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
end)

local function loadAllMacros()
    local names = { "新建宏..." }
    pcall(function()
        for _, file in ipairs(listfiles(SAVE_FOLDER)) do
            local name = file:match("([^/\\]+)%.json$")
            if name and name ~= "config" then 
                table.insert(names, name)
                local ok, data = pcall(function()
                    return HttpService:JSONDecode(readfile(file))
                end)
                if ok and type(data) == "table" then allMacrosData[name] = data end
            end
        end
    end)
    return names
end

local function saveCurrentMacro()
    if not currentMacroName or currentMacroName == "新建宏..." then return end
    allMacrosData[currentMacroName] = recordings
    pcall(function()
        writefile(SAVE_FOLDER .. "/" .. currentMacroName .. ".json", HttpService:JSONEncode(recordings))
    end)
end

local function loadSettings()
    local settings = {}
    pcall(function()
        if isfile(CONFIG_FILE) then
            settings = HttpService:JSONDecode(readfile(CONFIG_FILE))
        end
    end)
    return settings
end

local function saveSettings()
    local settings = {
        macroName = currentMacroName,
        autoVote = autoVote,
        autoReady = autoReady,
        autoPlayOnReady = autoPlayOnReady,
        autoRejoin = autoRejoin,
        autoPickItem = autoPickItem,
        replayDelay = replayDelay,
        selectedDifficulty = selectedDifficulty,
        verbose = verbose
    }
    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(settings))
    end)
end

local savedData = loadSettings()

--==================== 余额监听 ====================
task.spawn(function()
    while true do
        task.wait(0.1)
        local v = readCash()
        if v then liveCash = v end
    end
end)

--==================== UI ====================
-- 【核心修复】：不再全屏，把背景图 ID 直接交给 WindUI 处理
local Window = WindUI:CreateWindow({
    Title = "塔防宏 2.7",
    Author = "Macro + Memory",
    Icon = "shield",
    
    -- 原生背景图，只在UI框内部生效
    Background = "rbxassetid://79176013131678", 
    BackgroundImageTransparency = 0.3, -- 透明度，保证看字清晰
    Transparent = true,
})

local MainTab = Window:Tab({ Title = "宏控制", Icon = "settings" })
local AutoTab = Window:Tab({ Title = "自动化", Icon = "zap" })
local DbgTab  = Window:Tab({ Title = "调试", Icon = "bug" })

local statusParagraph = MainTab:Paragraph({ Title = "状态", Desc = "状态: 等待操作..." })
local function setStatus(text)
    pcall(function() statusParagraph:SetDesc(text) end)
end

dbgParagraph = DbgTab:Paragraph({ Title = "运行日志", Desc = "-" })

--==================== 宏管理 ====================
MainTab:Section({ Title = "宏管理" })

local macroList = loadAllMacros()
local startMacro = savedData.macroName or "新建宏..."
if not table.find(macroList, startMacro) then startMacro = "新建宏..." end

local macroDropdown = MainTab:Dropdown({
    Title = "选择已有宏",
    Values = macroList,
    Value = startMacro,
    Callback = function(opt)
        if opt == "新建宏..." then
            currentMacroName = nil
            recordings = {}
            setStatus("状态: 未选择宏")
        else
            currentMacroName = opt
            recordings = allMacrosData[opt] or {}
            setStatus(("状态: 已加载 [%s]，%d 个动作"):format(opt, #recordings))
        end
        saveSettings() 
    end,
})

if startMacro ~= "新建宏..." then
    currentMacroName = startMacro
    recordings = allMacrosData[startMacro] or {}
    setStatus(("状态: 已恢复 [%s]"):format(startMacro))
end

MainTab:Input({
    Title = "新建宏名称",
    Placeholder = "输入名称后回车",
    Callback = function(text)
        if text == "" or allMacrosData[text] then return end
        allMacrosData[text] = {}
        recordings = {}
        pcall(function()
            writefile(SAVE_FOLDER .. "/" .. text .. ".json", "[]")
        end)
        currentMacroName = text
        setStatus("状态: 已新建 [" .. text .. "]")
        pcall(function()
            macroDropdown:Refresh(loadAllMacros())
            macroDropdown:Set(text)
        end)
        saveSettings()
    end,
})

--==================== 录制 / 回放 ====================
MainTab:Section({ Title = "录制与回放" })

local recordToggle
local playToggle

recordToggle = MainTab:Toggle({
    Title = "开始录制",
    Value = false,
    Callback = function(v)
        if v then
            if isPlaying then stopPlayback() end
            if not currentMacroName or currentMacroName == "新建宏..." then
                pcall(function() recordToggle:Set(false) end)
                setStatus("状态: 请先选择或新建宏")
                return
            end
            recordings = {}
            uidMap = {}
            isRecording = true
            setStatus("状态: 🔴 录制中...")
            log("开始录制 [" .. currentMacroName .. "]")
        else
            isRecording = false
            saveCurrentMacro()
            setStatus(("状态: 已保存 %d 个动作"):format(#recordings))
            log(("录制结束，共 %d 个动作"):format(#recordings))
        end
    end,
})

playToggle = MainTab:Toggle({
    Title = "回放当前宏",
    Value = false,
    Callback = function(v)
        if v then startPlayback() else stopPlayback() end
    end,
})

MainTab:Button({
    Title = "强制停止回放",
    Callback = function() stopPlayback() end,
})

--==================== 自动化 ====================
AutoTab:Section({ Title = "挂机" })

AutoTab:Toggle({
    Title = "自动投票",
    Value = savedData.autoVote or false,
    Callback = function(v) autoVote = v; saveSettings() end,
})

local diffDropdown = AutoTab:Dropdown({
    Title = "投票难度",
    Values = { "Easy", "Medium", "Hard", "Insane" },
    Value = savedData.selectedDifficulty or "Medium",
    Callback = function(o) selectedDifficulty = o; saveSettings() end,
})
selectedDifficulty = diffDropdown.Value

AutoTab:Toggle({
    Title = "自动点准备 (ReadyButton)",
    Value = savedData.autoReady or false,
    Callback = function(v) autoReady = v; saveSettings() end,
})

AutoTab:Toggle({
    Title = "出现 ReadyFrame 时自动回放",
    Value = savedData.autoPlayOnReady or false,
    Callback = function(v) autoPlayOnReady = v; saveSettings() end,
})

AutoTab:Toggle({
    Title = "打完后自动重开下一局",
    Value = savedData.autoRejoin or false,
    Callback = function(v) autoRejoin = v; saveSettings() end,
})

AutoTab:Toggle({
    Title = "自动瞬移捡道具",
    Value = savedData.autoPickItem or false,
    Callback = function(v) autoPickItem = v; saveSettings() end,
})
autoPickItem = savedData.autoPickItem or false

local delayInput = AutoTab:Input({
    Title = "回放延迟（秒）",
    Placeholder = tostring(savedData.replayDelay or "3"),
    Callback = function(t)
        local n = tonumber(t)
        if n then 
            replayDelay = math.clamp(n, 0, 30) 
            saveSettings()
        end
    end,
})
replayDelay = savedData.replayDelay or 3

--==================== 调试 ====================
DbgTab:Section({ Title = "诊断" })

local verboseToggle = DbgTab:Toggle({
    Title = "控制台输出日志",
    Value = savedData.verbose ~= false,
    Callback = function(v) verbose = v; saveSettings() end,
})
verbose = savedData.verbose ~= false

DbgTab:Button({
    Title = "打印当前宏摘要",
    Callback = function()
        log(("宏: %s  动作数: %d"):format(tostring(currentMacroName), #recordings))
    end,
})

--==================== 录制 Hook ====================
local function installHook()
    pcall(function()
        if getgenv().TD2_OLD_NAMECALL then
            hookmetamethod(game, "__namecall", getgenv().TD2_OLD_NAMECALL)
        end
    end)

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method ~= "InvokeServer" and method ~= "FireServer" then return oldNamecall(self, ...) end
        if typeof(self) ~= "Instance" then return oldNamecall(self, ...) end
        if not isRecording or isPlaying then return oldNamecall(self, ...) end

        local name = self.Name
        if name == "RequestPlacement" then
            local a1, a2, a3 = ...
            local results = table.pack(oldNamecall(self, ...))
            local realUid = results[1]

            if type(realUid) == "string" and typeof(a2) == "Vector3" then
                table.insert(recordings, {
                    kind = "place", tower = tostring(a1),
                    pos = { a2.X, a2.Y, a2.Z }, rot = tonumber(a3) or 0,
                    realUid = realUid, cash = liveCash,
                })
                setStatus(("状态: 🔴 已录放塔 (%d)"):format(#recordings))
                log(("录制放塔 %s -> %s"):format(tostring(a1), realUid))
            end
            return table.unpack(results, 1, results.n)

        elseif name == "RequestTowerUpgrade" or name == "RequestTowerSell" then
            local a1 = ...
            table.insert(recordings, {
                kind = (name == "RequestTowerUpgrade") and "upgrade" or "sell",
                uid  = tostring(a1), cash = liveCash,
            })
            setStatus(("状态: 🔴 已录动作 (%d)"):format(#recordings))
            log(("录制%s %s"):format((name == "RequestTowerUpgrade") and "升级" or "卖塔", tostring(a1)))
            return oldNamecall(self, ...)
        end

        return oldNamecall(self, ...)
    end)
    getgenv().TD2_OLD_NAMECALL = oldNamecall
end

--==================== 回放 ====================
local function placeOnce(act)
    local uid = guid()
    local ts  = Workspace:GetServerTimeNow() 
    local ok, ret = pcall(function()
        return RequestPlacement:InvokeServer(act.tower, Vector3.new(act.pos[1], act.pos[2], act.pos[3]), act.rot or 0, uid, ts)
    end)
    if ok and type(ret) == "string" then return true, ret end
    return false, ok and ret or tostring(ret)
end

local function runTowerAction(act, failedUid)
    if not act.uid or failedUid[act.uid] then return false, "skip" end
    local target = uidMap[act.uid]
    if not target then return false, "skip" end 
    local remote = (act.kind == "upgrade") and RequestTowerUpgrade or RequestTowerSell
    if not remote then return false, "no remote" end
    local ok, ret = pcall(function() return remote:InvokeServer(target) end)
    return ok, ret
end

local function finishPlayback(msg)
    isPlaying = false
    playThread = nil
    if playToggle then pcall(function() playToggle:Set(false) end) end
    if msg then setStatus(msg) end
end

function startPlayback()
    if isRecording or isPlaying or #recordings == 0 then return end
    isPlaying = true
    uidMap = {}
    pcall(function() playToggle:Set(true) end)
    setStatus("状态: 🟢 回放开始")
    log(("回放开始，共 %d 个动作"):format(#recordings))

    playThread = task.spawn(function()
        local failedUid = {}
        local okN, failN, skipN = 0, 0, 0

        for i, act in ipairs(recordings) do
            if not isPlaying then break end
            if act.cash and act.cash > 0 then
                local deadline = os.clock() + CASH_WAIT_MAX
                while isPlaying and liveCash < act.cash and os.clock() < deadline do
                    setStatus(("🟡 等钱 %d/%d 需 %d 现 %d"):format(i, #recordings, act.cash, liveCash))
                    task.wait(0.1)
                end
            end
            if not isPlaying then break end

            if act.kind == "place" then
                local ok, ret
                for _ = 1, PLACE_RETRY do
                    ok, ret = placeOnce(act)
                    if ok then break end
                    task.wait(0.25)
                end
                if ok then
                    okN = okN + 1
                    if act.realUid then uidMap[act.realUid] = ret end
                    setStatus(("🟢 放塔 %d/%d [%s]"):format(i, #recordings, act.tower))
                    log(("放塔 %d/%d %s -> %s"):format(i, #recordings, act.tower, ret))
                else
                    failN = failN + 1
                    if act.realUid then failedUid[act.realUid] = true end
                    log(("放塔失败 %d %s ret=%s"):format(i, act.tower, tostring(ret)))
                end
            else
                local ok, ret = runTowerAction(act, failedUid)
                if ok then
                    okN = okN + 1
                    log(("%s %d ok"):format(act.kind, i))
                elseif ret == "skip" then
                    skipN = skipN + 1
                else
                    failN = failN + 1
                    log(("%s 失败 %d ret=%s"):format(act.kind, i, tostring(ret)))
                end
            end
            task.wait(ACTION_GAP)
        end
        finishPlayback(("状态: 🟢 结束 成功%d 失败%d"):format(okN, failN))
    end)
end

function stopPlayback()
    if not isPlaying then return end
    isPlaying = false
    if playThread then pcall(function() task.cancel(playThread) end); playThread = nil end
    pcall(function() playToggle:Set(false) end)
    setStatus("状态: 🟡 已停止")
end

--==================== 自动捡道具 ====================
Workspace:WaitForChild("ItemDrops", 10)
local itemDropsFolder = Workspace:FindFirstChild("ItemDrops")

if itemDropsFolder then
    itemDropsFolder.DescendantAdded:Connect(function(item)
        if not autoPickItem or not item:IsA("Model") then return end
        task.wait(0.1)
        if not autoPickItem or not item.Parent then return end
        
        local targetPos = item.PrimaryPart and item.PrimaryPart.Position or (pcall(function() return item:GetPivot().Position end) and item:GetPivot().Position)
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        
        if targetPos and hrp then
            local returnPos = hrp.CFrame
            hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 2, 0))
            log("⭐ 发现道具，已瞬移拾取")
            task.wait(0.3)
            if autoPickItem and hrp and hrp.Parent then hrp.CFrame = returnPos end
        end
    end)
end

--==================== 自动化循环 ====================
task.spawn(function()
    local firedRound = false
    local lastVote, lastReady, lastRejoin = 0, 0, 0

    while true do
        task.wait(0.2)
        if not isRecording then
            local now = os.clock()
            if autoVote and CastDifficultyVote and now - lastVote >= 1 then
                lastVote = now
                pcall(function() CastDifficultyVote:FireServer(selectedDifficulty) end)
            end
            if autoRejoin and ResultsAction and now - lastRejoin >= 3 then
                lastRejoin = now
                pcall(function() ResultsAction:FireServer("Rejoin") end)
            end

            local frame = findByName(playerGui, "ReadyFrame")
            if frame and isVisibleDeep(frame) then
                if autoReady and now - lastReady >= 1 then
                    lastReady = now
                    local btn = frame:FindFirstChild("ReadyButton", true)
                    if btn and btn:IsA("TextButton") and isVisibleDeep(btn) then
                        local ok = pcall(function() firesignal(btn.MouseButton1Click) end)
                        if not ok and ReadyUp then pcall(function() ReadyUp:FireServer() end) end
                    end
                end
                if autoPlayOnReady and not firedRound then
                    firedRound = true
                    setStatus(("状态: 🟢 ReadyFrame 出现，%.1f 秒后回放"):format(replayDelay))
                    task.wait(replayDelay)
                    if not isRecording then
                        if isPlaying then stopPlayback() task.wait(0.3) end
                        startPlayback()
                    end
                end
            else
                firedRound = false
            end
        end
    end
end)

--==================== 启动 ====================
installHook()
log("脚本加载完成，已恢复上次状态。")
