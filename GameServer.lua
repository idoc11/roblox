--[[ DRONE CHASE — серверный скрипт
Положить как Script в ServerScriptService.
Охотник управляет дронами, Беглец едет на машине по мосту.
Все модели собираются из деталей Roblox прямо здесь — сторонние ассеты не нужны.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

------------------------------------------------------------------ НАСТРОЙКИ
local BRIDGE_Y      = 100
local BRIDGE_LEN    = 1200
local BRIDGE_WIDTH  = 44
local ROUND_TIME    = 120
local CAR_HP        = 100
local CAR_MAX_SPEED = 70
local RESPAWN_TIME  = 2 -- через сколько секунд возрождается погибший персонаж

-- система раундов: ModuleScript RoundService должен лежать внутри этого скрипта
local roundModule = script:FindFirstChild("RoundService")
if not roundModule then
	error("DroneChase: не найден ModuleScript RoundService. Положите его внутрь скрипта GameServer.")
end
local RoundService = require(roundModule)

-- Баланс: машина проезжает мост примерно за 20–28 с при 100 HP.
-- speed/agility/tilt — полёт (agility: как быстро дрон набирает нужную скорость);
-- dmg/cooldown/mag/reload — урон, пауза между выстрелами, магазин, время перезарядки.
local DRONES = {
	-- СКАУТ: быстрый и вёрткий, скорострельный пулемёт с малым уроном; попадание в моторный отсек — крит
	{ name = "Скаут",    speed = 90, agility = 6,   tilt = 0.45, weapon = "gun",    dmg = 2,  cooldown = 0.1, mag = 30, reload = 1.6, radius = 0,
		range = 450, spread = 0.012, crit = 1.5,
		color = Color3.fromRGB(80, 200, 255), size = Vector3.new(3, 1, 3) },
	-- БОМБЕР: медленный и инертный, две мощные бомбы с большим радиусом и ударной волной, долгая перезарядка
	{ name = "Бомбер",   speed = 48, agility = 2.2, tilt = 0.2,  weapon = "bomb",   dmg = 40, cooldown = 0.9, mag = 2,  reload = 4,   radius = 18,
		push = { side = 35, up = 26, slow = 0.5 },
		color = Color3.fromRGB(255, 140, 40), size = Vector3.new(6, 2, 6) },
	-- РАКЕТЧИК: управляемые ракеты; скорость поворота ограничена, от ракеты можно уйти резким манёвром или за препятствие
	{ name = "Ракетчик", speed = 65, agility = 3.5, tilt = 0.32, weapon = "rocket", dmg = 16, cooldown = 0.8, mag = 2,  reload = 5,   radius = 10,
		rocketSpeed = 120, turn = 1.5, fuel = 5, lockRange = 450, lockCone = 0.35, loseAngle = 1.4,
		push = { side = 14, up = 10, slow = 0.8 },
		color = Color3.fromRGB(230, 60, 60),  size = Vector3.new(4, 1.5, 4) },
}
local SWITCH_TIME = 0.5 -- время трансформации при смене дрона, с

-- зона полёта дронов (клиент мягко удерживает дрон внутри, сервер не принимает выстрелы снаружи)
local FLIGHT = { minY = BRIDGE_Y + 6, maxY = BRIDGE_Y + 160, minX = -150, maxX = BRIDGE_LEN + 150, maxZ = 350 }
for _, d in ipairs(DRONES) do d.bounds = FLIGHT end

------------------------------------------------------------------ REMOTES
local folder = Instance.new("Folder")
folder.Name = "DroneChase"
folder.Parent = RS
local function remote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end
local FireEv   = remote("Fire")
local SwitchEv = remote("Switch")
local StateEv  = remote("State")
local ReloadEv = remote("Reload")

------------------------------------------------------------------ КОНСТРУКТОР ДЕТАЛЕЙ
local V, rgb, M = Vector3.new, Color3.fromRGB, Enum.Material
local L, W, Y = BRIDGE_LEN, BRIDGE_WIDTH, BRIDGE_Y
local UP  = CFrame.Angles(0, 0, math.pi / 2) -- цилиндр осью вверх
local FWD = CFrame.Angles(0, math.pi / 2, 0) -- цилиндр осью вдоль Z
local SIDES = { -1, 1 }

local BLACK, DARK, STEEL, WHITE = rgb(18, 18, 22), rgb(34, 36, 42), rgb(150, 155, 165), rgb(240, 240, 240)
local RED, ORANGE, AMBER, CYAN  = rgb(255, 40, 40), rgb(255, 120, 30), rgb(255, 190, 60), rgb(60, 220, 255)
local BRIDGE_RED, CONCRETE      = rgb(200, 60, 40), rgb(165, 165, 160)
local PALETTE = { rgb(190, 60, 50), rgb(40, 110, 170), rgb(220, 160, 40), rgb(60, 140, 90), rgb(200, 200, 205) }

local TEX = {
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire  = "rbxasset://textures/particles/fire_main.dds",
	spark = "rbxasset://textures/particles/sparkles_main.dds",
}
local SOLID = { CanCollide = true }                                        -- деталь-препятствие
local GHOST = { CanTouch = false, CanQuery = false, CastShadow = false }   -- не ловит снаряды и лучи

local function make(class, parent, props)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	o.Parent = parent
	return o
end

local function weld(a, b)
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1 = a, b
	w.Parent = a
end

-- Декоративная деталь модели (без коллизий и массы — физика не меняется).
-- root = Part  → приваривается к нему, cf задан в его локальных координатах;
-- root = CFrame → деталь заякорена, cf задан относительно этой точки.
-- extra.Spin = тег → вместо жёсткой сварки Weld, который клиенты вращают (пропеллеры, колёса).
local function piece(parent, root, shape, size, cf, color, material, extra)
	local p = Instance.new(shape == "Wedge" and "WedgePart" or "Part")
	if shape == "Cylinder" or shape == "Ball" then p.Shape = Enum.PartType[shape] end
	p.Size = size
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.Massless = true
	for k, v in pairs(extra or {}) do
		if k ~= "Spin" and k ~= "WeldTo" then p[k] = v end
	end
	if typeof(root) == "CFrame" then
		p.Anchored = true
		p.CFrame = root * cf
	else
		p.CFrame = root.CFrame * cf
		if extra and extra.Spin then
			local w = make("Weld", p, { Part0 = root, Part1 = p, C0 = cf })
			CollectionService:AddTag(w, extra.Spin)
		else
			make("WeldConstraint", p, { Part0 = extra and extra.WeldTo or root, Part1 = p })
		end
	end
	p.Parent = parent
	return p
end

------------------------------------------------------------------ ЭФФЕКТЫ
local function fxPart(shape, size, cf, color, life)
	local p = piece(workspace, cf, shape, size, CFrame.identity, color, M.Neon, GHOST)
	Debris:AddItem(p, life)
	return p
end

-- короткий выброс частиц (Rate вместо Emit — надёжно реплицируется у только что созданных эмиттеров)
local function burst(parent, props)
	local e = make("ParticleEmitter", parent, props)
	task.delay(0.15, function() e.Enabled = false end)
end

local function smokeProps(size, rate)
	return { Texture = TEX.smoke, Rate = rate, Lifetime = NumberRange.new(1.2, 2.2), Speed = NumberRange.new(3, 7),
		Size = NumberSequence.new(size, size * 3), Transparency = NumberSequence.new(0.35, 1),
		Color = ColorSequence.new(rgb(70, 70, 70), rgb(25, 25, 25)), Acceleration = V(0, 6, 0), Drag = 2,
		SpreadAngle = Vector2.new(25, 25), Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-40, 40) }
end

local function blastFx(pos, r)
	local a = fxPart("Block", V(1, 1, 1), CFrame.new(pos), ORANGE, 3)
	a.Transparency = 1
	local light = make("PointLight", a, { Color = ORANGE, Range = math.min(60, r * 4), Brightness = 8 })
	TweenService:Create(light, TweenInfo.new(0.5), { Brightness = 0 }):Play()

	burst(a, { Texture = TEX.fire, Rate = r * 25, Lifetime = NumberRange.new(0.3, 0.6), Speed = NumberRange.new(r, r * 2.5),
		SpreadAngle = Vector2.new(180, 180), Size = NumberSequence.new(r * 0.25, r * 0.55), Transparency = NumberSequence.new(0, 1),
		Color = ColorSequence.new(rgb(255, 230, 120), rgb(200, 50, 10)), LightEmission = 0.9, Drag = 4 })
	local smoke = smokeProps(r * 0.25, r * 8)
	smoke.SpreadAngle, smoke.Speed = Vector2.new(180, 180), NumberRange.new(r * 0.4, r)
	burst(a, smoke)
	burst(a, { Texture = TEX.spark, Rate = r * 30, Lifetime = NumberRange.new(0.5, 1), Speed = NumberRange.new(r * 3, r * 5),
		SpreadAngle = Vector2.new(180, 180), Size = NumberSequence.new(0.6, 0), Acceleration = V(0, -80, 0),
		Color = ColorSequence.new(rgb(255, 220, 120)), LightEmission = 1 })

	local flash = fxPart("Ball", V(r, r, r) * 0.5, CFrame.new(pos), rgb(255, 220, 140), 0.4)
	TweenService:Create(flash, TweenInfo.new(0.35), { Size = V(r, r, r) * 1.8, Transparency = 1 }):Play()
	local ring = fxPart("Cylinder", V(0.3, r, r), CFrame.new(pos) * UP, ORANGE, 0.5)
	ring.Transparency = 0.4
	TweenService:Create(ring, TweenInfo.new(0.45), { Size = V(0.3, r * 3.5, r * 3.5), Transparency = 1 }):Play()
end

local function hitFx(pos, normal)
	local a = fxPart("Ball", V(0.9, 0.9, 0.9), CFrame.lookAt(pos, pos + normal), rgb(255, 230, 150), 1)
	Debris:AddItem(make("PointLight", a, { Color = AMBER, Range = 10, Brightness = 4 }), 0.08)
	TweenService:Create(a, TweenInfo.new(0.08), { Transparency = 1 }):Play()
	burst(a, { Texture = TEX.spark, Rate = 120, Lifetime = NumberRange.new(0.2, 0.45), Speed = NumberRange.new(15, 30),
		SpreadAngle = Vector2.new(45, 45), Size = NumberSequence.new(0.45, 0), Acceleration = V(0, -60, 0),
		Color = ColorSequence.new(rgb(255, 220, 120)), LightEmission = 1, EmissionDirection = Enum.NormalId.Front })
end

------------------------------------------------------------------ КУЗОВ СПОРТКАРА
-- Строится вокруг коллизионного блока Body 7x2x12 (перед = -Z, земля на y = -1).
-- wreck = true → упрощённый ржавый остов для препятствий (root — CFrame, детали заякорены).
local function buildCarShell(model, root, paint, wreck)
	local pm = wreck and M.CorrodedMetal or M.SmoothPlastic
	local gloss = { Reflectance = wreck and 0 or 0.25 }
	local glass = { Transparency = wreck and 0.6 or 0.35, Reflectance = 0.4 }
	local back = CFrame.Angles(0, math.pi, 0)
	local function P(shape, size, x, y, z, color, mat, extra, rot)
		local cf = CFrame.new(x, y, z)
		return piece(model, root, shape, size, rot and cf * rot or cf, color, mat, extra)
	end
	local shell = { lamps = {}, skin = {}, glass = {}, wing = {} } -- списки деталей для визуальных повреждений
	local function skin(shape, size, x, y, z, rot)
		local p = P(shape, size, x, y, z, paint, pm, gloss, rot)
		table.insert(shell.skin, p)
		return p
	end

	-- силуэт: днище, тоннель, двери, нос, капот, корма, палуба
	P("Block", V(6.4, 0.3, 11.4), 0, -0.5, 0, BLACK)
	skin("Block", V(5, 1.3, 11.4), 0, 0.3, 0)
	skin("Block", V(6.8, 1.85, 4.75), 0, 0.575, 0.075)
	skin("Block", V(6.8, 1.3, 1), 0, 0.3, -5.3)
	skin("Wedge", V(6.8, 0.55, 3.5), 0, 1.225, -4.05)
	skin("Block", V(6.8, 1.35, 1.3), 0, 0.325, 5.35)
	skin("Block", V(6.8, 0.5, 3.55), 0, 1.25, 4.225)
	-- остекление: лобовое, боковые окна, крыша, фастбэк с задним стеклом
	table.insert(shell.glass, P("Wedge", V(5.8, 1.15, 2.4), 0, 2.075, -1.1, rgb(20, 30, 45), M.Glass, glass))
	table.insert(shell.glass, P("Block", V(5.6, 0.95, 2), 0, 1.975, 1.1, rgb(20, 30, 45), M.Glass, glass))
	P("Block", V(5.8, 0.2, 2.1), 0, 2.55, 1.1, BLACK)
	skin("Wedge", V(5.8, 1.15, 3), 0, 2.075, 3.6, back)
	table.insert(shell.glass, P("Wedge", V(4.6, 0.6, 1.565), 0, 2.352, 2.98, rgb(20, 30, 45), M.Glass, glass, back))
	-- перед: сплиттер, решётка, фары, воздухозаборники
	P("Block", V(7, 0.2, 0.8), 0, -0.5, -5.75, BLACK)
	P("Block", V(3.4, 0.55, 0.15), 0, 0, -5.8, BLACK, M.DiamondPlate)
	for _, s in ipairs(SIDES) do
		table.insert(shell.lamps, P("Block", V(1.4, 0.28, 0.15), s * 2.5, 0.62, -5.8, wreck and STEEL or WHITE, wreck and M.Glass or M.Neon))
		P("Block", V(1.3, 0.4, 0.15), s * 2.55, -0.05, -5.8, BLACK)
		P("Block", V(0.25, 0.3, 4.75), s * 3.4, -0.45, 0.075, BLACK) -- порог
		P("Block", V(0.1, 0.6, 1), s * 3.41, 0.6, 1.7, BLACK)        -- боковой воздухозаборник
	end
	-- корма: фонарь-полоса, диффузор
	shell.tail = P("Block", V(6.2, 0.22, 0.15), 0, 0.7, 6, wreck and rgb(90, 20, 20) or RED, wreck and M.Glass or M.Neon)
	P("Block", V(5.2, 0.4, 0.6), 0, -0.4, 5.8, BLACK)

	if not wreck then
		for _, s in ipairs(SIDES) do
			P("Cylinder", V(0.5, 0.45, 0.45), s * 1.1, -0.05, 6, STEEL, M.Metal, nil, FWD)                -- выхлоп
			skin("Block", V(0.7, 0.28, 0.45), s * 3.6, 1.65, -1.7)                                        -- зеркало
			P("Block", V(0.08, 0.08, 4.6), s * 3.42, -0.25, 0.075, paint, M.Neon)                         -- подсветка порога
			P("Block", V(1, 0.06, 1.3), s * 1.5, 1.32, -3.6, BLACK, nil, nil, CFrame.Angles(-0.156, 0, 0)) -- жабры капота
			table.insert(shell.wing, P("Block", V(0.2, 0.75, 0.5), s * 2.2, 1.85, 5.3, BLACK))           -- стойка спойлера
			table.insert(shell.wing, skin("Block", V(0.12, 0.6, 1.4), s * 3.4, 2.2, 5.4))                 -- законцовка крыла
		end
		table.insert(shell.wing, P("Block", V(6.8, 0.14, 1.3), 0, 2.28, 5.4, BLACK)) -- антикрыло
	end

	-- колёса: шина, диск, спицы (у остова одного колеса нет)
	for i, w in ipairs({ { -3, -3.7 }, { 3, -3.7 }, { -3, 3.6 }, { 3, 3.6 } }) do
		if not (wreck and i == 2) then
			local tire = P("Cylinder", V(1.1, 2.1, 2.1), w[1], 0.05, w[2], rgb(14, 14, 14), M.Rubber, { Spin = not wreck and "CarWheel" or nil })
			local sub = { WeldTo = tire }
			P("Cylinder", V(1.16, 1.35, 1.35), w[1], 0.05, w[2], STEEL, M.Metal, sub)
			if not wreck then
				P("Block", V(1.2, 0.22, 1.3), w[1], 0.05, w[2], paint, nil, sub)
				P("Block", V(1.2, 0.22, 1.3), w[1], 0.05, w[2], paint, nil, sub, CFrame.Angles(math.pi / 2, 0, 0))
			end
		end
	end
	return shell
end

------------------------------------------------------------------ КАРТА
local map = Instance.new("Folder")
map.Name = "Map"
map.Parent = workspace

local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local parent = props.Parent or map
	props.Parent = nil
	for k, v in pairs(props) do p[k] = v end
	p.Parent = parent
	return p
end

-- чисто декоративная деталь карты: не мешает ни машине, ни снарядам, ни прицелу
local function deco(props)
	props.CanCollide, props.CanTouch, props.CanQuery = false, false, false
	if props.CastShadow == nil then props.CastShadow = false end
	return part(props)
end

-- ОСВЕЩЕНИЕ: золотой час, дымка, блум
for _, c in ipairs(Lighting:GetChildren()) do
	if c:IsA("PostEffect") or c:IsA("Atmosphere") then c:Destroy() end
end
Lighting.ClockTime = 17.4
Lighting.GeographicLatitude = 35
Lighting.Brightness = 2.4
Lighting.Ambient = rgb(70, 70, 90)
Lighting.OutdoorAmbient = rgb(125, 115, 125)
Lighting.EnvironmentDiffuseScale = 1
Lighting.EnvironmentSpecularScale = 1
Lighting.GlobalShadows = true
Lighting.ShadowSoftness = 0.3
make("Atmosphere", Lighting, { Density = 0.28, Offset = 0.2, Color = rgb(255, 205, 165), Decay = rgb(120, 90, 110), Glare = 0.4, Haze = 1.6 })
make("BloomEffect", Lighting, { Intensity = 0.6, Size = 28, Threshold = 1.1 })
make("ColorCorrectionEffect", Lighting, { Contrast = 0.12, Saturation = 0.15, TintColor = rgb(255, 244, 232) })
make("SunRaysEffect", Lighting, { Intensity = 0.08, Spread = 0.8 })

-- ВОДА И БЕРЕГА (Terrain: настоящая вода с волнами и отражениями, скалы, холмы)
local terrain = workspace.Terrain
terrain.WaterColor = rgb(20, 75, 115)
terrain.WaterReflectance = 0.85
terrain.WaterTransparency = 0.55
terrain.WaterWaveSize = 0.3
terrain.WaterWaveSpeed = 12
terrain:FillBlock(CFrame.new(L / 2, -2, 0), V(2400, 12, 2400), M.Water)
make("Clouds", terrain, { Cover = 0.55, Density = 0.6, Color = rgb(255, 225, 205) })

-- дальний пейзаж всегда загружен, даже при включённом StreamingEnabled
local scenery = Instance.new("Model")
scenery.Name = "Scenery"
scenery.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
scenery.Parent = map

part{ Name = "Water", Size = V(2048, 4, 2048), Position = V(L / 2, -12, 0), Color = rgb(20, 45, 60), Material = M.Sand, Parent = scenery }
for i = -1, 1 do
	for j = -1, 1 do
		if i ~= 0 or j ~= 0 then
			deco{ Name = "Sea", Size = V(2048, 4, 2048), Position = V(L / 2 + i * 2048, 1.9, j * 2048),
				Color = rgb(25, 80, 115), Reflectance = 0.35, Parent = scenery }
		end
	end
end

local rng = Random.new(7)
local function tree(pos, s)
	local o = CFrame.new(pos)
	piece(map, o, "Cylinder", V(6 * s, 1.2 * s, 1.2 * s), CFrame.new(0, 3 * s, 0) * UP, rgb(95, 65, 40), M.Wood)
	piece(map, o, "Ball", V(7, 7, 7) * s, CFrame.new(0, 8 * s, 0), rgb(50, 110, 55), M.LeafyGrass)
	piece(map, o, "Ball", V(5, 5, 5) * s, CFrame.new(0.8 * s, 11 * s, 0.5 * s), rgb(70, 135, 60), M.LeafyGrass)
end
for _, shore in ipairs({ { -500, 16, -320, -20 }, { L - 16, L + 500, L + 20, L + 200 } }) do
	local a, b = shore[1], shore[2]
	terrain:FillBlock(CFrame.new((a + b) / 2, 42, 0), V(b - a, 100, 640), M.Rock)
	terrain:FillBlock(CFrame.new((a + b) / 2, 94, 0), V(b - a, 4, 640), M.Grass)
	for i = 1, 8 do
		local side = i % 2 == 0 and 1 or -1
		terrain:FillBall(V(rng:NextNumber(a + 60, b - 60), 92, side * rng:NextNumber(190, 300)), rng:NextNumber(40, 75), i % 3 == 0 and M.Rock or M.Grass)
		tree(V(rng:NextNumber(shore[3], shore[4]), Y - 4, side * rng:NextNumber(45, 110)), rng:NextNumber(0.9, 1.6))
	end
end

-- под лобби, вышкой и подъездными дорогами — голый грунт, чтобы трава не прорастала сквозь покрытие
terrain:FillBlock(CFrame.new(-60, 94, 0), V(72, 4, 72), M.Ground)
terrain:FillBlock(CFrame.new(-6, 94, -36), V(44, 4, 104), M.Ground)
terrain:FillBlock(CFrame.new(L + 42, 94, 0), V(116, 4, 56), M.Ground)

-- горы на горизонте
for i = 1, 12 do
	local ang = i / 12 * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
	local dist, w, h = rng:NextNumber(2300, 2700), rng:NextNumber(700, 1300), rng:NextNumber(250, 520)
	local o = CFrame.new(L / 2 + math.cos(ang) * dist, 0, math.sin(ang) * dist) * CFrame.Angles(0, math.pi / 2 - ang + rng:NextNumber(-0.3, 0.3), 0)
	for _, r in ipairs({ 0, math.pi }) do
		piece(scenery, o, "Wedge", V(w, h, w * 0.35), CFrame.Angles(0, r, 0) * CFrame.new(0, h / 2, -w * 0.175), rgb(70, 80, 95), M.Slate, GHOST)
	end
end

-- город за финишем
for i = 1, 14 do
	local h, w = rng:NextNumber(110, 320), rng:NextNumber(36, 64)
	local pos = V(rng:NextNumber(L + 230, L + 470), Y - 4 + h / 2, (i % 2 == 0 and 1 or -1) * rng:NextNumber(50, 260))
	deco{ Name = "Skyscraper", Size = V(w, h, w), Position = pos, Color = rgb(35, 45, 65), Material = M.Glass, Reflectance = 0.35, Parent = scenery }
	deco{ Name = "Glow", Size = V(w + 0.4, 3, w + 0.4), Position = pos + V(0, h / 2 - 6, 0), Color = ({ CYAN, ORANGE, rgb(200, 90, 255) })[i % 3 + 1], Material = M.Neon, Parent = scenery }
end

-- ЛОББИ
part{ Name = "Lobby", Size = V(60, 6, 60), Position = V(-60, Y - 3, 0), Color = rgb(90, 90, 100), Material = M.Concrete }
local spawn = Instance.new("SpawnLocation")
spawn.Anchored = true
spawn.Size = V(8, 1, 8)
spawn.Position = V(-60, Y + 0.5, 0)
spawn.Neutral = true
spawn.Duration = 0
spawn.Material = M.Neon
spawn.Color = CYAN
spawn.Parent = map
for _, s in ipairs(SIDES) do
	deco{ Name = "Trim", Size = V(60, 0.3, 0.4), Position = V(-60, Y + 0.1, s * 29.8), Color = CYAN, Material = M.Neon }
	deco{ Name = "Trim", Size = V(0.4, 0.3, 60), Position = V(-60 + s * 29.8, Y + 0.1, 0), Color = CYAN, Material = M.Neon }
	deco{ Name = "SignPost", Size = V(1, 14, 1), Position = V(-89, Y + 7, s * 13), Color = DARK, Material = M.Metal }
end
local sign = deco{ Name = "Sign", Size = V(30, 6, 0.6), CFrame = CFrame.lookAt(V(-89, Y + 13, 0), V(0, Y + 13, 0)), Color = BLACK, Material = M.Metal }
local signGui = make("SurfaceGui", sign, { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(1000, 200), LightInfluence = 0 })
make("TextLabel", signGui, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "DRONE CHASE", TextScaled = true,
	Font = Enum.Font.GothamBlack, TextColor3 = CYAN })

