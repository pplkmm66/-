--==============================================================
-- 随机塔防 宏录制/回放 忍者版1.8 (智能反宏秒答版)
--==============================================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local Workspace   = game:GetService("Workspace")
local player      = Players.LocalPlayer
local playerGui   = player:WaitForChild("PlayerGui")

local SAVE_FOLDER  = "TD2_Macro_Data"
local PROFILE_DIR  = SAVE_FOLDER .. "/profiles"
local CONFIG_FILE  = SAVE_FOLDER .. "/config.json"

pcall(function()
    if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
    if not isfolder(PROFILE_DIR) then makefolder(PROFILE_DIR) end
end)

--==================== Remotes ====================
local Remotes             = RS:WaitForChild("Remotes", 30)
local Functions           = Remotes and Remotes:WaitForChild("Functions", 30)
local Events              = Remotes and Remotes:WaitForChild("Events", 30)
local RequestPlacement    = Functions and Functions:WaitForChild("RequestPlacement", 30)
local RequestTowerUpgrade = Functions and Functions:WaitForChild("RequestTowerUpgrade", 30)
local RequestTowerSell    = Functions and Functions:WaitForChild("RequestTowerSell", 30)
local RequestTowerAbility = Functions and Functions:WaitForChild("RequestTowerAbility", 30)
local CastDifficultyVote  = Events and Events:WaitForChild("CastDifficultyVote", 30)
local ReadyUp             = Events and Events:WaitForChild("ReadyUp", 30)
local ResultsAction       = Events and Events:WaitForChild("ResultsAction", 30)
local SpeedToggle         = Events and Events:WaitForChild("SpeedToggle", 30)
local UpdateAbilityAutoUse= Events and Events:WaitForChild("UpdateAbilityAutoUse", 30)
local AntiMacro           = Events:WaitForChild("AntiMacro", 30) 

--==================== 配置 ====================
local DEFAULT_CFG = {
    autoVote         = false,
    autoReady        = false,
    autoPlayOnReady  = false,
    autoRejoin       = false, 
    autoPickItem     = false,
    autoSpeed        = false,
    gameSpeed        = "1",
    replayDelay      = 3,
    selectedDifficulty = "Medium",
    verbose          = true,
    macroName        = "新建宏...",
    profile          = "default",
}

local cfg = {}
for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end

local function readJson(path)
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
    if ok and type(data) == "table" then return data end
    return nil
end

local function writeJson(path, data)
    pcall(function() writefile(path, HttpService:JSONEncode(data)) end)
end

do
    local saved = readJson(CONFIG_FILE)
    if saved then
        for k in pairs(DEFAULT_CFG) do
            if saved[k] ~= nil then cfg[k] = saved[k] end
        end
    end
end

local function saveCfg() writeJson(CONFIG_FILE, cfg) end

--==================== 运行时状态 ====================
local currentMacroName = nil
local recordings       = {}
local allMacrosData    = {}
local isRecording      = false
local isPlaying        = false
local playThread       = nil
local liveCash         = 0
local uidMap           = {}
local dbLines          = {}
local dbgParagraph     = nil
local lastDbRefresh    = 0

local recordQueue = {}

local PLACE_RETRY   = 3
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

local function encodeArgs(...)
    local n = select("#", ...)
    local out = { n = n }
    for i = 1, n do
        local v = select(i, ...)
        local t = typeof(v)
        if t == "Vector3" or t == "vector" then
            out[i] = { __v3 = { v.X, v.Y, v.Z } }
        elseif t == "string" or t == "number" or t == "boolean" then
            out[i] = v
        end
    end
    return out
end

local function decodeArgs(packed)
    local n = (packed and packed.n) or 0
    local out = {}
    for i = 1, n do
        local v = packed[i]
        if type(v) == "table" and v.__v3 then
            out[i] = Vector3.new(v.__v3[1], v.__v3[2], v.__v3[3])
        else
            out[i] = v
        end
    end
    return out, n
end

local function findTowerModelByUuid(uuid)
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Model") then
            if d.Name == uuid then return d end
            local ok, hasAttr = pcall(function() return d:GetAttribute("UUID") == uuid end)
            if ok and hasAttr then return d end
        end
    end
    return nil
end

local function log(msg)
    local line = ("[%s] %s"):format(os.date("%H:%M:%S"), msg)
    table.insert(dbLines, line)
    while #dbLines > 14 do table.remove(dbLines, 1) end
    if cfg.verbose then print(line) end
    if dbgParagraph and os.clock() - lastDbRefresh > 0.5 then
        lastDbRefresh = os.clock()
        pcall(function() dbgParagraph:SetDesc(table.concat(dbLines, "\n")) end)
    end
