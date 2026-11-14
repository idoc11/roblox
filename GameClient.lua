--[[ DRONE CHASE — клиентский скрипт
Положить как LocalScript в StarterPlayer > StarterPlayerScripts.
Клиент только управляет и показывает: урон, попадания и перезарядку считает сервер.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local mouse = player:GetMouse()

local folder = RS:WaitForChild("DroneChase")
local FireEv, SwitchEv, StateEv = folder:WaitForChild("Fire"), folder:WaitForChild("Switch"), folder:WaitForChild("State")
local ReloadEv = folder:WaitForChild("Reload", 5)

------------------------------------------------------------------ ЗВУКИ
-- Встроенные звуки Roblox: { файл, громкость, высота тона }. Можно заменить на свои rbxassetid://...
local SOUNDS = {
	shot         = { "rbxasset://sounds/paintball.wav", 0.5, 1.7 },
	bombDrop     = { "rbxasset://sounds/swoosh.wav", 0.8, 0.7 },
	rocketLaunch = { "rbxasset://sounds/Rocket shot.wav", 0.9, 1 },
	explosion    = { "rbxasset://sounds/collide.wav", 1, 1 },
	bigExplosion = { "rbxasset://sounds/collide.wav", 1.6, 0.6 },
	switch       = { "rbxasset://sounds/switch.wav", 0.8, 0.8 },
	reload       = { "rbxasset://sounds/switch.wav", 0.6, 1.3 },
	reloaded     = { "rbxasset://sounds/button.wav", 0.7, 1.2 },
	empty        = { "rbxasset://sounds/clickfast.wav", 0.6, 1 },
	hit          = { "rbxasset://sounds/electronicpingshort.wav", 0.35, 1.6 },
	crit         = { "rbxasset://sounds/electronicpingshort.wav", 0.5, 2.2 },
	warn         = { "rbxasset://sounds/electronicpingshort.wav", 0.6, 1 },
}

------------------------------------------------------------------ GUI
local gui = Instance.new("ScreenGui")
gui.Name = "DroneChaseGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

-- pos nil → звук интерфейса; иначе объёмный звук в точке мира
local function play(name, pos)
	local def = SOUNDS[name]
	if not def then return end
	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed = def[1], def[2], def[3]
	local holder = gui
	if typeof(pos) == "Vector3" then
		holder = Instance.new("Attachment")
		holder.Position = pos
		holder.Parent = workspace.Terrain
		s.RollOffMinDistance, s.RollOffMaxDistance = 40, 700
		Debris:AddItem(holder, 4)
	end
	s.Parent = holder
	s:Play()
	Debris:AddItem(s, 4)
end

local function label(pos, size, textSize, parent)
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
	l.Parent = parent or gui
	return l
end

local function bar(pos, size, color, parent)
	local bg = Instance.new("Frame")
	bg.AnchorPoint = Vector2.new(0.5, 0)
	bg.Position = pos
	bg.Size = size
	bg.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	bg.BorderSizePixel = 0
	bg.Parent = parent or gui
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = bg
	return bg, fill
end

local msgLabel   = label(UDim2.new(0.5, 0, 0, 10), UDim2.fromOffset(620, 40), 20)
local timerLabel = label(UDim2.new(0.5, 0, 0, 56), UDim2.fromOffset(160, 30), 18)
local helpLabel  = label(UDim2.new(0.5, 0, 1, -90), UDim2.fromOffset(600, 60), 16)
helpLabel.Visible = false
local progBg, progFill = bar(UDim2.new(0.5, 0, 0, 92), UDim2.fromOffset(400, 10), Color3.fromRGB(60, 220, 90))

-- панель оружия охотника: три дрона, боезапас, полоса перезарядки
local weaponPanel = Instance.new("Frame")
weaponPanel.AnchorPoint = Vector2.new(1, 1)
weaponPanel.Position = UDim2.new(1, -16, 1, -16)
weaponPanel.Size = UDim2.fromOffset(250, 104)
weaponPanel.BackgroundColor3 = Color3.new(0, 0, 0)
weaponPanel.BackgroundTransparency = 0.4
weaponPanel.BorderSizePixel = 0
weaponPanel.Visible = false
weaponPanel.Parent = gui
local SLOT_NAMES = { "1 Скаут", "2 Бомбер", "3 Ракетчик" }
local slots = {}
for i = 1, 3 do
	slots[i] = label(UDim2.new((i - 0.5) / 3, 0, 0, 6), UDim2.new(1 / 3, -8, 0, 22), 13, weaponPanel)
	slots[i].Text = SLOT_NAMES[i]
end
local ammoLabel = label(UDim2.new(0.5, 0, 0, 32), UDim2.new(1, -12, 0, 40), 28, weaponPanel)
ammoLabel.BackgroundTransparency = 1
local _, reloadFill = bar(UDim2.new(0.5, 0, 0, 80), UDim2.new(1, -24, 0, 10), Color3.fromRGB(255, 190, 60), weaponPanel)

-- панель беглеца: прочность машины и ракетная тревога
local hpBg, hpFill = bar(UDim2.new(0.5, 0, 1, -116), UDim2.fromOffset(360, 14), Color3.fromRGB(60, 220, 90))
hpBg.Visible = false
local warnLabel = label(UDim2.new(0.5, 0, 0.22, 0), UDim2.fromOffset(300, 36), 22)
warnLabel.Text = "⚠ РАКЕТА! УКЛОНЯЙСЯ"
warnLabel.TextColor3 = Color3.fromRGB(255, 70, 70)
warnLabel.Visible = false

-- прицельные метки: маркер попадания, урон, захват цели
local function floating(textSize)
	local l = label(UDim2.fromOffset(0, 0), UDim2.fromOffset(170, 26), textSize)
	l.BackgroundTransparency = 1
	l.TextStrokeTransparency = 0.4
	l.Visible = false
	return l
end
local hitLabel, lockLabel = floating(22), floating(16)

local hurtFlash = Instance.new("Frame")
hurtFlash.Size = UDim2.fromScale(1, 1)
hurtFlash.BackgroundColor3 = Color3.fromRGB(255, 30, 30)
hurtFlash.BackgroundTransparency = 1
hurtFlash.BorderSizePixel = 0
hurtFlash.ZIndex = 0
hurtFlash.Parent = gui

------------------------------------------------------------------ СОСТОЯНИЕ
local conn = nil
local drone, droneCfg = nil, nil
local car = nil          -- машина, которой управляет этот игрок
local pendingPush = nil  -- ударная волна от сервера, ещё не применённая к машине
local hitUntil, lockNoteUntil, nextWarn = 0, 0, 0

local DEFAULT_BOUNDS = { minY = 95, maxY = 260, minX = -1e5, maxX = 1e5, maxZ = 1e5 }

local function stopControl()
	if conn then conn:Disconnect() conn = nil end
	drone, car, pendingPush = nil, nil, nil
	helpLabel.Visible = false
	weaponPanel.Visible, hpBg.Visible, warnLabel.Visible = false, false, false
	hitLabel.Visible, lockLabel.Visible = false, false
	mouse.Icon = ""
	mouse.TargetFilter = nil
	camera.FieldOfView = 70
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then camera.CameraSubject = hum end
end

local function showDroneHelp()
	helpLabel.Visible = true
	helpLabel.TextColor3 = droneCfg.color
	helpLabel.Text = "Дрон: " .. droneCfg.name .. "   [1] Скаут  [2] Бомбер  [3] Ракетчик\nWASD — полёт, E/Q — вверх/вниз, ЛКМ — огонь, R — перезарядка"
end

------------------------------------------------------------------ ДРОН (охотник)
-- у границы зоны полёта скорость наружу плавно гасится, за границей дрон возвращается внутрь
local function soft(pos, lo, hi, v)
	local m = 14
	if v < 0 and pos < lo + m then v = v * math.clamp((pos - lo) / m, 0, 1) end
	if v > 0 and pos > hi - m then v = v * math.clamp((hi - pos) / m, 0, 1) end
	if pos < lo then v = math.max(v, (lo - pos) * 2) end
	if pos > hi then v = math.min(v, (hi - pos) * 2) end
	return v
end

local function startDrone(d, cfg)
	if not d then warn("DroneChase: дрон не найден") return end
	stopControl()
	drone, droneCfg = d, cfg
	camera.CameraSubject = d
	mouse.TargetFilter = d -- прицел не должен упираться в собственный дрон в центре экрана
	mouse.Icon = "rbxasset://textures/GunCursor.png"
	weaponPanel.Visible = true
	showDroneHelp()

	local align = d:WaitForChild("Align")
	conn = RunService.RenderStepped:Connect(function(dt)
		if not drone or not drone.Parent then return end
		local c = droneCfg
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

		-- инерция: дрон набирает нужную скорость тем быстрее, чем выше agility;
		-- вертикально летит медленнее, тормозит ленивее, чем разгоняется
		local target = Vector3.new(move.X, move.Y * 0.7, move.Z) * c.speed
		local agility = c.agility or 4
		if move.Magnitude == 0 then agility = agility * 0.7 end
		local vel = drone.AssemblyLinearVelocity:Lerp(target, 1 - math.exp(-dt * agility))
		if move.Magnitude == 0 then
			vel += Vector3.new(0, math.sin(os.clock() * 2.2) * 0.6, 0) * dt * 4 -- лёгкое покачивание в висении
		end
		local b, p = c.bounds or DEFAULT_BOUNDS, drone.Position
		vel = Vector3.new(soft(p.X, b.minX, b.maxX, vel.X), soft(p.Y, b.minY, b.maxY, vel.Y), soft(p.Z, -b.maxZ, b.maxZ, vel.Z))
		drone.AssemblyLinearVelocity = vel

		-- крен и тангаж по скорости; у тяжёлого дрона наклон меньше
		local k = (c.tilt or 0.35) / c.speed
		align.CFrame = CFrame.lookAt(Vector3.zero, flat) * CFrame.Angles(-vel:Dot(flat) * k, 0, -vel:Dot(right) * k)
	end)
end

local function fire()
	if not drone then return end
	if (drone:GetAttribute("Ammo") or 1) <= 0 then play("empty") end
	FireEv:FireServer(mouse.Hit.Position) -- только точка прицеливания: попадание и урон считает сервер
end

UIS.InputBegan:Connect(function(input, processed)
	if processed or not drone then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		fire()
	elseif input.KeyCode == Enum.KeyCode.One then
		SwitchEv:FireServer(1)
	elseif input.KeyCode == Enum.KeyCode.Two then
		SwitchEv:FireServer(2)
	elseif input.KeyCode == Enum.KeyCode.Three then
		SwitchEv:FireServer(3)
	elseif input.KeyCode == Enum.KeyCode.R and ReloadEv then
		ReloadEv:FireServer()
	end
end)

-- автоогонь Скаута при зажатой ЛКМ (темп всё равно ограничивает сервер)
task.spawn(function()
	while true do
		local gun = drone and droneCfg and droneCfg.weapon == "gun"
		task.wait(gun and droneCfg.cooldown or 0.15)
		if gun and drone and (drone:GetAttribute("Ammo") or 1) > 0 and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			FireEv:FireServer(mouse.Hit.Position)
		end
	end
end)

------------------------------------------------------------------ МАШИНА (беглец)
local function startCar(model, maxSpeed)
	if not model then warn("DroneChase: машина не найдена") return end
	stopControl()
	car = model
	local body = car:WaitForChild("Body")
	local seat = car:WaitForChild("Seat")
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false) end
	camera.CameraSubject = seat
	hpBg.Visible = true
	helpLabel.Visible = true
	helpLabel.TextColor3 = Color3.fromRGB(60, 220, 90)
	helpLabel.Text = "Ты — БЕГЛЕЦ! W/S — газ/тормоз, A/D — руль.\nОбъезжай блоки и доедь до финиша, пока дрон тебя не взорвал!"

	local speed = 0
	local shove = Vector3.zero -- боковой снос от ударной волны, быстро затухает
	conn = RunService.Heartbeat:Connect(function(dt)
		if not body.Parent then stopControl() return end
		local thr, steer = seat.ThrottleFloat, seat.SteerFloat
		local target = thr >= 0 and thr * maxSpeed or thr * maxSpeed * 0.4
		speed += (target - speed) * math.min(1, dt * (thr == 0 and 0.8 or 1.6))

		local bump = 0
		if pendingPush then -- взрыв рядом: теряем скорость, машину подбрасывает и сносит
			speed *= pendingPush.slow
			shove += pendingPush.side
			bump = pendingPush.up
			pendingPush = nil
		end
		shove *= math.exp(-dt * 3)

		local look = body.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.1 then return end
		flat = flat.Unit
		local v = body.AssemblyLinearVelocity
		body.AssemblyLinearVelocity = Vector3.new(flat.X * speed + shove.X, math.min(v.Y, 30) + bump, flat.Z * speed + shove.Z)
		body.AssemblyAngularVelocity = Vector3.new(0, -steer * 2.2 * math.clamp(speed / 15, -1, 1), 0)
		camera.FieldOfView = 70 + 14 * math.clamp(math.abs(speed) / maxSpeed, 0, 1) -- ощущение скорости
	end)
end

------------------------------------------------------------------ ВИЗУАЛ И ИНДИКАТОРЫ
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

local function atMouse(l, dy)
	l.Position = UDim2.fromOffset(mouse.X, mouse.Y + dy)
end

-- индикаторы охотника: всё читается из атрибутов дрона, которые выставляет сервер
local function updateWeaponHud()
	local c = droneCfg
	local now = workspace:GetServerTimeNow()
	local idx = drone:GetAttribute("Weapon") or 1
	for i, s in ipairs(slots) do
		s.BackgroundColor3 = i == idx and c.color or Color3.new(0, 0, 0)
		s.BackgroundTransparency = i == idx and 0.15 or 0.5
	end
	local ammo, mag = drone:GetAttribute("Ammo") or 0, drone:GetAttribute("Mag") or 0
	local rs, re = drone:GetAttribute("ReloadStart") or 0, drone:GetAttribute("ReloadEnd") or 0
	local switching = now < (drone:GetAttribute("SwitchEnd") or 0)
	if switching then
		ammoLabel.Text, ammoLabel.TextColor3 = "СМЕНА ДРОНА", Color3.new(1, 1, 1)
		reloadFill.Size = UDim2.fromScale(0, 1)
	elseif re > now then
		ammoLabel.Text, ammoLabel.TextColor3 = "ПЕРЕЗАРЯДКА", Color3.fromRGB(255, 190, 60)
		reloadFill.Size = UDim2.fromScale(math.clamp((now - rs) / math.max(re - rs, 0.01), 0, 1), 1)
	else
		ammoLabel.Text = ammo .. " / " .. mag
		ammoLabel.TextColor3 = ammo > 0 and c.color or Color3.fromRGB(255, 70, 70)
		reloadFill.Size = UDim2.fromScale(0, 1)
	end

	-- подсказка захвата для ракет (решение о захвате всё равно принимает сервер при пуске)
	local tick = os.clock()
	local note = tick < lockNoteUntil
	local locked = false
	if not note and c.weapon == "rocket" and c.lockRange then
		local target = workspace:FindFirstChild("RunnerCar")
		local body = target and target:FindFirstChild("Body")
		if body then
			local aim, to = mouse.Hit.Position - drone.Position, body.Position - drone.Position
			if aim.Magnitude > 0.1 and to.Magnitude > 1 and to.Magnitude <= c.lockRange then
				locked = math.acos(math.clamp(aim.Unit:Dot(to.Unit), -1, 1)) <= c.lockCone
			end
		end
		lockLabel.Text = "◎ ЗАХВАТ ЦЕЛИ"
		lockLabel.TextColor3 = Color3.fromRGB(90, 255, 120)
	end
	lockLabel.Visible = note or locked
	atMouse(lockLabel, 22)
	hitLabel.Visible = tick < hitUntil
	atMouse(hitLabel, -40)
end

RunService.RenderStepped:Connect(function(dt)
	for _, w in ipairs(CollectionService:GetTagged("DroneRotor")) do
		turn(w, Vector3.yAxis, dt * 45)
	end
	for _, w in ipairs(CollectionService:GetTagged("CarWheel")) do
		local b = w.Part0
		if b then turn(w, Vector3.xAxis, -b.AssemblyLinearVelocity:Dot(b.CFrame.LookVector) / 1.05 * dt) end
	end

	if drone and drone.Parent and droneCfg then updateWeaponHud() end

	if car and car.Parent then -- индикаторы беглеца
		local hp, max = car:GetAttribute("HP") or 0, car:GetAttribute("MaxHP") or 100
		local k = math.clamp(hp / max, 0, 1)
		hpFill.Size = UDim2.fromScale(k, 1)
		hpFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(60, 220, 90), k)
		local danger = (car:GetAttribute("Missiles") or 0) > 0
		warnLabel.Visible = danger and os.clock() % 0.5 < 0.3
		if danger and os.clock() > nextWarn then
			nextWarn = os.clock() + 0.5
			play("warn")
		end
	end
end)

