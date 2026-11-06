--[[==========================================================
    随机塔防 · 录制宏 v2.0
    ------------------------------------------------------------
    本次改动（操作方式和基本逻辑完全不变）：
      1) Hook 安全化：只处理 Instance 上的 Remote 调用，且全程 pcall。
         旧版在 hook 第一行就 self.Name，遇到 CFrame / Vector3 这类
         没有 Name 的 __namecall 会直接抛错 —— 报错的是整个游戏的
         namecall，游戏自身脚本跟着中断，表现就是"开录制后放不了塔"。
      2) 参数用 table.pack 打包，保留 nil 位置；
         Instance 参数不再被解码成 nil（否则 unpack 会被截断，后面
         的参数全部丢失）。
      3) 塔的对应关系：录制用"放塔顺序队列"，回放用"放塔前后快照对比"，
         消除"塔还没生成就记 ID"的竞态。
      4) 录制时额外记录 Cost（这次动作实际扣了多少钱），
         这是极速模式能"踩着钱"放塔的前提。
      5) 新增【极速模式】：用 Cost 而不是 CashBefore 作为放行条件，
         钱一到就发；去掉固定的 0.05 秒间隔，改成逐帧轮询。
      6) 状态栏刷新节流（旧版等钱时每 0.01 秒刷一次 UI，本身就很卡）。
      7) 自动重播不再每 0.1 秒重置一次状态、也不再每 0.1 秒刷一次
         Replay / 投票，改成带冷却的触发。
==========================================================]]

-- ==========================================================
-- 0. 配置
-- ==========================================================
local CONFIG = {
    SAVE_FOLDER        = "TowerMacro_Data",  -- 存档目录
    TOWER_FOLDER       = "Towers",           -- 游戏里放塔的文件夹名
    REMOTES_FOLDER     = "Remotes",          -- 远程事件文件夹名
    CASH_POLL          = 0.1,                -- 找钱 UI 的轮询间隔
    LOOSE_SCAN_GAP     = 2.0,                -- 找不到 CashValue 时的兜底扫描间隔
    NORMAL_GAP         = 0.05,               -- 标准模式每个动作后的固定间隔
    CASH_WAIT_TIMEOUT  = 45,                 -- 等钱超时(秒)，超时跳过该动作
    TOWER_WAIT_TIMEOUT = 3,                  -- 等塔生成超时(秒)
    RETRY_MAX_PLACE    = 3,                  -- 放塔失败重试次数
    RETRY_MAX_UPGRADE  = 2,                  -- 升级失败重试次数
    RETRY_DELAY        = 0.12,               -- 重试间隔
    TURBO_MARGIN       = 0,                  -- 极速模式额外安全金额
    COST_WINDOW        = 0.45,               -- 录制时采样花费的窗口(秒)
    SPEND_CHECK_TIME   = 1.2,                -- 极速升级后确认扣钱的窗口(秒)
    STATUS_GAP         = 0.15,               -- 状态栏最小刷新间隔
    DEBUG              = false,              -- true 时打印 hook 错误
}

local RECORD_KEYWORDS = {"Place", "Upgrade", "Sell", "TowerAction"}

-- ==========================================================
-- 1. 服务 & 状态
-- ==========================================================
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

local SAVE_FOLDER = CONFIG.SAVE_FOLDER

local currentMacroName = nil
local allMacrosData = {}
local recordings = {}
local isRecording = false
local isPlaying = false
local turboMode = false
local playTask = nil

local MacroIDCounter = 0   -- 只给"放塔"编号
local ActionIDCounter = 0  -- 给升级/卖塔等动作编号
local recordPlaceQueue = {}
local instanceToMacroID = setmetatable({}, {__mode = "k"})

local isAutoReplayEnabled = false
local isAutoVoteEnabled = false
local isAutoStartEnabled = false
local isAutoEarlyStartEnabled = false
local selectedDifficulty = "Medium"

-- 前向声明（UI 在后面才创建）
local statusParagraph
local playToggle
local recordToggle
local autoToggles = {}

local function log(...)
    if CONFIG.DEBUG then warn("[Macro]", ...) end
