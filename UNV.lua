if not game:IsLoaded() then game.Loaded:Wait() end

-- Executor-safe protectgui
getgenv().protectgui = protectgui
    or (syn and syn.protect_gui)
    or (typeof(protect_gui) == "function" and protect_gui)
    or function() end

local SilentAimSettings = {
    Enabled = false,
    TeamCheck = false,
    VisibleCheck = false,
    TargetPart = "HumanoidRootPart",
    SilentAimMethod = "Raycast",
    FOVRadius = 130,
    FOVVisible = true,
    ShowSilentAimTarget = false,
    FOVTracer = false,
    MouseHitPrediction = false,
    MouseHitPredictionAmount = 0.165,
    HitChance = 100,
    AntiFriend = false,
    BoxESP = false,
    NameESP = false,
    TracerESP = false,
    ESPMaxDistance = 1000,
    AccentColor = Color3.fromRGB(120, 80, 255)
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

-- NOTE: Do NOT cache Camera methods at startup.
-- Caching causes FOV to break on executors that handle method references
-- differently, and breaks after camera changes (e.g. on respawn).
-- Always call through workspace.CurrentCamera at runtime.
local function getCamera()
    return workspace.CurrentCamera
end

local ValidTargetParts = {"Head", "HumanoidRootPart"}

local fov_circle = Drawing.new("Circle")
fov_circle.Thickness = 2
fov_circle.NumSides = 64
fov_circle.Radius = 130
fov_circle.Filled = false
fov_circle.Visible = false
fov_circle.ZIndex = 999
fov_circle.Transparency = 1
fov_circle.Color = SilentAimSettings.AccentColor

local fov_tracer = Drawing.new("Line")
fov_tracer.Thickness = 1.5
fov_tracer.Transparency = 0.8
fov_tracer.Visible = false
fov_tracer.ZIndex = 998
fov_tracer.Color = SilentAimSettings.AccentColor

local highlight_target = nil
local esp_boxes = {}

local function getDrawings(player)
    if esp_boxes[player] then return esp_boxes[player] end
    local drawings = {
        Box = Drawing.new("Square"),
        Name = Drawing.new("Text"),
        Tracer = Drawing.new("Line")
    }
    drawings.Box.Thickness = 1
    drawings.Box.Filled = false
    drawings.Box.Transparency = 1
    drawings.Name.Size = 14
    drawings.Name.Center = true
    drawings.Name.Outline = true
    drawings.Name.Font = 2
    drawings.Tracer.Thickness = 1
    drawings.Tracer.Transparency = 0.6
    esp_boxes[player] = drawings
    return drawings
end

local function hideESP(drawings)
    if not drawings then return end
    drawings.Box.Visible = false
    drawings.Name.Visible = false
    drawings.Tracer.Visible = false
end

local ExpectedArguments = {
    FindPartOnRayWithIgnoreList = {
        ArgCountRequired = 3,
        Args = {"Instance", "Ray", "table", "boolean", "boolean"}
    },
    FindPartOnRayWithWhitelist = {
        ArgCountRequired = 3,
        Args = {"Instance", "Ray", "table", "boolean"}
    },
    FindPartOnRay = {
        ArgCountRequired = 2,
        Args = {"Instance", "Ray", "Instance", "boolean", "boolean"}
    },
    Raycast = {
        ArgCountRequired = 3,
        Args = {"Instance", "Vector3", "Vector3", "RaycastParams"}
    }
}

local function CalculateChance(Percentage)
    return math.random(1, 100) <= (Percentage or 100)
end

local MainFileName = "UniversalSilentAim"

if not isfolder(MainFileName) then
    makefolder(MainFileName)
end
if not isfolder(string.format("%s/%s", MainFileName, tostring(game.PlaceId))) then
    makefolder(string.format("%s/%s", MainFileName, tostring(game.PlaceId)))
end

local Files = listfiles(string.format("%s/%s", "UniversalSilentAim", tostring(game.PlaceId)))

local function GetFiles()
    local out = {}
    for i = 1, #Files do
        local file = Files[i]
        if file:sub(-4) == '.lua' then
            local pos = file:find('.lua', 1, true)
            local start = pos
            local char = file:sub(pos, pos)
            while char ~= '/' and char ~= '\\' and char ~= '' do
                pos = pos - 1
                char = file:sub(pos, pos)
            end
            if char == '/' or char == '\\' then
                table.insert(out, file:sub(pos + 1, start - 1))
            end
        end
    end
    return out
end

local function UpdateFile(FileName)
    assert(FileName or FileName == "string", "oopsies")
    writefile(string.format("%s/%s/%s.lua", MainFileName, tostring(game.PlaceId), FileName), HttpService:JSONEncode(SilentAimSettings))
end

local function LoadFile(FileName)
    assert(FileName or FileName == "string", "oopsies")
    local File = string.format("%s/%s/%s.lua", MainFileName, tostring(game.PlaceId), FileName)
    local ConfigData = HttpService:JSONDecode(readfile(File))
    for Index, Value in next, ConfigData do
        SilentAimSettings[Index] = Value
    end
end

-- FIX: Always use workspace.CurrentCamera directly to avoid stale references.
local function getPositionOnScreen(Vector)
    local Camera = getCamera()
    local Vec3, OnScreen = Camera:WorldToScreenPoint(Vector)
    return Vector2.new(Vec3.X, Vec3.Y), OnScreen
end

local function ValidateArguments(Args, RayMethod)
    local Matches = 0
    if #Args < RayMethod.ArgCountRequired then
        return false
    end
    for Pos, Argument in next, Args do
        if typeof(Argument) == RayMethod.Args[Pos] then
            Matches = Matches + 1
        end
    end
    return Matches >= RayMethod.ArgCountRequired
end

local function getDirection(Origin, Position)
    return (Position - Origin).Unit * 1000
end

local function getMousePosition()
    return UserInputService:GetMouseLocation()
end

local function IsPlayerVisible(Player)
    local Camera = getCamera()
    local PlayerCharacter = Player.Character
    local LocalPlayerCharacter = LocalPlayer.Character
    if not (PlayerCharacter and LocalPlayerCharacter) then
        return false
    end
    local PlayerRoot = PlayerCharacter:FindFirstChild(SilentAimSettings.TargetPart)
        or PlayerCharacter:FindFirstChild("HumanoidRootPart")
    if not PlayerRoot then
        return false
    end
    local CastPoints = {PlayerRoot.Position}
    local IgnoreList = {LocalPlayerCharacter, PlayerCharacter}
    local ObscuringObjects = #Camera:GetPartsObscuringTarget(CastPoints, IgnoreList)
    return ObscuringObjects == 0
end

-- FIX: AntiFriend now uses Roblox's built-in IsFriendsWith API instead of a
-- hardcoded name list. Works correctly for all players without manual setup.
local friendCache = {}
local friendCacheTime = {}
local FRIEND_CACHE_TTL = 10 -- seconds

local function IsFriend(Player)
    if not SilentAimSettings.AntiFriend then
        return false
    end
    local userId = Player.UserId
    local now = tick()
    -- Use cached result to avoid repeated API calls each frame
    if friendCache[userId] ~= nil and (now - (friendCacheTime[userId] or 0)) < FRIEND_CACHE_TTL then
        return friendCache[userId]
    end
    local ok, result = pcall(function()
        return LocalPlayer:IsFriendsWith(userId)
    end)
    local isFriend = ok and result or false
    friendCache[userId] = isFriend
    friendCacheTime[userId] = now
    return isFriend
end

-- FIX: FOV distance measured from viewport center (standard for silent aim FOV).
-- Uses live camera each call so it works correctly on all executors and after
-- camera changes.
local function getClosestPlayer()
    if not SilentAimSettings.TargetPart then return end
    local Camera = getCamera()
    local Closest = nil
    local DistanceToMouse = nil
    local viewportCenter = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)

    for _, Player in next, Players:GetPlayers() do
        if Player == LocalPlayer then continue end
        if IsFriend(Player) then continue end
        if SilentAimSettings.TeamCheck and Player.Team == LocalPlayer.Team then continue end

        local Character = Player.Character
        if not Character then continue end

        if SilentAimSettings.VisibleCheck and not IsPlayerVisible(Player) then continue end

        local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
        local Humanoid = Character:FindFirstChild("Humanoid")
        if not HumanoidRootPart or not Humanoid or Humanoid.Health <= 0 then continue end

        local ScreenPosition, OnScreen = getPositionOnScreen(HumanoidRootPart.Position)
        if not OnScreen then continue end

        local Distance = (viewportCenter - ScreenPosition).Magnitude
        if Distance <= (DistanceToMouse or SilentAimSettings.FOVRadius or 2000) then
            local targetPart
            if SilentAimSettings.TargetPart == "Random" then
                targetPart = Character[ValidTargetParts[math.random(1, #ValidTargetParts)]]
            else
                targetPart = Character:FindFirstChild(SilentAimSettings.TargetPart)
                    or Character:FindFirstChild("HumanoidRootPart")
            end
            if targetPart then
                Closest = targetPart
                DistanceToMouse = Distance
            end
        end
    end
    return Closest
end

-- GUI Setup
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "SilentAimUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
protectgui(ScreenGui)
ScreenGui.Parent = game:GetService("CoreGui") or LocalPlayer.PlayerGui

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 340, 0, 480)
MainFrame.Position = UDim2.new(0.5, -160, 0.5, -230)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 8)
Corner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke", MainFrame)
MainStroke.Color = SilentAimSettings.AccentColor
MainStroke.Thickness = 1.5

local Title = Instance.new("TextLabel")
Title.Name = "Title"
Title.Size = UDim2.new(1, 0, 0, 40)
Title.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
Title.BorderSizePixel = 0
Title.Text = "XEIOA HUB | UNIVERSAL"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 16
Title.Font = Enum.Font.GothamBold
Title.Parent = MainFrame

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 8)
TitleCorner.Parent = Title

