-- Blockfall party protocol: message encoding and board packing. Pure Lua (no WoW
-- API), shared by Party.lua and the headless tests.
--
-- Every message is "<type>:<field>:<field>..." in plain ASCII, at most 255 bytes,
-- never containing "|" or control characters. Names are full "Name-Realm".
--   H:<proto>:<q|a>:<status>:<matchId|->:<wins>   hello / heartbeat (q asks for answers)
--   B                                             bye (window closed / leaving)
--   S:<matchId>:<seed>:<delayMs>:<name,name,...>  start a match
--   D:<matchId>:<score>:<lines>:<board>           board after a piece settled
--   A:<matchId>:<target>:<count>:<hole>           send garbage rows to target
--   O:<matchId>:<score>:<lines>:<board>           topped out
local _, ns = ...
ns = ns or {}

local Proto = {}
Proto.VERSION = "1.0"
Proto.MAJOR = 1
Proto.MAX_LEN = 255

-- 32 chat-safe symbols: 5 bits each, a 10-wide row in two characters.
local ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
local VALUE = {}
for i = 1, 32 do VALUE[ALPHA:sub(i, i)] = i - 1 end

-- Board rows (top to bottom, the visible part) -> 40-character string.
-- board[y][x] is truthy when filled; rows first..last are packed.
function Proto.PackBoard(board, first, last, width)
  width = width or 10
  local out = {}
  for y = first, last do
    local v, bit = 0, 1
    local row = board[y]
    for x = 1, width do
      if row[x] then v = v + bit end
      bit = bit * 2
    end
    local hi, lo = math.floor(v / 32), v % 32
    out[#out + 1] = ALPHA:sub(hi + 1, hi + 1) .. ALPHA:sub(lo + 1, lo + 1)
  end
  return table.concat(out)
end

-- String -> list of row bitmasks (numbers), or nil if malformed.
function Proto.UnpackBoard(s, rows)
  rows = rows or 20
  if type(s) ~= "string" or #s ~= rows * 2 then return nil end
  local out = {}
  for r = 1, rows do
    local hi, lo = VALUE[s:sub(2 * r - 1, 2 * r - 1)], VALUE[s:sub(2 * r, 2 * r)]
    if not hi or not lo then return nil end
    out[r] = hi * 32 + lo
  end
  return out
end

-- Is column x (1-based) set in a row bitmask?
function Proto.Bit(v, x)
  return math.floor(v / 2 ^ (x - 1)) % 2 == 1
end

function Proto.Encode(...)
  local parts = { ... }
  for i = 1, #parts do parts[i] = tostring(parts[i]) end
  local msg = table.concat(parts, ":")
  if #msg > Proto.MAX_LEN or msg:find("[%c|]") then return nil end
  return msg
end

function Proto.Decode(msg)
  if type(msg) ~= "string" or #msg == 0 or #msg > Proto.MAX_LEN then return nil end
  local parts = {}
  for field in (msg .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = field end
  return parts[1], parts
end

function Proto.Major(version)
  return tonumber(tostring(version or ""):match("^(%d+)"))
end

-- Comma list of names, trimmed so the whole message stays within MAX_LEN.
function Proto.NameList(names, room)
  local out, len = {}, 0
  for _, n in ipairs(names) do
    local add = #n + (#out > 0 and 1 or 0)
    if len + add > room then break end
    out[#out + 1] = n
    len = len + add
  end
  return table.concat(out, ","), out
end

function Proto.SplitNames(s)
  local out = {}
  for n in tostring(s or ""):gmatch("[^,]+") do out[#out + 1] = n end
  return out
end

ns.Proto = Proto
return Proto