end

-- ==========================================================
-- 2. 通用工具
-- ==========================================================
local lastStatusText, lastStatusTime = "", 0
local function setStatus(text, force)
    local now = os.clock()
    if not force then
        if text == lastStatusText then return end
        if now - lastStatusTime < CONFIG.STATUS_GAP then return end
    end
    lastStatusText, lastStatusTime = text, now
    if statusParagraph then
        pcall(function() statusParagraph:SetDesc(text) end)
    end
end

-- 把参数里的特殊类型转成可 JSON 的普通表
local function sanitizeValue(v, depth)
    depth = depth or 0
    if v == nil then return {__type = "Nil"} end

    local t = typeof(v)
    if t == "number" or t == "string" or t == "boolean" then
        return v
    elseif t == "CFrame" then
        return {__type = "CFrame", c = {v:GetComponents()}}
    elseif t == "Vector3" then
        return {__type = "Vector3", p = {v.X, v.Y, v.Z}}
    elseif t == "Vector2" then
        return {__type = "Vector2", p = {v.X, v.Y}}
    elseif t == "Color3" then
        return {__type = "Color3", c = {v.R, v.G, v.B}}
    elseif t == "Instance" then
        return {__type = "Instance", Class = v.ClassName, Name = v.Name}
    elseif t == "EnumItem" then
        return {__type = "EnumItem", Enum = tostring(v.EnumType), Name = v.Name}
    elseif t == "table" then
        if depth >= 8 then return {__type = "Nil"} end
        local o = {}
        for k, val in pairs(v) do
            if type(k) == "number" or type(k) == "string" then
                o[k] = sanitizeValue(val, depth + 1)
            end
        end
        return o
    end
    return {__type = "Raw", Value = tostring(v)}
end

local function decodeValue(v)
    if type(v) ~= "table" then return v end

    local t = v.__type
    if t == nil then
        local o = {}
        for k, val in pairs(v) do o[k] = decodeValue(val) end
        return o
    elseif t == "Nil" then
        return nil
    elseif t == "CFrame" then
        if type(v.c) ~= "table" then return nil end
        return CFrame.new(table.unpack(v.c))
    elseif t == "Vector3" then
        if type(v.p) ~= "table" then return nil end
        return Vector3.new(v.p[1], v.p[2], v.p[3])
    elseif t == "Vector2" then
        if type(v.p) ~= "table" then return nil end
        return Vector2.new(v.p[1], v.p[2])
    elseif t == "Color3" then
        if type(v.c) ~= "table" then return nil end
        return Color3.new(v.c[1], v.c[2], v.c[3])
    elseif t == "EnumItem" then
        local ok, item = pcall(function() return Enum[v.Enum][v.Name] end)
        if ok then return item end
        return nil
    elseif t == "Raw" then
        return v.Value
    end
    return nil
end

-- 只把"第一个 Instance 占位"还原成当前这局的塔，其余 Instance 保持 nil
local function decodeArgs(safe, tower)
    if type(safe) ~= "table" then return {}, 0 end
    local n = safe.n or #safe
    local out = {}
    local towerUsed = false

    for i = 1, n do
        local v = safe[i]
        if type(v) == "table" and v.__type == "Instance" and not towerUsed then
            out[i] = tower
            towerUsed = true
        else
            out[i] = decodeValue(v)
        end
    end
    return out, n
end

-- ==========================================================
-- 3. 现金读取（事件驱动，钱一变立刻更新）
-- ==========================================================
local Cash = {value = 0, source = nil, conn = nil}

local CASH_WORDS = {"cash", "money", "coin", "gold", "credit"}

local function isCashName(name)
    local n = string.lower(tostring(name or ""))
    for _, k in ipairs(CASH_WORDS) do
        if string.find(n, k, 1, true) then return true end
    end
    return false
end