local ContentFrame = Instance.new("ScrollingFrame")
ContentFrame.Name = "Content"
ContentFrame.Size = UDim2.new(1, -20, 1, -60)
ContentFrame.Position = UDim2.new(0, 10, 0, 50)
ContentFrame.BackgroundTransparency = 1
ContentFrame.BorderSizePixel = 0
ContentFrame.ScrollBarThickness = 4
ContentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ContentFrame.ScrollBarImageColor3 = SilentAimSettings.AccentColor
ContentFrame.ScrollingDirection = Enum.ScrollingDirection.Y
ContentFrame.Parent = MainFrame

local UIListLayout = Instance.new("UIListLayout")
UIListLayout.Padding = UDim.new(0, 6)
UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayout.Parent = ContentFrame

local function CreateToggle(text, settingKey, callback)
    local ToggleFrame = Instance.new("Frame")
    ToggleFrame.Size = UDim2.new(1, 0, 0, 38)
    ToggleFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
    ToggleFrame.BorderSizePixel = 0
    ToggleFrame.Parent = ContentFrame

    local Stroke = Instance.new("UIStroke", ToggleFrame)
    Stroke.Color = Color3.fromRGB(45, 45, 50)
    Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local ToggleCorner = Instance.new("UICorner")
    ToggleCorner.CornerRadius = UDim.new(0, 6)
    ToggleCorner.Parent = ToggleFrame

    local Label = Instance.new("TextLabel")
    Label.Size = UDim2.new(0.7, 0, 1, 0)
    Label.Position = UDim2.new(0, 10, 0, 0)
    Label.BackgroundTransparency = 1
    Label.Text = text
    Label.TextColor3 = Color3.fromRGB(200, 200, 200)
    Label.TextSize = 14
    Label.Font = Enum.Font.Gotham
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = ToggleFrame

    local ToggleButton = Instance.new("TextButton")
    ToggleButton.Size = UDim2.new(0, 50, 0, 25)
    ToggleButton.Position = UDim2.new(1, -60, 0.5, -12.5)
    ToggleButton.BackgroundColor3 = SilentAimSettings[settingKey] and SilentAimSettings.AccentColor or Color3.fromRGB(45, 45, 50)
    ToggleButton.BorderSizePixel = 0
    ToggleButton.Text = SilentAimSettings[settingKey] and "ON" or "OFF"
    ToggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ToggleButton.TextSize = 12
    ToggleButton.Font = Enum.Font.GothamBold
    ToggleButton.Parent = ToggleFrame

    local ButtonCorner = Instance.new("UICorner")
    ButtonCorner.CornerRadius = UDim.new(0, 4)
    ButtonCorner.Parent = ToggleButton

    ToggleButton.MouseButton1Click:Connect(function()
        SilentAimSettings[settingKey] = not SilentAimSettings[settingKey]
        ToggleButton.BackgroundColor3 = SilentAimSettings[settingKey] and SilentAimSettings.AccentColor or Color3.fromRGB(45, 45, 50)
        ToggleButton.Text = SilentAimSettings[settingKey] and "ON" or "OFF"
        if callback then callback(SilentAimSettings[settingKey]) end
    end)

    return ToggleButton
