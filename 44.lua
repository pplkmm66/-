--==============================================================
-- 随机塔防 宏录制/回放 v2.0
-- 核心规则：
--   1) 放塔第4参 UUID 客户端随便生成即可，服务端不校验
--   2) 第5参时间戳必须「发包那一刻」现取 workspace:GetServerTimeNow()
--   3) RequestPlacement 返回的 string 才是真实塔 UUID，升级/卖塔必须用它
--   4) 旧真实UUID -> 本局新真实UUID 的映射在回放时实时建立
--==============================================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local player      = Players.LocalPlayer
local playerGui   = player:WaitForChild("PlayerGui")

local SAVE_FOLDER = "TD2_Macro_Data"

--==================== Remotes ====================
local Remotes             = RS:WaitForChild("Remotes", 30)
local Functions           = Remotes and Remotes:WaitForChild("Functions", 30)
local Events              = Remotes and Remotes:WaitForChild("Events", 30)
local RequestPlacement    = Functions and Functions:WaitForChild("RequestPlacement", 30)
local RequestTowerUpgrade = Functions and Functions:WaitForChild("RequestTowerUpgrade", 30)
local RequestTowerSell    = Functions and Functions:WaitForChild("RequestTowerSell", 30)
local CastDifficultyVote  = Events and Events:WaitForChild("CastDifficultyVote", 30)
local ReadyUp             = Events and Events:WaitForChild("ReadyUp", 30)

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
local replayDelay        = 3
local selectedDifficulty = "Medium"

local CASH_WAIT_MAX = 25   -- 单个动作最多等钱秒数
local PLACE_RETRY   = 2    -- 放塔失败重试次数
local ACTION_GAP    = 0.08 -- 动作间隔

local startPlayback, stopPlayback   -- 前向声明

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

--==================== 存档 ====================
pcall(function()
    if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
end)

