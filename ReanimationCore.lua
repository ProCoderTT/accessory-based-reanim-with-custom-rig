--[[
  Zeon Glitcher V2 faithful rebuild: -gh kill + accessory reanimate
  - chat: -gh <ids> / -sh / -net (same command + timing as the Zeon source)
  - accessories requested: Accessory (LArm) / Accessory (LLeg)
                           Accessory (RArm) / Accessory (RLeg)
                           RetroFace / Accessory (TorsoWhite)
  - NO lp.Character swapping, NO separate fake-rig model. Real Zeon structure:
      * the FRESH CLONE parts stay inside the real character = the invisible
        driver. PlayerModule drives it (WASD), CameraSubject = its humanoid,
        so the camera follows it and it never becomes "just another model".
      * the ORIGINAL parts become a child "Corpse" model that breaks into a
        pile on the floor at loadtime and STAYS there.
      * the original humanoid is put in Physics state BEFORE the split, so
        when the corpse joints break it never fires Died -> no respawn.
  - accessories: the WORKING method (WORKINGREANIMWITHACCESSORIES.txt).
      * hats STAY on the corpse (visible body). NOT moved, NOT re-welded.
      * the fresh clone keeps its own copies of the accessories; those fresh
        handles keep their intact server AccessoryWeld on the invisible
        driver, so they move correctly with it.
      * every frame the visible handle copies the fresh handle's CFrame ->
        accessories "float around" the moving body exactly like Zeon.
      * once paired, each visible handle is reparented INTO the character and
        driven NETLESS (CFrame + zeroed physics + tiny upward velocity) so the
        server never simulates them and they never vanish when walking away.
      * legs get a 45 deg downward rotation relative to their fresh handle.
  - respawnrequest() + reset-button callback + jump copy (Zeon).
--]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local lp = Players.LocalPlayer
local ws = Workspace
local sg = StarterGui
local heartbeat = RunService.Heartbeat
local stepped = RunService.Stepped
local renderstepped = RunService.RenderStepped
local loadtime = Players.RespawnTime + 0.5

local activeChar

--[[ CHAT COMMANDS (same as source) ]]--
local TextChatService = game:GetService("TextChatService")
local TChannels = TextChatService:FindFirstChild("TextChannels")
local RBXGeneral = TChannels and TChannels:FindFirstChild("RBXGeneral")
local function send(msg)
    -- this game's chat is legacy (SendAsync throws GetServerChannelRemote
    -- not available), so Player:Chat is the primary path
    local ok = pcall(function()
        lp:Chat(msg)
    end)
    if not ok and RBXGeneral then
        pcall(function()
            RBXGeneral:SendAsync(msg)
        end)
    end
end
local GH_IDS = "14160471787 128948172708607 85392395166623 131385506535381 106249329428811 129462518582032 "

--[[ NO-RESPAWN (from Zeon) ]]--
local function respawnrequest()
    local ccfr, ch = ws.CurrentCamera.CFrame, lp.Character
    lp.Character = nil
    lp.Character = ch
    local con
    con = ws.CurrentCamera.Changed:Connect(function(prop)
        if (prop ~= "Parent") and (prop ~= "CFrame") then return end
        ws.CurrentCamera.CFrame = ccfr
        con:Disconnect()
    end)
end

--[[ LIMB ROTATION: which fresh handles get the 45 deg down turn ]]--
-- names are matched case-insensitively because the game creates them as
-- "Accessory (LArm)" / "Accessory (LLeg)" / "Accessory (RArm)" /
-- "Accessory (RLeg)" / "RetroFace" / "Accessory (TorsoWhite)"
local function normName(n)
    local s = (tostring(n):gsub("[^%w]", ""):lower())
    return s:gsub("^accessory", "")
end