end

local function CreateDropdown(text, settingKey, options)
    local DropdownFrame = Instance.new("Frame")
    DropdownFrame.Size = UDim2.new(1, 0, 0, 75)
    DropdownFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
    DropdownFrame.BorderSizePixel = 0
    DropdownFrame.ClipsDescendants = true
    DropdownFrame.Parent = ContentFrame

    local Stroke = Instance.new("UIStroke", DropdownFrame)
    Stroke.Color = Color3.fromRGB(45, 45, 50)

    local DropdownCorner = Instance.new("UICorner")
    DropdownCorner.CornerRadius = UDim.new(0, 6)
    DropdownCorner.Parent = DropdownFrame

    local Label = Instance.new("TextLabel")
    Label.Size = UDim2.new(1, -20, 0, 25)
    Label.Position = UDim2.new(0, 10, 0, 5)
    Label.BackgroundTransparency = 1
    Label.Text = text
    Label.TextColor3 = Color3.fromRGB(200, 200, 200)
    Label.TextSize = 14
    Label.Font = Enum.Font.Gotham
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = DropdownFrame

    local DropdownButton = Instance.new("TextButton")
    DropdownButton.Size = UDim2.new(1, -20, 0, 30)
    DropdownButton.Position = UDim2.new(0, 10, 0, 38)
    DropdownButton.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    DropdownButton.BorderSizePixel = 0
    DropdownButton.Text = SilentAimSettings[settingKey]
    DropdownButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    DropdownButton.TextSize = 14
    DropdownButton.Font = Enum.Font.Gotham
    DropdownButton.Parent = DropdownFrame

    local ButtonCorner = Instance.new("UICorner")
    ButtonCorner.CornerRadius = UDim.new(0, 4)
    ButtonCorner.Parent = DropdownButton

    local isOpen = false
    local OptionsFrame = Instance.new("Frame")
    OptionsFrame.Size = UDim2.new(1, -20, 0, #options * 30)
    OptionsFrame.Position = UDim2.new(0, 10, 0, 75)
    OptionsFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    OptionsFrame.BorderSizePixel = 0
    OptionsFrame.Visible = false
    OptionsFrame.ZIndex = 10
    OptionsFrame.Parent = DropdownFrame

    local OptionsCorner = Instance.new("UICorner")
    OptionsCorner.CornerRadius = UDim.new(0, 4)
    OptionsCorner.Parent = OptionsFrame

    for i, option in ipairs(options) do
        local OptionBtn = Instance.new("TextButton")
        OptionBtn.Size = UDim2.new(1, 0, 0, 30)
        OptionBtn.Position = UDim2.new(0, 0, 0, (i - 1) * 30)
        OptionBtn.BackgroundTransparency = 1
        OptionBtn.BorderSizePixel = 0
        OptionBtn.Text = option
        OptionBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
        OptionBtn.TextSize = 13
        OptionBtn.Font = Enum.Font.Gotham
        OptionBtn.ZIndex = 11
        OptionBtn.Parent = OptionsFrame

        OptionBtn.MouseButton1Click:Connect(function()
            SilentAimSettings[settingKey] = option
            DropdownButton.Text = option
            isOpen = false
            OptionsFrame.Visible = false
            DropdownFrame.Size = UDim2.new(1, 0, 0, 75)
        end)

        Instance.new("UIStroke", OptionBtn).Color = Color3.fromRGB(40, 40, 45)
    end

    DropdownButton.MouseButton1Click:Connect(function()
        isOpen = not isOpen
        OptionsFrame.Visible = isOpen
        DropdownFrame.Size = UDim2.new(1, 0, 0, isOpen and (80 + #options * 30) or 75)
    end)

    return DropdownButton
end

local function CreateSlider(text, settingKey, min, max, default, isFloat)
    local SliderFrame = Instance.new("Frame")
    SliderFrame.Size = UDim2.new(1, 0, 0, 75)
    SliderFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
    SliderFrame.BorderSizePixel = 0
    SliderFrame.Parent = ContentFrame

    local Stroke = Instance.new("UIStroke", SliderFrame)
    Stroke.Color = Color3.fromRGB(45, 45, 50)

    local SliderCorner = Instance.new("UICorner")
    SliderCorner.CornerRadius = UDim.new(0, 6)
    SliderCorner.Parent = SliderFrame

    local Label = Instance.new("TextLabel")
    Label.Size = UDim2.new(0.6, 0, 0, 25)
    Label.Position = UDim2.new(0, 10, 0, 5)
    Label.BackgroundTransparency = 1
    Label.Text = text
    Label.TextColor3 = Color3.fromRGB(200, 200, 200)
    Label.TextSize = 14
    Label.Font = Enum.Font.Gotham
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = SliderFrame

    local ValueLabel = Instance.new("TextLabel")
    ValueLabel.Size = UDim2.new(0.3, 0, 0, 25)
    ValueLabel.Position = UDim2.new(0.7, 0, 0, 5)
    ValueLabel.BackgroundTransparency = 1
    ValueLabel.Text = tostring(default)
    ValueLabel.TextColor3 = SilentAimSettings.AccentColor
    ValueLabel.TextSize = 14
    ValueLabel.Font = Enum.Font.GothamBold
    ValueLabel.TextXAlignment = Enum.TextXAlignment.Right
    ValueLabel.Parent = SliderFrame

    local SliderBar = Instance.new("Frame")
    SliderBar.Size = UDim2.new(1, -20, 0, 8)
    SliderBar.Position = UDim2.new(0, 10, 0, 45)
    SliderBar.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
    SliderBar.BorderSizePixel = 0
    SliderBar.Parent = SliderFrame

    local BarCorner = Instance.new("UICorner")
    BarCorner.CornerRadius = UDim.new(0, 4)
    BarCorner.Parent = SliderBar

    local Fill = Instance.new("Frame")
    Fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
    Fill.BackgroundColor3 = SilentAimSettings.AccentColor
    Fill.BorderSizePixel = 0
    Fill.Parent = SliderBar

    local FillCorner = Instance.new("UICorner")
    FillCorner.CornerRadius = UDim.new(0, 4)
    FillCorner.Parent = Fill

    local Dragging = false

    local function UpdateSlider(input)
        local pos = math.clamp(
            (input.Position.X - SliderBar.AbsolutePosition.X) / SliderBar.AbsoluteSize.X,
            0, 1
        )
        local value = min + (pos * (max - min))
        if not isFloat then
            value = math.floor(value)
        else
            value = math.floor(value * 1000) / 1000
        end
        SilentAimSettings[settingKey] = value
        ValueLabel.Text = tostring(value)
        Fill.Size = UDim2.new(pos, 0, 1, 0)
    end

    SliderBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            Dragging = true
            UpdateSlider(input)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if Dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            UpdateSlider(input)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            Dragging = false
        end
    end)

    return SliderBar
end

local function CreateInput(text, callback)
    local InputFrame = Instance.new("Frame")
    InputFrame.Size = UDim2.new(1, 0, 0, 75)
    InputFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
    InputFrame.BorderSizePixel = 0
    InputFrame.Parent = ContentFrame

    local Stroke = Instance.new("UIStroke", InputFrame)
    Stroke.Color = Color3.fromRGB(45, 45, 50)

    local InputCorner = Instance.new("UICorner")
    InputCorner.CornerRadius = UDim.new(0, 6)
    InputCorner.Parent = InputFrame

    local Label = Instance.new("TextLabel")
    Label.Size = UDim2.new(1, -20, 0, 25)
    Label.Position = UDim2.new(0, 10, 0, 5)
    Label.BackgroundTransparency = 1
    Label.Text = text
    Label.TextColor3 = Color3.fromRGB(200, 200, 200)
    Label.TextSize = 14
    Label.Font = Enum.Font.Gotham
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = InputFrame

    local TextBox = Instance.new("TextBox")
    TextBox.Size = UDim2.new(1, -20, 0, 30)
    TextBox.Position = UDim2.new(0, 10, 0, 35)
    TextBox.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    TextBox.BorderSizePixel = 0
    TextBox.Text = ""
    TextBox.PlaceholderText = "Enter name..."
    TextBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    TextBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 120)
    TextBox.TextSize = 14
    TextBox.Font = Enum.Font.Gotham
    TextBox.ClearTextOnFocus = false
    TextBox.Parent = InputFrame

    local BoxCorner = Instance.new("UICorner")
    BoxCorner.CornerRadius = UDim.new(0, 4)
    BoxCorner.Parent = TextBox

    TextBox.FocusLost:Connect(function()
        if callback then callback(TextBox.Text) end
    end)

    return TextBox
end

local function CreateButton(text, callback)
    local ButtonFrame = Instance.new("Frame")
    ButtonFrame.Size = UDim2.new(1, 0, 0, 40)
    ButtonFrame.BackgroundTransparency = 1
    ButtonFrame.Parent = ContentFrame

    local Button = Instance.new("TextButton")
    Button.Size = UDim2.new(1, 0, 1, 0)
    Button.BackgroundColor3 = SilentAimSettings.AccentColor
    Button.BorderSizePixel = 0
    Button.Text = text
    Button.TextColor3 = Color3.fromRGB(255, 255, 255)
    Button.TextSize = 14
    Button.Font = Enum.Font.GothamBold
    Button.Parent = ButtonFrame

    local BtnCorner = Instance.new("UICorner")
    BtnCorner.CornerRadius = UDim.new(0, 6)
    BtnCorner.Parent = Button

    Button.MouseButton1Click:Connect(function()
        if callback then callback() end
    end)

    return Button
end

local function CreateSection(text)
    local Section = Instance.new("TextLabel")
    Section.Size = UDim2.new(1, 0, 0, 25)
    Section.BackgroundTransparency = 1
    Section.Text = text
    Section.TextColor3 = SilentAimSettings.AccentColor
    Section.TextSize = 14
    Section.Font = Enum.Font.GothamBold
    Section.TextXAlignment = Enum.TextXAlignment.Left
    Section.Parent = ContentFrame
    return Section
end

CreateSection("Main Settings")
CreateToggle("Enabled", "Enabled")
CreateToggle("Team Check", "TeamCheck")
CreateToggle("SA Wallcheck", "VisibleCheck")
CreateToggle("Anti Friend", "AntiFriend")
CreateDropdown("Target Part", "TargetPart", {"Head", "HumanoidRootPart", "Random"})
CreateDropdown("Silent Aim Method", "SilentAimMethod", {"Raycast", "FindPartOnRay", "FindPartOnRayWithWhitelist", "FindPartOnRayWithIgnoreList", "Mouse.Hit/Target"})
CreateSlider("Hit Chance", "HitChance", 0, 100, 100, false)

CreateSection("FOV Settings")
CreateToggle("Show FOV Circle", "FOVVisible")
CreateSlider("FOV Radius", "FOVRadius", 10, 800, 130, false)
CreateToggle("FOV Tracer", "FOVTracer")
CreateToggle("Highlight Target", "ShowSilentAimTarget")

CreateSection("ESP Settings")
CreateToggle("Box ESP", "BoxESP")
CreateToggle("Name ESP", "NameESP")
CreateToggle("Tracer ESP", "TracerESP")
CreateSlider("ESP Max Distance", "ESPMaxDistance", 50, 5000, 1000, false)

CreateSection("Prediction")
CreateToggle("Mouse.Hit/Target Prediction", "MouseHitPrediction")
CreateSlider("Prediction Amount", "MouseHitPredictionAmount", 0.165, 1, 0.165, true)

CreateSection("Configuration")
local configName = ""
CreateInput("Config Name", function(text)
    configName = text
end)
CreateButton("Create Config", function()
    if configName ~= "" then
        UpdateFile(configName)
    end
end)

local saveDropdown = CreateDropdown("Save Config", "TargetPart", GetFiles())
CreateButton("Save Config", function()
    if SilentAimSettings.TargetPart then
        UpdateFile(SilentAimSettings.TargetPart)
    end
end)

local loadDropdown = CreateDropdown("Load Config", "TargetPart", GetFiles())
CreateButton("Load Config", function()
    local files = GetFiles()
    if table.find(files, SilentAimSettings.TargetPart) then
        LoadFile(SilentAimSettings.TargetPart)
    end
end)

local OpenButton = Instance.new("TextButton")
OpenButton.Name = "OpenButton"
OpenButton.Size = UDim2.new(0, 50, 0, 50)
OpenButton.Position = UDim2.new(0, 20, 0.5, -25)
OpenButton.BackgroundColor3 = SilentAimSettings.AccentColor
OpenButton.BorderSizePixel = 0
OpenButton.Text = "SA"
OpenButton.TextColor3 = Color3.fromRGB(255, 255, 255)
OpenButton.TextSize = 18
OpenButton.Font = Enum.Font.GothamBold
OpenButton.Visible = false
OpenButton.Parent = ScreenGui

local OpenCorner = Instance.new("UICorner")
OpenCorner.CornerRadius = UDim.new(1, 0)
OpenCorner.Parent = OpenButton

Instance.new("UIStroke", OpenButton).Thickness = 2

OpenButton.MouseButton1Click:Connect(function()
    MainFrame.Visible = not MainFrame.Visible
    OpenButton.Visible = not MainFrame.Visible
end)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 30, 0, 30)
CloseBtn.Position = UDim2.new(1, -35, 0, 2.5)
CloseBtn.BackgroundTransparency = 1
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
CloseBtn.TextSize = 18
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = Title

CloseBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
    OpenButton.Visible = true
end)

UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.RightShift then
        MainFrame.Visible = not MainFrame.Visible
        OpenButton.Visible = not MainFrame.Visible
    end
end)

local function updateHighlight()
    if SilentAimSettings.ShowSilentAimTarget and SilentAimSettings.Enabled then
        local target = getClosestPlayer()
        if target then
            local character = target.Parent
            if highlight_target and highlight_target.Adornee ~= character then
                highlight_target:Destroy()
                highlight_target = nil
            end
            if not highlight_target then
                highlight_target = Instance.new("Highlight")
                highlight_target.FillColor = SilentAimSettings.AccentColor
                highlight_target.OutlineColor = Color3.fromRGB(255, 255, 255)
                highlight_target.FillTransparency = 0.5
                highlight_target.OutlineTransparency = 0
                highlight_target.Adornee = character
                highlight_target.Parent = ScreenGui
            end
        else
            if highlight_target then
                highlight_target:Destroy()
                highlight_target = nil
            end
        end
    else
        if highlight_target then
            highlight_target:Destroy()
            highlight_target = nil
        end
    end
end

Players.PlayerRemoving:Connect(function(player)
    -- Clean up friend cache on player removal
    friendCache[player.UserId] = nil
    friendCacheTime[player.UserId] = nil
    if esp_boxes[player] then
        esp_boxes[player].Box:Remove()
        esp_boxes[player].Name:Remove()
        esp_boxes[player].Tracer:Remove()
        esp_boxes[player] = nil
    end
end)

