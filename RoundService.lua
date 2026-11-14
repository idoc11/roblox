--[[ DRONE CHASE — RoundService (система раундов)
Положить как ModuleScript с именем RoundService ВНУТРЬ скрипта GameServer.

Единственный владелец игрового состояния. Один цикл проходит состояния по порядку:
  Lobby → Countdown → Starting → Playing → Results → Intermission → Lobby ...
Матч создаётся только в этом цикле, поэтому два матча одновременно невозможны.

Модуль не трогает модели и оружие: всё, что касается мира, он делает через таблицу world
(её реализует GameServer). Благодаря этому логику раундов можно прогнать тестами
без Roblox — см. RoundServiceTests.lua.

Интерфейс world (все функции вызываются только из цикла раундов):
  message(text)             — показать сообщение всем
  publish(info)             — опубликовать состояние (state, matchId, hunter, runner, queue, winner)
  prepare(plr, timeout)     — дождаться живого персонажа; true/false          (может ждать)
  setup(match)              — построить машину, дрон, рассадить; true | false, причина (может ждать)
  begin(match)              — матч начался: разрешить оружие
  tick(match, left)         — шаг матча; nil или { destroyed, fell, finished }
  character(plr)            — живой персонаж игрока или nil
  respawn(plr)              — попросить возродить персонажа
  restore(match, role)      — вернуть возродившегося игрока в машину / к дрону
  finish(match, result)     — матч решён: запретить оружие, финальные эффекты
  cleanup(match)            — убрать всё, что создал setup (безопасно вызывать при любом исходе)
]]

local RoundService = {}
RoundService.__index = RoundService

local DEFAULTS = {
	MIN_PLAYERS     = 2,   -- сколько игроков нужно для матча
	COUNTDOWN       = 5,   -- обратный отсчёт, с
	ROUND_TIME      = 120, -- длительность матча, с
	RESULT_HOLD     = 1,   -- показ результата до уборки сцены, с
	INTERMISSION    = 4,   -- пауза между раундами, с
	TICK            = 0.1, -- шаг проверки условий, с
	LOBBY_POLL      = 1,   -- как часто лобби проверяет число игроков, с
	PREPARE_TIMEOUT = 8,   -- сколько ждать персонажа игрока, с
	ERROR_PAUSE     = 2,   -- пауза после отменённого раунда, с
}

function RoundService.new(deps)
	local self = setmetatable({}, RoundService)
	self.players = deps.Players
	self.world = deps.world
	self.wait = deps.wait or task.wait
	self.spawn = deps.spawn or task.spawn
	self.clock = deps.clock or os.clock
	self.log = deps.log or warn
	self.cfg = {}
	for k, v in pairs(DEFAULTS) do self.cfg[k] = v end
	for k, v in pairs(deps.config or {}) do self.cfg[k] = v end

	self.state = "Idle"
	self.queue = {}    -- игроки по порядку: [1] — следующий охотник, [2] — следующий беглец
	self.present = {}  -- множество игроков, которые сейчас на сервере
	self.match = nil   -- текущий матч (не nil только от Starting до уборки сцены)
	self.matchId = 0
	self.started = false
	self.stopped = false
	return self
end

------------------------------------------------------------------ ИГРОКИ И ОЧЕРЕДЬ
function RoundService:_indexOf(plr)
	for i, p in ipairs(self.queue) do
		if p == plr then return i end
	end
	return nil
end

function RoundService:AddPlayer(plr)
	if self.present[plr] then return end
	self.present[plr] = true
	table.insert(self.queue, plr)
	self:_publish()
end

function RoundService:RemovePlayer(plr)
	if not self.present[plr] then return end
	self.present[plr] = nil
	local i = self:_indexOf(plr)
	if i then table.remove(self.queue, i) end
	self:_publish()
end

function RoundService:_here(plr)
	return self.present[plr] == true and plr.Parent ~= nil
end

function RoundService:_toBack(plr)
	local i = self:_indexOf(plr)
	if i then
		table.remove(self.queue, i)
		table.insert(self.queue, plr)
	end
end

-- После сыгранного матча охотник уходит в конец очереди, беглец остаётся первым.
-- Двое игроков так просто меняются ролями, а при трёх и более все играют по кругу:
-- сначала беглецом, в следующем раунде охотником, затем ждут своей очереди.
function RoundService:_rotate(match)
	self:_toBack(match.hunter)
	self:_publish()