------------------------------------------------------------------ СОБЫТИЯ
-- Сообщение сервера продублировано атрибутом: его видит и только что зашедший игрок.
local function showMessage()
	msgLabel.Text = folder:GetAttribute("Message") or ""
end
folder:GetAttributeChangedSignal("Message"):Connect(showMessage)
showMessage()

StateEv.OnClientEvent:Connect(function(kind, a, b, c)
	if kind == "msg" then
		msgLabel.Text = a
	elseif kind == "timer" then
		timerLabel.Text = "⏱ " .. tostring(a)
		progFill.Size = UDim2.fromScale(math.clamp(b, 0, 1), 1)
	elseif kind == "drone" then
		startDrone(a or workspace:WaitForChild("Drone", 10), b) -- модель могла ещё не догрузиться
	elseif kind == "cfg" then
		droneCfg = a
		showDroneHelp()
	elseif kind == "car" then
		startCar(a or workspace:WaitForChild("RunnerCar", 10), b)
	elseif kind == "end" then
		stopControl()
		timerLabel.Text = ""
		progFill.Size = UDim2.fromScale(0, 1)
	elseif kind == "sfx" then
		play(a, b)
	elseif kind == "hit" then -- сервер подтвердил попадание: a — урон, b — крит
		hitLabel.Text = (b and "✕ КРИТ −" or "✕ −") .. tostring(math.max(1, math.floor(a + 0.5)))
		hitLabel.TextColor3 = b and Color3.fromRGB(255, 80, 60) or Color3.new(1, 1, 1)
		hitUntil = os.clock() + 0.25
		play(b and "crit" or "hit")
	elseif kind == "lock" then -- ракета ушла: a — был ли захват
		lockLabel.Text = a and "◎ РАКЕТА НАВЕДЕНА" or "○ ПУСК БЕЗ ЗАХВАТА"
		lockLabel.TextColor3 = a and Color3.fromRGB(90, 255, 120) or Color3.fromRGB(255, 190, 60)
		lockNoteUntil = os.clock() + 0.9
	elseif kind == "hurt" then -- по машине попали: короткая красная вспышка экрана
		hurtFlash.BackgroundTransparency = math.clamp(0.9 - a * 0.01, 0.55, 0.9)
		TweenService:Create(hurtFlash, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	elseif kind == "push" and car then -- ударная волна: a — боковой снос, b — подброс, c — множитель скорости
		if typeof(a) == "Vector3" and typeof(b) == "number" and typeof(c) == "number" then
			pendingPush = { side = a, up = b, slow = c }
		end
	end
end)
