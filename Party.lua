-- Blockfall party play: presence (who in the group has the window open), the
-- shared match (seeded pieces, boards, garbage attacks, K.O.s, placements) and a
-- small outgoing message queue in front of C_ChatInfo.SendAddonMessage.
local ADDON, ns = ...
local Game, Proto = ns.Game, ns.Proto

local Party = {}
ns.Party = Party

local PREFIX = "Blockfall"
local SEND_GAP = 0.25          -- at most 4 messages a second
local HEARTBEAT = 5
local TIMEOUT = 15
local COUNTDOWN = 3
local MAX_PLAYERS = 8
local MAX_QUEUE = 30
local ANSWER_GAP = 1           -- answer hello queries at most once a second
local SPECTATE_GRACE = 3       -- seconds before a watched match with no players is dropped

Party.STATUS = {
  L = "in lobby", R = "ready", P = "playing", O = "out", C = "in combat", S = "solo game", W = "watching",
}

Party.version = 0              -- bumps whenever something the UI shows changes
local peers = {}               -- full name -> { name, short, class, proto, ok, status, matchId, wins, last }
local rosterClass = {}         -- full name -> class file, from the group roster
local me, myRealm, myClass
local queue = { ctl = {}, hello = nil, board = false }
local nextSend, backoff = 0, 0
local blocked = false
local blockedUntil = 0         -- a lockdown send result blocks us for a while
local RESULT_BLOCK = 10
local match                    -- current (or watched) match
local results                  -- placements of the last finished match
local wins = {}                -- full name -> wins this session
local ended = {}               -- match ids that are over here (never watched again)
local lastHello, lastAnswer, lastStatus = -999, -999, nil
local stats = { sent = 0, throttled = 0, dropped = 0 }
Party.stats = stats

local R = (Enum and Enum.SendAddonMessageResult) or {}
local RESULT_OK = R.Success or 0

local function Now() return GetTime() end
local function Changed() Party.version = Party.version + 1 end
local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

---------------------------------------------------------------------------
-- Names: always "Name-Realm" internally; Ambiguate for display.
---------------------------------------------------------------------------
local function NormRealm(r) return (r:gsub("[%s%-]", "")) end

local function FullName(name, realm)
  if name == nil or Secret(name) or name == "" then return nil end
  if realm ~= nil and not Secret(realm) and realm ~= "" then return name .. "-" .. NormRealm(realm) end
  if name:find("-", 1, true) then return name end
  return name .. "-" .. (myRealm or "")
end

local function Short(full)
  local ok, s = pcall(Ambiguate, full, "none")
  if ok and type(s) == "string" and not Secret(s) then return s end
  return (full:gsub("%-.*$", ""))
end

function Party.Me() return me end

---------------------------------------------------------------------------
-- Group
---------------------------------------------------------------------------
local function InGroup() return IsInGroup() and true or false end

local function Channel()
  if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
  return nil
end

local function ReadRoster()
  wipe(rosterClass)
  local raid = IsInRaid()
  local n = GetNumGroupMembers() or 0
  for i = 1, n do
    local unit = raid and ("raid" .. i) or (i == 1 and "player" or ("party" .. (i - 1)))
    local name, realm = UnitName(unit)
    local full = FullName(name, realm)
    if full then
      local _, class = UnitClass(unit)
      rosterClass[full] = (class ~= nil and not Secret(class)) and class or false
    end
  end
end

