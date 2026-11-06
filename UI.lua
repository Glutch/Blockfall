-- Blockfall window: the well, side panel (hold, next, stats), overlays, keyboard
-- capture and the per-frame loop. All art is Blizzard's: WHITE8x8 tinted, the
-- tooltip border, the standard close and panel buttons and Blizzard fonts.
local ADDON, ns = ...
local Game = ns.Game

local WHITE = "Interface\\Buttons\\WHITE8x8"
local CELL = 16
local MINI = 12
local PAD = 10
local TITLE_H = 26
local SIDE_W = 70
local COLS, ROWS, HIDDEN = Game.W, Game.VISIBLE, Game.HIDDEN
local WELL_W, WELL_H = COLS * CELL, ROWS * CELL
local BOX_W, BOX_H = WELL_W + 3, WELL_H + 3   -- 1px edge + 1px gap around the cells

-- Blockfall's own palette: deep ink background with soft dusk colours.
local C = {
  bg     = { 0.055, 0.058, 0.082, 0.97 },
  border = { 0.30, 0.33, 0.45, 1 },
  well   = { 0.030, 0.034, 0.050, 1 },
  empty  = { 0.075, 0.082, 0.115, 1 },
  box    = { 0.040, 0.044, 0.064, 1 },
  line   = { 0.17, 0.19, 0.26, 1 },
  accent = { 1.00, 0.74, 0.38 },
  label  = { 0.52, 0.57, 0.70 },
  value  = { 0.94, 0.95, 0.98 },
  dim    = { 0.42, 0.45, 0.55 },
  piece = {
    I = { 0.99, 0.74, 0.36 },   -- amber
    O = { 0.56, 0.66, 0.98 },   -- periwinkle
    T = { 0.45, 0.85, 0.64 },   -- mint
    S = { 0.98, 0.50, 0.46 },   -- coral
    Z = { 0.32, 0.76, 0.84 },   -- lagoon
    J = { 0.88, 0.52, 0.82 },   -- orchid
    L = { 0.78, 0.86, 0.42 },   -- pear
    G = { 0.40, 0.42, 0.50 },   -- garbage rows from opponents
  },
  garbage = { 0.95, 0.32, 0.30 },
}
ns.COLORS = C

local frame, well, overlay, game, rep
local cells = {}            -- cells[row][col] = { fill, shine } for the visible rows
local holdTex, nextTex = {}, {}
local stat = {}
local popText, popT = nil, 0
local seenVersion, seenClears, seenParty = -1, 0, -1
local garbageBar, partyShown = nil, false
local capturing, inCombat, combatPaused = false, false, false
local held = {}             -- key name -> action, for keys we swallowed
local keyDownTrusted = false

local KEYMAP = {
  LEFT = "left", RIGHT = "right", DOWN = "soft", UP = "cw",
  X = "cw", Z = "ccw", SPACE = "hard",
  C = "hold", LSHIFT = "hold", RSHIFT = "hold", P = "pause",
}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function Font(parent, object, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFontObject(_G[object] or GameFontHighlight)
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

local function Tex(parent, layer, sub, color)
  local t = parent:CreateTexture(nil, layer, nil, sub)
  t:SetTexture(WHITE)
  if color then t:SetVertexColor(color[1], color[2], color[3], color[4] or 1) end
  return t
end

-- Flat panel with a 1px edge, all from WHITE8x8.
local function Box(parent, w, h, fill, edge)
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:SetSize(w, h)
  f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  f:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
  f:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4] or 1)
  return f
end

local function Mix(a, b, t)
  return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

local WHITE_RGB = { 1, 1, 1 }

local function Comma(n)
  local s = tostring(math.floor(n))
  local out
  repeat
    s, out = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until out == 0
  return s
end

