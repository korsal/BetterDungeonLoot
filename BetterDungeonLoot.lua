-- BetterDungeonLoot
-- F1 auto-confirm BoP bind popups
-- F3 smart auto-greed of wrong-armor body pieces
-- F5 persistent loot-log window: last N rolls, roll from the window,
--    shows who rolled Need (F4), and hides Blizzard's roll frames (F2 obsolete).

local ADDON_NAME = ...

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
    enchanterDisenchant = false,
    autoRollMode = "armor",      -- armor (wrong armor type) | cantuse (anything unusable)
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
    showPawnUpgrade = true,      -- show Pawn upgrade % under the icon (if Pawn is loaded)

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

-- "greed"/"disenchant" for clearly wrong-armor body pieces; "need" if configured
-- to auto-need fitting items; otherwise "leave" (let the player decide).
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

local function SlotHasHeirloom(equipLoc)
    local slots = EQUIPLOC_SLOTS[equipLoc]
    if not slots then return false end
    for _, slot in ipairs(slots) do
        local q = GetInventoryItemQuality("player", slot)
        if not q then
            local link = GetInventoryItemLink("player", slot)
            if link then q = select(3, GetItemInfo(link)) end
        end
        if q == HEIRLOOM_QUALITY then return true end
    end
    return false
end

-- Gem (3), Reagent (5), Trade Goods (7) — the "materials" bucket
local RESOURCE_CLASSES = { [3] = true, [5] = true, [7] = true }