local function parseCashText(text)
    if type(text) ~= "string" then return nil end
    local s = string.gsub(text, "[%s%$,]", "")
    local numStr, suffix = string.match(s, "^([%d]+%.?[%d]*)([KkMmBbTt]?)$")
    if not numStr or numStr == "" then return nil end
    local n = tonumber(numStr)
    if not n then return nil end
    suffix = string.upper(suffix or "")
    if suffix == "K" then n = n * 1e3
    elseif suffix == "M" then n = n * 1e6
    elseif suffix == "B" then n = n * 1e9
    elseif suffix == "T" then n = n * 1e12 end
    return math.floor(n + 0.5)
end

local function bindCashSource(obj)
    if Cash.source == obj then return end
    if Cash.conn then
        pcall(function() Cash.conn:Disconnect() end)
        Cash.conn = nil
    end
    Cash.source = obj

    if obj:IsA("TextLabel") then
        local v = parseCashText(obj.Text)
        if v then Cash.value = v end
        Cash.conn = obj:GetPropertyChangedSignal("Text"):Connect(function()
            local n = parseCashText(obj.Text)
            if n then Cash.value = n end
        end)
    else
        Cash.value = obj.Value
        Cash.conn = obj:GetPropertyChangedSignal("Value"):Connect(function()
            Cash.value = obj.Value
        end)
    end
end

local function tryBindCash()
    local src = Cash.source
    if src and src.Parent then return true end

    -- 首选：原版路径 GameUI.CashBar.CashValue
    local ui = player.PlayerGui:FindFirstChild("GameUI")
    local bar = ui and ui:FindFirstChild("CashBar")
    local val = bar and bar:FindFirstChild("CashValue")
    if val and val:IsA("TextLabel") then
        bindCashSource(val)
        return true
    end

    -- 次选：leaderstats 里的数值
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        for _, ch in ipairs(ls:GetChildren()) do
            if (ch:IsA("IntValue") or ch:IsA("NumberValue")) and isCashName(ch.Name) then
                bindCashSource(ch)
                return true
            end
        end
    end
    return false
end