-- Render loop
coroutine.resume(coroutine.create(function()
    while true do
        RunService.RenderStepped:Wait()
        local Camera = getCamera()

        -- FOV Circle: always centered on screen center, always uses live camera
        if SilentAimSettings.FOVVisible and SilentAimSettings.Enabled then
            fov_circle.Visible = true
            fov_circle.Radius = SilentAimSettings.FOVRadius
            fov_circle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
            fov_circle.Color = SilentAimSettings.AccentColor
        else
            fov_circle.Visible = false
        end

        -- FOV Tracer
        if SilentAimSettings.FOVTracer and SilentAimSettings.Enabled then
            local target = getClosestPlayer()
            if target then
                local screenPos, onScreen = getPositionOnScreen(target.Position)
                if onScreen then
                    fov_tracer.Visible = true
                    fov_tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
                    fov_tracer.To = screenPos
                    fov_tracer.Color = SilentAimSettings.AccentColor
                else
                    fov_tracer.Visible = false
                end
            else
                fov_tracer.Visible = false
            end
        else
            fov_tracer.Visible = false
        end

        -- ESP
        local espEnabled = SilentAimSettings.BoxESP or SilentAimSettings.NameESP or SilentAimSettings.TracerESP
        if espEnabled then
            for _, Player in next, Players:GetPlayers() do
                local drawings = getDrawings(Player)
                local Character = Player.Character
                local targetPart = Character and (
                    Character:FindFirstChild(SilentAimSettings.TargetPart)
                    or Character:FindFirstChild("HumanoidRootPart")
                )
                local hum = Character and Character:FindFirstChild("Humanoid")

                if Player ~= LocalPlayer and targetPart and hum and hum.Health > 0 then
                    local dist = (Camera.CFrame.Position - targetPart.Position).Magnitude
                    if (SilentAimSettings.TeamCheck and Player.Team == LocalPlayer.Team)
                        or dist > SilentAimSettings.ESPMaxDistance then
                        hideESP(drawings)
                        continue
                    end

                    local pos, onScreen = Camera:WorldToViewportPoint(targetPart.Position)
                    if onScreen then
                        local color = SilentAimSettings.AccentColor

                        if SilentAimSettings.BoxESP then
                            local size = Vector2.new(2000 / pos.Z, 3000 / pos.Z)
                            drawings.Box.Size = size
                            drawings.Box.Position = Vector2.new(pos.X - size.X / 2, pos.Y - size.Y / 2)
                            drawings.Box.Color = color
                            drawings.Box.Visible = true
                        else
                            drawings.Box.Visible = false
                        end

                        if SilentAimSettings.NameESP then
                            drawings.Name.Text = string.format("%s [%dm]", Player.DisplayName, math.floor(dist))
                            drawings.Name.Position = Vector2.new(pos.X, pos.Y - (2500 / pos.Z / 2) - 20)
                            drawings.Name.Color = Color3.new(1, 1, 1)
                            drawings.Name.Visible = true
                        else
                            drawings.Name.Visible = false
                        end

                        if SilentAimSettings.TracerESP then
                            drawings.Tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                            drawings.Tracer.To = Vector2.new(pos.X, pos.Y)
                            drawings.Tracer.Color = color
                            drawings.Tracer.Visible = true
                        else
                            drawings.Tracer.Visible = false
                        end
                    else
                        hideESP(drawings)
                    end
                else
                    hideESP(drawings)
                end
            end
        else
            for _, drawings in next, esp_boxes do
                hideESP(drawings)
            end
        end

        updateHighlight()
    end
end))