-- which driver body part each accessory should follow (so the walk cycle
-- swings the limbs), plus the per-accessory placement adjustment.
local BODY_TARGET = {
    torsowhite = { "UpperTorso", "Torso", "HumanoidRootPart" },
    retroface = { "Head" },
    larm = { "Left Arm", "LeftUpperArm", "LeftLowerArm" },
    rarm = { "Right Arm", "RightUpperArm", "RightLowerArm" },
    lleg = { "Left Leg", "LeftUpperLeg", "LeftLowerLeg" },
    rleg = { "Right Leg", "RightUpperLeg", "RightLowerLeg" },
}
-- per-accessory placement adjustment (editable): ox/oy/oz = stud offset,
-- rx/ry/rz = rotation degrees. these are the live values the UI edits.
local CONFIG = {
    torsowhite = { ox = 0, oy = -1.5, oz = 0, rx = 0, ry = 0, rz = 0 },
    retroface = { ox = 0, oy = 0, oz = 0, rx = 0, ry = 0, rz = 0 },
    larm = { ox = -0.5, oy = -0.5, oz = 0, rx = 0, ry = 0, rz = -90 },
    rarm = { ox = -0.5, oy = -0.5, oz = 0, rx = 0, ry = 0, rz = -90 },
    lleg = { ox = 0.5, oy = -0.5, oz = 0, rx = 0, ry = 0, rz = -90 },
    rleg = { ox = 0.5, oy = -0.5, oz = 0, rx = 0, ry = 0, rz = -90 },
}
local function makeAdj(cfg)
    return CFrame.new(cfg.ox, cfg.oy, cfg.oz) * CFrame.Angles(math.rad(cfg.rx), math.rad(cfg.ry), math.rad(cfg.rz))
end

--[[ NETLESS (ported from Reanimation.txt's SetUACFrameNetless): parts stay
     UNANCHORED but are moved purely by CFrame every frame, with a constant
     tiny upward velocity (~25) so the client keeps network ownership and the
     server never simulates or fights them. zeroed physics (Massless +
     CustomPhysicalProperties) makes them kinematic, so nothing can push or
     ragdoll them and they never get "reverted" by the server. ]]--
local NETLESS_VELOCITY = 25.01
local netlessClaims = {}
local netlessLastCf = {}
local function netless(part)
    part.CanCollide = false
    part.Massless = true
    part.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0, 0, 0, 0)
end
local function driveNetless(handle, newcf, tvel, dt)
    if dt <= 0 then return end
    if not handle:IsGrounded() then
        local timing = os.clock()
        local idleoff = Vector3.new(
            math.sin(timing * 14), math.sin(timing * 15 + 1.0472), math.sin(timing * 16 + 2.0944)
        ) * 0.001
        local netlessv = NETLESS_VELOCITY + (math.sin(timing * 0.5) + 1) / 2
        local lastcf = netlessLastCf[handle] or handle.CFrame
        local lastpos = lastcf.Position
        local vel = (newcf.Position - lastpos) / dt
        local rvel = lastcf:ToObjectSpace(newcf)
        local a, b = rvel:ToAxisAngle()
        rvel = (a * b) / dt
        netlessLastCf[handle] = newcf
        local claimtime = netlessClaims[handle]
        if claimtime then
            if timing - claimtime < 5.67 then
                handle.Massless = false
                handle.CustomPhysicalProperties = nil
            else
                handle.Massless = true
                handle.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0, 0, 0, 0)
            end
            vel += tvel
            vel *= Vector3.new(1, 0, 1)
            if vel.Magnitude > netlessv then
                vel = vel.Unit * netlessv
            end
            handle.AssemblyLinearVelocity = Vector3.new(vel.X, netlessv, vel.Z)
        else
            netlessClaims[handle] = timing
            handle.AssemblyLinearVelocity = Vector3.new(0, netlessv * 2, 0)
        end
        handle.CFrame = newcf
        handle.AssemblyAngularVelocity = rvel + idleoff
    else
        netlessClaims[handle] = nil
        netlessLastCf[handle] = handle.CFrame
    end
end

local function findPart(model, names)
    if not names then return nil end
    for _, name in ipairs(names) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            return p
        end
    end
    return nil
end