local function tryBindLoose()
    for _, d in ipairs(player.PlayerGui:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible and isCashName(d.Name) then
            local n = parseCashText(d.Text)
            if n then
                bindCashSource(d)
                return true
            end
        end
    end
    return false
end

task.spawn(function()
    local nextLoose = 0
    while true do
        local ok, bound = pcall(tryBindCash)
        if not (ok and bound) and os.clock() >= nextLoose then
            nextLoose = os.clock() + CONFIG.LOOSE_SCAN_GAP
            pcall(tryBindLoose)
        end
        -- 兜底：即使信号丢了也同步一次
        local src = Cash.source
        if src and src.Parent then
            if src:IsA("TextLabel") then
                local n = parseCashText(src.Text)
                if n then Cash.value = n end
            else
                Cash.value = src.Value
            end
        end
        task.wait(CONFIG.CASH_POLL)
    end
end)

-- ==========================================================
-- 4. 宏存档
-- ==========================================================
local function loadAllMacros()
    local names = {"新建宏..."}
    pcall(function()
        if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
        for _, file in ipairs(listfiles(SAVE_FOLDER)) do
            local name = string.match(file, "([^/\\]+)%.json$")
            if name then
                table.insert(names, name)
                local ok, decoded = pcall(function()
                    return HttpService:JSONDecode(readfile(file))
                end)
                if ok and type(decoded) == "table" then
                    allMacrosData[name] = decoded
                end
            end
        end
    end)
    return names
end

local function saveMacro(name, data)
    if not name then return end
    pcall(function()
        writefile(SAVE_FOLDER .. "/" .. name .. ".json", HttpService:JSONEncode(data))
    end)
end

-- ==========================================================
-- 5. Remote / 塔文件夹 工具
-- ==========================================================
local remoteCache = {}

local function getRemote(name)
    if type(name) ~= "string" then return nil end
    local cached = remoteCache[name]
    if cached and cached.Parent then return cached end

    local remotes = ReplicatedStorage:FindFirstChild(CONFIG.REMOTES_FOLDER)
    local r = remotes and remotes:FindFirstChild(name)
    if not r then
        r = ReplicatedStorage:FindFirstChild(name, true)
    end
    if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then
        remoteCache[name] = r
        return r
    end
    return nil
end

local function getTowersFolder()
    return workspace:FindFirstChild(CONFIG.TOWER_FOLDER)
end

local function attachTowerAdded(fn)
    local folder = getTowersFolder()
    if folder then
        return folder.ChildAdded:Connect(fn)
    end
    return workspace.DescendantAdded:Connect(function(obj)
        local p = obj.Parent
        if p and p.Name == CONFIG.TOWER_FOLDER then fn(obj) end
    end)
end

local function snapshotTowers(folder)
    local set = {}
    for _, c in ipairs(folder:GetChildren()) do set[c] = true end
    return set
end

local function waitNewTower(folder, beforeSet, timeout)
    local t0 = os.clock()
    while isPlaying and not isRecording do
        for _, c in ipairs(folder:GetChildren()) do
            if not beforeSet[c] then return c end
        end
        if os.clock() - t0 > timeout then return nil end
        RunService.Heartbeat:Wait()
    end
    return nil
end

local function unqueuePending(list, id)
    for k = #list, 1, -1 do
        if list[k] == id then
            table.remove(list, k)
            return
        end
    end
end

-- ==========================================================
-- 6. 回放引擎（标准 / 极速）
-- ==========================================================
local function getRequiredCash(act)
    local before = act.CashBefore or 0
    if turboMode then
        local cost = act.Cost
        if type(cost) == "number" and cost > 0 then
            -- 极速：只要求"这次动作本身的花费"，不再等录制时的余额
            if cost < before then before = cost end
            return before + CONFIG.TURBO_MARGIN
        end
    end
    return before
end

local function waitForCash(need, idx, total)
    if need <= 0 then return true end
    if Cash.value >= need then return true end

    local t0 = os.clock()
    local nextUi = 0
    while isPlaying and not isRecording do
        if Cash.value >= need then return true end
        if os.clock() - t0 > CONFIG.CASH_WAIT_TIMEOUT then
            return false
        end
        local now = os.clock()
        if now >= nextUi then
            nextUi = now + 0.25
            setStatus(string.format("状态: 🟡 等钱 [%d/%d] 需 %d / 有 %d",
                idx, total, math.floor(need), math.floor(Cash.value)))
        end
        RunService.Heartbeat:Wait()
    end
    return false
end

local function waitTowerFor(map, id, timeout)
    local t0 = os.clock()
    while isPlaying and not isRecording do
        local t = map[id]
        if t and t.Parent then return t end
        if os.clock() - t0 > timeout then return nil end
        RunService.Heartbeat:Wait()
    end
    return nil
end

-- 确认这笔钱真的扣了（用于极速模式的升级校验）
local function waitCashSpend(before, amount, timeout)
    local t0 = os.clock()
    local minC = before
    while os.clock() - t0 < timeout do
        if Cash.value < minC then minC = Cash.value end
        if before - minC >= amount then return true end
        RunService.Heartbeat:Wait()
    end
    return false
end

local function stopPlayback()
    if not isPlaying then return end
    isPlaying = false

    if playTask then
        local t = playTask
        playTask = nil
        -- 自己停自己时不能 cancel，否则会报错
        if t ~= coroutine.running() then
            pcall(task.cancel, t)
        end
    end
    if playToggle then
        pcall(function() playToggle:Set(false) end)
    end
    setStatus("状态: 🟡 回放结束 / 已停止", true)
end

local function runAction(act, idx, total, ctx)
    local playMap = ctx.playMap
    local pendingPlaces = ctx.pendingPlaces

    local remoteName = act.RemoteName
    if not remoteName then
        if act.Type == "Place" then
            remoteName = "PlaceTower"
        else
            return "skip"
        end
    end

    local remote = getRemote(remoteName)
    if not remote then
        setStatus(string.format("状态: 🔴 [%d/%d] 找不到远程 %s", idx, total, tostring(remoteName)))
        return "skip"
    end

    local isPlace = (act.Type == "Place") or string.find(remoteName, "Place", 1, true) ~= nil
    local isSell = string.find(remoteName, "Sell", 1, true) ~= nil
    local isUpgrade = string.find(remoteName, "Upgrade", 1, true) ~= nil

    -- 目标塔编号：新格式用 TargetMacroID，旧格式退回 MacroID
    local targetID = act.TargetMacroID
    if targetID == nil and act.RemoteClass == nil then
        targetID = act.MacroID
    end

    -- 动作类先确认目标塔已经在场
    local targetTower = nil
    if not isPlace then
        if targetID == nil then
            setStatus(string.format("状态: 🟠 [%d/%d] 动作缺少目标塔，跳过", idx, total))
            return "skip"
        end
        targetTower = waitTowerFor(playMap, targetID, CONFIG.TOWER_WAIT_TIMEOUT * 2)
        if not targetTower then
            setStatus(string.format("状态: 🟠 [%d/%d] 目标塔不存在，跳过", idx, total))
            return "skip"
        end
    end

    local need = 0
    if not isSell then
        need = getRequiredCash(act)
    end

    local maxAttempt = 1
    if isPlace then
        maxAttempt = CONFIG.RETRY_MAX_PLACE
    elseif isUpgrade then
        maxAttempt = CONFIG.RETRY_MAX_UPGRADE
    end

    for _ = 1, maxAttempt do
        if not isPlaying or isRecording then return "stop" end

        if not waitForCash(need, idx, total) then
            if not isPlaying or isRecording then return "stop" end
            setStatus(string.format("状态: 🟠 [%d/%d] 等钱超时，跳过", idx, total))
            return "skip"
        end

        local folder = isPlace and getTowersFolder() or nil
        local beforeSet = folder and snapshotTowers(folder) or nil
        if isPlace and not folder then
            table.insert(pendingPlaces, act.MacroID)
        end

        local args, n = decodeArgs(act.SafeArgs, targetTower)
        local cashBeforeCall = Cash.value

        local callOK, callErr = pcall(function()
            if remote:IsA("RemoteFunction") then
                return remote:InvokeServer(table.unpack(args, 1, n))
            else
                remote:FireServer(table.unpack(args, 1, n))
            end
        end)

        if not callOK then
            if isPlace and not folder then unqueuePending(pendingPlaces, act.MacroID) end
            setStatus(string.format("状态: 🔴 [%d/%d] 调用出错: %s", idx, total, tostring(callErr)))
            task.wait(CONFIG.RETRY_DELAY)

        elseif isPlace then
            local tower
            if folder then
                tower = waitNewTower(folder, beforeSet, CONFIG.TOWER_WAIT_TIMEOUT)
                if tower then playMap[act.MacroID] = tower end
            else
                tower = waitTowerFor(playMap, act.MacroID, CONFIG.TOWER_WAIT_TIMEOUT)
                if not tower then unqueuePending(pendingPlaces, act.MacroID) end
            end

            if tower then
                setStatus(string.format("状态: 🟢 [%d/%d] 放置成功", idx, total))
                return "ok"
            end
            setStatus(string.format("状态: 🟠 [%d/%d] 塔未生成，重试", idx, total))
            task.wait(CONFIG.RETRY_DELAY)

        elseif isUpgrade and turboMode and type(act.Cost) == "number" and act.Cost > 0 then
            -- 极速是踩着余额发的，这里确认钱确实扣了，避免服务器拒单后整段错位
            if waitCashSpend(cashBeforeCall, act.Cost * 0.5, CONFIG.SPEND_CHECK_TIME) then
                return "ok"
            end
            setStatus(string.format("状态: 🟠 [%d/%d] 升级可能失败，重试", idx, total))
            task.wait(CONFIG.RETRY_DELAY)

        else
            return "ok"
        end
    end

    setStatus(string.format("状态: 🟠 [%d/%d] 重试用尽，继续下一个", idx, total))
    return "ok"
end

local function startPlayback()
    if isRecording or isPlaying or #recordings == 0 then return end

    isPlaying = true
    if playToggle then
        pcall(function() playToggle:Set(true) end)
    end
    setStatus("状态: 🟢 回放开始（" .. (turboMode and "极速" or "标准") .. "）", true)

    playTask = task.spawn(function()
        local ctx = {
            playMap = {},
            pendingPlaces = {},
        }

        local conn = attachTowerAdded(function(obj)
            local id = table.remove(ctx.pendingPlaces, 1)
            if id then ctx.playMap[id] = obj end
        end)

        local total = #recordings
        for idx = 1, total do
            if not isPlaying or isRecording then break end
            local act = recordings[idx]
            if not act then break end

            if runAction(act, idx, total, ctx) == "stop" then break end

            if not turboMode and isPlaying then
                task.wait(CONFIG.NORMAL_GAP)
            end
        end

        if conn then pcall(function() conn:Disconnect() end) end
        if isPlaying then stopPlayback() end
    end)
end

-- ==========================================================
-- 7. 录制 Hook（安全版）
-- ==========================================================
local costSamplerBusy = false

local function scheduleCostSample(rec, baseCash)
    if costSamplerBusy then return end
    costSamplerBusy = true
    task.spawn(function()
        local t0 = os.clock()
        local minCash = baseCash
        while os.clock() - t0 < CONFIG.COST_WINDOW do
            if Cash.value < minCash then minCash = Cash.value end
            task.wait()
        end
        costSamplerBusy = false
        local cost = baseCash - minCash
        if cost > 0 then
            rec.Cost = cost
            rec.CashAfter = minCash
        end
    end)
end

local function isRecordable(name)
    for _, kw in ipairs(RECORD_KEYWORDS) do
        if string.find(name, kw, 1, true) then return true end
    end
    return false
end

local function handleRecordCall(self, method, ...)
    if typeof(self) ~= "Instance" then return end
    if not (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")) then return end

    local name = self.Name
    if not name or not isRecordable(name) then return end

    local packed = table.pack(...)
    local cashBefore = Cash.value
    local isPlace = string.find(name, "Place", 1, true) ~= nil
    local isSell = string.find(name, "Sell", 1, true) ~= nil

    -- 注意：这里必须是纯数组（1..n 连续，不能混入 n 字段），
    -- 否则 JSONEncode 会把它编成对象，读回来 key 变成字符串 "1"，
    -- 参数就全丢了。nil 已经被 sanitize 成 {__type="Nil"}，不会出现空洞。
    local safeArgs = {}
    for i = 1, packed.n do
        safeArgs[i] = sanitizeValue(packed[i])
    end

    local rec
    if isPlace then
        MacroIDCounter = MacroIDCounter + 1
        rec = {
            MacroID = MacroIDCounter,
            Type = "Place",
            RemoteName = name,
            RemoteClass = self.ClassName,
            CashBefore = cashBefore,
            SafeArgs = safeArgs,
        }
        table.insert(recordPlaceQueue, MacroIDCounter)
    else
        ActionIDCounter = ActionIDCounter + 1
        local targetID = nil
        if typeof(packed[1]) == "Instance" then
            targetID = instanceToMacroID[packed[1]]
        end
        rec = {
            MacroID = ActionIDCounter,
            TargetMacroID = targetID,
            Type = "Action",
            RemoteName = name,
            RemoteClass = self.ClassName,
            CashBefore = cashBefore,
            SafeArgs = safeArgs,
        }
    end

    table.insert(recordings, rec)

    if not isSell then
        scheduleCostSample(rec, cashBefore)
    end

    local count = #recordings
    task.spawn(function()
        setStatus("状态: 🔴 已录制动作 (" .. count .. ")")
    end)
end

-- 注意：这里是整个旧脚本"开录制就放不了塔"的根因。
-- 旧代码在外层无条件 self.Name，CFrame / Vector3 等没有 Name，
-- 抛错后 oldRemote 没被调用，游戏自己的逻辑就断了。
local function tryRecord(self, ...)
    local method = getnamecallmethod()
    if method ~= "FireServer" and method ~= "InvokeServer" then return end
    handleRecordCall(self, method, ...)
end

local oldNamecall
local hookInstalled = pcall(function()
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if isRecording then
            local ok, err = pcall(tryRecord, self, ...)
            if not ok then log("record hook:", err) end
        end
        return oldNamecall(self, ...)
    end)
end)

if not hookInstalled or not oldNamecall then
    warn("[Macro] hookmetamethod 失败，录制功能不可用")
end

-- 录制：塔生成后按"放塔顺序队列"配对
local recordTowerConn
local function attachRecordTowerListener()
    if recordTowerConn then
        pcall(function() recordTowerConn:Disconnect() end)
        recordTowerConn = nil
    end

    local folder = getTowersFolder()
    if folder then
        recordTowerConn = folder.ChildAdded:Connect(function(obj)
            if not isRecording then return end
            local id = table.remove(recordPlaceQueue, 1)
            if id then instanceToMacroID[obj] = id end
        end)
    else
        recordTowerConn = workspace.DescendantAdded:Connect(function(obj)
            if not isRecording then return end
            local p = obj.Parent
            if p and p.Name == CONFIG.TOWER_FOLDER then
                local id = table.remove(recordPlaceQueue, 1)
                if id then instanceToMacroID[obj] = id end
            end
        end)
    end
end
attachRecordTowerListener()

-- ==========================================================
-- 8. UI
-- ==========================================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Window = WindUI:CreateWindow({
    Title = "随机塔防1.0",
    Author = "WindUI 全兼容版",
    Icon = "shield",
    Background = "rbxassetid://79176013131678",
    BackgroundImageTransparency = 0.3,
    Transparent = true,
})

local MainTab = Window:Tab({Title = "宏控制", Icon = "settings"})
statusParagraph = MainTab:Paragraph({Title = "状态监控", Desc = "状态: 等待操作..."})

MainTab:Section({Title = "宏管理"})
local macroDropdown = MainTab:Dropdown({
    Title = "选择已有宏",
    Values = loadAllMacros(),
    Value = "新建宏...",
    Callback = function(Option)
        if Option == "新建宏..." then
            currentMacroName = nil
            recordings = {}
            setStatus("状态: 未选择宏", true)
        else
            currentMacroName = Option
            recordings = allMacrosData[Option] or {}
            setStatus("状态: 已加载 [" .. Option .. "]，动作数: " .. #recordings, true)
        end
    end,
})

MainTab:Input({
    Title = "新建宏名称",
    Placeholder = "输入名称后回车创建",
    Callback = function(Text)
        if Text == "" or allMacrosData[Text] then return end
        allMacrosData[Text] = {}
        saveMacro(Text, {})
        currentMacroName = Text
        recordings = {}
        setStatus("状态: 成功新建 [" .. Text .. "]", true)
        pcall(function()
            macroDropdown:Refresh(loadAllMacros())
            macroDropdown:Set(Text)
        end)
    end,
})

MainTab:Section({Title = "录制与回放"})

recordToggle = MainTab:Toggle({
    Title = "开启录制",
    Value = false,
    Callback = function(Value)
        if Value then
            if isPlaying then stopPlayback() end
            isAutoVoteEnabled = false
            isAutoReplayEnabled = false
            isAutoStartEnabled = false
            isAutoEarlyStartEnabled = false
            -- 同步关掉 UI，避免"开关还亮着但实际没生效"
            for _, t in ipairs(autoToggles) do
                pcall(function() t:Set(false) end)
            end

            if not currentMacroName or currentMacroName == "新建宏..." then
                recordToggle:Set(false)
                return
            end

            isRecording = true
            recordings = {}
            MacroIDCounter = 0
            ActionIDCounter = 0
            recordPlaceQueue = {}
            for k in pairs(instanceToMacroID) do instanceToMacroID[k] = nil end
            attachRecordTowerListener()
            setStatus("状态: 🔴 正在录制中...", true)
        else
            isRecording = false
            setStatus("状态: 保存成功，共 " .. #recordings .. " 个动作", true)
            if currentMacroName then
                allMacrosData[currentMacroName] = recordings
                saveMacro(currentMacroName, recordings)
            end
        end
    end,
})

playToggle = MainTab:Toggle({
    Title = "开启回放 (单次跑完自动关闭)",
    Value = false,
    Callback = function(Value)
        if Value then
            if isRecording then
                playToggle:Set(false)
                return
            end
            if #recordings == 0 then
                playToggle:Set(false)
                return
            end
            startPlayback()
        else
            stopPlayback()
        end
    end,
})

MainTab:Toggle({
    Title = "极速模式 (钱够立刻执行，不留间隔)",
    Value = false,
    Callback = function(Value)
        turboMode = Value
        setStatus("状态: 已切换为 " .. (Value and "极速" or "标准") .. " 模式", true)
    end,
})

-- ==========================================================
-- 9. 自动化
-- ==========================================================
local AutoTab = Window:Tab({Title = "自动化", Icon = "zap"})
AutoTab:Section({Title = "挂机功能"})

local function addAutoToggle(cfg)
    local t = AutoTab:Toggle(cfg)
    table.insert(autoToggles, t)
    return t
end

addAutoToggle({
    Title = "自动重播",
    Value = false,
    Callback = function(v)
        if isRecording and v then return end
        isAutoReplayEnabled = v
    end,
})

addAutoToggle({
    Title = "出现【EARLY START】时自动回放",
    Value = false,
    Callback = function(v)
        if isRecording and v then return end
        isAutoStartEnabled = v
    end,
})

addAutoToggle({
    Title = "自动点击提前开始",
    Value = false,
    Callback = function(v)
        if isRecording and v then return end
        isAutoEarlyStartEnabled = v
    end,
})

addAutoToggle({
    Title = "自动投票",
    Value = false,
    Callback = function(v)
        if isRecording and v then return end
        isAutoVoteEnabled = v
    end,
})

AutoTab:Dropdown({
    Title = "投票难度",
    Values = {"Easy", "Medium", "Hard", "Insane"},
    Value = "Medium",
    Callback = function(o) selectedDifficulty = o end,
})

-- ==========================================================
-- 10. 自动化后台
-- ==========================================================
task.spawn(function()
    local remotes
    repeat
        remotes = ReplicatedStorage:FindFirstChild(CONFIG.REMOTES_FOLDER)
        if not remotes then task.wait(1) end
    until remotes

    local VoteRemote = remotes:WaitForChild("VoteDifficulty", 10)
    local EndChoiceRemote = remotes:WaitForChild("EndChoice", 10)
    local StartWaveRemote = remotes:WaitForChild("StartWave", 10)

    local nextVote, nextReplay, nextStart, nextEarly = 0, 0, 0, 0
    local earlyArmed = true
    local scanAccum = 0

    while task.wait(0.1) do
        if not isRecording then
            local now = os.clock()

            if isAutoVoteEnabled and VoteRemote and now >= nextVote then
                nextVote = now + 1
                pcall(function() VoteRemote:FireServer(selectedDifficulty) end)
            end

            if isAutoReplayEnabled and EndChoiceRemote and now >= nextReplay then
                nextReplay = now + 2
                pcall(function() EndChoiceRemote:InvokeServer("Replay") end)
            end

            if isAutoEarlyStartEnabled and StartWaveRemote and now >= nextStart then
                nextStart = now + 0.5
                pcall(function() StartWaveRemote:FireServer() end)
            end

            if isAutoStartEnabled and not isPlaying then
                scanAccum = scanAccum + 0.1
                if scanAccum >= 0.25 then
                    scanAccum = 0
                    local found = false
                    for _, gui in ipairs(player.PlayerGui:GetDescendants()) do
                        if (gui:IsA("TextLabel") or gui:IsA("TextButton"))
                            and gui.Visible
                            and string.find(string.upper(gui.Text), "EARLY START", 1, true) then
                            found = true
                            break
                        end
                    end

                    if found then
                        if earlyArmed and now >= nextEarly then
                            earlyArmed = false
                            nextEarly = now + 8
                            setStatus("状态: 🟢 发现 [EARLY START]，3.2 秒后回放", true)
                            task.spawn(function()
                                task.wait(3.2)
                                if not isRecording and not isPlaying then
                                    startPlayback()
                                end
                            end)
                        end
                    else
                        earlyArmed = true
                    end
                end
            end
        end
    end
end)
