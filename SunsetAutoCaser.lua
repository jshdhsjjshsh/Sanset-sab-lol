-- Sunset Auto Caser | compact mobile-first client interface
-- Uses the game's own Catalog, Economy, Art and Request APIs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
if not player then return end

local function findModule(root, name)
    if not root then return nil end
    local direct = root:FindFirstChild(name)
    if direct and direct:IsA("ModuleScript") then return direct end
    for _, obj in ipairs(root:GetDescendants()) do
        if obj.Name == name and obj:IsA("ModuleScript") then return obj end
    end
end

local caser = ReplicatedStorage:WaitForChild("Caser", 20)
if not caser then warn("[Sunset] Caser folder not found") return end
local request = caser:WaitForChild("Request", 20)
local catalogModule = caser:WaitForChild("Catalog", 20)
local economyModule = caser:WaitForChild("Economy", 20)
if not request or not request:IsA("RemoteFunction") then warn("[Sunset] Caser.Request is unavailable") return end
if not catalogModule or not economyModule then warn("[Sunset] Catalog/Economy modules are unavailable") return end

local ok, Catalog = pcall(require, catalogModule)
if not ok or type(Catalog) ~= "table" then warn("[Sunset] Catalog failed: " .. tostring(Catalog)) return end
local okEconomy, Economy = pcall(require, economyModule)
if not okEconomy or type(Economy) ~= "table" then warn("[Sunset] Economy failed: " .. tostring(Economy)) return end

local playerScripts = player:WaitForChild("PlayerScripts", 15)
local artModule = findModule(playerScripts, "Art")
local Art
if artModule then
    local artOk, artResult = pcall(require, artModule)
    if artOk and type(artResult) == "table" then Art = artResult else warn("[Sunset] Art module failed: " .. tostring(artResult)) end
else
    warn("[Sunset] StarterPlayerScripts.Art not found; image placeholders will be used")
end

-- Normalize catalog indexes without changing the game's original records.
Catalog.ById = Catalog.ById or {}
if type(Catalog.Items) == "table" then
    for _, item in pairs(Catalog.Items) do
        if type(item) == "table" and item.id then Catalog.ById[item.id] = item end
    end
end
Catalog.CaseById = Catalog.CaseById or {}
if type(Catalog.Cases) == "table" then
    for _, caseData in pairs(Catalog.Cases) do
        if type(caseData) == "table" and caseData.id then Catalog.CaseById[caseData.id] = caseData end
    end
end

local function invoke(action, data)
    local payload = table.clone(data or {})
    -- An empty version map requests a complete profile response rather than an unknown delta base.
    payload.m7have = payload.m7have or {}
    local success, result = pcall(function() return request:InvokeServer(action, payload) end)
    if not success then return nil, tostring(result) end
    if type(result) ~= "table" then return nil, "Invalid server response" end
    return result
end

local profile
local function refreshProfile()
    local result, err = invoke("state", {})
    if result and result.ok == true and type(result.profile) == "table" then
        profile = result.profile
        if type(profile.items) ~= "table" then profile.items = {} end
        return true
    end
    return false, err or (result and result.error) or "Profile refresh failed"
end
local profileOk, profileError = refreshProfile()
if not profileOk then warn("[Sunset] Profile: " .. tostring(profileError)) end

local function money(value)
    value = tonumber(value) or 0
    if type(Economy.money) == "function" then
        local success, result = pcall(Economy.money, value)
        if success and result then return tostring(result) end
    end
    local n = math.floor(value + 0.5)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
    return out
end

local function getItem(id)
    return Catalog.ById and Catalog.ById[id]
end

local function sortedCases()
    local byId, result = {}, {}
    local function add(record, fallbackId)
        if type(record) ~= "table" then return end
        local id = record.id or fallbackId
        if not id or byId[id] then return end
        record.id = record.id or id
        byId[id] = true
        table.insert(result, record)
    end
    if type(Catalog.Cases) == "table" then
        for key, record in pairs(Catalog.Cases) do add(record, key) end
    end
    if #result == 0 and type(Catalog.CaseById) == "table" then
        for key, record in pairs(Catalog.CaseById) do add(record, key) end
    end
    table.sort(result, function(a, b)
        local av, bv = tonumber(a.price) or 0, tonumber(b.price) or 0
        if av == bv then return tostring(a.name or a.id) < tostring(b.name or b.id) end
        return av > bv
    end)
    return result
end

local function inventoryEntries(eligibleOnly)
    local result = {}
    for _, inv in ipairs((profile and profile.items) or {}) do
        local data = getItem(inv.id)
        if data then
            local eligible = inv.locked ~= true and data.noPrice ~= true and (tonumber(data.value) or 0) > 0
            if not eligibleOnly or eligible then
                table.insert(result, {inv = inv, data = data, eligible = eligible})
            end
        end
    end
    table.sort(result, function(a, b)
        local av, bv = tonumber(a.data.value) or 0, tonumber(b.data.value) or 0
        if av == bv then return tostring(a.data.name or a.data.id) < tostring(b.data.name or b.data.id) end
        return av > bv
    end)
    return result
end

local function caseDrops(caseData, sortMode)
    local result, seen = {}, {}
    for _, entry in pairs((caseData and caseData.pool) or {}) do
        local id = type(entry) == "table" and entry.id or entry
        local data = id and getItem(id)
        if data and not seen[id] then
            seen[id] = true
            table.insert(result, {data = data, weight = type(entry) == "table" and tonumber(entry.weight) or nil})
        end
    end
    table.sort(result, function(a, b)
        local av, bv = tonumber(a.data.value) or 0, tonumber(b.data.value) or 0
        if av == bv then return tostring(a.data.name or a.data.id) < tostring(b.data.name or b.data.id) end
        if sortMode == "low" then return av < bv end
        return av > bv
    end)
    return result
end

-- GUI foundation
local playerGui = player:WaitForChild("PlayerGui")
local previous = playerGui:FindFirstChild("SunsetAutoCaser")
if previous then previous:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "SunsetAutoCaser"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.Parent = playerGui
local function raiseGuiPriority()
    for _, screen in ipairs(playerGui:GetChildren()) do
        if screen:IsA("ScreenGui") and screen ~= gui and screen.DisplayOrder >= gui.DisplayOrder then
            pcall(function() screen.DisplayOrder = gui.DisplayOrder - 1 end)
        end
    end
end
raiseGuiPriority()
playerGui.ChildAdded:Connect(function(child)
    if child:IsA("ScreenGui") and child ~= gui then task.defer(raiseGuiPriority) end
end)
task.spawn(function()
    while gui.Parent do
        task.wait(1)
        raiseGuiPriority()
    end
end)

local palette = {
    bg = Color3.fromRGB(13, 15, 23),
    side = Color3.fromRGB(17, 19, 29),
    panel = Color3.fromRGB(22, 25, 37),
    panel2 = Color3.fromRGB(30, 34, 49),
    panel3 = Color3.fromRGB(38, 42, 59),
    red = Color3.fromRGB(238, 74, 94),
    redDark = Color3.fromRGB(119, 42, 62),
    green = Color3.fromRGB(83, 205, 148),
    text = Color3.fromRGB(240, 242, 248),
    muted = Color3.fromRGB(145, 153, 173),
    line = Color3.fromRGB(54, 60, 79),
    amber = Color3.fromRGB(238, 180, 91),
}

