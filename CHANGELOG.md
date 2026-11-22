# Changelog

## [1.5.1] - 2026-11-22
### Fixed
- WoW Forever now uses its available item-info API, restoring automatic Greed
  for materials, green items, and armor covered by the selected rule.
- A new roll that needs a decision opens the loot window even when item data is
  still loading or the previous window was closed.
- Recipes for professions the character does not have are greeded in every
  auto-greed mode. Recipes and materials no longer wait on Pawn's gear check.

### Added
- `/bdl mode` and `/bdl scope` commands to choose the auto-greed rule and where
  automatic actions apply.
- `/bdl status` now reports the last roll decision and relevant client state.

## [1.5.0] - 2026-11-08
### Added
- WoW Forever (1.60.1) compatibility: its loot-history API and Transmog roll
  button are handled separately while the same addon files support the existing
  Classic clients.
- Repeatable installation into the Forever client with `install-forever.sh`.

### Fixed
- The addon now loads correctly in Forever when `GetBuildInfo()` returns multiple
  values.
- Blizzard's default group-loot frames are hidden in Forever while their roll
  lifecycle remains active.

## [1.4.0] - 2026-10-24
### Added
- Support for Burning Crusade Classic Anniversary (2.5.6) alongside Mists of
  Pandaria Classic (5.5.4) in the same addon package.

### Packaging
- Keep the Git checkout outside `AddOns` and use the local install script to
  restore the Anniversary copy after CurseForge updates it.

## [1.3.0] - 2026-07-09
### Added
- Countdown bar on rolls that still need your decision: a coloured bar under each
  pending item fills down as the timer runs out (green → yellow → red), so you can
  see at a glance how long is left to roll. Can be turned off in the settings panel.
- New auto-greed mode (shown only when Pawn is installed): **greed everything that
  isn't a Pawn upgrade** — actual upgrades for your active spec are left for you to
  roll on, everything else is greeded.

### Changed
- The Pawn upgrade % / arrow now shows automatically whenever Pawn is installed —
  the separate "Show upgrade % vs equipped" toggle has been removed (it was
  redundant).
- Heirloom-slot auto-greed now takes priority over Pawn: a drop for a slot you fill
  with an heirloom is greeded even if Pawn rates it as an upgrade (you keep the
  heirloom). Previously the "never auto-greed a Pawn upgrade" rule could override it.
- ...but only while the heirloom is still scaling: once you out-level its cap
  (the "Requires level 1 to 80/85" range), that slot is no longer force-greeded, so
  genuine upgrades replacing a dead heirloom go to a normal roll again.

### Removed
- The "Enchanters: disenchant instead of greed" option (disenchant-on-roll isn't
  supported on this MoP Classic build).

## [1.2.0] - 2026-07-08
### Added
- Option "Never auto-greed a Pawn upgrade" — items Pawn considers an upgrade are
  left for you to roll on instead of being auto-greeded.
- `/bdl test` fills the window with sample rows so you can preview the layout.

### Changed
- Pawn upgrade display: a green upgrade arrow now sits on the item icon, with the
  percentage shown below it (with a shadow for readability).

### Fixed
- Pawn upgrade percentage not showing at all (readiness check now uses
  `PawnIsReady`).

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
