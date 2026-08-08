-- /WIDGETS/RFBattmgr/RFBattmgr.lua (v6.7 -- Native 480x320 Resolution Redesign)
-- Battery Manager widget for RadioMaster / EdgeTX (480x320 fullscreen)

local name = "RFBattmgr"

local options = {
  { "Rem%", SOURCE, 1 }, { "Capa", SOURCE, 1 }, { "Volt", SOURCE, 1 }, { "Cell", SOURCE, 1 },
  { "Curr", SOURCE, 1 }, { "EscT", SOURCE, 1 }, { "RQly", SOURCE, 1 }, { "Bec",  SOURCE, 1 },
  { "MinCell", SOURCE, 1 }, { "MaxCurr", SOURCE, 1 }, { "MaxEscT", SOURCE, 1 }, { "MinRQly", SOURCE, 1 },
  { "GV_Select", VALUE, 8, 1, 9 }, { "TimerSrc", VALUE, 1, 1, 3 },
  { "ArmSrc", SOURCE, 1 }, { "RpmSrc", SOURCE, 1 }, { "ModeSrc", SOURCE, 1 }, { "BankSrc", SOURCE, 1 },
  { "Bank1_2", VALUE, -250, -1024, 1024 }, { "Bank2_3", VALUE, 250, -1024, 1024 },
  { "BkGround", COLOR, lcd.RGB(20,20,20) },
}

-- ===========================================================================
-- LOCALIZED ENV & API LOOKUPS
-- ===========================================================================
local getValue, getTime, getDateTime = getValue, getTime, getDateTime
local type, math, string, table, io  = type, math, string, table, io
local lcd, model = lcd, model
local SMALL, MEDIUM, BIG = SMLSIZE, MIDSIZE, DBLSIZE
local BOLD, CENTER, RIGHT = BOLD, CENTER, RIGHT

local lcdDrawText            = lcd.drawText
local lcdDrawFilledRectangle = lcd.drawFilledRectangle
local lcdDrawBitmap          = lcd.drawBitmap
local lcdClear               = lcd.clear

-- ===========================================================================
-- SAFE EDGETX API & NUMBER WRAPPERS
-- ===========================================================================
local function safeNum(v, default)
  return (type(v) == "number") and v or (default or 0)
end

local function safeGetValue(src, default)
  if src ~= nil then
    local val = getValue(src)
    if type(val) == "number" then return val end
  end
  return default or 0
end

local function safeOpenBitmap(path)
  if lcd and type(lcd.openBitmap) == "function" then
    local ok, bmp = pcall(lcd.openBitmap, path)
    if ok and bmp then return bmp end
  elseif Bitmap and type(Bitmap.open) == "function" then
    local ok, bmp = pcall(Bitmap.open, path)
    if ok and bmp then return bmp end
  end
  return nil
end

local function safeGetModelInfo()
  if model and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" then return info end
  end
  return nil
end

local function safeGetTimer(idx)
  if model and type(model.getTimer) == "function" then
    local ok, t = pcall(model.getTimer, idx)
    if ok and type(t) == "table" then return t end
  end
  return nil
end

local function safeGetGV(index, default)
  if model and type(model.getGlobalVariable) == "function" then
    local ok, val = pcall(model.getGlobalVariable, index, 0)
    if ok and type(val) == "number" then return val end
  end
  return safeNum(default, 0)
end

local function safeSetGV(index, val)
  if model and type(model.setGlobalVariable) == "function" then
    pcall(model.setGlobalVariable, index, 0, safeNum(val, 0))
  end
end

local function setScreen(widget, newScreen)
  widget.screen = newScreen
  widget.pendingBatteryIndex = nil
  widget.clickEvent = false
  widget.touchActive = true
  widget.lastClickTime = getTime()
  widget.showModelsModal = false
  widget.slotPickerModel = nil
end

-- ===========================================================================
-- COLORS
-- ===========================================================================
local C_NAVY   = lcd.RGB(23, 75, 114)
local C_BLUE   = lcd.RGB(0, 125, 207)
local C_GREY   = lcd.RGB(107, 114, 128)
local C_BLACK  = lcd.RGB(0, 0, 0)
local C_WHITE  = lcd.RGB(255, 255, 255)
local C_RED    = lcd.RGB(239, 68, 68)
local C_ORANGE = lcd.RGB(245, 158, 11)
local C_YELLOW = lcd.RGB(234, 179, 8)
local C_GREEN  = lcd.RGB(34, 197, 94)
local C_SLATE  = lcd.RGB(55, 65, 81)
local C_DKGREY = lcd.RGB(20, 20, 20)
local C_TEAL   = lcd.RGB(13, 148, 136)

local BTN_PRESS_MAP = {
  [C_BLUE]  = lcd.RGB(80, 170, 235),
  [C_GREY]  = lcd.RGB(150, 156, 165),
  [C_NAVY]  = lcd.RGB(45, 100, 145),
  [C_BLACK] = lcd.RGB(45, 45, 45),
  [C_RED]   = lcd.RGB(255, 110, 110),
  [C_TEAL]  = lcd.RGB(40, 185, 170),
}

-- ===========================================================================
-- CONSTANTS & KEYBOARD LAYOUT
-- ===========================================================================
local CONN_DEBOUNCE_FRAMES = 15
local PRESS_FLASH_FRAMES   = 4
local BATTERIES_PATH       = "/WIDGETS/RFBattmgr/batteries.lua"
local CLICK_COOLDOWN_TICKS = 40
local MIN_FLIGHT_TICKS     = 600

local FIXED_STEPS = { -1024, -614, -205, 205, 614, 1024 }
local function getMappedValue(i) return FIXED_STEPS[safeNum(i, 1)] or -1024 end
local function getIndexFromValue(val)
  val = safeNum(val, -1024)
  local idx, best = 1, math.abs(val - FIXED_STEPS[1])
  for i = 2, 6 do
    local d = math.abs(val - FIXED_STEPS[i])
    if d < best then best, idx = d, i end
  end
  return idx
end