-- МОСТ: настил, подъезды, ограждения, разметка
local ASPHALT = rgb(60, 60, 65)
part{ Name = "Bridge", Size = V(L, 2, W), Position = V(L / 2, Y - 1, 0), Color = ASPHALT, Material = M.Asphalt }
part{ Name = "Road", Size = V(30, 6, W), Position = V(-15, Y - 3, 0), Color = ASPHALT, Material = M.Asphalt }
part{ Name = "Road", Size = V(90, 6, W), Position = V(L + 45, Y - 3, 0), Color = ASPHALT, Material = M.Asphalt }
part{ Name = "Gate", Size = V(1.5, 3, W - 2), Position = V(6, Y + 1.5, 0), Color = CONCRETE, Material = M.Concrete }
deco{ Name = "GateStripe", Size = V(1.7, 0.6, W - 2), Position = V(6, Y + 2.2, 0), Color = AMBER, Material = M.Neon }

for _, s in ipairs(SIDES) do
	local z = s * W / 2
	part{ Name = "Rail", Size = V(L, 3, 1), Position = V(L / 2, Y + 1.5, z), Color = CONCRETE, Material = M.Concrete }
	deco{ Name = "Handrail", Size = V(L, 0.35, 0.5), Position = V(L / 2, Y + 3.2, z), Color = BRIDGE_RED, Material = M.Metal }
	deco{ Name = "RailGlow", Size = V(L, 0.15, 0.1), Position = V(L / 2, Y + 2.5, z - s * 0.55), Color = CYAN, Material = M.Neon }
	deco{ Name = "Curb", Size = V(L, 0.4, 1), Position = V(L / 2, Y + 0.2, z - s), Color = CONCRETE, Material = M.Concrete }
	deco{ Name = "Girder", Size = V(L, 4, 1.5), Position = V(L / 2, Y - 4, s * 14), Color = BRIDGE_RED, Material = M.Metal }
	deco{ Name = "Chord", Size = V(L, 2.4, 2.4), Position = V(L / 2, Y + 36.8, z + s * 1.8), Color = BRIDGE_RED, Material = M.Metal, CastShadow = true }
	deco{ Name = "Line", Size = V(L, 0.05, 0.4), Position = V(L / 2, Y + 0.03, s * 0.5), Color = rgb(235, 190, 40) }
	deco{ Name = "Line", Size = V(L, 0.05, 0.4), Position = V(L / 2, Y + 0.03, s * 19.5), Color = WHITE }
	for x = 10, L, 30 do
		deco{ Name = "Dash", Size = V(12, 0.05, 0.4), Position = V(x, Y + 0.03, s * 10), Color = WHITE }
	end
