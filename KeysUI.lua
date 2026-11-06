-- Blockfall key binding editor: a panel over the well. Click a slot, press a
-- key. Right-click clears a slot, Esc cancels, "Defaults" restores the standard keys.
local _, ns = ...

local KeysUI = {}
ns.KeysUI = KeysUI

local Keys = ns.Keys
local WHITE = "Interface\\Buttons\\WHITE8x8"
local ROW_H, BTN_W, BTN_H, GAP = 24, 46, 20, 4

local panel, status, h
local buttons = {}     -- buttons[action][slot]
local listen           -- { action, slot } while waiting for a key
local onOpen, onClose

local function Paint(b)
  local C = h.C
  local key = Keys.Get(b.action, b.slot)
  local active = listen and listen.action == b.action and listen.slot == b.slot
  if active then
    b.text:SetText("Press a key")
    b.text:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    b:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
  else
    b.text:SetText(key and Keys.Name(key) or "-")
    local col = key and C.value or C.dim
    b.text:SetTextColor(col[1], col[2], col[3])
    local e = b.hover and C.accent or C.line
    b:SetBackdropBorderColor(e[1], e[2], e[3], 1)
  end
end

local function PaintAll()
  for _, row in pairs(buttons) do
    for _, b in ipairs(row) do Paint(b) end
  end
  if panel then panel.defaults:SetEnabled(not Keys.IsDefault()) end
end

local function Say(text) status:SetText(text or "") end

local function LabelOf(action)
  for _, a in ipairs(Keys.ACTIONS) do if a.id == action then return a.label end end
  return action
end

local function SlotButton(action, slot)
  local C = h.C
  local b = CreateFrame("Button", nil, panel, "BackdropTemplate")
  b:SetSize(BTN_W, BTN_H)
  b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  b:SetBackdropColor(C.box[1], C.box[2], C.box[3], 1)
  b.text = h.Font(b, "GameFontHighlightSmall", C.value, "CENTER")
  b.text:SetPoint("CENTER")
  b.text:SetWidth(BTN_W - 4)
  b.text:SetWordWrap(false)
  b.action, b.slot = action, slot
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, mouse)
    if mouse == "RightButton" then
      listen = nil
      Keys.Clear(self.action, self.slot)
      Say("Cleared.")
    else
      listen = { action = self.action, slot = self.slot }
      Say("Press a key for " .. LabelOf(self.action) .. ". Esc cancels.")
    end
    PaintAll()
  end)
  b:SetScript("OnEnter", function(self) self.hover = true; Paint(self) end)
  b:SetScript("OnLeave", function(self) self.hover = false; Paint(self) end)
  return b
end

local function TextButton(text, w)
  local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

-- parent: the Blockfall window; x, y, w, hgt: where the panel sits.
function KeysUI.Build(parent, x, y, w, hgt, helpers, hooks)
  h = helpers
  onOpen, onClose = hooks and hooks.onOpen, hooks and hooks.onClose
  local C = h.C
  panel = h.Box(parent, w, hgt, C.bg, C.border)
  panel:SetPoint("TOPLEFT", x, y)
  panel:SetFrameLevel(parent:GetFrameLevel() + 40)
  panel:EnableMouse(true)
  panel:Hide()

  local title = h.Font(panel, "GameFontNormal", C.accent)
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("Key bindings")

  local slotsW = Keys.SLOTS * BTN_W + (Keys.SLOTS - 1) * GAP
  for i, a in ipairs(Keys.ACTIONS) do
    local rowY = -34 - (i - 1) * ROW_H
    local label = h.Font(panel, "GameFontHighlightSmall", C.label)
    label:SetPoint("TOPLEFT", 10, rowY - 4)
    label:SetText(a.label)
    buttons[a.id] = {}
    for slot = 1, Keys.SLOTS do
      local b = SlotButton(a.id, slot)
      b:SetPoint("TOPLEFT", w - 10 - slotsW + (slot - 1) * (BTN_W + GAP), rowY)
      buttons[a.id][slot] = b
    end
  end

  status = h.Font(panel, "GameFontHighlightSmall", C.accent)
  status:SetPoint("TOPLEFT", 10, -34 - #Keys.ACTIONS * ROW_H - 4)
  status:SetPoint("RIGHT", -10, 0)
  status:SetWordWrap(true)

  local hint = h.Font(panel, "GameFontDisableSmall", C.dim)
  hint:SetPoint("BOTTOMLEFT", 10, 40)
  hint:SetPoint("RIGHT", -10, 0)
  hint:SetText("Click a slot, then press a key. Right-click clears.")

  panel.defaults = TextButton("Defaults", 86)
  panel.defaults:SetPoint("BOTTOMLEFT", 10, 10)
  panel.defaults:SetScript("OnClick", function()
    listen = nil
    Keys.Reset()
    Say("Back to the standard keys.")
    PaintAll()
  end)
  local done = TextButton("Done", 86)
  done:SetPoint("BOTTOMRIGHT", -10, 10)
  done:SetScript("OnClick", function() KeysUI.Close() end)
end

function KeysUI.IsOpen() return panel ~= nil and panel:IsShown() end
function KeysUI.Listening() return listen ~= nil end

function KeysUI.Open()
  if not panel then return end
  listen = nil
  Say("")
  PaintAll()
  panel:Show()
  if onOpen then onOpen() end
end

function KeysUI.Close()
  if not panel then return end
  listen = nil
  panel:Hide()
  if onClose then onClose() end
end

function KeysUI.Toggle()
  if KeysUI.IsOpen() then KeysUI.Close() else KeysUI.Open() end
end

-- A key went down while the panel is open. Returns true when the panel used it.
function KeysUI.Key(key)
  if not KeysUI.IsOpen() then return false end
  if not listen then
    if key == "ESCAPE" then KeysUI.Close() return true end
    return false
  end
  if key == "ESCAPE" then
    listen = nil
    Say("Cancelled.")
    PaintAll()
    return true
  end
  local l = listen
  listen = nil
  local ok, info = Keys.Set(l.action, l.slot, key)
  if not ok then
    Say(info == "reserved" and "Esc can't be bound: it closes the game." or "Can't bind that key.")
  elseif info then
    Say(Keys.Name(key) .. " now " .. LabelOf(l.action):lower() .. " (was " .. LabelOf(info):lower() .. ").")
  else
    Say(Keys.Name(key) .. " set.")
  end
  PaintAll()
  return true
end

-- For tests and debugging: the slot button for an action.
function KeysUI.Button(action, slot) return buttons[action] and buttons[action][slot] end
