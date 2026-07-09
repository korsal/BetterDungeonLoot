# BetterDungeonLoot — Project Overview

Technical overview of the addon: what it does, how it is structured, and the
MoP Classic (5.5.4, interface **50504**) APIs it relies on.

BetterDungeonLoot removes the repetitive clicking around group loot in dungeons:
it can auto-roll on drops your character can't use, auto-confirms the "this will
bind to you" popups, hides Blizzard's centre-screen roll frames, and replaces
them with a compact, movable **loot log** that also shows who rolled Need
(ninja detection).

---

## Feature summary

| ID | Feature | Notes |
|----|---------|-------|
| F1 | Auto-confirm BoP bind popups | `CONFIRM_LOOT_ROLL` / `LOOT_BIND_CONFIRM` |
| F2 | Hide Blizzard roll frames | Superseded by the log window |
| F3 | Smart auto-greed | Two modes: wrong-armor-type, or "anything I can't use" |
| F4 | Show who rolled Need | Class-coloured tokens, ninja detection |
| F5 | Loot-log window | Roll/try-on from it; auto-open/close; per-character; `/reload`-safe |
| F6 | Settings panel + minimap button | Sliders, mode radios, greed toggles |
| F7 | Pawn integration | Upgrade % vs equipped, under the icon (optional) |

All auto behaviour is gated by **scope** (default: dungeons + raids only).

---

## Behaviour in detail

### F1 — Auto-confirm binding
When you roll Need/Greed on a Bind-on-Pickup item, the client normally shows a
confirmation popup. The addon listens for:
- `CONFIRM_LOOT_ROLL(rollID, rollType)` → calls `ConfirmLootRoll(rollID, rollType)`
  and hides the `CONFIRM_LOOT_ROLL` static popup.
- `LOOT_BIND_CONFIRM(slot)` → calls `ConfirmLootSlot(slot)` and hides the
  `LOOT_BIND` popup.

Only fires inside the configured scope, so world/other rolls are untouched.

### F3 — Smart auto-greed
On `START_LOOT_ROLL(rollID)` the addon reads
`GetLootRollItemInfo(rollID)` →
`texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, …`
and the item link via `GetLootRollItemLink(rollID)`, then decides an action:

- **Resources** (if "auto-greed materials" is enabled): items of class Gem (3),
  Reagent (5) or Trade Goods (7) are greeded.
- **Mode "armor"** (default): greeds **body armour** whose armour subclass isn't
  your class's type for your level (see the table below). Everything else is left
  for a manual decision.
- **Mode "cantuse"**: greeds anything the client says you can't equip/use
  (`canNeed == false`).
- In **"armor"** mode, weapons the character can't equip (`canNeed == false`) are
  also greeded.
- Optional blanket toggles: **all green (uncommon) items**, and drops for a slot
  where you already wear an **heirloom** (checked via `GetInventoryItemQuality`,
  quality 7). Both greed regardless of mode.
- Enchanters may choose **Disenchant instead of Greed** for the greeded items.
- Items you *can* use are left alone (the window opens so you decide), unless
  `fittingBehavior = "need"` is set, which auto-Needs them.

