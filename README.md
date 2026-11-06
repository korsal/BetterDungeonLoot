# Better Dungeon Loot

Stop clicking every drop. **Better Dungeon Loot** automates the tedious parts of
group loot in Mists of Pandaria Classic (5.5.4) and Burning Crusade Classic
Anniversary (2.5.6) dungeons and gives you a clean, compact loot-roll log.

## Features
- **Auto-greed** drops your character can't use — choose between "anything I can't
  equip/use", the smart "wrong armor type" rule, or (with Pawn) "greed everything
  that isn't an upgrade".
- **Auto-confirm** the "this will bind to you" popups.
- **Loot log window** that replaces Blizzard's centre-screen roll frames: roll
  Need / Greed / Pass / Disenchant right from the window, with the item that needs
  a roll pulsing for attention and a countdown bar (green → yellow → red) showing
  how long you have left to roll.
- **See who rolled Need** — class-coloured circles with a crown over the winner
  (spot ninja looters at a glance).
- **Optional**: auto-greed gems, reagents & materials; auto-greed greens or
  heirloom-slot drops.
- Movable window, minimap button, and a settings panel.

By default it only acts inside dungeons and raids.

## Usage
- **Minimap button** — left-click: show/hide the window; right-click: settings.
- `/bdl` — command help
- `/bdl config` — open settings (rows shown, history size, auto-greed mode, …)
- `/bdl log` — show/hide the window

## Install
Keep this Git checkout at `World of Warcraft/BetterDungeonLoot`, outside the
game's `AddOns` directories. Run `./install-anniversary.sh` or
`./install-forever.sh` from this checkout to install the game files into the
corresponding client's `Interface/AddOns/BetterDungeonLoot` directory. Run the
installer again if CurseForge replaces the installed copy. It copies only the
`.toc` and `.lua` files, and removes other files from that game copy.

The same `.toc` supports MoP Classic (interface 50504), Burning Crusade Classic
Anniversary (interface 20506), and WoW Forever (interface 16001). Pawn is optional.

## Package for CurseForge
Run `./package.sh` from a clean release commit tagged with the `.toc` version.
It creates a ZIP containing
only `BetterDungeonLoot/BetterDungeonLoot.toc` and
`BetterDungeonLoot/BetterDungeonLoot.lua`. On the CurseForge file page, tag the
upload for both Mists of Pandaria Classic and Burning Crusade Classic Anniversary.

## License
Personal project; do as you like.