local function round(object, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = object
    return c
end
local function outline(object, color, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color or palette.line
    s.Transparency = transparency or 0
    s.Thickness = 1
    s.Parent = object
    return s
end
local function makeLabel(parent, text, size, pos, dim, color, font, z)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Text = tostring(text or "")
    l.TextColor3 = color or palette.text
    l.Font = font or Enum.Font.Gotham
    l.TextSize = size or 12
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Center
    l.Position = pos
    l.Size = dim
    l.ZIndex = z or 2
    l.Parent = parent
    return l
end
local function makeButton(parent, text, pos, dim, callback, fill, z)
    local b = Instance.new("TextButton")
    b.AutoButtonColor = true
    b.Text = tostring(text or "")
    b.TextColor3 = palette.text
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 11
    b.BackgroundColor3 = fill or palette.panel2
    b.Position = pos
    b.Size = dim
    b.ZIndex = z or 2
    b.Parent = parent
    round(b, 7)
    outline(b, palette.line, 0.25)
    if callback then b.Activated:Connect(callback) end
    return b
end
local function makeInput(parent, placeholder, value, pos, dim, z)
    local t = Instance.new("TextBox")
    t.ClearTextOnFocus = false
    t.PlaceholderText = placeholder or ""
    t.Text = tostring(value or "")
    t.TextColor3 = palette.text
    t.PlaceholderColor3 = palette.muted
    t.Font = Enum.Font.Gotham
    t.TextSize = 11
    t.BackgroundColor3 = palette.panel2
    t.Position = pos
    t.Size = dim
    t.ZIndex = z or 2
    t.Parent = parent
    round(t, 7)
    outline(t, palette.line, 0.25)
    return t
end
local function makeArt(parent, key, pos, dim, z)
    local holder = Instance.new("Frame")
    holder.Position = pos
    holder.Size = dim
    holder.BackgroundColor3 = palette.panel3
    holder.ZIndex = z or 3
    holder.Parent = parent
    round(holder, 7)
    if Art and type(Art.image) == "function" and key and key ~= "" then
        local success, image = pcall(Art.image, holder, key, 2, 2, math.max(1, dim.X.Offset - 4), math.max(1, dim.Y.Offset - 4), Enum.ScaleType.Fit)
        if success and image then image.ZIndex = holder.ZIndex + 1 else
            local fallback = makeLabel(holder, "◇", 19, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), palette.muted, Enum.Font.GothamBold, holder.ZIndex + 1)
            fallback.TextXAlignment = Enum.TextXAlignment.Center
        end
    else
        local fallback = makeLabel(holder, "◇", 19, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), palette.muted, Enum.Font.GothamBold, holder.ZIndex + 1)
        fallback.TextXAlignment = Enum.TextXAlignment.Center
    end
    return holder
end
local function makeScroll(parent, pos, dim, z)
    local scroll = Instance.new("ScrollingFrame")
    scroll.Position = pos
    scroll.Size = dim
    scroll.BackgroundColor3 = palette.panel
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 3
    scroll.ScrollBarImageColor3 = palette.red
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.ScrollingDirection = Enum.ScrollingDirection.Y
    scroll.ZIndex = z or 10
    scroll.Parent = parent
    round(scroll, 8)
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = scroll
    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 5)
    padding.PaddingBottom = UDim.new(0, 5)
    padding.PaddingLeft = UDim.new(0, 5)
    padding.PaddingRight = UDim.new(0, 5)
    padding.Parent = scroll
    return scroll, layout
end
local function clearRows(frame)
    for _, child in ipairs(frame:GetChildren()) do
        if child:IsA("GuiObject") and not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
            child:Destroy()
        end
    end
end
local function makeItemRow(parent, entry, rightText, selected, callback, disabled, order)
    local data = entry.data or entry
    local row = makeButton(parent, "", UDim2.new(), UDim2.new(1, -2, 0, 46), callback, selected and Color3.fromRGB(34, 62, 55) or palette.panel2, (parent.ZIndex or 1) + 1)
    row.LayoutOrder = order or 0
    row.Text = ""
    row.AutoButtonColor = not disabled
    local imageKey = data.art
    makeArt(row, imageKey, UDim2.fromOffset(5, 4), UDim2.fromOffset(38, 38), row.ZIndex + 1)
    local name = makeLabel(row, data.name or data.fullName or tostring(data.id or "Unknown"), 10, UDim2.fromOffset(50, 5), UDim2.new(1, -142, 0, 17), disabled and palette.muted or palette.text, Enum.Font.GothamSemibold, row.ZIndex + 2)
    name.TextTruncate = Enum.TextTruncate.AtEnd
    local sub = makeLabel(row, disabled and (entry.inv and entry.inv.locked and "LOCKED" or "NOT ELIGIBLE") or "TAP TO SELECT", 8, UDim2.fromOffset(50, 24), UDim2.new(1, -145, 0, 13), disabled and palette.amber or palette.muted, Enum.Font.Gotham, row.ZIndex + 2)
    sub.TextTruncate = Enum.TextTruncate.AtEnd
    local value = makeLabel(row, rightText or (money(data.value or data.price or 0) .. " Stars"), 9, UDim2.new(1, -88, 0, 5), UDim2.fromOffset(80, 17), palette.green, Enum.Font.GothamBold, row.ZIndex + 2)
    value.TextXAlignment = Enum.TextXAlignment.Right
    if disabled then row.BackgroundTransparency = 0.2 end
    return row
end

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(500, 340)
main.Position = UDim2.new(0.5, -250, 0.5, -170)
main.BackgroundColor3 = palette.bg
main.Active = true
main.Parent = gui
round(main, 13)
outline(main, Color3.fromRGB(111, 69, 91), 0.15)
local mainGradient = Instance.new("UIGradient")
mainGradient.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 20, 32)), ColorSequenceKeypoint.new(0.55, palette.bg), ColorSequenceKeypoint.new(1, Color3.fromRGB(26, 18, 30))})
mainGradient.Rotation = 24
mainGradient.Parent = main
local scale = Instance.new("UIScale")
scale.Parent = main
local function fitGui()
    local camera = workspace.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    scale.Scale = math.clamp(math.min((viewport.X - 28) / 500, (viewport.Y - 32) / 340, 0.82), 0.56, 0.82)
end
fitGui()
if workspace.CurrentCamera then workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitGui) end

local bgImage = Instance.new("ImageLabel")
bgImage.BackgroundTransparency = 1
bgImage.Image = "rbxassetid://138766728600198"
bgImage.ImageTransparency = 0.9
bgImage.ScaleType = Enum.ScaleType.Crop
bgImage.Size = UDim2.fromScale(1, 1)
bgImage.ZIndex = 1
bgImage.Parent = main
round(bgImage, 13)