--[[ ZEON-FAITHFUL SPLIT: corpse + invisible driver ]]--
local function setup(c)
    if not (c and c.Parent) then return end
    activeChar = c

    -- remove constraints so the corpse never physics-ragdolls
    local function antiragdoll(v)
        if v:IsA("HingeConstraint") or v:IsA("BallSocketConstraint") then
            v.Parent = nil
        end
    end
    for _, v in c:GetDescendants() do antiragdoll(v) end
    c.DescendantAdded:Connect(antiragdoll)

    -- fresh intact clone FIRST (Zeon order: clone before ChangeState)
    c.Archivable = true
    local cl = c:Clone()
    cl.Parent = ws

    -- CRITICAL: original humanoid -> Physics state. when the corpse joints
    -- break at loadtime it simulates instead of dying -> no Died -> no respawn
    local hum = c:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function()
            for _, track in hum:GetPlayingAnimationTracks() do
                track:Stop()
            end
            hum:ChangeState(Enum.HumanoidStateType.Physics)
        end)
    end

    -- original parts -> child corpse model
    local model = Instance.new("Model", c)
    model.Name = "Corpse"
    for _, v in c:GetChildren() do
        if v ~= model then
            v.Parent = model
        end
    end
    for _, v in model:GetDescendants() do
        if v:IsA("LocalScript") then
            v.Disabled = true
        end
    end

    -- corpse: noclip until it breaks, then settle as a collidable pile
    for _, v in model:GetDescendants() do
        if v:IsA("BasePart") then
            v.CanCollide = false
        end
    end
    task.delay(loadtime, function()
        pcall(model.BreakJoints, model)
        for _, v in model:GetDescendants() do
            if v:IsA("BasePart") then
                v.CanCollide = true
                v.Massless = false
                v.Anchored = false
            end
        end
    end)

    -- fresh parts back into c = the invisible driver
    for _, v in cl:GetChildren() do
        v.Parent = c
    end
    cl:Destroy()

    -- hide ONLY the driver; corpse stays visible. NOTE: the driver keeps its
    -- own accessory copies (they stay invisible, only their Handle position
    -- is used as the target the visible handles follow).
    for _, v in c:GetDescendants() do
        if not v:IsDescendantOf(model) then
            if v:IsA("BasePart") then
                v.Transparency = 1
                v.Anchored = false
            elseif v:IsA("Decal") then
                v.Transparency = 1
            elseif v:IsA("ForceField") then
                v.Visible = false
            elseif v:IsA("Sound") then
                v.Playing = false
            elseif v:IsA("ParticleEmitter") or v:IsA("Fire") or v:IsA("Smoke") or v:IsA("Sparkles") or v:IsA("Trail") or v:IsA("BillboardGui") or v:IsA("SurfaceGui") then
                v.Enabled = false
            end
        end
    end

    -- driver noclips so it never gets stuck on the pile; the root keeps
    -- collision so the driver can't fall through the floor
    local root = c:FindFirstChild("HumanoidRootPart")
    for _, v in c:GetDescendants() do
        if v:IsA("BasePart") and (not v:IsDescendantOf(model)) and (v ~= root) then
            v.CanCollide = false
        end
    end

    --[[ NETLESS BODY: zero the invisible driver's physics so the server never
         simulates it, and pin the root's PhysicsRepRootPart to a hidden
         anchored anchor at the death spot so the server sees the player lying
         there instead of walking around after the kill. ]]--
    local NETLESS_BODY = true
    if NETLESS_BODY then
        for _, v in c:GetDescendants() do
            if v:IsA("BasePart") and (not v:IsDescendantOf(model)) and (v ~= root) then
                netless(v)
            end
        end
        local repAnchor = Instance.new("Part")
        repAnchor.Name = "ZeonRepAnchor"
        repAnchor.Size = Vector3.new(1, 1, 1)
        repAnchor.Transparency = 1
        repAnchor.Anchored = true
        repAnchor.CanCollide = false
        repAnchor.CanQuery = false
        repAnchor.CanTouch = false
        repAnchor.Parent = ws
        repAnchor.CFrame = root and root.CFrame or c:GetPivot()
        task.spawn(function()
            while c and c.Parent do
                if root and root.Parent then
                    pcall(sethiddenproperty, root, "PhysicsRepRootPart", repAnchor)
                end
                heartbeat:Wait()
            end
        end)
    end

    --[[ ACCESSORIES: each visible handle follows its matching DRIVER BODY
         PART (BODY_TARGET) so the walk cycle swings the limbs, instead of
         copying the fresh handle's root-anchored weld. the world offset is
         captured from the fresh handle (which keeps the server's intact
         AccessoryWeld) so the rig keeps its exact equipped position; the
         per-accessory CONFIG adjustment is applied on top and is editable
         live from the UI. once paired the visible handle is reparented into
         the character and driven NETLESS (unanchored, CFrame every frame,
         zeroed physics) so it streams with the player and the server never
         simulates it. pairing is dynamic:
         -gh accessories arrive AFTER the split, so we re-scan on every new
         accessory / body part. ]]--
    local hatData = {}

    local function pairAccessories()
        for _, acc in model:GetDescendants() do
            if acc:IsA("Accessory") then
                local handle = acc:FindFirstChild("Handle")
                if handle and not hatData[acc] then
                    local key = normName(acc.Name)
                    local targets = BODY_TARGET[key]
                    if targets then
                        local part = findPart(c, targets)
                        if part then
                            -- capture the offset from the driver body part to
                            -- the fresh handle (server-placed position)
                            local freshAcc, freshHandle
                            for _, v in c:GetChildren() do
                                if v:IsA("Accessory") and normName(v.Name) == key then
                                    freshAcc = v
                                    break
                                end
                            end
                            freshHandle = freshAcc and freshAcc:FindFirstChild("Handle")
                            local ref = freshHandle or handle
                            local rel = part.CFrame:ToObjectSpace(ref.CFrame)
                            hatData[acc] = {
                                Handle = handle,
                                Part = part,
                                Rel = rel,
                                Key = key,
                            }
                            -- once paired, move the visible handle INTO the
                            -- character so it streams with the player (a corpse
                            -- child gets culled / loses client ownership when
                            -- you walk away). NETLESS replaces anchoring: the
                            -- handle stays unanchored but is driven by CFrame
                            -- every frame with zeroed physics, so the server
                            -- never simulates it and can't reset it.
                            netless(handle)
                            if acc.Parent ~= c then
                                acc.Name = key .. "Vis"
                                local weld = handle:FindFirstChildOfClass("AccessoryWeld")
                                if weld then
                                    weld:Destroy()
                                end
                                acc.Parent = c
                            end
                        end
                    end
                end
            end
        end
    end
    pairAccessories()

    model.DescendantAdded:Connect(function(v)
        if v:IsA("Accessory") or v:IsA("BasePart") then
            task.delay(0.1, pairAccessories)
        end
    end)
    c.DescendantAdded:Connect(function(v)
        if v:IsA("Accessory") or v:IsA("BasePart") then
            task.delay(0.1, pairAccessories)
        end
    end)
    -- some accessories land seconds after the split; keep trying until the
    -- corpse is gone
    task.spawn(function()
        while model and model.Parent do
            task.wait(0.5)
            pairAccessories()
        end
    end)

    local hatCon
    hatCon = heartbeat:Connect(function(dt)
        if not (model and c and c.Parent) then
            hatCon:Disconnect()
            return
        end
        for _, data in hatData do
            local handle, part = data.Handle, data.Part
            if handle and handle.Parent and part and part.Parent then
                local cf = part.CFrame * data.Rel * makeAdj(CONFIG[data.Key])
                driveNetless(handle, cf, part.Velocity, dt)
            end
        end
    end)

    -- keep the driver humanoid alive
    local hum1 = c:FindFirstChildOfClass("Humanoid")
    local hum0 = model:FindFirstChildOfClass("Humanoid")
    if hum1 then
        pcall(function()
            hum1.BreakJointsOnDeath = false
            hum1.MaxHealth = 9e9
            hum1.Health = 9e9
        end)
        ws.CurrentCamera.CameraSubject = hum1
        -- keep the camera glued to the invisible driver humanoid; the game's
        -- camera script fights us on spawn, so re-assert it every frame
        task.spawn(function()
            while c and c.Parent and hum1 and hum1.Parent do
                if ws.CurrentCamera and ws.CurrentCamera.CameraSubject ~= hum1 then
                    ws.CurrentCamera.CameraSubject = hum1
                end
                renderstepped:Wait()
            end
        end)
        if hum0 then
            hum0:GetPropertyChangedSignal("Jump"):Connect(function()
                if hum1 then
                    hum1.Jump = hum0.Jump
                end
            end)
        end
    end

    -- simulation radius net bypass (keeps network ownership of the driver)
    task.spawn(function()
        while c and c.Parent do
            pcall(sethiddenproperty, lp, "SimulationRadius", 1000)
            heartbeat:Wait()
        end
    end)

    -- block the reset button from breaking the reanimation
    local rb = Instance.new("BindableEvent", c)
    rb.Event:Connect(function()
        pcall(rb.Destroy, rb)
        sg:SetCore("ResetButtonCallback", true)
        if model and hum0 and (hum0.Health > 0) then
            pcall(model.BreakJoints, model)
            hum0.Health = 0
        end
        respawnrequest()
    end)
    sg:SetCore("ResetButtonCallback", rb)
    task.spawn(function()
        while c and c.Parent do
            task.wait()
        end
        sg:SetCore("ResetButtonCallback", true)
    end)
