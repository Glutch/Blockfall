-- Blockfall party column: who is here (lobby) and the opponents' mini boards
-- (match). Sits to the right of the side panel and only shows in a party.
local ADDON, ns = ...
local Game, Proto = ns.Game, ns.Proto

local PartyUI = {}
ns.PartyUI = PartyUI

PartyUI.WIDTH = 120
local MINI_CELL = 5
local MAX_ROWS = 9
local SLOTS = 4
local BOARD_W, BOARD_H = Game.W * MINI_CELL + 2, Game.VISIBLE * MINI_CELL + 2

local col, header, listRows, slots, moreText
local K                                   -- shared look from UI.lua

local function Hex(r, g, b)
  return string.format("|cff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end
PartyUI.Hex = Hex

local STATUS_COLOR = {
  L = "|cff8f98b8", R = "|cffffbd61", P = "|cff7fdca4", O = "|cffe0605a", C = "|cffff8a4a", S = "|cff8f98b8", W = "|cff8f98b8",
}

local function BuildSlot(i)
  local s = CreateFrame("Frame", nil, col)
  s:SetSize(BOARD_W, BOARD_H + 26)
  local cx = ((i - 1) % 2) * (BOARD_W + 12)
  local cy = -16 - math.floor((i - 1) / 2) * (BOARD_H + 32)
  s:SetPoint("TOPLEFT", cx, cy)
  s.name = K.Font(s, "GameFontHighlightSmall", K.C.value)
  s.name:SetPoint("TOPLEFT", 0, 0)
  s.name:SetWidth(BOARD_W + 10)
  s.name:SetWordWrap(false)
  s.box = K.Box(s, BOARD_W, BOARD_H, K.C.well, K.C.line)
  s.box:SetPoint("TOPLEFT", 0, -12)
  s.cells = {}
  for row = 1, Game.VISIBLE do
    s.cells[row] = {}
    for x = 1, Game.W do
      local t = K.Tex(s.box, "ARTWORK", 0, K.C.empty)
      t:SetSize(MINI_CELL - 1, MINI_CELL - 1)
      t:SetPoint("TOPLEFT", 1 + (x - 1) * MINI_CELL, -(1 + (row - 1) * MINI_CELL))
      s.cells[row][x] = t
    end
  end
  s.score = K.Font(s, "GameFontDisableSmall", K.C.label)
  s.score:SetPoint("TOPLEFT", s.box, "BOTTOMLEFT", 0, -2)
  s.ko = CreateFrame("Frame", nil, s.box)
  s.ko:SetAllPoints()
  s.ko:SetFrameLevel(s.box:GetFrameLevel() + 3)
  local shade = K.Tex(s.ko, "BACKGROUND", 0, { 0.02, 0.02, 0.03, 0.62 })
  shade:SetAllPoints()
  s.ko.text = K.Font(s.ko, "GameFontNormalLarge", { 0.92, 0.36, 0.33 }, "CENTER")
  s.ko.text:SetPoint("CENTER", 0, 6)
  s.ko.text:SetText("K.O.")
  s.ko.place = K.Font(s.ko, "GameFontHighlightSmall", K.C.value, "CENTER")
  s.ko.place:SetPoint("TOP", s.ko.text, "BOTTOM", 0, -2)
  s:Hide()
  return s
end

function PartyUI.Build(frame, x, y, kit)
  K = kit
  col = CreateFrame("Frame", nil, frame)
  col:SetPoint("TOPLEFT", x, y)
  col:SetSize(PartyUI.WIDTH, 330)
  header = K.Font(col, "GameFontNormalSmall", K.C.label)
  header:SetPoint("TOPLEFT", 0, 0)
  header:SetText("PARTY")
  listRows = {}
  for i = 1, MAX_ROWS do
    local r = {}
    r.name = K.Font(col, "GameFontHighlightSmall", K.C.value)
    r.name:SetPoint("TOPLEFT", 0, -16 - (i - 1) * 26)
    r.name:SetWidth(PartyUI.WIDTH)
    r.name:SetWordWrap(false)
    r.status = K.Font(col, "GameFontDisableSmall", K.C.label)
    r.status:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 6, -1)
    listRows[i] = r
  end
  slots = {}
  for i = 1, SLOTS do slots[i] = BuildSlot(i) end
  moreText = K.Font(col, "GameFontDisableSmall", K.C.label)
  moreText:SetPoint("BOTTOMLEFT", 0, 2)
  col:Hide()
  return col
end

local function ShowRow(r, text, status)
  r.name:SetText(text); r.name:Show()
  r.status:SetText(status or ""); r.status:Show()
end

local function RenderList(players)
  local n = 0
  for i, p in ipairs(players) do
    if i > MAX_ROWS then break end
    n = i
    local name = Hex(p.r, p.g, p.b) .. p.short .. "|r" .. (p.me and " |cff8f98b8(you)|r" or "")
    if p.wins > 0 then name = name .. string.format("  |cffffbd61%d|r", p.wins) end
    local status = p.ok and ((STATUS_COLOR[p.status] or "") .. (ns.Party.STATUS[p.status] or "") .. "|r")
      or "|cffe0605aneeds update|r"
    ShowRow(listRows[i], name, status)
  end
  for i = n + 1, MAX_ROWS do listRows[i].name:Hide(); listRows[i].status:Hide() end
  local extra = #players - MAX_ROWS
  moreText:SetText(extra > 0 and ("+" .. extra .. " more") or "")
end

local function PaintBoard(s, o)
  local board = o.board
  for row = 1, Game.VISIBLE do
    local v = board and board[row] or 0
    for x = 1, Game.W do
      local t = s.cells[row][x]
      if v > 0 and Proto.Bit(v, x) then t:SetVertexColor(o.r * 0.85, o.g * 0.85, o.b * 0.85, 1)
      else t:SetVertexColor(K.C.empty[1], K.C.empty[2], K.C.empty[3], 1) end
    end
  end
end

local function RenderBoards(opponents)
  for i = 1, SLOTS do
    local s, o = slots[i], opponents[i]
    if o then
      s.name:SetText(Hex(o.r, o.g, o.b) .. o.short .. "|r")
      if o.alive and o.status == "C" then
        s.score:SetText(K.Comma(o.score or 0) .. "  |cffff8a4ain combat|r")
      else
        s.score:SetText(K.Comma(o.score or 0) .. "  |cff6b7390" .. (o.lines or 0) .. " lines|r")
      end
      PaintBoard(s, o)
      s.ko:SetShown(not o.alive)
      s.ko.place:SetText(o.place and ("#" .. o.place) or "")
      s:Show()
    else
      s:Hide()
    end
  end
  local extra = #opponents - SLOTS
  moreText:SetText(extra > 0 and ("+" .. extra .. " more") or "")
end

-- Returns true when the column should be visible (the window widens for it).
function PartyUI.Render()
  local P = ns.Party
  local inMatch = P.Match() ~= nil
  local want = inMatch or (P.Present() and P.HasPeers())
  if not want then col:Hide() return false end
  col:Show()
  if inMatch and (P.Match().started or not P.Match().mine) then
    header:SetText(P.Watching() and "WATCHING" or "OPPONENTS")
    for i = 1, MAX_ROWS do listRows[i].name:Hide(); listRows[i].status:Hide() end
    -- Highest scores first among the living, K.O.s after.
    RenderBoards(P.Opponents())
  else
    header:SetText("PARTY")
    for i = 1, SLOTS do slots[i]:Hide() end
    RenderList(P.Players())
  end
  return true
end
