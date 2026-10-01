-- Klar-sjekk: en liten knapp som passer på at du har med deg det du trenger før PvP.
-- Lista lager du selv: dra en ting fra baggen eller en spell fra spellboken inn i vinduet,
-- dra en rad ut av vinduet for å fjerne den, og opp eller ned for å bytte rekkefølge.
-- Varselet er et rolig, pulserende lys rundt knappen. Det kommer bare når noe mangler og det
-- faktisk gjelder (du står i BG-kø, køen har sprettet, eller du er i en BG), pulserer i
-- 30 sekunder og lyser deretter svakt til du har ordnet det. Høyreklikk = «ikke nå».
-- Alt leses utenfor kamp; i kamp er buffer og tall «hemmelige» for addons i WoW Forever.

local ADDON, ns = ...
ns = ns or {}
local VERSION = "1.0.0"

local ICON_SIZE = 32
local ROW_H = 32
local LIST_W = 262
local PULSE_SECONDS = 30
local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Note_01"
local POISON_TEXTURE = "Interface\\Icons\\Trade_BrewPoison"
local GREEN = { 0.45, 0.9, 0.45 }
local RED = { 1, 0.4, 0.3 }
local GRAY = { 0.6, 0.6, 0.6 }

------------------------------------------------------------------------
-- API-hjelpere (klientene har flyttet funksjoner rundt; bruk den som finnes)
------------------------------------------------------------------------

local function SpellInfo(id)
  if C_Spell and C_Spell.GetSpellInfo then
    local i = C_Spell.GetSpellInfo(id)
    if i then return i.name, i.iconID end
  end
  if GetSpellInfo then
    local name, _, icon = GetSpellInfo(id)
    return name, icon
  end
end

local function ItemSpell(itemID)
  if C_Item and C_Item.GetItemSpell then return C_Item.GetItemSpell(itemID) end
  if GetItemSpell then return GetItemSpell(itemID) end
end

local function ItemName(itemID)
  local fn = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  local name = fn and fn(itemID)
  return name or ("item " .. itemID)
end

local function ItemIcon(itemID)
  if C_Item and C_Item.GetItemIconByID then
    local icon = C_Item.GetItemIconByID(itemID)
    if icon then return icon end
  end
  local fn = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
  local icon = fn and select(5, fn(itemID))
  return icon or 134400
end

local function ItemCount(itemID)
  local fn = GetItemCount or (C_Item and C_Item.GetItemCount)
  return fn and fn(itemID) or 0
end

local function ItemClass(itemID)
  local fn = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
  if not fn then return end
  return (select(6, fn(itemID)))
end

local function NumSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function BagItemID(bag, slot)
  if C_Container and C_Container.GetContainerItemID then return C_Container.GetContainerItemID(bag, slot) end
  if GetContainerItemID then return GetContainerItemID(bag, slot) end
  local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
  return link and tonumber(link:match("item:(%d+)"))
end

local function IsEquipped(itemID)
  local fn = (C_Item and C_Item.IsEquippedItem) or IsEquippedItem
  return fn and fn(itemID) and true or false
end

local function IsEquippable(itemID)
  local fn = (C_Item and C_Item.IsEquippableItem) or IsEquippableItem
  return fn and fn(itemID) and true or false
end

-- Buffene på deg: navn → sekunder igjen (math.huge = uten tidsgrense), og spellId → sekunder igjen.
local function PlayerAuras()
  local byName, byId = {}, {}
  local now = GetTime()
  for i = 1, 40 do
    local name, spellId, expires
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
      local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
      if not a then break end
      name, spellId, expires = a.name, a.spellId, a.expirationTime
    else
      local n, _, _, _, _, exp, _, _, _, sid = UnitBuff("player", i)
      if not n then break end
      name, spellId, expires = n, sid, exp
    end
    local left = (expires and expires > 0) and (expires - now) or math.huge
    if name then byName[name] = math.max(byName[name] or 0, left) end
    if spellId then byId[spellId] = math.max(byId[spellId] or 0, left) end
  end
  return { byName = byName, byId = byId }
end

-- Gift, olje og slipestein på våpnene: slot (16/17) → sekunder igjen.
local function WeaponEnchants()
  local t = {}
  if not GetWeaponEnchantInfo then return t end
  local hasMain, mainExp, _, _, hasOff, offExp = GetWeaponEnchantInfo()
  if hasMain then t[16] = (mainExp and mainExp > 0) and mainExp / 1000 or math.huge end
  if hasOff then t[17] = (offExp and offExp > 0) and offExp / 1000 or math.huge end
  return t