end

--[[ ADJUST UI: tweak each accessory's offset/rotation live, then hit COPY
     to get a ready-to-paste CONFIG table to send to the assistant. ]]--
local function buildUI()
    local PlayerGui = lp:WaitForChild("PlayerGui")
    local gui = Instance.new("ScreenGui")
    gui.Name = "ZeonAdjustUI"
    gui.ResetOnSpawn = false
    gui.Parent = PlayerGui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 300, 0, 300)
    frame.Position = UDim2.new(1, -310, 0, 10)
    frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.Parent = gui
    frame.Active = true
    frame.Draggable = true

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 24)
    title.BackgroundTransparency = 1
    title.Text = "Zeon Rig Adjust"
    title.TextColor3 = Color3.new(1, 1, 1)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.Parent = frame

    local keys = { "torsowhite", "retroface", "larm", "rarm", "lleg", "rleg" }
    local keyButtons = {}
    local selected = keys[1]
    local fields = {} -- field name -> TextBox

    local function applySelected()
        local cfg = CONFIG[selected]
        local labels = { "ox", "oy", "oz", "rx", "ry", "rz" }
        for _, n in ipairs(labels) do
            if fields[n] then
                fields[n].Text = string.format("%g", cfg[n])
            end
        end
    end

    local function readField(n)
        local v = tonumber(fields[n].Text)
        if v then
            CONFIG[selected][n] = v
        end
    end

    local y = 30
    for i, k in ipairs(keys) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 90, 0, 22)
        btn.Position = UDim2.new(0, (i - 1) % 3 * 100, 0, y + math.floor((i - 1) / 3) * 26)
        btn.BackgroundColor3 = k == selected and Color3.fromRGB(60, 120, 200) or Color3.fromRGB(45, 45, 45)
        btn.Text = k
        btn.TextSize = 11
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.Gotham
        btn.BorderSizePixel = 0
        btn.Parent = frame
        btn.MouseButton1Click:Connect(function()
            selected = k
            for _, b in ipairs(keyButtons) do
                b.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
            end
            btn.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
            applySelected()
        end)
        keyButtons[i] = btn
    end
    y = y + 56

    local rowNames = {
        { "ox", "x" }, { "oy", "y" }, { "oz", "z" },
        { "rx", "x deg" }, { "ry", "y deg" }, { "rz", "z deg" },
    }
    for i, pair in ipairs(rowNames) do
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(0, 50, 0, 22)
        lbl.Position = UDim2.new(0, 5, 0, y)
        lbl.BackgroundTransparency = 1
        lbl.Text = pair[2]
        lbl.TextColor3 = Color3.new(1, 1, 1)
        lbl.TextSize = 12
        lbl.Font = Enum.Font.Gotham
        lbl.Parent = frame
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(0, 80, 0, 22)
        box.Position = UDim2.new(0, 60, 0, y)
        box.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
        box.TextColor3 = Color3.new(1, 1, 1)
        box.TextSize = 12
        box.Font = Enum.Font.Gotham
        box.BorderSizePixel = 0
        box.Text = "0"
        box.Parent = frame
        box.FocusLost:Connect(function()
            readField(pair[1])
        end)
        fields[pair[1]] = box
        y = y + 26
    end

    local copy = Instance.new("TextButton")
    copy.Size = UDim2.new(1, -10, 0, 26)
    copy.Position = UDim2.new(0, 5, 0, y + 4)
    copy.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
    copy.Text = "COPY CONFIG"
    copy.TextSize = 13
    copy.TextColor3 = Color3.new(1, 1, 1)
    copy.Font = Enum.Font.GothamBold
    copy.BorderSizePixel = 0
    copy.Parent = frame
    copy.MouseButton1Click:Connect(function()
        readField("ox") readField("oy") readField("oz")
        readField("rx") readField("ry") readField("rz")
        local parts = {}
        for _, k in ipairs(keys) do
            local c = CONFIG[k]
            parts[#parts + 1] = string.format(
                "    %s = { ox = %g, oy = %g, oz = %g, rx = %g, ry = %g, rz = %g }",
                k, c.ox, c.oy, c.oz, c.rx, c.ry, c.rz
            )
        end
        local out = "local CONFIG = {\n" .. table.concat(parts, ",\n") .. "\n}"
        pcall(setclipboard, out)
        copy.Text = "COPIED"
        task.delay(1.2, function() copy.Text = "COPY CONFIG" end)
    end)

    applySelected()