-- Drag only from the top strip; avoids blocking taps on controls.
local dragBar = Instance.new("Frame")
dragBar.BackgroundTransparency = 1
dragBar.Position = UDim2.fromOffset(0, 0)
dragBar.Size = UDim2.new(1, 0, 0, 36)
dragBar.Active = true
dragBar.ZIndex = 4
dragBar.Parent = main
local dragging, dragInput, dragStart, startPosition
local function updateDrag(inputObject)
    local delta = inputObject.Position - dragStart
    main.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
end
dragBar.InputBegan:Connect(function(inputObject)
    if inputObject.UserInputType == Enum.UserInputType.MouseButton1 or inputObject.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = inputObject.Position
        startPosition = main.Position
        inputObject.Changed:Connect(function()
            if inputObject.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
dragBar.InputChanged:Connect(function(inputObject)
    if inputObject.UserInputType == Enum.UserInputType.MouseMovement or inputObject.UserInputType == Enum.UserInputType.Touch then dragInput = inputObject end
end)
UserInputService.InputChanged:Connect(function(inputObject)
    if dragging and (inputObject == dragInput or inputObject.UserInputType == Enum.UserInputType.Touch) then updateDrag(inputObject) end
end)

local sidebar = Instance.new("Frame")
sidebar.Size = UDim2.new(0, 108, 1, 0)
sidebar.BackgroundColor3 = palette.side
sidebar.BackgroundTransparency = 0.04
sidebar.ZIndex = 2
sidebar.Parent = main
round(sidebar, 13)
local sideGradient = Instance.new("UIGradient")
sideGradient.Color = ColorSequence.new(Color3.fromRGB(29, 23, 38), palette.side)
sideGradient.Rotation = 90
sideGradient.Parent = sidebar
local logo = Instance.new("ImageLabel")
logo.BackgroundTransparency = 1
logo.Image = "rbxassetid://138766728600198"
logo.Position = UDim2.fromOffset(9, 9)
logo.Size = UDim2.fromOffset(27, 27)
logo.ScaleType = Enum.ScaleType.Fit
logo.ZIndex = 4
logo.Parent = sidebar
makeLabel(sidebar, "SUNSET", 13, UDim2.fromOffset(40, 7), UDim2.fromOffset(65, 17), palette.text, Enum.Font.GothamBlack, 4)
makeLabel(sidebar, "AUTO CASER", 7, UDim2.fromOffset(41, 22), UDim2.fromOffset(63, 12), palette.muted, Enum.Font.GothamBold, 4)
local nav = Instance.new("Frame")
nav.BackgroundTransparency = 1
nav.Position = UDim2.fromOffset(6, 52)
nav.Size = UDim2.new(1, -12, 0, 132)
nav.ZIndex = 3
nav.Parent = sidebar
local content = Instance.new("Frame")
content.BackgroundTransparency = 1
content.Position = UDim2.fromOffset(117, 39)
content.Size = UDim2.new(1, -126, 1, -47)
content.ZIndex = 2
content.Parent = main
local header = makeLabel(main, "AUTO CASES", 13, UDim2.fromOffset(119, 7), UDim2.fromOffset(250, 24), palette.text, Enum.Font.GothamBold, 5)
local close = makeButton(main, "×", UDim2.new(1, -32, 0, 5), UDim2.fromOffset(25, 25), function() gui:Destroy() end, palette.red, 8)
close.TextSize = 17
local line = Instance.new("Frame")
line.Position = UDim2.fromOffset(117, 34)
line.Size = UDim2.new(1, -126, 0, 1)
line.BackgroundColor3 = palette.redDark
line.BackgroundTransparency = 0.25
line.BorderSizePixel = 0
line.ZIndex = 4
line.Parent = main
makeLabel(sidebar, "BETA  •  V6", 8, UDim2.new(0, 9, 1, -22), UDim2.fromOffset(90, 14), palette.muted, Enum.Font.GothamBold, 4)

local pages, navButtons = {}, {}
local function newPage(name)
    local page = Instance.new("Frame")
    page.Name = name
    page.BackgroundTransparency = 1
    page.Size = UDim2.fromScale(1, 1)
    page.Visible = false
    page.ZIndex = 2
    page.Parent = content
    pages[name] = page
    return page
end
local casePage = newPage("cases")
local upgradePage = newPage("upgrade")
local contractPage = newPage("contracts")
local function showPage(name)
    for key, page in pairs(pages) do page.Visible = key == name end
    header.Text = ({cases = "AUTO CASES", upgrade = "AUTO UPGRADE", contracts = "AUTO CONTRACTS"})[name] or name
    for key, button in pairs(navButtons) do
        button.BackgroundColor3 = key == name and palette.red or palette.panel2
        button.TextColor3 = palette.text
    end
end
navButtons.cases = makeButton(nav, "▣  CASES", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 31), function() showPage("cases") end, palette.red, 4)
navButtons.upgrade = makeButton(nav, "↗  UPGRADE", UDim2.fromOffset(0, 36), UDim2.new(1, 0, 0, 31), function() showPage("upgrade") end, palette.panel2, 4)
navButtons.contracts = makeButton(nav, "◇  CONTRACTS", UDim2.fromOffset(0, 72), UDim2.new(1, 0, 0, 31), function() showPage("contracts") end, palette.panel2, 4)

-- Shared row helpers
local function setStatus(labelObject, text, color)
    labelObject.Text = tostring(text or "")
    labelObject.TextColor3 = color or palette.muted
end

-- CASE PAGE
makeLabel(casePage, "CASE AUTOMATION", 11, UDim2.fromOffset(0, 0), UDim2.fromOffset(180, 18), palette.muted, Enum.Font.GothamBold)
local balanceLabel = makeLabel(casePage, "STARS  —", 9, UDim2.new(1, -150, 0, 0), UDim2.fromOffset(145, 18), palette.green, Enum.Font.GothamBold)
balanceLabel.TextXAlignment = Enum.TextXAlignment.Right
local function updateBalance()
    balanceLabel.Text = "STARS  " .. money(profile and profile.credits or 0)
end
updateBalance()
local caseSelect = makeButton(casePage, "SELECT CASE  ▾", UDim2.fromOffset(0, 23), UDim2.fromOffset(143, 29), nil, palette.panel2)
local caseName = makeLabel(casePage, "No case selected", 10, UDim2.fromOffset(151, 24), UDim2.new(1, -220, 0, 28), palette.muted, Enum.Font.GothamSemibold)
caseName.TextTruncate = Enum.TextTruncate.AtEnd
local casePreview = makeArt(casePage, nil, UDim2.new(1, -61, 0, 20), UDim2.fromOffset(56, 54), 4)
local quantityBox = makeInput(casePage, "Quantity", "1", UDim2.fromOffset(0, 62), UDim2.fromOffset(75, 28))
makeLabel(casePage, "COUNT", 8, UDim2.fromOffset(0, 49), UDim2.fromOffset(70, 12), palette.muted, Enum.Font.GothamBold)
local autoSell = false
local autoSellButton = makeButton(casePage, "AUTO SELL  OFF", UDim2.fromOffset(83, 62), UDim2.fromOffset(110, 28), nil, palette.panel2)
local sellDropsButton = makeButton(casePage, "PICK DROPS", UDim2.fromOffset(201, 62), UDim2.fromOffset(93, 28), nil, palette.panel2)
local caseStart
local caseStatus = makeLabel(casePage, "Choose a case to begin", 9, UDim2.fromOffset(0, 101), UDim2.new(1, -130, 0, 28), palette.muted, Enum.Font.Gotham)
caseStart = makeButton(casePage, "START", UDim2.new(1, -105, 0, 99), UDim2.fromOffset(105, 31), nil, palette.green)
local caseContents = Instance.new("Frame")
caseContents.Position = UDim2.fromOffset(0, 137)
caseContents.Size = UDim2.new(1, 0, 1, -139)
caseContents.BackgroundColor3 = palette.panel
caseContents.ZIndex = 3
caseContents.Parent = casePage
round(caseContents, 8)
outline(caseContents, palette.line, 0.35)
makeLabel(caseContents, "TOP DROPS  /  VALUE", 8, UDim2.fromOffset(8, 5), UDim2.fromOffset(180, 13), palette.muted, Enum.Font.GothamBold, 4)
local contentsHint = makeLabel(caseContents, "Select a case to view its drops", 9, UDim2.fromOffset(8, 29), UDim2.new(1, -16, 0, 22), palette.muted, Enum.Font.Gotham, 4)
local casePickerPanel = Instance.new("Frame")
casePickerPanel.Position = UDim2.fromOffset(0, 20)
casePickerPanel.Size = UDim2.new(1, 0, 1, -20)
casePickerPanel.BackgroundColor3 = palette.panel
casePickerPanel.ZIndex = 20
casePickerPanel.Visible = false
casePickerPanel.Parent = casePage
round(casePickerPanel, 8)
local caseSearch = makeInput(casePickerPanel, "Search cases...", "", UDim2.fromOffset(7, 7), UDim2.new(1, -14, 0, 27), 22)
local caseScroll = makeScroll(casePickerPanel, UDim2.fromOffset(5, 40), UDim2.new(1, -10, 1, -45), 21)
local selectedCase
local sellPanel
local autoSellIds = {}
local caseRunning = false
local function updateCasePreview()
    caseName.Text = selectedCase and ((selectedCase.name or selectedCase.id) .. "  •  " .. money(selectedCase.price or 0) .. " Stars") or "No case selected"
    for _, child in ipairs(casePreview:GetChildren()) do child:Destroy() end
    if selectedCase and Art and type(Art.image) == "function" then
        pcall(Art.image, casePreview, selectedCase.art, 2, 2, 52, 50, Enum.ScaleType.Fit)
    else
        makeLabel(casePreview, "CASE", 8, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), palette.muted, Enum.Font.GothamBold, 6).TextXAlignment = Enum.TextXAlignment.Center
    end