end

local function InCombat()
  return InCombatLockdown() or UnitAffectingCombat("player")
end

local function Say(msg)
  print("|cff7fd17fKlar-sjekk:|r " .. msg)
end

------------------------------------------------------------------------
-- Lista. Hver rad er én av disse:
--   {kind="item",     id=itemID,  need=antall}   så mange i baggen
--   {kind="gear",     id=itemID}                 skal være på deg (trinket, våpen …)
--   {kind="buff",     id=spellID, min=minutter}  buffen er på, minst så lenge igjen
--   {kind="itembuff", id=itemID,  min=minutter}  buffen fra itemet er på (eliksir, mat)
--   {kind="enchant",  slot=16/17, min=minutter}  gift/olje/stein på våpenet
------------------------------------------------------------------------

local db
local results = {}  -- per rad: {ok=, text=}
local missing = 0
local stale = false -- i kamp: tallene er fra før kampen
local moment, pulseUntil, snoozed, testUntil = nil, 0, nil, 0
local lastRemoved
local Refresh, UpdatePanel -- defineres lenger ned

local SLOT_NAME = { [16] = "hovedhånd", [17] = "venstre hånd" }
local KIND_TEXT = {
  item = "antall i baggen",
  gear = "skal være på deg",
  buff = "buffen skal være på",
  itembuff = "buffen fra den skal være på",
  enchant = "gift, olje eller stein",
}

local function Key(e)
  if e.kind == "buff" then return "s:" .. e.id end
  if e.kind == "enchant" then return "e:" .. e.slot end
  return "i:" .. e.id
end

local function Describe(e)
  if e.kind == "buff" then
    local name, icon = SpellInfo(e.id)
    return name or ("spell " .. e.id), icon or 134400
  elseif e.kind == "enchant" then
    local icon = GetInventoryItemTexture and GetInventoryItemTexture("player", e.slot)
    return "Våpenet i " .. SLOT_NAME[e.slot], icon or POISON_TEXTURE
  end
  return ItemName(e.id), ItemIcon(e.id)
end

local function Requirement(e)
  local text = KIND_TEXT[e.kind] or ""
  if e.min and e.min > 0 and e.kind ~= "item" and e.kind ~= "gear" then
    text = text .. string.format(", minst %d min", e.min)
  end
  return text
end

local function TimeText(left)
  if left == math.huge then return "på" end
  if left < 60 then return "<1 min" end
  return string.format("%d min", math.floor(left / 60))
end

local function TimedCheck(left, min)
  min = min or 0
  if not left then return false, "mangler" end
  if left >= min * 60 then return true, TimeText(left) end
  return false, string.format("%s (vil ha %d)", TimeText(left), min)
end

local function BuffLeft(name, id, auras)
  local a = name and auras.byName[name]
  local b = id and auras.byId[id]
  if a and b then return math.max(a, b) end
  return a or b
end

local function Check(e, auras, enchants)
  if e.kind == "item" then
    local n = ItemCount(e.id)
    return n >= e.need, string.format("%d/%d", n, e.need)
  elseif e.kind == "gear" then
    if IsEquipped(e.id) then return true, "på deg" end
    return false, ItemCount(e.id) > 0 and "i baggen" or "mangler"
  elseif e.kind == "buff" then
    return TimedCheck(BuffLeft(SpellInfo(e.id), e.id, auras), e.min)
  elseif e.kind == "itembuff" then
    local name, id = ItemSpell(e.id)
    return TimedCheck(BuffLeft(name, id, auras), e.min)
  elseif e.kind == "enchant" then
    return TimedCheck(enchants[e.slot], e.min)
  end
  return true, ""
end

local function Evaluate()
  local auras, enchants = PlayerAuras(), WeaponEnchants()
  local res, miss = {}, 0
  for i, e in ipairs(db.list) do
    local ok, text = Check(e, auras, enchants)
    res[i] = { ok = ok, text = text }
    if not ok then miss = miss + 1 end
  end
  return res, miss
end

------------------------------------------------------------------------
-- Når gjelder det? Bare da lyser knappen.
------------------------------------------------------------------------

local function QueueState()
  if not GetBattlefieldStatus then return end
  local max = (GetMaxBattlefieldID and GetMaxBattlefieldID()) or MAX_BATTLEFIELD_QUEUES or 3
  local queued
  for i = 1, max do
    local status = GetBattlefieldStatus(i)
    if status == "confirm" then return "confirm", i end
    if status == "queued" then queued = "queued" end
  end
  return queued