end

--[[ CUSTOM ANIMATIONS: load any rbxassetid onto the invisible driver's
     humanoid. the driver's parts animate normally (default game anims + your
     own), and the visible handles copy their body-part CFrame every frame via
     driveNetless, so a custom animation ID plays on your reanimated body
     without the game allowing the asset.
     default: auto-swap idle <-> walk from the IDs below, driven by the
     driver's MoveDirection. override: -anim <id> in chat, or X key. -animstop
     / -animauto returns to auto mode. ]]--
local IDLE_ID = "113961615420702"
local WALK_ID = "133313306374862"

local customTrack, customLastId
local autoMode = true
local idleTrack, walkTrack
local activeTrack

local function loadTrack(hum, id)
    if not id then return nil end
    local anim = Instance.new("Animation")
    anim.AnimationId = "rbxassetid://" .. tostring(id)
    local ok, track = pcall(hum.LoadAnimation, hum, anim)
    if not (ok and track) then
        warn("anim load failed for " .. tostring(id))
        return nil
    end
    track.Priority = Enum.AnimationPriority.Action
    track.Looped = true
    return track
end

local function stopTrack(track)
    if track then
        pcall(track.Stop, track)
        pcall(track.Destroy, track)
    end
end

local function playTrack(track)
    if track and track.Parent and track.IsPlaying ~= true then
        pcall(track.Play, track)
    end
