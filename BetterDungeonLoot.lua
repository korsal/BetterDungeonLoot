-- BetterDungeonLoot
-- F1 auto-confirm BoP bind popups
-- F3 smart auto-greed of wrong-armor body pieces
-- F5 persistent loot-log window: last N rolls, roll from the window,
--    shows who rolled Need (F4), and hides Blizzard's roll frames (F2 obsolete).

local ADDON_NAME = ...
local interfaceVersion = tonumber((select(4, GetBuildInfo()))) or 0
local IS_FOREVER = interfaceVersion >= 16000 and interfaceVersion < 17000
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)

local PREFIX = "|cff33ff99BetterDungeonLoot|r: "
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

--------------------------------------------------------------------------------
-- SavedVariables / defaults
--------------------------------------------------------------------------------

local DB_VERSION = 2
local MAX_POOL = 12       -- row frames created (pool / hard cap on visible rows)
local STORAGE_MAX = 20    -- log entries kept (so scroll can reach older loot)

local defaults = {
    dbVersion = DB_VERSION,
    enabled = true,

    -- F1
    autoConfirmBind = true,

    -- F3
    autoRoll = true,
    fittingBehavior = "leave",   -- leave | need
    autoRollMode = "armor",      -- armor (wrong armor type) | cantuse (anything unusable) | pawn (greed non-upgrades)
    autoGreedResources = true,   -- greed gems / reagents / trade goods
    autoGreedGreens = true,      -- greed all uncommon (green) items
    autoGreedHeirloomSlot = true, -- greed drops for slots you fill with an heirloom

    -- F4
    showNeeders = true,

    -- F5
    hideBlizzardRoll = true,
    logShown = true,
    logPoint = { "CENTER", "CENTER", 320, -60 },
    rowCount = 2,                -- how many log rows to show (1..5)
    storageMax = 20,             -- how many entries kept in history (10..100)
    minimapAngle = 200,          -- minimap button position (degrees)
    dontGreedUpgrades = true,    -- never auto-greed an item Pawn calls an upgrade
    showTimerBar = true,         -- show a countdown bar on rolls still awaiting a decision

    scope = "instance",          -- party | instance (party+raid) | everywhere
}

local function ApplyDefaults(db, def)
    for k, v in pairs(def) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                ApplyDefaults(db[k], v)
            else
                db[k] = v
            end
        end
    end
end

local db  -- BetterDungeonLootDB after login
local log = {}  -- shared with the loot-history adapter below
local lastAutoRollReason
local startLootRollCount = 0

--------------------------------------------------------------------------------
-- Scope check
--------------------------------------------------------------------------------

local function InScope()
    if not db.enabled then return false end
    if db.scope == "everywhere" then return true end
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false end
    if db.scope == "party" then
        return instanceType == "party"
    end
    return instanceType == "party" or instanceType == "raid"
end

--------------------------------------------------------------------------------
-- F1: auto-confirm BoP bind popups
--------------------------------------------------------------------------------

local function OnConfirmLootRoll(rollID, rollType)
    if not db.autoConfirmBind or not InScope() then return end
    ConfirmLootRoll(rollID, rollType)
    StaticPopup_Hide("CONFIRM_LOOT_ROLL")
end

local function OnLootBindConfirm(slot)
    if not db.autoConfirmBind or not InScope() then return end
    ConfirmLootSlot(slot)
    StaticPopup_Hide("LOOT_BIND")
end

--------------------------------------------------------------------------------
-- F3: smart auto-greed for body armor that doesn't fit your class
-- GetLootRollItemInfo -> texture, name, count, quality, bindOnPickUp,
--                        canNeed, canGreed, canDisenchant, ...
--------------------------------------------------------------------------------

local ITEM_CLASS_ARMOR = 4
local ITEM_CLASS_WEAPON = 2
local ARMOR_CLOTH, ARMOR_LEATHER, ARMOR_MAIL, ARMOR_PLATE = 1, 2, 3, 4

local BODY_ARMOR_SLOTS = {
    INVTYPE_HEAD = true, INVTYPE_SHOULDER = true, INVTYPE_CHEST = true,
    INVTYPE_ROBE = true, INVTYPE_WAIST = true, INVTYPE_LEGS = true,
    INVTYPE_FEET = true, INVTYPE_WRIST = true, INVTYPE_HAND = true,
}

local function PreferredArmorSubclass()
    local _, class = UnitClass("player")
    local level = UnitLevel("player")
    if class == "WARRIOR" or class == "PALADIN" or class == "DEATHKNIGHT" then
        return level >= 40 and ARMOR_PLATE or ARMOR_MAIL
    elseif class == "HUNTER" or class == "SHAMAN" then
        return level >= 40 and ARMOR_MAIL or ARMOR_LEATHER
    elseif class == "ROGUE" or class == "DRUID" or class == "MONK" then
        return ARMOR_LEATHER
    elseif class == "MAGE" or class == "PRIEST" or class == "WARLOCK" then
        return ARMOR_CLOTH
    end
    return nil
end

-- "greed" for items the chosen mode decides against; "need" if configured to
-- auto-need fitting items; otherwise "leave" (let the player decide).
-- equip location -> character inventory slot id(s), for the heirloom-slot check
local EQUIPLOC_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_HOLDABLE = { 17 }, INVTYPE_SHIELD = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}
local HEIRLOOM_QUALITY = 7