local function DecideRoll(rollID, canNeed, canDE, quality)
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
    if not link then return "leave" end
    local _, _, _, _, _, _, _, _, equipLoc, _, _, classID, subclassID = GetItemInfo(link)

    local function greedOrDE()
        if db.enchanterDisenchant and canDE then return "disenchant" end
        return "greed"
    end

    -- gems / reagents / crafting materials
    if db.autoGreedResources and classID and RESOURCE_CLASSES[classID] then
        return greedOrDE()
    end

    -- all green (uncommon) items
    if db.autoGreedGreens and quality == 2 then
        return greedOrDE()
    end

    -- slot is already filled by an heirloom (regular drops there aren't upgrades)
    if db.autoGreedHeirloomSlot and equipLoc and SlotHasHeirloom(equipLoc) then
        return greedOrDE()
    end

    if db.autoRollMode == "cantuse" then
        -- greed anything this character can't equip/use at all
        if not canNeed then
            return greedOrDE()
        end
    else
        -- "armor": greed body armor that isn't your class's armor type,
        -- and weapons the character can't equip
        if not classID then return "leave" end  -- not cached: never risk a wrong roll
        if classID == ITEM_CLASS_ARMOR and BODY_ARMOR_SLOTS[equipLoc] then
            local pref = PreferredArmorSubclass()
            if pref and subclassID and subclassID ~= pref then
                return greedOrDE()
            end
        elseif classID == ITEM_CLASS_WEAPON and not canNeed then
            return greedOrDE()
        end
    end

    if db.fittingBehavior == "need" and canNeed then return "need" end
    return "leave"
end

-- Runs the auto-roll and returns what we did: "greed" | "de" | "need" | "leave".
local function DecideAndRoll(rollID)
    if not db.autoRoll or not InScope() then return "leave" end
    local _, _, _, quality, _, canNeed, canGreed, canDE = GetLootRollItemInfo(rollID)
    if not canGreed then return "leave" end

    local decision = DecideRoll(rollID, canNeed, canDE, quality)
    if decision == "greed" then
        RollOnLoot(rollID, 2)
        return "greed"
    elseif decision == "disenchant" then
        RollOnLoot(rollID, 3)
        return "de"
    elseif decision == "need" then
        RollOnLoot(rollID, 1)
        return "need"
    end
    return "leave"
end

--------------------------------------------------------------------------------
-- F4 helpers: read each player's roll from C_LootHistory
-- GetPlayerInfo -> name, class, rollType, roll, isWinner, isMe
-- rollType: 0 pass, 1 need, 2 greed, 3 disenchant
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

-- list of {name(short), class, rollType, isWinner} for players who have chosen
local function HistoryPlayersForRoll(rollID)
    if not C_LootHistory then return nil end
    local n = C_LootHistory.GetNumItems and C_LootHistory.GetNumItems() or 0
    for idx = 1, n do
        local id = C_LootHistory.GetItem(idx)
        if id == rollID and C_LootHistory.GetPlayerInfo then
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
local log = {}           -- log[1] = newest
local scrollOffset = 0   -- how many newest entries are scrolled past
local autoOpened = false -- window was popped open by a roll (auto-close when done)
local UpdateLog          -- forward declaration

local function IsLogShown()
    return logFrame and logFrame:IsShown()
end

local ROLL_TYPE_NAME = { [0] = "Pass", [1] = "Need", [2] = "Greed", [3] = "DE" }

local function QualityColoredName(e)
    local q = ITEM_QUALITY_COLORS[e.quality or 1]
    local hex = (q and q.hex) or "|cffffffff"
    return hex .. (e.name or "?") .. "|r"
end

local function RollFromRow(row, rtype)
    local e = row.entry
    if not e or not e.active then return end
    RollOnLoot(e.rollID, rtype)
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
local CROWN_TEX = "Interface\\GroupFrame\\UI-Group-LeaderIcon"
local CIRCLE_MASK = "Interface\\Masks\\CircleMaskScalable"

-- the Blizzard roll icons sit high inside their texture; nudge them down so they
-- look centered (buttons at 22px, circle tokens at 16px need a smaller nudge)
local ROLL_ICON_OFFSET = { [0] = 0, [1] = -1, [2] = -3, [3] = 0 }
local ROLL_ICON_OFFSET_TOKEN = { [0] = 0, [1] = -1, [2] = -3, [3] = 0 }

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

    local base = ROLL_BTN_BASE[rtype]
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(22, 22)
    b.icon:SetPoint("CENTER", b, "CENTER", 0, ROLL_ICON_OFFSET[rtype] or 0)
    b.icon:SetTexture(base .. "-Up")

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

-- returns computed(bool), text, r, g, b  (computed=false means "item not cached, retry later")
local function PawnUpgradeFor(link)
    if not (PawnIsInitialized and PawnGetItemData and PawnIsItemAnUpgrade) then
        return true, nil
    end
    if not link then return true, nil end
    local ok, item = pcall(PawnGetItemData, link)
    if not ok then return true, nil end
    if not item or not item.Link then return false, nil end  -- not cached yet
    local ok2, up, ilvl = pcall(PawnIsItemAnUpgrade, item)
    if not ok2 then return true, nil end

    if up then
        local active = PawnActiveScaleName()
        for _, u in ipairs(up) do
            if u.ScaleName == active then
                return true, ("+%d%%"):format(math.floor((u.PercentUpgrade or 0) * 100 + 0.5)), 0.2, 1, 0.2
            end
        end
    end
    if ilvl and ilvl > 0 then
        return true, ("ilvl +%d"):format(ilvl), 0.6, 0.8, 1
    end
    return true, nil
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

    -- Pawn upgrade % under the icon
    row.upgrade = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.upgrade:SetPoint("TOP", row.icon, "BOTTOM", 0, -1)
    row.upgrade:SetWidth(46)
    row.upgrade:SetJustifyH("CENTER")
    row.upgrade:SetWordWrap(false)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 44, -2)
    row.name:SetWidth(130)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.timer = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.timer:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)

    -- separate right-side column so the tag never gets clipped with the name
    row.autoTag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.autoTag:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
    row.autoTag:SetText("Auto")

    -- roll buttons (each in its own rounded frame; shown when the item needs a decision)
    row.needBtn  = MakeRollIconButton(row, 1)
    row.greedBtn = MakeRollIconButton(row, 2)
    row.passBtn  = MakeRollIconButton(row, 0)
    row.deBtn    = MakeRollIconButton(row, 3)
    row.needBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 44, -20)
    row.greedBtn:SetPoint("LEFT", row.needBtn, "RIGHT", 6, 0)
    row.passBtn:SetPoint("LEFT", row.greedBtn, "RIGHT", 6, 0)
    row.deBtn:SetPoint("LEFT", row.passBtn, "RIGHT", 6, 0)

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
            tok.rollIcon:SetTexture(ROLL_TYPE_ICON[p.rollType])
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