end
local function renderCaseContents()
    for _, child in ipairs(caseContents:GetChildren()) do
        if child.Name == "DropCard" then child:Destroy() end
    end
    if not selectedCase then contentsHint.Visible = true; contentsHint.Text = "Select a case to view its drops"; return end
    local drops = caseDrops(selectedCase, "high")
    contentsHint.Visible = #drops == 0
    contentsHint.Text = #drops == 0 and "This case has no catalogued drops" or ""
    for index = 1, math.min(3, #drops) do
        local data = drops[index].data
        local card = Instance.new("Frame")
        card.Name = "DropCard"
        card.Position = UDim2.fromOffset(8 + (index - 1) * 104, 23)
        card.Size = UDim2.new(0, 97, 1, -29)
        card.BackgroundColor3 = palette.panel2
        card.ZIndex = 4
        card.Parent = caseContents
        round(card, 7)
        makeArt(card, data.art, UDim2.new(0.5, -25, 0, 4), UDim2.fromOffset(50, 47), 5)
        local nm = makeLabel(card, data.name or data.id, 8, UDim2.fromOffset(3, 53), UDim2.new(1, -6, 0, 14), palette.text, Enum.Font.GothamSemibold, 6)
        nm.TextXAlignment = Enum.TextXAlignment.Center
        nm.TextTruncate = Enum.TextTruncate.AtEnd
        local val = makeLabel(card, money(data.value or 0) .. " Stars", 8, UDim2.fromOffset(3, 68), UDim2.new(1, -6, 0, 13), palette.green, Enum.Font.GothamBold, 6)
        val.TextXAlignment = Enum.TextXAlignment.Center
    end
end
local function renderCasePicker()
    clearRows(caseScroll)
    local query = string.lower(caseSearch.Text or "")
    local cases = sortedCases()
    local shown = 0
    for index, data in ipairs(cases) do
        local name = string.lower(tostring(data.name or data.id))
        if query == "" or string.find(name, query, 1, true) then
            shown += 1
            local row = makeItemRow(caseScroll, data, money(data.price or 0) .. " Stars", false, nil, false, shown)
            local lastTap = 0
            row.Activated:Connect(function()
                local now = os.clock()
                if now - lastTap <= 0.42 then
                    selectedCase = data
                    autoSellIds = {}
                    updateCasePreview()
                    renderCaseContents()
                    casePickerPanel.Visible = false
                    setStatus(caseStatus, "Selected: " .. tostring(data.name or data.id), palette.green)
                else
                    setStatus(caseStatus, "Tap again to select: " .. tostring(data.name or data.id), palette.amber)
                end
                lastTap = now
            end)
        end
    end
    if shown == 0 then
        local msg = makeLabel(caseScroll, #cases == 0 and "Catalog returned 0 cases" or "No cases match this search", 10, UDim2.fromOffset(10, 10), UDim2.new(1, -20, 0, 24), palette.amber, Enum.Font.Gotham)
        msg.ZIndex = 23
    end
end
caseSelect.Activated:Connect(function()
    casePickerPanel.Visible = not casePickerPanel.Visible
    if sellPanel then sellPanel.Visible = false end
    caseContents.Visible = true
    if casePickerPanel.Visible then renderCasePicker() end
end)
caseSearch:GetPropertyChangedSignal("Text"):Connect(function() if casePickerPanel.Visible then renderCasePicker() end end)

autoSellButton.Activated:Connect(function()
    autoSell = not autoSell
    autoSellButton.Text = "AUTO SELL  " .. (autoSell and "ON" or "OFF")
    autoSellButton.BackgroundColor3 = autoSell and Color3.fromRGB(36, 69, 58) or palette.panel2
end)

sellPanel = Instance.new("Frame")
sellPanel.Position = UDim2.fromOffset(0, 137)
sellPanel.Size = UDim2.new(1, 0, 1, -139)
sellPanel.BackgroundColor3 = palette.panel
sellPanel.ZIndex = 20
sellPanel.Visible = false
sellPanel.Parent = casePage
round(sellPanel, 8)
local sellHeader = makeLabel(sellPanel, "SELECT DROPS TO SELL", 8, UDim2.fromOffset(8, 5), UDim2.fromOffset(160, 13), palette.muted, Enum.Font.GothamBold, 22)
local sellSort = "high"
local sellSortButton = makeButton(sellPanel, "HIGH → LOW", UDim2.new(1, -91, 0, 3), UDim2.fromOffset(83, 21), nil, palette.panel2, 22)
local sellScroll = makeScroll(sellPanel, UDim2.fromOffset(5, 29), UDim2.new(1, -10, 1, -34), 21)
local function renderSellPicker()
    clearRows(sellScroll)
    if not selectedCase then
        makeLabel(sellScroll, "Select a case first", 10, UDim2.fromOffset(8, 8), UDim2.new(1, -16, 0, 20), palette.amber, Enum.Font.Gotham, 23)
        return
    end
    local drops = caseDrops(selectedCase, sellSort)
    local shown = 0
    for _, entry in ipairs(drops) do
        local data = entry.data
        if not data.noPrice and (tonumber(data.value) or 0) > 0 then
            shown += 1
            local selected = autoSellIds[data.id] == true
            local row = makeItemRow(sellScroll, data, money(data.value or 0) .. " Stars", selected, nil, false, shown)
            local check = makeLabel(row, selected and "✓" or "+", 14, UDim2.new(1, -25, 0.5, -9), UDim2.fromOffset(18, 18), selected and palette.green or palette.muted, Enum.Font.GothamBold, row.ZIndex + 3)
            row.Activated:Connect(function()
                autoSellIds[data.id] = not autoSellIds[data.id]
                check.Text = autoSellIds[data.id] and "✓" or "+"
                check.TextColor3 = autoSellIds[data.id] and palette.green or palette.muted
                row.BackgroundColor3 = autoSellIds[data.id] and Color3.fromRGB(34, 62, 55) or palette.panel2
            end)
        end
    end
    if shown == 0 then makeLabel(sellScroll, "No sellable drops in this case", 10, UDim2.fromOffset(8, 8), UDim2.new(1, -16, 0, 20), palette.amber, Enum.Font.Gotham, 23) end
end
sellDropsButton.Activated:Connect(function()
    local open = not sellPanel.Visible
    sellPanel.Visible = open
    casePickerPanel.Visible = false
    caseContents.Visible = not open
    if open then renderSellPicker() end
end)
sellSortButton.Activated:Connect(function()
    sellSort = sellSort == "high" and "low" or "high"
    sellSortButton.Text = sellSort == "high" and "HIGH → LOW" or "LOW → HIGH"
    if sellPanel.Visible then renderSellPicker() end
end)

local function sellOpenedDrop(result)
    if not autoSell or type(result) ~= "table" then return true end
    local uid, itemId = result.uid, result.item
    if not uid or not itemId or not autoSellIds[itemId] then return true end
    local sold, err = invoke("sell", {ids = {uid}})
    if not sold or sold.ok ~= true then
        setStatus(caseStatus, "Auto-sell failed: " .. tostring(err or (sold and sold.error)), palette.amber)
        return false
    end
    return true
end

local function toggleCaseRun()
    if caseRunning then
        caseRunning = false
        caseStart.Text = "START"
        setStatus(caseStatus, "Stopping...", palette.amber)
        return
    end
    if not selectedCase then setStatus(caseStatus, "Choose a case first", palette.amber); return end
    if autoSell then
        local selectedDropCount = 0
        for _, enabled in pairs(autoSellIds) do if enabled then selectedDropCount += 1 end end
        if selectedDropCount == 0 then setStatus(caseStatus, "Pick at least one drop for auto-sell", palette.amber); return end
    end
    local quantity = math.floor(tonumber(quantityBox.Text) or 0)
    if quantity < 1 then setStatus(caseStatus, "Quantity must be at least 1", palette.amber); return end
    local refreshed, refreshErr = refreshProfile()
    if not refreshed then setStatus(caseStatus, "Profile error: " .. tostring(refreshErr), palette.red); return end
    updateBalance()
    local runningCase = selectedCase
    local price = tonumber(runningCase.price) or 0
    local balance = tonumber(profile.credits) or 0
    if price > 0 and balance < price then setStatus(caseStatus, "Not enough Stars for one case", palette.red); return end
    if price > 0 and quantity * price > balance then
        quantity = math.floor(balance / price)
        quantityBox.Text = tostring(quantity)
        setStatus(caseStatus, "Quantity adjusted to " .. quantity .. " (your balance)", palette.amber)
    end
    if quantity < 1 then setStatus(caseStatus, "Not enough Stars", palette.red); return end
    local maxInventory = tonumber(Catalog.MaxInventory) or 500
    local freeSlots = math.max(0, maxInventory - #profile.items)
    if not autoSell and quantity > freeSlots then
        quantity = freeSlots
        quantityBox.Text = tostring(quantity)
        if quantity < 1 then setStatus(caseStatus, "Inventory is full. Enable auto-sell or clear space.", palette.red); return end
        setStatus(caseStatus, "Quantity reduced to available inventory space", palette.amber)
    end
    caseRunning = true
    caseStart.Text = "STOP"
    task.spawn(function()
        local remaining = quantity
        while caseRunning and remaining > 0 do
            local stateOk, stateErr = refreshProfile()
            if not stateOk then setStatus(caseStatus, "Stopped: " .. tostring(stateErr), palette.red); break end
            updateBalance()
            local currentBalance = tonumber(profile.credits) or 0
            if price > 0 and currentBalance < price then setStatus(caseStatus, "Stopped: insufficient Stars", palette.red); break end
            if #profile.items >= maxInventory and not autoSell then setStatus(caseStatus, "Stopped: inventory full", palette.red); break end
            local result, err = invoke("open", {case = runningCase.id, count = 1, turbo = true})
            if not result or result.ok ~= true then
                setStatus(caseStatus, "Open failed: " .. tostring(err or (result and result.error)), palette.red)
                break
            end
            remaining -= 1
            setStatus(caseStatus, "Opened • " .. remaining .. " remaining", palette.green)
            local sellOk = sellOpenedDrop(result)
            if not sellOk then break end
            task.wait(0.35)
        end
        caseRunning = false
        caseStart.Text = "START"
        if remaining <= 0 then setStatus(caseStatus, "Completed " .. quantity .. " openings", palette.green)
        elseif not caseStatus.Text:find("Stopped") and not caseStatus.Text:find("failed") then setStatus(caseStatus, "Stopped", palette.muted) end
        refreshProfile()
        updateBalance()
    end)
end
caseStart.Activated:Connect(toggleCaseRun)

-- UPGRADE PAGE
makeLabel(upgradePage, "UPGRADE WORKBENCH", 11, UDim2.fromOffset(0, 0), UDim2.fromOffset(190, 18), palette.muted, Enum.Font.GothamBold)
local inventoryRefresh = makeButton(upgradePage, "REFRESH", UDim2.new(1, -74, 0, -1), UDim2.fromOffset(74, 22), nil, palette.panel2)
local upgradeChoose = makeButton(upgradePage, "CHOOSE SKIN  ▾", UDim2.fromOffset(0, 24), UDim2.fromOffset(138, 29), nil, palette.panel2)
local upgradeSelectedLabel = makeLabel(upgradePage, "No skin selected", 9, UDim2.fromOffset(146, 24), UDim2.new(1, -205, 0, 29), palette.muted, Enum.Font.GothamSemibold)
upgradeSelectedLabel.TextTruncate = Enum.TextTruncate.AtEnd
local upgradePreview = makeArt(upgradePage, nil, UDim2.new(1, -57, 0, 18), UDim2.fromOffset(53, 53), 4)
makeLabel(upgradePage, "MULTIPLIER", 8, UDim2.fromOffset(0, 61), UDim2.fromOffset(75, 12), palette.muted, Enum.Font.GothamBold)
local multiplierBox = makeInput(upgradePage, "x2", "2", UDim2.fromOffset(0, 74), UDim2.fromOffset(62, 26))
makeLabel(upgradePage, "ADD STARS", 8, UDim2.fromOffset(70, 61), UDim2.fromOffset(75, 12), palette.muted, Enum.Font.GothamBold)
local extraBox = makeInput(upgradePage, "0", "0", UDim2.fromOffset(70, 74), UDim2.fromOffset(70, 26))
makeLabel(upgradePage, "STEP", 8, UDim2.fromOffset(148, 61), UDim2.fromOffset(45, 12), palette.muted, Enum.Font.GothamBold)
local stepBox = makeInput(upgradePage, "1000", "1000", UDim2.fromOffset(148, 74), UDim2.fromOffset(57, 26))
local plusStep = makeButton(upgradePage, "+", UDim2.fromOffset(210, 74), UDim2.fromOffset(25, 26), nil, palette.panel2)
local minusStep = makeButton(upgradePage, "−", UDim2.fromOffset(239, 74), UDim2.fromOffset(25, 26), nil, palette.panel2)
local chanceLabel = makeLabel(upgradePage, "CHANCE  —", 10, UDim2.fromOffset(272, 73), UDim2.new(1, -272, 0, 27), palette.green, Enum.Font.GothamBold)
local targetCard = Instance.new("Frame")
targetCard.Position = UDim2.fromOffset(0, 108)
targetCard.Size = UDim2.new(1, 0, 0, 68)
targetCard.BackgroundColor3 = palette.panel
 targetCard.ZIndex = 3
targetCard.Parent = upgradePage
round(targetCard, 8)
outline(targetCard, palette.line, 0.35)
local targetArt = makeArt(targetCard, nil, UDim2.fromOffset(7, 7), UDim2.fromOffset(54, 54), 4)
makeLabel(targetCard, "TARGET", 8, UDim2.fromOffset(69, 7), UDim2.fromOffset(70, 12), palette.muted, Enum.Font.GothamBold, 5)
local targetName = makeLabel(targetCard, "Select a skin and multiplier", 10, UDim2.fromOffset(69, 20), UDim2.new(1, -78, 0, 18), palette.text, Enum.Font.GothamSemibold, 5)
local targetValue = makeLabel(targetCard, "—", 9, UDim2.fromOffset(69, 40), UDim2.new(1, -78, 0, 16), palette.green, Enum.Font.GothamBold, 5)
local upgradeStart = makeButton(upgradePage, "START AUTO", UDim2.fromOffset(0, 183), UDim2.fromOffset(105, 29), nil, palette.green)
local upgradeStatus = makeLabel(upgradePage, "Choose an item to calculate chance", 8, UDim2.fromOffset(112, 183), UDim2.new(1, -112, 0, 29), palette.muted, Enum.Font.Gotham)
local upgradeStats = makeLabel(upgradePage, "WINS 0   •   FAILS 0", 8, UDim2.fromOffset(0, 215), UDim2.fromOffset(220, 14), palette.muted, Enum.Font.GothamBold)
local queueHint = makeLabel(upgradePage, "AUTO MODE uses each eligible inventory skin once", 8, UDim2.new(1, -240, 0, 215), UDim2.fromOffset(240, 14), palette.muted, Enum.Font.Gotham)
queueHint.TextXAlignment = Enum.TextXAlignment.Right
local upgradePickerPanel = Instance.new("Frame")
upgradePickerPanel.Position = UDim2.fromOffset(0, 24)
upgradePickerPanel.Size = UDim2.new(1, 0, 1, -25)
upgradePickerPanel.BackgroundColor3 = palette.panel
upgradePickerPanel.ZIndex = 20
upgradePickerPanel.Visible = false
upgradePickerPanel.Parent = upgradePage
round(upgradePickerPanel, 8)
local upgradeSearch = makeInput(upgradePickerPanel, "Search inventory...", "", UDim2.fromOffset(7, 7), UDim2.new(1, -14, 0, 26), 22)
local upgradeScroll = makeScroll(upgradePickerPanel, UDim2.fromOffset(5, 38), UDim2.new(1, -10, 1, -43), 21)
local selectedInv, selectedData
local wins, fails, upgradeRunning = 0, 0, false
local function calculateUpgrade()
    if not selectedInv or not selectedData then
        chanceLabel.Text = "CHANCE  —"
        targetName.Text = "Select a skin and multiplier"
        targetValue.Text = "—"
        for _, child in ipairs(targetArt:GetChildren()) do child:Destroy() end
        makeLabel(targetArt, "?", 17, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), palette.muted, Enum.Font.GothamBold, 6).TextXAlignment = Enum.TextXAlignment.Center
        return nil
    end
    local multiplier = tonumber(multiplierBox.Text)
    local extra = math.max(0, math.floor(tonumber(extraBox.Text) or 0))
    local baseValue = tonumber(selectedData.value) or 0
    if not multiplier or multiplier <= 1 or baseValue <= 0 then
        chanceLabel.Text = "CHANCE  INVALID"
        targetName.Text = "Multiplier must be greater than x1"
        targetValue.Text = "—"
        return nil
    end
    local stake = baseValue + extra
    local targetId = Economy.presetTarget(stake, multiplier, Catalog)
    local target = targetId and getItem(targetId)
    if not target then
        chanceLabel.Text = "CHANCE  —"
        targetName.Text = "No target at this multiplier"
        targetValue.Text = "Try a lower multiplier"
        return nil
    end
    local chanceOk, chance = pcall(Economy.chance, stake, tonumber(target.value) or 0, nil, nil)
    if not chanceOk or type(chance) ~= "number" then
        chance = Economy.honestChance(stake, tonumber(target.value) or 0)
    end
    if type(chance) ~= "number" or chance <= 0 then
        chanceLabel.Text = "CHANCE  IMPOSSIBLE"
        targetName.Text = target.name or target.id
        targetValue.Text = money(target.value or 0) .. " Stars"
        return nil
    end
    chanceLabel.Text = string.format("CHANCE  %.2f%%", chance * 100)
    targetName.Text = target.name or target.id
    targetValue.Text = money(target.value or 0) .. " Stars  •  stake " .. money(stake)
    for _, child in ipairs(targetArt:GetChildren()) do child:Destroy() end
    if Art and type(Art.image) == "function" then
        pcall(Art.image, targetArt, target.art, 2, 2, 50, 50, Enum.ScaleType.Fit)
    end
    return targetId, target, stake, chance
end
local function renderUpgradePicker(shouldRefresh)
    if shouldRefresh ~= false then
        local refreshed, err = refreshProfile()
        if not refreshed then setStatus(upgradeStatus, "Inventory refresh failed: " .. tostring(err), palette.red); return end
    end
    clearRows(upgradeScroll)
    local query = string.lower(upgradeSearch.Text or "")
    local entries = inventoryEntries(false)
    local shown = 0
    for _, entry in ipairs(entries) do
        local data, inv = entry.data, entry.inv
        local name = string.lower(tostring(data.name or data.id))
        if query == "" or string.find(name, query, 1, true) then
            shown += 1
            local disabled = not entry.eligible
            local row = makeItemRow(upgradeScroll, entry, money(data.value or 0) .. " Stars", selectedInv and selectedInv.uid == inv.uid, nil, disabled, shown)
            row.Activated:Connect(function()
                if disabled then setStatus(upgradeStatus, "This item is locked or cannot be upgraded", palette.amber); return end
                selectedInv, selectedData = inv, data
                upgradeSelectedLabel.Text = (data.name or data.id) .. "  •  " .. money(data.value or 0)
                for _, child in ipairs(upgradePreview:GetChildren()) do child:Destroy() end
                if Art and type(Art.image) == "function" then pcall(Art.image, upgradePreview, data.art, 2, 2, 49, 49, Enum.ScaleType.Fit) end
                upgradePickerPanel.Visible = false
                calculateUpgrade()
                setStatus(upgradeStatus, "Selected • " .. tostring(data.name or data.id), palette.green)
            end)
        end
    end
    if shown == 0 then
        local msg = makeLabel(upgradeScroll, #entries == 0 and "Inventory is empty" or "No items match this search", 10, UDim2.fromOffset(9, 9), UDim2.new(1, -18, 0, 22), palette.amber, Enum.Font.Gotham, 23)
        msg.ZIndex = 23
    end
end
upgradeChoose.Activated:Connect(function()
    upgradePickerPanel.Visible = not upgradePickerPanel.Visible
    if upgradePickerPanel.Visible then renderUpgradePicker() end
end)
inventoryRefresh.Activated:Connect(function()
    local refreshed, err = refreshProfile()
    if refreshed then setStatus(upgradeStatus, "Inventory refreshed • " .. #inventoryEntries(false) .. " items", palette.green)
    else setStatus(upgradeStatus, tostring(err), palette.red) end
end)
upgradeSearch:GetPropertyChangedSignal("Text"):Connect(function() if upgradePickerPanel.Visible then renderUpgradePicker(false) end end)
multiplierBox:GetPropertyChangedSignal("Text"):Connect(calculateUpgrade)
extraBox:GetPropertyChangedSignal("Text"):Connect(calculateUpgrade)
plusStep.Activated:Connect(function()
    local current = math.max(0, math.floor(tonumber(extraBox.Text) or 0))
    local step = math.max(1, math.floor(tonumber(stepBox.Text) or 1))
    extraBox.Text = tostring(current + step)
end)
minusStep.Activated:Connect(function()
    local current = math.max(0, math.floor(tonumber(extraBox.Text) or 0))
    local step = math.max(1, math.floor(tonumber(stepBox.Text) or 1))
    extraBox.Text = tostring(math.max(0, current - step))
end)

local function startUpgrade()
    if upgradeRunning then
        upgradeRunning = false
        upgradeStart.Text = "START AUTO"
        setStatus(upgradeStatus, "Stopping after current request...", palette.amber)
        return
    end
    if not selectedInv or not selectedData then setStatus(upgradeStatus, "Choose a skin first", palette.amber); return end
    local multiplier = tonumber(multiplierBox.Text)
    if not multiplier or multiplier <= 1 then setStatus(upgradeStatus, "Multiplier must be greater than 1", palette.red); return end
    local refreshed, err = refreshProfile()
    if not refreshed then setStatus(upgradeStatus, "Profile error: " .. tostring(err), palette.red); return end
    local eligible = inventoryEntries(true)
    local startIndex, selectedFound = 1, false
    for index, entry in ipairs(eligible) do
        if entry.inv.uid == selectedInv.uid then startIndex = index; selectedFound = true; break end
    end
    if not selectedFound then setStatus(upgradeStatus, "Selected skin is no longer eligible", palette.red); return end
    local queue = {}
    for offset = 0, #eligible - 1 do
        local index = ((startIndex + offset - 1) % #eligible) + 1
        table.insert(queue, eligible[index].inv.uid)
    end
    -- The game consumes the selected input skin on both a win and a miss; queue each owned UID only once.
    if #queue == 0 then setStatus(upgradeStatus, "Selected skin is no longer available", palette.red); return end
    upgradeRunning = true
    upgradeStart.Text = "STOP"
    task.spawn(function()
        local attempted = 0
        local halted = false
        for _, uid in ipairs(queue) do
            if not upgradeRunning then break end
            local stateOk, stateErr = refreshProfile()
            if not stateOk then
                setStatus(upgradeStatus, "Stopped: " .. tostring(stateErr), palette.red)
                halted = true
                break
            end
            local current
            for _, inv in ipairs(profile.items or {}) do
                if inv.uid == uid then current = inv; break end
            end
            if current and not current.locked then
                local data = getItem(current.id)
                if data and not data.noPrice and (tonumber(data.value) or 0) > 0 then
                    selectedInv, selectedData = current, data
                    upgradeSelectedLabel.Text = (data.name or data.id) .. "  •  " .. money(data.value or 0)
                    for _, child in ipairs(upgradePreview:GetChildren()) do child:Destroy() end
                    if Art and type(Art.image) == "function" then
                        pcall(Art.image, upgradePreview, data.art, 2, 2, 49, 49, Enum.ScaleType.Fit)
                    end
                    local currentMultiplier = tonumber(multiplierBox.Text)
                    if not currentMultiplier or currentMultiplier <= 1 then
                        setStatus(upgradeStatus, "Multiplier must be greater than 1", palette.red)
                        halted = true
                        break
                    end
                    local targetId, target, stake, chance = calculateUpgrade()
                    if not targetId then
                        setStatus(upgradeStatus, "No valid target for " .. tostring(data.name or data.id), palette.red)
                        halted = true
                        break
                    end
                    local extra = math.max(0, math.floor(tonumber(extraBox.Text) or 0))
                    if (tonumber(profile.credits) or 0) < extra then
                        setStatus(upgradeStatus, "Not enough Stars for additional stake", palette.red)
                        halted = true
                        break
                    end
                    setStatus(upgradeStatus, string.format("Attempt %d • %s • %.2f%%", attempted + 1, data.name or data.id, chance * 100), palette.amber)
                    local result, requestErr = invoke("upgrade", {ids = {uid}, credits = extra, target = targetId, turbo = true})
                    if not result or result.ok ~= true then
                        setStatus(upgradeStatus, "Upgrade failed: " .. tostring(requestErr or (result and result.error)), palette.red)
                        halted = true
                        break
                    end
                    attempted += 1
                    if result.win == true then wins += 1 else fails += 1 end
                    upgradeStats.Text = string.format("WINS %d   •   FAILS %d", wins, fails)
                    refreshProfile()
                    updateBalance()
                    task.wait(0.3)
                end
            end
        end
        local manuallyStopped = not upgradeRunning
        upgradeRunning = false
        upgradeStart.Text = "START AUTO"
        if manuallyStopped then
            setStatus(upgradeStatus, "Stopped • " .. attempted .. " attempts", palette.muted)
        elseif not halted then
            setStatus(upgradeStatus, "Queue finished • " .. attempted .. " attempts", palette.green)
        end
        if selectedInv then
            local stillOwned = false
            for _, inv in ipairs((profile and profile.items) or {}) do
                if inv.uid == selectedInv.uid then stillOwned = true; break end
            end
            if not stillOwned then
                selectedInv, selectedData = nil, nil
                upgradeSelectedLabel.Text = "Select next skin"
                calculateUpgrade()
            end
        end
    end)
end
upgradeStart.Activated:Connect(startUpgrade)

-- CONTRACT PAGE
makeLabel(contractPage, "CONTRACT BUILDER", 11, UDim2.fromOffset(0, 0), UDim2.fromOffset(190, 18), palette.muted, Enum.Font.GothamBold)
local contractRefresh = makeButton(contractPage, "REFRESH", UDim2.new(1, -74, 0, -1), UDim2.fromOffset(74, 22), nil, palette.panel2)
local contractInfo = makeLabel(contractPage, "Select 3–10 eligible skins", 9, UDim2.fromOffset(0, 25), UDim2.new(1, -130, 0, 22), palette.muted, Enum.Font.Gotham)
local contractTotals = makeLabel(contractPage, "0 / 10  •  0 Stars", 9, UDim2.new(1, -145, 0, 25), UDim2.fromOffset(145, 22), palette.green, Enum.Font.GothamBold)
contractTotals.TextXAlignment = Enum.TextXAlignment.Right
local contractSearch = makeInput(contractPage, "Search inventory...", "", UDim2.fromOffset(0, 51), UDim2.new(1, -112, 0, 25))
local contractRun = makeButton(contractPage, "MAKE CONTRACT", UDim2.new(1, -105, 0, 50), UDim2.fromOffset(105, 27), nil, palette.green)
local contractStatus = makeLabel(contractPage, "Ready", 8, UDim2.fromOffset(0, 80), UDim2.new(1, 0, 0, 22), palette.muted, Enum.Font.Gotham)
local contractScroll = makeScroll(contractPage, UDim2.fromOffset(0, 106), UDim2.new(1, 0, 1, -108), 10)
local contractSelected = {}
local contractRules = Economy.Contract or {}
contractInfo.Text = "Select " .. tostring(contractRules.minItems or 3) .. "–" .. tostring(contractRules.maxItems or 10) .. " skins • min " .. money(contractRules.minValue or 2000) .. " Stars"
local function updateContractTotals()
    local count, total = 0, 0
    for uid, enabled in pairs(contractSelected) do
        if enabled then
            count += 1
            for _, entry in ipairs(inventoryEntries(true)) do
                if entry.inv.uid == uid then total += tonumber(entry.data.value) or 0; break end
            end
        end
    end
    contractTotals.Text = string.format("%d / 10  •  %s Stars", count, money(total))
end
local function renderContracts(shouldRefresh)
    if shouldRefresh ~= false then
        local refreshed, err = refreshProfile()
        if not refreshed then setStatus(contractStatus, "Inventory refresh failed: " .. tostring(err), palette.red); return end
    end
    clearRows(contractScroll)
    local query = string.lower(contractSearch.Text or "")
    local entries = inventoryEntries(true)
    local shown = 0
    for _, entry in ipairs(entries) do
        local inv, data = entry.inv, entry.data
        local name = string.lower(tostring(data.name or data.id))
        if query == "" or string.find(name, query, 1, true) then
            shown += 1
            local chosen = contractSelected[inv.uid] == true
            local row = makeItemRow(contractScroll, entry, money(data.value or 0) .. " Stars", chosen, nil, false, shown)
            local mark = makeLabel(row, chosen and "✓" or "+", 14, UDim2.new(1, -24, 0.5, -9), UDim2.fromOffset(17, 18), chosen and palette.green or palette.muted, Enum.Font.GothamBold, row.ZIndex + 3)
            row.Activated:Connect(function()
                if contractSelected[inv.uid] then contractSelected[inv.uid] = nil
                else
                    local count = 0
                    for _, on in pairs(contractSelected) do if on then count += 1 end end
                    if count >= (Economy.Contract and Economy.Contract.maxItems or 10) then setStatus(contractStatus, "Maximum 10 items", palette.amber); return end
                    contractSelected[inv.uid] = true
                end
                local active = contractSelected[inv.uid] == true
                mark.Text = active and "✓" or "+"
                mark.TextColor3 = active and palette.green or palette.muted
                row.BackgroundColor3 = active and Color3.fromRGB(34, 62, 55) or palette.panel2
                updateContractTotals()
            end)
        end
    end
    if shown == 0 then makeLabel(contractScroll, #entries == 0 and "No eligible inventory items" or "No items match this search", 10, UDim2.fromOffset(9, 9), UDim2.new(1, -18, 0, 22), palette.amber, Enum.Font.Gotham, 12) end
    updateContractTotals()
end
contractRefresh.Activated:Connect(renderContracts)
contractSearch:GetPropertyChangedSignal("Text"):Connect(function() renderContracts(false) end)
contractRun.Activated:Connect(function()
    local refreshed, refreshErr = refreshProfile()
    if not refreshed then setStatus(contractStatus, "Profile error: " .. tostring(refreshErr), palette.red); return end
    local ids, total = {}, 0
    for uid, enabled in pairs(contractSelected) do
        if enabled then
            for _, entry in ipairs(inventoryEntries(true)) do
                if entry.inv.uid == uid then table.insert(ids, uid); total += tonumber(entry.data.value) or 0; break end
            end
        end
    end
    local rules = Economy.Contract or {}
    local minItems, maxItems = tonumber(rules.minItems) or 3, tonumber(rules.maxItems) or 10
    local minValue, maxValue = tonumber(rules.minValue) or 2000, tonumber(rules.maxValue) or 500000000
    if #ids < minItems or #ids > maxItems then setStatus(contractStatus, "Select " .. minItems .. "–" .. maxItems .. " items", palette.amber); return end
    if total < minValue or total > maxValue then setStatus(contractStatus, "Value must be " .. money(minValue) .. "–" .. money(maxValue), palette.amber); return end
    local result, err = invoke("contract", {ids = ids})
    if not result or result.ok ~= true then
        setStatus(contractStatus, "Contract failed: " .. tostring(err or (result and result.error)), palette.red)
        return
    end
    local reward = getItem(result.item)
    setStatus(contractStatus, "Created: " .. tostring(reward and reward.name or "new skin"), palette.green)
    contractSelected = {}
    refreshProfile()
    renderContracts()
end)
renderContracts()

-- Diagnostics are visible in the executor console and in the page statuses if data is missing.
local caseTotal = #sortedCases()
local itemTotal = 0
if type(Catalog.Items) == "table" then for _ in pairs(Catalog.Items) do itemTotal += 1 end end
local inventoryTotal = #(profile and profile.items or {})
print(string.format("[Sunset Auto Caser] Ready | cases=%d | items=%d | inventory=%d | art=%s", caseTotal, itemTotal, inventoryTotal, Art and "ready" or "fallback"))
if caseTotal == 0 then warn("[Sunset] Catalog.Cases and Catalog.CaseById both contain no case records") end
if inventoryTotal == 0 then warn("[Sunset] Profile inventory is empty; upgrade/contracts lists will correctly show empty state") end

showPage("cases")
