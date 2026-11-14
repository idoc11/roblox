--[[ DRONE CHASE — тесты системы раундов
Прогоняют RoundService на подставном мире с виртуальным временем: два часа игры за доли секунды.

Запуск в Roblox Studio: вставить как Script в ServerScriptService (RoundService уже должен
лежать внутри GameServer), нажать Run и смотреть Output. После проверки скрипт удалить.
Запуск вне Roblox: `lua RoundServiceTests.lua` из папки проекта (Lua 5.2+ или Luau).
]]

local RoundService
if script then
	RoundService = require(game:GetService("ServerScriptService"):FindFirstChild("RoundService", true))
else
	RoundService = dofile("RoundService.lua")
end

------------------------------------------------------------------ ВИРТУАЛЬНОЕ ВРЕМЯ
local function newScheduler()
	local s = { now = 0, threads = {}, seq = 0, errors = {} }

	local function resume(co)
		local ok, t = coroutine.resume(co)
		if not ok then
			table.insert(s.errors, tostring(t))
		elseif coroutine.status(co) ~= "dead" then
			s.seq = s.seq + 1
			table.insert(s.threads, { co = co, wake = s.now + (t or 0), seq = s.seq })
		end
	end

	function s.wait(t) coroutine.yield(t or 0) end
	function s.spawn(fn) resume(coroutine.create(fn)) end
	function s.clock() return s.now end

	-- выполняет все пробуждения до момента s.now + dt
	function s.advance(dt)
		local target = s.now + dt
		while true do
			local best
			for i, th in ipairs(s.threads) do
				if th.wake <= target + 1e-9 then
					local b = best and s.threads[best]
					if not b or th.wake < b.wake or (th.wake == b.wake and th.seq < b.seq) then best = i end
				end
			end
			if not best then break end
			local th = table.remove(s.threads, best)
			if th.wake > s.now then s.now = th.wake end
			resume(th.co)
		end
		s.now = target
	end
	return s
end

------------------------------------------------------------------ ПОДСТАВНЫЕ ИГРОКИ И МИР
local function newSignal()
	local sig = { fns = {} }
	function sig:Connect(fn) table.insert(self.fns, fn) end
	function sig:Fire(...)
		for _, fn in ipairs(self.fns) do fn(...) end
	end
	return sig
end