local function loadAllMacros()
    local names = { "新建宏..." }
    pcall(function()
        for _, file in ipairs(listfiles(SAVE_FOLDER)) do
            local name = file:match("([^/\\]+)%.json$")
            if name then
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
    if not currentMacroName then return end
    allMacrosData[currentMacroName] = recordings
    pcall(function()
        writefile(SAVE_FOLDER .. "/" .. currentMacroName .. ".json",
            HttpService:JSONEncode(recordings))
    end)
end

--==================== 余额监听 ====================
task.spawn(function()
    while true do
        task.wait(0.1)
        local v = readCash()
        if v then liveCash = v end
    end
end)

--==================== UI ====================
local Window = WindUI:CreateWindow({
    Title = "塔防宏 2.0",
    Author = "Macro",
    Icon = "shield",
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

local macroDropdown = MainTab:Dropdown({
    Title = "选择已有宏",
    Values = loadAllMacros(),
    Value = "新建宏...",
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
    end,
})

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
            if not currentMacroName then
                pcall(function() recordToggle:Set(false) end)
                setStatus("状态: 请先选择或新建宏")
                return
            end
            recordings = {}
            uidMap = {}
            isRecording = true
            setStatus("状态: 🔴 录制中（正常放塔/升级/卖塔即可）")
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
    Value = false,
    Callback = function(v) autoVote = v end,
})

AutoTab:Dropdown({
    Title = "投票难度",
    Values = { "Easy", "Medium", "Hard", "Insane" },
    Value = "Medium",
    Callback = function(o) selectedDifficulty = o end,
})

AutoTab:Toggle({
    Title = "自动点准备 (ReadyButton)",
    Value = false,
    Callback = function(v) autoReady = v end,
})

AutoTab:Toggle({
    Title = "出现 ReadyFrame 时自动回放",
    Value = false,
    Callback = function(v) autoPlayOnReady = v end,
})

AutoTab:Input({
    Title = "回放延迟（秒）",
    Placeholder = "3",
    Callback = function(t)
        local n = tonumber(t)
        if n then replayDelay = math.clamp(n, 0, 30) end
    end,
})

--==================== 调试 ====================
DbgTab:Section({ Title = "诊断" })

DbgTab:Toggle({
    Title = "控制台输出日志",
    Value = true,
    Callback = function(v) verbose = v end,
})

DbgTab:Button({
    Title = "打印当前宏摘要",
    Callback = function()
        log(("宏: %s  动作数: %d"):format(tostring(currentMacroName), #recordings))
        local placeN, towerN = 0, 0
        for _, a in ipairs(recordings) do
            if a.kind == "place" then placeN = placeN + 1 else towerN = towerN + 1 end
        end
        log(("放塔 %d  升级/卖塔 %d"):format(placeN, towerN))
    end,
})

DbgTab:Button({
    Title = "测试：用第一条放塔动作发一次包",
    Callback = function()
        local act
        for _, a in ipairs(recordings) do
            if a.kind == "place" and a.pos then act = a break end
        end
        if not act then
            setStatus("状态: 没有可测试的放塔动作")
            return
        end
        if not RequestPlacement then
            setStatus("状态: RequestPlacement 不存在")
            return
        end
        local uid = guid()
        local ts  = workspace:GetServerTimeNow()
        local ok, ret = pcall(function()
            return RequestPlacement:InvokeServer(act.tower,
                Vector3.new(act.pos[1], act.pos[2], act.pos[3]), act.rot or 0, uid, ts)
        end)
        log(("测试放塔 %s ok=%s ret=%s"):format(tostring(act.tower), tostring(ok), tostring(ret)))
        setStatus("状态: 测试发包完成，看日志")
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
        if method ~= "InvokeServer" and method ~= "FireServer" then
            return oldNamecall(self, ...)
        end
        if typeof(self) ~= "Instance" then
            return oldNamecall(self, ...)
        end
        if not isRecording or isPlaying then
            return oldNamecall(self, ...)
        end

        local name = self.Name

        if name == "RequestPlacement" then
            local a1, a2, a3 = ...
            -- 先放行真实调用，拿到服务端返回的真实塔 UUID（这是唯一正确来源）
            local results = table.pack(oldNamecall(self, ...))
            local realUid = results[1]

            if type(realUid) == "string" and typeof(a2) == "Vector3" then
                table.insert(recordings, {
                    kind    = "place",
                    tower   = tostring(a1),
                    pos     = { a2.X, a2.Y, a2.Z },
                    rot     = tonumber(a3) or 0,
                    realUid = realUid,        -- ★ 服务端真实塔 UUID
                    cash    = liveCash,
                })
                setStatus(("状态: 🔴 已录放塔 (%d)"):format(#recordings))
                log(("录制放塔 %s -> %s"):format(tostring(a1), realUid))
            else
                log(("录制跳过：放塔未返回UUID (%s)"):format(tostring(realUid)))
            end
            return table.unpack(results, 1, results.n)

        elseif name == "RequestTowerUpgrade" or name == "RequestTowerSell" then
            local a1 = ...
            table.insert(recordings, {
                kind = (name == "RequestTowerUpgrade") and "upgrade" or "sell",
                uid  = tostring(a1),          -- 真实塔 UUID
                cash = liveCash,
            })
            setStatus(("状态: 🔴 已录动作 (%d)"):format(#recordings))
            log(("录制%s %s"):format(
                (name == "RequestTowerUpgrade") and "升级" or "卖塔", tostring(a1)))
            return oldNamecall(self, ...)
        end

        return oldNamecall(self, ...)
    end)

    getgenv().TD2_OLD_NAMECALL = oldNamecall
end

--==================== 回放 ====================
local function placeOnce(act)
    local uid = guid()
    local ts  = workspace:GetServerTimeNow()      -- ★ 必须紧贴发包，不能提前算
    local ok, ret = pcall(function()
        return RequestPlacement:InvokeServer(
            act.tower,
            Vector3.new(act.pos[1], act.pos[2], act.pos[3]),
            act.rot or 0,
            uid,
            ts)
    end)
    if ok and type(ret) == "string" then
        return true, ret
    end
    return false, ok and ret or tostring(ret)
end

local function runTowerAction(act, failedUid)
    if not act.uid then return false, "skip" end
    if failedUid[act.uid] then return false, "skip" end
    local target = uidMap[act.uid]
    if not target then return false, "skip" end       -- 该塔本局没放下，跳过后续操作
    local remote = (act.kind == "upgrade") and RequestTowerUpgrade or RequestTowerSell
    if not remote then return false, "no remote" end
    local ok, ret = pcall(function() return remote:InvokeServer(target) end)
    if not ok then return false, tostring(ret) end
    return true, ret
end

local function finishPlayback(msg)
    isPlaying = false
    playThread = nil
    if playToggle then pcall(function() playToggle:Set(false) end) end
    if msg then setStatus(msg) end
end

function startPlayback()
    if isRecording then
        setStatus("状态: 录制中不能回放")
        pcall(function() playToggle:Set(false) end)
        return
    end
    if isPlaying then return end
    if #recordings == 0 then
        setStatus("状态: 当前宏为空")
        pcall(function() playToggle:Set(false) end)
        return
    end
    if not (RequestPlacement and RequestTowerUpgrade and RequestTowerSell) then
        setStatus("状态: ❌ Remotes 缺失")
        pcall(function() playToggle:Set(false) end)
        return
    end

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

            -- 等钱：时间戳在真正发包时才取，这里的等待不影响校验
            if act.cash and act.cash > 0 then
                local deadline = os.clock() + CASH_WAIT_MAX
                while isPlaying and liveCash < act.cash and os.clock() < deadline do
                    setStatus(("🟡 等钱 %d/%d 需 %d 现 %d")
                        :format(i, #recordings, act.cash, liveCash))
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
                    if act.realUid then uidMap[act.realUid] = ret end   -- ★ 建立映射
                    setStatus(("🟢 放塔 %d/%d [%s]"):format(i, #recordings, act.tower))
                    log(("放塔 %d/%d %s -> %s"):format(i, #recordings, act.tower, ret))
                else
                    failN = failN + 1
                    if act.realUid then failedUid[act.realUid] = true end
                    setStatus(("🔴 放塔失败 %d/%d [%s]"):format(i, #recordings, act.tower))
                    log(("放塔失败 %d %s ret=%s"):format(i, act.tower, tostring(ret)))
                end
            else
                local ok, ret = runTowerAction(act, failedUid)
                if ok then
                    okN = okN + 1
                    setStatus(("🔵 %s %d/%d"):format(act.kind, i, #recordings))
                    log(("%s %d ok"):format(act.kind, i))
                elseif ret == "skip" then
                    skipN = skipN + 1
                    log(("%s 跳过 %d（目标塔未放置）"):format(act.kind, i))
                else
                    failN = failN + 1
                    log(("%s 失败 %d ret=%s"):format(act.kind, i, tostring(ret)))
                end
            end

            task.wait(ACTION_GAP)
        end

        finishPlayback(("状态: 🟢 结束 成功%d 失败%d 跳过%d"):format(okN, failN, skipN))
        log(("回放结束 ok=%d fail=%d skip=%d"):format(okN, failN, skipN))
    end)
end

function stopPlayback()
    if not isPlaying then return end
    isPlaying = false
    if playThread then
        pcall(function() task.cancel(playThread) end)
        playThread = nil
    end
    pcall(function() playToggle:Set(false) end)
    setStatus("状态: 🟡 已停止")
    log("回放已手动停止")
end

--==================== ReadyFrame 触发 + 自动化 ====================
local function getReadyFrame()
    if readyFrameRef and readyFrameRef.Parent and readyFrameRef:IsDescendantOf(playerGui) then
        return readyFrameRef
    end
    readyFrameRef = findByName(playerGui, "ReadyFrame")
    return readyFrameRef
end

task.spawn(function()
    local firedRound = false
    local lastVote, lastReady = 0, 0

    while true do
        task.wait(0.2)

        if isRecording then
            firedRound = false
        else
            local now = os.clock()

            -- 自动投票（1 秒最多一次，别刷太快）
            if autoVote and CastDifficultyVote and now - lastVote >= 1 then
                lastVote = now
                pcall(function() CastDifficultyVote:FireServer(selectedDifficulty) end)
            end

            local frame = getReadyFrame()
            local frameVisible = frame ~= nil and frame.Parent ~= nil and isVisibleDeep(frame)
            if frameVisible then
                -- 自动点准备
                if autoReady and now - lastReady >= 1 then
                    lastReady = now
                    local btn = frame:FindFirstChild("ReadyButton", true)
                    if btn and btn:IsA("TextButton") and isVisibleDeep(btn) then
                        local ok = pcall(function() firesignal(btn.MouseButton1Click) end)
                        if not ok and ReadyUp then
                            pcall(function() ReadyUp:FireServer() end)
                        end
                    end
                end

                -- 自动回放
                if autoPlayOnReady and not firedRound then
                    firedRound = true
                    setStatus(("状态: 🟢 检测到 ReadyFrame，%.1f 秒后回放"):format(replayDelay))
                    log("ReadyFrame 出现，准备回放")
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
setStatus("状态: 就绪（先选宏 → 录制 → 回放）")
log("脚本加载完成")

-- 方便手动调用/调试
getgenv().TD2Macro = {
    start = function() startPlayback() end,
    stop = function() stopPlayback() end,
    dump = function() return recordings end,
    cash = function() return liveCash end,
}