function Party.ClassColor(full)
  local class = full == me and myClass or rosterClass[full] or (peers[full] and peers[full].class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if c then return c.r, c.g, c.b end
  return 0.85, 0.86, 0.92
end

-- Window open, in a group and messages allowed: the party session is live.
function Party.Present()
  return me ~= nil and ns.IsShown() and InGroup() and not blocked
end

function Party.Blocked() return blocked end
function Party.InGroup() return InGroup() end

---------------------------------------------------------------------------
-- Outgoing queue: control messages first (FIFO), then one pending hello, then
-- the newest board. Paced to SEND_GAP, with backoff on throttle results.
---------------------------------------------------------------------------
local function ClearQueue()
  wipe(queue.ctl)
  queue.hello, queue.board = nil, false
end

local function SendCtl(msg, matchId)
  if not msg or not Channel() then return end
  if #queue.ctl >= MAX_QUEUE then table.remove(queue.ctl, 1); stats.dropped = stats.dropped + 1 end
  queue.ctl[#queue.ctl + 1] = { msg = msg, matchId = matchId }
end

local function Hello(query)
  if not Channel() then return end
  queue.hello = (query or queue.hello == "q") and "q" or "a"
end

local function MyStatus()
  local g = ns.game
  if match and not match.over then
    if match.mine then
      if not match.started then return "R" end
      local pl = match.players[me]
      if pl and not pl.alive then return "O" end
      if ns.InCombat() then return "C" end
      return "P"
    end
    return "W"
  end
  if ns.InCombat() then return "C" end
  if g and (g.phase == "running" or g.phase == "paused") then return "S" end
  return "L"
end
Party.MyStatus = MyStatus

local function BuildHello(kind)
  local mid = (match and not match.over and match.mine) and match.id or "-"
  return Proto.Encode("H", Proto.VERSION, kind, MyStatus(), mid, wins[me] or 0)
end

local function BuildBoard()
  local g = ns.game
  if not (match and match.mine and match.started and not match.over) then return nil end
  return Proto.Encode("D", match.id, g.score, g.lines, Proto.PackBoard(g.board, Game.HIDDEN + 1, Game.H, Game.W))
end

local function SetBlocked(on)
  if on == blocked then return end
  blocked = on
  if on then
    -- Can't talk to the group: carry on alone.
    if match and not match.over then
      if ns.game then ns.game.versus = false end
      match = nil
    end
    peers = {}
  else
    Hello(true)
  end
  Changed()
end

local function Pump()
  local t = Now()
  if t < nextSend then return end
  local kind, msg, entry
  if #queue.ctl > 0 then
    kind, entry = "ctl", queue.ctl[1]
    msg = entry.msg
    if entry.matchId and not (match and match.id == entry.matchId and not match.over) then
      table.remove(queue.ctl, 1)                 -- stale: that match is over
      return
    end
  elseif queue.hello then
    kind = "hello"
    msg = BuildHello(queue.hello)
    lastStatus = MyStatus()
  elseif queue.board then
    kind = "board"
    msg = BuildBoard()
    if not msg then queue.board = false return end
  else
    return
  end
  local channel = Channel()
  if not channel then ClearQueue() return end
  if C_ChatInfo.InChatMessagingLockdown() then
    SetBlocked(true)
    nextSend = t + 1
    return
  end
  local result = C_ChatInfo.SendAddonMessage(PREFIX, msg, channel)
  if result == nil or result == true or result == RESULT_OK then
    stats.sent = stats.sent + 1
    backoff = 0
    nextSend = t + SEND_GAP
    if kind == "ctl" then table.remove(queue.ctl, 1)
    elseif kind == "hello" then queue.hello = nil; lastHello = t
    else queue.board = false end
  elseif result == R.AddonMessageThrottle or result == R.ChannelThrottle then
    stats.throttled = stats.throttled + 1
    backoff = math.min(math.max(backoff * 2, 1), 8)
    nextSend = t + backoff                     -- keep it queued, try again later
  elseif result == R.AddOnMessageLockdown then
    blockedUntil = t + RESULT_BLOCK
    SetBlocked(true)
    nextSend = t + 1
  elseif result == R.NotInGroup then
    ClearQueue()
    nextSend = t + SEND_GAP
  else
    stats.dropped = stats.dropped + 1        -- invalid message etc.: drop it
    if kind == "ctl" then table.remove(queue.ctl, 1)
    elseif kind == "hello" then queue.hello = nil
    else queue.board = false end
    nextSend = t + SEND_GAP
  end
end

---------------------------------------------------------------------------
-- Match
---------------------------------------------------------------------------
local function AliveList()
  local out = {}
  if not match then return out end
  for _, n in ipairs(match.roster) do
    local pl = match.players[n]
    if pl and pl.alive then out[#out + 1] = n end
  end
  return out
end

local function AddPlayer(name, alive)
  if match.players[name] then return match.players[name] end
  local pl = { alive = alive ~= false, score = 0, lines = 0 }
  match.players[name] = pl
  match.roster[#match.roster + 1] = name
  return pl
end

local function FinishMatch()
  local alive = AliveList()
  local winner = alive[1]
  if winner then
    match.players[winner].place = 1
    wins[winner] = (wins[winner] or 0) + 1
  end
  match.over = true
  match.winner = winner
  ended[match.id] = true
  results = {}
  for _, n in ipairs(match.roster) do
    local pl = match.players[n]
    results[#results + 1] = { name = n, short = Short(n), place = pl.place or #match.roster, score = pl.score, me = n == me }
  end
  table.sort(results, function(a, b) return a.place < b.place end)
  local g = ns.game
  if match.mine and g then g:EndMatch(winner == me) end
  match = nil
  Hello(false)
  Changed()
end

local function MarkOut(name)
  if not match or match.over then return end
  local pl = match.players[name]
  if not pl or not pl.alive then return end
  pl.place = #AliveList()
  pl.alive = false
  Changed()
  if match.started and #AliveList() <= 1 then FinishMatch() end
end

local function NewMatch(id, seed, starter, names, delay, mine)
  match = { id = id, seed = seed, starter = starter, roster = {}, players = {}, mine = mine,
    startAt = Now() + delay, started = false, over = false, target = 0 }
  for _, n in ipairs(names) do AddPlayer(n, true) end
  results = nil
  Hello(false)
  Changed()
end

-- Lower seed wins a start race; equal seeds: the alphabetically first starter.
local function Beats(seedA, starterA, seedB, starterB)
  if seedA ~= seedB then return seedA < seedB end
  return starterA < starterB
end

local function BeginGame()
  match.started = true
  if match.mine then
    ns.game:Start({ rng = Game.SeededRNG(match.seed), versus = true })
    if ns.OnMatchStart then ns.OnMatchStart() end
    queue.board = true
  end
  Hello(false)
  Changed()
end

function Party.RequestStart()
  if not Party.Present() then return false end
  if match and not match.over then return true end         -- countdown or match already on
  for _, p in pairs(peers) do
    if p.ok and (p.status == "P" or p.status == "C" or p.status == "R" or p.status == "O") then return true end
  end
  local others = {}
  for name, p in pairs(peers) do
    if p.ok and p.status == "L" then others[#others + 1] = name end
  end
  if #others == 0 then return false end                    -- nobody to play with: solo
  table.sort(others)
  local names = { me }
  for i = 1, math.min(#others, MAX_PLAYERS - 1) do names[#names + 1] = others[i] end
  local seed = math.random(1, 2147483646)
  local id = tostring(seed)
  local head = Proto.Encode("S", id, seed, COUNTDOWN * 1000, "")
  local list, kept = Proto.NameList(names, Proto.MAX_LEN - #head)
  SendCtl(Proto.Encode("S", id, seed, COUNTDOWN * 1000, list))
  NewMatch(id, seed, me, kept, COUNTDOWN, true)
  return true
end

local function SendAttack(count)
  if not (match and match.mine and match.started and not match.over) then return end
  local targets = {}
  for _, n in ipairs(AliveList()) do if n ~= me then targets[#targets + 1] = n end end
  if #targets == 0 then return end
  match.target = match.target % #targets + 1
  local target = targets[match.target]
  local hole = math.random(1, Game.W)
  SendCtl(Proto.Encode("A", match.id, target, count, hole), match.id)
  match.lastAttack = { target = target, count = count, t = Now() }
  Changed()
end

function Party.InMatch() return match ~= nil and match.mine and match.started and not match.over end
function Party.Watching() return match ~= nil and not match.mine and not match.over end
function Party.Countdown()
  if match and match.mine and not match.started then return math.max(0, match.startAt - Now()) end
end
function Party.Match() return match end
function Party.Results() return results end
function Party.Wins(name) return wins[name or me] or 0 end

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------
local function Drop(name)
  if not peers[name] then return end
  peers[name] = nil
  if match then MarkOut(name) end
  Changed()
end

local function HandleHello(from, f)
  local p = peers[from]
  if not p then
    p = { name = from, short = Short(from) }
    peers[from] = p
  end
  p.proto = f[2]
  p.ok = Proto.Major(f[2]) == Proto.MAJOR
  p.status = Party.STATUS[f[4]] and f[4] or "L"
  p.matchId = (f[5] and f[5] ~= "-" and f[5] ~= "") and f[5] or nil
  p.wins = tonumber(f[6]) or 0
  p.last = Now()
  p.class = rosterClass[from] or nil
  if f[3] == "q" and Party.Present() and Now() - lastAnswer >= ANSWER_GAP then
    lastAnswer = Now()
    Hello(false)
  end
  if p.ok and Party.Present() then
    local playing = p.status == "P" or p.status == "C" or p.status == "O"
    if p.matchId and playing and not match and not ended[p.matchId] then
      -- Opened mid-match: watch it, join the next round.
      match = { id = p.matchId, roster = {}, players = {}, mine = false, startAt = Now() - SPECTATE_GRACE, started = true, over = false, target = 0 }
      results = nil
    end
    if match and match.started and Now() > match.startAt + 2 then
      local pl = match.players[from]
      if p.matchId == match.id then
        if not pl and not match.mine then pl = AddPlayer(from, p.status ~= "O") end
        if pl and p.status == "O" then MarkOut(from) end
      elseif pl and pl.alive then
        MarkOut(from)                          -- back in the lobby: no longer playing
      end
    end
  end
  Changed()
end

local function HandleStart(from, f)
  local id, seed, delay = f[2], tonumber(f[3]), tonumber(f[4])
  if not (id and seed and delay) then return end
  local names = Proto.SplitNames(f[5])
  local listed = false
  for _, n in ipairs(names) do if n == me then listed = true end end
  if match and not match.over and match.mine then
    if match.id == id or match.started then return end      -- already playing
    if not Beats(seed, from, match.seed, match.starter) then return end   -- our start wins the race
  end
  if not Party.Present() then return end
  delay = math.max(0, math.min(delay / 1000, 10))
  NewMatch(id, seed, from, names, delay, listed)
end

function Party.OnMessage(prefix, text, channel, sender)
  if prefix ~= PREFIX then return end
  if Secret(text) or Secret(sender) or type(text) ~= "string" or type(sender) ~= "string" then return end
  local from = FullName(sender)
  if not from or from == me then return end
  local kind, f = Proto.Decode(text)
  if not kind then return end
  if kind == "H" then HandleHello(from, f) return end
  if kind == "B" then Drop(from) return end
  local p = peers[from]
  if not p or not p.ok or blocked then return end         -- unknown or outdated client
  p.last = Now()
  if kind == "S" then
    HandleStart(from, f)
  elseif match and f[2] == match.id then
    local pl = match.players[from]
    if not pl and not match.mine and (kind == "D" or kind == "O") then pl = AddPlayer(from, true) end
    if kind == "D" and pl then
      pl.score, pl.lines = tonumber(f[3]) or pl.score, tonumber(f[4]) or pl.lines
      pl.board = Proto.UnpackBoard(f[5], Game.VISIBLE) or pl.board
      Changed()
    elseif kind == "O" and pl then
      pl.score, pl.lines = tonumber(f[3]) or pl.score, tonumber(f[4]) or pl.lines
      pl.board = Proto.UnpackBoard(f[5], Game.VISIBLE) or pl.board
      MarkOut(from)
    elseif kind == "A" and match.mine and match.started and f[3] == me then
      local mine = match.players[me]
      local count = math.max(0, math.min(tonumber(f[4]) or 0, 10))
      if mine and mine.alive and count > 0 then
        ns.game:QueueGarbage(count, tonumber(f[5]))
        match.lastHit = { from = from, count = count, t = Now() }
        Changed()
      end
    end
  end
end

---------------------------------------------------------------------------
-- Lists for the UI
---------------------------------------------------------------------------
-- Everyone present, you first: { name, short, status, ok, wins, r, g, b, me }
function Party.Players()
  local out = {}
  local r, g, b = Party.ClassColor(me)
  out[1] = { name = me, short = Short(me), status = MyStatus(), ok = true, wins = wins[me] or 0, r = r, g = g, b = b, me = true }
  local others = {}
  for name, p in pairs(peers) do others[#others + 1] = p end
  table.sort(others, function(a, b) return a.short < b.short end)
  for _, p in ipairs(others) do
    local pr, pg, pb = Party.ClassColor(p.name)
    out[#out + 1] = { name = p.name, short = p.short, status = p.status, ok = p.ok, wins = wins[p.name] or 0, r = pr, g = pg, b = pb }
  end
  return out
end

-- Opponents in the current/watched match, highest score first.
function Party.Opponents()
  local out = {}
  if not match then return out end
  for _, n in ipairs(match.roster) do
    if n ~= me then
      local pl = match.players[n]
      local r, g, b = Party.ClassColor(n)
      out[#out + 1] = { name = n, short = Short(n), score = pl.score, lines = pl.lines, board = pl.board,
        alive = pl.alive, place = pl.place, status = peers[n] and peers[n].status, r = r, g = g, b = b }
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  return out
end

-- Anyone else here (with a matching version)?
function Party.HasPeers()
  for _, p in pairs(peers) do if p.ok then return true end end
  return false
end

---------------------------------------------------------------------------
-- Hooks from Core / UI
---------------------------------------------------------------------------
function Party.Init()
  local name, realm = UnitName("player")
  myRealm = GetNormalizedRealmName() or ""
  if Secret(myRealm) then myRealm = "" end
  me = FullName(name, realm) or ("player-" .. myRealm)
  local _, class = UnitClass("player")
  myClass = (class ~= nil and not Secret(class)) and class or nil
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  ReadRoster()

  local g = ns.game
  g.onAttack = function(_, n) SendAttack(n) end
  g.onSettle = function() if Party.InMatch() then queue.board = true end end
  g.onGameOver = function(game)
    if Party.InMatch() and match.players[me] and match.players[me].alive then
      -- not tied to the match: it must still go out if this K.O. ends the match here
      SendCtl(Proto.Encode("O", match.id, game.score, game.lines,
        Proto.PackBoard(game.board, Game.HIDDEN + 1, Game.H, Game.W)))
      MarkOut(me)
    end
  end
end

function Party.OnOpen()
  if not me then return end
  ReadRoster()
  if InGroup() then
    SetBlocked(C_ChatInfo.InChatMessagingLockdown() and true or false)
    Hello(true)
  end
  Changed()
end

function Party.OnClose()
  if not me then return end
  if match and not match.over then
    if match.mine and match.started and ns.game then
      ns.game:EndMatch(false)
    end
    ended[match.id] = true
    match = nil
  end
  if InGroup() and not blocked then
    wipe(queue.ctl)
    queue.hello, queue.board = nil, false
    SendCtl(Proto.Encode("B"))
  end
  Changed()
end

function Party.OnRoster()
  if not me then return end
  if not InGroup() then
    if match and not match.over and ns.game then ns.game.versus = false end
    match = nil
    peers = {}
    wipe(rosterClass)
    ClearQueue()
    blocked = false
    Changed()
    return
  end
  ReadRoster()
  for name in pairs(peers) do
    if rosterClass[name] == nil then Drop(name) end
  end
  if ns.IsShown() then Hello(true) end
  Changed()
end

function Party.Tick()
  local t = Now()
  if InGroup() then
    local locked = (C_ChatInfo.InChatMessagingLockdown() or t < blockedUntil) and true or false
    if locked ~= blocked then SetBlocked(locked) end
  end
  if Party.Present() then
    if t - lastHello >= HEARTBEAT then Hello(false) end
    if MyStatus() ~= lastStatus and not queue.hello then Hello(false) end
  end
  for name, p in pairs(peers) do
    if t - (p.last or 0) > TIMEOUT then Drop(name) end
  end
  if match and not match.over then
    if not match.started and t >= match.startAt then
      if match.mine then BeginGame() else match.started = true; Changed() end
    end
    if match and not match.mine and match.started and t > match.startAt + SPECTATE_GRACE then
      local any = false
      for _, p in pairs(peers) do if p.matchId == match.id then any = true end end
      if not any then ended[match.id] = true; match = nil; Changed() end
    end
  end
  Pump()
end

-- Test hook: drop all state (for a fresh client in the same VM).
function Party._State()
  return { peers = peers, queue = queue, match = match, blocked = blocked, wins = wins, results = results }
end