local function BindRow(row, e)
    row.entry = e
    row.icon.tex:SetTexture(e.texture)
    row.icon.link = e.link
    row.name:SetText(QualityColoredName(e))

    if db.showPawnUpgrade then
        if not e.pawnDone then
            local done, txt, r, g, b = PawnUpgradeFor(e.link)
            if done then
                e.pawnDone = true
                e.pawnText, e.pawnR, e.pawnG, e.pawnB = txt, r, g, b
            end
        end
        row.upgrade:SetText(e.pawnText or "")
        if e.pawnText then row.upgrade:SetTextColor(e.pawnR or 1, e.pawnG or 1, e.pawnB or 1) end
    else
        row.upgrade:SetText("")
    end

    local isAuto = (e.auto and e.myRoll) and true or false
    row.autoTag:SetShown(isAuto)

    if e.active and not isAuto then
        local left = GetLootRollTimeLeft and GetLootRollTimeLeft(e.rollID)
        row.timer:SetText((left and left > 0) and (math.ceil(left / 1000) .. "s") or "")
    else
        row.timer:SetText("")
    end

    local needRoll = e.active and not e.myRoll
    row.needBtn:SetShown(needRoll and (e.canNeed and true or false))
    row.greedBtn:SetShown(needRoll and (e.canGreed and true or false))
    row.passBtn:SetShown(needRoll)
    row.deBtn:SetShown(needRoll and (e.canDE and true or false))

    if needRoll then
        row.glow:Show()
        row.glowAnim:Play()
        for _, t in ipairs(row.tokens) do t:Hide() end
    else
        row.glowAnim:Stop()
        row.glow:Hide()
        BindTokens(row, e)
    end
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
            if row:IsShown() and ent and ent.active and not ent.auto then
                local left = GetLootRollTimeLeft and GetLootRollTimeLeft(ent.rollID)
                if not left or left <= 0 then
                    ent.active = false
                    dirty = true
                else
                    row.timer:SetText(math.ceil(left / 1000) .. "s")
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