local KEYBOARD_ROWS = {
  { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
  { "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" },
  { "A", "S", "D", "F", "G", "H", "J", "K", "L" },
  { "Z", "X", "C", "V", "B", "N", "M", "-", "_" },
}

local STR_SELECT_BATTERY = "SELECT BATTERY"
local STR_SUMMARY        = "POST-FLIGHT SUMMARY"
local STR_EDIT           = "EDIT BATTERIES"
local STR_CONFIRM        = "Confirm"
local STR_BACK           = "Back"
local STR_NO_IMAGE       = "[No Image]"
local STR_ARMED          = "ARMED"
local STR_DISARMED       = "DISARMED"
local STR_ENGINE_OFF     = "ENGINE OFF"
local STR_IDLE           = "IDLE"
local STR_BANK_1, STR_BANK_2, STR_BANK_3 = "BANK 1","BANK 2","BANK 3"
local STR_LOADING        = "Loading model profile..."
local STR_SAVED          = "Saved!"
local STR_SAVE_ERR       = "Save failed!"
local SUMMARY_LABELS = {
  "Model Name:","Flight Time:","Capacity Used:","Max ESC Temp:",
  "Max Current:","Min Cell Voltage:","Min Link Qly:",
}

-- ===========================================================================
-- HELPER FUNCTIONS & SLOT UNIQUE ENFORCEMENT
-- ===========================================================================
local function resolveModelName()
  if rawget(_G, "rf2") and type(rf2.modelName) == "string" and rf2.modelName ~= "" then
    return rf2.modelName
  end

  local info = safeGetModelInfo()
  local n = (info and type(info.name) == "string" and info.name ~= "") and info.name or "Unknown"

  if string.sub(n, 1, 1) == ">" then 
    n = string.sub(n, 2) 
  end

  return n
end

local function getBatterySlotForModel(profile, currentModel)
  if not profile or type(currentModel) ~= "string" or currentModel == "" then 
    return nil 
  end
  
  local lowCurrent = string.lower(currentModel)

  if type(profile.models) == "table" then
    for mName, slotNum in pairs(profile.models) do
      if mName ~= "" and string.find(lowCurrent, string.lower(mName), 1, true) then
        return safeNum(slotNum, 1)
      end
    end
  end

  if type(profile.model) == "string" and profile.model ~= "" then
    if string.find(lowCurrent, string.lower(profile.model), 1, true) then
      return 1
    end
  end

  return nil
end

local function getFilteredProfiles(modelName, src)
  src = src or {}
  local out = {}
  for i = 1, #src do
    local p = src[i]
    if p then
      local slot = getBatterySlotForModel(p, modelName)
      local isGlobal = (type(p.models) ~= "table" or next(p.models) == nil) and (not p.model or p.model == "")
      if slot or isGlobal then
        out[#out+1] = p
      end
    end
  end
  return #out == 0 and src or out
end

local function getFailsafeGVValue(profile, currentModel, fallbackIndex)
  local slot = getBatterySlotForModel(profile, currentModel)
  if not slot or slot < 1 or slot > 6 then
    slot = safeNum(fallbackIndex, 1)
  end
  return getMappedValue(slot)
end

local function assignModelSlot(allProfiles, targetProfile, modelName, desiredSlot)
  if not modelName or modelName == "" or not targetProfile then return end
  desiredSlot = safeNum(desiredSlot, 1)
  if desiredSlot < 1 then desiredSlot = 1 end
  if desiredSlot > 6 then desiredSlot = 6 end

  if type(allProfiles) == "table" then
    for i = 1, #allProfiles do
      local p = allProfiles[i]
      if p and type(p.models) == "table" then
        if p.models[modelName] == desiredSlot then
          p.models[modelName] = nil
        end
      end
    end
  end

  targetProfile.models = targetProfile.models or {}
  targetProfile.models[modelName] = desiredSlot
end

local function getNextFreeSlot(allProfiles, modelName)
  local used = {}
  if type(allProfiles) == "table" then
    for i = 1, #allProfiles do
      local p = allProfiles[i]
      if p and type(p.models) == "table" and p.models[modelName] then
        used[p.models[modelName]] = true
      end
    end
  end
  for slot = 1, 6 do
    if not used[slot] then return slot end
  end
  return 1
end

local function getUsedSlotsForModel(allProfiles, modelName, currentProfile)
  local used = {}
  if type(allProfiles) == "table" and type(modelName) == "string" and modelName ~= "" then
    for i = 1, #allProfiles do
      local p = allProfiles[i]
      if p and p ~= currentProfile and type(p.models) == "table" then
        local slot = safeNum(p.models[modelName], 0)
        if slot >= 1 and slot <= 6 then
          used[slot] = true
        end
      end
    end
  end
  return used
end

local function deepCopyProfiles(src)
  src = src or {}
  local out = {}
  for i = 1, #src do
    local item = src[i] or {}
    local mCopy = {}
    if type(item.models) == "table" then
      for k, v in pairs(item.models) do mCopy[k] = safeNum(v, 1) end
    elseif type(item.model) == "string" and item.model ~= "" then
      mCopy[item.model] = 1
    end
    out[i] = { 
      name = item.name or "Battery", 
      cap = safeNum(item.cap, 1000), 
      models = mCopy,
      flights = safeNum(item.flights, 0)
    }
  end
  return out
end

local function saveProfilesToSD(profiles)
  profiles = profiles or {}
  local f = io.open(BATTERIES_PATH, "w")
  if not f then return false end
  
  io.write(f, "return {\n")
  for i = 1, #profiles do
    local p = profiles[i] or {}
    local eName = string.gsub(p.name or "", '"', '\\"')
    
    io.write(f, string.format('  { name="%s", cap=%d, flights=%d, models={ ', 
      eName, math.floor(safeNum(p.cap, 0)), math.floor(safeNum(p.flights, 0))))

    if type(p.models) == "table" then
      local first = true
      for mName, slotNum in pairs(p.models) do
        local eModel = string.gsub(mName or "", '"', '\\"')
        if not first then io.write(f, ", ") end
        io.write(f, string.format('["%s"]=%d', eModel, math.floor(safeNum(slotNum, 1))))
        first = false
      end
    end

    io.write(f, " } },\n")
  end
  io.write(f, "}\n")
  io.close(f)
  return true
end

-- ===========================================================================
-- DRAW HELPERS & TOUCH DETECTION
-- ===========================================================================
local function roundRect(x, y, w, h, r, color)
  x, y, w, h = safeNum(x, 0), safeNum(y, 0), safeNum(w, 0), safeNum(h, 0)
  r = safeNum(r, 0)
  color = color or C_WHITE
  if r > 0 then
    lcdDrawFilledRectangle(x + 1, y, w - 2, h, color)
    lcdDrawFilledRectangle(x, y + 1, w, h - 2, color)
  else
    lcdDrawFilledRectangle(x, y, w, h, color)
  end
end

local function pctColor(p)
  p = safeNum(p, 0)
  if p <= 10 then return C_RED 
  elseif p <= 40 then return C_ORANGE
  elseif p <= 80 then return C_YELLOW 
  else return C_GREEN end
end

local function drawBattBar(x, y, w, h, pct, fillColor)
  pct = safeNum(pct, 0)
  roundRect(x, y, w, h, 4, C_SLATE)
  local fw = math.floor(safeNum(w, 0) * (math.max(0, math.min(100, pct)) / 100))
  if fw > 4 then roundRect(x, y, fw, h, fillColor or pctColor(pct)) end
end

local function drawTxBar(x, y, w, h, pct)
  pct = safeNum(pct, 100)
  lcdDrawFilledRectangle(x, y, w, h, C_SLATE)
  local fw = math.floor(w * (math.max(0, math.min(100, pct)) / 100))
  if fw > 0 then
    lcdDrawFilledRectangle(x, y, fw, h, pctColor(pct))
  end
end

local function rqlyIconIndex(v)
  v = safeNum(v, 0)
  if v>=95 then return 4 elseif v>=80 then return 3
  elseif v>=60 then return 2 elseif v>=30 then return 1 else return 0 end
end

local function isBtnPressed(w, tx, ty, ce, x, y, bw, bh, slop)
  if not ce or not w then return false end
  tx, ty = safeNum(tx, -1), safeNum(ty, -1)
  x, y, bw, bh = safeNum(x, 0), safeNum(y, 0), safeNum(bw, 0), safeNum(bh, 0)
  slop = safeNum(slop, 2)
  
  if tx >= (x - slop) and tx <= (x + bw + slop) and ty >= (y - slop) and ty <= (y + bh + slop) then
    w.flashRect = { x = x, y = y, w = bw, h = bh }
    w.flashTimer = PRESS_FLASH_FRAMES
    return true
  end
  return false
end

local function btnColor(w, x, y, bw, bh, base)
  if not w then return base end
  local f = w.flashRect
  if safeNum(w.flashTimer, 0) > 0 and f and f.x==x and f.y==y and f.w==bw and f.h==bh then
    return BTN_PRESS_MAP[base] or base
  end
  return base
end

-- ===========================================================================
-- TELEMETRY GRID LAYOUT
-- ===========================================================================
local TELEM_LAYOUT = {
  {key="volt",col=1,row=1},{key="cell",col=1,row=2},
  {key="temp",col=2,row=1},{key="curr",col=2,row=2},
  {key="bec", col=3,row=1},{key="rqly",col=3,row=2},
}
local RQLY_ICON_FILES={"icon_40_0.png","icon_40_1.png","icon_40_2.png","icon_40_3.png","icon_40_4.png"}
local ICON_DIR = "/WIDGETS/"..name.."/icons/"

-- ===========================================================================
-- TOUCH KEYBOARD MODAL
-- ===========================================================================
local function drawKeyboardModal(widget, zx, zy, tx, ty, clickEvent)
  widget.keyboardBuffer = widget.keyboardBuffer or ""
  local field = widget.editingField or "name"

  local title = "EDIT BATTERY NAME"
  if field == "cap" then title = "EDIT CAPACITY (mAh)"
  elseif field == "model" then title = "ADD MODEL LOCK"
  elseif field == "flights" then title = "EDIT FLIGHT COUNT" end

  roundRect(zx, zy, 480, 320, 0, C_DKGREY)
  roundRect(zx, zy, 480, 38, 0, C_NAVY)
  lcdDrawText(zx+12, zy+5, title, BIG+C_WHITE)

  roundRect(zx+10, zy+44, 460, 36, 4, C_BLACK)
  lcdDrawText(zx+20, zy+48, (widget.keyboardBuffer or "") .. "_", MEDIUM+C_WHITE)

  local startY = zy + 88
  local keyH, gap = 34, 4

  for rIdx, row in ipairs(KEYBOARD_ROWS) do
    local keyW = (#row == 10) and 44 or 48
    local rowW = #row * keyW + (#row - 1) * gap
    local startX = zx + math.floor((480 - rowW) / 2)
    local kY = startY + (rIdx - 1) * (keyH + gap)

    for cIdx, char in ipairs(row) do
      local kX = startX + (cIdx - 1) * (keyW + gap)
      if isBtnPressed(widget, tx, ty, clickEvent, kX, kY, keyW, keyH, 2) then
        if #widget.keyboardBuffer < 18 then
          widget.keyboardBuffer = widget.keyboardBuffer .. char
        end
        clickEvent = false
      end
      roundRect(kX, kY, keyW, keyH, 4, btnColor(widget, kX, kY, keyW, keyH, C_SLATE))
      lcdDrawText(kX + keyW/2, kY + 7, char, SMALL+CENTER+C_WHITE)
    end
  end

  local actY = zy + 256
  local actH = 54

  local bsX, bsW = zx + 8, 84
  if isBtnPressed(widget, tx, ty, clickEvent, bsX, actY, bsW, actH, 2) then
    if #widget.keyboardBuffer > 0 then
      widget.keyboardBuffer = string.sub(widget.keyboardBuffer, 1, -2)
    end
    clickEvent = false
  end
  roundRect(bsX, actY, bsW, actH, 4, btnColor(widget, bsX, actY, bsW, actH, C_ORANGE))
  lcdDrawText(bsX + bsW/2, actY + 16, "< Back", SMALL+CENTER+C_WHITE)

  local spX, spW = bsX + bsW + 6, 96
  if isBtnPressed(widget, tx, ty, clickEvent, spX, actY, spW, actH, 2) then
    if #widget.keyboardBuffer < 18 then
      widget.keyboardBuffer = widget.keyboardBuffer .. " "
    end
    clickEvent = false
  end
  roundRect(spX, actY, spW, actH, 4, btnColor(widget, spX, actY, spW, actH, C_SLATE))
  lcdDrawText(spX + spW/2, actY + 16, "Space", SMALL+CENTER+C_WHITE)

  local clrX, clrW = spX + spW + 6, 76
  if isBtnPressed(widget, tx, ty, clickEvent, clrX, actY, clrW, actH, 2) then
    widget.keyboardBuffer = ""
    clickEvent = false
  end
  roundRect(clrX, actY, clrW, actH, 4, btnColor(widget, clrX, actY, clrW, actH, C_RED))
  lcdDrawText(clrX + clrW/2, actY + 16, "Clear", SMALL+CENTER+C_WHITE)

  local okX, okW = clrX + clrW + 6, 104
  if isBtnPressed(widget, tx, ty, clickEvent, okX, actY, okW, actH, 2) then
    if widget.editProfiles and widget.editSelected then
      local target = widget.editProfiles[widget.editSelected]
      if target then
        if field == "name" then
          target.name = (widget.keyboardBuffer ~= "") and widget.keyboardBuffer or "Battery"
        elseif field == "cap" then
          local num = tonumber(widget.keyboardBuffer) or target.cap or 2200
          target.cap = math.max(0, math.floor(num))
        elseif field == "model" then
          if widget.keyboardBuffer ~= "" then
            local mName = widget.keyboardBuffer
            target.models = target.models or {}
            local freeSlot = getNextFreeSlot(widget.editProfiles, mName)
            assignModelSlot(widget.editProfiles, target, mName, freeSlot)
          end
        elseif field == "flights" then
          local num = tonumber(widget.keyboardBuffer) or target.flights or 0
          target.flights = math.max(0, math.floor(num))
        end
      end
    end
    widget.editingField = nil
    clickEvent = false
  end
  roundRect(okX, actY, okW, actH, 4, btnColor(widget, okX, actY, okW, actH, C_TEAL))
  lcdDrawText(okX + okW/2, actY + 14, "Done", MEDIUM+CENTER+C_WHITE)

  local canX, canW = okX + okW + 6, 86
  if isBtnPressed(widget, tx, ty, clickEvent, canX, actY, canW, actH, 2) then
    widget.editingField = nil
    clickEvent = false
  end
  roundRect(canX, actY, canW, actH, 4, btnColor(widget, canX, actY, canW, actH, C_GREY))
  lcdDrawText(canX + canW/2, actY + 16, "Cancel", SMALL+CENTER+C_WHITE)

  return clickEvent
end

-- ===========================================================================
-- MODELS MANAGEMENT MODAL & NUMBER PICKER
-- ===========================================================================
local function drawModelsModal(widget, zx, zy, tx, ty, clickEvent)
  local selIdx = safeNum(widget.editSelected, 1)
  local eps = widget.editProfiles or {}
  local sel = eps[selIdx]
  if not sel then
    widget.showModelsModal = false
    return clickEvent
  end

  sel.models = sel.models or {}

  -- Sub-Modal: Change Model-Specific Battery Number Slot
  if widget.slotPickerModel then
    local mName = widget.slotPickerModel
    local popW, popH = 340, 220
    local popX = zx + math.floor((480 - popW) / 2)
    local popY = zy + math.floor((320 - popH) / 2)

    roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_TEAL)
    roundRect(popX, popY, popW, popH, 6, C_DKGREY)
    roundRect(popX, popY, popW, 36, 6, C_NAVY)

    local titleStr = "CHANGE NUMBER: " .. mName
    if #titleStr > 25 then titleStr = string.sub(titleStr, 1, 23) .. ".." end
    lcdDrawText(popX + popW/2, popY + 6, titleStr, SMALL+CENTER+C_WHITE)

    lcdDrawText(popX + popW/2, popY + 45, "Select Battery Number (1-6):", SMALL+CENTER+C_WHITE)

    local used = getUsedSlotsForModel(widget.editProfiles, mName, sel)
    local curSlot = safeNum(sel.models[mName], 1)

    local btnW, btnH = 80, 40
    local startX = popX + 25
    local startY = popY + 75

    for slot = 1, 6 do
      local row = (slot > 3) and 2 or 1
      local col = ((slot - 1) % 3) + 1
      local bx = startX + (col - 1) * (btnW + 15)
      local by = startY + (row - 1) * (btnH + 10)

      local isUsed = (used[slot] == true)
      local isCurrent = (slot == curSlot)

      if isUsed then
        roundRect(bx, by, btnW, btnH, 4, C_DKGREY)
        lcdDrawFilledRectangle(bx, by, btnW, btnH, C_SLATE)
        lcdDrawText(bx + btnW/2, by + 10, "#" .. slot .. " (Used)", SMALL+CENTER+C_GREY)
      elseif isCurrent then
        roundRect(bx, by, btnW, btnH, 4, C_TEAL)
        lcdDrawText(bx + btnW/2, by + 10, "#" .. slot, MEDIUM+CENTER+C_WHITE)
      else
        if isBtnPressed(widget, tx, ty, clickEvent, bx, by, btnW, btnH) then
          assignModelSlot(widget.editProfiles, sel, mName, slot)
          widget.slotPickerModel = nil
          clickEvent = false
        end
        roundRect(bx, by, btnW, btnH, 4, btnColor(widget, bx, by, btnW, btnH, C_BLUE))
        lcdDrawText(bx + btnW/2, by + 10, "#" .. slot, MEDIUM+CENTER+C_WHITE)
      end
    end

    local canX, canY, canW, canH = popX + math.floor((popW - 100) / 2), popY + 175, 100, 32
    if isBtnPressed(widget, tx, ty, clickEvent, canX, canY, canW, canH) then
      widget.slotPickerModel = nil
      clickEvent = false
    end
    roundRect(canX, canY, canW, canH, 4, btnColor(widget, canX, canY, canW, canH, C_GREY))
    lcdDrawText(canX + canW/2, canY + 6, "Cancel", SMALL+CENTER+C_WHITE)

    return clickEvent
  end

  -- Main Models Pop-Up Modal
  local popW, popH = 440, 270
  local popX = zx + math.floor((480 - popW) / 2)
  local popY = zy + math.floor((320 - popH) / 2)

  roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_NAVY)
  roundRect(popX, popY, popW, popH, 6, C_DKGREY)
  roundRect(popX, popY, popW, 36, 6, C_NAVY)

  local headTitle = "MODELS FOR: " .. (sel.name or "Battery")
  if #headTitle > 30 then headTitle = string.sub(headTitle, 1, 28) .. ".." end
  lcdDrawText(popX + 15, popY + 6, headTitle, MEDIUM+C_WHITE)

  local modelList = {}
  for mName, sNum in pairs(sel.models) do
    modelList[#modelList + 1] = { name = mName, slot = safeNum(sNum, 1) }
  end
  table.sort(modelList, function(a, b) return a.name < b.name end)

  local listY = popY + 45
  local itemH = 34

  if #modelList == 0 then
    lcdDrawText(popX + popW/2, popY + 95, "No models assigned (Global Battery)", SMALL+CENTER+C_GREY)
  else
    for i = 1, math.min(4, #modelList) do
      local item = modelList[i]
      local iy = listY + (i - 1) * (itemH + 4)

      roundRect(popX + 10, iy, popW - 20, itemH, 4, C_SLATE)

      local mDisp = item.name
      if #mDisp > 16 then mDisp = string.sub(mDisp, 1, 14) .. ".." end
      lcdDrawText(popX + 20, iy + 7, mDisp, SMALL+C_WHITE)

      -- Change Number Slot Button
      local numBtnX = popX + 210
      local numBtnW = 105
      if isBtnPressed(widget, tx, ty, clickEvent, numBtnX, iy + 3, numBtnW, itemH - 6) then
        widget.slotPickerModel = item.name
        clickEvent = false
      end
      roundRect(numBtnX, iy + 3, numBtnW, itemH - 6, 4, btnColor(widget, numBtnX, iy + 3, numBtnW, itemH - 6, C_BLUE))
      lcdDrawText(numBtnX + numBtnW/2, iy + 7, "Num: #" .. item.slot, SMALL+CENTER+C_WHITE)

      -- Delete Model Assignment Button
      local delBtnX = popX + 325
      local delBtnW = 85
      if isBtnPressed(widget, tx, ty, clickEvent, delBtnX, iy + 3, delBtnW, itemH - 6) then
        sel.models[item.name] = nil
        clickEvent = false
      end
      roundRect(delBtnX, iy + 3, delBtnW, itemH - 6, 4, btnColor(widget, delBtnX, iy + 3, delBtnW, itemH - 6, C_RED))
      lcdDrawText(delBtnX + delBtnW/2, iy + 7, "Delete", SMALL+CENTER+C_WHITE)
    end
  end

  -- Action Buttons
  local bY = popY + 220
  local bH = 38

  local addCurX, addCurW = popX + 10, 130
  if isBtnPressed(widget, tx, ty, clickEvent, addCurX, bY, addCurW, bH) then
    if widget.cachedModelName and widget.cachedModelName ~= "" then
      local freeSlot = getNextFreeSlot(widget.editProfiles, widget.cachedModelName)
      assignModelSlot(widget.editProfiles, sel, widget.cachedModelName, freeSlot)
    end
    clickEvent = false
  end
  roundRect(addCurX, bY, addCurW, bH, 4, btnColor(widget, addCurX, bY, addCurW, bH, C_TEAL))
  lcdDrawText(addCurX + addCurW/2, bY + 10, "+ Set Current", SMALL+CENTER+C_WHITE)

  local addNewX, addNewW = addCurX + addCurW + 8, 130
  if isBtnPressed(widget, tx, ty, clickEvent, addNewX, bY, addNewW, bH) then
    widget.keyboardBuffer = ""
    widget.editingField = "model"
    clickEvent = false
  end
  roundRect(addNewX, bY, addNewW, bH, 4, btnColor(widget, addNewX, bY, addNewW, bH, C_BLUE))
  lcdDrawText(addNewX + addNewW/2, bY + 10, "+ Add Model", SMALL+CENTER+C_WHITE)

  local closeX, closeW = addNewX + addNewW + 8, 134
  if isBtnPressed(widget, tx, ty, clickEvent, closeX, bY, closeW, bH) then
    widget.showModelsModal = false
    clickEvent = false
  end
  roundRect(closeX, bY, closeW, bH, 4, btnColor(widget, closeX, bY, closeW, bH, C_GREY))
  lcdDrawText(closeX + closeW/2, bY + 10, "Close", MEDIUM+CENTER+C_WHITE)

  return clickEvent
end

-- ===========================================================================
-- EDITOR SCREEN
-- ===========================================================================
local ED_LIST_X  = 10
local ED_LIST_W  = 140
local ED_ITEM_H  = 38
local ED_VISIBLE = 5
local ED_PANEL_X = 160

local function enterEditScreen(widget)
  widget.editProfiles   = deepCopyProfiles(widget.allProfiles)
  widget.editSelected   = 1
  widget.editScrollOff  = 0
  widget.editStatusMsg  = ""
  widget.editStatusEnd  = 0
  widget.editingField   = nil
  widget.keyboardBuffer = ""
  widget.showModelsModal = false
  widget.slotPickerModel = nil
  setScreen(widget, "edit")
end

local function drawEditScreen(widget, opts, zx, zy, tx, ty, clickEvent)
  if widget.editingField then
    return drawKeyboardModal(widget, zx, zy, tx, ty, clickEvent)
  end

  if widget.showModelsModal then
    return drawModelsModal(widget, zx, zy, tx, ty, clickEvent)
  end

  local eps    = widget.editProfiles or {}
  local selIdx = safeNum(widget.editSelected, 1)
  local scr    = safeNum(widget.editScrollOff, 0)

  roundRect(zx, zy, 480, 36, 0, C_NAVY)
  lcdDrawText(zx+12, zy+4, STR_EDIT, BIG+C_WHITE)

  local listTopY = zy + 40

  if scr > 0 then
    local ux, uy, uw, uh = zx+ED_LIST_X, listTopY, ED_LIST_W, 20
    if isBtnPressed(widget, tx, ty, clickEvent, ux, uy, uw, uh) then
      widget.editScrollOff = math.max(0, scr - 1)
      clickEvent = false
    end
    roundRect(ux, uy, uw, uh, 3, btnColor(widget, ux, uy, uw, uh, C_BLUE))
    lcdDrawText(ux+uw/2, uy+2, "^ UP", SMALL+CENTER+C_WHITE)
    listTopY = listTopY + 22
  end

  local drawnCount = 0
  for vi = 1, ED_VISIBLE do
    local i = vi + scr
    if i > #eps then break end
    local b = eps[i]
    if b then
      drawnCount = drawnCount + 1
      local iy = listTopY + (vi - 1) * ED_ITEM_H
      local iw, ih = ED_LIST_W, ED_ITEM_H - 3
      if isBtnPressed(widget, tx, ty, clickEvent, zx+ED_LIST_X, iy, iw, ih) then
        widget.editSelected = i
        clickEvent = false
      end
      local base = (i == selIdx) and C_NAVY or C_SLATE
      roundRect(zx+ED_LIST_X, iy, iw, ih, 4, btnColor(widget, zx+ED_LIST_X, iy, iw, ih, base))
      local dn = b.name or "Battery"
      if #dn > 18 then dn = string.sub(dn, 1, 17) .. "~" end
      lcdDrawText(zx+ED_LIST_X+5, iy+2,  dn, SMALL+C_WHITE)
      lcdDrawText(zx+ED_LIST_X+5, iy+18, safeNum(b.cap, 0) .. " mAh", SMALL+C_WHITE)
    end
  end

  if (#eps > scr + ED_VISIBLE) then
    local dy = listTopY + drawnCount * ED_ITEM_H
    local dx, dw, dh = zx+ED_LIST_X, ED_LIST_W, 20
    if isBtnPressed(widget, tx, ty, clickEvent, dx, dy, dw, dh) then
      widget.editScrollOff = math.min(#eps - ED_VISIBLE, scr + 1)
      clickEvent = false
    end
    roundRect(dx, dy, dw, dh, 3, btnColor(widget, dx, dy, dw, dh, C_BLUE))
    lcdDrawText(dx+dw/2, dy+2, "v DOWN", SMALL+CENTER+C_WHITE)
  end

  local actY = zy + 270
  local aW   = 66
  local adX  = zx + ED_LIST_X

  if isBtnPressed(widget, tx, ty, clickEvent, adX, actY, aW, 42) then
    eps[#eps+1] = { name="Batt "..(#eps+1), cap=2200, models={}, flights=0 }
    widget.editSelected = #eps
    if #eps > ED_VISIBLE then widget.editScrollOff = #eps - ED_VISIBLE end
    clickEvent = false
  end
  roundRect(adX, actY, aW, 42, 4, btnColor(widget, adX, actY, aW, 42, C_TEAL))
  lcdDrawText(adX+aW/2, actY+12, "+ Add", SMALL+CENTER+C_WHITE)

  if #eps > 1 then
    local dlX = adX + aW + 8
    if isBtnPressed(widget, tx, ty, clickEvent, dlX, actY, aW, 42) then
      table.remove(eps, selIdx)
      widget.editSelected  = math.max(1, selIdx - 1)
      widget.editScrollOff = math.max(0, math.min(scr, #eps - ED_VISIBLE))
      clickEvent = false
    end
    roundRect(dlX, actY, aW, 42, 4, btnColor(widget, dlX, actY, aW, 42, C_RED))
    lcdDrawText(dlX+aW/2, actY+12, "Delete", SMALL+CENTER+C_WHITE)
  end

  lcdDrawFilledRectangle(zx+ED_PANEL_X, zy+38, 2, 278, C_SLATE)

  local sel = eps[selIdx]
  if sel then
    local px = zx + ED_PANEL_X + 12
    local pw = 480 - (ED_PANEL_X + 12) - 12

    roundRect(px, zy+40, pw, 32, 4, C_SLATE)
    local displayName = sel.name or "Battery"
    if #displayName > 20 then displayName = string.sub(displayName, 1, 19) .. "~" end
    lcdDrawText(px+8, zy+44, displayName, MEDIUM+C_WHITE)

    lcdDrawText(px, zy+82, "Name", SMALL+C_WHITE)
    local nBtnX, nBtnY, nBtnW, nBtnH = px + 60, zy+78, pw - 60, 28
    if isBtnPressed(widget, tx, ty, clickEvent, nBtnX, nBtnY, nBtnW, nBtnH) then
      widget.keyboardBuffer = sel.name or "Battery"
      widget.editingField = "name"
      clickEvent = false
    end
    roundRect(nBtnX, nBtnY, nBtnW, nBtnH, 4, btnColor(widget, nBtnX, nBtnY, nBtnW, nBtnH, C_BLUE))
    lcdDrawText(nBtnX + nBtnW/2, nBtnY + 5, "Edit Name", SMALL+CENTER+C_WHITE)

    lcdDrawText(px, zy+116, "Cap: " .. (sel.cap or 2200) .. "mAh", SMALL+C_GREY)
    local cBtnX, cBtnY, cBtnW, cBtnH = px + 140, zy+112, pw - 140, 28
    if isBtnPressed(widget, tx, ty, clickEvent, cBtnX, cBtnY, cBtnW, cBtnH) then
      widget.keyboardBuffer = tostring(sel.cap or 2200)
      widget.editingField = "cap"
      clickEvent = false
    end
    roundRect(cBtnX, cBtnY, cBtnW, cBtnH, 4, btnColor(widget, cBtnX, cBtnY, cBtnW, cBtnH, C_TEAL))
    lcdDrawText(cBtnX + cBtnW/2, cBtnY + 5, "Edit Capacity", SMALL+CENTER+C_WHITE)

    lcdDrawText(px, zy+150, "Flt: " .. (sel.flights or 0), SMALL+C_GREY)
    local fBtnX, fBtnY, fBtnW, fBtnH = px + 140, zy+146, pw - 140, 28
    if isBtnPressed(widget, tx, ty, clickEvent, fBtnX, fBtnY, fBtnW, fBtnH) then
      widget.keyboardBuffer = tostring(sel.flights or 0)
      widget.editingField = "flights"
      clickEvent = false
    end
    roundRect(fBtnX, fBtnY, fBtnW, fBtnH, 4, btnColor(widget, fBtnX, fBtnY, fBtnW, fBtnH, C_ORANGE))
    lcdDrawText(fBtnX + fBtnW/2, fBtnY + 5, "Edit Flights", SMALL+CENTER+C_WHITE)

    sel.models = sel.models or {}
    local mCount = 0
    for _ in pairs(sel.models) do mCount = mCount + 1 end
    local mInfoStr = (mCount == 0) and "Models: Global (All models)" or ("Models: " .. mCount .. " assigned")
    lcdDrawText(px, zy+184, mInfoStr, SMALL+C_GREY)

    -- Models Pop-Up Trigger Button
    local mBtnX, mBtnY, mBtnW, mBtnH = px, zy+208, pw, 36
    if isBtnPressed(widget, tx, ty, clickEvent, mBtnX, mBtnY, mBtnW, mBtnH) then
      widget.showModelsModal = true
      clickEvent = false
    end
    roundRect(mBtnX, mBtnY, mBtnW, mBtnH, 4, btnColor(widget, mBtnX, mBtnY, mBtnW, mBtnH, C_BLUE))
    lcdDrawText(mBtnX + mBtnW/2, mBtnY + 8, "Models", MEDIUM+CENTER+C_WHITE)
  end

  local savY = zy + 270
  local savX = zx + ED_PANEL_X + 12
  local savW = math.floor((480 - (ED_PANEL_X + 12) - 18) / 2)
  local canX = savX + savW + 12
  local canW = savW

  if isBtnPressed(widget, tx, ty, clickEvent, savX, savY, savW, 42) then
    local ok = saveProfilesToSD(widget.editProfiles)
    if ok then
      widget.allProfiles  = deepCopyProfiles(widget.editProfiles)
      widget.profiles     = getFilteredProfiles(widget.cachedModelName, widget.allProfiles)
      widget.batteryIndex = math.max(1, math.min(safeNum(widget.batteryIndex, 1), #widget.profiles))
      widget.editStatusMsg = STR_SAVED
    else
      widget.editStatusMsg = STR_SAVE_ERR
    end
    widget.editStatusEnd = getTime() + 300
    clickEvent = false
  end
  roundRect(savX, savY, savW, 42, 4, btnColor(widget, savX, savY, savW, 42, C_TEAL))
  lcdDrawText(savX+savW/2, savY+10, "Save", MEDIUM+CENTER+C_WHITE)

  if isBtnPressed(widget, tx, ty, clickEvent, canX, savY, canW, 42) then
    widget.editProfiles = nil
    setScreen(widget, "flight")
    clickEvent = false
  end
  roundRect(canX, savY, canW, 42, 4, btnColor(widget, canX, savY, canW, 42, C_GREY))
  lcdDrawText(canX+canW/2, savY+10, "BACK", MEDIUM+CENTER+C_WHITE)

  if widget.editStatusMsg and widget.editStatusMsg ~= "" then
    if getTime() < safeNum(widget.editStatusEnd, 0) then
      local err = (widget.editStatusMsg == STR_SAVE_ERR)
      local tX, tY, tW, tH = zx + 180, zy + 225, 120, 28
      roundRect(tX, tY, tW, tH, 4, err and C_RED or C_TEAL)
      lcdDrawText(tX+tW/2, tY+5, widget.editStatusMsg, SMALL+CENTER+C_WHITE)
    else
      widget.editStatusMsg = ""
    end
  end

  return clickEvent
end

-- ===========================================================================
-- FLIGHT SCREEN
-- ===========================================================================
local function drawFlightScreen(widget, opts, zx, zy, tx, ty, clickEvent)
  local tick = safeNum(widget.tick, 0)
  local v    = widget.vals or {}
  local s    = widget.strs or {}

  if widget.bgBmp then
    lcdDrawBitmap(widget.bgBmp, zx, zy)
  else
    roundRect(zx, zy, 480, 36, 0, C_NAVY)
  end

  lcdDrawText(zx+3, zy, widget.cachedModelName or "", BIG+C_WHITE)

  if tick % 20 == 0 or not s.clock or s.clock == "" then
    local dt = getDateTime and getDateTime() or nil
    if dt then s.clock = string.format("%02d:%02d", safeNum(dt.hour, 0), safeNum(dt.min, 0)) end
  end
  lcdDrawText(zx+441, zy+11, s.clock or "", SMALL+C_WHITE)

  if tick % 120 == 0 or safeNum(v.txVolt, -1) == -1 then
    local txV = safeGetValue("tx-voltage", 0)
    local minV = safeNum(widget.txMin, 7.4)
    local maxV = safeNum(widget.txMax, 8.4)
    if txV == 0 then txV = minV end
    if txV ~= v.txVolt then
      v.txVolt = txV
      widget.txPctCached = (maxV > minV) and math.max(0, math.min(100, math.floor((txV - minV)/(maxV - minV)*100))) or 100
      s.txPct = string.format("%.1fV", txV)
    end
  end
  drawTxBar(zx+393, zy+10, 33, 20, widget.txPctCached or 100)
  lcdDrawText(zx+337, zy+6, s.txPct or "", MEDIUM+C_WHITE)

  if widget.modelBmp then
    lcdDrawBitmap(widget.modelBmp, zx, zy+36)
  elseif not widget.bgBmp then
    roundRect(zx, zy+36, 185, 94, 0, C_DKGREY)
    lcdDrawText(zx+92, zy+78, STR_NO_IMAGE, SMALL+CENTER+C_WHITE)
  end

  local bY1, bY2, bY3 = zy+38, zy+76, zy+114
  local tOff = -2
  local isArmed = safeGetValue(opts and opts.ArmSrc, 0) > 0
  local rpm     = safeGetValue(opts and opts.RpmSrc, 0)
  local mode    = safeGetValue(opts and opts.ModeSrc, -1024)
  local bank    = safeGetValue(opts and opts.BankSrc, -1024)
  local b12     = safeNum(opts and opts.Bank1_2, -250)
  local b23     = safeNum(opts and opts.Bank2_3, 250)

  lcdDrawFilledRectangle(zx+197, bY1, 278, 34, isArmed and C_RED or C_GREEN)
  lcdDrawText(zx+340, bY1+tOff, isArmed and STR_ARMED or STR_DISARMED, BIG+CENTER+C_WHITE)

  if mode ~= v.mode or rpm ~= v.rpm then
    v.mode, v.rpm = mode, rpm
    s.eTxt = (mode < -512) and STR_ENGINE_OFF or (mode < 512) and STR_IDLE or (math.floor(rpm) .. " RPM")
  end
  lcdDrawText(zx+340, bY2+tOff, s.eTxt or "", BIG+CENTER+C_WHITE)

  if bank ~= v.bank or b12 ~= v.b12 or b23 ~= v.b23 then
    v.bank, v.b12, v.b23 = bank, b12, b23
    s.bTxt = (bank < b12) and STR_BANK_1 or (bank < b23) and STR_BANK_2 or STR_BANK_3
  end
  lcdDrawText(zx+272, bY3+tOff, s.bTxt or "", BIG+CENTER+C_WHITE)

  if tick % 10 == 0 or not s.timer or s.timer == "" then
    local timerIdx = safeNum(opts and opts.TimerSrc, 1) - 1
    local td = safeGetTimer(timerIdx)
    local t  = safeNum(td and td.value, 0)
    if t ~= v.timer then
      v.timer = t; local a = math.abs(t)
      s.timer = string.format("%s%02d:%02d",(t<0 and "-" or ""),math.floor(a/60),a%60)
    end
  end
  lcdDrawText(zx+415, bY3+tOff, s.timer or "00:00", BIG+CENTER+C_WHITE)

  local profs  = widget.profiles or {}
  local bIdx   = safeNum(widget.batteryIndex, 1)
  local prof   = profs[bIdx] or profs[1] or {name="Default", cap=2200, flights=0}

  local barX, barY, barW, barH = zx, zy+148, 480, 38

  if isBtnPressed(widget, tx, ty, clickEvent, barX, barY, barW, barH) then
    widget.selectInitTime = getTime()
    setScreen(widget, "select")
    clickEvent = false
  end

  if safeNum(widget.flashTimer, 0) > 0 and widget.flashRect then
    roundRect(zx+438, zy+141, 34, 32, 4, BTN_PRESS_MAP[C_BLUE])
  end

  local displayName = prof.name or "Default"
  if #displayName > 24 then displayName = string.sub(displayName, 1, 23) .. "~" end
  lcdDrawText(zx+12, zy+154, displayName, MEDIUM+BOLD+C_WHITE)

  local fltText = safeNum(prof.flights, 0) .. " flights"
  lcdDrawText(zx+377, zy+160, fltText, MEDIUM+CENTER+C_WHITE)

  local rawPct  = safeGetValue(opts and opts["Rem%"], 100)
  local rawUsed = safeGetValue(opts and opts.Capa, 0)
  local posbat  = 204

  if tick % 4 == 0 then
    local lvl = (rawPct < 20) and 2 or (rawPct < 80) and 1 or 0
    if lvl ~= widget.lastWarnLevel then
      widget.warnChangeTimer = safeNum(widget.warnChangeTimer, 0) + 1
      if widget.warnChangeTimer >= 4 then widget.lastWarnLevel, widget.warnChangeTimer = lvl, 0 end
    else widget.warnChangeTimer = 0 end
  end
  local themeC = (widget.lastWarnLevel == 2 and C_RED) or (widget.lastWarnLevel == 1 and C_ORANGE) or C_GREEN
  drawBattBar(zx+6, zy+posbat, 468, 36, rawPct, themeC)
  lcdDrawText(zx+16,  zy+posbat, math.floor(rawPct) .. "%",    MEDIUM+BOLD+C_WHITE)
  lcdDrawText(zx+464, zy+posbat, math.floor(rawUsed) .. "mAh", MEDIUM+BOLD+RIGHT+C_WHITE)

  if tick % 5 == 0 then
    local tVolt = safeGetValue(opts and opts.Volt, 0)
    local cVolt = safeGetValue(opts and opts.Cell, 0)
    local cAmps = safeGetValue(opts and opts.Curr, 0)
    local eTemp = safeGetValue(opts and opts.EscT, 0)
    local becV  = (opts and opts.Bec) and safeGetValue(opts.Bec, nil) or nil
    local rqly  = safeGetValue(opts and opts.RQly, -1)

    if tVolt ~= v.volt then v.volt=tVolt; s.volt=string.format("Voltage: %.2f V",tVolt) end
    if cVolt ~= v.cell then v.cell=cVolt; s.cell=string.format("Vcell: %.2f V/c",cVolt) end
    if cAmps ~= v.curr then v.curr=cAmps; s.curr=string.format("Current: %.1f A",cAmps) end
    if eTemp ~= v.temp then v.temp=eTemp; s.temp=string.format("ESC temp: %d C",math.floor(eTemp)) end
    if becV and becV ~= v.bec then v.bec=becV; s.bec=string.format("BEC: %.2f V",becV)
    elseif not becV and (not s.bec or s.bec=="") then s.bec="BEC: --" end
    if rqly ~= v.rqly then v.rqly=rqly; s.rqly=string.format("RQly: %d%%", math.floor(math.max(0, rqly))) end
  end

  local gX, gY, bW, bH, gpX, gpY = zx+6, zy+245, 160, 34, 2, 6
  for _, lay in ipairs(TELEM_LAYOUT) do
    local bx = gX + (lay.col - 1) * (bW + gpX)
    local by = gY + (lay.row - 1) * (bH + gpY)
    
    if lay.key == "rqly" then
      local rIdx = rqlyIconIndex(math.max(0, safeNum(v.rqly, 0)))
      local ic = widget.rqlyIcons and widget.rqlyIcons[rIdx]
      if ic then lcdDrawBitmap(ic, bx-4, by-5) end
    end
    
    lcdDrawText(bx+30, by+8, s[lay.key] or "", SMALL+C_WHITE)
  end

  return clickEvent
end

-- ===========================================================================
-- SELECT SCREEN
-- ===========================================================================
local function drawSelectScreen(widget, opts, zx, zy, tx, ty, clickEvent)
  roundRect(zx, zy, 480, 40, 0, C_NAVY)
  lcdDrawText(zx+111, zy+4, STR_SELECT_BATTERY, BIG+C_WHITE)

  local now = getTime()
  local initT = safeNum(widget.selectInitTime, now)
  if (now - initT) < 100 then
    local cur = resolveModelName()
    if cur ~= widget.cachedModelName then
      widget.cachedModelName = cur
      widget.profiles = getFilteredProfiles(cur, widget.allProfiles)
    end
    lcdDrawText(zx+27, zy+65, STR_LOADING, MEDIUM+C_GREY)
    return clickEvent
  end

  local profs = widget.profiles or {}
  local hasModal = (widget.pendingBatteryIndex ~= nil)

  -- Bottom Action Buttons (Back & Edit)
  local btnY, btnW, btnH = zy+268, 110, 42
  local backX = zx + 110
  local editX = zx + 260

  if not hasModal then
    if isBtnPressed(widget, tx, ty, clickEvent, backX, btnY, btnW, btnH) then
      setScreen(widget, "flight")
      clickEvent = false
    end
  end
  roundRect(backX, btnY, btnW, btnH, 4, btnColor(widget, backX, btnY, btnW, btnH, C_GREY))
  lcdDrawText(backX+btnW/2, btnY+10, STR_BACK, MEDIUM+CENTER+C_WHITE)

  if not hasModal then
    if isBtnPressed(widget, tx, ty, clickEvent, editX, btnY, btnW, btnH) then
      enterEditScreen(widget)
      clickEvent = false
    end
  end
  roundRect(editX, btnY, btnW, btnH, 4, btnColor(widget, editX, btnY, btnW, btnH, C_TEAL))
  lcdDrawText(editX+btnW/2, btnY+10, "Edit", MEDIUM+CENTER+C_WHITE)

  -- Battery Selection Grid
  for i = 1, math.min(6, #profs) do
    local b = profs[i]
    if b then
      local isLeft = (i % 2 ~= 0)
      local cW, cH = 220, 58
      local cX = zx + (isLeft and 15 or 245)
      local cY = zy + 50 + math.floor((i - 1) / 2) * 70

      if not hasModal then
        if isBtnPressed(widget, tx, ty, clickEvent, cX, cY, cW, cH) then
          widget.pendingBatteryIndex = i
          clickEvent = false
        end
      end

      local base = C_BLACK
      roundRect(cX, cY, cW, cH, 4, btnColor(widget, cX, cY, cW, cH, base))
      lcdDrawText(cX+11, cY+8, b.name or "Battery", MEDIUM+C_WHITE)
      lcdDrawText(cX+11, cY+32, "(" .. safeNum(b.flights, 0) .. " flt)", SMALL+C_GREY)
    end
  end

  -- Pop-up Confirmation Modal
  if widget.pendingBatteryIndex then
    local popW, popH = 360, 200
    local popX = zx + math.floor((480 - popW) / 2)
    local popY = zy + math.floor((320 - popH) / 2)

    roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_TEAL)
    roundRect(popX, popY, popW, popH, 6, C_DKGREY)
    roundRect(popX, popY, popW, 36, 6, C_NAVY)
    lcdDrawText(popX + popW/2, popY + 6, "CONFIRM SELECTION", MEDIUM+CENTER+C_WHITE)

    local selProf = profs[widget.pendingBatteryIndex] or {}
    local pName = selProf.name or "Battery"
    if #pName > 22 then pName = string.sub(pName, 1, 20) .. "~" end

    lcdDrawText(popX + popW/2, popY + 48, pName, BIG+CENTER+C_WHITE)
    local infoStr = safeNum(selProf.cap, 0) .. " mAh  |  " .. safeNum(selProf.flights, 0) .. " flights"
    lcdDrawText(popX + popW/2, popY + 88, infoStr, MEDIUM+CENTER+C_GREY)

    local mBtnW, mBtnH = 130, 44
    local mBtnY = popY + 136
    local cnfX = popX + 30
    local canX = popX + popW - 30 - mBtnW

    if isBtnPressed(widget, tx, ty, clickEvent, cnfX, mBtnY, mBtnW, mBtnH) then
      widget.batteryIndex = widget.pendingBatteryIndex
      widget.pendingBatteryIndex = nil

      local gvIdx = safeNum(opts and opts.GV_Select, 8) - 1
      local gvValue = getFailsafeGVValue(selProf, widget.cachedModelName, widget.batteryIndex)

      safeSetGV(gvIdx, gvValue)
      setScreen(widget, "flight")
      clickEvent = false
    end
    roundRect(cnfX, mBtnY, mBtnW, mBtnH, 4, btnColor(widget, cnfX, mBtnY, mBtnW, mBtnH, C_TEAL))
    lcdDrawText(cnfX + mBtnW/2, mBtnY + 12, STR_CONFIRM, MEDIUM+CENTER+C_WHITE)

    if isBtnPressed(widget, tx, ty, clickEvent, canX, mBtnY, mBtnW, mBtnH) then
      widget.pendingBatteryIndex = nil
      clickEvent = false
    end
    roundRect(canX, mBtnY, mBtnW, mBtnH, 4, btnColor(widget, canX, mBtnY, mBtnW, mBtnH, C_GREY))
    lcdDrawText(canX + mBtnW/2, mBtnY + 12, STR_BACK, MEDIUM+CENTER+C_WHITE)
  end

  return clickEvent
end

-- ===========================================================================
-- SUMMARY SCREEN
-- ===========================================================================
local function drawSummaryScreen(widget, opts, zx, zy, tx, ty, clickEvent)
  roundRect(zx,zy,480,40,0,C_NAVY)
  lcdDrawText(zx+79,zy+4,STR_SUMMARY,BIG+C_WHITE)

  local now = getTime()
  local sumT = safeNum(widget.summaryStartTime, now)
  if now - sumT > 30000 then setScreen(widget, "flight") end

  local bX,bY,bW,bH = zx+195,zy+268,90,42
  if isBtnPressed(widget,tx,ty,clickEvent,bX,bY,bW,bH) then
    setScreen(widget, "flight"); clickEvent=false
  end
  roundRect(bX,bY,bW,bH,4,btnColor(widget,bX,bY,bW,bH,C_GREY))
  lcdDrawText(bX+bW/2,bY+10,STR_BACK,MEDIUM+CENTER+C_WHITE)

  local cache = widget.summaryCache or {}
  local rH,rW = 48,225
  for idx = 1, 7 do
    local col = (idx%2==1) and 10 or 245
    local rY  = zy+48+math.floor((idx-1)/2)*rH
    roundRect(zx+col,rY,rW,42,4,C_BLACK)
    lcdDrawText(zx+col+7,rY+6,  SUMMARY_LABELS[idx], SMALL+C_GREY)
    lcdDrawText(zx+col+7,rY+22, cache[idx] or "",     SMALL+C_WHITE)
  end
  return clickEvent
end

-- ===========================================================================
-- CREATE & UPDATE
-- ===========================================================================
local function create(zone, opts)
  local ok, lp = pcall(dofile, BATTERIES_PATH)
  local profiles = (ok and type(lp)=="table") and lp or {{name="Default",cap=2200,models={},flights=0}}

  local bgBmp = safeOpenBitmap("/WIDGETS/"..name.."/background.bmp") or 
                safeOpenBitmap("/WIDGETS/"..name.."/background.png") or 
                safeOpenBitmap("/WIDGETS/"..name.."/background.jpg")

  local modelBmp = nil
  local info = safeGetModelInfo()
  if info and type(info.bitmap)=="string" and info.bitmap~="" then
    modelBmp = safeOpenBitmap("/IMAGES/"..info.bitmap)
  end

  local rqlyIcons = {}
  for i,f in ipairs(RQLY_ICON_FILES) do rqlyIcons[i-1] = safeOpenBitmap(ICON_DIR..f) end

  local txMin, txMax = 7.4, 8.4
  if type(getGeneralSettings) == "function" then
    local ok, settings = pcall(getGeneralSettings)
    if ok and type(settings) == "table" then
      txMin = safeNum(settings.battMin, txMin)
      txMax = safeNum(settings.battMax, txMax)
    end
  end

  opts = opts or {}
  local initName     = resolveModelName()
  local filteredProfs= getFilteredProfiles(initName, profiles)
  local gvSel        = safeNum(opts.GV_Select, 8) - 1
  local savedGV      = safeGetGV(gvSel, 0)
  local startScreen, initBatt = "select", 1
  if savedGV ~= 0 then initBatt = getIndexFromValue(savedGV); startScreen = "flight" end

  return {
    zone=zone, options=opts, batteryIndex=initBatt, pendingBatteryIndex=nil,
    cachedModelName=initName, allProfiles=profiles, profiles=filteredProfs,
    screen=startScreen, wasConnected=false, clickEvent=false,
    touchX=0, touchY=0, touchActive=false, lastClickTime=0, noTouchFrames=0,
    bgBmp=bgBmp, modelBmp=modelBmp, rqlyIcons=rqlyIcons, tick=0,
    txMin=txMin, txMax=txMax, summaryStartTime=0, selectInitTime=getTime(),
    lastWarnLevel=0, warnChangeTimer=0,
    flashRect=nil, flashTimer=0,
    connCandidate=false, connStableCount=0,
    armedTime=0, flightQualified=false,
    editProfiles=nil, editSelected=1, editScrollOff=0,
    editingField=nil, keyboardBuffer="",
    showModelsModal=false, slotPickerModel=nil,
    editStatusMsg="", editStatusEnd=0,
    vals={volt=-1,cell=-1,curr=-1,temp=-1,bec=-1,rqly=-2,timer=-99999,txVolt=-1,clockMin=-1,mode=-999,rpm=-999,bank=-999},
    strs={volt="",cell="",curr="",temp="",bec="",rqly="",timer="",txPct="",clock="",eTxt="",bTxt=""},
    summaryCache={initName,"00:00","0 mAh","0 C","0.0 A","0.00 V/c","0%"},
  }
end

local function update(widget, opts) widget.options=opts end

-- ===========================================================================
-- MAIN DRAW / REFRESH
-- ===========================================================================
local function draw(widget)
  if not widget or not widget.options then return end
  local opts = widget.options

  local zw = safeNum(widget.zone and widget.zone.w, 480)
  local zh = safeNum(widget.zone and widget.zone.h, 320)
  local zx = safeNum(widget.zone and widget.zone.x, 0)
  local zy = safeNum(widget.zone and widget.zone.y, 0)

  if zw < 480 or zh < 320 then
    lcdDrawText(zx+2, zy+zh-14, "Set to fullscreen", SMALL+C_WHITE)
    return
  end

  widget.tick       = safeNum(widget.tick, 0) + 1
  widget.flashTimer = math.max(0, safeNum(widget.flashTimer, 0) - 1)

  local isArmed = safeGetValue(opts and opts.ArmSrc, 0) > 0
  local mode    = safeGetValue(opts and opts.ModeSrc, -1024)

  if isArmed and mode >= -512 then
    widget.armedTime = safeNum(widget.armedTime, 0) + 1
    if widget.armedTime >= MIN_FLIGHT_TICKS then
      widget.flightQualified = true
    end
  else
    if widget.flightQualified then
      local profs = widget.profiles or {}
      local bIdx  = safeNum(widget.batteryIndex, 1)
      local curProf = profs[bIdx]
      if curProf then
        curProf.flights = safeNum(curProf.flights, 0) + 1
        saveProfilesToSD(widget.allProfiles)
      end
      widget.flightQualified = false
      widget.armedTime = 0
    end
  end

  if widget.screen ~= "edit" then
    local rqlyVal = safeGetValue(opts and opts.RQly, -1)
    local rawConn = rqlyVal > 10
    if rawConn == widget.connCandidate then 
      widget.connStableCount = safeNum(widget.connStableCount, 0) + 1
    else 
      widget.connCandidate = rawConn; widget.connStableCount = 1 
    end
    if safeNum(widget.connStableCount, 0) >= CONN_DEBOUNCE_FRAMES and rawConn ~= widget.wasConnected then
      if rawConn then
        local gvIdx = safeNum(opts and opts.GV_Select, 8) - 1
        safeSetGV(gvIdx, 0)
        widget.selectInitTime = getTime()
        setScreen(widget, "select")
        widget.armedTime = 0
        widget.flightQualified = false
      else
        if widget.flightQualified then
          local profs = widget.profiles or {}
          local bIdx  = safeNum(widget.batteryIndex, 1)
          local curProf = profs[bIdx]
          if curProf then
            curProf.flights = safeNum(curProf.flights, 0) + 1
            saveProfilesToSD(widget.allProfiles)
          end
        end

        widget.summaryStartTime = getTime()
        setScreen(widget, "summary")
        widget.armedTime = 0
        widget.flightQualified = false
      end
      widget.wasConnected = rawConn
    end
  end

  if widget.wasConnected then
    local cache = widget.summaryCache or {}
    cache[1] = widget.cachedModelName or "Model"
    cache[2] = (widget.strs and widget.strs.timer ~= "") and widget.strs.timer or "00:00"
    local lc = safeGetValue(opts and opts.Capa, 0);    if lc > 0  then cache[3] = math.floor(lc).." mAh" end
    local mt = safeGetValue(opts and opts.MaxEscT, 0); if mt > 0  then cache[4] = math.floor(mt).." C" end
    local mc = safeGetValue(opts and opts.MaxCurr, 0); if mc > 0  then cache[5] = string.format("%.1f A", mc) end
    local ml = safeGetValue(opts and opts.MinCell, 0); if ml > 1.0 then cache[6] = string.format("%.2f V/c", ml) end
    local mr = safeGetValue(opts and opts.MinRQly, 0); if mr > 0  then cache[7] = math.floor(mr).."%" end
  end

  local tx = safeNum(widget.touchX, 0)
  local ty = safeNum(widget.touchY, 0)
  local ce = widget.clickEvent
  widget.clickEvent = false
  
  local bgColor = (opts and opts.BkGround) or C_DKGREY
  lcdClear(bgColor)

  if widget.screen == "select" then
    if widget.tick % 60 == 0 then
      local n = resolveModelName()
      if n ~= widget.cachedModelName then widget.cachedModelName = n; widget.profiles = getFilteredProfiles(n, widget.allProfiles) end
    end
    drawSelectScreen(widget, opts, zx, zy, tx, ty, ce)
  elseif widget.screen == "summary" then
    drawSummaryScreen(widget, opts, zx, zy, tx, ty, ce)
  elseif widget.screen == "edit" then
    drawEditScreen(widget, opts, zx, zy, tx, ty, ce)
  else
    if widget.tick % 60 == 0 then
      local n = resolveModelName()
      if n ~= widget.cachedModelName then widget.cachedModelName = n; widget.profiles = getFilteredProfiles(n, widget.allProfiles) end
    end
    drawFlightScreen(widget, opts, zx, zy, tx, ty, ce)
  end
end

local function background(wgt) end

return {
  name = name, options = options, create = create, update = update, background = background,
  refresh = function(w, event, touchState)
    if not w then return end

    local now = getTime()
    local lastTime = safeNum(w.lastClickTime, 0)
    local t = (type(touchState) == "table") and touchState or ((type(event) == "table") and event or nil)
    local hasTouch = (t ~= nil and type(t.x) == "number" and type(t.y) == "number" and (t.x > 0 or t.y > 0))

    if not hasTouch then
      w.noTouchFrames = safeNum(w.noTouchFrames, 0) + 1
      if w.noTouchFrames >= 5 then
        w.touchActive = false
      end
    else
      w.noTouchFrames = 0
      local elapsed = now - lastTime
      if elapsed < 0 then elapsed = 999 end

      if not w.touchActive and elapsed >= CLICK_COOLDOWN_TICKS then
        w.touchX = safeNum(t.x, 0)
        w.touchY = safeNum(t.y, 0)
        w.clickEvent = true
        w.touchActive = true
        w.lastClickTime = now
      end
    end

    draw(w)
  end,
}