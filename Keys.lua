-- Blockfall key bindings: which keys do what, saved in BlockfallDB.keys.
-- Every action has up to Keys.SLOTS keys; a key belongs to one action at most.
-- Pure Lua apart from reading global key names for display.
local _, ns = ...
ns = ns or {}

local Keys = {}
Keys.SLOTS = 3

-- In the order the editor lists them.
Keys.ACTIONS = {
  { id = "left",  label = "Move left" },
  { id = "right", label = "Move right" },
  { id = "soft",  label = "Soft drop" },
  { id = "hard",  label = "Hard drop" },
  { id = "cw",    label = "Rotate right" },
  { id = "ccw",   label = "Rotate left" },
  { id = "hold",  label = "Hold" },
  { id = "pause", label = "Pause" },
}

Keys.DEFAULTS = {
  left = { "LEFT", "A" }, right = { "RIGHT", "D" }, soft = { "DOWN", "S" },
  hard = { "SPACE" }, cw = { "UP", "W", "X" }, ccw = { "Z" },
  hold = { "C", "LSHIFT", "RSHIFT" }, pause = { "P" },
}

-- Keys that can't be bound: Esc always closes (or cancels).
Keys.RESERVED = { ESCAPE = true }

local binds = {}   -- action -> { [slot] = key }
local byKey = {}   -- key -> action
local db           -- BlockfallDB

local function Copy(t)
  local out = {}
  for action, list in pairs(t) do
    out[action] = {}
    for slot = 1, Keys.SLOTS do out[action][slot] = list[slot] end
  end
  return out
end

local function Rebuild()
  for k in pairs(byKey) do byKey[k] = nil end
  for _, a in ipairs(Keys.ACTIONS) do
    binds[a.id] = binds[a.id] or {}
    for slot = 1, Keys.SLOTS do
      local key = binds[a.id][slot]
      if key then
        if byKey[key] or Keys.RESERVED[key] then binds[a.id][slot] = nil  -- saved data with a clash
        else byKey[key] = a.id end
      end
    end
  end
  Keys.version = (Keys.version or 0) + 1
end

local function Save()
  if not db then return end
  db.keys = Copy(binds)
end

-- Saved bindings, or the defaults when there are none.
function Keys.Load(saved)
  db = saved
  local src = (saved and type(saved.keys) == "table") and saved.keys or Keys.DEFAULTS
  binds = {}
  for _, a in ipairs(Keys.ACTIONS) do
    binds[a.id] = {}
    local list = type(src[a.id]) == "table" and src[a.id] or {}
    for slot = 1, Keys.SLOTS do
      if type(list[slot]) == "string" and list[slot] ~= "" then binds[a.id][slot] = list[slot] end
    end
  end
  Rebuild()
end

function Keys.Action(key) return byKey[key] end
function Keys.Get(action, slot) return binds[action] and binds[action][slot] end

-- Binds key to action/slot. Returns the action that lost the key, if any,
-- or false plus a reason when the key can't be bound.
function Keys.Set(action, slot, key)
  if not binds[action] or slot < 1 or slot > Keys.SLOTS then return false, "bad slot" end
  if Keys.RESERVED[key] then return false, "reserved" end
  local old = byKey[key]
  if old then
    for s = 1, Keys.SLOTS do if binds[old][s] == key then binds[old][s] = nil end end
  end
  binds[action][slot] = key
  Rebuild()
  Save()
  return true, (old and old ~= action) and old or nil
end

function Keys.Clear(action, slot)
  if binds[action] then binds[action][slot] = nil end
  Rebuild()
  Save()
end

function Keys.Reset()
  binds = Copy(Keys.DEFAULTS)
  Rebuild()
  if db then db.keys = nil end
end

function Keys.IsDefault()
  for _, a in ipairs(Keys.ACTIONS) do
    for slot = 1, Keys.SLOTS do
      if binds[a.id][slot] ~= Keys.DEFAULTS[a.id][slot] then return false end
    end
  end
  return true
end

local PRETTY = {
  LEFT = "Left", RIGHT = "Right", UP = "Up", DOWN = "Down", SPACE = "Space",
  LSHIFT = "L-Shift", RSHIFT = "R-Shift", LCTRL = "L-Ctrl", RCTRL = "R-Ctrl",
  LALT = "L-Alt", RALT = "R-Alt", ENTER = "Enter", BACKSPACE = "Backspace", TAB = "Tab",
  CAPSLOCK = "Caps Lock", INSERT = "Insert", DELETE = "Delete", HOME = "Home", END = "End",
  PAGEUP = "Page Up", PAGEDOWN = "Page Down",
}

-- Short, readable name for a key ("NUMPAD4" -> "Num 4").
function Keys.Name(key)
  if not key then return nil end
  if PRETTY[key] then return PRETTY[key] end
  local n = key:match("^NUMPAD(.+)$")
  if n then return "Num " .. n end
  local g = rawget(_G, "KEY_" .. key)
  if type(g) == "string" and g ~= "" and #g <= 12 then return g end
  return key:sub(1, 1) .. key:sub(2):lower()
end

-- "Left / A" for an action's keys, or "-" when it has none.
function Keys.List(action)
  local out = {}
  for slot = 1, Keys.SLOTS do
    local k = Keys.Get(action, slot)
    if k then out[#out + 1] = Keys.Name(k) end
  end
  return #out > 0 and table.concat(out, "/") or "-"
end

-- Compact controls hint for the start screen.
function Keys.Hint()
  return "Move " .. Keys.List("left") .. ", " .. Keys.List("right") ..
    "\nDrop " .. Keys.List("soft") .. ", " .. Keys.List("hard") ..
    "\nRotate " .. Keys.List("cw") .. ", " .. Keys.List("ccw") ..
    "\nHold " .. Keys.List("hold") .. "   Pause " .. Keys.List("pause")
end

Keys.Load(nil)
ns.Keys = Keys
return Keys