-- hidden tooltip for reading an item link's text lines (see porting notes)
local bdlScanTip
local function ItemTooltipLines(link)
    if not bdlScanTip then
        bdlScanTip = CreateFrame("GameTooltip", "BDLScanTooltip", nil, "GameTooltipTemplate")
    end
    bdlScanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    bdlScanTip:ClearLines()
    local ok = pcall(function() bdlScanTip:SetHyperlink(link) end)
    local lines = {}
    if ok then
        for i = 1, bdlScanTip:NumLines() do
            local fs = _G["BDLScanTooltipTextLeft" .. i]
            lines[#lines + 1] = (fs and fs:GetText()) or ""
        end
    end
    return lines
end

-- Heirloom scaling cap. Heirloom tooltips carry a line like
-- "Requires level 1 to 85 (53)": 85 is the level this heirloom scales up to and
-- (53) is the level it is currently scaled to (= min(playerLevel, cap)). We read
-- the cap from that "<cap> (<scaledLevel>)" shape, validated against the player's
-- level, so it stays locale-independent (no reliance on the "Requires level" text).
-- Cached per itemID (a heirloom's cap never changes). Returns a number or nil.
local heirloomCapCache = {}
local function HeirloomCap(link)
    local itemID = tonumber(link:match("item:(%d+)"))
    if itemID and heirloomCapCache[itemID] then return heirloomCapCache[itemID] end
    local plvl = UnitLevel("player") or 0
    local cap
    for _, t in ipairs(ItemTooltipLines(link)) do
        for c, scaled in t:gmatch("(%d+)%s*%((%d+)%)") do
            c, scaled = tonumber(c), tonumber(scaled)
            if c and scaled and c <= 200 and scaled == math.min(plvl, c) then
                cap = c
                break
            end
        end
        if cap then break end
    end
    if itemID and cap then heirloomCapCache[itemID] = cap end
    return cap
end

-- true only when the slot holds an heirloom that is STILL scaling at the player's
-- level (level <= cap). A capped heirloom (level past its cap) no longer helps, so
-- it's treated as "no heirloom" here — real upgrades for that slot stop being
-- greeded. If the cap can't be parsed we keep the old behavior (treat as working).
local function SlotHasHeirloom(equipLoc)
    local slots = EQUIPLOC_SLOTS[equipLoc]
    if not slots then return false end
    local plvl = UnitLevel("player") or 0
    for _, slot in ipairs(slots) do
        local link = GetInventoryItemLink("player", slot)
        local q = GetInventoryItemQuality("player", slot)
        if not q and link then q = select(3, GetItemInfo(link)) end
        if q == HEIRLOOM_QUALITY and link then
            local cap = HeirloomCap(link)
            if not cap or plvl <= cap then return true end
        end
    end
    return false
end

-- Gem (3), Reagent (5), Trade Goods (7) — the "materials" bucket
local RESOURCE_CLASSES = { [3] = true, [5] = true, [7] = true }

-- Recipe item subclasses map to profession skill lines. A missing profession
-- makes the recipe safe to Greed; an unknown subclass stays a manual choice.
local RECIPE_PROFESSION_SKILLS = {
    [1] = 165,  -- Leatherworking
    [2] = 197,  -- Tailoring
    [3] = 202,  -- Engineering
    [4] = 164,  -- Blacksmithing
    [5] = 185,  -- Cooking
    [6] = 171,  -- Alchemy
    [7] = 129,  -- First Aid
    [8] = 333,  -- Enchanting
    [9] = 356,  -- Fishing
    [10] = 755, -- Jewelcrafting
    [11] = 773, -- Inscription
}

local function MissingRecipeProfession(subclassID)
    local required = RECIPE_PROFESSION_SKILLS[subclassID]
    if not required or not (GetProfessions and GetProfessionInfo) then return nil end
    local ok, prof1, prof2, archaeology, fishing, cooking, firstAid = pcall(GetProfessions)
    if not ok then return nil end
    -- GetProfessions has fixed slots and may leave holes; ipairs would stop early.
    local slots = { prof1, prof2, archaeology, fishing, cooking, firstAid }
    for slot = 1, 6 do
        local index = slots[slot]
        if index then
            local infoOK, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, index)
            if not infoOK or not skillLine then return nil end
            if skillLine == required then return false end
        end
    end
    return true
end

local function DecideRoll(rollID, canNeed, quality, link)
    -- The roll's quality is available before the item cache has filled in its
    -- link on some clients.  A green item needs no class/subclass lookup.
    if db.autoGreedGreens and quality == 2 then
        return "greed"
    end
    link = link or (GetLootRollItemLink and GetLootRollItemLink(rollID))
    if not link then return "retry" end
    local _, _, _, _, _, _, _, _, equipLoc, _, _, classID, subclassID = GetItemInfo(link)
    if not classID then return "retry" end

    -- gems / reagents / crafting materials
    if db.autoGreedResources and classID and RESOURCE_CLASSES[classID] then
        return "greed"
    end

    if classID == 9 and MissingRecipeProfession(subclassID) then
        return "greed", true
    end

    -- slot is filled by a still-scaling heirloom: keep the heirloom no matter what
    -- Pawn says (second return = "final", bypasses the Pawn gate). SlotHasHeirloom
    -- returns false once the heirloom is past its scaling cap, so a capped heirloom
    -- no longer forces a greed on genuine upgrades.
    if db.autoGreedHeirloomSlot and equipLoc and SlotHasHeirloom(equipLoc) then
        return "greed", true
    end

    if db.autoRollMode == "pawn" then
        -- greed everything that isn't a Pawn upgrade; DecideAndApply's Pawn check
        -- holds actual upgrades back for a manual roll. If Pawn isn't available
        -- (not loaded / not ready) we can't judge upgrades, so fall back to only
        -- greeding what the character can't use and never risk greeding a keeper.
        local pawnOK = PawnIsReady and PawnIsReady() and PawnGetItemData and PawnIsItemAnUpgrade
        if pawnOK then
            return "greed"
        elseif not canNeed then
            return "greed"
        end
    elseif db.autoRollMode == "cantuse" then
        -- greed anything this character can't equip/use at all
        if not canNeed then
            return "greed"
        end
    else
        -- "armor": greed body armor that isn't your class's armor type,
        -- and weapons the character can't equip
        if not classID then return "leave" end  -- not cached: never risk a wrong roll
        if classID == ITEM_CLASS_ARMOR and BODY_ARMOR_SLOTS[equipLoc] then
            local pref = PreferredArmorSubclass()
            if pref and subclassID and subclassID ~= pref then
                return "greed"
            end
        elseif classID == ITEM_CLASS_WEAPON and not canNeed then
            return "greed"
        end
    end

    if db.fittingBehavior == "need" and canNeed then return "need" end
    return "leave"
end


--------------------------------------------------------------------------------
-- F4 helpers: read each player's roll from C_LootHistory. Classic uses
-- GetItem/GetPlayerInfo; Forever uses encounter drops and different roll states.
--------------------------------------------------------------------------------

local function ShortName(name)
    if Ambiguate then return Ambiguate(name, "short") end
    return (name:gsub("%-.*", ""))
end

-- first up-to-n UTF-8 characters (byte-safe for Cyrillic names)
local function Utf8Sub(s, n)
    if not s then return "" end
    local i, count, len = 1, 0, #s
    while i <= len and count < n do
        local c = s:byte(i)
        local step = (c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1
        i = i + step
        count = count + 1
    end
    return s:sub(1, i - 1)
end

local function ItemSignature(link)
    if type(link) ~= "string" then return nil end
    return link:match("|H(item:[^|]+)|h") or link:match("(item:[^|]+)")
end

-- Forever does not expose a rollID -> history-drop mapping. Match by the full
-- item payload and the roll start time, without assigning one drop twice.
local function ForeverHistoryDropForRoll(e)
    if not e.link or not C_LootHistory.GetAllEncounterInfos then return nil end
    if e.historyEncounterID and e.historyLootListKey then
        local drop = C_LootHistory.GetSortedInfoForDrop(e.historyEncounterID, e.historyLootListKey)
        if drop then return drop end
    end
    if not e.historyTime or C_LootHistory.GetLootHistoryTime() - e.historyTime > 120 then return nil end

    local signature = ItemSignature(e.link)
    if not signature then return nil end
    local best, bestEncounter, bestDelta
    for _, encounter in ipairs(C_LootHistory.GetAllEncounterInfos() or {}) do
        for _, drop in ipairs(C_LootHistory.GetSortedDropsForEncounter(encounter.encounterID) or {}) do
            if ItemSignature(drop.itemHyperlink) == signature and type(drop.startTime) == "number" then
                local claimed = false
                for _, other in ipairs(log) do
                    if other ~= e and other.historyEncounterID == encounter.encounterID
                        and other.historyLootListKey == drop.lootListKey then
                        claimed = true
                        break
                    end
                end
                local delta = math.abs(drop.startTime - e.historyTime)
                if not claimed and delta <= 120 and (not bestDelta or delta < bestDelta) then
                    best, bestEncounter, bestDelta = drop, encounter.encounterID, delta
                end
            end
        end
    end
    if best then
        e.historyEncounterID = bestEncounter
        e.historyLootListKey = best.lootListKey
    end
    return best
end

local function ForeverRollType(state)
    if state == 0 or state == 1 then return 1 end  -- main/off-spec Need
    if state == 2 then return 4 end                -- Transmog
    if state == 3 then return 2 end                -- Greed
    if state == 5 then return 0 end                -- Pass
    return nil                                     -- NoRoll
end

-- list of {name(short), class, rollType, isWinner} for players who have chosen
local function HistoryPlayersForRoll(e)
    if not C_LootHistory then return nil end
    if IS_FOREVER then
        local drop = ForeverHistoryDropForRoll(e)
        if not drop then return nil end
        local players = {}
        for _, roll in ipairs(drop.rollInfos or {}) do
            local rollType = ForeverRollType(roll.state)
            if rollType ~= nil then
                players[#players + 1] = {
                    name = ShortName(roll.playerName), class = roll.playerClass,
                    rollType = rollType, isWinner = roll.isWinner, isMe = roll.isSelf,
                }
            end
        end
        return players, (drop.winner or drop.allPassed) and true or false
    end

    local n = C_LootHistory.GetNumItems and C_LootHistory.GetNumItems() or 0
    for idx = 1, n do
        local id = C_LootHistory.GetItem(idx)
        if id == e.rollID and C_LootHistory.GetPlayerInfo then
            local players
            for p = 1, 40 do
                local name, class, rollType, _, isWinner, isMe = C_LootHistory.GetPlayerInfo(idx, p)
                if not name then break end
                if rollType ~= nil then
                    players = players or {}
                    players[#players + 1] = {
                        name = ShortName(name), class = class,
                        rollType = rollType, isWinner = isWinner, isMe = isMe,
                    }
                end
            end
            return players
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- F5: persistent loot-log window
--------------------------------------------------------------------------------

local logFrame
local rows = {}
-- log[1] = newest
local scrollOffset = 0   -- how many newest entries are scrolled past
local autoOpened = false -- window was popped open by a roll (auto-close when done)
local dismissedRolls = setmetatable({}, { __mode = "k" }) -- X dismisses only the current rolls
local UpdateLog          -- forward declaration

local function IsLogShown()
    return logFrame and logFrame:IsShown()
end

local ROLL_TYPE_NAME = { [0] = "Pass", [1] = "Need", [2] = "Greed", [3] = "DE", [4] = "Transmog" }

local function QualityColoredName(e)
    local q = ITEM_QUALITY_COLORS[e.quality or 1]
    local hex = (q and q.hex) or "|cffffffff"
    return hex .. (e.name or "?") .. "|r"
end

local function RollFromRow(row, rtype)
    local e = row.entry
    if not e or not e.active then return end
    if not e.test then RollOnLoot(e.rollID, rtype) end
    e.myRoll = rtype
    e.auto = false
    UpdateLog()
end

local ROLL_BTN_BASE = {
    [1] = "Interface\\Buttons\\UI-GroupLoot-Dice",
    [2] = "Interface\\Buttons\\UI-GroupLoot-Coin",
    [0] = "Interface\\Buttons\\UI-GroupLoot-Pass",
    [3] = "Interface\\Buttons\\UI-GroupLoot-DE",
}
local ROLL_TYPE_ICON = {
    [0] = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
    [1] = "Interface\\Buttons\\UI-GroupLoot-Dice-Up",
    [2] = "Interface\\Buttons\\UI-GroupLoot-Coin-Up",
    [3] = "Interface\\Buttons\\UI-GroupLoot-DE-Up",
}
local FOREVER_ROLL_ATLAS = {
    [0] = "lootroll-toast-icon-pass-up",
    [1] = "lootroll-toast-icon-need-up",
    [2] = "lootroll-toast-icon-greed-up",
    [4] = "lootroll-toast-icon-transmog-up",
}
local CROWN_TEX = "Interface\\GroupFrame\\UI-Group-LeaderIcon"
local CIRCLE_MASK = "Interface\\Masks\\CircleMaskScalable"

-- the Blizzard roll icons sit high inside their texture; nudge them down so they
-- look centered (buttons at 22px, circle tokens at 16px need a smaller nudge)
local ROLL_ICON_OFFSET = { [0] = 0, [1] = -1, [2] = -3, [3] = 0, [4] = 0 }
local ROLL_ICON_OFFSET_TOKEN = { [0] = 0, [1] = -1, [2] = -3, [3] = 0, [4] = 0 }

local function MakeRollIconButton(row, rtype)
    local b = CreateFrame("Button", nil, row, "BackdropTemplate")
    b:SetSize(32, 32)
    b:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    b:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
    b:SetBackdropBorderColor(0.55, 0.55, 0.6, 0.9)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(22, 22)
    b.icon:SetPoint("CENTER", b, "CENTER", 0, ROLL_ICON_OFFSET[rtype] or 0)
    if IS_FOREVER then
        b.icon:SetAtlas(FOREVER_ROLL_ATLAS[rtype])
    else
        b.icon:SetTexture(ROLL_BTN_BASE[rtype] .. "-Up")
    end

    -- neutral additive glow on hover (the roll "-Highlight" art includes the icon
    -- itself, which drew a duplicated texture on top)
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    local hl = b:GetHighlightTexture()
    hl:SetVertexColor(1, 1, 1, 0.2)
    hl:SetBlendMode("ADD")

    b:SetScript("OnClick", function() RollFromRow(row, rtype) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ROLL_TYPE_NAME[rtype] or "")
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- a class-colored circle with the chosen roll icon inside, name below, crown on winner
local function CreateToken(row)
    local t = CreateFrame("Frame", nil, row)
    t:SetSize(36, 52)

    t.disc = t:CreateTexture(nil, "BACKGROUND")
    t.disc:SetTexture("Interface\\Buttons\\WHITE8X8")
    t.disc:SetSize(30, 30)
    t.disc:SetPoint("TOP", t, "TOP", 0, 0)
    pcall(function()
        t.mask = t:CreateMaskTexture()
        t.mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        t.mask:SetAllPoints(t.disc)
        t.disc:AddMaskTexture(t.mask)
    end)

    -- black round background so the roll icon reads on top of the class color
    t.inner = t:CreateTexture(nil, "BORDER")
    t.inner:SetTexture("Interface\\Buttons\\WHITE8X8")
    t.inner:SetVertexColor(0, 0, 0)
    t.inner:SetSize(26, 26)
    t.inner:SetPoint("CENTER", t.disc, "CENTER", 0, 0)
    pcall(function()
        local m = t:CreateMaskTexture()
        m:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(t.inner)
        t.inner:AddMaskTexture(m)
    end)

    t.rollIcon = t:CreateTexture(nil, "ARTWORK")
    t.rollIcon:SetSize(22, 22)
    t.rollIcon:SetPoint("CENTER", t.disc, "CENTER", 0, 0)

    t.crown = t:CreateTexture(nil, "OVERLAY")
    t.crown:SetTexture(CROWN_TEX)
    t.crown:SetSize(16, 16)
    t.crown:SetPoint("CENTER", t.disc, "TOP", 0, 2)
    t.crown:Hide()

    t.name = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.name:SetPoint("TOP", t.disc, "BOTTOM", 0, -2)
    t.name:SetWidth(30)
    t.name:SetWordWrap(false)
    t.name:SetJustifyH("CENTER")

    return t
end

-- Pawn integration: the scale for the player's current class + spec
local function PawnActiveScaleName()
    if not PawnFindScaleForSpec then return nil end
    local _, _, classID = UnitClass("player")
    local specID
    if GetSpecialization then
        local idx = GetSpecialization()
        if idx and GetSpecializationInfo then specID = GetSpecializationInfo(idx) end
    end
    return PawnFindScaleForSpec(classID, specID)
end

-- Pawn present at all? (installed + enabled → its API globals exist). The upgrade
-- % display is shown automatically whenever this is true; no separate toggle.
local function PawnLoaded()
    return (PawnGetItemData and PawnIsItemAnUpgrade) and true or false
end

-- returns computed(bool), text, r, g, b  (computed=false means "item not cached, retry later")
local function PawnUpgradeFor(link)
    if not (PawnIsReady and PawnIsReady() and PawnGetItemData and PawnIsItemAnUpgrade) then
        return true, nil
    end
    if not link then return true, nil end
    local ok, item = pcall(PawnGetItemData, link)
    if not ok then return true, nil end
    if not item or not item.Link then return false, nil end  -- not cached yet
    local ok2, up, ilvl = pcall(PawnIsItemAnUpgrade, item)
    if not ok2 then return true, nil end

    if up and #up > 0 then
        -- prefer the active spec's scale; otherwise fall back to the biggest upgrade
        local active = PawnActiveScaleName()
        local chosen
        for _, u in ipairs(up) do
            if u.ScaleName == active then chosen = u break end
        end
        if not chosen then
            chosen = up[1]
            for _, u in ipairs(up) do
                if (u.PercentUpgrade or 0) > (chosen.PercentUpgrade or 0) then chosen = u end
            end
        end
        return true, ("+%d%%"):format(math.floor((chosen.PercentUpgrade or 0) * 100 + 0.5)), 0, 1, 0, true
    end
    if ilvl and ilvl > 0 then
        return true, ("ilvl +%d"):format(ilvl), 0.6, 0.8, 1, false
    end
    return true, nil
end

-- for the "don't auto-greed upgrades" rule: ready(item loaded?), isUpgrade
local function PawnUpgradeCheck(link)
    if not PawnLoaded() then
        return true, false
    end
    if not (link and PawnIsReady and PawnIsReady()) then return false, false end
    local ok, item = pcall(PawnGetItemData, link)
    if not ok then return true, false end
    if not item or not item.Link then return false, false end  -- not loaded yet
    local ok2, up = pcall(PawnIsItemAnUpgrade, item)
    if not ok2 then return true, false end
    return true, (up ~= nil and #up > 0)
end

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(288, 56)

    row.icon = CreateFrame("Button", nil, row)
    row.icon:SetSize(38, 38)
    row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
    row.icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.icon.tex = row.icon:CreateTexture(nil, "ARTWORK")
    row.icon.tex:SetAllPoints()
    row.icon:SetScript("OnEnter", function(self)
        if not self.link then return end
        -- anchor beside the whole window on the side with free space, so the
        -- tooltip (and equipped-item comparisons) never cover the log
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        local cx = logFrame:GetCenter()
        if cx and cx > (UIParent:GetWidth() / 2) then
            GameTooltip:SetPoint("TOPRIGHT", logFrame, "TOPLEFT", -6, 0)
        else
            GameTooltip:SetPoint("TOPLEFT", logFrame, "TOPRIGHT", 6, 0)
        end
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:AddLine("Ctrl+Right-click: try on", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    row.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.icon:SetScript("OnClick", function(self, button)
        if self.link and button == "RightButton" and IsControlKeyDown() then
            if DressUpItemLink then
                DressUpItemLink(self.link)
            elseif DressUpLink then
                DressUpLink(self.link)
            end
        end
    end)

    -- pulsing alert glow around the icon while the item still needs a roll
    -- (same technique as BurstCooldownTracker's "active" glow)
    row.glow = row:CreateTexture(nil, "OVERLAY", nil, 1)
    row.glow:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    row.glow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    row.glow:SetBlendMode("ADD")
    row.glow:SetVertexColor(1, 0.9, 0.3)
    row.glow:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -8, 8)
    row.glow:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 8, -8)
    row.glow:Hide()

    local ag = row.glow:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local a1 = ag:CreateAnimation("Alpha")
    a1:SetFromAlpha(1); a1:SetToAlpha(0.3); a1:SetDuration(0.5); a1:SetOrder(1)
    local a2 = ag:CreateAnimation("Alpha")
    a2:SetFromAlpha(0.3); a2:SetToAlpha(1); a2:SetDuration(0.5); a2:SetOrder(2)
    row.glowAnim = ag

    -- Pawn upgrade arrow (on the icon) + % under it
    row.upgradeArrow = row.icon:CreateTexture(nil, "OVERLAY")
    row.upgradeArrow:SetTexture("Interface\\AddOns\\Pawn\\Textures\\UpgradeArrow")
    row.upgradeArrow:SetSize(18, 18)
    row.upgradeArrow:SetPoint("TOPLEFT", row.icon, "TOPLEFT", 0, 1)
    row.upgradeArrow:Hide()

    row.upgrade = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.upgrade:SetPoint("TOP", row.icon, "BOTTOM", 0, -4)
    row.upgrade:SetWidth(46)
    row.upgrade:SetJustifyH("CENTER")
    row.upgrade:SetWordWrap(false)
    row.upgrade:SetShadowColor(0, 0, 0, 1)
    row.upgrade:SetShadowOffset(1, -1)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 44, -2)
    row.name:SetWidth(130)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.timer = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.timer:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)

    -- countdown bar along the bottom of the row while the item awaits a decision
    row.timerBar = CreateFrame("StatusBar", nil, row)
    row.timerBar:SetPoint("TOPLEFT", row, "TOPLEFT", 44, -54)
    row.timerBar:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -54)
    row.timerBar:SetHeight(9)
    row.timerBar:SetMinMaxValues(0, 1)
    row.timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.timerBar.bg = row.timerBar:CreateTexture(nil, "BACKGROUND")
    row.timerBar.bg:SetAllPoints()
    row.timerBar.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.timerBar.bg:SetVertexColor(0, 0, 0, 0.5)
    row.timerBar:Hide()

    -- separate right-side column so the tag never gets clipped with the name
    row.autoTag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.autoTag:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
    row.autoTag:SetText("Auto")

    -- roll buttons (each in its own rounded frame; shown when the item needs a decision)
    row.needBtn  = MakeRollIconButton(row, 1)
    row.greedBtn = MakeRollIconButton(row, 2)
    row.passBtn  = MakeRollIconButton(row, 0)
    row.extraBtn = MakeRollIconButton(row, IS_FOREVER and 4 or 3)
    row.needBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 44, -20)
    row.greedBtn:SetPoint("LEFT", row.needBtn, "RIGHT", 6, 0)
    row.passBtn:SetPoint("LEFT", row.greedBtn, "RIGHT", 6, 0)
    row.extraBtn:SetPoint("LEFT", row.passBtn, "RIGHT", 6, 0)

    -- class-circle tokens (row shown once rolled / finished); cap at 5 (raids)
    row.tokens = {}
    for i = 1, 5 do row.tokens[i] = CreateToken(row) end

    return row
