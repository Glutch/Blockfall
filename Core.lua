-- Blockfall startup: saved variables, events (combat, group, addon messages),
-- the party tick and the /blockfall, /bf commands.
local ADDON, ns = ...

local events = CreateFrame("Frame")
local loggedIn = false

local HELP = {
  "|cffffbd61/bf|r  open or close the game",
  "|cffffbd61/bf reset|r  move the window back to the middle",
  "Party: everyone in your group who opens Blockfall joins the lobby; press Start for a match.",
  "|cffffbd61/bf keys|r  change the keys (or click Keys in the window)",
}

SLASH_BLOCKFALL1 = "/blockfall"
SLASH_BLOCKFALL2 = "/bf"
SlashCmdList.BLOCKFALL = function(msg)
  local cmd = strlower(strtrim(msg or ""))
  if cmd == "" then
    ns.ToggleUI()
  elseif cmd == "keys" then
    if ns.Frame() and not ns.Frame():IsShown() then ns.ToggleUI() end
    ns.KeysUI.Open()
  elseif cmd == "reset" then
    ns.ResetPosition()
    ns.Print("window position reset")
  else
    for _, line in ipairs(HELP) do print(line) end
    print("Keys: " .. ns.Keys.Hint():gsub("\n", ", ") .. ", Esc close")
  end
end

events:SetScript("OnEvent", function(self, event, arg1, ...)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    BlockfallDB = BlockfallDB or {}
    BlockfallDB.best = BlockfallDB.best or 0
    ns.Keys.Load(BlockfallDB)
    ns.game = ns.Game.New({ best = BlockfallDB.best })
    ns.CreateUI(ns.game)
    self:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_LOGIN" then
    ns.Party.Init()
    loggedIn = true
  elseif event == "CHAT_MSG_ADDON" then
    if loggedIn then ns.Party.OnMessage(arg1, ...) end
  elseif event == "GROUP_ROSTER_UPDATE" or event == "GROUP_LEFT" then
    if loggedIn then ns.Party.OnRoster() end
  elseif event == "PLAYER_REGEN_DISABLED" then
    if ns.EnterCombat then ns.EnterCombat() end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if ns.LeaveCombat then ns.LeaveCombat() end
  end
end)

-- Party messages go out from here, so a goodbye still leaves after the window closes.
local tick = 0
events:SetScript("OnUpdate", function(_, elapsed)
  tick = tick + elapsed
  if tick < 0.1 or not loggedIn then return end
  tick = 0
  ns.Party.Tick()
end)

for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "GROUP_LEFT" }) do
  events:RegisterEvent(e)
end