local function Print(msg) print("|cffffbd61Blockfall|r: " .. msg) end
ns.Print = Print

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
-- A block is a tinted square with a light top edge and a dark bottom edge, so it
-- reads as a raised tile rather than a flat swatch.
local function PaintCell(c, mode, rgb, amount)
  if mode == "empty" then
    c.fill:SetVertexColor(C.empty[1], C.empty[2], C.empty[3], 1)
    c.shine:Hide(); c.shade:Hide()
  elseif mode == "ghost" then
    c.fill:SetVertexColor(Mix(C.empty, rgb, 0.30))
    c.shine:Hide(); c.shade:Hide()
  elseif mode == "flash" then
    local r, g, b = Mix(rgb, WHITE_RGB, 0.85 - 0.5 * amount)
    c.fill:SetVertexColor(r, g, b, 1 - 0.7 * amount)
    c.shine:Hide(); c.shade:Hide()
  else
    c.fill:SetVertexColor(rgb[1], rgb[2], rgb[3], 1)
    c.shine:Show(); c.shade:Show()
  end
end

-- Four textures showing a piece in its spawn orientation, centred in a slot.
local function DrawMini(texs, slot, t, alpha)
  if not t then
    for _, tx in ipairs(texs) do tx:Hide() end
    return
  end
  local shape = Game.ROT[t][0]
  local minX, maxX, minY, maxY = 9, -9, 9, -9
  for _, p in ipairs(shape) do
    minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
    minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
  end
  local w, h = (maxX - minX + 1) * MINI, (maxY - minY + 1) * MINI
  local rgb = C.piece[t]
  for i, p in ipairs(shape) do
    local tx = texs[i]
    tx:ClearAllPoints()
    tx:SetPoint("TOPLEFT", slot, "CENTER", -w / 2 + (p[1] - minX) * MINI, h / 2 - (p[2] - minY) * MINI)
    tx:SetVertexColor(rgb[1], rgb[2], rgb[3], alpha or 1)
    tx:Show()
  end
end

local OVERLAY_TEXT = {
  ready = { "Blockfall", "Space or click to play" },
  paused = { "Paused", "P, Space or click to resume" },
  over = { "Game over", "Space or click to play again" },
}
local CONTROLS = "|cff8790b3Left/Right move   Down soft drop\nUp, X, Z rotate   Space hard drop\nC or Shift hold   P pause|r"
local BLOCKED = "|cffe0605aParty messages are blocked here|r"