end

local function CurrentMoment()
  if GetTime() < testUntil then return "test" end
  local inside, kind = IsInInstance()
  if inside and (kind == "pvp" or kind == "arena") then return "bg" end
  local q, i = QueueState()
  if q == "confirm" then return "confirm" .. i end
  if q then return "queued" end
  if db.flag and UnitIsPVP("player") then return "flag" end
end

local MOMENT_TEXT = {
  bg = "Du er i en BG.",
  queued = "Du står i kø.",
  flag = "PvP-flagget er på.",
  test = "Test av varselet.",
}

local function MomentText(m)
  if not m then return nil end
  if m:find("^confirm") then return "Køen har sprettet!" end
  return MOMENT_TEXT[m]
end

------------------------------------------------------------------------
-- Knappen og lyset
------------------------------------------------------------------------

local icon = CreateFrame("Button", "KlarsjekkIcon", UIParent)
icon:SetSize(ICON_SIZE, ICON_SIZE)
icon:SetMovable(true)
icon:SetClampedToScreen(true)
icon:EnableMouse(true)
icon:RegisterForDrag("LeftButton")
icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")

local iconBg = icon:CreateTexture(nil, "BACKGROUND")
iconBg:SetPoint("TOPLEFT", -1, 1)
iconBg:SetPoint("BOTTOMRIGHT", 1, -1)
iconBg:SetColorTexture(0, 0, 0, 0.9)

icon.tex = icon:CreateTexture(nil, "ARTWORK")
icon.tex:SetAllPoints()
icon.tex:SetTexture(ICON_TEXTURE)
icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

icon.badge = icon:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
icon.badge:SetPoint("BOTTOMRIGHT", -1, 2)

icon.ok = icon:CreateTexture(nil, "OVERLAY")
icon.ok:SetSize(14, 14)
icon.ok:SetPoint("BOTTOMRIGHT", 3, -3)
icon.ok:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
icon.ok:Hide()

-- Lyset: en myk, varm ring som går fra svak til sterk og tilbake på 2,4 sekunder. Ikke blink.
local glow = icon:CreateTexture(nil, "OVERLAY")
glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
glow:SetBlendMode("ADD")
glow:SetVertexColor(1, 0.65, 0.2)
glow:SetSize(ICON_SIZE * 1.9, ICON_SIZE * 1.9)
glow:SetPoint("CENTER")
glow:SetAlpha(0)
local pulse = glow:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(0.15)
fade:SetToAlpha(0.95)
fade:SetDuration(1.2)
fade:SetSmoothing("IN_OUT")

local glowState -- nil til første oppdatering, så knappens gjennomsiktighet settes med en gang
local function SetGlow(state)
  if state == glowState then return end
  glowState = state
  if state == "pulse" then
    glow:SetAlpha(1)
    pulse:Play()
  else
    pulse:Stop()
    glow:SetAlpha(state == "steady" and 0.35 or 0)
  end
  icon:SetAlpha(state == "off" and 0.7 or 1)
end

local function UpdateIcon()
  if #db.list == 0 then
    icon.badge:SetText("+")
    icon.badge:SetTextColor(unpack(GRAY))
    icon.ok:Hide()
  elseif missing > 0 then
    icon.badge:SetText(missing)
    icon.badge:SetTextColor(unpack(RED))
    icon.ok:Hide()
  else
    icon.badge:SetText("")
    icon.ok:Show()
  end

  local active = moment and snoozed ~= moment and (missing > 0 or moment == "test")
    and not InCombat() and not UnitIsDeadOrGhost("player")
  if not active then
    SetGlow("off")
  elseif GetTime() < pulseUntil then
    SetGlow("pulse")
  else
    SetGlow("steady")
  end
end

function Refresh()
  if not db then return end
  if InCombat() then
    stale = true
  else
    -- Kan fortsatt feile hvis klienten gjør buffene hemmelige utenom kamp.
    local ok, res, miss = pcall(Evaluate)
    if ok then
      results, missing, stale = res, miss, false
    else
      stale = true
    end
  end

  local m = CurrentMoment()
  if m ~= moment then
    moment = m
    if m then
      pulseUntil = GetTime() + PULSE_SECONDS
      if m:find("^confirm") and db.sound and missing > 0 then
        pcall(PlaySound, (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960, "Master")
      end
    end
  end

  UpdateIcon()
  UpdatePanel()
end

local function ListChanged()
  results = {}
  Refresh()
end

local function PlaceIcon()
  icon:ClearAllPoints()
  local p = db.point
  if p then
    icon:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  else
    icon:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -210, -40)
  end