end

-- опоры, порталы, ферма, фонари
local TRUSS_H = 38
local function lamp(x, s)
	local o = CFrame.new(x, Y, s * W / 2)
	piece(map, o, "Cylinder", V(13, 0.5, 0.5), CFrame.new(0, 9.5, 0) * UP, DARK, M.Metal, GHOST)
	piece(map, o, "Block", V(0.4, 0.3, 5), CFrame.new(0, 16, -s * 2.3), DARK, M.Metal, GHOST)
	local head = piece(map, o, "Block", V(1.6, 0.25, 2.2), CFrame.new(0, 15.8, -s * 4.2), rgb(255, 225, 170), M.Neon, GHOST)
	make("SpotLight", head, { Face = Enum.NormalId.Bottom, Range = 46, Angle = 110, Brightness = 2.2, Color = rgb(255, 215, 160), Shadows = false })
end
for x = 0, L, 50 do
	local portal = x % 100 == 0
	for _, s in ipairs(SIDES) do
		local z = s * (W / 2 + 1.8)
		deco{ Name = "Tower", Size = portal and V(3, TRUSS_H, 2.4) or V(1.6, TRUSS_H, 1.6), Position = V(x, Y + TRUSS_H / 2, z),
			Color = BRIDGE_RED, Material = M.Metal, CastShadow = true }
		if x < L then -- раскосы фермы
			local up = (x / 50) % 2 == 0
			local a, b = V(x, Y + (up and 0 or TRUSS_H), z), V(x + 50, Y + (up and TRUSS_H or 0), z)
			deco{ Name = "Brace", Size = V(1.4, 1.4, (b - a).Magnitude), CFrame = CFrame.lookAt((a + b) / 2, b),
				Color = BRIDGE_RED, Material = M.Metal, CastShadow = true }
		end
		if not portal then lamp(x, s) end
	end
	if portal then
		part{ Name = "Pillar", Size = V(10, Y - 4, 26), Position = V(x, (Y - 4) / 2 - 2, 0), Color = rgb(120, 120, 120), Material = M.Concrete }
		deco{ Name = "PierCap", Size = V(12, 4, W + 6), Position = V(x, Y - 4, 0), Color = CONCRETE, Material = M.Concrete, CastShadow = true }
		deco{ Name = "Footing", Size = V(18, 10, 36), Position = V(x, 3, 0), Color = rgb(95, 95, 95), Material = M.Concrete }
		deco{ Name = "Portal", Size = V(3, 3, W + 6), Position = V(x, Y + TRUSS_H - 1.5, 0), Color = BRIDGE_RED, Material = M.Metal, CastShadow = true }
		deco{ Name = "PortalGlow", Size = V(0.3, 0.3, W - 2), Position = V(x, Y + TRUSS_H - 3.2, 0), Color = CYAN, Material = M.Neon }
		deco{ Name = "Beacon", Size = V(1, 1, 1), Position = V(x, Y + TRUSS_H + 0.5, 0), Color = RED, Material = M.Neon }
	end