local function ResultLines(results)
  local lines = {}
  for i, r in ipairs(results) do
    if i > 6 then lines[#lines + 1] = "..." break end
    local cr, cg, cb = ns.Party.ClassColor(r.name)
    lines[#lines + 1] = string.format("%d. %s%s|r  |cff8f98b8%s|r", r.place, ns.PartyUI.Hex(cr, cg, cb), r.short, Comma(r.score or 0))
  end
  return table.concat(lines, "\n")
end

-- Title, text, button label (nil = no button) and countdown for the overlay,
-- or nil when the well should be clear.
local function OverlayState()
  local P = ns.Party
  local phase = game.phase
  local cd = P.Countdown()
  if cd then
    local m = P.Match()
    return "Get ready", "Match with " .. #m.roster .. " players\nEveryone gets the same pieces", nil, math.ceil(cd)
  end
  if P.InMatch() then
    if phase == "running" then return nil end
    if phase == "paused" then
      if inCombat then return "Paused (combat)", "The others play on.\nYou can carry on after combat." end
      return "Paused (combat)", "Space or click to carry on", "Resume"
    end
    local mine = P.Match().players[P.Me()]
    return "K.O.", (mine and mine.place and ("Place " .. mine.place .. "\n") or "") .. "Watching the others"
  end
  if P.Watching() then return "Match in progress", "You're watching.\nYou join the next round." end
  if phase == "running" then return nil end

  local title, sub = OVERLAY_TEXT[phase][1], OVERLAY_TEXT[phase][2]
  local button = phase == "paused" and "Resume" or (phase == "over" and "Play again" or "Play")
  local party = P.Present() and P.HasPeers()
  local results = P.Results()
  if party and phase ~= "paused" then
    local n = 0
    for _, p in ipairs(P.Players()) do if p.ok then n = n + 1 end end
    title = results and (game.won and "You win!" or "Results") or "Party lobby"
    sub = (results and (ResultLines(results) .. "\n\n") or "") ..
      n .. " players here\nSpace or click to start a match"
    button = "Start"
    if not results then sub = sub .. "\n\n" .. CONTROLS end
  else
    if phase == "paused" and combatPaused then title = "Paused (combat)" end
    if phase == "over" then
      sub = "Score " .. Comma(game.score) .. (game.newBest and "\n|cffffbd61New best!|r" or "") .. "\n\n" .. sub
    elseif phase == "ready" then
      sub = sub .. "\n\n" .. CONTROLS
    end
  end
  if inCombat then
    sub = (phase == "paused" and "Resumes after combat" or "Play after combat")
  end
  if P.Blocked() then sub = sub .. "\n\n" .. BLOCKED end
  return title, sub, button
end

local function RenderOverlay()
  local title, sub, button, count = OverlayState()
  if not title then overlay:Hide() return end
  overlay.title:SetText(title)
  overlay.sub:SetText(sub or "")
  overlay.count:SetText(count and tostring(count) or "")
  overlay.button:SetShown(button ~= nil)
  if button then
    overlay.button:SetText(button)
    overlay.button:SetEnabled(not inCombat)
  end
  overlay:Show()
end

local function RenderGarbage()
  local n = game:PendingGarbage()
  if n <= 0 then garbageBar:Hide() return end
  garbageBar:SetHeight(math.min(n, ROWS) * CELL)
  garbageBar:Show()
end

local function RenderParty()
  local show = ns.PartyUI.Render()
  if show ~= partyShown then
    partyShown = show
    frame:SetWidth(PAD + BOX_W + PAD + SIDE_W + PAD + (show and (ns.PartyUI.WIDTH + PAD) or 0))
  end
end

local function Render()
  -- What sits in each cell: board, then ghost, then the falling piece.
  local board = game.board
  local clearing = game:ClearingRows()
  local flashing = {}
  if clearing then for _, y in ipairs(clearing) do flashing[y] = true end end
  local amount = game.clearing and math.min(1, game.clearing.t / Game.CLEAR_TIME) or 0

  local over = {}
  local p = game.piece
  if p and game.phase ~= "over" then
    local gy = game:GhostY()
    for _, c in ipairs(game:Cells(p.type, p.rot, p.x, gy)) do over[c[2] * 100 + c[1]] = "ghost" end
    for _, c in ipairs(game:Cells(p.type, p.rot, p.x, p.y)) do over[c[2] * 100 + c[1]] = "piece" end
  end

  for row = 1, ROWS do
    local y = row + HIDDEN
    local line = board[y]
    for x = 1, COLS do
      local c = cells[row][x]
      local o = over[y * 100 + x]
      if o == "piece" then
        PaintCell(c, "block", C.piece[p.type])
      elseif line[x] then
        PaintCell(c, flashing[y] and "flash" or "block", C.piece[line[x]], amount)
      elseif o == "ghost" then
        PaintCell(c, "ghost", C.piece[p.type])
      else
        PaintCell(c, "empty")
      end
    end
  end

  DrawMini(holdTex, holdTex.slot, game.held, game.canHold and 1 or 0.35)
  local nxt = game:Next(3)
  for i = 1, 3 do DrawMini(nextTex[i], nextTex[i].slot, nxt[i], i == 1 and 1 or 0.75) end

  stat.score:SetText(Comma(game.score))
  stat.lines:SetText(tostring(game.lines))
  stat.level:SetText(tostring(game.level))
  stat.best:SetText(Comma(math.max(game.best, BlockfallDB.best or 0)))
  RenderGarbage()
  RenderParty()
  RenderOverlay()
end

local function Refresh() seenVersion = -1 end
ns.Refresh = Refresh

---------------------------------------------------------------------------
-- Game flow
---------------------------------------------------------------------------
local function PrimaryAction()
  if inCombat then return end
  local P = ns.Party
  if P.Countdown() or P.Watching() then return end
  if P.InMatch() then
    if game.phase == "paused" then
      combatPaused = false
      game:Pause(false)
    end
    Refresh()
    return
  end
  if game.phase == "ready" or game.phase == "over" then
    combatPaused = false
    rep:Clear()
    -- In a party lobby this starts a match for everyone; otherwise a solo game.
    if not P.RequestStart() then game:Start({ solo = true }) end
  elseif game.phase == "paused" then
    combatPaused = false
    game:Pause(false)
  end
  Refresh()
end

local function ReleaseAll()
  wipe(held)
  rep:Clear()
end

-- Keyboard capture only while shown and out of combat; propagation can't be
-- changed in combat, so we let go of the keyboard entirely then.
local function UpdateKeyboard()
  local want = frame:IsShown() and not inCombat and not InCombatLockdown()
  if want == capturing then return end
  if want then
    pcall(frame.SetPropagateKeyboardInput, frame, true)
  end
  if pcall(frame.EnableKeyboard, frame, want) then capturing = want end
  ReleaseAll()
end

local function EnterCombat()
  inCombat = true
  if not frame then return end
  if game.phase == "running" then
    game:Pause(true)
    combatPaused = true
  end
  UpdateKeyboard()
  Refresh()
end

local function LeaveCombat()
  inCombat = false
  if not frame then return end
  UpdateKeyboard()
  Refresh()
end
ns.EnterCombat, ns.LeaveCombat = EnterCombat, LeaveCombat

function ns.InCombat() return inCombat end
function ns.IsShown() return frame ~= nil and frame:IsShown() end

-- A party match just began (after the countdown): fresh input state.
function ns.OnMatchStart()
  combatPaused = false
  rep:Clear()
  if inCombat then
    game:Pause(true)
    combatPaused = true
  end
  Refresh()
end

-- Returns true when the key is ours (swallow it), false to pass it on.
local function HandleKey(key)
  if key == "ESCAPE" then
    frame:Hide()
    return true
  end
  if IsControlKeyDown() or IsAltKeyDown() then return false end
  local action = KEYMAP[key]
  if not action then return false end
  if game.phase == "running" then
    if held[key] then return true end
    held[key] = action
    if action == "left" or action == "right" or action == "soft" then rep:Press(action)
    elseif action == "cw" then game:Rotate(1)
    elseif action == "ccw" then game:Rotate(-1)
    elseif action == "hard" then game:HardDrop()
    elseif action == "hold" then game:Hold()
    elseif action == "pause" then
      if not ns.Party.InMatch() then game:Pause(true); rep:Clear() end   -- no pausing a party match
    end
    return true
  end
  -- Not running: only P and Space are ours (start, resume, play again).
  if action == "pause" and ns.Party.InMatch() then return true end
  if action == "pause" or action == "hard" then
    if not held[key] then
      held[key] = action
      PrimaryAction()
    end
    return true
  end
  return false
end

local function OnKeyDown(self, key)
  if inCombat or InCombatLockdown() then
    EnterCombat()
    return
  end
  local ours = HandleKey(key)
  self:SetPropagateKeyboardInput(not ours)
end

-- Key-ups follow the same rule, so a movement key pressed before ours still
-- reaches the game when it is let go.
local function OnKeyUp(self, key)
  local action = held[key]
  if action then
    held[key] = nil
    rep:Release(action)
  end
  if inCombat or InCombatLockdown() then return end
  self:SetPropagateKeyboardInput(action == nil)
end

-- If a key-up goes elsewhere (chat opened mid-press), IsKeyDown tells us; it is
-- only trusted once it has reported a held key as down at least once.
local function CheckHeldKeys()
  if not IsKeyDown then return end
  for key, action in pairs(held) do
    local down = IsKeyDown(key)
    if down then
      keyDownTrusted = true
    elseif keyDownTrusted and down == false then
      held[key] = nil
      rep:Release(action)
    end
  end
end

local function OnUpdate(_, elapsed)
  if elapsed > 0.25 then elapsed = 0.25 end   -- after a loading hitch, don't drop the piece 30 rows
  if game.phase == "running" then
    CheckHeldKeys()
    rep:Update(elapsed)
    game:Update(elapsed)
  end
  if game.best > (BlockfallDB.best or 0) then BlockfallDB.best = game.best end
  if game.clears ~= seenClears then
    seenClears = game.clears
    if game.clears > 0 then
      popText:SetText("+" .. Comma(game.lastPoints))
      popT = 0.9
    end
  end
  if popT > 0 then
    popT = popT - elapsed
    popText:SetAlpha(math.max(0, math.min(1, popT / 0.4)))
    popText:SetShown(popT > 0)
  end
  local party = ns.Party.version
  if game.version ~= seenVersion or party ~= seenParty or game.clearing or ns.Party.Countdown() then
    seenVersion, seenParty = game.version, party
    Render()
  end
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------
local function SavePosition()
  local point, _, relPoint, x, y = frame:GetPoint(1)
  if point then BlockfallDB.pos = { point, relPoint, x, y } end
end

local function PlaceFrame()
  frame:ClearAllPoints()
  local pos = BlockfallDB.pos
  if pos then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  end
end

local function Label(parent, text, x, y)
  local fs = Font(parent, "GameFontNormalSmall", C.label)
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetText(text)
  return fs
end

local function BuildWell()
  well = Box(frame, BOX_W, BOX_H, C.well, C.line)
  well:SetPoint("TOPLEFT", PAD, -TITLE_H)
  for row = 1, ROWS do
    cells[row] = {}
    for x = 1, COLS do
      local fill = Tex(well, "ARTWORK", 0, C.empty)
      fill:SetSize(CELL - 1, CELL - 1)
      fill:SetPoint("TOPLEFT", 1 + (x - 1) * CELL + 1, -(1 + (row - 1) * CELL + 1))
      local shine = Tex(well, "ARTWORK", 1, { 1, 1, 1, 0.18 })
      shine:SetPoint("TOPLEFT", fill, "TOPLEFT")
      shine:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
      shine:SetHeight(3)
      shine:Hide()
      local shade = Tex(well, "ARTWORK", 1, { 0, 0, 0, 0.28 })
      shade:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT")
      shade:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
      shade:SetHeight(3)
      shade:Hide()
      cells[row][x] = { fill = fill, shine = shine, shade = shade }
    end
  end

  -- Incoming garbage meter, just right of the well, growing from the bottom.
  garbageBar = Tex(frame, "ARTWORK", 0, C.garbage)
  garbageBar:SetWidth(4)
  garbageBar:SetPoint("BOTTOMLEFT", well, "BOTTOMRIGHT", 2, 1)
  garbageBar:Hide()

  popText = Font(well, "GameFontNormalLarge", C.accent, "CENTER")
  popText:SetPoint("TOP", 0, -36)
  popText:Hide()

  overlay = CreateFrame("Button", nil, well)
  overlay:SetAllPoints()
  overlay:SetFrameLevel(well:GetFrameLevel() + 5)
  local shade = Tex(overlay, "BACKGROUND", 0, { 0.02, 0.022, 0.035, 0.80 })
  shade:SetAllPoints()
  overlay.title = Font(overlay, "GameFontNormalLarge", C.accent, "CENTER")
  overlay.title:SetPoint("CENTER", 0, 80)
  overlay.count = Font(overlay, "GameFontNormalHuge", C.value, "CENTER")
  overlay.count:SetPoint("BOTTOM", overlay.title, "TOP", 0, 10)
  overlay.sub = Font(overlay, "GameFontHighlightSmall", C.value, "CENTER")
  overlay.sub:SetPoint("TOP", overlay.title, "BOTTOM", 0, -10)
  overlay.sub:SetWidth(WELL_W - 12)
  overlay.sub:SetSpacing(2)
  overlay.button = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
  overlay.button:SetSize(100, 22)
  overlay.button:SetPoint("BOTTOM", 0, 40)
  overlay.button:SetScript("OnClick", PrimaryAction)
  overlay:SetScript("OnClick", PrimaryAction)
end

local function BuildSide()
  local x0 = PAD + BOX_W + PAD
  local y = -TITLE_H

  Label(frame, "HOLD", x0, y)
  local hold = Box(frame, SIDE_W, 36, C.box, C.line)
  hold:SetPoint("TOPLEFT", x0, y - 14)
  for i = 1, 4 do
    local t = Tex(hold, "ARTWORK", 0)
    t:SetSize(MINI - 1, MINI - 1)
    holdTex[i] = t
  end
  holdTex.slot = hold
  y = y - 14 - 36 - 10

  Label(frame, "NEXT", x0, y)
  local nextBox = Box(frame, SIDE_W, 96, C.box, C.line)
  nextBox:SetPoint("TOPLEFT", x0, y - 14)
  for s = 1, 3 do
    local slot = CreateFrame("Frame", nil, nextBox)
    slot:SetSize(SIDE_W, 30)
    slot:SetPoint("TOP", 0, -3 - (s - 1) * 30)
    nextTex[s] = { slot = slot }
    for i = 1, 4 do
      local t = Tex(slot, "ARTWORK", 0)
      t:SetSize(MINI - 1, MINI - 1)
      nextTex[s][i] = t
    end
  end
  y = y - 14 - 96 - 14

  for _, k in ipairs({ { "score", "SCORE" }, { "lines", "LINES" }, { "level", "LEVEL" }, { "best", "BEST" } }) do
    Label(frame, k[2], x0, y)
    local v = Font(frame, k[1] == "score" and "GameFontHighlightLarge" or "GameFontHighlight", C.value)
    v:SetPoint("TOPLEFT", x0, y - 13)
    stat[k[1]] = v
    y = y - (k[1] == "score" and 40 or 34)
  end
end

function ns.CreateUI(theGame)
  game = theGame
  rep = Game.Repeat.New(game)

  frame = CreateFrame("Frame", "BlockfallFrame", UIParent, "BackdropTemplate")
  frame:SetSize(PAD + BOX_W + PAD + SIDE_W + PAD, TITLE_H + BOX_H + PAD)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetDontSavePosition(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
  frame:SetBackdrop({
    bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
  frame:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
  frame:Hide()

  -- Title: a little falling-block mark and the name.
  local marks = { { "I", 0, 0 }, { "J", 6, 0 }, { "T", 6, -6 } }
  for _, m in ipairs(marks) do
    local t = Tex(frame, "ARTWORK", 0, C.piece[m[1]])
    t:SetSize(5, 5)
    t:SetPoint("TOPLEFT", PAD + m[2], -8 + m[3])
  end
  local title = Font(frame, "GameFontNormal", C.accent)
  title:SetPoint("TOPLEFT", PAD + 17, -8)
  title:SetText("Blockfall")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetSize(22, 22)
  close:SetPoint("TOPRIGHT", -3, -3)

  BuildWell()
  BuildSide()
  ns.PartyUI.Build(frame, PAD + BOX_W + PAD + SIDE_W + PAD, -TITLE_H,
    { Font = Font, Tex = Tex, Box = Box, C = C, Comma = Comma })
  PlaceFrame()

  frame:SetScript("OnKeyDown", OnKeyDown)
  frame:SetScript("OnKeyUp", OnKeyUp)
  frame:SetScript("OnUpdate", OnUpdate)
  frame:SetScript("OnShow", function()
    UpdateKeyboard()
    ns.Party.OnOpen()
    Refresh()
  end)
  frame:SetScript("OnHide", function()
    ns.Party.OnClose()                 -- leaves a party match (others see you as out)
    if game.phase == "running" then game:Pause(true) end
    UpdateKeyboard()
  end)

  -- Esc closes the window (when the keyboard is not ours, e.g. in combat).
  if UISpecialFrames then tinsert(UISpecialFrames, "BlockfallFrame") end

  inCombat = InCombatLockdown() and true or false
end

function ns.ToggleUI()
  if not frame then return end
  frame:SetShown(not frame:IsShown())
end

function ns.ResetPosition()
  BlockfallDB.pos = nil
  if frame then PlaceFrame() end
end

function ns.Frame() return frame end
