-- Luau | mm2_hub_v4.lua | Roblox executor (firetouchinterest, gethui; mousemoveabs/mouse1click + hookmetamethod optional) | Murder Mystery 2
-- RightShift = menu | G = ghost | F = shoot murderer | K = kill all
local Players, RS, UIS, TS, Lighting, RepStorage = game:GetService("Players"), game:GetService("RunService"),
    game:GetService("UserInputService"), game:GetService("TweenService"), game:GetService("Lighting"),
    game:GetService("ReplicatedStorage")
local LP, Camera = Players.LocalPlayer, workspace.CurrentCamera
local alive, conns = true, {}
local function bind(sig, fn) local c = sig:Connect(fn); conns[#conns + 1] = c; return c end

local ACC = Color3.fromRGB(140, 120, 255)
local ROLE = {Murderer = Color3.fromRGB(255, 60, 60), Sheriff = Color3.fromRGB(70, 140, 255), Innocent = Color3.fromRGB(80, 230, 120)}
-- FILL: hideout for the real body in ghost mode. empty airspace above the map, below any ceiling. tune per map
local HIDE_CF = CFrame.new(0, 1800, 0)
local FARM_START_RANGE = 450 -- nearest coin must be within this many studs or you're still in the lobby -> no farm
local FARM_SPEED_CAP = 34    -- server position check flags you around 37+ studs/s; stay under
local FARM_HIP = 3           -- root sits this far above the coin so legs end at coin level, not inside the floor
local S = {esp = true, gunesp = true, autogun = false, farm = false, farmspeed = 28, bagcap = 50, flingafter = true,
           speed = false, speedval = 32, noclip = false, touchfling = false, autoshoot = false, killloop = false}
local SHOT_MODES = {"auto", "Shoot", "Beam", "Click"}
local shot_idx = 1

local ghost, ghost_hum, ghost_root, busy, killing = nil, nil, nil, false, false
local ghost_btn
local dbg_labels = {}
local cur_cont, blocked_cont, collected, farm_session, fling_running = nil, nil, 0, false, false
local ui_min, ui_now = nil, nil
local seen = {}

local function dbg(t) for _, l in ipairs(dbg_labels) do l.Text = "dbg: " .. t end end
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
local function my_head_pos()
    local c = my_char()
    local h = c and (c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart"))
    return h and h.Position or Camera.CFrame.Position
end
local function tool_of(plr, n)
    local c, bp = plr.Character, plr:FindFirstChild("Backpack")
    return (c and c:FindFirstChild(n)) or (bp and bp:FindFirstChild(n))
end

-- ===== roles =====
-- other players' Backpack does not replicate to you, so tool checks only see a knife/gun that is held out.
-- the game's own role data fixes that: GetPlayerData (RemoteFunction) + PlayerDataChanged (RemoteEvent), found by name anywhere in ReplicatedStorage.
-- FILL: if "data:0" stays in the status line, print(RepStorage:FindFirstChild("GetPlayerData", true)) and check the returned table shape
local role_data = {}
local function norm_role(s)
    s = tostring(s or ""):lower()
    if s == "murderer" then return "Murderer" end
    if s == "sheriff" or s == "hero" then return "Sheriff" end
    return "Innocent"
end
local function ingest(data)
    if type(data) ~= "table" then return end
    for name, info in pairs(data) do
        if type(info) == "table" and info.Role ~= nil then
            role_data[tostring(name)] = {role = norm_role(info.Role), dead = (info.Dead == true) or (info.Killed == true)}
        end
    end
end
task.spawn(function()
    local ev = RepStorage:FindFirstChild("PlayerDataChanged", true)
    if ev and ev:IsA("RemoteEvent") then bind(ev.OnClientEvent, ingest) end
    while alive do
        local rf = RepStorage:FindFirstChild("GetPlayerData", true)
        if rf and rf:IsA("RemoteFunction") then pcall(function() ingest(rf:InvokeServer()) end) end
        task.wait(2)
    end
end)
local function role(plr)
    if tool_of(plr, "Knife") then return "Murderer" end
    if tool_of(plr, "Gun") then return "Sheriff" end
    local d = role_data[plr.Name]
    return d and d.role or "Innocent"
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
local function find_cont()
    for _, m in ipairs(workspace:GetChildren()) do
        local c = m:FindFirstChild("CoinContainer")
        if c then return c end
    end
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
    local o = my_head_pos()
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
local function dump_remotes(tool)
    for _, d in ipairs(tool:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then print("[toker] remote:", d.ClassName, d:GetFullName()) end
    end
end
local function fire(rem, ...)
    local a = table.pack(...)
    if rem:IsA("RemoteFunction") then
        task.spawn(function() rem:InvokeServer(table.unpack(a, 1, a.n)) end)
    else rem:FireServer(table.unpack(a, 1, a.n)) end
end

-- optional: log every remote call so you can read real args (output). hit "Log remotes", do one shot + one stab by hand
local hooked = false
local function log_remotes()
    if hooked or not (hookmetamethod and getnamecallmethod) then dbg("hookmetamethod missing or already on"); return end
    hooked = true
    local old
    old = hookmetamethod(game, "__namecall", function(self, ...)
        local m = getnamecallmethod()
        if (m == "FireServer" or m == "InvokeServer") and typeof(self) == "Instance" then
            local a, parts = table.pack(...), {}
            for i = 1, a.n do parts[i] = typeof(a[i]) .. ":" .. tostring(a[i]) end
            print("[toker]", self:GetFullName(), m, table.concat(parts, ", "))
        end
        return old(self, ...)
    end)
    dbg("remote logging on, check output")
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

-- ===== sheriff: three shot paths, cycle with "Shot mode" in Combat =====
-- Shoot : Gun.Shoot:FireServer(CFrame origin, CFrame target)     (current layout, v3 sent a Vector3 as arg 2 -> that was the bug)
-- Beam  : Gun.KnifeLocal.CreateBeam.RemoteFunction:InvokeServer(1, pos, "AH2")   (older layout)
-- Click : moves the real mouse onto the target and clicks, so the game's own gun script builds the args (needs target on screen)
-- if all three fail, "Log remotes", one manual shot, send the output line
local function shoot_remote_shoot(gun, pos)
    local rem = gun:FindFirstChild("Shoot", true)
    if not (rem and rem:IsA("RemoteEvent")) then return false, "no Gun.Shoot" end
    local h = gun:FindFirstChild("Handle")
    rem:FireServer(h and h.CFrame or CFrame.new(my_head_pos()), CFrame.new(pos))
    return true, "Shoot(cf,cf)"
end
local function shoot_remote_beam(gun, pos)
    local rem = find_remote(gun, "createbeam", "beam")
    if not rem then return false, "no CreateBeam" end
    fire(rem, 1, pos, "AH2")
    return true, "CreateBeam(1,pos,AH2)"
end
local function shoot_click(gun, pos)
    local v, on = Camera:WorldToViewportPoint(pos)
    if not on then return false, "target offscreen (click mode)" end
    if mousemoveabs then mousemoveabs(v.X, v.Y) end
    task.wait(0.05)
    if mouse1click then mouse1click() else gun:Activate() end
    return true, "click"
end
local function shoot_at(pos)
    local gun = equip("Gun")
    if not gun then dbg("no gun in hand"); return false end
    local mode = SHOT_MODES[shot_idx]
    local ok, how
    if mode == "Click" then ok, how = shoot_click(gun, pos)
    elseif mode == "Shoot" then ok, how = shoot_remote_shoot(gun, pos)
    elseif mode == "Beam" then ok, how = shoot_remote_beam(gun, pos)
    else
        ok, how = shoot_remote_shoot(gun, pos)
        if not ok then ok, how = shoot_remote_beam(gun, pos) end
        if not ok then ok, how = shoot_click(gun, pos) end
    end
    if not ok then dbg("shot failed: " .. tostring(how)); dump_remotes(gun); return false end
    dbg("shot via " .. how)
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
    if not m then dbg("no murderer found (data:" .. tostring(next(role_data) and "ok" or "0") .. ")"); return end
    if not tool_of(LP, "Gun") then
        if find_gundrop() then grab_gun() end
        if not tool_of(LP, "Gun") then dbg("you have no gun"); return end
    end
    local pos = aim_point(m)
    if not pos then return end
    last_shot = os.clock()
    if ghost then with_real(ghost_root.CFrame, function() shoot_at(pos) end) else shoot_at(pos) end
end

-- ===== murderer: kill all =====
-- FILL: knife remote/args per build. "Log remotes", stab once manually
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
    elseif knife then dbg("no stab remote, see output"); dump_remotes(knife) end
    killing = false
end

-- ===== targeted fling (heavy body, spin, wobble offsets, lead on target movement, void-proof) =====
local function fling_player(plr)
    local _, th, tr = get_char(plr)
    if not tr then return false end
    local start = tr.Position
    local flung = false
    local old_h = workspace.FallenPartsDestroyHeight
    with_real(tr.CFrame, function()
        local lc, r = LP.Character, real_root()
        if not (lc and r) then return end
        local saved = {}
        for _, p in ipairs(lc:GetDescendants()) do
            if p:IsA("BasePart") then
                saved[p] = p.CustomPhysicalProperties
                p.CustomPhysicalProperties = PhysicalProperties.new(100, 0.3, 0.5, 1, 1)
            end
        end
        pcall(function() workspace.FallenPartsDestroyHeight = 0 / 0 end)
        Camera.CameraSubject = th
        local t0, angle = os.clock(), 0
        pcall(function()
            while alive and os.clock() - t0 < 2.6 do
                local _, th2, t = get_char(plr)
                if not t then flung = true; break end
                if t.AssemblyLinearVelocity.Magnitude > 300 or (t.Position - start).Magnitude > 140 then flung = true; break end
                angle += 100
                local lead = th2.MoveDirection * math.clamp(t.AssemblyLinearVelocity.Magnitude / 1.25, 0, 12)
                local yoff = (math.floor(angle / 100) % 2 == 0) and 1.5 or -1.5
                r.CFrame = CFrame.new(t.Position + lead + Vector3.new(0, yoff, 0)) * CFrame.Angles(math.rad(angle), 0, 0)
                r.AssemblyLinearVelocity = Vector3.new(9e7, 9e8, 9e7)
                r.AssemblyAngularVelocity = Vector3.new(9e8, 9e8, 9e8)
                RS.Heartbeat:Wait()
            end
        end)
        for p, v in pairs(saved) do if p.Parent then p.CustomPhysicalProperties = v end end
        pcall(function() workspace.FallenPartsDestroyHeight = old_h end)
        local hum = ghost_hum or (lc:FindFirstChildOfClass("Humanoid"))
        if hum then Camera.CameraSubject = hum end
    end)
    return flung
end
local function fling_role(r) local p = find_role(r); if p then fling_player(p) end end
local function fling_all()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and alive and get_char(p) then fling_player(p); task.wait(0.3) end
    end
end

-- ===== ghost: real body parked in the sky (what others see), you drive a client-only clone =====
local ANIMS = {R15 = {idle = "rbxassetid://507766666", run = "rbxassetid://507767714"},
               R6 = {idle = "rbxassetid://180435571", run = "rbxassetid://180426354"}} -- cosmetic, default Animate ids
local g_idle, g_run
local controls
task.spawn(function() -- PlayerModule controls = WASD + gamepad + mobile thumbstick, camera-relative
    local ok, mod = pcall(function() return require(LP:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)) end)
    if ok and mod then pcall(function() controls = mod:GetControls() end) end
end)
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
    gh.PlatformStand, gh.Sit, gh.WalkSpeed = false, false, 16
    for _, d in ipairs(g:GetDescendants()) do
        if d:IsA("BasePart") then d.Transparency = (d == gr) and 1 or 0.75
        elseif d:IsA("Decal") then d.Transparency = 0.75 end
    end
    mk("Highlight", {Adornee = g, FillColor = ACC, OutlineColor = Color3.new(1, 1, 1), FillTransparency = 0.8,
        OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop}, g)
    g:PivotTo(r.CFrame)
    g.Parent = workspace
    pcall(function() gh:ChangeState(Enum.HumanoidStateType.Running) end)
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
bind(UIS.JumpRequest, function() if ghost_hum then ghost_hum.Jump = true end end)

bind(RS.RenderStepped, function()
    Camera = workspace.CurrentCamera
    if not ghost then return end
    if not ghost.Parent or ghost_hum.Health <= 0 then ghost_off(); return end
    if not busy then Camera.CameraSubject = ghost_hum end
    local moving = false
    local mv = Vector3.zero
    if controls then
        local ok, v = pcall(function() return controls:GetMoveVector() end)
        if ok and v then mv = v end
    end
    ghost_hum.WalkSpeed = S.speed and S.speedval or 16
    if mv.Magnitude > 0.01 then
        ghost_hum:Move(mv, true); moving = true
    else
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
        moving = dir.Magnitude > 0
        ghost_hum:Move(moving and dir.Unit or Vector3.zero, false)
    end
    if g_idle and g_run then
        if moving and not g_run.IsPlaying then g_idle:Stop(); g_run:Play() end
        if not moving and not g_idle.IsPlaying then g_run:Stop(); g_idle:Play() end
    end
end)

-- ===== character hooks: on death stop farming for this round, drop ghost =====
local function hook_char(c)
    local h = c:WaitForChild("Humanoid", 5)
    if not h then return end
    bind(h.Died, function()
        if cur_cont then blocked_cont = cur_cont end
        farm_session = false
        if ghost then ghost_off(true) end
    end)
end
if LP.Character then task.spawn(hook_char, LP.Character) end
bind(LP.CharacterAdded, function(c)
    if ghost then ghost_off(true) end
    farm_session = false
    hook_char(c)
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
    Text = "TOKER  <font color='#8c78ff'>mm2 v4</font>", RichText = true, Font = Enum.Font.GothamBold, TextSize = 15,
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
        TextSize = 12, TextColor3 = ACC, TextXAlignment = Enum.TextXAlignment.Left, RichText = true,
        TextTruncate = Enum.TextTruncate.AtEnd}, p)
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
dbg_labels[#dbg_labels + 1] = label(t_main, "dbg: idle")
toggle(t_main, "Auto grab dropped gun", false, function(v) S.autogun = v end)
button(t_main, "Grab gun now", function() task.spawn(grab_gun) end)
label(t_main, "AUTOFARM")
toggle(t_main, "Coin / candy autofarm", false, function(v) S.farm = v; farm_session = false end)
slider(t_main, "Farm speed (studs/s, cap 34)", 10, FARM_SPEED_CAP, 28, function(v) S.farmspeed = v end)
slider(t_main, "Stop after N collected", 5, 100, 50, function(v) S.bagcap = v end)
toggle(t_main, "Fling murderer when bag is full", true, function(v) S.flingafter = v end)

-- Combat
local t_cmb = new_tab("Combat")
dbg_labels[#dbg_labels + 1] = label(t_cmb, "dbg: idle")
label(t_cmb, "SHERIFF")
toggle(t_cmb, "Auto shoot murderer (LOS)", false, function(v) S.autoshoot = v end)
button(t_cmb, "Shoot murderer  (F)", function() task.spawn(shoot_murderer) end)
local sm_btn
sm_btn = button(t_cmb, "Shot mode: auto  (tap to cycle)", function()
    shot_idx = shot_idx % #SHOT_MODES + 1
    sm_btn.Text = "Shot mode: " .. SHOT_MODES[shot_idx] .. "  (tap to cycle)"
end)
label(t_cmb, "MURDERER")
button(t_cmb, "Kill all  (K)", function() task.spawn(kill_all) end)
toggle(t_cmb, "Loop kill all", false, function(v) S.killloop = v end)
label(t_cmb, "FLING")
button(t_cmb, "Fling murderer", function() task.spawn(fling_role, "Murderer") end)
button(t_cmb, "Fling sheriff", function() task.spawn(fling_role, "Sheriff") end)
button(t_cmb, "Fling everyone", function() task.spawn(fling_all) end)
label(t_cmb, "DEBUG")
button(t_cmb, "Log remotes (output)", log_remotes)

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

-- ===== bag counter: local count (coin removed within 3s of our touch) + bag UI delta (CoinBags), whichever is higher =====
-- UI is read as a delta from the lowest value seen this round, so a static label (like a max cap) can never trigger a false "full"
local bags_ref, bags_t = nil, 0
local function ui_bag()
    if not (bags_ref and bags_ref.Parent) then
        if os.clock() - bags_t < 1 then return nil end
        bags_t = os.clock()
        local pg = LP:FindFirstChild("PlayerGui")
        bags_ref = pg and pg:FindFirstChild("CoinBags", true)
        if not bags_ref then return nil end
    end
    local best
    for _, d in ipairs(bags_ref:GetDescendants()) do
        if d:IsA("TextLabel") then
            local n = tonumber(d.Text:match("^%s*(%d+)%s*$"))
            if n and n <= 999 and (not best or n > best) then best = n end
        end
    end
    return best
end
local function bag_count()
    local ui = (ui_now and ui_min) and (ui_now - ui_min) or 0
    return math.max(collected, ui)
end

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
        local n = 0
        for _ in pairs(role_data) do n += 1 end
        status.Text = string.format("you: %s  bag %d/%d  data:%d  <font color='#ff3c3c'>M: %s</font> <font color='#468cff'>S: %s</font>",
            role(LP), bag_count(), S.bagcap, n, murd, sher)
        local gd = find_gundrop()
        gun_hl.Adornee, gun_hl.Enabled = gd, S.gunesp and gd ~= nil
        if not busy and not killing then
            local me = role(LP)
            if S.autogun and gd and me == "Innocent" then
                task.spawn(grab_gun)
            elseif S.autoshoot and me == "Sheriff" then
                if os.clock() - last_shot > 1.5 then
                    local m = find_role("Murderer")
                    if not m then dbg("auto: no murderer found")
                    elseif not los(m.Character) then dbg("auto: no line of sight")
                    else task.spawn(shoot_murderer) end
                end
            elseif S.killloop and me == "Murderer" then
                task.spawn(kill_all)
            end
        end
        task.wait(0.2)
    end
end)

-- ===== autofarm =====
-- root rides FARM_HIP above the coin (legs end at coin level, not in the floor), noclip stays on for the whole session (no flicker between coins),
-- constant-speed stepping, no-progress detection skips a coin that can't be reached, coins can be Parts or Models
local function coin_part(c)
    if c:IsA("BasePart") then return c end
    if c:IsA("Model") then return c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart", true) end
end

local function end_round(cont)
    dbg("bag full, flinging murderer")
    local tries = 0
    while alive and S.flingafter and cont == cur_cont and cont ~= blocked_cont and tries < 10 do
        local m = find_role("Murderer")
        if not m or role(LP) == "Murderer" then break end
        if not get_char(LP) then break end
        fling_player(m)
        tries += 1
        task.wait(1.2)
    end
end

local function farm_to(obj, part, cont)
    seen[obj] = os.clock()
    local speed = math.min(S.farmspeed, FARM_SPEED_CAP)
    local reached = false
    local best_d, t_prog = math.huge, os.clock()
    while alive and S.farm and not ghost and not busy do
        local dt = math.min(RS.Heartbeat:Wait(), 0.05)
        local _, _, r = get_char(LP)
        if not r or not part.Parent or cont ~= cur_cont or cont == blocked_cont then break end
        local delta = part.Position + Vector3.new(0, FARM_HIP, 0) - r.Position
        local dist = delta.Magnitude
        if dist < 1.5 then reached = true; break end
        if dist < best_d - 0.5 then best_d, t_prog = dist, os.clock() end
        if os.clock() - t_prog > 1.2 then dbg("farm: stuck, skipping coin"); break end
        local step = math.min(dist, speed * dt)
        r.CFrame = CFrame.new(r.Position + delta.Unit * step) * r.CFrame.Rotation
        r.AssemblyLinearVelocity = Vector3.zero
        r.AssemblyAngularVelocity = Vector3.zero
    end
    if reached and part.Parent then
        local _, _, r = get_char(LP)
        if r and firetouchinterest then firetouchinterest(r, part, 0); firetouchinterest(r, part, 1) end
        local counted, conn = false, nil
        conn = obj.AncestryChanged:Connect(function(_, parent)
            if not parent and not counted then counted = true; collected += 1 end
        end)
        task.delay(3, function() if conn then conn:Disconnect() end end)
        task.wait(0.1)
    end
end

task.spawn(function()
    while alive do
        task.wait(0.1)
        local cont = find_cont()
        if cont ~= cur_cont then -- new round (or round over): reset everything
            cur_cont, collected, blocked_cont, ui_min, ui_now = cont, 0, nil, nil, nil
            seen = {}
            if not cont then role_data = {} end
        end
        if cont then
            local ui = ui_bag()
            if ui then ui_now = ui; ui_min = ui_min and math.min(ui_min, ui) or ui end
        end
        local _, hum, r = get_char(LP)
        local can = S.farm and cont ~= nil and cont ~= blocked_cont and not ghost and not busy and hum ~= nil and r ~= nil
        local full = can and bag_count() >= S.bagcap
        farm_session = can and not full
        if not can then continue end
        if full then
            if S.flingafter and not fling_running then
                fling_running = true
                task.spawn(function() end_round(cont); fling_running = false end)
            end
            continue
        end
        local best_obj, best_part, bd
        for _, c in ipairs(cont:GetChildren()) do
            local p = coin_part(c)
            if p and not (seen[c] and os.clock() - seen[c] < 4) then
                local d = (p.Position - r.Position).Magnitude
                if not bd or d < bd then best_obj, best_part, bd = c, p, d end
            end
        end
        if best_obj and bd <= FARM_START_RANGE then farm_to(best_obj, best_part, cont) end
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
    end
end)
bind(RS.Stepped, function()
    if busy then return end
    local c = my_char()
    if c and (S.noclip or farm_session) then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end
end)
task.spawn(function()
    while alive do
        RS.Heartbeat:Wait()
        if S.touchfling and not farm_session and not ghost and not busy then
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