end

local function playCustom(id)
    if not (activeChar and activeChar.Parent) then return end
    local hum = activeChar:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    autoMode = false
    stopTrack(customTrack)
    customTrack = loadTrack(hum, id)
    playTrack(customTrack)
    customLastId = id
end

local function stopCustom()
    stopTrack(customTrack)
    customTrack = nil
end

-- auto idle/walk loop: respects activeChar going away / respawns
task.spawn(function()
    while true do
        task.wait()
        if not (activeChar and activeChar.Parent) then
            activeTrack = nil
            continue
        end
        local hum = activeChar:FindFirstChildOfClass("Humanoid")
        if not hum then continue end
        if not idleTrack or not idleTrack.Parent then
            idleTrack = loadTrack(hum, IDLE_ID)
        end
        if not walkTrack or not walkTrack.Parent then
            walkTrack = loadTrack(hum, WALK_ID)
        end
        if not autoMode then continue end
        local moving = hum.MoveDirection.Magnitude > 0.1
        local want = moving and walkTrack or idleTrack
        if want and want ~= activeTrack then
            if activeTrack then
                pcall(activeTrack.Stop, activeTrack)
            end
            activeTrack = want
            playTrack(activeTrack)
        end
    end
end)

local function onChatMsg(text)
    text = (text or ""):lower()
    local num = text:match("^-anim%s+(%d+)")
    if num then
        playCustom(num)
    elseif text == "-animauto" then
        autoMode = true
        stopCustom()
    elseif text == "-animstop" then
        stopCustom()
    end
end
-- legacy + TextChatService fallback (same pattern as send())
local TextChatService = game:GetService("TextChatService")
local TChannels = TextChatService:FindFirstChild("TextChannels")
local RBXGeneral = TChannels and TChannels:FindFirstChild("RBXGeneral")
local function hookChat()
    local ok = pcall(function()
        lp.Chatted:Connect(onChatMsg)
    end)
    if not ok and RBXGeneral then
        pcall(function()
            RBXGeneral.MessageReceived:Connect(function(message)
                if message and message.Text then
                    onChatMsg(message.Text)
                end
            end)
        end)
    end
end
hookChat()

local UIS = game:GetService("UserInputService")
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.X then
        if customTrack then
            autoMode = true
            stopCustom()
        elseif customLastId then
            playCustom(customLastId)
        end
    end
end)

--[[ boot ]]--
respawnrequest()

local function doGrab()
    send("-gh " .. GH_IDS)
    task.wait(1.6)
    send("-sh")
    task.wait(6.7)
    send("-net")
    task.wait(0.6)

    local c = lp.Character
    if not (c and c.Parent) then
        c = lp.CharacterAdded:Wait()
    end
    setup(c)
end

-- run the chat sequence first (Zeon order: -gh, -sh, -net, then setupOwn)
task.spawn(doGrab)
task.spawn(buildUI)

-- on any respawn: rebuild the whole thing on the fresh character
lp.CharacterAdded:Connect(function(newChar)
    task.wait()
    respawnrequest()
    setup(newChar)
end)