end

local function BindTokens(row, e)
    local players = e.players
    if (not players or #players == 0) and e.myRoll then
        local _, myClass = UnitClass("player")
        players = { { name = "You", class = myClass, rollType = e.myRoll, isWinner = false, isMe = true } }
    end
    players = players or {}

    local x = 44
    for i, tok in ipairs(row.tokens) do
        local p = players[i]
        if p then
            tok:ClearAllPoints()
            tok:SetPoint("TOPLEFT", row, "TOPLEFT", x, -26)
            local col = p.class and RAID_CLASS_COLORS[p.class]
            local r, g, b = 0.6, 0.6, 0.6
            if col then r, g, b = col.r, col.g, col.b end
            tok.disc:SetVertexColor(r, g, b)
            if IS_FOREVER then
                tok.rollIcon:SetAtlas(FOREVER_ROLL_ATLAS[p.rollType])
            else
                tok.rollIcon:SetTexture(ROLL_TYPE_ICON[p.rollType])
            end
            tok.rollIcon:ClearAllPoints()
            tok.rollIcon:SetPoint("CENTER", tok.disc, "CENTER", 0, ROLL_ICON_OFFSET_TOKEN[p.rollType] or 0)
            tok.crown:SetShown(p.isWinner and true or false)
            tok.name:SetText(p.isMe and "You" or Utf8Sub(p.name, 4))
            tok.name:SetTextColor(r, g, b)
            tok:Show()
            x = x + 34
        else
            tok:Hide()
        end
    end
end

-- countdown bar: fraction of the roll time still left, colored by urgency.
-- Only shown while the item is still awaiting the player's decision.
local function UpdateTimerBar(row)
    local e = row.entry
    if not e or not db.showTimerBar or not (e.active and not e.myRoll) then
        row.timerBar:Hide()
        return
    end

    local frac
    if e.test then
        frac = e.fakeFrac or 1
    else
        local left = GetLootRollTimeLeft and GetLootRollTimeLeft(e.rollID)
        if not left or left <= 0 then row.timerBar:Hide(); return end
        -- rollTime (from START_LOOT_ROLL) is the total; missing after a /reload
        -- re-arm, so fall back to the largest remaining we've seen for this roll
        local maxMs = e.rollTime
        if not maxMs or maxMs <= 0 then
            e.rollTimeMax = math.max(e.rollTimeMax or 0, left)
            maxMs = e.rollTimeMax
        end
        frac = (maxMs and maxMs > 0) and math.min(1, left / maxMs) or 1
    end

    row.timerBar:SetValue(frac)
    if frac > 0.5 then
        row.timerBar:SetStatusBarColor(0.2, 0.8, 0.25)
    elseif frac > 0.25 then
        row.timerBar:SetStatusBarColor(0.95, 0.8, 0.2)
    else
        row.timerBar:SetStatusBarColor(0.9, 0.25, 0.2)
    end
    row.timerBar:Show()
end

local function BindRow(row, e)
    row.entry = e
    row.icon.tex:SetTexture(e.texture)
    row.icon.link = e.link
    row.name:SetText(QualityColoredName(e))

    if PawnLoaded() or e.test then
        if not e.pawnDone then
            local _, txt, r, g, b, isUp = PawnUpgradeFor(e.link)
            local tries = e.pawnTries or 0
            if txt ~= nil or tries >= 5 then
                -- cache a real result, or give up: Pawn's hidden-tooltip scan is
                -- often empty right after a drop, so retry a few times first
                e.pawnDone = true
                e.pawnText, e.pawnR, e.pawnG, e.pawnB, e.pawnArrow = txt, r, g, b, isUp
            else
                e.pawnTries = tries + 1
                if C_Timer and C_Timer.After then
                    C_Timer.After(0.6, function()
                        if e and not e.pawnDone then UpdateLog() end
                    end)
                end
            end
        end
        row.upgrade:SetText(e.pawnText or "")
        if e.pawnText then row.upgrade:SetTextColor(e.pawnR or 1, e.pawnG or 1, e.pawnB or 1) end
        row.upgradeArrow:SetShown(e.pawnArrow and true or false)
    else
        row.upgrade:SetText("")
        row.upgradeArrow:Hide()
    end

    local isAuto = (e.auto and e.myRoll) and true or false
    row.autoTag:SetShown(isAuto)

    if e.active and not isAuto then
        if e.test then
            row.timer:SetText(e.fakeTimer or "")
        else
            local left = GetLootRollTimeLeft and GetLootRollTimeLeft(e.rollID)
            row.timer:SetText((left and left > 0) and (math.ceil(left / 1000) .. "s") or "")
        end
    else
        row.timer:SetText("")
    end

    local needRoll = e.active and not e.myRoll
    row.needBtn:SetShown(needRoll and (e.canNeed and true or false))
    row.greedBtn:SetShown(needRoll and (e.canGreed and true or false))
    row.passBtn:SetShown(needRoll)
    row.extraBtn:SetShown(needRoll and ((IS_FOREVER and e.canTransmog or e.canDE) and true or false))

    if needRoll then
        row.glow:Show()
        row.glowAnim:Play()
        for _, t in ipairs(row.tokens) do t:Hide() end
    else
        row.glowAnim:Stop()
        row.glow:Hide()
        BindTokens(row, e)
    end

    UpdateTimerBar(row)
end

local function CreateLogFrame()
    if logFrame then return end
    logFrame = CreateFrame("Frame", "BetterDungeonLootLog", UIParent, "BackdropTemplate")
    logFrame:SetSize(240, 80)
    logFrame:SetFrameStrata("DIALOG")
    logFrame:SetClampedToScreen(true)
    logFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    logFrame:SetBackdropColor(0, 0, 0, 0.85)
    logFrame:SetBackdropBorderColor(0.2, 1, 0.6, 1)

    logFrame:SetMovable(true)
    logFrame:EnableMouse(true)
    logFrame:RegisterForDrag("LeftButton")
    logFrame:SetScript("OnDragStart", logFrame.StartMoving)
    logFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.logPoint = { point, relPoint, x, y }
    end)

    local title = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", logFrame, "TOP", 0, -6)
    title:SetText("BetterDungeonLoot")
    logFrame.title = title

    local close = CreateFrame("Button", nil, logFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        autoOpened = false
        for _, e in ipairs(log) do
            if e.active and not e.myRoll then dismissedRolls[e] = true end
        end
        db.logShown = false
        logFrame:Hide()
    end)

    -- Auto-greed checkbox in the bottom-right corner
    local autoCB = CreateFrame("CheckButton", nil, logFrame, "UICheckButtonTemplate")
    autoCB:SetSize(22, 22)
    autoCB:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -6, 6)
    autoCB:SetChecked(db.autoRoll)
    autoCB:SetScript("OnClick", function(self)
        db.autoRoll = self:GetChecked() and true or false
        Print("auto-greed: " .. tostring(db.autoRoll))
    end)
    local autoLabel = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetText("Auto-greed")
    autoLabel:SetPoint("RIGHT", autoCB, "LEFT", -1, 0)
    logFrame.autoCB = autoCB

    logFrame.empty = logFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    logFrame.empty:SetPoint("TOP", logFrame, "TOP", 0, -30)
    logFrame.empty:SetText("No recent loot")

    for i = 1, MAX_POOL do
        rows[i] = CreateRow(logFrame, i)
    end

    -- mouse-wheel scrolling through older loot
    logFrame:EnableMouseWheel(true)
    logFrame:SetScript("OnMouseWheel", function(self, delta)
        local mo = self.maxOffset or 0
        local new = math.min(math.max(scrollOffset - delta, 0), mo)
        if new ~= scrollOffset then
            scrollOffset = new
            UpdateLog()
        end
    end)

    -- thin scrollbar on the right edge (only visible when there is history to scroll)
    local sb = CreateFrame("Slider", nil, logFrame)
    sb:SetOrientation("VERTICAL")
    sb:SetWidth(10)
    sb:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -4, -(28 + 4))
    sb:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -4, 24 + 4)

    sb.track = logFrame:CreateTexture(nil, "BACKGROUND")
    sb.track:SetTexture("Interface\\Buttons\\WHITE8X8")
    sb.track:SetVertexColor(0, 0, 0, 0.35)
    sb.track:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, 0)
    sb.track:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    sb.track:Hide()

    sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = sb:GetThumbTexture()
    thumb:SetSize(10, 30)
    thumb:SetVertexColor(0.55, 0.55, 0.6, 0.95)
    sb:SetValueStep(1)
    sb:SetObeyStepOnDrag(true)
    sb:SetScript("OnValueChanged", function(self, value)
        if logFrame._updatingSB then return end
        local v = math.floor(value + 0.5)
        if v ~= scrollOffset then
            scrollOffset = v
            UpdateLog()
        end
    end)
    sb:Hide()
    logFrame.scrollbar = sb

    local p = db.logPoint
    logFrame:ClearAllPoints()
    logFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])

    logFrame.elapsed = 0
    logFrame:SetScript("OnUpdate", function(self, e)
        self.elapsed = self.elapsed + e
        if self.elapsed < 0.2 then return end
        self.elapsed = 0
        local dirty = false
        for i = 1, MAX_POOL do
            local row = rows[i]
            local ent = row.entry
            if row:IsShown() and ent and ent.active and not ent.auto and not ent.test then
                local left = GetLootRollTimeLeft and GetLootRollTimeLeft(ent.rollID)
                if not left or left <= 0 then
                    ent.active = false
                    dirty = true
                else
                    row.timer:SetText(math.ceil(left / 1000) .. "s")
                    UpdateTimerBar(row)
                end
            end
        end
        if dirty then UpdateLog() end
    end)
