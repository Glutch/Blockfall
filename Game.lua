-- Blockfall game logic: the well, pieces, rotation with wall kicks, gravity, lock
-- delay, 7-bag, hold, line clears, levels and score. Pure Lua, no WoW API, so it
-- runs in the headless tests as well as in the game.
local _, ns = ...
ns = ns or {}

local Game = {}
Game.__index = Game

local W, VISIBLE, HIDDEN = 10, 20, 2
local H = VISIBLE + HIDDEN          -- rows 1..HIDDEN sit above the visible well
Game.W, Game.H, Game.VISIBLE, Game.HIDDEN = W, H, VISIBLE, HIDDEN

Game.LOCK_DELAY = 0.5               -- seconds a grounded piece may still move
Game.MAX_RESETS = 15                -- moves/rotations that restart the lock timer
Game.CLEAR_TIME = 0.3               -- line-clear flash before the rows collapse
Game.LINES_PER_LEVEL = 10
Game.SECONDS_PER_LEVEL = 30         -- it also speeds up with time: one level every 30 s of play
Game.MAX_LEVEL = 20
Game.QUEUE = 6                      -- pieces kept ready (next preview shows 3)

Game.TYPES = { "I", "O", "T", "S", "Z", "J", "L" }

-- Spawn-orientation cells in an n x n box, x right and y down, 0-based.
local SHAPES = {
  I = { n = 4, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } },
  O = { n = 4, { 1, 0 }, { 2, 0 }, { 1, 1 }, { 2, 1 } },
  T = { n = 3, { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
  S = { n = 3, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } },
  Z = { n = 3, { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } },
  J = { n = 3, { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
  L = { n = 3, { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
}

-- ROT[type][r] = list of {dx, dy} for rotation r (0 spawn, 1 right, 2 flipped, 3 left).
local ROT = {}
for t, s in pairs(SHAPES) do
  ROT[t] = {}
  local cells = {}
  for i = 1, 4 do cells[i] = { s[i][1], s[i][2] } end
  for r = 0, 3 do
    ROT[t][r] = cells
    if t == "O" then
      -- the O square looks the same every way round
    else
      local nextCells = {}
      for i, c in ipairs(cells) do nextCells[i] = { s.n - 1 - c[2], c[1] } end   -- clockwise
      cells = nextCells
    end
  end
end
Game.ROT = ROT

-- Wall kicks (the usual "super rotation" offsets), written x right / y UP as they
-- are usually tabled; flipped to y down when used.
local KICKS = {
  ["0>1"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["1>0"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
  ["1>2"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
  ["2>1"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["2>3"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["3>2"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["3>0"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["0>3"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
}
local KICKS_I = {
  ["0>1"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, -1 }, { 1, 2 } },
  ["1>0"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, 1 }, { -1, -2 } },
  ["1>2"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, 2 }, { 2, -1 } },
  ["2>1"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, -2 }, { -2, 1 } },
  ["2>3"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, 1 }, { -1, -2 } },
  ["3>2"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, -1 }, { 1, 2 } },
  ["3>0"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, -2 }, { -2, 1 } },
  ["0>3"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, 2 }, { 2, -1 } },
}
local NO_KICK = { { 0, 0 } }

local LINE_SCORE = { 100, 300, 500, 800 }
Game.LINE_SCORE = LINE_SCORE

-- Versus: garbage rows sent for clearing 1/2/3/4 lines (as many as you cleared).
local ATTACK = { 1, 2, 3, 4 }
Game.ATTACK = ATTACK

-- Seeded generator (Park-Miller): exact in doubles, so every client running the
-- same seed deals the same pieces, in Lua 5.1 and 5.3 alike.
function Game.SeededRNG(seed)
  -- float maths on purpose: integer maths overflows in some Lua VMs (32-bit integers)
  local s = (math.floor(seed or 1) % 2147483647) + 0.0
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (s * 16807.0) % 2147483647.0
    return math.floor(s / 2147483647 * n) + 1
  end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
-- opts.rng(n) returns an integer in 1..n (defaults to math.random).
function Game.New(opts)
  opts = opts or {}
  local g = setmetatable({}, Game)
  g.rng = opts.rng or math.random
  g.soloRng = g.rng
  g.startLevel = opts.level or 1
  g.best = opts.best or 0
  g:Reset()
  g.phase = "ready"
  return g
end

function Game:Reset()
  self.board = {}
  for y = 1, H do self.board[y] = self:EmptyRow() end
  self.bag, self.queue = {}, {}
  self.score, self.lines, self.level = 0, 0, self.startLevel
  self.held, self.canHold = nil, true
  self.piece, self.clearing = nil, nil
  self.fall, self.lockT, self.resets, self.lowest = 0, 0, 0, 0
  self.lastClear, self.lastPoints, self.clears = 0, 0, 0
  self.garbage = {}                 -- incoming rows waiting: { {count, hole}, ... }
  self.elapsed = 0                  -- seconds of play (not paused), drives the time levels
  self.won = false
  self.newBest = false
  self.version = (self.version or 0) + 1
end

function Game:EmptyRow()
  local row = {}
  for x = 1, W do row[x] = false end
  return row
end

-- opts.rng: piece generator for this game (a seeded one in a match);
-- opts.versus: line clears attack and incoming garbage applies.
function Game:Start(opts)
  opts = opts or {}
  if opts.rng then self.rng = opts.rng elseif opts.solo then self.rng = self.soloRng end
  self.versus = opts.versus and true or false
  self:Reset()
  self.phase = "running"
  self:FillQueue()
  self:Spawn(self:TakeNext())
end

function Game:Changed() self.version = self.version + 1 end

---------------------------------------------------------------------------
-- 7-bag randomizer and the queue
---------------------------------------------------------------------------
function Game:RefillBag()
  local bag = {}
  for i, t in ipairs(Game.TYPES) do bag[i] = t end
  for i = #bag, 2, -1 do                       -- Fisher-Yates
    local j = self.rng(i)
    bag[i], bag[j] = bag[j], bag[i]
  end
  for _, t in ipairs(bag) do self.bag[#self.bag + 1] = t end
end

function Game:FillQueue()
  while #self.queue < Game.QUEUE do
    if #self.bag == 0 then self:RefillBag() end
    self.queue[#self.queue + 1] = table.remove(self.bag, 1)
  end
end

function Game:TakeNext()
  local t = table.remove(self.queue, 1)
  self:FillQueue()
  return t
end

-- The next n piece types, nearest first.
function Game:Next(n)
  local out = {}
  for i = 1, math.min(n or 3, #self.queue) do out[i] = self.queue[i] end
  return out
end

---------------------------------------------------------------------------
-- Collision
---------------------------------------------------------------------------
function Game:Cells(t, r, px, py)
  local out = {}
  for i, c in ipairs(ROT[t][r]) do out[i] = { px + c[1], py + c[2] } end
  return out
end

function Game:Fits(t, r, px, py)
  for _, c in ipairs(ROT[t][r]) do
    local x, y = px + c[1], py + c[2]
    if x < 1 or x > W or y < 1 or y > H then return false end
    if self.board[y][x] then return false end
  end
  return true
end

function Game:PieceFits(dx, dy, r)
  local p = self.piece
  return p and self:Fits(p.type, r or p.rot, p.x + dx, p.y + dy)
end

function Game:OnGround()
  return self.piece ~= nil and not self:PieceFits(0, 1)
end

---------------------------------------------------------------------------
-- Spawning, gravity, locking
---------------------------------------------------------------------------
function Game:Spawn(t)
  local n = SHAPES[t].n
  local p = { type = t, rot = 0, x = math.floor((W - n) / 2) + 1, y = 1 }
  self.piece = p
  self.fall, self.lockT, self.resets = 0, 0, 0
  if not self:Fits(t, 0, p.x, p.y) then
    self:GameOver()
    return false
  end
  if self:Fits(t, 0, p.x, p.y + 1) then p.y = p.y + 1 end   -- show it right away
  self.lowest = p.y
  self:Changed()
  return true
end

-- Seconds per row at a level: 1 s at level 1, faster each level, 20 rows a
-- second by level 13 or so.
function Game.GravityInterval(level)
  local l = math.min(level, Game.MAX_LEVEL) - 1
  return math.max((0.8 - l * 0.007) ^ l, 1 / 60)
end

function Game:Interval() return Game.GravityInterval(self.level) end

-- The level is the higher of the line level (every 10 lines) and the time
-- level (every 30 s of play), so the game keeps getting faster.
function Game:LevelFor()
  local byLines = 1 + math.floor(self.lines / Game.LINES_PER_LEVEL)
  local byTime = self.startLevel + math.floor((self.elapsed or 0) / Game.SECONDS_PER_LEVEL)
  return math.min(math.max(self.startLevel, byLines, byTime), Game.MAX_LEVEL)
end

function Game:Update(dt)
  if self.phase ~= "running" then return end
  self.elapsed = (self.elapsed or 0) + dt
  local level = self:LevelFor()
  if level ~= self.level then
    self.level = level
    self:Changed()
  end
  if self.clearing then
    self.clearing.t = self.clearing.t + dt
    if self.clearing.t >= Game.CLEAR_TIME then self:FinishClear() end
    return
  end
  local p = self.piece
  if not p then return end
  if self:PieceFits(0, 1) then
    self.lockT = 0
    self.fall = self.fall + dt
    local interval = self:Interval()
    while self.fall >= interval do
      self.fall = self.fall - interval
      if not self:StepDown() then self.fall = 0 break end
    end
  else
    self.fall = 0
    self.lockT = self.lockT + dt
    if self.lockT >= Game.LOCK_DELAY then self:Lock() end
  end
end

function Game:StepDown()
  local p = self.piece
  if not self:PieceFits(0, 1) then return false end
  p.y = p.y + 1
  if p.y > self.lowest then self.lowest, self.resets = p.y, 0 end
  self:Changed()
  return true
end

-- A successful move or rotation on the ground buys more lock time, up to MAX_RESETS.
function Game:MovedOnGround()
  if self.resets < Game.MAX_RESETS then
    self.lockT = 0
    self.resets = self.resets + 1
  end
end

function Game:Lock()
  local p = self.piece
  if not p then return end
  local allHidden = true
  for _, c in ipairs(self:Cells(p.type, p.rot, p.x, p.y)) do
    self.board[c[2]][c[1]] = p.type
    if c[2] > HIDDEN then allHidden = false end
  end
  self.piece = nil
  self.canHold = true
  self:Changed()
  if allHidden then self:GameOver() return end

  local full = {}
  for y = 1, H do
    local isFull = true
    for x = 1, W do if not self.board[y][x] then isFull = false break end end
    if isFull then full[#full + 1] = y end
  end
  self.lastClear = #full
  if #full > 0 then
    local points = LINE_SCORE[math.min(#full, 4)] * self.level
    self.score = self.score + points
    self.lastPoints, self.clears = points, self.clears + 1
    self.lines = self.lines + #full
    self.level = self:LevelFor()
    self.clearing = { rows = full, t = 0 }
    self:CheckBest()
    if self.versus then
      local attack = self:CancelGarbage(ATTACK[math.min(#full, 4)])
      if attack > 0 and self.onAttack then self.onAttack(self, attack) end
    end
  else
    if self.versus and not self:InsertGarbage() then return end
    self:Settled()
    self:Spawn(self:TakeNext())
  end
end

function Game:FinishClear()
  local rows = self.clearing.rows
  self.clearing = nil
  for i = #rows, 1, -1 do table.remove(self.board, rows[i]) end
  for _ = 1, #rows do table.insert(self.board, 1, self:EmptyRow()) end
  self:Changed()
  self:Settled()
  self:Spawn(self:TakeNext())
end

-- The board has come to rest after a lock (rows collapsed, garbage in).
function Game:Settled()
  if self.onSettle then self.onSettle(self) end
end

---------------------------------------------------------------------------
-- Garbage (versus)
---------------------------------------------------------------------------
function Game:QueueGarbage(count, hole)
  count = math.floor(tonumber(count) or 0)
  hole = math.floor(tonumber(hole) or 1)
  if count <= 0 or self.phase == "over" then return end
  if hole < 1 or hole > W then hole = 1 end
  self.garbage[#self.garbage + 1] = { count, hole }
  self:Changed()
end

function Game:PendingGarbage()
  local n = 0
  for _, e in ipairs(self.garbage) do n = n + e[1] end
  return n
end

-- An attack first cancels queued garbage (oldest first); returns what is left to send.
function Game:CancelGarbage(attack)
  while attack > 0 and #self.garbage > 0 do
    local e = self.garbage[1]
    local n = math.min(attack, e[1])
    e[1], attack = e[1] - n, attack - n
    if e[1] == 0 then table.remove(self.garbage, 1) end
  end
  self:Changed()
  return attack
end

-- Push queued garbage rows in from the bottom. False if that pushed blocks out
-- of the top (game over).
function Game:InsertGarbage()
  if #self.garbage == 0 then return true end
  local toppedOut = false
  for _, e in ipairs(self.garbage) do
    for _ = 1, e[1] do
      for x = 1, W do if self.board[1][x] then toppedOut = true end end
      table.remove(self.board, 1)
      local row = {}
      for x = 1, W do row[x] = (x ~= e[2]) and "G" or false end
      self.board[H] = row
    end
  end
  self.garbage = {}
  self:Changed()
  if toppedOut then self:GameOver() return false end
  return true
end

-- A match ended while this game was still going (everyone else is out).
function Game:EndMatch(won)
  if self.phase ~= "running" and self.phase ~= "paused" then return end
  self.phase = "over"
  self.won = won and true or false
  self.piece, self.clearing = nil, nil
  self:Changed()
end

-- Rows flashing right now (set while the clear animation runs).
function Game:ClearingRows() return self.clearing and self.clearing.rows end

function Game:CheckBest()
  if self.score > self.best then
    self.best = self.score
    self.newBest = true
  end
end

function Game:GameOver()
  self.phase = "over"
  self.clearing = nil
  self:CheckBest()
  self:Changed()
  if self.onGameOver then self.onGameOver(self) end
end

---------------------------------------------------------------------------
-- Player actions (each returns true if it did something)
---------------------------------------------------------------------------
function Game:Active() return self.phase == "running" and self.piece ~= nil and not self.clearing end

function Game:Move(dx)
  if not self:Active() or not self:PieceFits(dx, 0) then return false end
  self.piece.x = self.piece.x + dx
  if self:OnGround() then self:MovedOnGround() end
  self:Changed()
  return true
end

-- dir: 1 clockwise, -1 counter-clockwise.
function Game:Rotate(dir)
  if not self:Active() then return false end
  local p = self.piece
  local from, to = p.rot, (p.rot + dir) % 4
  local kicks = p.type == "O" and NO_KICK or (p.type == "I" and KICKS_I or KICKS)[from .. ">" .. to]
  for _, k in ipairs(kicks) do
    local nx, ny = p.x + k[1], p.y - k[2]          -- tables are y up, the well is y down
    if self:Fits(p.type, to, nx, ny) then
      p.x, p.y, p.rot = nx, ny, to
      if p.y > self.lowest then self.lowest, self.resets = p.y, 0 end
      if self:OnGround() then self:MovedOnGround() end
      self:Changed()
      return true
    end
  end
  return false
end

function Game:SoftDrop()
  if not self:Active() or not self:StepDown() then return false end
  self.score = self.score + 1
  self.fall = 0
  self:CheckBest()
  return true
end

function Game:HardDrop()
  if not self:Active() then return false end
  local n = 0
  while self:StepDown() do n = n + 1 end
  self.score = self.score + 2 * n
  self:CheckBest()
  self:Lock()
  return true
end

function Game:Hold()
  if not self:Active() or not self.canHold then return false end
  local t = self.piece.type
  local swap = self.held
  self.held = t
  self:Spawn(swap or self:TakeNext())
  self.canHold = false
  return true
end

-- Row a piece would land on (ghost), or nil with no piece.
function Game:GhostY()
  local p = self.piece
  if not p then return nil end
  local y = p.y
  while self:Fits(p.type, p.rot, p.x, y + 1) do y = y + 1 end
  return y
end

function Game:Pause(on)
  if on and self.phase == "running" then self.phase = "paused"; self:Changed(); return true end
  if not on and self.phase == "paused" then self.phase = "running"; self:Changed(); return true end
  return false
end

function Game:TogglePause() return self:Pause(self.phase == "running") end

---------------------------------------------------------------------------
-- Key repeat: delayed auto shift for left/right, steady repeat for soft drop.
-- Press/Release come from key events, Update(dt) from OnUpdate.
---------------------------------------------------------------------------
local Repeat = {}
Repeat.__index = Repeat
Repeat.DAS = 0.16      -- hold this long before sideways repeat starts
Repeat.ARR = 0.045     -- then one cell per this many seconds
Repeat.SOFT = 0.035    -- soft drop: one row per this many seconds
Game.Repeat = Repeat

function Repeat.New(game)
  return setmetatable({ game = game, dir = 0, dirT = 0, dirOrder = {}, soft = false, softT = 0 }, Repeat)
end

function Repeat:Press(action)
  local g = self.game
  if action == "left" or action == "right" then
    local d = action == "left" and -1 or 1
    self.dirOrder[action] = true
    self.dir, self.dirT = d, 0           -- the newest direction wins
    g:Move(d)
  elseif action == "soft" then
    self.soft, self.softT = true, 0
    g:SoftDrop()
  end
end

function Repeat:Release(action)
  if action == "left" or action == "right" then
    self.dirOrder[action] = nil
    local d = action == "left" and -1 or 1
    if self.dir == d then
      local other = action == "left" and "right" or "left"
      if self.dirOrder[other] then self.dir, self.dirT = -d, 0 else self.dir = 0 end
    end
  elseif action == "soft" then
    self.soft = false
  end
end

function Repeat:Clear()
  self.dir, self.dirT, self.soft = 0, 0, false
  self.dirOrder = {}
end

function Repeat:Update(dt)
  local g = self.game
  if self.dir ~= 0 then
    local before = self.dirT
    self.dirT = self.dirT + dt
    if self.dirT >= Repeat.DAS then
      local prev = math.max(0, math.floor((before - Repeat.DAS) / Repeat.ARR) + 1)
      if before < Repeat.DAS then prev = 0 end
      local now = math.floor((self.dirT - Repeat.DAS) / Repeat.ARR) + 1
      for _ = prev + 1, now do if not g:Move(self.dir) then break end end
    end
  end
  if self.soft then
    self.softT = self.softT + dt
    while self.softT >= Repeat.SOFT do
      self.softT = self.softT - Repeat.SOFT
      if not g:SoftDrop() then self.softT = 0 break end
    end
  end
end

ns.Game = Game
return Game