local function newGame(names)
	local g = { sched = newScheduler(), logs = {} }
	local sched = g.sched

	local Players = { list = {}, PlayerAdded = newSignal(), PlayerRemoving = newSignal() }
	function Players:GetPlayers()
		local copy = {}
		for i, p in ipairs(self.list) do copy[i] = p end
		return copy
	end
	g.Players = Players

	local w = {
		chars = {},        -- игрок → его живой «персонаж» (любое уникальное значение) или nil
		open = {},         -- id матчей, чья сцена сейчас построена
		openCount = 0, maxOpen = 0,
		setups = 0, cleanups = {}, restores = {}, respawns = {}, messages = {}, states = {}, results = {},
		nextEvent = nil,   -- что вернёт ближайший tick
		setupMode = nil,   -- "fail" | "error" | nil
		tickError = false,
		prepareFail = {},  -- игрок → true: персонаж не загружается
		autoRespawn = true,
	}
	g.world = w

	function w.message(text) table.insert(w.messages, text) end
	function w.publish(info)
		if w.states[#w.states] ~= info.state then table.insert(w.states, info.state) end
		w.info = info
	end
	function w.prepare(plr)
		if w.prepareFail[plr] then return false end
		if not w.chars[plr] then w.chars[plr] = {} end
		return true
	end
	function w.setup(match)
		w.setups = w.setups + 1
		w.open[match.id] = true
		w.openCount = w.openCount + 1
		if w.openCount > w.maxOpen then w.maxOpen = w.openCount end
		sched.wait(0.7) -- как настоящий setup: рассадка и репликация занимают время
		if w.setupMode == "fail" then return false, "тестовый отказ" end
		if w.setupMode == "error" then error("тестовая ошибка setup") end
		return true
	end
	function w.begin(match) w.began = match.id end
	function w.tick(match, left)
		if not w.open[match.id] then error("tick без сцены") end
		if w.tickError then error("тестовая ошибка tick") end
		w.lastLeft = left
		local ev = w.nextEvent
		w.nextEvent = nil
		return ev
	end
	function w.character(plr) return w.chars[plr] end
	function w.respawn(plr) table.insert(w.respawns, plr.Name) end
	function w.restore(match, role) table.insert(w.restores, role) end
	function w.finish(match, result) table.insert(w.results, result) end
	function w.cleanup(match)
		w.cleanups[match.id] = (w.cleanups[match.id] or 0) + 1
		if w.open[match.id] then
			w.open[match.id] = nil
			w.openCount = w.openCount - 1
		end
	end

	function g.join(name)
		local plr = { Name = name, Parent = true }
		table.insert(Players.list, plr)
		w.chars[plr] = {}
		Players.PlayerAdded:Fire(plr)
		return plr
	end
	function g.leave(plr)
		for i, p in ipairs(Players.list) do
			if p == plr then table.remove(Players.list, i) break end
		end
		Players.PlayerRemoving:Fire(plr)
		plr.Parent = nil
		w.chars[plr] = nil
	end
	function g.die(plr) w.chars[plr] = nil end
	function g.respawn(plr) w.chars[plr] = {} end

	g.players = {}
	for i, name in ipairs(names) do g.players[i] = g.join(name) end
	g.service = RoundService.new({
		Players = Players, world = w, wait = sched.wait, spawn = sched.spawn, clock = sched.clock,
		log = function(text) table.insert(g.logs, text) end,
	})
	g.service:Start()

	function g.advance(dt) sched.advance(dt) end
	function g.last() return w.results[#w.results] end
	-- до состояния Playing: 0.1 (проход цикла) + 5 (отсчёт) + 0.7 (setup)
	function g.toPlaying() sched.advance(5.9) end
	return g
end

------------------------------------------------------------------ МИНИ-ФРЕЙМВОРК
local passed, failed = 0, {}
local current = "?"

local function check(cond, what)
	if cond then
		passed = passed + 1
	else
		table.insert(failed, current .. ": " .. what)
	end
end

local function eq(actual, expected, what)
	check(actual == expected, what .. " (ожидалось " .. tostring(expected) .. ", получено " .. tostring(actual) .. ")")
end

-- общие инварианты: нет параллельных матчей, каждая сцена убрана ровно один раз, цикл не падал
local function invariants(g, expectLogs)
	local w = g.world
	check(w.maxOpen <= 1, "одновременно построено сцен: " .. w.maxOpen)
	for id = 1, g.service.matchId do
		local n = w.cleanups[id] or 0
		if id < g.service.matchId or g.service.match == nil then
			eq(n, 1, "уборок сцены у матча " .. id)
		end
	end
	eq(#g.sched.errors, 0, "необработанных ошибок в потоках" .. (g.sched.errors[1] and (": " .. g.sched.errors[1]) or ""))
	if not expectLogs then
		eq(#g.logs, 0, "сообщений об ошибках в логе" .. (g.logs[1] and (": " .. g.logs[1]) or ""))
	end
end

local function test(name, fn)
	current = name
	local ok, err = pcall(fn)
	if not ok then table.insert(failed, name .. ": исключение: " .. tostring(err)) end
end

------------------------------------------------------------------ СЦЕНАРИИ
test("лобби ждёт второго игрока", function()
	local g = newGame({ "A" })
	g.advance(30)
	eq(g.service.state, "Lobby", "состояние")
	eq(g.world.setups, 0, "запущено матчей")
	g.join("B")
	g.toPlaying()
	g.advance(1.5)
	eq(g.service.state, "Playing", "состояние после входа второго")
	eq(g.service.match.hunter.Name, "A", "охотник")
	eq(g.service.match.runner.Name, "B", "беглец")
	invariants(g)
end)

test("беглец доезжает, роли меняются, следующий раунд стартует сам", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	eq(g.service.state, "Playing", "состояние")
	g.world.nextEvent = { finished = true }
	g.advance(0.2)
	eq(g.service.state, "Results", "состояние после финиша")
	eq(g.last().winner, "runner", "победитель")
	g.advance(1)
	eq(g.service.state, "Intermission", "состояние после уборки")
	eq(g.service.match, nil, "текущий матч после уборки")
	g.advance(4 + 5.9)
	eq(g.service.state, "Playing", "второй раунд")
	eq(g.service.match.hunter.Name, "B", "охотник второго раунда")
	eq(g.service.match.runner.Name, "A", "беглец второго раунда")
	eq(g.service.matchId, 2, "номер матча")
	invariants(g)
end)

test("победы охотника: уничтожение, падение, время", function()
	for _, case in ipairs({ { ev = { destroyed = true }, reason = "destroyed" }, { ev = { fell = true }, reason = "fell" } }) do
		local g = newGame({ "A", "B" })
		g.toPlaying()
		g.world.nextEvent = case.ev
		g.advance(0.2)
		eq(g.last().winner, "hunter", "победитель (" .. case.reason .. ")")
		eq(g.last().reason, case.reason, "причина")
		eq(g.last().destroyed, case.reason == "destroyed", "флаг взрыва")
		invariants(g)
	end
	local g = newGame({ "A", "B" })
	g.toPlaying()
	g.advance(119)
	eq(g.service.state, "Playing", "за секунду до конца времени")
	g.advance(1.5)
	eq(g.last() and g.last().reason, "timeout", "причина по истечении времени")
	eq(g.last() and g.last().winner, "hunter", "победитель по времени")
	invariants(g)
end)

test("ничья: уничтожена на финише", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	g.world.nextEvent = { finished = true, destroyed = true }
	g.advance(0.2)
	eq(g.last().winner, "draw", "исход")
	eq(g.last().destroyed, true, "флаг взрыва")
	g.advance(20)
	eq(g.service.state, "Playing", "следующий раунд после ничьей")
	invariants(g)
end)

test("выход охотника, беглеца и обоих во время матча", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	g.leave(g.players[1])
	g.advance(0.2)
	eq(g.last().winner, "runner", "вышел охотник")
	g.advance(10)
	eq(g.service.state, "Lobby", "один игрок — снова лобби")
	invariants(g)

	g = newGame({ "A", "B" })
	g.toPlaying()
	g.leave(g.players[2])
	g.advance(0.2)
	eq(g.last().winner, "hunter", "вышел беглец")
	invariants(g)

	g = newGame({ "A", "B", "C" })
	g.toPlaying()
	g.leave(g.players[1])
	g.leave(g.players[2])
	g.advance(0.2)
	eq(g.last().winner, "draw", "вышли оба")
	g.advance(10)
	eq(g.service.state, "Lobby", "остался один игрок")
	invariants(g)
end)

test("выход во время отсчёта не запускает матч", function()
	local g = newGame({ "A", "B" })
	g.advance(3)
	eq(g.service.state, "Countdown", "состояние")
	g.leave(g.players[2])
	g.advance(10)
	eq(g.service.state, "Lobby", "состояние после выхода")
	eq(g.world.setups, 0, "запущено матчей")
	local c = g.join("C")
	g.advance(6.5)
	eq(g.service.state, "Playing", "матч с новым игроком")
	eq(g.service.match.runner, c, "беглец — новый игрок")
	invariants(g)
end)

test("выход во время подготовки отменяет матч и убирает сцену", function()
	local g = newGame({ "A", "B" })
	g.advance(5.4)
	eq(g.service.state, "Starting", "состояние")
	g.leave(g.players[1])
	g.advance(1)
	eq(g.service.match, nil, "текущий матч")
	eq(g.world.openCount, 0, "построенных сцен")
	eq(#g.world.results, 0, "результатов")
	g.advance(10)
	eq(g.service.state, "Lobby", "состояние")
	invariants(g)
end)

test("отказ и ошибка подготовки не подвешивают игру", function()
	for _, mode in ipairs({ "fail", "error" }) do
		local g = newGame({ "A", "B" })
		g.world.setupMode = mode
		g.advance(20)
		check(g.world.setups >= 2, mode .. ": повторные попытки (" .. g.world.setups .. ")")
		eq(g.world.openCount, 0, mode .. ": построенных сцен")
		g.world.setupMode = nil
		g.advance(10)
		eq(g.service.state, "Playing", mode .. ": матч после восстановления")
		eq(g.service.match.hunter.Name, "A", mode .. ": очередь не сдвинулась")
		invariants(g, true)
	end
end)

test("персонаж не загрузился: игрок уходит в конец очереди", function()
	local g = newGame({ "A", "B", "C" })
	g.world.prepareFail[g.players[1]] = true
	g.advance(5.4)
	g.advance(2.2 + 5.9)
	eq(g.service.state, "Playing", "состояние")
	eq(g.service.match.hunter.Name, "B", "охотник")
	eq(g.service.match.runner.Name, "C", "беглец")
	invariants(g)
end)

test("ошибка в шаге матча даёт ничью и не останавливает цикл", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	g.world.tickError = true
	g.advance(0.2)
	eq(g.last().winner, "draw", "исход")
	eq(g.last().reason, "error", "причина")
	g.world.tickError = false
	g.advance(1 + 4 + 5.9)
	eq(g.service.state, "Playing", "следующий раунд")
	invariants(g, true)
end)

test("очередь из трёх и четырёх игроков идёт по кругу", function()
	local g = newGame({ "A", "B", "C" })
	local seen = {}
	for _ = 1, 6 do
		g.advance(5.9)
		if g.service.match then
			table.insert(seen, g.service.match.hunter.Name .. g.service.match.runner.Name)
			g.world.nextEvent = { finished = true }
		end
		g.advance(0.2 + 1 + 4)
	end
	eq(table.concat(seen, " "), "AB BC CA AB BC CA", "порядок пар при трёх игроках")
	invariants(g)

	g = newGame({ "A", "B", "C", "D" })
	seen = {}
	for _ = 1, 4 do
		g.advance(5.9)
		table.insert(seen, g.service.match.hunter.Name .. g.service.match.runner.Name)
		g.world.nextEvent = { destroyed = true }
		g.advance(0.2 + 1 + 4)
	end
	eq(table.concat(seen, " "), "AB BC CD DA", "порядок пар при четырёх игроках")
	invariants(g)
end)

test("ждущий игрок встаёт в очередь и не мешает идущему матчу", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	local c = g.join("C")
	g.advance(10)
	eq(g.service.state, "Playing", "состояние")
	eq(g.world.setups, 1, "запущено матчей")
	g.leave(c)
	g.advance(1)
	eq(g.service.state, "Playing", "состояние после выхода зрителя")
	invariants(g)
end)

test("повторный Start не создаёт второй цикл", function()
	local g = newGame({ "A", "B" })
	eq(g.service:Start(), false, "повторный Start")
	g.service:Start()
	g.advance(600)
	check(g.world.setups >= 4, "матчи идут (" .. g.world.setups .. ")")
	invariants(g)
end)

test("смерть персонажа: матч продолжается, игрок возвращается один раз", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	g.advance(1)
	eq(#g.world.restores, 0, "лишних восстановлений до смерти")
	g.die(g.players[2])
	g.advance(1)
	eq(g.service.state, "Playing", "матч идёт, пока беглец мёртв")
	eq(#g.world.respawns, 1, "запросов возрождения")
	g.respawn(g.players[2])
	g.advance(1)
	eq(table.concat(g.world.restores, ","), "runner", "восстановления")
	g.die(g.players[1])
	g.advance(0.5)
	g.respawn(g.players[1])
	g.advance(2)
	eq(table.concat(g.world.restores, ","), "runner,hunter", "восстановления после смерти охотника")
	eq(#g.world.respawns, 2, "запросов возрождения всего")
	eq(g.service.state, "Playing", "состояние")
	invariants(g)
end)

test("состояния идут строго по порядку", function()
	local g = newGame({ "A", "B" })
	g.toPlaying()
	g.world.nextEvent = { finished = true }
	g.advance(0.2 + 1 + 4 + 0.2)
	eq(table.concat(g.world.states, ">"), "Idle>Lobby>Countdown>Starting>Playing>Results>Intermission>Lobby>Countdown", "цепочка состояний")
	invariants(g)
end)

test("два часа случайных входов, выходов, смертей и сбоев", function()
	local seed = 12345
	local function rnd(n) -- свой генератор: одинаковый результат в любой версии Lua
		seed = (seed * 1103 + 12347) % 65521
		return seed % n + 1
	end
	local g = newGame({ "P1", "P2" })
	local w, counter, lastId, stuck = g.world, 2, 0, 0
	for _ = 1, 7200 * 2 do
		g.advance(0.5)
		local r = rnd(200)
		if r <= 4 and #g.Players.list < 6 then
			counter = counter + 1
			g.join("P" .. counter)
		elseif r <= 7 and #g.Players.list > 0 then
			g.leave(g.Players.list[rnd(#g.Players.list)])
		elseif r <= 12 and #g.Players.list > 0 then
			g.die(g.Players.list[rnd(#g.Players.list)])
		elseif r <= 30 then
			for _, p in ipairs(g.Players.list) do
				if not w.chars[p] then g.respawn(p) end
			end
		elseif r <= 40 then
			w.nextEvent = ({ { finished = true }, { destroyed = true }, { fell = true }, { finished = true, fell = true } })[rnd(4)]
		elseif r == 41 then
			w.setupMode = ({ "fail", "error" })[rnd(2)]
		elseif r == 42 then
			w.tickError = true
		elseif r <= 60 then
			w.setupMode, w.tickError = nil, false
		end
		-- игра не должна застревать: при двух и более игроках матчи обязаны появляться
		if #g.Players.list >= 2 and g.service.matchId == lastId then stuck = stuck + 0.5 else stuck = 0 end
		lastId = g.service.matchId
		check(stuck < 400, "новый матч не начинается " .. stuck .. " с")
		check(w.openCount <= 1, "параллельные сцены")
	end
	check(g.service.matchId > 30, "сыграно матчей: " .. g.service.matchId)
	invariants(g, true)
end)

------------------------------------------------------------------ ИТОГ
local out = print
out(("RoundService: проверок пройдено %d, провалено %d"):format(passed, #failed))
for _, f in ipairs(failed) do out("  ПРОВАЛ — " .. f) end
if #failed == 0 then out("  все сценарии пройдены") end
if not script and os and os.exit then os.exit(#failed == 0 and 0 or 1) end
