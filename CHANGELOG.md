# Changelog

## [1.1.0] - 2026-07-08
### Added
- Per-character loot history — each character keeps its own log.
- Auto-greed all green (uncommon) items (optional).
- Auto-greed drops for slots where you wear an heirloom (optional).
- "Wrong armor type" mode now also greeds weapons your character can't use.
- Pawn integration: shows the upgrade % versus your equipped item (for your
  active spec's scale) under the icon, with an item-level fallback.
- The window auto-opens when a drop needs a roll and auto-closes once nothing is
  pending; windows you open manually stay open.

### Changed
- Item tooltips now anchor beside the window so they never cover the icons, and
  equipped-item comparisons no longer overlap.
- Sensible defaults: auto-greed of materials, greens and heirloom-slot drops is
  on by default.

## [1.0.0] - 2026-07-07
Initial release for Mists of Pandaria Classic (5.5.4).

### Added
- Auto-greed of loot your character can't use, with two modes: "anything I can't
  equip/use" and the smart "wrong armor type" rule (per class and level).
- Auto-confirm of the Bind-on-Pickup roll and loot confirmations.
- Loot-log window that replaces Blizzard's roll frames: roll Need / Greed / Pass /
  Disenchant from the window, with the pending item pulsing for attention.
- Need detection: class-coloured circles showing who rolled Need, with a crown over
  the winner.
- Optional auto-greed of gems, reagents and crafting materials.
- Enchanter option: disenchant instead of greed.
- Movable window with history (up to 100 rolls), mouse-wheel scrolling, and
  persistence across `/reload`.
- Ctrl+Right-click an item icon in the window to try it on in the Dressing Room.
- Minimap button (left-click: window, right-click: settings) and a settings panel.
- Scope control: acts in dungeons and raids by default.