end

------------------------------------------------------------------------
-- Legg til, fjern, flytt, juster
------------------------------------------------------------------------

local function Find(e)
  local k = Key(e)
  for i, x in ipairs(db.list) do
    if Key(x) == k then return i end
  end
end

local function Insert(e, pos)
  if Find(e) then
    Say(Describe(e) .. " står allerede på lista.")
    return
  end
  pos = math.max(1, math.min(pos or (#db.list + 1), #db.list + 1))
  table.insert(db.list, pos, e)
  ListChanged()
  return true
end

-- Legg til det du holder på musepekeren (dratt fra baggen, karakteren eller spellboken).
local function AddFromCursor(pos)
  local kind, a, b, c = GetCursorInfo()
  if not kind then return end
  local e, link
  if kind == "item" and a then
    link = b
    if IsEquippable(a) then
      e = { kind = "gear", id = a }
    else
      e = { kind = "item", id = a, need = 1 }
    end
  elseif kind == "spell" then
    local id = c
    if not id and a and GetSpellBookItemInfo then id = select(2, GetSpellBookItemInfo(a, b)) end
    if id and SpellInfo(id) then e = { kind = "buff", id = id, min = 0 } end
  end
  ClearCursor()
  if not e then
    Say("Bare ting fra baggen og spells fra spellboken kan legges på lista.")
    return
  end
  if Insert(e, pos) then
    Say((link or Describe(e)) .. " er lagt til – " .. Requirement(e) .. ".")
  end
end

-- Forslag: trinketene du har på deg og forbruksvarene i baggen (potions, mat, eliksirer, bandasjer,
-- gift, scrolls). Med «Vis alt» kommer resten av baggen også. Det som alt står på lista, hoppes over.
local CONSUMABLE = 0
local function Suggestions()
  local list, seen = {}, {}
  local function add(id, kind)
    if not id or seen[id] then return end
    seen[id] = true
    local e = { kind = kind, id = id, need = kind == "item" and 1 or nil }
    if not Find(e) then list[#list + 1] = e end
  end
  for _, slot in ipairs({ 13, 14 }) do
    add(GetInventoryItemID and GetInventoryItemID("player", slot), "gear")
  end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, NumSlots(bag) do
      local id = BagItemID(bag, slot)
      if id and (db.showAll or ItemClass(id) == CONSUMABLE) then
        add(id, IsEquippable(id) and "gear" or "item")
      end
    end
  end
  return list
end

local function AddEnchant(slot)
  if Insert({ kind = "enchant", slot = slot, min = 0 }) then
    Say("Gift/olje på våpenet i " .. SLOT_NAME[slot] .. " er lagt til.")
  end
end

local function Remove(i)
  local e = table.remove(db.list, i)
  if not e then return end
  lastRemoved = { e = e, pos = i }
  Say(Describe(e) .. " er fjernet. Skriv /klar angre for å få den tilbake.")
  ListChanged()
end

local function Move(from, to)
  if from == to or not db.list[from] or not db.list[to] then return end
  local e = table.remove(db.list, from)
  table.insert(db.list, to, e)
  ListChanged()
end

-- Musehjul på en rad: antall for ting i baggen, minutter igjen for buffer og gift.
local function Adjust(i, delta)
  local e = db.list[i]
  if not e or e.kind == "gear" then return end
  local step = (IsShiftKeyDown and IsShiftKeyDown()) and 5 or 1
  if e.kind == "item" then
    e.need = math.max(1, math.min(999, (e.need or 1) + delta * step))
  else
    e.min = math.max(0, math.min(180, (e.min or 0) + delta * step))
  end
  Refresh()
end

-- Høyreklikk på en rad: bytt mellom «antall i baggen» og «buffen fra den er på».
local function ToggleMode(i)
  local e = db.list[i]
  if not e then return end
  if e.kind == "item" and ItemSpell(e.id) then
    e.kind, e.min = "itembuff", e.min or 0
  elseif e.kind == "itembuff" then
    e.kind, e.need = "item", e.need or 1
  else
    return
  end
  Say(Describe(e) .. ": " .. Requirement(e) .. ".")
  ListChanged()
end

local function Snooze()
  if not moment then return end
  snoozed = moment
  Say("Greit – ikke mer lys før neste kø eller BG.")
  UpdateIcon()
end

------------------------------------------------------------------------
-- Vinduet med lista
------------------------------------------------------------------------

local panel, scroll, listChild, statusText, momentText, marker
local rows = {}
local dragFrom

local ghost = CreateFrame("Frame", nil, UIParent)
ghost:SetSize(28, 28)
ghost:SetFrameStrata("TOOLTIP")
ghost.tex = ghost:CreateTexture(nil, "ARTWORK")
ghost.tex:SetAllPoints()
ghost.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
ghost.text = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ghost.text:SetPoint("LEFT", ghost, "RIGHT", 6, 0)
ghost.text:SetTextColor(unpack(RED))
ghost:Hide()

local function HoveredRow()
  if not scroll or not scroll:IsMouseOver() then return end
  for i = 1, #db.list do
    local r = rows[i]
    if r and r:IsShown() and r:IsMouseOver() then return i end
  end
end

ghost:SetScript("OnUpdate", function(self)
  local x, y = GetCursorPosition()
  local s = UIParent:GetEffectiveScale()
  self:ClearAllPoints()
  self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)
  local inside = panel:IsMouseOver()
  self.text:SetText(inside and "" or "Slipp for å fjerne")
  self.tex:SetDesaturated(not inside)
  local t = inside and HoveredRow()
  if t and dragFrom and t ~= dragFrom then
    marker:ClearAllPoints()
    if t < dragFrom then
      marker:SetPoint("TOPLEFT", rows[t], "TOPLEFT", 0, 1)
    else
      marker:SetPoint("TOPLEFT", rows[t], "BOTTOMLEFT", 0, 1)
    end
    marker:Show()
  else
    marker:Hide()
  end
end)

local function BeginDrag(r)
  local e = db.list[r.index]
  if not e then return end
  dragFrom = r.index
  ghost.tex:SetTexture(select(2, Describe(e)))
  ghost.text:SetText("")
  r:SetAlpha(0.35)
  ghost:Show()
end

local function EndDrag(r)
  r:SetAlpha(1)
  if not dragFrom then return end
  local from = dragFrom
  dragFrom = nil
  ghost:Hide()
  marker:Hide()
  if not panel:IsMouseOver() then
    Remove(from)
  else
    local to = HoveredRow()
    if to then Move(from, to) end
  end
end

local function RowTooltip(self)
  local e = db.list[self.index]
  if not e or dragFrom then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if e.kind == "buff" and GameTooltip.SetSpellByID then
    GameTooltip:SetSpellByID(e.id)
  elseif e.id then
    GameTooltip:SetItemByID(e.id)
  else
    GameTooltip:SetText(Describe(e), 1, 1, 1)
  end
  GameTooltip:AddLine(" ")
  if e.kind == "item" then
    GameTooltip:AddLine("Musehjul: hvor mange du vil ha med (Shift = 5 om gangen)", 0.4, 0.8, 1)
    if ItemSpell(e.id) then GameTooltip:AddLine("Høyreklikk: sjekk heller at buffen er på", 0.4, 0.8, 1) end
  elseif e.kind ~= "gear" then
    GameTooltip:AddLine("Musehjul: minst så mange minutter igjen (Shift = 5)", 0.4, 0.8, 1)
    if e.kind == "itembuff" then GameTooltip:AddLine("Høyreklikk: sjekk heller antall i baggen", 0.4, 0.8, 1) end
  end
  GameTooltip:AddLine("Dra opp eller ned: bytt plass  ·  Dra ut av vinduet: fjern", GRAY[1], GRAY[2], GRAY[3])
  GameTooltip:Show()
end

local function Row(i)
  if rows[i] then return rows[i] end
  local r = CreateFrame("Button", nil, listChild)
  r:SetSize(LIST_W, ROW_H - 2)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r.index = i
  r:RegisterForDrag("LeftButton")
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r:EnableMouseWheel(true)

  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")

  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(24, 24)
  r.icon:SetPoint("LEFT", 4, 0)
  r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  r.status = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.status:SetPoint("RIGHT", -6, 0)
  r.status:SetJustifyH("RIGHT")

  r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.label:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, 0)
  r.label:SetPoint("RIGHT", r.status, "LEFT", -6, 0)
  r.label:SetJustifyH("LEFT")
  r.label:SetWordWrap(false)

  r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.sub:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 6, 0)
  r.sub:SetPoint("RIGHT", r.status, "LEFT", -6, 0)
  r.sub:SetJustifyH("LEFT")
  r.sub:SetWordWrap(false)

  r:SetScript("OnDragStart", BeginDrag)
  r:SetScript("OnDragStop", EndDrag)
  r:SetScript("OnReceiveDrag", function(self) AddFromCursor(self.index) end)
  r:SetScript("OnClick", function(self, button)
    if GetCursorInfo() then return AddFromCursor(self.index) end
    if button == "RightButton" then ToggleMode(self.index) end
  end)
  r:SetScript("OnMouseWheel", function(self, delta) Adjust(self.index, delta) end)
  r:SetScript("OnEnter", RowTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)

  rows[i] = r
  return r
end

local MAX_SUG, SUG_PER_ROW = 16, 8

local function SugButton(i)
  local b = CreateFrame("Button", nil, panel)
  b:SetSize(28, 28)
  local row, col = math.floor((i - 1) / SUG_PER_ROW), (i - 1) % SUG_PER_ROW
  b:SetPoint("BOTTOMLEFT", 16 + col * 32, 230 - row * 32)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  b.count:SetPoint("BOTTOMRIGHT", -1, 1)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnClick", function(self)
    local e = self.entry
    if not e then return end
    GameTooltip:Hide()
    if Insert({ kind = e.kind, id = e.id, need = e.need }) then
      Say(Describe(e) .. " er lagt til – " .. Requirement(e) .. ".")
    end
  end)
  b:SetScript("OnEnter", function(self)
    if not self.entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.entry.id)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Klikk: legg til – " .. Requirement(self.entry), 0.4, 0.8, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function UpdateSuggestions()
  local sugs = Suggestions()
  for i = 1, MAX_SUG do
    local e = sugs[i]
    local b = panel.sugg[i]
    if e and not b then
      b = SugButton(i)
      panel.sugg[i] = b
    end
    if b then
      b.entry = e
      if e then
        b.icon:SetTexture(ItemIcon(e.id))
        local n = ItemCount(e.id)
        b.count:SetText(n > 1 and n or "")
        b:Show()
      else
        b:Hide()
      end
    end
  end
  local text
  if #sugs == 0 then
    text = db.showAll and "Ingen forslag – alt i baggen er på lista." or "Ingen forslag – ingen forbruksvarer i baggen."
  elseif #sugs > MAX_SUG then
    text = string.format("Forslag – klikk for å legge til (%d av %d)", MAX_SUG, #sugs)
  else
    text = "Forslag – klikk for å legge til"
  end
  panel.sugTitle:SetText(text)
  panel.allBtn.text:SetText(db.showAll and "Bare forbruk" or "Vis alt")
end

function UpdatePanel()
  if not panel or not panel:IsShown() then return end
  local n = #db.list
  if n == 0 then
    statusText:SetText("Lista er tom – dra noe inn nedenfor.")
    statusText:SetTextColor(unpack(GRAY))
  elseif stale then
    statusText:SetText("I kamp – sjekker igjen når kampen er over.")
    statusText:SetTextColor(unpack(GRAY))
  elseif missing == 0 then
    statusText:SetText("Alt klart!")
    statusText:SetTextColor(unpack(GREEN))
  else
    statusText:SetText(string.format("Mangler %d av %d", missing, n))
    statusText:SetTextColor(unpack(RED))
  end
  momentText:SetText(MomentText(moment) or "Ingen kø eller BG nå – knappen holder seg rolig.")

  for i, e in ipairs(db.list) do
    local r = Row(i)
    local label, tex = Describe(e)
    r.icon:SetTexture(tex)
    r.label:SetText(label)
    r.sub:SetText(Requirement(e))
    local res = results[i]
    if not res then
      r.status:SetText("…")
      r.status:SetTextColor(unpack(GRAY))
      r.bg:SetColorTexture(1, 1, 1, 0.03)
    elseif res.ok then
      r.status:SetText(res.text)
      r.status:SetTextColor(unpack(GREEN))
      r.bg:SetColorTexture(0.3, 0.8, 0.3, 0.06)
    else
      r.status:SetText(res.text)
      r.status:SetTextColor(unpack(RED))
      r.bg:SetColorTexture(1, 0.3, 0.2, 0.12)
    end
    r:Show()
  end
  for i = n + 1, #rows do rows[i]:Hide() end
  listChild:SetHeight(math.max(1, n * ROW_H))
  UpdateSuggestions()
end

local function Checkbox(parent, y, text, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("BOTTOMLEFT", 14, y)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  fs:SetText(text)
  cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    Refresh()
  end)
  return cb
end

local function BuildPanel()
  local ok, f = pcall(CreateFrame, "Frame", "KlarsjekkPanel", UIParent, "BasicFrameTemplateWithInset")
  if not ok then
    f = CreateFrame("Frame", "KlarsjekkPanel2", UIParent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
  end
  f:SetSize(300, 580)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  tinsert(UISpecialFrames, f:GetName()) -- Esc lukker

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText("Klar-sjekk")

  statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusText:SetPoint("TOPLEFT", 16, -34)

  momentText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  momentText:SetPoint("TOPLEFT", 16, -52)

  scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -70)
  scroll:SetPoint("BOTTOMRIGHT", -32, 288)
  listChild = CreateFrame("Frame", nil, scroll)
  listChild:SetSize(LIST_W, 1)
  scroll:SetScrollChild(listChild)

  marker = listChild:CreateTexture(nil, "OVERLAY")
  marker:SetColorTexture(1, 0.82, 0, 0.9)
  marker:SetSize(LIST_W, 2)
  marker:Hide()

  -- Forslag fra baggen
  local sugTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sugTitle:SetPoint("BOTTOMLEFT", 16, 266)
  sugTitle:SetPoint("RIGHT", f, "RIGHT", -96, 0)
  sugTitle:SetJustifyH("LEFT")
  f.sugTitle = sugTitle
  local allBtn = CreateFrame("Button", nil, f)
  allBtn:SetSize(80, 16)
  allBtn:SetPoint("BOTTOMRIGHT", -16, 264)
  allBtn.text = allBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  allBtn.text:SetPoint("RIGHT")
  allBtn:SetScript("OnClick", function()
    db.showAll = not db.showAll
    UpdatePanel()
  end)
  f.allBtn = allBtn
  f.sugg = {}

  -- Slippfelt
  local drop = CreateFrame("Button", nil, f)
  drop:SetPoint("BOTTOMLEFT", 14, 140)
  drop:SetPoint("BOTTOMRIGHT", -14, 140)
  drop:SetHeight(48)
  local dbg = drop:CreateTexture(nil, "BACKGROUND")
  dbg:SetAllPoints()
  dbg:SetColorTexture(0.5, 0.82, 0.5, 0.18)
  local dtext = drop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dtext:SetPoint("CENTER")
  dtext:SetText("Dra en ting fra baggen eller en spell\nfra spellboken hit for å legge den til")
  drop:SetScript("OnReceiveDrag", function() AddFromCursor() end)
  drop:SetScript("OnClick", function() AddFromCursor() end)
  drop:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
  f.drop = drop

  -- Gift/olje kan ikke dras inn (den er ikke en ting på våpenet), så den har egne knapper.
  local mh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  mh:SetSize(132, 22)
  mh:SetPoint("BOTTOMLEFT", 14, 112)
  mh:SetText("+ Gift, hovedhånd")
  mh:SetScript("OnClick", function() AddEnchant(16) end)
  local oh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  oh:SetSize(132, 22)
  oh:SetPoint("BOTTOMRIGHT", -14, 112)
  oh:SetText("+ Gift, venstre hånd")
  oh:SetScript("OnClick", function() AddEnchant(17) end)
  f.enchantButtons = { mh, oh }

  f.flagCheck = Checkbox(f, 82, "Lys også når PvP-flagget er på (world PvP)",
    function() return db.flag end, function(v) db.flag = v end)
  f.soundCheck = Checkbox(f, 58, "Én lyd når køen spretter og noe mangler",
    function() return db.sound end, function(v) db.sound = v end)

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 16, 14)
  hint:SetPoint("BOTTOMRIGHT", -16, 14)
  hint:SetJustifyH("LEFT")
  hint:SetText("Musehjul på en rad: antall eller minutter.\nDra en rad ut av vinduet: fjern.  Høyreklikk: antall/buff.")

  f:SetScript("OnShow", UpdatePanel)
  f:SetScript("OnHide", function()
    -- Lukkes vinduet midt i et drag (Esc), avbrytes draget; ingenting fjernes.
    if dragFrom and rows[dragFrom] then rows[dragFrom]:SetAlpha(1) end
    dragFrom = nil
    ghost:Hide()
    marker:Hide()
  end)
  f:Hide()
  panel = f