end

------------------------------------------------------------------ БЕЗОПАСНЫЕ ВЫЗОВЫ МИРА
-- Ошибка в мире не должна останавливать цикл раундов: логируем и идём дальше.
function RoundService:_call(name, ...)
	local fn = self.world[name]
	if not fn then return false, nil end
	local ok, res = pcall(fn, ...)
	if not ok then self.log("[RoundService] world." .. name .. ": " .. tostring(res)) end
	return ok, res
end

function RoundService:_message(text)
	self:_call("message", text)
end

function RoundService:_publish()
	local m = self.match
	local names = {}
	for i, p in ipairs(self.queue) do names[i] = p.Name end
	self:_call("publish", {
		state = self.state,
		matchId = self.matchId,
		hunter = m and m.hunterName or "",
		runner = m and m.runnerName or "",
		winner = m and m.result and m.result.winner or "",
		queue = names,
	})
end

function RoundService:_set(state)
	self.state = state
	self:_publish()
end

function RoundService:_endMatch(match)
	if match.cleaned then return end
	match.cleaned = true
	self:_call("cleanup", match)
	if self.match == match then self.match = nil end
end

------------------------------------------------------------------ ПОДГОТОВКА МАТЧА
function RoundService:_setup(match)
	for _, plr in ipairs({ match.hunter, match.runner }) do
		local ok, ready = pcall(self.world.prepare, plr, self.cfg.PREPARE_TIMEOUT)
		if not self:_here(plr) then return false, plr.Name .. " вышел" end
		if not ok or not ready then
			if not ok then self.log("[RoundService] world.prepare: " .. tostring(ready)) end
			self:_toBack(plr) -- чтобы игрок без персонажа не блокировал остальных
			return false, "персонаж " .. plr.Name .. " не загрузился"
		end
	end

	local ok, res, why = pcall(self.world.setup, match)
	if not ok then
		self.log("[RoundService] world.setup: " .. tostring(res))
		return false, "ошибка подготовки"
	end
	if not res then return false, why or "ошибка подготовки" end
	if not self:_here(match.hunter) then return false, match.hunterName .. " вышел" end
	if not self:_here(match.runner) then return false, match.runnerName .. " вышел" end

	local _, hc = self:_call("character", match.hunter)
	local _, rc = self:_call("character", match.runner)
	match.chars.hunter, match.chars.runner = hc, rc
	return true
end

------------------------------------------------------------------ МАТЧ
local function result(winner, reason, text, destroyed)
	return { winner = winner, reason = reason, text = text, destroyed = destroyed == true }
end

-- Смерть персонажа не завершает матч: ждём возрождения и возвращаем игрока на место.
function RoundService:_recover(match)
	for _, role in ipairs({ "hunter", "runner" }) do
		local plr = match[role]
		local ok, char = pcall(self.world.character, plr)
		if ok and char then
			match.respawnAsked[role] = nil
			if char ~= match.chars[role] then
				match.chars[role] = char
				self:_call("restore", match, role)
			end
		elseif ok and not match.respawnAsked[role] then
			match.respawnAsked[role] = true
			match.chars[role] = nil
			self:_call("respawn", plr)
		end
	end
end

function RoundService:_play(match)
	local hunter, runner = match.hunterName, match.runnerName
	local t0 = self.clock()
	while true do
		self.wait(self.cfg.TICK)

		-- выход игроков
		local hGone, rGone = not self:_here(match.hunter), not self:_here(match.runner)
		if hGone and rGone then return result("draw", "both_left", "🤝 Ничья: оба игрока вышли") end
		if hGone then return result("runner", "hunter_left", runner .. " победил (охотник вышел)") end
		if rGone then return result("hunter", "runner_left", hunter .. " победил (беглец вышел)") end

		self:_recover(match)

		local left = self.cfg.ROUND_TIME - (self.clock() - t0)
		local ev = self.world.tick(match, left) -- ошибка здесь ловится в _cycle и даёт ничью
		if ev then
			local hunterWins = ev.destroyed or ev.fell
			if ev.finished and hunterWins then
				return result("draw", "simultaneous", "🤝 Ничья! Машина погибла прямо на финише", ev.destroyed)
			elseif ev.destroyed then
				return result("hunter", "destroyed", "💥 Машина уничтожена! Победил охотник " .. hunter, true)
			elseif ev.fell then
				return result("hunter", "fell", "🌊 Машина упала с моста! Победил охотник " .. hunter)
			elseif ev.finished then
				return result("runner", "finished", "🏁 " .. runner .. " доехал до конца моста и победил!")
			end
		end
		if left <= 0 then
			return result("hunter", "timeout", "⏱ Время вышло! Победил охотник " .. hunter)
		end
	end