end

--==================== 宏存档 ====================
local function loadAllMacros()
    local names = { "新建宏..." }
    pcall(function()
        for _, file in ipairs(listfiles(SAVE_FOLDER)) do
            local name = file:match("([^/\\]+)%.json$")
            if name and name ~= "config" then
                table.insert(names, name)
                local data = readJson(file)
                if data and type(data) == "table" and data[1] ~= nil then
                    allMacrosData[name] = data
                end
            end
        end
    end)
    return names
end

local function saveCurrentMacro()
    if not currentMacroName or currentMacroName == "新建宏..." then return end
    allMacrosData[currentMacroName] = recordings
    writeJson(SAVE_FOLDER .. "/" .. currentMacroName .. ".json", recordings)
end

--==================== Profile ====================
local profileDirty = false
local pendingProfileName = nil
local profileStateParagraph = nil

local function listProfiles()
    local list = { "default" }
    pcall(function()
        for _, f in ipairs(listfiles(PROFILE_DIR)) do
            local n = f:match("([^/\\]+)%.json$")
            if n and n ~= "default" then table.insert(list, n) end
        end
    end)
    return list
end

local function saveProfile(name)
    if not name or name == "" then return false end
    cfg.profile = name
    writeJson(PROFILE_DIR .. "/" .. name .. ".json", cfg)
    saveCfg()
    profileDirty = false
    return true
end

local function loadProfile(name)
    if not name or name == "" then return false end
    local data = readJson(PROFILE_DIR .. "/" .. name .. ".json")
    if not data then return false end
    for k in pairs(DEFAULT_CFG) do
        if data[k] ~= nil then cfg[k] = data[k] end
    end
    cfg.profile = name
    saveCfg()
    profileDirty = false
    return true
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
    Title    = "忍者版1.8",
    Author   = "Ninja Fix",
    Icon     = "shield",
    Background = "rbxassetid://125060338684123",
    BackgroundImageTransparency = 0.3,
    Transparent = true,
})

local MainTab = Window:Tab({ Title = "宏控制", Icon = "settings" })
local AutoTab = Window:Tab({ Title = "自动化", Icon = "zap" })
local ConfTab = Window:Tab({ Title = "配置档案", Icon = "save" })
local DbgTab  = Window:Tab({ Title = "调试", Icon = "bug" })

local statusParagraph = MainTab:Paragraph({ Title = "状态", Desc = "状态: 等待操作..." })
local function setStatus(text)
    pcall(function() statusParagraph:SetDesc(text) end)
end

dbgParagraph = DbgTab:Paragraph({ Title = "运行日志", Desc = "-" })

local suppressDirty = false
local function refreshProfileState()
    if not profileStateParagraph then return end
    local txt = profileDirty
        and ("Profile: %s\n* Unsaved changes"):format(cfg.profile or "default")
        or  ("Profile: %s\nAll changes saved"):format(cfg.profile or "default")
    pcall(function() profileStateParagraph:SetDesc(txt) end)
end

local function markDirty()
    if suppressDirty then return end
    profileDirty = true
    refreshProfileState()
end

--==================== 宏管理 ====================
MainTab:Section({ Title = "宏管理" })

local macroList = loadAllMacros()
local startMacro = cfg.macroName
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
        cfg.macroName = opt
        saveCfg()
        markDirty()
    end,
})

if startMacro ~= "新建宏..." then
    currentMacroName = startMacro
    recordings = allMacrosData[startMacro] or {}
end