end

-- Vinduet åpnes ved siden av knappen, mot midten av skjermen.
local function PlacePanel()
  panel:ClearAllPoints()
  local x, y = icon:GetCenter()
  local right = x and x > UIParent:GetWidth() / 2
  local top = y and y > UIParent:GetHeight() / 2
  local point = (top and "TOP" or "BOTTOM") .. (right and "RIGHT" or "LEFT")
  local rel = (top and "BOTTOM" or "TOP") .. (right and "LEFT" or "RIGHT")
  panel:SetPoint(point, icon, rel, right and -4 or 4, top and -4 or 4)
end

local function TogglePanel()
  if not panel then BuildPanel() end
  if panel:IsShown() then
    panel:Hide()
    return
  end
  PlacePanel()
  pulseUntil = 0 -- du har sett det: pulsen roer seg til et svakt lys
  panel:Show()
  Refresh()
end

------------------------------------------------------------------------
-- Knappens oppførsel
------------------------------------------------------------------------

icon:SetScript("OnDragStart", function(self) self:StartMoving() end)
icon:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, relPoint, x, y = self:GetPoint()
  db.point = { point, relPoint, x, y }
end)
icon:SetScript("OnReceiveDrag", function() AddFromCursor() end)
icon:SetScript("OnClick", function(_, button)
  if GetCursorInfo() then return AddFromCursor() end
  if button == "RightButton" then Snooze() else TogglePanel() end
end)
icon:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
  GameTooltip:SetText("Klar-sjekk", 1, 1, 1)
  local m = MomentText(moment)
  if m then GameTooltip:AddLine(m, 1, 0.82, 0) end
  if #db.list == 0 then
    GameTooltip:AddLine("Klikk for å lage lista di.", GRAY[1], GRAY[2], GRAY[3])
  elseif stale then
    GameTooltip:AddLine("I kamp – sjekker igjen etterpå.", GRAY[1], GRAY[2], GRAY[3])
  elseif missing == 0 then
    GameTooltip:AddLine("Alt klart!", GREEN[1], GREEN[2], GREEN[3])
  else
    for i, e in ipairs(db.list) do
      local res = results[i]
      if res and not res.ok then
        GameTooltip:AddDoubleLine(Describe(e), res.text, 1, 1, 1, RED[1], RED[2], RED[3])
      end
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Klikk: lista  ·  Dra: flytt knappen  ·  Høyreklikk: ikke nå", GRAY[1], GRAY[2], GRAY[3])
  GameTooltip:Show()
