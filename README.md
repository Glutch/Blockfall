# Blockfall

A falling-blocks puzzle game for **WoW Forever**, in a small in-game window. Play solo, or against everyone in your party who has it installed.

`/bf` (or `/blockfall`) opens and closes it.

## Install

You need the addon folder at `<WoW Forever folder>\Interface\AddOns\Blockfall`, with `Blockfall.toc` directly inside it.

**Option A, download:** get `Blockfall.zip` from the [latest release](https://github.com/Glutch/Blockfall/releases/latest) and unzip it into `Interface\AddOns`. It already contains the `Blockfall` folder.

**Option B, git** (easy to update with `git pull`):

```
cd "<WoW Forever folder>\Interface\AddOns"
git clone https://github.com/Glutch/Blockfall.git Blockfall
```

Then `/reload` in game, or restart the game if it doesn't show up. Check that "Blockfall" is ticked in the AddOns list on the character screen.

### Asking Claude (or another AI agent) to install it

Paste this:

> Install the WoW addon from https://github.com/Glutch/Blockfall for WoW Forever. Find my WoW Forever install (the `_forever_` folder inside the World of Warcraft folder, e.g. `C:\Program Files (x86)\World of Warcraft\_forever_`; check other drives too), then clone the repo into `_forever_\Interface\AddOns\Blockfall` so that `Blockfall.toc` sits directly in that folder. If it's already there, `git pull` instead. If git isn't available, download the release zip and unzip it into `Interface\AddOns`.

Notes for the agent:
- WoW Forever lives in its own `_forever_` folder, next to `_retail_` / `_classic_` if those exist. Install into `_forever_`, not the others.
- The folder name must be exactly `Blockfall`. GitHub's "Download ZIP" button gives `Blockfall-main`, which WoW won't load unless it's renamed. The release zip doesn't have this problem.
- Nothing needs building. These are plain Lua files.

## Play

| Key | Action |
|---|---|
| Left / Right, or A / D | Move |
| Down or S | Soft drop |
| Up, W or X | Rotate clockwise |
| Z | Rotate counter-clockwise |
| Space | Hard drop; also start, resume, replay |
| C or Shift | Hold |
| P | Pause (solo only) |
| Esc | Close |

These are the defaults. **To change them:** click **Keys** in the window's title bar (or type `/bf keys`), click a slot, then press the key you want. Each action has three slots. Binding a key that another action uses moves it over. Right-click a slot to clear it, Esc cancels, and **Defaults** brings the standard keys back. Your keys are saved and kept across reloads. Esc can't be bound, because it always closes the game.

Out of combat the game only takes these keys while you're playing; chat and everything else still work. On the start screen, in the lobby or while paused, WASD and the arrows move your character as usual.

**In combat you keep playing.** The game won't let addons change which keys they take during a fight, so while Blockfall is open in combat it takes the whole keyboard: your other keybinds don't work until you close it. Esc closes it and gives the keyboard back; Enter and / still open chat, unless you've bound them to a game action. Mouse clicks on your action bars work as usual.

## Party matches

1. Everyone in the party or raid opens Blockfall with `/bf`. The window shows a party list with everyone who has it open.
2. Anyone presses **Start**. After a 3-second countdown, everyone gets the same piece order.
3. Clearing 2, 3 or 4 lines sends 1, 2 or 4 garbage rows to an opponent. Incoming garbage shows as a red bar, and your own clears cancel it first.
4. The last player standing wins. Placements and session wins show at the end; Space starts the next round.

- Up to 8 players. Opponents show as small boards beside your well.
- If you open Blockfall mid-match, you watch and join the next round.
- Combat doesn't stop you (see the keys note above). Closing the window counts as leaving the match.
- The game can block addon messages in some places (such as boss fights). Blockfall says so, and solo play still works.

Everyone in the match needs the same major version of Blockfall (1.3 or newer). Players with an older version show as "needs update".

## Commands

- `/bf`: open or close
- `/bf keys`: change the keys
- `/bf reset`: move the window back to the middle
- `/bf help`: list commands