-- Raycast hooks (wrapped in pcall for executors that don't support hookmetamethod)
local hasHookMetamethod = typeof(hookmetamethod) == "function"
local hasCheckcaller = typeof(checkcaller) == "function"
local hasNewcclosure = typeof(newcclosure) == "function"
local hasGetnamecallmethod = typeof(getnamecallmethod) == "function"

if hasHookMetamethod and hasCheckcaller and hasNewcclosure and hasGetnamecallmethod then
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(...)
        local Method = getnamecallmethod()
        local Arguments = {...}
        local self = Arguments[1]
        local chance = CalculateChance(SilentAimSettings.HitChance)

        if SilentAimSettings.Enabled and self == workspace and not checkcaller() and chance then
            if Method == "FindPartOnRayWithIgnoreList" and SilentAimSettings.SilentAimMethod == Method then
                if ValidateArguments(Arguments, ExpectedArguments.FindPartOnRayWithIgnoreList) then
                    local A_Ray = Arguments[2]
                    local HitPart = getClosestPlayer()
                    if HitPart then
                        local Origin = A_Ray.Origin
                        local Direction = getDirection(Origin, HitPart.Position)
                        Arguments[2] = Ray.new(Origin, Direction)
                        return oldNamecall(unpack(Arguments))
                    end
                end
            elseif Method == "FindPartOnRayWithWhitelist" and SilentAimSettings.SilentAimMethod == Method then
                if ValidateArguments(Arguments, ExpectedArguments.FindPartOnRayWithWhitelist) then
                    local A_Ray = Arguments[2]
                    local HitPart = getClosestPlayer()
                    if HitPart then
                        local Origin = A_Ray.Origin
                        local Direction = getDirection(Origin, HitPart.Position)
                        Arguments[2] = Ray.new(Origin, Direction)
                        return oldNamecall(unpack(Arguments))
                    end
                end
            elseif Method:lower() == "findpartonray" and SilentAimSettings.SilentAimMethod:lower() == "findpartonray" then
                if ValidateArguments(Arguments, ExpectedArguments.FindPartOnRay) then
                    local A_Ray = Arguments[2]
                    local HitPart = getClosestPlayer()
                    if HitPart then
                        local Origin = A_Ray.Origin
                        local Direction = getDirection(Origin, HitPart.Position)
                        Arguments[2] = Ray.new(Origin, Direction)
                        return oldNamecall(unpack(Arguments))
                    end
                end
            elseif Method == "Raycast" and SilentAimSettings.SilentAimMethod == Method then
                if ValidateArguments(Arguments, ExpectedArguments.Raycast) then
                    local A_Origin = Arguments[2]
                    local HitPart = getClosestPlayer()
                    if HitPart then
                        Arguments[3] = getDirection(A_Origin, HitPart.Position)
                        return oldNamecall(unpack(Arguments))
                    end
                end
            end
        end

        return oldNamecall(...)
    end))

    local oldIndex
    oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, Index)
        if self == Mouse
            and not checkcaller()
            and SilentAimSettings.Enabled
            and SilentAimSettings.SilentAimMethod == "Mouse.Hit/Target" then
            local HitPart = getClosestPlayer()
            if HitPart then
                if Index == "Target" or Index == "target" then
                    return HitPart
                elseif Index == "Hit" or Index == "hit" then
                    if SilentAimSettings.MouseHitPrediction then
                        return HitPart.CFrame + (HitPart.Velocity * SilentAimSettings.MouseHitPredictionAmount)
                    else
                        return HitPart.CFrame
                    end
                elseif Index == "UnitRay" then
                    local Camera = getCamera()
                    local origin = Camera.CFrame.Position
                    return Ray.new(origin, (HitPart.Position - origin).Unit)
                end
            end
        end
        return oldIndex(self, Index)
    end))
end