end

function UpdateLog()
    if not logFrame then return end
    local titleH, pad, rowH, gap, footerH = 28, 6, 72, 3, 24

    -- display order: items still needing a roll first, then everything else,
    -- newest-first within each group (a rolled item drops below the pending ones)
    local pending, others = {}, {}
    for _, e in ipairs(log) do
        if e.active and not e.myRoll then
            pending[#pending + 1] = e
        else
            others[#others + 1] = e
        end
    end

    -- if the window only popped open for a roll, close it once nothing is pending
    if autoOpened and #pending == 0 then
        autoOpened = false
        db.logShown = false
        logFrame:Hide()
        return
    end

    local view = {}
    for _, e in ipairs(pending) do view[#view + 1] = e end
    for _, e in ipairs(others) do view[#view + 1] = e end
    local total = #view

    -- grow so all pending items are visible at the top
    local viewport = math.min(math.max(db.rowCount or 2, #pending), MAX_POOL)

    -- pin to the top while a roll is pending so it can never be scrolled away
    if #pending > 0 then scrollOffset = 0 end
    local maxOffset = math.max(0, total - viewport)
    scrollOffset = math.min(math.max(scrollOffset, 0), maxOffset)
    logFrame.maxOffset = maxOffset
    local rowRight = (maxOffset > 0) and -18 or -8   -- reserve space only when scrollbar shows

    for i = 1, MAX_POOL do
        local row = rows[i]
        local e = (i <= viewport) and view[i + scrollOffset] or nil
        if e then
            BindRow(row, e)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 8, -(titleH + (i - 1) * (rowH + gap)))
            row:SetPoint("RIGHT", logFrame, "RIGHT", rowRight, 0)
            row:Show()
        else
            row.entry = nil
            if row.glowAnim then row.glowAnim:Stop() end
            if row.glow then row.glow:Hide() end
            row:Hide()
        end
    end

    local shown = math.min(total, viewport)
    logFrame.empty:SetShown(shown == 0)
    local body = (shown > 0) and (shown * rowH + (shown - 1) * gap) or 22

    local sb = logFrame.scrollbar
    if sb then
        if maxOffset > 0 then
            local thumbH = math.max(16, math.floor(body * viewport / total))
            sb:GetThumbTexture():SetHeight(thumbH)
            logFrame._updatingSB = true
            sb:SetMinMaxValues(0, maxOffset)
            sb:SetValue(scrollOffset)
            logFrame._updatingSB = false
            sb.track:Show()
            sb:Show()
        else
            sb.track:Hide()
            sb:Hide()
        end
    end

    logFrame:SetHeight(titleH + pad + body + pad + footerH)
end

local function AddRoll(rollID, action, rollTime)
    local e = {
        rollID = rollID, quality = 1,
        action = action, active = true, players = nil, auto = (action ~= "leave"),
        rollTime = rollTime,
    }
    if action == "greed" then e.myRoll = 2
    elseif action == "need" then e.myRoll = 1
    elseif action == "de" then e.myRoll = 3 end

    for i = #log, 1, -1 do
        if log[i].rollID == rollID then table.remove(log, i) end
    end
    table.insert(log, 1, e)
    while #log > (db.storageMax or STORAGE_MAX) do table.remove(log) end
    scrollOffset = 0  -- jump to the top so the new item is visible

    -- Forever can fire START_LOOT_ROLL before all item data is ready. Keep the
    -- pending entry even if a client API fails so the player still gets a roll UI.
    local ok, texture, name, _, quality, bop, canNeed, canGreed, canDE,
        _, _, _, _, canTransmog = pcall(GetLootRollItemInfo, rollID)
    if ok then
        e.texture, e.name, e.quality, e.bop = texture, name, quality or 1, bop
        e.canNeed, e.canGreed, e.canDE, e.canTransmog = canNeed, canGreed, canDE, canTransmog
    end
    if GetLootRollItemLink then
        local linkOK, link = pcall(GetLootRollItemLink, rollID)
        if linkOK then e.link = link end
    end
    if IS_FOREVER and C_LootHistory and C_LootHistory.GetLootHistoryTime then
        local timeOK, historyTime = pcall(C_LootHistory.GetLootHistoryTime)
        if timeOK then e.historyTime = historyTime end
    end
    return e
end

local function RefreshPlayers()
    if not (db.showNeeders and C_LootHistory) then return end
    local found = false
    local historyNow = IS_FOREVER and C_LootHistory.GetLootHistoryTime()
    for _, e in ipairs(log) do
        if not IS_FOREVER or e.historyEncounterID
            or (e.historyTime and historyNow - e.historyTime <= 120) then
            local players, done = HistoryPlayersForRoll(e)
            if players then
                e.players = players
                if done then e.active = false end
                for _, p in ipairs(players) do
                    if p.isMe and e.myRoll == nil then e.myRoll = p.rollType end
                end
                found = true
            end
        end
    end
    if found then UpdateLog() end
end

-- After a /reload the restored entries are inactive; if a roll is still live
-- server-side, GetLootRollTimeLeft returns > 0, so re-arm it so you can still roll.
local function ReactivateLiveRolls()
    if not GetLootRollTimeLeft then return end
    local changed = false
    for _, e in ipairs(log) do
        if not e.active then
            local left = GetLootRollTimeLeft(e.rollID)
            if left and left > 0 then
                e.active = true
                changed = true
            end
        end
    end
    if changed then
        RefreshPlayers()
        UpdateLog()
    end
end

local function ShowLog()
    CreateLogFrame()
    db.logShown = true
    logFrame:Show()
    UpdateLog()
end

local function ShowPendingRoll(e)
    if dismissedRolls[e] then
        UpdateLog()
        return
    end
    if not IsLogShown() then autoOpened = true end
    ShowLog()
end

local function HideLog()
    db.logShown = false
    for _, e in ipairs(log) do
        if e.active and not e.myRoll then dismissedRolls[e] = true end
    end
    if logFrame then logFrame:Hide() end
end

local function ToggleLog()
    autoOpened = false  -- manual action takes over; don't auto-close afterwards
    if IsLogShown() then HideLog() else ShowLog() end
end

--------------------------------------------------------------------------------
-- Test mode: fill the window with sample rows to preview the layout
--------------------------------------------------------------------------------

local testMode, realLog = false, nil

local function BuildTestData()
    local _, myClass = UnitClass("player")
    return {
        {   -- pending, needs a roll (pulses; Need/Greed/Pass/extra + Pawn %)
            rollID = -1, name = "Greatsword of Testing", texture = "Interface\\Icons\\INV_Sword_39",
            quality = 4, canNeed = true, canGreed = true, canDE = true, canTransmog = true,
            action = "leave", active = true, test = true, fakeTimer = "50s", fakeFrac = 0.85,
            pawnDone = true, pawnText = "+18%", pawnR = 0, pawnG = 1, pawnB = 0, pawnArrow = true,
        },
        {   -- pending, not usable by class (no Need button)
            rollID = -2, name = "Cloth Hood of the Wrong Class", texture = "Interface\\Icons\\INV_Helmet_24",
            quality = 3, canNeed = false, canGreed = true, canDE = true,
            action = "leave", active = true, test = true, fakeTimer = "15s", fakeFrac = 0.22, pawnDone = true,
        },
        {   -- auto-greeded (shows your token + "Auto")
            rollID = -3, name = "Leather Belt of Filler", texture = "Interface\\Icons\\INV_Belt_15",
            quality = 3, action = "greed", myRoll = 2, auto = true, active = false, test = true, pawnDone = true,
            players = { { name = "You", class = myClass, rollType = 2, isWinner = false, isMe = true } },
        },
        {   -- resolved, several rollers, a winner (crown)
            rollID = -4, name = "Contested Trinket of Envy", texture = "Interface\\Icons\\INV_Jewelry_Trinket_04",
            quality = 4, action = "leave", myRoll = 1, auto = false, active = false, test = true,
            pawnDone = true, pawnText = "ilvl +8", pawnR = 0.6, pawnG = 0.8, pawnB = 1,
            players = {
                { name = "You", class = myClass, rollType = 1, isWinner = true, isMe = true },
                { name = "Sneakyy", class = "ROGUE", rollType = 1 },
                { name = "Frostina", class = "MAGE", rollType = 2 },
                { name = "Healbot", class = "PRIEST", rollType = 0 },
            },
        },
    }
end

local function ToggleTest()
    testMode = not testMode
    if testMode then
        realLog = log
        log = BuildTestData()
        autoOpened = false
        ShowLog()
        Print("test mode ON - sample data. /bdl test again to restore your log.")
    else
        log = realLog or {}
        realLog = nil
        UpdateLog()
        Print("test mode OFF.")
    end
end

--------------------------------------------------------------------------------
-- Options panel (Settings canvas) + minimap button
--------------------------------------------------------------------------------

local settingsCategory

local function OpenSettings()
    if Settings and settingsCategory and settingsCategory.GetID then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and settingsCategory then
        InterfaceOptionsFrame_OpenToCategory(settingsCategory)
        InterfaceOptionsFrame_OpenToCategory(settingsCategory)
    end
end

local function AddCheck(panel, x, y, label, getFn, setFn)
    local c = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    c:SetPoint("TOPLEFT", x, y)
    c:SetChecked(getFn())
    c:SetScript("OnClick", function(self) setFn(self:GetChecked() and true or false) end)
    local l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    l:SetPoint("LEFT", c, "RIGHT", 4, 0)
    l:SetText(label)
    return c
end

local function BuildOptions()
    local panel = CreateFrame("Frame")
    panel.name = "BetterDungeonLoot"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("BetterDungeonLoot")

    -- rows slider (1..5)
    local rows = CreateFrame("Slider", "BDLRowsSlider", panel, "OptionsSliderTemplate")
    rows:SetPoint("TOPLEFT", 24, -60)
    rows:SetWidth(220)
    rows:SetMinMaxValues(1, 5)
    rows:SetValueStep(1)
    rows:SetObeyStepOnDrag(true)
    BDLRowsSliderLow:SetText("1")
    BDLRowsSliderHigh:SetText("5")
    rows:SetValue(db.rowCount or 2)
    BDLRowsSliderText:SetText("Rows shown: " .. (db.rowCount or 2))
    rows:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v + 0.5)
        db.rowCount = v
        BDLRowsSliderText:SetText("Rows shown: " .. v)
        UpdateLog()
    end)

    -- history slider (10..100)
    local hist = CreateFrame("Slider", "BDLHistSlider", panel, "OptionsSliderTemplate")
    hist:SetPoint("TOPLEFT", 24, -120)
    hist:SetWidth(220)
    hist:SetMinMaxValues(10, 100)
    hist:SetValueStep(5)
    hist:SetObeyStepOnDrag(true)
    BDLHistSliderLow:SetText("10")
    BDLHistSliderHigh:SetText("100")
    hist:SetValue(db.storageMax or 20)
    BDLHistSliderText:SetText("History size: " .. (db.storageMax or 20))
    hist:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / 5 + 0.5) * 5
        db.storageMax = v
        BDLHistSliderText:SetText("History size: " .. v)
        while #log > v do table.remove(log) end
        UpdateLog()
    end)

    -- auto-greed mode (radio)
    local modeHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    modeHdr:SetPoint("TOPLEFT", 24, -170)
    modeHdr:SetText("Auto-greed mode:")

    local r1 = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
    r1:SetPoint("TOPLEFT", 28, -192)
    local r1l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r1l:SetPoint("LEFT", r1, "RIGHT", 4, 0)
    r1l:SetText("Greed anything I can't equip/use")

    local r2 = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
    r2:SetPoint("TOPLEFT", 28, -216)
    local r2l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r2l:SetPoint("LEFT", r2, "RIGHT", 4, 0)
    r2l:SetText("Greed wrong armor type (smart)")

    -- third mode only offered when Pawn is loaded: greed everything that isn't a
    -- Pawn upgrade (actual upgrades are left for you to roll on)
    local pawnLoaded = (PawnGetItemData and PawnIsItemAnUpgrade) and true or false
    if not pawnLoaded and db.autoRollMode == "pawn" then db.autoRollMode = "armor" end

    local r3
    if pawnLoaded then
        r3 = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
        r3:SetPoint("TOPLEFT", 28, -240)
        local r3l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r3l:SetPoint("LEFT", r3, "RIGHT", 4, 0)
        r3l:SetText("Greed everything that isn't an upgrade (Pawn)")
    end

    local function syncRadios()
        r1:SetChecked(db.autoRollMode == "cantuse")
        r2:SetChecked(db.autoRollMode == "armor")
        if r3 then r3:SetChecked(db.autoRollMode == "pawn") end
    end
    r1:SetScript("OnClick", function() db.autoRollMode = "cantuse"; syncRadios() end)
    r2:SetScript("OnClick", function() db.autoRollMode = "armor"; syncRadios() end)
    if r3 then r3:SetScript("OnClick", function() db.autoRollMode = "pawn"; syncRadios() end) end
    syncRadios()

    AddCheck(panel, 24, -272, "Auto-greed gems, reagents & materials",
        function() return db.autoGreedResources end,
        function(v) db.autoGreedResources = v end)

    AddCheck(panel, 24, -300, "Auto-greed all green (uncommon) items",
        function() return db.autoGreedGreens end,
        function(v) db.autoGreedGreens = v end)

    AddCheck(panel, 24, -328, "Auto-greed slots where you wear an heirloom",
        function() return db.autoGreedHeirloomSlot end,
        function(v) db.autoGreedHeirloomSlot = v end)

    -- Pawn-only option: hidden entirely when Pawn isn't loaded (it's a no-op then)
    local timerY = -356
    if pawnLoaded then
        AddCheck(panel, 24, -356, "Never auto-greed a Pawn upgrade (offer the roll)",
            function() return db.dontGreedUpgrades end,
            function(v) db.dontGreedUpgrades = v end)
        timerY = -384
    end

    AddCheck(panel, 24, timerY, "Show a countdown bar on pending rolls",
        function() return db.showTimerBar end,
        function(v) db.showTimerBar = v; UpdateLog() end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "BetterDungeonLoot")
        Settings.RegisterAddOnCategory(settingsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
        settingsCategory = panel
    end
end

local function CreateMinimapButton()
    local b = CreateFrame("Button", "BetterDungeonLootMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Dice_02")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT")

    local function updatePos()
        local a = math.rad(db.minimapAngle or 200)
        local r = (Minimap:GetWidth() / 2) + 5
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
    end

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            cx, cy = cx / scale, cy / scale
            db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            updatePos()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            OpenSettings()
        else
            ToggleLog()
        end
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("BetterDungeonLoot")
        GameTooltip:AddLine("Left-click: show/hide window", 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    updatePos()
end

--------------------------------------------------------------------------------
-- Hide Blizzard's group-loot roll frames. Items needing a manual roll pop our
-- log window instead, so the default center frames are never needed.
--------------------------------------------------------------------------------

local foreverMouseState = setmetatable({}, { __mode = "k" })
local function SetForeverMouseTree(frame, hide)
    if foreverMouseState[frame] == nil then
        foreverMouseState[frame] = frame:IsMouseEnabled() and 1 or 0
    end
    frame:EnableMouse(not hide and foreverMouseState[frame] == 1)
    for _, child in ipairs({ frame:GetChildren() }) do
        SetForeverMouseTree(child, hide)
    end
end

local function UpdateForeverBlizzardVisibility()
    if not IS_FOREVER then return end
    local hide = db.enabled and db.hideBlizzardRoll
    -- Keep Blizzard's roll frames shown internally so their event handlers still
    -- retire each roll. Hiding the frames makes Blizzard reuse live roll slots.
    -- In Forever the roll frames are parented to UIParent, not GroupLootContainer.
    for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
        local rollFrame = _G["GroupLootFrame" .. i]
        if rollFrame then
            rollFrame:SetAlpha(hide and 0 or 1)
            SetForeverMouseTree(rollFrame, hide)
        end
    end
end

local function SetupHideBlizzard()
    if IS_FOREVER then
        for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
            local f = _G["GroupLootFrame" .. i]
            if f then f:HookScript("OnShow", UpdateForeverBlizzardVisibility) end
        end
        UpdateForeverBlizzardVisibility()
        return
    end
    local function hideIf(f)
        if db.enabled and db.hideBlizzardRoll then
            f:Hide()
        end
    end
    if GroupLootContainer then
        hooksecurefunc(GroupLootContainer, "Show", function(self) hideIf(self) end)
    end
    local num = NUM_GROUP_LOOT_FRAMES or 4
    for i = 1, num do
        local f = _G["GroupLootFrame" .. i]
        if f then
            hooksecurefunc(f, "Show", function(self) hideIf(self) end)
        end
    end
end

--------------------------------------------------------------------------------
-- Auto-roll dispatch (defers greed while Pawn checks for an upgrade)
--------------------------------------------------------------------------------

local function AutoRoll_Apply(e, rollID, decision)
    local rt = (decision == "need" and 1) or (decision == "greed" and 2) or (decision == "disenchant" and 3)
    if not rt then return end
    RollOnLoot(rollID, rt)
    e.myRoll = rt
    e.action = (decision == "disenchant") and "de" or decision
    e.auto = true
    lastAutoRollReason = (e.name or tostring(rollID)) .. ": auto-" .. decision
    UpdateLog()
end

local function AutoRoll_Leave(e)
    e.action = "leave"
    e.auto = false
    e.myRoll = nil
    ShowPendingRoll(e)
end

local DecideAndApply, SafeDecideAndApply
DecideAndApply = function(rollID, tries)
    local e
    for _, x in ipairs(log) do if x.rollID == rollID then e = x break end end
    if not e or e.myRoll or not e.active then
        if (tries or 0) == 0 then
            lastAutoRollReason = "roll " .. tostring(rollID) .. ": already resolved before decision"
        end
        return
    end

    if not db.autoRoll then
        lastAutoRollReason = (e.name or tostring(rollID)) .. ": auto-roll disabled"
        AutoRoll_Leave(e)
        return
    end
    if not InScope() then
        local inInstance, instanceType = IsInInstance()
        lastAutoRollReason = (e.name or tostring(rollID)) .. ": outside scope (IsInInstance="
            .. tostring(inInstance) .. ", type=" .. tostring(instanceType) .. ")"
        AutoRoll_Leave(e)
        return
    end

    local _, name, _, quality, _, canNeed, canGreed = GetLootRollItemInfo(rollID)
    e.link = (GetLootRollItemLink and GetLootRollItemLink(rollID)) or e.link
    e.name = name or e.name
    e.quality = quality or e.quality
    quality = e.quality
    e.canNeed, e.canGreed = canNeed, canGreed
    local function Retry(reason)
        if (tries or 0) < 10 and C_Timer and C_Timer.After then
            lastAutoRollReason = (e.name or tostring(rollID)) .. ": waiting for " .. reason
            C_Timer.After(0.25, function() SafeDecideAndApply(rollID, (tries or 0) + 1) end)
            ShowPendingRoll(e)
            return true
        end
        lastAutoRollReason = (e.name or tostring(rollID)) .. ": " .. reason .. " unavailable; manual roll"
        AutoRoll_Leave(e)
        return true
    end
    if not name or canGreed == nil then
        Retry("loot roll data")
        return
    end
    if not canGreed then
        lastAutoRollReason = (e.name or tostring(rollID)) .. ": Greed unavailable"
        AutoRoll_Leave(e)
        return
    end

    local decision, final = DecideRoll(rollID, canNeed, quality, e.link)
    if decision == "retry" then
        Retry("item data")
        return
    end
    if decision == "leave" then
        lastAutoRollReason = (e.name or tostring(rollID)) .. ": rule left item for manual roll"
        AutoRoll_Leave(e)
        return
    end

    -- Hold back items Pawn flags as an upgrade (waiting for Pawn to load first).
    -- Always applies in the "greed non-upgrades (Pawn)" mode, and when the
    -- "never auto-greed a Pawn upgrade" option is on for the other modes.
    -- A "final" greed (the heirloom-slot rule) skips this: keeping the heirloom
    -- deliberately overrides Pawn, which may rate the drop as an upgrade.
    -- Pawn compares equipment.  Gems, materials, and recipes have no equipment
    -- slot, so do not hold their Greed roll while Pawn tries to parse them.
    local equipLoc, _, _, classID
    if e.link then equipLoc, _, _, classID = select(9, GetItemInfo(e.link)) end
    if not classID and PawnLoaded() and (db.autoRollMode == "pawn" or db.dontGreedUpgrades) then
        Retry("item data")
        return
    end
    local pawnRelevant = equipLoc ~= nil and equipLoc ~= "" and classID ~= 9
    if not final and pawnRelevant and (db.autoRollMode == "pawn" or db.dontGreedUpgrades) and decision == "greed" then
        local ready, isUp = PawnUpgradeCheck(e.link)
        if isUp then
            lastAutoRollReason = (e.name or tostring(rollID)) .. ": Pawn marked as upgrade"
            AutoRoll_Leave(e)
            return
        end
        if not ready then
            Retry("Pawn item data")
            return
        end
    end

    AutoRoll_Apply(e, rollID, decision)
end

SafeDecideAndApply = function(rollID, tries)
    local ok, err = pcall(DecideAndApply, rollID, tries)
    if ok then return end
    lastAutoRollReason = "roll " .. tostring(rollID) .. ": decision error: " .. tostring(err)
    Print(lastAutoRollReason)
    for _, e in ipairs(log) do
        if e.rollID == rollID and e.active and not e.myRoll then
            local shown, showErr = pcall(AutoRoll_Leave, e)
            if not shown then Print("couldn't show roll window: " .. tostring(showErr)) end
            break
        end
    end
end

--------------------------------------------------------------------------------
-- Event dispatch
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("START_LOOT_ROLL")
frame:RegisterEvent("CANCEL_LOOT_ROLL")
frame:RegisterEvent("CONFIRM_LOOT_ROLL")
frame:RegisterEvent("LOOT_BIND_CONFIRM")
if IS_FOREVER then
    frame:RegisterEvent("CANCEL_ALL_LOOT_ROLLS")
    frame:RegisterEvent("LOOT_HISTORY_UPDATE_DROP")
    frame:RegisterEvent("LOOT_HISTORY_UPDATE_ENCOUNTER")
else
    frame:RegisterEvent("LOOT_HISTORY_FULL_UPDATE")
    frame:RegisterEvent("LOOT_HISTORY_ROLL_CHANGED")
    frame:RegisterEvent("LOOT_HISTORY_ROLL_COMPLETE")
end
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        BetterDungeonLootDB = BetterDungeonLootDB or {}
        db = BetterDungeonLootDB
        ApplyDefaults(db, defaults)
        db.dbVersion = DB_VERSION
        db.log = nil  -- migrated: history is now per-character
        -- per-character loot log (rollIDs are dead after a reload, so view-only)
        BetterDungeonLootCharDB = BetterDungeonLootCharDB or {}
        BetterDungeonLootCharDB.log = BetterDungeonLootCharDB.log or {}
        log = BetterDungeonLootCharDB.log
        for _, e in ipairs(log) do e.active = false end
        CreateLogFrame()
        if db.logShown then logFrame:Show() else logFrame:Hide() end
        UpdateLog()
        SetupHideBlizzard()
        pcall(BuildOptions)
        pcall(CreateMinimapButton)
        -- re-arm rolls that are still live after a reload (data may lag a moment)
        if C_Timer and C_Timer.After then
            for _, d in ipairs({ 1, 2, 3, 5 }) do
                C_Timer.After(d, ReactivateLiveRolls)
            end
        end
        Print("loaded. /bdl for commands.")

    elseif event == "START_LOOT_ROLL" then
        startLootRollCount = startLootRollCount + 1
        lastAutoRollReason = "START_LOOT_ROLL received (ID " .. tostring(arg1) .. ")"
        local e = AddRoll(arg1, "leave", arg2)  -- arg2 = total roll time (ms)
        SafeDecideAndApply(arg1, 0)
        -- A client API error must never leave a live roll invisible.
        if e.active and not e.myRoll and not IsLogShown() and not dismissedRolls[e] then
            ShowPendingRoll(e)
        end
        if IS_FOREVER then RefreshPlayers() end

    elseif event == "CANCEL_LOOT_ROLL" then
        for _, e in ipairs(log) do
            if e.rollID == arg1 then e.active = false end
        end
        UpdateLog()

    elseif event == "CANCEL_ALL_LOOT_ROLLS" then
        for _, e in ipairs(log) do e.active = false end
        UpdateLog()

    elseif event == "CONFIRM_LOOT_ROLL" then
        OnConfirmLootRoll(arg1, arg2)

    elseif event == "LOOT_BIND_CONFIRM" then
        OnLootBindConfirm(arg1)

    elseif event == "LOOT_HISTORY_FULL_UPDATE"
        or event == "LOOT_HISTORY_ROLL_CHANGED"
        or event == "LOOT_HISTORY_ROLL_COMPLETE"
        or event == "LOOT_HISTORY_UPDATE_DROP"
        or event == "LOOT_HISTORY_UPDATE_ENCOUNTER" then
        RefreshPlayers()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- an item finished loading: recompute Pawn % for entries still pending
        for _, e in ipairs(log) do
            if not e.pawnDone then UpdateLog() break end
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        for _, e in ipairs(log) do e.pawnDone = nil end
        UpdateLog()
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Diagnostic: dump the parsed scaling cap (and working state) for equipped heirlooms.
local function DumpHeirlooms()
    local plvl = UnitLevel("player") or 0
    Print(("heirloom dump — player level %d:"):format(plvl))
    local found = false
    for slot = 1, 18 do
        local q = GetInventoryItemQuality("player", slot)
        local link = GetInventoryItemLink("player", slot)
        if link and q == nil then q = select(3, GetItemInfo(link)) end
        if link and q == HEIRLOOM_QUALITY then
            found = true
            local name = GetItemInfo(link)
            local cap = HeirloomCap(link)
            local working = (not cap) or plvl <= cap
            Print(("  slot %d: %s — cap %s, %s"):format(
                slot, tostring(name), cap and tostring(cap) or "?",
                working and "still scaling (greed slot)" or "capped (treated as no heirloom)"))
        end
    end
    if not found then Print("  no equipped heirlooms found.") end
end

local function ShowStatus()
    local inInstance, instanceType = IsInInstance()
    local activeRolls = "unavailable"
    if GetActiveLootRollIDs then
        local ok, ids = pcall(GetActiveLootRollIDs)
        if ok and type(ids) == "table" then activeRolls = tostring(#ids) end
    end
    Print("status:")
    Print(("  enabled: %s | scope: %s | IsInInstance: %s (%s)"):format(
        tostring(db.enabled), db.scope, tostring(inInstance), tostring(instanceType)))
    Print(("  autoConfirmBind (F1): %s"):format(tostring(db.autoConfirmBind)))
    Print(("  autoRoll (F3): %s | mode: %s | fitting: %s"):format(
        tostring(db.autoRoll), tostring(db.autoRollMode), db.fittingBehavior))
    Print("  last roll: " .. (lastAutoRollReason or "none since login"))
    Print(("  START_LOOT_ROLL: %d | active roll IDs: %s | opt out: %s"):format(
        startLootRollCount, activeRolls,
        tostring(GetOptOutOfLoot and GetOptOutOfLoot() or false)))
    Print(("  showNeeders (F4): %s"):format(tostring(db.showNeeders)))
    Print(("  hideBlizzardRoll: %s | logShown: %s"):format(tostring(db.hideBlizzardRoll), tostring(db.logShown)))
end

SLASH_BETTERDUNGEONLOOT1 = "/bdl"
SlashCmdList["BETTERDUNGEONLOOT"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "" or msg == "help" then
        Print("commands:")
        Print("  /bdl status   - show current settings")
        Print("  /bdl log      - show/hide the loot-log window")
        Print("  /bdl test     - fill the window with sample rows (preview layout)")
        Print("  /bdl config   - open the settings panel")
        Print("  /bdl autoroll - toggle auto-greed of wrong-armor items (F3)")
        Print("  /bdl mode cantuse|armor|pawn - choose auto-greed rule")
        Print("  /bdl scope instance|everywhere - where automatic actions apply")
        Print("  /bdl fitting  - fitting items: leave <-> auto-need")
        Print("  /bdl needers  - toggle showing who rolled Need (F4)")
        Print("  /bdl hideblizz- toggle hiding Blizzard roll frames")
        Print("  /bdl heirloom - dump equipped heirloom data (cap detection debug)")
        Print("  /bdl on|off   - enable/disable the addon")
    elseif msg == "status" then
        ShowStatus()
    elseif msg == "heirloom" then
        DumpHeirlooms()
    elseif msg == "log" then
        ToggleLog()
    elseif msg == "test" then
        ToggleTest()
    elseif msg == "config" or msg == "options" then
        OpenSettings()
    elseif msg == "autoroll" then
        db.autoRoll = not db.autoRoll
        if logFrame and logFrame.autoCB then logFrame.autoCB:SetChecked(db.autoRoll) end
        Print("autoRoll (F3): " .. tostring(db.autoRoll))
    elseif msg == "mode cantuse" or msg == "mode armor" or msg == "mode pawn" then
        local mode = msg:match("^mode (.+)$")
        if mode == "pawn" and not PawnLoaded() then
            Print("Pawn mode requires Pawn to be loaded.")
        else
            db.autoRollMode = mode
            Print("auto-greed mode: " .. mode)
        end
    elseif msg == "mode" then
        Print("auto-greed mode: " .. db.autoRollMode .. " (use /bdl mode cantuse|armor|pawn)")
    elseif msg == "scope instance" or msg == "scope everywhere" then
        db.scope = msg:match("^scope (.+)$")
        Print("automatic actions scope: " .. db.scope)
    elseif msg == "scope" then
        Print("automatic actions scope: " .. db.scope .. " (use /bdl scope instance|everywhere)")
    elseif msg == "fitting" then
        db.fittingBehavior = (db.fittingBehavior == "need") and "leave" or "need"
        Print("fitting items behavior: " .. db.fittingBehavior)
    elseif msg == "needers" then
        db.showNeeders = not db.showNeeders
        Print("showNeeders (F4): " .. tostring(db.showNeeders))
        UpdateLog()
    elseif msg == "hideblizz" then
        db.hideBlizzardRoll = not db.hideBlizzardRoll
        UpdateForeverBlizzardVisibility()
        Print("hideBlizzardRoll: " .. tostring(db.hideBlizzardRoll))
    elseif msg == "on" then
        db.enabled = true
        UpdateForeverBlizzardVisibility()
        Print("enabled.")
    elseif msg == "off" then
        db.enabled = false
        UpdateForeverBlizzardVisibility()
        Print("disabled.")
    else
        Print("unknown command: " .. msg .. " (try /bdl help)")
    end
end