end

-- финишная арка
part{ Name = "Finish", Size = V(4, 0.2, W), Position = V(L - 20, Y + 0.1, 0), Color = Color3.new(1, 1, 1), Material = M.Neon, CanCollide = false }
for _, s in ipairs(SIDES) do
	deco{ Name = "FinishPost", Size = V(2, 16, 1.6), Position = V(L - 20, Y + 8, s * (W / 2 + 0.6)), Color = DARK, Material = M.Metal, CastShadow = true }
end
deco{ Name = "FinishBeam", Size = V(2, 3, W + 3), Position = V(L - 20, Y + 15.5, 0), Color = DARK, Material = M.Metal, CastShadow = true }
deco{ Name = "FinishGlow", Size = V(0.4, 0.3, W), Position = V(L - 20, Y + 13.8, 0), Color = rgb(60, 255, 120), Material = M.Neon }
for i = -5, 5 do
	deco{ Name = "Checker", Size = V(2.2, 1.4, 2), Position = V(L - 20, Y + 15.5 + (i % 2 == 0 and 0.7 or -0.7), i * 4), Color = WHITE, Material = M.Neon }
end

-- вышка охотника: платформа на решётчатой мачте
part{ Name = "HunterTower", Size = V(12, 2, 12), Position = V(0, Y + 60, -70), Color = rgb(50, 50, 60), Material = M.DiamondPlate }
do
	local o = CFrame.new(0, Y - 4, -70) -- уровень земли
	for _, sx in ipairs(SIDES) do
		for _, sz in ipairs(SIDES) do
			piece(map, o, "Block", V(0.8, 63, 0.8), CFrame.new(sx * 5, 31.5, sz * 5), DARK, M.Metal, GHOST)
			piece(map, o, "Block", V(0.4, 3, 0.4), CFrame.new(sx * 5.8, 66.5, sz * 5.8), DARK, M.Metal, GHOST)
		end
		for _, y in ipairs({ 16, 40, 68 }) do -- пояса мачты и перила площадки
			local t = y == 68 and 0.3 or 0.5
			local r = y == 68 and 5.8 or 5
			piece(map, o, "Block", V(t, t, r * 2), CFrame.new(sx * r, y, 0), y == 68 and CYAN or DARK, y == 68 and M.Neon or M.Metal, GHOST)
			piece(map, o, "Block", V(r * 2, t, t), CFrame.new(0, y, sx * r), y == 68 and CYAN or DARK, y == 68 and M.Neon or M.Metal, GHOST)
		end
	end
	piece(map, o, "Cylinder", V(14, 0.3, 0.3), CFrame.new(-5, 72, -5) * UP, STEEL, M.Metal, GHOST)
	piece(map, o, "Ball", V(0.9, 0.9, 0.9), CFrame.new(-5, 79.2, -5), RED, M.Neon, GHOST)
	piece(map, o, "Block", V(0.4, 2, 4), CFrame.new(5, 66.4, 0), DARK, M.Metal, GHOST)
	piece(map, o, "Block", V(0.1, 1.4, 3.4), CFrame.new(4.76, 66.5, 0), CYAN, M.Neon, GHOST)
end

-- ПРЕПЯТСТВИЯ: пять видов, каждый занимает полосу поперёк дороги длиной len
local obstacles = Instance.new("Folder")
obstacles.Name = "Obstacles"
obstacles.Parent = map

local function jitter(range) return CFrame.Angles(0, (math.random() - 0.5) * range, 0) end