end

------------------------------------------------------------------ ЦИКЛ СОСТОЯНИЙ
function RoundService:_cycle()
	local cfg = self.cfg
	self.wait(cfg.TICK) -- каждый проход цикла гарантированно уступает управление

	-- ЛОББИ: ждём нужное число игроков
	self:_set("Lobby")
	while #self.queue < cfg.MIN_PLAYERS do
		if cfg.MIN_PLAYERS == 2 and #self.queue == 1 then
			self:_message("Ждём второго игрока...")
		else
			self:_message("Ждём игроков: " .. #self.queue .. "/" .. cfg.MIN_PLAYERS)
		end
		self.wait(cfg.LOBBY_POLL)
		if self.stopped then return end
	end

	-- ОТСЧЁТ: роли назначаются по очереди; если пара изменилась — начинаем заново
	self:_set("Countdown")
	local hunter, runner = self.queue[1], self.queue[2]
	for i = cfg.COUNTDOWN, 1, -1 do
		if self.queue[1] ~= hunter or self.queue[2] ~= runner then return end
		self:_message("Раунд начнётся через " .. i .. "   |   🚁 " .. hunter.Name .. "   🚗 " .. runner.Name)
		self.wait(1)
	end
	if self.queue[1] ~= hunter or self.queue[2] ~= runner then return end

	-- ЗАПУСК
	self.matchId = self.matchId + 1
	local match = {
		id = self.matchId,
		hunter = hunter, runner = runner,
		hunterName = hunter.Name, runnerName = runner.Name,
		chars = {}, respawnAsked = {},
	}
	self.match = match
	self:_set("Starting")
	local ready, why = self:_setup(match)
	if not ready then
		self:_message("Раунд отменён: " .. tostring(why))
		self:_endMatch(match)
		self:_set("Intermission")
		self.wait(cfg.ERROR_PAUSE)
		return
	end

	-- МАТЧ
	self:_set("Playing")
	self:_call("begin", match)
	local text = "🚁 " .. match.hunterName .. " — ОХОТНИК   |   🚗 " .. match.runnerName .. " — БЕГЛЕЦ"
	if #self.queue > 2 then text = text .. "   |   в очереди: " .. (#self.queue - 2) end
	self:_message(text)

	local ok, res = pcall(self._play, self, match)
	if not ok then
		self.log("[RoundService] матч " .. match.id .. ": " .. tostring(res))
		res = result("draw", "error", "⚠ Раунд прерван из-за ошибки — ничья")
	end
	match.result = res

	-- РЕЗУЛЬТАТ
	self:_set("Results")
	self:_call("finish", match, res)
	self:_message(res.text)
	self.wait(cfg.RESULT_HOLD)
	self:_endMatch(match)
	self:_rotate(match)

	-- ПАУЗА перед следующим раундом
	self:_set("Intermission")
	self.wait(cfg.INTERMISSION)
end

function RoundService:_loop()
	while not self.stopped do
		local ok, err = xpcall(function() self:_cycle() end, function(e)
			return debug.traceback(tostring(e))
		end)
		if not ok then
			-- сюда попадает только непредвиденная ошибка: убираем сцену и продолжаем
			self.log("[RoundService] сбой цикла: " .. tostring(err))
			if self.match then self:_endMatch(self.match) end
			self.match = nil
			self.state = "Intermission"
			self.wait(self.cfg.ERROR_PAUSE)
		end
	end
end

-- Запускает цикл раундов. Повторный вызов ничего не делает (защита от дублей).
function RoundService:Start()
	if self.started then return false end
	self.started = true
	self.players.PlayerAdded:Connect(function(plr) self:AddPlayer(plr) end)
	self.players.PlayerRemoving:Connect(function(plr) self:RemovePlayer(plr) end)
	for _, plr in ipairs(self.players:GetPlayers()) do self:AddPlayer(plr) end
	self.spawn(function() self:_loop() end)
	return true
end

function RoundService:Stop()
	self.stopped = true
end

return RoundService
