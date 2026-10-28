-- Luau | mm2_hub_v2.lua | Roblox executor (firetouchinterest, gethui) | Murder Mystery 2
-- RightShift = menu | G = ghost | F = shoot murderer | K = kill all
local Players, RS, UIS, TS, Lighting = game:GetService("Players"), game:GetService("RunService"),
    game:GetService("UserInputService"), game:GetService("TweenService"), game:GetService("Lighting")
local LP, Camera = Players.LocalPlayer, workspace.CurrentCamera
local alive, conns = true, {}
local function bind(sig, fn) conns[#conns + 1] = sig:Connect(fn) end

local ACC = Color3.fromRGB(140, 120, 255)
local ROLE = {Murderer = Color3.fromRGB(255, 60, 60), Sheriff = Color3.fromRGB(70, 140, 255), Innocent = Color3.fromRGB(80, 230, 120)}
-- FILL: hideout for the real body in ghost mode. empty airspace above the map, below any ceiling. tune per map
local HIDE_CF = CFrame.new(0, 1800, 0)
local S = {esp = true, gunesp = true, autogun = false, farm = false, farmspeed = 24, speed = false, speedval = 32,
           noclip = false, touchfling = false, autoshoot = false, killloop = false}
local ghost, ghost_hum, ghost_root, busy, killing = nil, nil, nil, false, false
local ghost_btn

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(o, r) mk("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o) end

-- ===== core helpers =====
local function get_char(plr)
    local c = plr.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if h and r and h.Health > 0 then return c, h, r end
end
local function real_root() return LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") end
local function my_char() return ghost or LP.Character end
local function tool_of(plr, n)
    local c, bp = plr.Character, plr:FindFirstChild("Backpack")
    return (c and c:FindFirstChild(n)) or (bp and bp:FindFirstChild(n))
end
local function role(plr)
    if tool_of(plr, "Knife") then return "Murderer" end
    if tool_of(plr, "Gun") then return "Sheriff" end
    return "Innocent"
end
local function find_role(r)
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and role(p) == r and get_char(p) then return p end
    end
end
local function find_gundrop()
    local gd = workspace:FindFirstChild("GunDrop", true)
    return gd and gd:IsA("BasePart") and gd or nil
end
local function los(c)
    local head = c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart")
    if not head then return false end
    local ign = {Camera}
    if LP.Character then ign[#ign + 1] = LP.Character end
    if ghost then ign[#ign + 1] = ghost end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = ign
    local o = Camera.CFrame.Position
    local hit = workspace:Raycast(o, head.Position - o, rp)
    return hit == nil or hit.Instance:IsDescendantOf(c)
end

-- real body briefly goes to cf, runs fn, returns (to hideout if ghost, else to where it was)
local function with_real(cf, fn)
    local r = real_root()
    if busy or not r then return false end
    busy = true
    local back = r.CFrame
    r.CFrame = cf
    r.AssemblyLinearVelocity = Vector3.zero
    task.wait(LP:GetNetworkPing() + 0.06) -- let the server see the new position first
    local ok = pcall(fn)
    r = real_root()
    if r then
        r.AssemblyLinearVelocity = Vector3.zero
        r.AssemblyAngularVelocity = Vector3.zero
        r.CFrame = ghost and HIDE_CF or back
    end
    busy = false
    return ok
end

local function equip(name)
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local t = tool_of(LP, name)
    if hum and t and t.Parent ~= c then hum:EquipTool(t); task.wait(0.15) end
    return c and c:FindFirstChild(name)
end
local function find_remote(tool, ...)
    local pats, base = {...}, #tool:GetFullName()
    for _, d in ipairs(tool:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            local rel = d:GetFullName():sub(base + 1):lower()
            for _, p in ipairs(pats) do if rel:find(p) then return d end end
        end
    end
end
local function fire(rem, ...)
    local a = table.pack(...)
    if rem:IsA("RemoteFunction") then
        task.spawn(function() rem:InvokeServer(table.unpack(a, 1, a.n)) end)
    else rem:FireServer(table.unpack(a, 1, a.n)) end
end

-- ===== gun grab =====
local function grab_gun()
    local gd = find_gundrop()
    if not gd then return end
    with_real(gd.CFrame, function()
        local r = real_root()
        if firetouchinterest then firetouchinterest(r, gd, 0); firetouchinterest(r, gd, 1) end
        task.wait(0.2)
    end)
end

-- ===== sheriff: silent aim (remote gets the predicted position, camera never moves) =====
-- FILL: remote layout/args change per build. if shots don't register, capture one real shot:
--   local o; o = hookmetamethod(game, "__namecall", function(s, ...) if getnamecallmethod():find("Server") then print(s:GetFullName(), ...) end return o(s, ...) end)
-- then fix the two fire() calls below to match
local function shoot_at(pos)
    local gun = equip("Gun")
    if not gun then return false end
    local rem = find_remote(gun, "beam", "shoot", "fire")
    if not rem then return false end
    if rem:IsA("RemoteFunction") then fire(rem, 1, pos, "AH2")
    else fire(rem, CFrame.new(Camera.CFrame.Position, pos), pos) end
    return true
end
local function aim_point(plr)
    local c, _, r = get_char(plr)
    if not c then return end
    local part = c:FindFirstChild("Head") or r
    local v = r.AssemblyLinearVelocity
    return part.Position + Vector3.new(v.X, 0, v.Z) * (LP:GetNetworkPing() + 0.07) -- tune 0.07 if you lead/lag
end
local last_shot = 0
local function shoot_murderer()
    local m = find_role("Murderer")
    if not m then return end
    if not tool_of(LP, "Gun") then
        if find_gundrop() then grab_gun() end
        if not tool_of(LP, "Gun") then return end
    end
    local pos = aim_point(m)
    if not pos then return end
    last_shot = os.clock()
    if ghost then with_real(ghost_root.CFrame, function() shoot_at(pos) end) else shoot_at(pos) end
end

-- ===== murderer: kill all =====
-- FILL: knife remote/args per build. same __namecall dump as above, stab once manually
local function kill_all()
    if killing or role(LP) ~= "Murderer" then return end
    killing = true
    local knife = equip("Knife")
    local stab = knife and find_remote(knife, "stab", "slash")
    if knife and stab then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and alive then
                local c, _, tr = get_char(plr)
                if c then
                    local from = (tr.CFrame * CFrame.new(0, 0, 2)).Position
                    with_real(CFrame.lookAt(from, tr.Position), function()
                        local _, _, t2 = get_char(plr)
                        if not t2 then return end
                        fire(stab, "Slash")
                        local h = knife:FindFirstChild("Handle")
                        if h and firetouchinterest then firetouchinterest(h, t2, 0); firetouchinterest(h, t2, 1) end
                        task.wait(0.1)
                    end)
                end
            end
        end
    end
    killing = false
end

-- ===== targeted fling =====
local function fling_player(plr)
    local c, _, tr = get_char(plr)
    if not tr then return end
    local start = tr.Position
    with_real(tr.CFrame, function()
        local r, t0 = real_root(), os.clock()
        while alive and r and r.Parent and os.clock() - t0 < 2 do
            local _, _, t = get_char(plr)
            if not t then break end
            if (t.Position - start).Magnitude > 120 or t.AssemblyLinearVelocity.Magnitude > 250 then break end
            r.CFrame = t.CFrame
            r.AssemblyLinearVelocity = Vector3.new(9e5, 9e5, 9e5)
            r.AssemblyAngularVelocity = Vector3.new(9e5, 9e5, 9e5)
            RS.Heartbeat:Wait()
        end
    end)
end
local function fling_role(r) local p = find_role(r); if p then fling_player(p) end end
local function fling_all()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and alive and get_char(p) then fling_player(p) end
    end
end

-- ===== ghost: real body parked in the sky (what others see), you drive a client-only clone =====
local ANIMS = {R15 = {idle = "rbxassetid://507766666", run = "rbxassetid://507767714"},
               R6 = {idle = "rbxassetid://180435571", run = "rbxassetid://180426354"}} -- cosmetic, default Animate ids
local g_idle, g_run
local function set_ghost_ui(on)
    if ghost_btn then ghost_btn.Text = on and "Ghost: ON  (G)" or "Ghost: OFF  (G)" end
end
local function ghost_off(skip_tp)
    local g, gr = ghost, ghost_root
    local cf = gr and gr.CFrame
    ghost, ghost_hum, ghost_root, g_idle, g_run = nil, nil, nil, nil, nil
    local r = real_root()
    if r and cf and not skip_tp then r.CFrame = cf; r.AssemblyLinearVelocity = Vector3.zero end
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if hum then Camera.CameraSubject = hum end
    if g then g:Destroy() end
    set_ghost_ui(false)
end
local function ghost_on()
    local c, r = LP.Character, real_root()
    if ghost or busy or not (c and r) then return end
    local was = c.Archivable
    c.Archivable = true
    local ok, g = pcall(function() return c:Clone() end)
    c.Archivable = was
    if not ok or not g then return end
    for _, d in ipairs(g:GetDescendants()) do
        if d:IsA("LuaSourceContainer") or d:IsA("Tool") then d:Destroy() end
    end
    local gh, gr = g:FindFirstChildOfClass("Humanoid"), g:FindFirstChild("HumanoidRootPart")
    if not (gh and gr) then g:Destroy(); return end
    g.Name = "TokerGhost"
    gh.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    for _, d in ipairs(g:GetDescendants()) do
        if d:IsA("BasePart") then d.Transparency = (d == gr) and 1 or 0.75
        elseif d:IsA("Decal") then d.Transparency = 0.75 end
    end
    mk("Highlight", {Adornee = g, FillColor = ACC, OutlineColor = Color3.new(1, 1, 1), FillTransparency = 0.8,
        OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop}, g)
    g:PivotTo(r.CFrame)
    g.Parent = workspace
    local animator = gh:FindFirstChildOfClass("Animator") or mk("Animator", {}, gh)
    local set = ANIMS[gh.RigType == Enum.HumanoidRigType.R15 and "R15" or "R6"]
    local function load(id)
        local a = mk("Animation", {AnimationId = id}, nil)
        local ok2, tr = pcall(function() return animator:LoadAnimation(a) end)
        if ok2 and tr then tr.Priority = Enum.AnimationPriority.Core; return tr end
    end
    g_idle, g_run = load(set.idle), load(set.run)
    ghost, ghost_hum, ghost_root = g, gh, gr
    set_ghost_ui(true)
end
bind(LP.CharacterAdded, function() if ghost then ghost_off(true) end end)
bind(UIS.JumpRequest, function() if ghost_hum then ghost_hum.Jump = true end end)

bind(RS.RenderStepped, function()
    Camera = workspace.CurrentCamera
    if not ghost then return end
    if not ghost.Parent or ghost_hum.Health <= 0 then ghost_off(); return end
    Camera.CameraSubject = ghost_hum
    local dir = Vector3.zero
    if not UIS:GetFocusedTextBox() then
        local look, right = Camera.CFrame.LookVector, Camera.CFrame.RightVector
        local f, rt = Vector3.new(look.X, 0, look.Z), Vector3.new(right.X, 0, right.Z)
        f = f.Magnitude > 0.01 and f.Unit or Vector3.zero
        rt = rt.Magnitude > 0.01 and rt.Unit or Vector3.zero
        if UIS:IsKeyDown(Enum.KeyCode.W) then dir += f end
        if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= f end
        if UIS:IsKeyDown(Enum.KeyCode.D) then dir += rt end
        if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= rt end
    end
    ghost_hum.WalkSpeed = S.speed and S.speedval or 16
    ghost_hum:Move(dir.Magnitude > 0 and dir.Unit or dir, false)
    if g_idle and g_run then
        local moving = dir.Magnitude > 0
        if moving and not g_run.IsPlaying then g_idle:Stop(); g_run:Play() end
        if not moving and not g_idle.IsPlaying then g_run:Stop(); g_idle:Play() end
    end
end)

-- ===== UI =====
local gui = mk("ScreenGui", {Name = "TokerMM2", ResetOnSpawn = false}, (gethui and gethui()) or game:GetService("CoreGui"))
local main = mk("Frame", {Size = UDim2.fromOffset(500, 340), Position = UDim2.new(0.5, -250, 0.5, -170),
    BackgroundColor3 = Color3.fromRGB(16, 16, 22), BorderSizePixel = 0}, gui)
corner(main, 12)
mk("UIStroke", {Color = Color3.fromRGB(45, 45, 60)}, main)
local header = mk("Frame", {Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = Color3.fromRGB(22, 22, 30), BorderSizePixel = 0}, main)
corner(header, 12)
mk("TextLabel", {Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(14, 0), BackgroundTransparency = 1,
    Text = "TOKER  <font color='#8c78ff'>mm2 v2</font>", RichText = true, Font = Enum.Font.GothamBold, TextSize = 15,
    TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left}, header)
do
    local drag, start, origin
    bind(header.InputBegan, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            drag, start, origin = true, i.Position, main.Position
        end
    end)
    bind(UIS.InputChanged, function(i)
        if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            main.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
        end
    end)
    bind(UIS.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end
    end)
end
local sidebar = mk("Frame", {Size = UDim2.new(0, 110, 1, -44), Position = UDim2.fromOffset(8, 42), BackgroundTransparency = 1}, main)
mk("UIListLayout", {Padding = UDim.new(0, 6)}, sidebar)
local content = mk("Frame", {Size = UDim2.new(1, -134, 1, -48), Position = UDim2.fromOffset(126, 42), BackgroundTransparency = 1}, main)
local pages, tabs = {}, {}
local function select_tab(n)
    for k, p in pairs(pages) do p.Visible = (k == n) end
    for k, b in pairs(tabs) do
        TS:Create(b, TweenInfo.new(0.15), {BackgroundColor3 = (k == n) and ACC or Color3.fromRGB(28, 28, 38)}):Play()
    end
end
local function new_tab(n)
    local b = mk("TextButton", {Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = Color3.fromRGB(28, 28, 38), Text = n,
        Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false}, sidebar)
    corner(b)
    local p = mk("ScrollingFrame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false}, content)
    mk("UIListLayout", {Padding = UDim.new(0, 6)}, p)
    pages[n], tabs[n] = p, b
    bind(b.MouseButton1Click, function() select_tab(n) end)
    return p
end
local function label(p, t)
    return mk("TextLabel", {Size = UDim2.new(1, -8, 0, 22), BackgroundTransparency = 1, Text = t, Font = Enum.Font.GothamBold,
        TextSize = 12, TextColor3 = ACC, TextXAlignment = Enum.TextXAlignment.Left, RichText = true}, p)
end
local function toggle(p, t, def, cb)
    local f = mk("Frame", {Size = UDim2.new(1, -8, 0, 32), BackgroundColor3 = Color3.fromRGB(26, 26, 36)}, p)
    corner(f)
    mk("TextLabel", {Size = UDim2.new(1, -60, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1, Text = t,
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = Color3.fromRGB(225, 225, 235), TextXAlignment = Enum.TextXAlignment.Left}, f)
    local pill = mk("Frame", {Size = UDim2.fromOffset(34, 18), Position = UDim2.new(1, -46, 0.5, -9)}, f)
    corner(pill, 9)
    local knob = mk("Frame", {Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Color3.new(1, 1, 1)}, pill)
    corner(knob, 7)
    local st = def
    local function paint()
        TS:Create(pill, TweenInfo.new(0.15), {BackgroundColor3 = st and ACC or Color3.fromRGB(50, 50, 66)}):Play()
        TS:Create(knob, TweenInfo.new(0.15), {Position = UDim2.fromOffset(st and 18 or 2, 2)}):Play()
    end
    paint()
    local b = mk("TextButton", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = ""}, f)
    bind(b.MouseButton1Click, function() st = not st; paint(); cb(st) end)
end
local function slider(p, t, min, max, def, cb)
    local f = mk("Frame", {Size = UDim2.new(1, -8, 0, 44), BackgroundColor3 = Color3.fromRGB(26, 26, 36)}, p)
    corner(f)
    local l = mk("TextLabel", {Size = UDim2.new(1, -20, 0, 20), Position = UDim2.fromOffset(12, 3), BackgroundTransparency = 1,
        Text = t .. ": " .. def, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = Color3.fromRGB(225, 225, 235),
        TextXAlignment = Enum.TextXAlignment.Left}, f)
    local bar = mk("Frame", {Size = UDim2.new(1, -24, 0, 6), Position = UDim2.new(0, 12, 0, 31), BackgroundColor3 = Color3.fromRGB(50, 50, 66)}, f)
    corner(bar, 3)
    local fill = mk("Frame", {Size = UDim2.fromScale((def - min) / (max - min), 1), BackgroundColor3 = ACC}, bar)
    corner(fill, 3)
    local down = false
    local function set(x)
        local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local v = math.floor(min + (max - min) * a + 0.5)
        fill.Size = UDim2.fromScale(a, 1); l.Text = t .. ": " .. v; cb(v)
    end
    bind(bar.InputBegan, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then down = true; set(i.Position.X) end
    end)
    bind(UIS.InputChanged, function(i)
        if down and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then set(i.Position.X) end
    end)
    bind(UIS.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then down = false end
    end)
end
local function button(p, t, cb)
    local b = mk("TextButton", {Size = UDim2.new(1, -8, 0, 32), BackgroundColor3 = Color3.fromRGB(38, 34, 70), Text = t,
        Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = Color3.new(1, 1, 1)}, p)
    corner(b)
    bind(b.MouseButton1Click, cb)
    return b
end

-- Main
local t_main = new_tab("Main")
local status = label(t_main, "round: waiting")
toggle(t_main, "Auto grab dropped gun", false, function(v) S.autogun = v end)
button(t_main, "Grab gun now", function() task.spawn(grab_gun) end)
toggle(t_main, "Coin autofarm (pauses in ghost)", false, function(v) S.farm = v end)
slider(t_main, "Farm speed (studs/s)", 10, 60, 24, function(v) S.farmspeed = v end)

-- Combat
local t_cmb = new_tab("Combat")
label(t_cmb, "SHERIFF")
toggle(t_cmb, "Auto shoot murderer (LOS)", false, function(v) S.autoshoot = v end)
button(t_cmb, "Shoot murderer  (F)", function() task.spawn(shoot_murderer) end)
label(t_cmb, "MURDERER")
button(t_cmb, "Kill all  (K)", function() task.spawn(kill_all) end)
toggle(t_cmb, "Loop kill all", false, function(v) S.killloop = v end)
label(t_cmb, "FLING")
button(t_cmb, "Fling murderer", function() task.spawn(fling_role, "Murderer") end)
button(t_cmb, "Fling sheriff", function() task.spawn(fling_role, "Sheriff") end)
button(t_cmb, "Fling everyone", function() task.spawn(fling_all) end)

-- Visuals
local t_vis = new_tab("Visuals")
toggle(t_vis, "Role ESP", true, function(v) S.esp = v end)
toggle(t_vis, "Gun drop ESP", true, function(v) S.gunesp = v end)
local lb = {Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient}
local function fullbright(on)
    if on then
        Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.GlobalShadows = 2, 14, 1e6, false
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
    else for k, v in pairs(lb) do Lighting[k] = v end end
end
toggle(t_vis, "Fullbright", false, fullbright)

-- Player
local t_pl = new_tab("Player")
ghost_btn = button(t_pl, "Ghost: OFF  (G)", function() if ghost then ghost_off() else ghost_on() end end)
toggle(t_pl, "Speed", false, function(v)
    S.speed = v
    local h = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if h and not v then h.WalkSpeed = 16 end
end)
slider(t_pl, "Speed value", 16, 120, 32, function(v) S.speedval = v end)
toggle(t_pl, "Noclip", false, function(v) S.noclip = v end)
toggle(t_pl, "Touch fling (not in ghost)", false, function(v) S.touchfling = v end)
button(t_pl, "Unload", function()
    alive = false
    if ghost then ghost_off() end
    for _, c in ipairs(conns) do c:Disconnect() end
    fullbright(false)
    gui:Destroy()
end)
select_tab("Main")

-- ===== ESP / status / auto actions =====
local hl = {}
local gun_hl = mk("Highlight", {FillColor = Color3.fromRGB(255, 220, 60), OutlineColor = Color3.new(1, 1, 1), FillTransparency = 0.3,
    DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Enabled = false}, gui)
bind(Players.PlayerRemoving, function(p) if hl[p] then hl[p]:Destroy(); hl[p] = nil end end)
task.spawn(function()
    while alive do
        local murd, sher = "?", "?"
        for _, p in ipairs(Players:GetPlayers()) do
            local r = role(p)
            if r == "Murderer" then murd = p.Name elseif r == "Sheriff" then sher = p.Name end
            if p ~= LP then
                local h = hl[p]
                if p.Character then
                    if not h or h.Parent ~= gui then
                        h = mk("Highlight", {FillTransparency = 0.45, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop}, gui)
                        hl[p] = h
                    end
                    h.Adornee, h.FillColor, h.OutlineColor, h.Enabled = p.Character, ROLE[r], ROLE[r], S.esp
                elseif h then h.Enabled = false end
            end
        end
        status.Text = string.format("you: %s   <font color='#ff3c3c'>M: %s</font>  <font color='#468cff'>S: %s</font>", role(LP), murd, sher)
        local gd = find_gundrop()
        gun_hl.Adornee, gun_hl.Enabled = gd, S.gunesp and gd ~= nil
        if not busy and not killing then
            local me = role(LP)
            if S.autogun and gd and me == "Innocent" then
                task.spawn(grab_gun)
            elseif S.autoshoot and me == "Sheriff" and os.clock() - last_shot > 1.5 then
                local m = find_role("Murderer")
                if m and los(m.Character) then task.spawn(shoot_murderer) end
            elseif S.killloop and me == "Murderer" then
                task.spawn(kill_all)
            end
        end
        task.wait(0.2)
    end
end)

-- ===== coin autofarm =====
local seen = {}
task.spawn(function()
    while alive do
        task.wait(0.1)
        local r = real_root()
        if S.farm and not ghost and not busy and r then
            local hum = LP.Character:FindFirstChildOfClass("Humanoid")
            local cont
            for _, m in ipairs(workspace:GetChildren()) do
                cont = m:FindFirstChild("CoinContainer"); if cont then break end
            end
            if hum and hum.Health > 0 and cont then
                local best, bd
                for _, coin in ipairs(cont:GetChildren()) do
                    if coin.Name == "Coin_Server" and coin:IsA("BasePart") and not (seen[coin] and os.clock() - seen[coin] < 4) then
                        local d = (coin.Position - r.Position).Magnitude
                        if not bd or d < bd then best, bd = coin, d end
                    end
                end
                if best then
                    seen[best] = os.clock()
                    local tw = TS:Create(r, TweenInfo.new(bd / S.farmspeed, Enum.EasingStyle.Linear), {CFrame = best.CFrame})
                    tw:Play(); tw.Completed:Wait()
                    if best.Parent and firetouchinterest then firetouchinterest(r, best, 0); firetouchinterest(r, best, 1) end
                    task.wait(0.12)
                end
            end
        end
    end
end)

-- ===== movement / noclip / touch fling / ghost pin =====
bind(RS.Heartbeat, function()
    if ghost and not busy then
        local r = real_root()
        if r then r.CFrame = HIDE_CF; r.AssemblyLinearVelocity = Vector3.zero; r.AssemblyAngularVelocity = Vector3.zero end
    elseif not ghost then
        local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
        if hum and S.speed then hum.WalkSpeed = S.speedval end
        local r = real_root()
        if r and S.farm then r.AssemblyLinearVelocity = Vector3.zero end
    end
end)
bind(RS.Stepped, function()
    if busy then return end
    local c = my_char()
    if c and (S.noclip or (S.farm and not ghost)) then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end
end)
task.spawn(function()
    while alive do
        RS.Heartbeat:Wait()
        if S.touchfling and not S.farm and not ghost and not busy then
            local r = real_root()
            if r then
                local v = r.AssemblyLinearVelocity
                r.AssemblyLinearVelocity = v * 1e4 + Vector3.new(0, 1e4, 0)
                RS.RenderStepped:Wait()
                r.AssemblyLinearVelocity = v
                RS.Stepped:Wait()
                r.AssemblyLinearVelocity = v + Vector3.new(0, math.random() > 0.5 and 0.1 or -0.1, 0)
            end
        end
    end
end)

-- ===== hotkeys =====
bind(UIS.InputBegan, function(i, gp)
    if gp then return end
    local k = i.KeyCode
    if k == Enum.KeyCode.RightShift then main.Visible = not main.Visible
    elseif k == Enum.KeyCode.G then if ghost then ghost_off() else ghost_on() end
    elseif k == Enum.KeyCode.F then task.spawn(shoot_murderer)
    elseif k == Enum.KeyCode.K then task.spawn(kill_all) end
end)