end)
icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

------------------------------------------------------------------------
-- Hendelser, lagring og kommandoer
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    KlarsjekkDB = KlarsjekkDB or {}
    db = KlarsjekkDB
    db.list = db.list or {}
    if db.flag == nil then db.flag = false end
    if db.sound == nil then db.sound = false end
    PlaceIcon()
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED",
      "UPDATE_BATTLEFIELD_STATUS", "ZONE_CHANGED_NEW_AREA", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
      "PLAYER_FLAGS_CHANGED", "GET_ITEM_INFO_RECEIVED", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
      pcall(self.RegisterEvent, self, e)
    end
    pcall(self.RegisterUnitEvent, self, "UNIT_AURA", "player")
    pcall(self.RegisterUnitEvent, self, "UNIT_INVENTORY_CHANGED", "player")
    C_Timer.NewTicker(1, Refresh)
    ns.db = db
    Refresh()
    return
  end
  Refresh()
end)

SLASH_KLARSJEKK1 = "/klar"
SLASH_KLARSJEKK2 = "/klarsjekk"
SlashCmdList.KLARSJEKK = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "test" then
    testUntil = GetTime() + PULSE_SECONDS + 10
    snoozed = nil
    Refresh()
    Say("Slik ser varselet ut: 30 sekunder rolig puls, så et svakt lys i 10 sekunder.")
  elseif msg == "reset" then
    db.point = nil
    PlaceIcon()
    Say("Knappen er flyttet tilbake.")
  elseif msg == "angre" then
    if not lastRemoved then return Say("Ingenting å angre.") end
    local r = lastRemoved
    lastRemoved = nil
    if Insert(r.e, r.pos) then Say(Describe(r.e) .. " er tilbake på lista.") end
  else
    TogglePanel()
  end
end

-- For testene
ns.icon = icon
ns.Refresh = Refresh
ns.TogglePanel = TogglePanel
ns.AddFromCursor = AddFromCursor
ns.state = function()
  return { missing = missing, glow = glowState, moment = moment, stale = stale, results = results,
           panel = panel, rows = rows, status = statusText, version = VERSION }
end