MainTab:Input({
    Title = "新建宏名称",
    Placeholder = "输入名称后回车",
    Callback = function(text)
        if text == "" or allMacrosData[text] then return end
        allMacrosData[text] = {}
        recordings = {}
        writeJson(SAVE_FOLDER .. "/" .. text .. ".json", {})
        currentMacroName = text
        cfg.macroName = text
        saveCfg()
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
            if not currentMacroName or currentMacroName == "新建宏..." then
                pcall(function() recordToggle:Set(false) end)
                setStatus("状态: 请先选择或新建宏")
                return
            end
            recordings = {}
            recordQueue = {}
            uidMap = {}
            isRecording = true
            setStatus("状态: 🔴 录制中...")
            log("开始录制 [" .. currentMacroName .. "]")
        else
            isRecording = false
            task.wait(0.2)
            for _, act in ipairs(recordQueue) do
                recordings[#recordings + 1] = act
            end
            recordQueue = {}
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

MainTab:Button({ Title = "强制停止回放", Callback = function() stopPlayback() end })

--==================== 自动化 ====================
AutoTab:Section({ Title = "挂机" })

local uiToggles   = {}
local uiDropdowns = {}
local uiInputs    = {}

uiToggles.autoVote = AutoTab:Toggle({
    Title = "自动投票",
    Value = cfg.autoVote,
    Callback = function(v) cfg.autoVote = v; saveCfg(); markDirty() end,
})

uiDropdowns.selectedDifficulty = AutoTab:Dropdown({
    Title = "投票难度",
    Values = { "Easy", "Medium", "Hard", "Nightmare" },
    Value = cfg.selectedDifficulty,
    Callback = function(o) cfg.selectedDifficulty = o; saveCfg(); markDirty() end,
})

uiToggles.autoReady = AutoTab:Toggle({
    Title = "自动点准备 (ReadyUp)",
    Value = cfg.autoReady,
    Callback = function(v) cfg.autoReady = v; saveCfg(); markDirty() end,
})

uiToggles.autoPlayOnReady = AutoTab:Toggle({
    Title = "出现 ReadyFrame 时自动回放",
    Value = cfg.autoPlayOnReady,
    Callback = function(v) cfg.autoPlayOnReady = v; saveCfg(); markDirty() end,
})

uiToggles.autoRejoin = AutoTab:Toggle({
    Title = "打完后自动重开下一局",
    Value = cfg.autoRejoin,
    Callback = function(v) cfg.autoRejoin = v; saveCfg(); markDirty() end,
})

uiToggles.autoPickItem = AutoTab:Toggle({
    Title = "自动瞬移捡道具",
    Value = cfg.autoPickItem,
    Callback = function(v) cfg.autoPickItem = v; saveCfg(); markDirty() end,
})

uiToggles.autoSpeed = AutoTab:Toggle({
    Title = "自动设置倍速",
    Value = cfg.autoSpeed,
    Callback = function(v) cfg.autoSpeed = v; saveCfg(); markDirty() end,
})

uiDropdowns.gameSpeed = AutoTab:Dropdown({
    Title = "选择倍速档位",
    Values = { "1", "1.5", "2" },
    Value = tostring(cfg.gameSpeed),
    Callback = function(o) cfg.gameSpeed = o; saveCfg(); markDirty() end,
})

uiInputs.replayDelay = AutoTab:Input({
    Title = "回放延迟（秒）",
    Placeholder = tostring(cfg.replayDelay),
    Callback = function(t)
        local n = tonumber(t)
        if n then
            cfg.replayDelay = math.clamp(n, 0, 30)
            saveCfg(); markDirty()
        end
    end,
})

--==================== 配置档案（Profile） ====================
ConfTab:Section({ Title = "Profile" })

profileStateParagraph = ConfTab:Paragraph({
    Title = "Profile state",
    Desc = ("Profile: %s\nAll changes saved"):format(cfg.profile or "default"),
})

local pendingName = nil

ConfTab:Input({
    Title = "Profile name",
    Placeholder = cfg.profile or "default",
    Callback = function(text)
        pendingName = (text ~= "" and text) or nil
        log("待保存的档案名: " .. tostring(pendingName or cfg.profile))
    end,
})

local profileDropdown = ConfTab:Dropdown({
    Title = "Saved profiles",
    Values = listProfiles(),
    Value = cfg.profile or "default",
    Callback = function(name)
        cfg.profile = name
        saveCfg()
        refreshProfileState()
    end,
})

ConfTab:Button({
    Title = "Save profile",
    Callback = function()
        local name = pendingName or cfg.profile or "default"
        if saveProfile(name) then
            pcall(function()
                profileDropdown:Refresh(listProfiles())
                profileDropdown:Set(name)
            end)
            refreshProfileState()
            log("已保存档案 [" .. name .. "]")
            setStatus("状态: 档案已保存 [" .. name .. "]")
        end
    end,
})

ConfTab:Button({
    Title = "Load profile",
    Callback = function()
        local name = cfg.profile or "default"
        if loadProfile(name) then
            applyCfgToUI()
            log("已加载档案 [" .. name .. "]")
            setStatus("状态: 已加载档案 [" .. name .. "]")
        else
            setStatus("状态: 档案不存在 [" .. tostring(name) .. "]")
        end
    end,
})

ConfTab:Button({
    Title = "Reset to default（全部关闭）",
    Callback = function()
        local keepProfile = cfg.profile
        for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end
        cfg.profile = keepProfile
        cfg.macroName = currentMacroName or "新建宏..."
        saveCfg()
        applyCfgToUI()
        profileDirty = true
        refreshProfileState()
        log("已重置为默认（全部功能关闭）")
        setStatus("状态: 已重置为默认")
    end,
})

--==================== 调试 ====================
DbgTab:Section({ Title = "诊断" })

uiToggles.verbose = DbgTab:Toggle({
    Title = "控制台输出日志",
    Value = cfg.verbose,
    Callback = function(v) cfg.verbose = v; saveCfg(); markDirty() end,
})

DbgTab:Button({
    Title = "打印当前宏摘要",
    Callback = function()
        log(("宏: %s  动作数: %d"):format(tostring(currentMacroName), #recordings))
    end,
})

--==================== 配置同步到 UI ====================
function applyCfgToUI()
    suppressDirty = true
    for key, w in pairs(uiToggles) do
        pcall(function() w:Set(cfg[key] == true) end)
    end
    for key, w in pairs(uiDropdowns) do
        pcall(function() w:Set(tostring(cfg[key])) end)
    end
    for key, w in pairs(uiInputs) do
        local v = cfg[key]
        if v ~= nil then pcall(function() w:Set(tostring(v)) end) end
    end
    suppressDirty = false
    refreshProfileState()
end

applyCfgToUI()

-- ★★★ 修复后的队列刷新线程 ★★★
task.spawn(function()
    while true do
        task.wait(0.1)
        if #recordQueue > 0 then
            local batch = recordQueue
            recordQueue = {}
            for _, act in ipairs(batch) do
                recordings[#recordings + 1] = act
                if act.kind == "place" then
                    log(("录制放塔 %s -> %s"):format(act.tower, tostring(act.realUid)))
                elseif act.kind == "ability" or act.kind == "auto_ability" then
                    log(("录制技能: %s"):format(act.kind))
                else
                    log(("录制%s %s"):format(
                        act.kind == "upgrade" and "升级" or "卖塔", tostring(act.uid)))
                end
            end
            setStatus(("状态: 🔴 已录 %d 个动作"):format(#recordings))
        end
    end
end)

--==================== ★ 智能反宏秒答系统（修复版） ★ ====================
do
    local POLL      = 0.15   -- 检查间隔（秒）
    local RETRY_GAP = 0.60   -- 同一题两次尝试的间隔
    local MAX_TRY   = 6      -- 同一题最多尝试次数

    local anti = {
        sig = nil, tries = 0, lastTry = 0,
        logged = false, seen = false, noMatch = false,
    }

    -- 文本清洗：去富文本标签、去 nbsp、去掉所有空白
    local function plain(text)
        local s = tostring(text or "")
        s = s:gsub("<[^>]->", "")
        s = s:gsub("&nbsp;", " ")
        s = s:gsub("%s+", "")
        return s
    end

    local function chain(obj)          -- 祖先链，顺便当层级深度
        local t, n = {}, obj
        while n and n ~= playerGui do
            t[#t + 1] = n
            n = n.Parent
        end
        return t
    end

    local function shown(obj)          -- 逐级检查 Visible / ScreenGui.Enabled
        if not obj or not obj.Parent then return false end
        local node, guard = obj, 0
        while node and node ~= playerGui and guard < 64 do
            guard = guard + 1
            if node:IsA("ScreenGui") then
                if node.Enabled == false then return false end
            elseif node:IsA("GuiObject") then
                if node.Visible == false then return false end
            end
            node = node.Parent
        end
        return true
    end

    local function getAntiRoot()
        local g = playerGui:FindFirstChild("AntiMacro")
        if g and shown(g) then return g end
        for _, d in ipairs(playerGui:GetDescendants()) do
            if d.Name == "AntiMacro" and shown(d) then return d end
        end
        return nil
    end

    local function nearScore(a, b)     -- 最近公共祖先，越小越近
        local pos = {}
        for i, v in ipairs(chain(a)) do pos[v] = i end
        for i, v in ipairs(chain(b)) do
            if pos[v] then return i + pos[v] end
        end
        return math.huge
    end

    -- 同一个父节点下 >= 2 个可见 TextButton 自动成组（四个选项天然同父）
    local function collectGroups(root)
        local function byParent(getParent)
            local map, order = {}, {}
            for _, d in ipairs(root:GetDescendants()) do
                if d:IsA("TextButton") and plain(d.Text) ~= "" and shown(d) then
                    local p = getParent(d)
                    if p then
                        if not map[p] then map[p] = {}; order[#order + 1] = p end
                        table.insert(map[p], d)
                    end
                end
            end
            return map, order
        end

        local groups = {}
        local map, order = byParent(function(d) return d.Parent end)
        for _, p in ipairs(order) do
            if #map[p] >= 2 then
                groups[#groups + 1] = { parent = p, buttons = map[p], count = #map[p] }
            end
        end

        -- 按钮外面还包了一层 Frame：按祖父节点再分一次
        if #groups == 0 then
            local map2, order2 = byParent(function(d) return d.Parent and d.Parent.Parent end)
            for _, p in ipairs(order2) do
                if #map2[p] >= 2 then
                    groups[#groups + 1] = { parent = p, buttons = map2[p], count = #map2[p] }
                end
            end
        end

        table.sort(groups, function(a, b)
            local a4, b4 = a.count == 4, b.count == 4
            if a4 ~= b4 then return a4 end
            if a.count ~= b.count then return a.count > b.count end
            return #chain(a.parent) > #chain(b.parent)
        end)
        return groups
    end

    local function collectLabels(root)
        local list = {}
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("TextLabel") and plain(d.Text) ~= "" and shown(d) then
                list[#list + 1] = d
            end
        end
        return list
    end

    -- 三级比对：完全一致 -> 数值相等 -> 提取数字相同
    local function pickButton(labelText, buttons)
        local target = plain(labelText)
        if target == "" then return nil, nil end

        for _, b in ipairs(buttons) do
            if plain(b.Text) == target then return b, "完全一致" end
        end

        local tn = tonumber(target)
        if tn then
            for _, b in ipairs(buttons) do
                local bn = tonumber(plain(b.Text))
                if bn and bn == tn then return b, "数值相等" end
            end
        end

        local td = target:match("%d+%.?%d*")
        if td then
            for _, b in ipairs(buttons) do
                local bt = plain(b.Text)
                if bt == td then return b, "数字相同" end
                local bd = bt:match("%d+%.?%d*")
                if bd and bd == td then return b, "数字相同" end
            end
        end

        return nil, nil
    end

    -- 方式一：直接调用 MouseButton1Click / Activated / Down / Up 上的回调
    local function clickSignal(btn)
        local names = { "MouseButton1Click", "Activated", "MouseButton1Down", "MouseButton1Up" }

        if type(getconnections) == "function" then
            for _, n in ipairs(names) do
                local sig = btn[n]
                if sig then
                    local ok, conns = pcall(getconnections, sig)
                    if ok and type(conns) == "table" and #conns > 0 then
                        local ran = 0
                        for _, c in ipairs(conns) do
                            local fn = c.Function or c.Func
                            if type(fn) == "function" then
                                pcall(fn)
                                ran = ran + 1
                            end
                        end
                        if ran > 0 then return true, n .. " (getconnections)" end
                    end
                end
            end
        end

        for _, n in ipairs(names) do
            local sig = btn[n]
            if sig then
                local ok = pcall(function() firesignal(sig) end)
                if ok then return true, n .. " (firesignal)" end
            end
        end
        return false, nil
    end

    -- 方式二：模拟真实鼠标点击（对付只认 UserInputService / Activated 的写法）
    local function clickMouse(btn)
        local pos = btn.AbsolutePosition + (btn.AbsoluteSize / 2)

        if type(mousemoveabs) == "function" and type(mouse1click) == "function" then
            local ok = pcall(function()
                mousemoveabs(pos.X, pos.Y)
                task.wait(0.05)
                mouse1click()
            end)
            if ok then return true, "真实鼠标 (mousemoveabs)" end
        end

        local okVim, VIM = pcall(function()
            return game:GetService("VirtualInputManager")
        end)
        if okVim and VIM then
            local ok = pcall(function()
                VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true,  game, 1)
                task.wait(0.04)
                VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
            end)
            if ok then return true, "VirtualInputManager" end
        end

        return false, nil
    end

    task.spawn(function()
        while true do
            task.wait(POLL)

            local root = getAntiRoot()

            if not root then
                anti.sig, anti.tries, anti.logged = nil, 0, false
                anti.seen, anti.noMatch = false, false
            else
                if not anti.seen then
                    anti.seen = true
                    log("👀 检测到反宏界面，开始解析")
                end

                local groups = collectGroups(root)
                if #groups > 0 then
                    local labels = collectLabels(root)

                    local chosenBtn, chosenText, how
                    local best = math.huge
                    for _, g in ipairs(groups) do
                        for _, lab in ipairs(labels) do
                            local b, m = pickButton(lab.Text, g.buttons)
                            if b then
                                -- 4 按钮的组优先，其次文本离选项组最近
                                local sc = nearScore(lab, g.parent) + ((g.count == 4) and 0 or 100)
                                if sc < best then
                                    best       = sc
                                    chosenBtn  = b
                                    chosenText = lab.Text
                                    how        = m
                                end
                            end
                        end
                    end

                    if chosenBtn then
                        local sig = plain(chosenText) .. "|" .. plain(chosenBtn.Text)
                        if sig ~= anti.sig then
                            anti.sig, anti.tries, anti.logged = sig, 0, false
                        end

                        local now = os.clock()
                        if anti.tries < MAX_TRY and now - anti.lastTry >= RETRY_GAP then
                            anti.lastTry = now
                            anti.tries   = anti.tries + 1

                            local okClick, method
                            if anti.tries == 1 then
                                okClick, method = clickSignal(chosenBtn)
                                if not okClick then
                                    okClick, method = clickMouse(chosenBtn)
                                end
                            elseif anti.tries == 2 then
                                okClick, method = clickMouse(chosenBtn)
                            else
                                okClick, method = clickSignal(chosenBtn)
                                if not okClick then
                                    okClick, method = clickMouse(chosenBtn)
                                end
                            end

                            if not anti.logged then
                                anti.logged = true
                                log(("🎯 反宏命中：题目[%s] 选项[%s] 比对=%s 点击=%s 方式=%s"):format(
                                    tostring(chosenText), tostring(chosenBtn.Text),
                                    tostring(how), tostring(okClick), tostring(method)))
                            end
                        end
                    elseif not anti.noMatch then
                        anti.noMatch = true
                        local lt, bt = {}, {}
                        for i, l in ipairs(labels) do
                            if i <= 8 then lt[#lt + 1] = plain(l.Text) end
                        end
                        for _, b in ipairs(groups[1].buttons) do
                            bt[#bt + 1] = plain(b.Text)
                        end
                        log("⚠️ 反宏：找到选项但没匹配上，文本=" .. table.concat(lt, ",")
                            .. " 按钮=" .. table.concat(bt, ","))
                    end
                end
            end
        end
    end)
end

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

        if not isRecording or isPlaying
            or (method ~= "InvokeServer" and method ~= "FireServer")
            or typeof(self) ~= "Instance" then
            return oldNamecall(self, ...)
        end

        local name = self.Name

        -- 排除反宏发包，不要记录它
        if name == "AntiMacro" then
            return oldNamecall(self, ...)
        end

        if name == "RequestPlacement" then
            local a1, a2, a3 = ...
            local realUid = oldNamecall(self, ...)
            pcall(function()
                if type(realUid) == "string" and typeof(a2) == "Vector3" then
                    recordQueue[#recordQueue + 1] = {
                        kind = "place",
                        tower = tostring(a1),
                        pos = { a2.X, a2.Y, a2.Z },
                        rot = tonumber(a3) or 0,
                        realUid = realUid,
                        cash = liveCash,
                    }
                end
            end)
            return realUid
        end

        if name == "RequestTowerUpgrade" or name == "RequestTowerSell" then
            local a1 = ...
            local ret = oldNamecall(self, ...)
            pcall(function()
                recordQueue[#recordQueue + 1] = {
                    kind = (name == "RequestTowerUpgrade") and "upgrade" or "sell",
                    uid  = tostring(a1),
                    cash = liveCash,
                }
            end)
            return ret
        end
        
        if name == "RequestTowerAbility" or name == "UpdateAbilityAutoUse" then
            local a1 = ...
            local ret = oldNamecall(self, ...)
            local packed = encodeArgs(...)
            
            local act = {
                kind   = (name == "RequestTowerAbility") and "ability" or "auto_ability",
                method = method,
                args   = packed,
                cash   = liveCash,
                retUid = (type(ret) == "string" and #ret >= 32) and ret or nil,
            }
            
            task.delay(4, function()
                local uuid = tostring(a1)
                local towerModel = findTowerModelByUuid(uuid)
                if towerModel and towerModel.PrimaryPart then
                    act.postPos = { towerModel:GetPivot().Position:GetComponents() }
                end
            end)

            pcall(function()
                recordQueue[#recordQueue + 1] = act
            end)
            return ret
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
        return RequestPlacement:InvokeServer(act.tower,
            Vector3.new(act.pos[1], act.pos[2], act.pos[3]), act.rot or 0, uid, ts)
    end)
    if ok and type(ret) == "string" then return true, ret end
    return false, ok and ret or tostring(ret)
end

local function runTowerAction(act, failedUid)
    if act.kind == "ability" or act.kind == "auto_ability" then
        local args, argc
        if act.args then
            args, argc = decodeArgs(act.args)
        else 
            args, argc = { act.uid, act.ability }, 2
        end
        if argc == 0 then return false, "skip" end

        if args[1] ~= nil then
            args[1] = uidMap[args[1]] or args[1]
        end

        local remote = (act.kind == "ability") and RequestTowerAbility or UpdateAbilityAutoUse
        if not remote then return false, "no remote" end

        local ok, ret = pcall(function()
            if act.method == "FireServer" then
                return remote:FireServer(table.unpack(args, 1, argc))
            end
            return remote:InvokeServer(table.unpack(args, 1, argc))
        end)

        if ok and type(ret) == "string" and #ret >= 32 then
            if act.args and act.args[1] then uidMap[act.args[1]] = ret end
            if act.retUid then uidMap[act.retUid] = ret end
        end
        
        if ok and act.postPos then
            task.wait(0.5) 
            local newUuid = (type(ret) == "string" and #ret >= 32) and ret or args[1]
            local towerModel = findTowerModelByUuid(newUuid)
            if towerModel and towerModel.PrimaryPart then
                towerModel:PivotTo(CFrame.new(Vector3.new(unpack(act.postPos))))
                log(("🚀 技能释放，已物理传送塔到目标点"))
            end
        end
        
        return ok, ret
    end

    if not act.uid or failedUid[act.uid] then return false, "skip" end
    local target = uidMap[act.uid]
    if not target then return false, "skip" end
    
    local ok, ret = false, nil
    if act.kind == "upgrade" then
        ok, ret = pcall(function() return RequestTowerUpgrade:InvokeServer(target) end)
    elseif act.kind == "sell" then
        ok, ret = pcall(function() return RequestTowerSell:InvokeServer(target) end)
    end
    
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
                while isPlaying and liveCash < act.cash do
                    setStatus(("🟡 等钱中 [%d/%d] 需 %d 现 %d"):format(i, #recordings, act.cash, liveCash))
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
                else
                    failN = failN + 1
                    if act.realUid then failedUid[act.realUid] = true end
                    log(("放塔失败 %d %s ret=%s"):format(i, act.tower, tostring(ret)))
                end
            else
                local ok, ret
                for _ = 1, 3 do
                    ok, ret = runTowerAction(act, failedUid)
                    if ok then break end
                    task.wait(0.4)
                end

                if ok then okN = okN + 1
                elseif ret == "skip" then skipN = skipN + 1
                else failN = failN + 1 end
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
    if playThread then pcall(function() task.cancel(playThread) end); playThread = nil end
    pcall(function() playToggle:Set(false) end)
    setStatus("状态: 🟡 已停止")
end

--==================== 自动捡道具 ====================
task.spawn(function()
    local folder = Workspace:WaitForChild("ItemDrops", 30)
    if not folder then return end
    folder.DescendantAdded:Connect(function(item)
        if not cfg.autoPickItem or not item:IsA("Model") then return end
        task.wait(0.1)
        if not cfg.autoPickItem or not item.Parent then return end
        local pos = item.PrimaryPart and item.PrimaryPart.Position
        if not pos then
            local ok, pivot = pcall(function() return item:GetPivot().Position end)
            if ok then pos = pivot end
        end
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if pos and hrp then
            local back = hrp.CFrame
            hrp.CFrame = CFrame.new(pos + Vector3.new(0, 2, 0))
            log("⭐ 发现道具，已瞬移拾取")
            task.wait(0.3)
            if cfg.autoPickItem and hrp and hrp.Parent then hrp.CFrame = back end
        end
    end)
end)

--==================== 自动化循环 ====================
task.spawn(function()
    local round = {
        readyOpen   = false,
        fired       = false,   
        sentReady   = false,   
        lastVote    = 0,
        voteCooldown= 0,
        lastRejoin  = 0,
        lastSpeed   = 0,
    }

    local readyFrameRef = nil
    local function getReadyFrame()
        if readyFrameRef and readyFrameRef.Parent and readyFrameRef:IsDescendantOf(playerGui) then
            return readyFrameRef
        end
        readyFrameRef = findByName(playerGui, "ReadyFrame")
        return readyFrameRef
    end

    while true do
        task.wait(0.2)

        if isRecording then
            round.fired = false
            round.sentReady = false
        elseif not isPlaying then
            local now = os.clock()

            if cfg.autoSpeed and SpeedToggle then
                if now - round.lastSpeed >= 10 then
                    round.lastSpeed = now
                    local speedVal = tonumber(cfg.gameSpeed) or 1
                    pcall(function() SpeedToggle:FireServer(speedVal) end)
                    log("⚡ 已尝试设置倍速为: " .. tostring(speedVal))
                end
            end

            if cfg.autoRejoin and ResultsAction then
                local winContent = game:GetService("StarterGui"):FindFirstChild("Win")
                winContent = winContent and winContent:FindFirstChild("Content")
                
                local defeatContent = game:GetService("StarterGui"):FindFirstChild("Defeat")
                defeatContent = defeatContent and defeatContent:FindFirstChild("Content")

                local isGameOver = (winContent and isVisibleDeep(winContent)) or (defeatContent and isVisibleDeep(defeatContent))

                if isGameOver and now - round.lastRejoin >= 5 then
                    round.lastRejoin = now
                    log("🏁 检测到结算界面 (Win/Defeat)，发送 Rejoin 重开")
                    pcall(function() ResultsAction:FireServer("Rejoin") end)
                    round.lastSpeed = 0
                end
            end

            if cfg.autoVote and CastDifficultyVote and now >= round.voteCooldown then
                if now - round.lastVote >= 3 then
                    round.lastVote = now
                    
                    local foundVoteUI = false
                    
                    local coreGui1 = playerGui:FindFirstChild("CoreGui")
                    local diffSelect1 = coreGui1 and coreGui1:FindFirstChild("DifficultySelect")
                    local holder1 = diffSelect1 and diffSelect1:FindFirstChild("Holder")
                    local diff1_1 = holder1 and holder1:FindFirstChild("1Diff")
                    if diff1_1 and isVisibleDeep(diff1_1) then
                        foundVoteUI = true
                    end
                    
                    local coreGui2 = playerGui:FindFirstChild("DiffSelect2")
                    local mapDiff = coreGui2 and coreGui2:FindFirstChild("MapDiff")
                    local diff1_2 = mapDiff and mapDiff:FindFirstChild(".2Diff")
                    if diff1_2 and isVisibleDeep(diff1_2) then
                        foundVoteUI = true
                    end

                    if foundVoteUI then
                        pcall(function() CastDifficultyVote:FireServer(cfg.selectedDifficulty) end)
                        round.voteCooldown = now + 30
                        log("✅ 已检测到投票面板并发送投票: " .. tostring(cfg.selectedDifficulty))
                    end
                end
            end

            local frame = getReadyFrame()
            local open  = frame ~= nil and frame.Parent ~= nil and isVisibleDeep(frame)

            if open and not round.readyOpen then
                round.sentReady = false
                round.fired = false
                log("准备界面打开，本局状态已重置")
            elseif not open and round.readyOpen then
                round.sentReady = false
                round.fired = false
                log("准备界面关闭（进入对局）")
                round.lastSpeed = 0
            end
            round.readyOpen = open

            if open then
                if cfg.autoReady and not round.sentReady then
                    round.sentReady = true
                    local btn = frame:FindFirstChild("ReadyButton", true)
                    if btn and btn:IsA("TextButton") and isVisibleDeep(btn) then
                        local ok = pcall(function() firesignal(btn.MouseButton1Click) end)
                        if not ok and ReadyUp then
                            pcall(function() ReadyUp:FireServer() end)
                        end
                    elseif ReadyUp then
                        pcall(function() ReadyUp:FireServer() end)
                    end
                    log("✅ 已发送 ReadyUp")
                end

                if cfg.autoPlayOnReady and not round.fired then
                    round.fired = true
                    setStatus(("状态: 🟢 ReadyFrame 出现，%.1f 秒后回放"):format(cfg.replayDelay))
                    log("准备回放")
                    task.wait(cfg.replayDelay)
                    if not isRecording and not isPlaying then startPlayback() end
                end
            end
        end
    end
end)

--==================== 启动 ====================
installHook()
setStatus(("状态: 就绪  档案[%s]  宏[%s]"):format(tostring(cfg.profile), tostring(currentMacroName)))
log("脚本加载完成，已恢复配置与上次宏")
