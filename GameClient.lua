--[[ DRONE CHASE — клиентский скрипт
Положить как LocalScript в StarterPlayer > StarterPlayerScripts.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local mouse = player:GetMouse()

local folder = RS:WaitForChild("DroneChase")
local FireEv, SwitchEv, StateEv = folder:WaitForChild("Fire"), folder:WaitForChild("Switch"), folder:WaitForChild("State")

------------------------------------------------------------------ GUI
local gui = Instance.new("ScreenGui")
gui.Name = "DroneChaseGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local function label(pos, size, textSize)
	local l = Instance.new("TextLabel")
	l.Position = pos
	l.Size = size
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.BackgroundTransparency = 0.4
	l.BackgroundColor3 = Color3.new(0, 0, 0)
	l.TextColor3 = Color3.new(1, 1, 1)
	l.Font = Enum.Font.GothamBold
	l.TextSize = textSize
	l.TextWrapped = true
	l.Text = ""
	l.Parent = gui
	return l
end

local msgLabel   = label(UDim2.new(0.5, 0, 0, 10), UDim2.fromOffset(620, 40), 20)
local timerLabel = label(UDim2.new(0.5, 0, 0, 56), UDim2.fromOffset(160, 30), 18)
local helpLabel  = label(UDim2.new(0.5, 0, 1, -90), UDim2.fromOffset(560, 60), 16)
helpLabel.Visible = false

local progBg = Instance.new("Frame")
progBg.AnchorPoint = Vector2.new(0.5, 0)
progBg.Position = UDim2.new(0.5, 0, 0, 92)
progBg.Size = UDim2.fromOffset(400, 10)
progBg.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
progBg.Parent = gui
local progFill = Instance.new("Frame")
progFill.Size = UDim2.fromScale(0, 1)
progFill.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
progFill.BorderSizePixel = 0
progFill.Parent = progBg

------------------------------------------------------------------ СОСТОЯНИЕ
local conn = nil
local drone, droneCfg = nil, nil

local function stopControl()
	if conn then conn:Disconnect() conn = nil end
	drone = nil
	helpLabel.Visible = false
	mouse.Icon = ""
	camera.FieldOfView = 70
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then camera.CameraSubject = hum end
end

local function showDroneHelp()
	helpLabel.Visible = true
	helpLabel.TextColor3 = droneCfg.color
	helpLabel.Text = "Дрон: " .. droneCfg.name .. "   [1] Скаут  [2] Бомбер  [3] Ракетчик\nWASD — полёт, E/Q — вверх/вниз, ЛКМ — огонь"
end

------------------------------------------------------------------ ДРОН (охотник)
local function startDrone(d, cfg)
	stopControl()
	drone, droneCfg = d, cfg
	camera.CameraSubject = d
	mouse.Icon = "rbxasset://textures/GunCursor.png"
	showDroneHelp()

	local align = d:WaitForChild("Align")
	conn = RunService.RenderStepped:Connect(function(dt)
		if not drone or not drone.Parent then return end
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
		local right = Vector3.new(-flat.Z, 0, flat.X)

		local move = Vector3.zero
		if UIS:IsKeyDown(Enum.KeyCode.W) then move += flat end
		if UIS:IsKeyDown(Enum.KeyCode.S) then move -= flat end
		if UIS:IsKeyDown(Enum.KeyCode.D) then move += right end
		if UIS:IsKeyDown(Enum.KeyCode.A) then move -= right end
		if UIS:IsKeyDown(Enum.KeyCode.E) then move += Vector3.yAxis end
		if UIS:IsKeyDown(Enum.KeyCode.Q) then move -= Vector3.yAxis end
		if move.Magnitude > 0 then move = move.Unit end

		local vel = drone.AssemblyLinearVelocity:Lerp(move * droneCfg.speed, math.min(1, dt * 4))
		if (drone.Position.Y > 260 and vel.Y > 0) or (drone.Position.Y < 95 and vel.Y < 0) then
			vel = Vector3.new(vel.X, 0, vel.Z)
		end
		drone.AssemblyLinearVelocity = vel

		local tilt = CFrame.Angles(-vel:Dot(flat) / droneCfg.speed * 0.35, 0, -vel:Dot(right) / droneCfg.speed * 0.35)
		align.CFrame = CFrame.lookAt(Vector3.zero, flat) * tilt
	end)
end

UIS.InputBegan:Connect(function(input, processed)
	if processed or not drone then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		FireEv:FireServer(mouse.Hit.Position)
	elseif input.KeyCode == Enum.KeyCode.One then
		SwitchEv:FireServer(1)
	elseif input.KeyCode == Enum.KeyCode.Two then
		SwitchEv:FireServer(2)
	elseif input.KeyCode == Enum.KeyCode.Three then
		SwitchEv:FireServer(3)
	end
end)

-- автоогонь Скаута при зажатой ЛКМ
task.spawn(function()
	while true do
		task.wait(0.15)
		if drone and droneCfg and droneCfg.weapon == "gun" and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			FireEv:FireServer(mouse.Hit.Position)
		end
	end
end)

------------------------------------------------------------------ МАШИНА (беглец)
local function startCar(car, maxSpeed)
	stopControl()
	local body = car:WaitForChild("Body")
	local seat = car:WaitForChild("Seat")
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false) end
	camera.CameraSubject = seat
	helpLabel.Visible = true
	helpLabel.TextColor3 = Color3.fromRGB(60, 220, 90)
	helpLabel.Text = "Ты — БЕГЛЕЦ! W/S — газ/тормоз, A/D — руль.\nОбъезжай блоки и доедь до финиша, пока дрон тебя не взорвал!"

	local speed = 0
	conn = RunService.Heartbeat:Connect(function(dt)
		if not body.Parent then stopControl() return end
		local thr, steer = seat.ThrottleFloat, seat.SteerFloat
		local target = thr >= 0 and thr * maxSpeed or thr * maxSpeed * 0.4
		speed += (target - speed) * math.min(1, dt * (thr == 0 and 0.8 or 1.6))

		local look = body.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.1 then return end
		flat = flat.Unit
		local v = body.AssemblyLinearVelocity
		body.AssemblyLinearVelocity = Vector3.new(flat.X * speed, math.min(v.Y, 30), flat.Z * speed)
		body.AssemblyAngularVelocity = Vector3.new(0, -steer * 2.2 * math.clamp(speed / 15, -1, 1), 0)
		camera.FieldOfView = 70 + 14 * math.clamp(math.abs(speed) / maxSpeed, 0, 1) -- ощущение скорости
	end)
end

------------------------------------------------------------------ ВИЗУАЛ
-- Вращение пропеллеров дронов и колёс машин: сервер помечает их Weld-ы тегами,
-- каждый клиент крутит их у себя (плавно и без сетевого трафика).
local spins = setmetatable({}, { __mode = "k" })
local function turn(w, axis, delta)
	local s = spins[w]
	if not s then
		s = { c0 = w.C0, angle = 0 }
		spins[w] = s
	end
	s.angle = (s.angle + delta) % (math.pi * 2)
	w.C0 = s.c0 * CFrame.fromAxisAngle(axis, s.angle)
end

RunService.RenderStepped:Connect(function(dt)
	for _, w in ipairs(CollectionService:GetTagged("DroneRotor")) do
		turn(w, Vector3.yAxis, dt * 45)
	end
	for _, w in ipairs(CollectionService:GetTagged("CarWheel")) do
		local b = w.Part0
		if b then turn(w, Vector3.xAxis, -b.AssemblyLinearVelocity:Dot(b.CFrame.LookVector) / 1.05 * dt) end
	end
end)

------------------------------------------------------------------ СОБЫТИЯ
StateEv.OnClientEvent:Connect(function(kind, a, b)
	if kind == "msg" then
		msgLabel.Text = a
	elseif kind == "timer" then
		timerLabel.Text = "⏱ " .. tostring(a)
		progFill.Size = UDim2.fromScale(math.clamp(b, 0, 1), 1)
	elseif kind == "drone" then
		startDrone(a, b)
	elseif kind == "cfg" then
		droneCfg = a
		showDroneHelp()
	elseif kind == "car" then
		startCar(a, b)
	elseif kind == "end" then
		stopControl()
		timerLabel.Text = ""
		progFill.Size = UDim2.fromScale(0, 1)
	end
end)