local OBSTACLES = {
	function(o) -- разбитый автомобиль
		o = o * jitter(0.7)
		local col = part{ Name = "Block", Size = V(6.8, 3, 11.6), CFrame = o * CFrame.new(0, 1.5, 0), Transparency = 1, Parent = obstacles }
		buildCarShell(obstacles, o * CFrame.new(0, 1, 0), PALETTE[math.random(#PALETTE)], true)
		make("ParticleEmitter", make("Attachment", col, { Position = V(0, 0.7, -3.8) }), smokeProps(1.2, 3))
	end,
	function(o, len) -- дорожные барьеры
		local n = math.max(1, math.floor(len / 4.4))
		for i = 1, n do
			local c = o * CFrame.new(0, 0, (i - (n + 1) / 2) * 4.4) * jitter(0.25)
			piece(obstacles, c, "Block", V(2.2, 1, 4.2), CFrame.new(0, 0.5, 0), CONCRETE, M.Concrete, SOLID)
			piece(obstacles, c, "Block", V(1.1, 2.2, 4.2), CFrame.new(0, 2.1, 0), CONCRETE, M.Concrete, SOLID)
			piece(obstacles, c, "Block", V(1.16, 0.5, 2.4), CFrame.new(0, 2.4, 0), i % 2 == 0 and WHITE or ORANGE, M.Neon)
		end
	end,
	function(o, len) -- грузовой контейнер
		o = o * jitter(0.4)
		piece(obstacles, o, "Block", V(5, 5.4, len), CFrame.new(0, 2.7, 0), PALETTE[math.random(#PALETTE)], M.Metal, SOLID)
		for _, s in ipairs(SIDES) do
			for _, y in ipairs({ 0.2, 5.3 }) do
				piece(obstacles, o, "Block", V(0.4, 0.4, len + 0.2), CFrame.new(s * 2.4, y, 0), DARK, M.Metal)
			end
			piece(obstacles, o, "Block", V(5.2, 5.5, 0.3), CFrame.new(0, 2.75, s * len / 2), DARK, M.Metal)                 -- торцевая рама
			piece(obstacles, o, "Cylinder", V(5, 0.16, 0.16), CFrame.new(s * 0.9, 2.7, len / 2 + 0.2) * UP, STEEL, M.Metal) -- запоры дверей
		end
	end,
	function(o, len) -- бетонные блоки с арматурой
		local n = math.max(1, math.floor(len / 4))
		for i = 1, n do
			local c = o * CFrame.new(0, 0, (i - (n + 1) / 2) * 4.1) * jitter(0.4)
			piece(obstacles, c, "Block", V(4, 2.6, 3.6), CFrame.new(0, 1.3, 0), CONCRETE, M.Concrete, SOLID)
			if i % 2 == 1 then
				piece(obstacles, c, "Block", V(3.4, 2, 3.2), CFrame.new(0, 3.6, 0) * jitter(0.6), rgb(140, 140, 135), M.Concrete, SOLID)
			else
				for _, s in ipairs(SIDES) do
					piece(obstacles, c, "Cylinder", V(2.2, 0.14, 0.14), CFrame.new(s * 1.2, 3.4, s * 0.8) * UP, rgb(120, 70, 45), M.CorrodedMetal)
				end
			end
		end
	end,
	function(o, len) -- строительные леса с ограждением
		part{ Name = "Block", Size = V(4, 6.4, len), CFrame = o * CFrame.new(0, 3.2, 0), Transparency = 1, Parent = obstacles }
		for _, s in ipairs(SIDES) do
			for _, sz in ipairs(SIDES) do
				piece(obstacles, o, "Cylinder", V(6.4, 0.3, 0.3), CFrame.new(s * 1.8, 3.2, sz * (len / 2 - 0.3)) * UP, STEEL, M.Metal)
			end
			piece(obstacles, o, "Block", V(4, 0.25, len), CFrame.new(0, 4.7 + s * 1.6, 0), rgb(150, 110, 70), M.WoodPlanks)
			piece(obstacles, o, "Ball", V(0.7, 0.7, 0.7), CFrame.new(-2.1, 2.3, s * (len / 2 - 0.5)), AMBER, M.Neon)
		end
		piece(obstacles, o, "Block", V(0.3, 1, len), CFrame.new(-2.1, 1.4, 0), ORANGE)
		piece(obstacles, o, "Block", V(0.34, 1.04, len / 3), CFrame.new(-2.1, 1.4, 0), WHITE)
	end,
}

local function buildObstacles()
	obstacles:ClearAllChildren()
	for x = 120, BRIDGE_LEN - 60, 45 do
		local z = math.random(-BRIDGE_WIDTH/2 + 6, BRIDGE_WIDTH/2 - 6)
		OBSTACLES[math.random(#OBSTACLES)](CFrame.new(x, BRIDGE_Y, z), math.random(6, 14))
	end
end

------------------------------------------------------------------ МАШИНА
local function buildCar()
	local model = Instance.new("Model")
	model.Name = "RunnerCar"
	local start = Vector3.new(30, BRIDGE_Y + 2, 0)
	local cf = CFrame.lookAt(start, start + Vector3.new(1, 0, 0))

	-- невидимый коллизионный блок: вся физика и управление остаются на нём
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(7, 2, 12)
	body.CFrame = cf
	body.Color = Color3.fromRGB(40, 200, 90)
	body.Transparency = 1
	body.CastShadow = false
	body.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 100)
	body.Parent = model
	model.PrimaryPart = body

	local shell = buildCarShell(model, body, body.Color, false)
	for _, l in ipairs(shell.lamps) do
		make("SpotLight", l, { Face = Enum.NormalId.Front, Range = 60, Angle = 70, Brightness = 3, Color = rgb(235, 240, 255), Shadows = false })
	end
	make("PointLight", shell.tail, { Color = RED, Range = 10, Brightness = 1.5 })

	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.Size = Vector3.new(2, 1, 2)
	seat.CFrame = cf * CFrame.new(0, 1.5, 1)
	seat.MaxSpeed = 0
	seat.Transparency = 1
	seat.Massless = true
	seat.Parent = model
	weld(body, seat)

	-- держит машину колёсами вниз
	local att = Instance.new("Attachment")
	att.Parent = body
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.AlignType = Enum.AlignType.PrimaryAxisParallel
	align.PrimaryAxis = Vector3.new(0, 1, 0)
	att.Axis = Vector3.new(0, 1, 0)
	att.SecondaryAxis = Vector3.new(1, 0, 0)
	align.Attachment0 = att
	align.MaxTorque = 1e6
	align.Responsiveness = 40
	align.Parent = body

	-- эффекты: дым/огонь/искры из-под капота, пыль из-под задних колёс, шлейфы фонарей
	local engine = make("Attachment", body, { Position = V(0, 1.3, -3.6) })
	local smoke = make("ParticleEmitter", engine, smokeProps(1.5, 0))
	smoke.Enabled = false
	local fire = make("ParticleEmitter", engine, { Texture = TEX.fire, Rate = 30, Enabled = false, Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(5, 9), Size = NumberSequence.new(2.2, 0.5), Transparency = NumberSequence.new(0, 1),
		Color = ColorSequence.new(rgb(255, 200, 80), rgb(220, 60, 20)), LightEmission = 1, SpreadAngle = Vector2.new(15, 15) })
	local sparks = make("ParticleEmitter", engine, { Texture = TEX.spark, Rate = 0, Enabled = false, Lifetime = NumberRange.new(0.3, 0.7),
		Speed = NumberRange.new(20, 40), Size = NumberSequence.new(0.5, 0), Acceleration = V(0, -60, 0),
		Color = ColorSequence.new(rgb(255, 220, 120)), LightEmission = 1, SpreadAngle = Vector2.new(180, 180) })
	local dust = {}
	for _, s in ipairs(SIDES) do
		local wheel = make("Attachment", body, { Position = V(s * 3, -0.9, 4.6) })
		table.insert(dust, make("ParticleEmitter", wheel, { Texture = TEX.smoke, Rate = 0, Lifetime = NumberRange.new(0.6, 1.2),
			Speed = NumberRange.new(2, 5), Size = NumberSequence.new(1, 4), Transparency = NumberSequence.new(0.75, 1),
			Color = ColorSequence.new(rgb(170, 160, 150)), EmissionDirection = Enum.NormalId.Back, SpreadAngle = Vector2.new(20, 20) }))
		make("Trail", body, { Attachment0 = make("Attachment", body, { Position = V(s * 2.9, 0.62, 6) }),
			Attachment1 = make("Attachment", body, { Position = V(s * 2.9, 0.78, 6) }), Lifetime = 0.25,
			Color = ColorSequence.new(RED), Transparency = NumberSequence.new(0.3, 1), LightEmission = 1 })
	end

	-- полоска HP
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(120, 18)
	bb.StudsOffset = Vector3.new(0, 6, 0)
	bb.AlwaysOnTop = true
	bb.Parent = body
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.new(0.1, 0.1, 0.1)
	bg.Parent = bb
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	-- визуальные повреждения по стадиям (каждые 20% HP): кузов темнеет и теряет блеск,
	-- гаснут фары, отлетает антикрыло, стёкла покрываются копотью
	local stage = 0
	local function lampOff(l)
		l.Material, l.Color = M.Glass, rgb(40, 40, 40)
		local beam = l:FindFirstChildOfClass("SpotLight")
		if beam then beam.Enabled = false end
	end
	local function damageLook(hp)
		local s = math.clamp(math.floor((1 - hp / CAR_HP) * 5), 0, 4)
		if s <= stage then return end
		local was = stage
		stage = s
		local scorched = body.Color:Lerp(rgb(25, 22, 20), s * 0.2)
		for _, p in ipairs(shell.skin) do
			p.Color, p.Reflectance = scorched, 0.25 * (1 - s / 4)
		end
		if s >= 2 and was < 2 then lampOff(shell.lamps[1]) end
		if s >= 3 and was < 3 then
			for _, p in ipairs(shell.wing) do -- антикрыло отрывается и падает на дорогу
				local w = p:FindFirstChildOfClass("WeldConstraint")
				if w then w:Destroy() end
				p.Massless, p.CanCollide = false, true
				p.AssemblyLinearVelocity = body.AssemblyLinearVelocity * 0.5 + V(0, 18, 0)
				Debris:AddItem(p, 4)
			end
			sparks:Emit(30)
		end
		if s >= 4 and was < 4 then
			lampOff(shell.lamps[2])
			for _, g in ipairs(shell.glass) do
				g.Color, g.Transparency, g.Reflectance = rgb(12, 12, 12), 0.12, 0.05
			end
		end
	end

	model:SetAttribute("MaxHP", CAR_HP)
	model:SetAttribute("Missiles", 0)
	model:SetAttribute("HP", CAR_HP)
	model:GetAttributeChangedSignal("HP"):Connect(function()
		local hp = math.max(0, model:GetAttribute("HP"))
		damageLook(hp)
		fill.Size = UDim2.fromScale(hp / CAR_HP, 1)
		fill.BackgroundColor3 = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(60, 220, 90), hp / CAR_HP)
		-- чем меньше HP, тем гуще дым; ниже 30% двигатель горит
		smoke.Enabled = hp < CAR_HP * 0.7
		smoke.Rate = 5 + 30 * (1 - hp / CAR_HP)
		fire.Enabled = hp < CAR_HP * 0.3
		sparks:Emit(14)
	end)

	model.Parent = workspace
	return model, body, seat, dust
end

------------------------------------------------------------------ ДРОН
local HULL = { rgb(215, 220, 228), rgb(78, 84, 66), rgb(40, 40, 46) }

-- Собирает внешний вид дрона нужного типа вокруг невидимого блока-корпуса (перед = -Z).
local function placeProps(drone, idx)
	local cfg = DRONES[idx]
	local old = drone:FindFirstChild("Visual")
	if old then old:Destroy() end
	local vis = Instance.new("Model")
	vis.Name = "Visual"
	local h, s, hull = drone.Size / 2, drone.Size.X / 3, HULL[idx]
	local function P(shape, size, x, y, z, color, mat, extra, rot)
		local cf = CFrame.new(x, y, z)
		return piece(vis, drone, shape, size, rot and cf * rot or cf, color, mat, extra)
	end

	-- рама: 4 луча, моторы, пропеллеры с диском-размытием, навигационные огни
	local R = h.X * 0.9
	for i, c in ipairs({ { 1, -1 }, { -1, -1 }, { 1, 1 }, { -1, 1 } }) do
		local tip = V(c[1] * h.X, 0, c[2] * h.Z)
		piece(vis, drone, "Block", V(0.22 * s, 0.16 * s, tip.Magnitude), CFrame.lookAt(Vector3.zero, tip) * CFrame.new(0, 0, -tip.Magnitude / 2), DARK, M.Metal)
		local pod = P("Cylinder", V(0.6 * s, 0.55 * s, 0.55 * s), tip.X, 0.1 * s, tip.Z, STEEL, M.Metal, nil, UP)
		local blade = P("Block", V(R * 2, 0.05, 0.2 * s), tip.X, 0.45 * s, tip.Z, BLACK, nil, { Name = "Prop", Spin = "DroneRotor", CastShadow = false })
		if cfg.weapon == "bomb" then -- у тяжёлого дрона четырёхлопастные винты
			P("Block", V(0.2 * s, 0.05, R * 2), tip.X, 0.45 * s, tip.Z, BLACK, nil, { Name = "Prop", WeldTo = blade, CastShadow = false })
		end
		P("Cylinder", V(0.04, R * 2, R * 2), tip.X, 0.47 * s, tip.Z, cfg.color, M.Glass, { Name = "Prop", Transparency = 0.85, CastShadow = false }, UP)
		P("Ball", V(0.22, 0.22, 0.22) * s, tip.X, -0.28 * s, tip.Z, i <= 2 and cfg.color or RED, M.Neon)
		if i > 2 then -- шлейфы за задними моторами
			make("Trail", pod, { Attachment0 = make("Attachment", pod, { Position = V(0, 0.2 * s, 0) }),
				Attachment1 = make("Attachment", pod, { Position = V(0, -0.2 * s, 0) }), Lifetime = 0.35,
				Color = ColorSequence.new(cfg.color), Transparency = NumberSequence.new(0.5, 1), LightEmission = 1 })
		end
	end
	-- шасси, камера на подвесе, антенна
	for _, sx in ipairs(SIDES) do
		P("Block", V(0.1, 0.1, 1.5) * s, sx * 0.55 * s, -0.62 * s, 0, DARK, M.Metal)
		P("Block", V(0.08, 0.4, 0.5) * s, sx * 0.5 * s, -0.4 * s, 0, DARK, M.Metal)
	end
	P("Ball", V(0.42, 0.42, 0.42) * s, 0, -0.4 * s, 0.45 * s, BLACK, M.Metal)
	P("Cylinder", V(0.14, 0.24, 0.24) * s, 0, -0.4 * s, 0.24 * s, cfg.color, M.Neon, nil, FWD)
	P("Cylinder", V(0.9, 0.05, 0.05) * s, 0.3 * s, 0.65 * s, 0.6 * s, STEEL, M.Metal, nil, UP)
	P("Ball", V(0.12, 0.12, 0.12) * s, 0.3 * s, 1.1 * s, 0.6 * s, RED, M.Neon)

	local core
	if cfg.weapon == "gun" then -- СКАУТ: узкий фюзеляж, спаренный пулемёт
		core = P("Block", V(0.9, 0.42, 1.7), 0, 0, 0.15, hull, nil, { Reflectance = 0.15 })
		P("Wedge", V(0.9, 0.42, 0.9), 0, 0, -1.15, hull, nil, { Reflectance = 0.15 })
		P("Block", V(0.6, 0.16, 0.9), 0, 0.27, -0.1, rgb(20, 30, 45), M.Glass, { Reflectance = 0.4 })
		P("Block", V(0.12, 0.06, 0.6), 0, 0.24, 0.7, cfg.color, M.Neon)
		P("Block", V(0.6, 0.16, 0.5), 0, -0.28, -0.4, DARK, M.Metal)
		for _, sx in ipairs(SIDES) do
			P("Cylinder", V(0.9, 0.1, 0.1), sx * 0.2, -0.3, -0.95, BLACK, M.Metal, nil, FWD)
			P("Block", V(0.05, 0.1, 1.5), sx * 0.46, 0.05, 0.15, cfg.color, M.Neon)
		end
	elseif cfg.weapon == "bomb" then -- БОМБЕР: бронекорпус, бомбодержатель с двумя бомбами
		core = P("Block", V(2.6, 1.1, 3.4), 0, 0, 0, hull, M.Metal)
		P("Wedge", V(2.6, 1.1, 1), 0, 0, -2.2, hull, M.Metal)
		P("Block", V(2, 0.25, 2.4), 0, 0.65, 0, DARK, M.DiamondPlate)
		P("Block", V(1.6, 0.5, 0.4), 0, 0.1, 1.8, BLACK, M.DiamondPlate)
		P("Block", V(1.6, 0.25, 2.2), 0, -0.65, -0.1, DARK, M.Metal)
		for _, sx in ipairs(SIDES) do
			P("Block", V(0.1, 0.2, 3), sx * 1.32, 0.2, 0, cfg.color, M.Neon)
			P("Cylinder", V(1.1, 0.55, 0.55), sx * 0.45, -1, -0.2, DARK, M.Metal, nil, FWD)
			P("Ball", V(0.55, 0.55, 0.55), sx * 0.45, -1, -0.75, cfg.color, M.Metal)
			P("Block", V(0.06, 0.6, 0.3), sx * 0.45, -1, 0.4, cfg.color) -- стабилизатор бомбы
		end
	else -- РАКЕТЧИК: угловатый корпус, два ракетных блока, кили
		core = P("Block", V(1.3, 0.6, 2.2), 0, 0, 0.1, hull, M.Metal)
		P("Wedge", V(1.3, 0.6, 1), 0, 0, -1.5, hull, M.Metal)
		P("Block", V(0.9, 0.12, 0.6), 0, 0.34, -0.5, rgb(20, 30, 45), M.Glass, { Reflectance = 0.4 })
		for _, sx in ipairs(SIDES) do
			P("Block", V(0.06, 0.14, 1.8), sx * 0.66, 0, 0.1, cfg.color, M.Neon)
			P("Block", V(0.5, 0.12, 0.5), sx * 0.9, -0.1, 0, DARK, M.Metal)
			P("Block", V(0.55, 0.55, 1.7), sx * 1.25, -0.25, -0.1, STEEL, M.Metal)
			P("Block", V(0.38, 0.38, 0.08), sx * 1.25, -0.25, -0.96, cfg.color, M.Neon)
			P("Block", V(0.08, 0.5, 0.6), sx * 0.4, 0.5, 0.9, cfg.color)
		end
	end
	-- прожектор вниз и цветная подсветка
	make("SpotLight", core, { Face = Enum.NormalId.Bottom, Range = 60, Angle = 55, Brightness = 2.5, Color = WHITE, Shadows = false })
	make("PointLight", core, { Color = cfg.color, Range = 10 * s, Brightness = 1.5 })
	vis.Parent = drone
end

local function buildDrone(owner)
	local d = Instance.new("Part")
	d.Name = "Drone"
	d.Size = DRONES[1].size
	d.Position = Vector3.new(0, BRIDGE_Y + 40, -30)
	d.Material = Enum.Material.Neon
	d.Color = DRONES[1].color
	d.Transparency = 1 -- физический корпус невидим, поверх него модель из placeProps
	d.CastShadow = false
	d.CanCollide = false
	d.Parent = workspace

	local att = Instance.new("Attachment")
	att.Parent = d
	local vf = Instance.new("VectorForce")
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Parent = d
	local align = Instance.new("AlignOrientation")
	align.Name = "Align"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.MaxTorque = 1e6
	align.Responsiveness = 60
	align.Parent = d

	placeProps(d, 1)
	vf.Force = Vector3.new(0, d.AssemblyMass * workspace.Gravity, 0)
	d:SetNetworkOwner(owner)
	return d, vf
end

local function applyDroneType(drone, vf, idx)
	local cfg = DRONES[idx]
	drone.Size = cfg.size
	drone.Color = cfg.color
	placeProps(drone, idx)
	vf.Force = Vector3.new(0, drone.AssemblyMass * workspace.Gravity, 0)
	-- плавная смена: новая модель проявляется из гаснущей вспышки цвета дрона
	local d = cfg.size.X * 1.3
	local flash = piece(drone.Visual, drone, "Ball", V(d, d, d), CFrame.identity, cfg.color, M.Neon, { Name = "Prop", Transparency = 0.15, CastShadow = false })
	TweenService:Create(flash, TweenInfo.new(SWITCH_TIME), { Transparency = 1, Size = V(d, d, d) * 1.5 }):Play()
	Debris:AddItem(flash, SWITCH_TIME + 0.1)
end

------------------------------------------------------------------ ОРУЖИЕ
-- Всё решает сервер: боезапас, перезарядка, темп огня, попадания и урон.
-- Клиент присылает только точку прицеливания; цель ракете выбирает сервер.
local round = nil
local rand = Random.new()
local projectiles = {} -- бомбы и ракеты в полёте

local function now() return workspace:GetServerTimeNow() end
local function sfx(name, pos) StateEv:FireAllClients("sfx", name, pos) end

local function canAct(r, plr)
	return r ~= nil and r.active and r.drone ~= nil and r.drone.Parent ~= nil and plr == r.hunter
end

local function ignoreList(r, extra)
	local list = { r.drone, extra }
	if r.hunter.Character then table.insert(list, r.hunter.Character) end
	return list
end

---------------------------------------------------------------- боезапас и перезарядка
-- Состояние видно клиенту через атрибуты дрона (только для индикаторов).
local function syncWeapon(r)
	local st, cfg, d = r.weapons[r.droneIdx], DRONES[r.droneIdx], r.drone
	d:SetAttribute("Weapon", r.droneIdx)
	d:SetAttribute("Ammo", st.ammo)
	d:SetAttribute("Mag", cfg.mag)
	d:SetAttribute("ReloadStart", st.reloadStart or 0)
	d:SetAttribute("ReloadEnd", st.reloadEnd or 0)
	d:SetAttribute("SwitchEnd", r.switchEnd)
end

local function startReload(r, from)
	local st, cfg = r.weapons[r.droneIdx], DRONES[r.droneIdx]
	if st.reloadEnd or st.ammo >= cfg.mag then return end
	st.reloadStart = math.max(now(), from or 0)
	st.reloadEnd = st.reloadStart + cfg.reload
	syncWeapon(r)
	StateEv:FireClient(r.hunter, "sfx", "reload")
end

-- завершает перезарядку, когда вышло время (вызывается каждый шаг матча и перед выстрелом)
local function updateReload(r)
	local st = r.weapons[r.droneIdx]
	if st.reloadEnd and now() >= st.reloadEnd then
		st.ammo = DRONES[r.droneIdx].mag
		st.reloadStart, st.reloadEnd = nil, nil
		syncWeapon(r)
		StateEv:FireClient(r.hunter, "sfx", "reloaded")
	end
end

---------------------------------------------------------------- урон
local function damageCar(amount, pos, crit)
	local r = round
	if not r or not r.car or not r.active or amount <= 0 then return end
	r.car:SetAttribute("HP", r.car:GetAttribute("HP") - amount)
	if r.hunter.Parent then StateEv:FireClient(r.hunter, "hit", amount, crit == true, pos) end -- маркер попадания
	if r.runner.Parent then StateEv:FireClient(r.runner, "hurt", amount) end
end

-- расстояние от точки до ближайшей точки корпуса машины (а не до её центра)
local function carDistance(body, pos)
	local lp = body.CFrame:PointToObjectSpace(pos)
	local h = body.Size / 2
	local c = Vector3.new(math.clamp(lp.X, -h.X, h.X), math.clamp(lp.Y, -h.Y, h.Y + 1.7), math.clamp(lp.Z, -h.Z, h.Z))
	return (lp - c).Magnitude
end

-- push = { side, up, slow } — ударная волна: отбрасывает и тормозит машину
local function explode(pos, radius, dmg, push)
	local e = Instance.new("Explosion")
	e.Position = pos
	e.BlastRadius = radius
	e.BlastPressure = 0
	e.DestroyJointRadiusPercent = 0
	e.Parent = workspace
	blastFx(pos, radius)
	sfx(radius >= 15 and "bigExplosion" or "explosion", pos)
	-- подпалина на асфальте
	if math.abs(pos.Y - BRIDGE_Y) < 2.5 and pos.X > 0 and pos.X < BRIDGE_LEN and math.abs(pos.Z) < BRIDGE_WIDTH / 2 then
		local mark = fxPart("Cylinder", V(0.1, radius * 0.9, radius * 0.9), CFrame.new(pos.X, BRIDGE_Y + 0.06, pos.Z) * UP, rgb(15, 15, 15), 10)
		mark.Material = M.SmoothPlastic
		mark.Transparency = 0.25
		TweenService:Create(mark, TweenInfo.new(3, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 6.5), { Transparency = 1 }):Play()
	end

	local r = round
	if dmg <= 0 or not r or not r.active or not r.body.Parent then return end
	local body = r.body
	local dist = carDistance(body, pos)
	if dist > radius then return end
	local k = 1 - dist / radius -- 1 в эпицентре, 0 на границе радиуса
	local amount = dmg * (dist < 1.5 and 1 or 0.3 + 0.7 * k)
	-- укрытие: препятствие между взрывом и машиной гасит половину урона
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = ignoreList(r, r.runner.Character)
	params.FilterType = Enum.RaycastFilterType.Exclude
	local from = pos + Vector3.new(0, 1, 0)
	local res = workspace:Raycast(from, body.Position - from, params)
	if res and not res.Instance:IsDescendantOf(r.car) then amount = amount * 0.5 end
	damageCar(amount, pos, false)
	-- машиной владеет клиент беглеца, поэтому толчок применяет он; величину задаёт сервер
	if push and r.runner.Parent then
		local away = (body.Position - pos) * Vector3.new(1, 0, 1)
		away = away.Magnitude > 0.1 and away.Unit or Vector3.zero
		local f = 0.4 + 0.6 * k
		StateEv:FireClient(r.runner, "push", away * push.side * f, push.up * f, 1 - (1 - push.slow) * f)
	end
end

---------------------------------------------------------------- эффекты выстрела
local function tracer(a, b, color)
	local len = (b - a).Magnitude
	local t = Instance.new("Part")
	t.Anchored = true
	t.CanCollide = false
	t.CanQuery = false
	t.CanTouch = false
	t.CastShadow = false
	t.Material = Enum.Material.Neon
	t.Color = color
	t.Size = Vector3.new(0.3, 0.3, len)
	t.CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2)
	t.Parent = workspace
	Debris:AddItem(t, 0.08)
	fxPart("Ball", V(1.1, 1.1, 1.1), CFrame.new(a), rgb(255, 235, 170), 0.05) -- дульная вспышка
end

local function launchFx(pos, dir)
	local a = fxPart("Ball", V(1.6, 1.6, 1.6), CFrame.lookAt(pos, pos - dir), rgb(255, 220, 150), 1.5)
	TweenService:Create(a, TweenInfo.new(0.12), { Transparency = 1 }):Play()
	local smoke = smokeProps(0.8, 150) -- выхлоп назад из пускового блока
	smoke.Speed, smoke.Lifetime = NumberRange.new(12, 22), NumberRange.new(0.5, 1)
	smoke.Acceleration, smoke.EmissionDirection = Vector3.zero, Enum.NormalId.Front
	burst(a, smoke)
end

---------------------------------------------------------------- снаряды
-- Снаряд — серверная деталь. Попадание ищется лучом вдоль пройденного за кадр пути,
-- поэтому быстрый снаряд не пролетает сквозь тонкие детали.
local function projectile(r, cfg, origin, velocity, locked)
	local rocket = cfg.weapon == "rocket"
	local p = Instance.new("Part")
	p.Name = "Projectile"
	p.Shape = rocket and Enum.PartType.Cylinder or Enum.PartType.Ball
	p.Size = rocket and V(2.4, 0.55, 0.55) or V(2.5, 2.5, 2.5)
	p.Material = Enum.Material.Metal
	p.Color = DARK
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = rocket and CFrame.lookAt(origin, origin + velocity) * FWD or CFrame.new(origin)
	p.Parent = workspace
	p:SetNetworkOwner(nil)
	p.AssemblyLinearVelocity = velocity

	local tail = make("Attachment", p, { Position = rocket and V(-1.2, 0, 0) or Vector3.zero })
	make("PointLight", p, { Color = cfg.color, Range = 14, Brightness = 2 })
	make("ParticleEmitter", tail, { Texture = TEX.smoke, Rate = rocket and 70 or 15, Lifetime = NumberRange.new(0.7, 1.3), Speed = NumberRange.new(0, 1),
		Size = NumberSequence.new(0.8, rocket and 3.2 or 2.5), Transparency = NumberSequence.new(0.35, 1),
		Color = ColorSequence.new(rgb(215, 215, 215), rgb(100, 100, 100)), Rotation = NumberRange.new(0, 360) })
	if rocket then
		make("ParticleEmitter", tail, { Texture = TEX.fire, Rate = 60, Lifetime = NumberRange.new(0.15, 0.3), Speed = NumberRange.new(0, 2),
			Size = NumberSequence.new(1.3, 0), Transparency = NumberSequence.new(0, 1), Color = ColorSequence.new(rgb(255, 230, 120), cfg.color), LightEmission = 1 })
		piece(p, p, "Ball", V(0.55, 0.55, 0.55), CFrame.new(1.2, 0, 0), cfg.color, M.Neon, GHOST)  -- боевая часть
		piece(p, p, "Block", V(0.5, 1.3, 0.08), CFrame.new(-0.95, 0, 0), cfg.color, nil, GHOST)   -- стабилизаторы
		piece(p, p, "Block", V(0.5, 0.08, 1.3), CFrame.new(-0.95, 0, 0), cfg.color, nil, GHOST)
		make("VectorForce", p, { Attachment0 = tail, RelativeTo = Enum.ActuatorRelativeTo.World, ApplyAtCenterOfMass = true,
			Force = Vector3.new(0, p.AssemblyMass * workspace.Gravity, 0) })
		make("Sound", p, { SoundId = "rbxasset://sounds/Rocket whoosh 01.wav", Volume = 0.6, Looped = true, Playing = true,
			RollOffMinDistance = 20, RollOffMaxDistance = 400 })
	else
		piece(p, p, "Cylinder", V(0.4, 2.56, 2.56), CFrame.identity, cfg.color, M.Neon, GHOST)    -- полоса на корпусе бомбы
		piece(p, p, "Block", V(0.2, 1.4, 1.4), CFrame.new(0, 1.5, 0), DARK, M.Metal, GHOST)       -- оперение
		piece(p, p, "Block", V(1.4, 1.4, 0.2), CFrame.new(0, 1.5, 0), DARK, M.Metal, GHOST)
	end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = ignoreList(r, p)
	params.FilterType = Enum.RaycastFilterType.Exclude
	table.insert(projectiles, { part = p, cfg = cfg, round = r, last = origin, born = os.clock(),
		life = rocket and cfg.fuel or 8, dir = velocity.Unit, locked = locked, params = params })
end

-- Наведение ракеты: доворачивает к машине не быстрее cfg.turn рад/с.
-- Если цель ушла из переднего сектора — захват сорван, ракета летит прямо до выгорания топлива.
local function steer(pr, pos, dt)
	local r, cfg, dir = pr.round, pr.cfg, pr.dir
	local body = r.body
	if pr.locked and r.active and body.Parent then
		local to = body.Position + body.AssemblyLinearVelocity * 0.2 - pos
		if to.Magnitude > 1 then
			local want = to.Unit
			local angle = math.acos(math.clamp(dir:Dot(want), -1, 1))
			if angle > cfg.loseAngle then
				pr.locked = false
			elseif angle > 1e-3 then
				dir = dir:Lerp(want, math.min(1, cfg.turn * dt / angle)).Unit
			end
		end
	else
		pr.locked = false
	end
	pr.dir = dir
	pr.part.AssemblyLinearVelocity = dir * cfg.rocketSpeed
	pr.part.AssemblyAngularVelocity = Vector3.zero
	pr.part.CFrame = CFrame.lookAt(pos, pos + dir) * FWD
end

RunService.Heartbeat:Connect(function(dt)
	local locks = 0
	for i = #projectiles, 1, -1 do
		local pr = projectiles[i]
		local p = pr.part
		if round ~= pr.round or not p.Parent then -- матч закончился: снаряды прошлого раунда исчезают
			table.remove(projectiles, i)
			p:Destroy()
		else
			local pos = p.Position
			local hit = nil
			local move = pos - pr.last
			if move.Magnitude > 0.05 then
				local res = workspace:Raycast(pr.last, move, pr.params)
				hit = res and res.Position
				pr.last = pos
			end
			if not hit and os.clock() - pr.born > pr.life then hit = pos end -- топливо/взрыватель по времени
			if hit then
				table.remove(projectiles, i)
				p:Destroy()
				explode(hit, pr.cfg.radius, pr.cfg.dmg, pr.cfg.push)
			elseif pr.cfg.weapon == "rocket" then
				steer(pr, pos, dt)
				if pr.locked then locks = locks + 1 end
			end
		end
	end
	-- беглец видит предупреждение, пока на него наведена хотя бы одна ракета
	local car = round and round.car
	if car and car.Parent and car:GetAttribute("Missiles") ~= locks then car:SetAttribute("Missiles", locks) end
end)

---------------------------------------------------------------- команды охотника
FireEv.OnServerEvent:Connect(function(plr, target)
	local r = round
	-- принимаем выстрел только от охотника идущего матча; запоздавшие события прошлого раунда отсекаются
	if not canAct(r, plr) then return end
	if typeof(target) ~= "Vector3" or target ~= target or target.Magnitude > 1e5 then return end -- в т.ч. NaN и бесконечность
	updateReload(r)
	local cfg, st, drone, t = DRONES[r.droneIdx], r.weapons[r.droneIdx], r.drone, now()
	if t < r.switchEnd or st.reloadEnd then return end
	if t < st.nextFire - 0.03 then return end -- темп огня; 0.03 с — допуск на сетевой джиттер
	if st.ammo <= 0 then startReload(r) return end

	-- ограничения: дрон должен быть в зоне полёта и лететь не быстрее положенного
	local dp = drone.Position
	if drone.AssemblyLinearVelocity.Magnitude > cfg.speed * 1.5 + 15
		or dp.Y < FLIGHT.minY - 30 or dp.Y > FLIGHT.maxY + 30
		or dp.X < FLIGHT.minX - 60 or dp.X > FLIGHT.maxX + 60 or math.abs(dp.Z) > FLIGHT.maxZ + 60 then
		return
	end

	local origin = dp - Vector3.new(0, drone.Size.Y, 0)
	if cfg.weapon == "rocket" then -- ракеты уходят поочерёдно из левого и правого блока
		r.podSide = -(r.podSide or 1)
		origin = (drone.CFrame * CFrame.new(r.podSide * 1.25, -0.25, -1.3)).Position
	end
	local dir = target - origin
	if dir.Magnitude < 0.1 then return end
	dir = dir.Unit

	st.nextFire = math.max(st.nextFire, t - 0.05) + cfg.cooldown
	st.ammo = st.ammo - 1
	if st.ammo <= 0 then startReload(r) else drone:SetAttribute("Ammo", st.ammo) end

	if cfg.weapon == "gun" then
		-- разброс считает сервер
		dir = (CFrame.lookAt(origin, origin + dir) * CFrame.Angles(rand:NextNumber(-cfg.spread, cfg.spread), rand:NextNumber(-cfg.spread, cfg.spread), 0)).LookVector
		local params = RaycastParams.new()
		params.FilterDescendantsInstances = ignoreList(r)
		params.FilterType = Enum.RaycastFilterType.Exclude
		local res = workspace:Raycast(origin, dir * cfg.range, params)
		tracer(origin, res and res.Position or origin + dir * cfg.range, cfg.color)
		sfx("shot", origin)
		if res then
			hitFx(res.Position, res.Normal)
			-- скрытый водитель торчит над крышей: попадание в него тоже считается попаданием в машину
			local driver = r.runner.Character
			if res.Instance:IsDescendantOf(r.car) or (driver and res.Instance:IsDescendantOf(driver)) then
				local falloff = 1 - 0.5 * math.clamp((res.Distance - 150) / (cfg.range - 150), 0, 1) -- дальше 150 студов урон падает до 50%
				local crit = r.body.CFrame:PointToObjectSpace(res.Position).Z < -2.3                  -- моторный отсек
				damageCar(cfg.dmg * falloff * (crit and cfg.crit or 1), res.Position, crit)
			end
		end
	elseif cfg.weapon == "bomb" then
		projectile(r, cfg, origin, drone.AssemblyLinearVelocity * 0.8, false)
		sfx("bombDrop", origin)
	else
		-- захват: машина в пределах дальности и в конусе вокруг линии прицеливания
		local to = r.body.Position - origin
		local locked = to.Magnitude > 1 and to.Magnitude <= cfg.lockRange
			and math.acos(math.clamp(dir:Dot(to.Unit), -1, 1)) <= cfg.lockCone
		projectile(r, cfg, origin, dir * cfg.rocketSpeed, locked)
		launchFx(origin, dir)
		sfx("rocketLaunch", origin)
		StateEv:FireClient(plr, "lock", locked)
	end
end)

ReloadEv.OnServerEvent:Connect(function(plr)
	local r = round
	if not canAct(r, plr) or now() < r.switchEnd then return end
	updateReload(r)
	startReload(r)
end)

SwitchEv.OnServerEvent:Connect(function(plr, idx)
	local r = round
	if not canAct(r, plr) then return end
	if typeof(idx) ~= "number" or not DRONES[idx] or idx == r.droneIdx then return end
	local t = now()
	if t < r.switchEnd then return end -- смена пересобирает модель и занимает SWITCH_TIME
	local old = r.weapons[r.droneIdx]
	old.reloadStart, old.reloadEnd = nil, nil -- незаконченная перезарядка прерывается
	r.droneIdx = idx
	r.switchEnd = t + SWITCH_TIME           -- на время трансформации оружие заблокировано
	applyDroneType(r.drone, r.vf, idx)
	syncWeapon(r)
	if r.weapons[idx].ammo <= 0 then startReload(r, r.switchEnd) end
	sfx("switch", r.drone.Position)
	StateEv:FireClient(plr, "cfg", DRONES[idx], idx)
end)

------------------------------------------------------------------ МИР ДЛЯ СИСТЕМЫ РАУНДОВ
-- Здесь только действия над сценой. Когда и что вызывать, решает RoundService:
-- он единственный владелец состояния игры (лобби, отсчёт, матч, результат).
local HUNTER_SPOT = CFrame.new(0, BRIDGE_Y + 64, -70)

local function msgAll(text)
	folder:SetAttribute("Message", text) -- опоздавшие и только что зашедшие клиенты читают атрибут
	StateEv:FireAllClients("msg", text)
end

local function getHum(plr)
	local ch = plr.Character
	return ch and ch:FindFirstChildOfClass("Humanoid"), ch and ch:FindFirstChild("HumanoidRootPart")
end

-- живой персонаж игрока (в мире, с HumanoidRootPart) или nil
local function aliveCharacter(plr)
	local ch = plr.Character
	local hum, hrp = getHum(plr)
	if ch and ch.Parent and hum and hrp and hum.Health > 0 then return ch, hum, hrp end
	return nil
end

local function loadCharacter(plr)
	task.spawn(pcall, plr.LoadCharacter, plr) -- LoadCharacter ждёт загрузки: не блокируем цикл раундов
end

-- водитель скрыт за тонировкой; детали, догрузившиеся позже (аксессуары), тоже прячем
local function hideCharacter(ch)
	local function hide(d)
		if d:IsA("BasePart") or d:IsA("Decal") then d.Transparency = 1 end
	end
	for _, d in ipairs(ch:GetDescendants()) do hide(d) end
	ch.DescendantAdded:Connect(hide)
end

local function seatRunner(r)
	local ch, hum = aliveCharacter(r.runner)
	if ch and r.seat.Parent and r.seat.Occupant ~= hum then
		ch:PivotTo(r.seat.CFrame * CFrame.new(0, 3, 0))
		r.seat:Sit(hum)
	end
end

local function placeHunter(r)
	local ch, _, hrp = aliveCharacter(r.hunter)
	if ch then
		ch:PivotTo(HUNTER_SPOT)
		hrp.Anchored = true
	end
end

-- убирает всё, что относится к матчу; безопасно вызывать повторно и после любого сбоя
local function cleanup(match)
	local r = round
	round = nil
	for _, pr in ipairs(projectiles) do pr.part:Destroy() end -- снаряды не переживают матч
	table.clear(projectiles)
	if r then
		if r.drone then r.drone:Destroy() end
		if r.car then r.car:Destroy() end
	end
	for _, inst in ipairs(workspace:GetChildren()) do -- остатки недостроенного матча
		if inst.Name == "RunnerCar" or inst.Name == "Drone" then inst:Destroy() end
	end
	StateEv:FireAllClients("end")
	for _, plr in ipairs({ match.hunter, match.runner }) do
		if plr.Parent then loadCharacter(plr) end
	end
end

local world = {}

world.message = msgAll
world.cleanup = cleanup

function world.publish(info)
	folder:SetAttribute("State", info.state)
	folder:SetAttribute("MatchId", info.matchId)
	folder:SetAttribute("Hunter", info.hunter)
	folder:SetAttribute("Runner", info.runner)
	folder:SetAttribute("Winner", info.winner)
	folder:SetAttribute("Queue", table.concat(info.queue, ", "))
end

function world.character(plr)
	return (aliveCharacter(plr))
end

function world.respawn(plr)
	if not Players.CharacterAutoLoads then loadCharacter(plr) end -- иначе Roblox возродит сам через RESPAWN_TIME
end

function world.prepare(plr, timeout)
	if not aliveCharacter(plr) then loadCharacter(plr) end
	local t0 = os.clock()
	while not aliveCharacter(plr) do
		if not plr.Parent or os.clock() - t0 > timeout then return false end
		task.wait(0.1)
	end
	return true
end

-- бывший playRound, часть 1: строим сцену и раздаём управление
function world.setup(match)
	local hunter, runner = match.hunter, match.runner
	buildObstacles()
	local car, body, seat, dust = buildCar()
	round = { id = match.id, hunter = hunter, runner = runner, car = car, body = body, seat = seat, dust = dust,
		droneIdx = 1, switchEnd = 0, weapons = {}, ticks = 0, active = false }
	for i, cfg in ipairs(DRONES) do -- у каждого дрона свой магазин
		round.weapons[i] = { ammo = cfg.mag, nextFire = 0 }
	end

	local ch, hum = aliveCharacter(runner)
	if not ch then return false, "Беглец пропал" end
	ch:PivotTo(seat.CFrame * CFrame.new(0, 3, 0))
	task.wait(0.2)
	seat:Sit(hum)
	task.wait(0.2)
	if not runner.Parent then return false, "Беглец вышел" end
	body:SetNetworkOwner(runner)
	StateEv:FireClient(runner, "car", car, CAR_MAX_SPEED)
	hideCharacter(ch)

	if not aliveCharacter(hunter) then return false, "Охотник пропал" end
	placeHunter(round)
	local drone, vf = buildDrone(hunter)
	round.drone, round.vf = drone, vf
	syncWeapon(round)
	task.wait(0.3) -- дать модели дрона реплицироваться клиенту до команды на управление
	if not hunter.Parent then return false, "Охотник вышел" end
	StateEv:FireClient(hunter, "drone", drone, DRONES[1], 1)
	return true
end

function world.begin(match)
	if round and round.id == match.id then round.active = true end
end

-- бывший playRound, часть 2: один шаг матча. Возвращает nil или события этого шага;
-- кто победил и что считать ничьей, решает RoundService.
function world.tick(match, left)
	local r = round
	if not r or r.id ~= match.id then error("сцена матча потеряна") end
	local body = r.body
	r.ticks = r.ticks + 1
	if r.ticks % 2 == 0 then -- таймер и прогресс 5 раз в секунду
		StateEv:FireAllClients("timer", math.max(0, math.ceil(left)), body.Position.X / (BRIDGE_LEN - 20))
	end

	local speed = body.AssemblyLinearVelocity.Magnitude -- пыль из-под колёс на скорости
	for _, e in ipairs(r.dust) do e.Rate = speed > 12 and speed * 0.35 or 0 end

	seatRunner(r) -- выпавшего из кресла водителя возвращаем за руль
	if r.drone then updateReload(r) end

	local destroyed = r.car:GetAttribute("HP") <= 0
	local fell = body.Parent == nil or body.Position.Y < BRIDGE_Y - 20
	local finished = body.Position.X >= BRIDGE_LEN - 20
	if destroyed or fell or finished then
		return { destroyed = destroyed, fell = fell, finished = finished }
	end
	return nil
end

-- персонаж участника возродился посреди матча: возвращаем его на место и заново отдаём управление
function world.restore(match, role)
	local r = round
	if not r or r.id ~= match.id then return end
	if role == "runner" then
		local ch = aliveCharacter(r.runner)
		if not ch then return end
		hideCharacter(ch)
		seatRunner(r)
		task.delay(0.5, function() -- после того как клиент обработает появление нового персонажа
			if round == r and r.runner.Parent and r.car.Parent then
				StateEv:FireClient(r.runner, "car", r.car, CAR_MAX_SPEED)
			end
		end)
	else
		placeHunter(r)
		task.delay(0.5, function()
			if round == r and r.hunter.Parent and r.drone and r.drone.Parent then
				StateEv:FireClient(r.hunter, "drone", r.drone, DRONES[r.droneIdx], r.droneIdx)
			end
		end)
	end
end

function world.finish(match, result)
	local r = round
	if not r or r.id ~= match.id then return end
	r.active = false -- после решения исхода оружие больше не действует
	if result.destroyed and r.body.Parent then explode(r.body.Position, 10, 0) end
end

------------------------------------------------------------------ ЗАПУСК
Players.RespawnTime = RESPAWN_TIME

RoundService.new({
	Players = Players,
	world = world,
	config = { ROUND_TIME = ROUND_TIME },
}):Start()