Armour type is read from `GetItemInfo(link)` returns **classID (#12)** and
**subclassID (#13)** plus **equipLoc (#9)** — non-localised, so it is locale-safe.
If the item isn't cached yet the addon does nothing (never risks a wrong roll).

Preferred armour subclass (threshold: level 40):

| Classes | < 40 | ≥ 40 |
|---|---|---|
| Warrior, Paladin, Death Knight | Mail | Plate |
| Hunter, Shaman | Leather | Mail |
| Rogue, Druid, Monk | Leather | Leather |
| Mage, Priest, Warlock | Cloth | Cloth |

Only "body" slots are subject to the armour-type rule (head, shoulder, chest,
wrist, hands, waist, legs, feet). Cloaks, rings, necks, trinkets, weapons and
shields are treated as usable and left for a manual decision.

### F4 — Who rolled Need
Uses the MoP **Loot History** system (`C_LootHistory`):
- `C_LootHistory.GetItem(idx)` → `rollID, itemLink, numPlayers, isDone, winnerIdx, …`
- `C_LootHistory.GetPlayerInfo(idx, p)` → `name, class, rollType, roll, isWinner, isMe`
- Events `LOOT_HISTORY_FULL_UPDATE`, `LOOT_HISTORY_ROLL_CHANGED`,
  `LOOT_HISTORY_ROLL_COMPLETE` drive live updates.

Roll types: `0 = Pass, 1 = Need, 2 = Greed, 3 = Disenchant`.

Each player who has chosen is drawn as a class-coloured circle containing their
choice icon (dice/coin/pass/DE), with the first four letters of their name below
and a crown over the winner. Your own token is labelled **You**. Up to 5 tokens
are shown (raids usually use different loot rules anyway).

### F5 — Loot-log window
The window replaces Blizzard's roll frames. For each recent drop it shows the
item icon, name (quality-coloured), and either:
- **roll buttons** (Need / Greed / Pass, plus Disenchant when possible) if the
  item still needs your decision — the icon **pulses** to draw attention; or
- **class-circle tokens** (F4) once you've rolled or the roll has ended.

Ordering: items still awaiting a roll are pinned to the top; once you roll, the
item drops below the remaining pending ones. The viewport grows so every pending
roll is visible; the rest of the history is reachable with the mouse wheel or the
thin scrollbar. The window is movable, closable, and its state and contents
persist across `/reload` (see SavedVariables).

Blizzard's frames are hidden while the addon is enabled; on `/reload` during a
live roll the entries are re-armed by probing `GetLootRollTimeLeft(rollID)` (the
roll is still valid server-side) so you can still roll from the window.

Extras: **Ctrl+Right-click** an item icon opens the Dressing Room
(`DressUpItemLink`). If the window is closed, a drop that needs a roll
**auto-opens** it, and it **auto-closes** once nothing is pending (windows opened
manually stay open). History is **per-character** (see SavedVariables).

### F7 — Pawn integration (optional)
When Pawn is loaded, a green upgrade arrow is drawn on the item icon and the
upgrade percentage versus your currently equipped item is shown under it. It uses
`PawnGetItemData(link)` + `PawnIsItemAnUpgrade(item)` and picks the entry for the
character's **active** class/spec scale (`PawnFindScaleForSpec`), falling back to
the biggest visible-scale % and then to an item-level delta. Readiness is gated on
`PawnIsReady()` (Pawn's `PawnIsInitialized` is a local); the hidden-tooltip scan is
often empty right after a drop, so results are retried for a couple of seconds.

With **"Never auto-greed a Pawn upgrade"** on (default), the auto-roll dispatcher
(`DecideAndApply`) waits for Pawn before greeding: if the item is an upgrade it is
left for a manual roll; otherwise it greeds as usual. Everything is guarded so a
missing Pawn is a no-op. `## OptionalDeps: Pawn` ensures load order.

### F6 — Settings + minimap button
- **Minimap button** (dice icon): left-click toggles the window, right-click opens
  settings; draggable around the minimap (angle saved).
- **Settings panel** (Settings canvas, `/bdl config`):
  - rows shown (1–5), history size (10–100);
  - auto-greed mode radios ("can't equip/use" vs "wrong armor type");
  - checkboxes: auto-greed materials, all greens, heirloom-slot drops;
  - show Pawn upgrade %; never auto-greed a Pawn upgrade;
  - enchanters: disenchant instead of greed.

Panel construction is wrapped in `pcall` so a template mismatch can't break load.

---

## Architecture

Single file, `BetterDungeonLoot.lua`, organised into sections:

1. **SavedVariables / defaults** — `defaults` table + recursive `ApplyDefaults`.
2. **Scope** — `InScope()` via `IsInInstance()`.
3. **F1** — bind-confirm handlers.
4. **F3** — armour tables, resource/heirloom checks, `DecideRoll` (pure decision).
5. **F4 helpers** — `HistoryPlayersForRoll`, name/UTF-8 helpers.
6. **F7 helpers** — `PawnUpgradeFor` / `PawnUpgradeCheck` (Pawn integration).
7. **F5** — the log window: row pool, tokens, buttons, pulse glow, upgrade badge, scroll.
8. **F6** — options panel + minimap button; test mode (`/bdl test`).
9. **Auto-roll dispatch** — `DecideAndApply` (defers greed for the Pawn upgrade check).
10. **Event dispatch** — one frame routing all events.
11. **Slash commands** — `/bdl`.

### Data model
`log` is an array of entries (newest first), bound to
`BetterDungeonLootCharDB.log` (per-character) so it persists. Each entry:

```
{ rollID, link, name, texture, quality, bop,
  canNeed, canGreed, canDE,
  action,        -- "greed" | "need" | "de" | "leave" (what the addon did)
  myRoll,        -- 1/2/3 if you (or auto) rolled
  auto,          -- true if the addon rolled it automatically
  active,        -- roll still in progress
  players,       -- list of { name, class, rollType, isWinner, isMe }
  pawnText, pawnArrow, pawnDone,  -- cached Pawn upgrade result
  test }         -- true for /bdl test sample rows
```

Display order and the visible viewport are computed each `UpdateLog()`:
pending (active & not yet rolled) first, then everything else; the viewport is
`max(rowCount, pendingCount)` capped at the row-frame pool size; `scrollOffset`
selects the window into the full history.

### SavedVariables
- **`BetterDungeonLootDB`** (account-wide) — settings:
  `enabled, autoConfirmBind, autoRoll, fittingBehavior, enchanterDisenchant,
  autoRollMode, autoGreedResources, autoGreedGreens, autoGreedHeirloomSlot,
  showNeeders, showPawnUpgrade, hideBlizzardRoll, logShown, logPoint, rowCount,
  storageMax, minimapAngle, scope`.
- **`BetterDungeonLootCharDB`** (per-character) — `log` (the roll history).

`dbVersion` / `DB_VERSION` is present for migrations (v2 moved the history from the
account DB to a per-character DB).

---

## Slash commands
- `/bdl` — help
- `/bdl status` — current settings
- `/bdl config` — open the settings panel
- `/bdl log` — show/hide the window
- `/bdl test` — fill the window with sample rows (preview the layout)
- `/bdl autoroll` — toggle auto-greed
- `/bdl fitting` — leave ↔ auto-need for usable items
- `/bdl needers` — toggle the Need tokens
- `/bdl hideblizz` — toggle hiding Blizzard's roll frames
- `/bdl on | off` — enable/disable the addon

---

## MoP Classic (5.5.4) API notes
- `GetLootRollItemInfo`, `GetLootRollItemLink`, `GetLootRollTimeLeft`,
  `RollOnLoot`, `ConfirmLootRoll`, `ConfirmLootSlot` are **global** functions.
- `C_LootHistory` exists and reports each player's choice live via
  `LOOT_HISTORY_ROLL_CHANGED`.
- `GroupLootContainer` / `GroupLootFrame1..N` exist; hidden via a persistent
  `Show` hook (Blizzard re-shows on updates).
- `GetItemInfo` returns classID/subclassID at positions 12/13 (locale-safe).
- Class-coloured circles use `WHITE8X8` tinted + `CircleMaskScalable` (wrapped in
  `pcall`), the alert glow uses `SpellActivationOverlay\IconAlert`, and the
  Settings canvas API (`Settings.RegisterCanvasLayoutCategory`) is available.

## Known limitations
- Live Need detection depends on `C_LootHistory` updating during the roll.
- Class/spec weapon proficiency isn't modelled; "armor" mode greeds only weapons
  the client marks unusable (`canNeed == false`), the rest are left for you.
- Upgrade detection needs Pawn; without it there is no "is this an upgrade?" data,
  so the "never auto-greed an upgrade" rule is a no-op.