local function AddRoll(rollID, action)
    local texture, name, _, quality, bop, canNeed, canGreed, canDE = GetLootRollItemInfo(rollID)
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
    local e = {
        rollID = rollID, link = link, name = name, texture = texture,
        quality = quality or 1, bop = bop,
        canNeed = canNeed, canGreed = canGreed, canDE = canDE,
        action = action, active = true, players = nil, auto = (action ~= "leave"),
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
end

local function RefreshPlayers()
    if not (db.showNeeders and C_LootHistory) then return end
    local found = false
    for _, e in ipairs(log) do
        local players = HistoryPlayersForRoll(e.rollID)
        if players then e.players = players; found = true end
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
    if changed then UpdateLog() end
end

local function ShowLog()
    CreateLogFrame()
    db.logShown = true
    logFrame:Show()
    UpdateLog()
end

local function HideLog()
    db.logShown = false
    if logFrame then logFrame:Hide() end
end

local function ToggleLog()
    autoOpened = false  -- manual action takes over; don't auto-close afterwards
    if IsLogShown() then HideLog() else ShowLog() end
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

    local function syncRadios()
        r1:SetChecked(db.autoRollMode == "cantuse")
        r2:SetChecked(db.autoRollMode ~= "cantuse")
    end
    r1:SetScript("OnClick", function() db.autoRollMode = "cantuse"; syncRadios() end)
    r2:SetScript("OnClick", function() db.autoRollMode = "armor"; syncRadios() end)
    syncRadios()

    AddCheck(panel, 24, -248, "Auto-greed gems, reagents & materials",
        function() return db.autoGreedResources end,
        function(v) db.autoGreedResources = v end)

    AddCheck(panel, 24, -276, "Auto-greed all green (uncommon) items",
        function() return db.autoGreedGreens end,
        function(v) db.autoGreedGreens = v end)

    AddCheck(panel, 24, -304, "Auto-greed slots where you wear an heirloom",
        function() return db.autoGreedHeirloomSlot end,
        function(v) db.autoGreedHeirloomSlot = v end)

    AddCheck(panel, 24, -332, "Show upgrade % vs equipped (requires Pawn)",
        function() return db.showPawnUpgrade end,
        function(v) db.showPawnUpgrade = v; UpdateLog() end)

    AddCheck(panel, 24, -360, "Enchanters: disenchant instead of greed",
        function() return db.enchanterDisenchant end,
        function(v) db.enchanterDisenchant = v end)

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

local function SetupHideBlizzard()
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
-- Event dispatch
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("START_LOOT_ROLL")
frame:RegisterEvent("CANCEL_LOOT_ROLL")
frame:RegisterEvent("CONFIRM_LOOT_ROLL")
frame:RegisterEvent("LOOT_BIND_CONFIRM")
frame:RegisterEvent("LOOT_HISTORY_FULL_UPDATE")
frame:RegisterEvent("LOOT_HISTORY_ROLL_CHANGED")
frame:RegisterEvent("LOOT_HISTORY_ROLL_COMPLETE")
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
        local action = DecideAndRoll(arg1)
        AddRoll(arg1, action)
        if action == "leave" then
            if not IsLogShown() then autoOpened = true end
            ShowLog()   -- needs a manual decision: pop the window to roll
        else
            UpdateLog() -- auto-handled: just record (silent if the log is hidden)
        end

    elseif event == "CANCEL_LOOT_ROLL" then
        for _, e in ipairs(log) do
            if e.rollID == arg1 then e.active = false end
        end
        UpdateLog()

    elseif event == "CONFIRM_LOOT_ROLL" then
        OnConfirmLootRoll(arg1, arg2)

    elseif event == "LOOT_BIND_CONFIRM" then
        OnLootBindConfirm(arg1)

    elseif event == "LOOT_HISTORY_FULL_UPDATE"
        or event == "LOOT_HISTORY_ROLL_CHANGED"
        or event == "LOOT_HISTORY_ROLL_COMPLETE" then
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

local function ShowStatus()
    Print("status:")
    Print(("  enabled: %s | scope: %s"):format(tostring(db.enabled), db.scope))
    Print(("  autoConfirmBind (F1): %s"):format(tostring(db.autoConfirmBind)))
    Print(("  autoRoll (F3): %s | fitting: %s"):format(tostring(db.autoRoll), db.fittingBehavior))
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
        Print("  /bdl config   - open the settings panel")
        Print("  /bdl autoroll - toggle auto-greed of wrong-armor items (F3)")
        Print("  /bdl fitting  - fitting items: leave <-> auto-need")
        Print("  /bdl needers  - toggle showing who rolled Need (F4)")
        Print("  /bdl hideblizz- toggle hiding Blizzard roll frames")
        Print("  /bdl on|off   - enable/disable the addon")
    elseif msg == "status" then
        ShowStatus()
    elseif msg == "log" then
        ToggleLog()
    elseif msg == "config" or msg == "options" then
        OpenSettings()
    elseif msg == "autoroll" then
        db.autoRoll = not db.autoRoll
        if logFrame and logFrame.autoCB then logFrame.autoCB:SetChecked(db.autoRoll) end
        Print("autoRoll (F3): " .. tostring(db.autoRoll))
    elseif msg == "fitting" then
        db.fittingBehavior = (db.fittingBehavior == "need") and "leave" or "need"
        Print("fitting items behavior: " .. db.fittingBehavior)
    elseif msg == "needers" then
        db.showNeeders = not db.showNeeders
        Print("showNeeders (F4): " .. tostring(db.showNeeders))
        UpdateLog()
    elseif msg == "hideblizz" then
        db.hideBlizzardRoll = not db.hideBlizzardRoll
        Print("hideBlizzardRoll: " .. tostring(db.hideBlizzardRoll))
    elseif msg == "on" then
        db.enabled = true
        Print("enabled.")
    elseif msg == "off" then
        db.enabled = false
        Print("disabled.")
    else
        Print("unknown command: " .. msg .. " (try /bdl help)")
    end
end
