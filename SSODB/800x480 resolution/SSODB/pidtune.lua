-- /WIDGETS/RFBattmgr/pidtune.lua
-- Custom PID + Rates/Expo + Gov tuning screen for RFBattmgr, tabbed.
-- Talks to the flight controller directly via Rotorflight's MSP layer
-- (loaded from /SCRIPTS/RF2/). No LVGL, no system.runScript -- draws with
-- the same raw lcd.draw* style as the rest of RFBattmgr.
--
-- Hardware key vocabulary matches main.lua's getEvtType() exactly:
--   PAGE_UP, PAGE_DN, ENTER, EXIT, NEXT, PREV
-- PAGE_UP / PAGE_DN switch between the PID, Rates, and Gov tabs.
-- EXIT always means "leave this screen" (or "cancel editing" if mid-edit).

local M = {}

local TABS = { "pid", "rates", "gov" }

local PID_AXIS_LABELS  = { "Roll", "Pitch", "Yaw" }
local PID_FIELD_LABELS = { "P", "I", "D", "FF" }
local PID_INDEX = {
  { 0, 1, 2, 3 },
  { 4, 5, 6, 7 },
  { 8, 9, 10, 11 },
}

local RATE_AXIS_LABELS  = { "Roll", "Pitch", "Yaw", "Coll" }
local RATE_FIELD_LABELS = { "Rate", "Shape", "Expo" }
local RATE_INDEX = {
  { 0, 1, 2 },
  { 3, 4, 5 },
  { 6, 7, 8 },
  { 9, 10, 11 },
}

local AUTO_REFRESH_SECONDS = 2

-- ===========================================================================
-- Lazy RF2 / MSP initialisation.
-- ===========================================================================
-- The rf2.lua / mspQueue / mspHelper bootstrap now lives in rf2util.lua,
-- shared with main.lua -- this file used to carry its own copy, and the
-- two drifted (the apiVersion nil-comparison workaround was fixed here
-- and had to be rediscovered there). Only the tab-specific MSP modules
-- are loaded locally.
local RF2 = (function()
  local ok, mod = pcall(dofile, "/WIDGETS/SSODB/rf2util.lua")
  if ok and type(mod) == "table" then return mod end
  return nil
end)()

local function ensureRf2(widget)
  if widget.rf2Ready then return true end
  if widget.rf2Failed then return false end

  if not RF2 then
    widget.rf2Failed = true
    widget.pidStatus = "Err: rf2util.lua missing"
    return false
  end
  if not RF2.ensure() then
    widget.rf2Failed = true
    widget.pidStatus = "Err: " .. tostring(RF2.lastError)
    return false
  end

  local ok, err = pcall(function()
    widget.pidTuning = widget.pidTuning or RF2.script("MSP/mspPidTuning")
    widget.rcTuning  = widget.rcTuning  or RF2.script("MSP/mspRcTuning")
    widget.govTuning = widget.govTuning or RF2.script("MSP/mspGovernorProfile")
    widget.mspStatus = widget.mspStatus or RF2.script("MSP/mspStatus")
  end)

  if not ok then
    widget.rf2Failed = true
    widget.pidStatus = "Err: " .. tostring(err)
    return false
  end

  widget.rf2Ready = true
  return true
end

-- ===========================================================================
-- Per-tab state
-- ===========================================================================
local function freshTabState()
  return {
    data      = nil,
    dirty     = false,
    cursor    = 1,
    editing   = false,
    status    = "",
    lastRead  = 0,
  }
end

local function ensureTuneState(widget)
  widget.tune = widget.tune or {}
  for _, tabName in ipairs(TABS) do
    widget.tune[tabName] = widget.tune[tabName] or freshTabState()
  end
  widget.tuneTab = widget.tuneTab or "pid"
end

-- Curated governor fields, in display order, with friendly labels.
-- Built explicitly (not by dumping+alphabetizing every key in the MSP
-- reply) so the fields you actually care about are first and readable,
-- and so the list is short enough to fit on screen without any of it
-- landing off-screen or under the Save button.
local GOV_FIELD_DEFS = {
  { key = "headspeed",         label = "RPM" },
  { key = "gain",               label = "Gain" },
  { key = "cyclic_weight",      label = "Cyc Precomp" },
  { key = "collective_weight",  label = "Col Precomp" },
  { key = "p_gain",             label = "P Gain" },
  { key = "i_gain",             label = "I Gain" },
  { key = "d_gain",             label = "D Gain" },
  { key = "f_gain",             label = "F Gain" },
  { key = "tta_gain",           label = "TTA Gain" },
  { key = "tta_limit",          label = "TTA Limit" },
  { key = "yaw_weight",         label = "Yaw Weight" },
  { key = "max_throttle",       label = "Max Thr" },
  { key = "min_throttle",       label = "Min Thr" },   -- only present on some FC versions
  { key = "fallback_drop",      label = "FB Drop" },   -- only present on some FC versions
  -- "flags" intentionally omitted -- it's a bitmask, not a simple numeric
  -- value, and doesn't make sense as a +/- stepper.
}

local function getGovFields(data)
  local fields = {}
  if type(data) == "table" then
    for _, def in ipairs(GOV_FIELD_DEFS) do
      local field = data[def.key]
      if type(field) == "table" and field.value ~= nil then
        table.insert(fields, { key = def.key, label = def.label, field = field })
      end
    end
  end
  return fields
end

-- rf2.apiVersion starts nil and is normally populated by RF2's own
-- background_init.lua, which we never run. Several MSP modules do
-- unconditional `rf2.apiVersion >= 12.0x` comparisons inside getDefaults(),
-- which throws "attempt to compare nil with number" if it's still nil, so
-- every tab read waits for it. The query itself now lives in rf2util.lua
-- (shared with main.lua, and with a timeout so a dropped reply can't leave
-- callers pending forever).
local function ensureApiVersion(widget)
  return RF2 and RF2.ensureApiVersion() or false
end

local function requestReadPid(widget)
  local t = widget.tune.pid
  if not ensureApiVersion(widget) then
    t.status = "Detecting FC..."
    t.lastRead = (type(getTime) == "function" and getTime()) or 0
    return
  end
  t.status = "Reading..."
  if widget.pidTuning and widget.pidTuning.read then
    widget.pidTuning.read(function(w, data)
      if w and w.tune and w.tune.pid then
        if type(data) == "table" and next(data) ~= nil then
          w.tune.pid.data = data
          w.tune.pid.status = "Loaded"
        else
          w.tune.pid.data = nil
          w.tune.pid.status = "Offline"
        end
      end
    end, widget)
  end
  t.lastRead = (type(getTime) == "function" and getTime()) or 0
end

local function requestReadRates(widget)
  local t = widget.tune.rates
  if not ensureApiVersion(widget) then
    t.status = "Detecting FC..."
    t.lastRead = (type(getTime) == "function" and getTime()) or 0
    return
  end
  t.status = "Reading..."
  if widget.rcTuning and widget.rcTuning.read then
    widget.rcTuning.read(function(w, data)
      if w and w.tune and w.tune.rates then
        if type(data) == "table" and next(data) ~= nil then
          w.tune.rates.data = data
          w.tune.rates.status = "Loaded"
        else
          w.tune.rates.data = nil
          w.tune.rates.status = "Offline"
        end
      end
    end, widget)
  end
  t.lastRead = (type(getTime) == "function" and getTime()) or 0
end

local function requestReadGov(widget)
  local t = widget.tune.gov
  if not ensureApiVersion(widget) then
    t.status = "Detecting FC..."
    t.lastRead = (type(getTime) == "function" and getTime()) or 0
    return
  end
  t.status = "Reading..."
  if widget.govTuning and widget.govTuning.read then
    widget.govTuning.read(function(w, data)
      if w and w.tune and w.tune.gov then
        if type(data) == "table" and next(data) ~= nil then
          w.tune.gov.data = data
          w.tune.gov.status = "Loaded"
        else
          w.tune.gov.data = nil
          w.tune.gov.status = "Offline"
        end
      end
    end, widget)
  end
  t.lastRead = (type(getTime) == "function" and getTime()) or 0
end

local function requestReadStatus(widget)
  if widget.mspStatus and widget.mspStatus.getStatus then
    widget.mspStatus.getStatus(function(w, status)
      if w and type(status) == "table" then
        w.fcProfile = status.profile
        w.fcRateProfile = status.rateProfile
      end
    end, widget)
  end
end

-- ===========================================================================
-- Tab Navigation Helpers
-- ===========================================================================
local function selectTab(widget, newTab)
  if widget.tuneTab ~= newTab then
    widget.tuneTab = newTab
    local t = widget.tune[newTab]
    t.cursor = 1
    t.editing = false
    if not t.data then
      if newTab == "rates" then requestReadRates(widget)
      elseif newTab == "gov" then requestReadGov(widget)
      else requestReadPid(widget) end
    end
  end
end

local function getNextTab(currentTab, dir)
  local idx = 1
  for i, v in ipairs(TABS) do if v == currentTab then idx = i end end
  idx = ((idx - 1 + dir) % #TABS) + 1
  return TABS[idx]
end

-- ===========================================================================
-- Tick
-- ===========================================================================
function M.tick(widget)
  if RF2 then RF2.pump() end
end

-- ===========================================================================
-- onEnter
-- ===========================================================================
function M.onEnter(widget)
  ensureTuneState(widget)
  
  for _, tabName in ipairs(TABS) do
    local t = widget.tune[tabName]
    t.data = nil
    t.dirty = false
    t.cursor = 1
    t.editing = false
  end

  if not ensureRf2(widget) then return end

  requestReadStatus(widget)
  widget.statusLastRead = (type(getTime) == "function" and getTime()) or 0
  if widget.tuneTab == "rates" then requestReadRates(widget)
  elseif widget.tuneTab == "gov" then requestReadGov(widget)
  else requestReadPid(widget) end
end

-- ===========================================================================
-- Draw
-- ===========================================================================
function M.draw(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt, helpers)
  helpers = helpers or {}
  local isBtnPressed  = helpers.isBtnPressed or function() return false end
  local btnColor      = helpers.btnColor or function(w, x, y, bw, bh, c) return c end
  local roundRect     = helpers.roundRect or function() end
  local lcdDrawText   = helpers.lcdDrawText or function() end
  local SMALL, MEDIUM = helpers.SMALL or 0, helpers.MEDIUM or 0
  local CENTER        = helpers.CENTER or 0

  -- Shared palette, passed through by real name (it used to arrive remapped,
  -- so the source said one colour and drew another). C_CARD/C_CARD_TXT are
  -- the light card treatment used by the battery select and editor screens;
  -- C_MUTED is secondary text on the dark background.
  local C_WHITE    = helpers.C_WHITE    or lcd.RGB(255, 255, 255)
  local C_GREY     = helpers.C_GREY     or lcd.RGB(92, 98, 107)
  local C_BLACK    = helpers.C_BLACK    or lcd.RGB(28, 30, 34)
  local C_DKGREY   = helpers.C_DKGREY   or lcd.RGB(16, 18, 20)
  local C_SLATE    = helpers.C_SLATE    or lcd.RGB(36, 39, 45)
  local C_GREEN    = helpers.C_GREEN    or lcd.RGB(0, 196, 106)
  local C_RED      = helpers.C_RED      or lcd.RGB(220, 53, 53)
  local C_YELLOW   = helpers.C_YELLOW   or lcd.RGB(217, 180, 30)
  local C_ORANGE   = helpers.C_ORANGE   or lcd.RGB(255, 149, 0)
  local C_TEAL     = helpers.C_TEAL     or lcd.RGB(22, 163, 74)
  local C_CARD     = helpers.C_CARD     or lcd.RGB(239, 233, 232)
  local C_CARD_TXT = helpers.C_CARD_TXT or lcd.RGB(24, 26, 30)
  local C_MUTED    = helpers.C_MUTED    or lcd.RGB(176, 184, 196)
  local C_SURFACE    = helpers.C_SURFACE    or lcd.RGB(46, 51, 60)
  local C_SURFACE_HI = helpers.C_SURFACE_HI or lcd.RGB(88, 96, 110)

  -- Layout and screen size come from main.lua so this screen follows the same
  -- resolution profile as the rest of the widget. The fallbacks are the
  -- original 480x320 values, so an older main.lua still renders correctly.
  local SCREEN_W = helpers.SCREEN_W or 480
  local SCREEN_H = helpers.SCREEN_H or 320
  local PT = helpers.PT or {
    titleX=10, titleY=8, profX=320, profY=11,
    backX=400, backY=4, backW=70, backH=28,
    bodyY=36, headH=36,
    tabY=40, tabH=28, tabW=85, tabX1=10, tabX2=100, tabX3=190,
    statusX=290, msgX=20, msgY1=100, msgY2=120, msgY3=140,
    govColW=150, govStartX=15, govStartY=78,
    pidColW=113, pidStartX=1, pidStartY=78,
    saveX=20, saveY=280, saveW=120, saveH=36,
  }
  local C_LABEL      = helpers.C_LABEL      or lcd.RGB(104, 110, 120)

  -- The panel is light (it matches the widget's white background), so the
  -- accent colours used for column labels and focus halos need darkened
  -- variants -- the dark-panel greens/yellows wash out completely on it.
  local L_GREEN  = lcd.RGB(20, 120, 64)
  local L_ORANGE = lcd.RGB(186, 88, 0)
  local L_YELLOW = lcd.RGB(150, 118, 10)

  local PID_FIELD_COLORS  = { L_GREEN, L_ORANGE, C_RED, L_YELLOW }
  local RATE_FIELD_COLORS = { L_GREEN, L_ORANGE, C_RED }

  ensureTuneState(widget)
  local tab = widget.tuneTab
  local t   = widget.tune[tab]

  -- The header's "P%d / R%d" profile/rate indicator was only ever fetched
  -- once, in onEnter() -- it never refreshed again, so switching profile
  -- or rate on the transmitter while this screen was open never showed up.
  -- Poll it periodically instead, same cadence as the tab data itself.
  local nowStatus = (type(getTime) == "function" and getTime()) or 0
  if rf2 and rf2.mspQueue and (nowStatus - (widget.statusLastRead or 0)) > (AUTO_REFRESH_SECONDS * 100) then
    requestReadStatus(widget)
    widget.statusLastRead = nowStatus
  end

  -- Determine dynamic cursor maximums based on tab type
  local maxCursor = 14
  if tab == "gov" and type(t.data) == "table" then
    local govItems = getGovFields(t.data)
    maxCursor = #govItems + 2 -- items + save + back
  end

  if keyEvt then
    if keyEvt == "PAGE_UP" then
      selectTab(widget, getNextTab(widget.tuneTab, -1))
      tab, t = widget.tuneTab, widget.tune[widget.tuneTab]
    elseif keyEvt == "PAGE_DN" then
      selectTab(widget, getNextTab(widget.tuneTab, 1))
      tab, t = widget.tuneTab, widget.tune[widget.tuneTab]
    elseif t.editing then
      if (keyEvt == "NEXT" or keyEvt == "PREV") and type(t.data) == "table" then
        if tab == "gov" then
          local govItems = getGovFields(t.data)
          local item = govItems[t.cursor]
          if item and type(item.field) == "table" then
            local field = item.field
            local mult  = field.mult or 1
            local delta = (keyEvt == "NEXT") and mult or -mult
            field.value = math.max(field.min or 0, math.min(field.max or 10000, (field.value or 0) + delta))
            t.dirty = true
          end
        else
          local index = (tab == "rates") and RATE_INDEX or PID_INDEX
          local cols  = (tab == "rates") and 3 or 4
          if t.cursor <= 12 then
            local a = math.floor((t.cursor - 1) / cols) + 1
            local f = ((t.cursor - 1) % cols) + 1
            local idx = index[a] and index[a][f]
            local field = idx and t.data[idx]
            if type(field) == "table" then
              local mult  = field.mult or 1
              local delta = (keyEvt == "NEXT") and mult or -mult
              field.value = math.max(field.min or 0, math.min(field.max or 1000, (field.value or 0) + delta))
              t.dirty = true
            end
          end
        end
      elseif keyEvt == "ENTER" or keyEvt == "EXIT" then
        t.editing = false
      end
    else
      if keyEvt == "NEXT" then
        t.cursor = (t.cursor % maxCursor) + 1
      elseif keyEvt == "PREV" then
        t.cursor = ((t.cursor - 2) % maxCursor) + 1
      elseif keyEvt == "ENTER" then
        local saveIdx = maxCursor - 1
        local backIdx = maxCursor
        if tab == "gov" then
          local govItems = getGovFields(t.data)
          if t.cursor <= #govItems then
            if type(t.data) == "table" and next(t.data) ~= nil then t.editing = true end
          elseif t.cursor == saveIdx then
            if t.dirty and type(t.data) == "table" then
              if widget.govTuning and widget.govTuning.write then widget.govTuning.write(t.data) end
              t.status = "Saved"
              t.dirty = false
            end
          elseif t.cursor == backIdx then
            return "back"
          end
        else
          if t.cursor <= 12 then
            if type(t.data) == "table" and next(t.data) ~= nil then t.editing = true end
          elseif t.cursor == 13 then
            if t.dirty and type(t.data) == "table" then
              if tab == "rates" then
                if widget.rcTuning and widget.rcTuning.write then widget.rcTuning.write(t.data) end
              else
                if widget.pidTuning and widget.pidTuning.write then widget.pidTuning.write(t.data) end
              end
              t.status = "Saved"
              t.dirty = false
            end
          elseif t.cursor == 14 then
            return "back"
          end
        end
      elseif keyEvt == "EXIT" then
        return "back"
      end
    end
  end

  -- Header
  roundRect(zx, zy, SCREEN_W, PT.headH, 0, C_BLACK)
  lcdDrawText(zx + PT.titleX, zy + PT.titleY, "Tuning", MEDIUM + C_WHITE)

  local profileTxt = ""
  if widget.fcProfile ~= nil then
    profileTxt = string.format("P%d / R%d", (widget.fcProfile or 0) + 1, (widget.fcRateProfile or 0) + 1)
  end
  lcdDrawText(zx + PT.profX, zy + PT.profY, widget.fcProfile ~= nil and profileTxt or "", SMALL + C_YELLOW)

  local bX, bY, bW, bH = zx + PT.backX, zy + PT.backY, PT.backW, PT.backH
  if isBtnPressed(widget, tx, ty, clickEvent, bX, bY, bW, bH) then return "back" end
  local backColor = ((tab == "gov" and t.cursor == maxCursor) or (tab ~= "gov" and t.cursor == 14)) and C_YELLOW or C_GREY
  roundRect(bX, bY, bW, bH, 4, btnColor(widget, bX, bY, bW, bH, backColor))
  lcdDrawText(bX + bW / 2, bY + 6, "Back", SMALL + CENTER + C_WHITE)

  roundRect(zx, zy + PT.bodyY, SCREEN_W, SCREEN_H - PT.bodyY, 0, C_SURFACE)

  -- Tabs
  local tabY, tabH = zy + PT.tabY, PT.tabH
  local pidTabX, ratesTabX, govTabX, tabW = zx + PT.tabX1, zx + PT.tabX2, zx + PT.tabX3, PT.tabW

  if isBtnPressed(widget, tx, ty, clickEvent, pidTabX, tabY, tabW, tabH) then
    selectTab(widget, "pid")
    tab, t = widget.tuneTab, widget.tune[widget.tuneTab]
  end
  roundRect(pidTabX, tabY, tabW, tabH, 4, (tab == "pid") and C_TEAL or C_SURFACE_HI)
  lcdDrawText(pidTabX + tabW / 2, tabY + 6, "PID", SMALL + CENTER + C_WHITE)

  if isBtnPressed(widget, tx, ty, clickEvent, ratesTabX, tabY, tabW, tabH) then
    selectTab(widget, "rates")
    tab, t = widget.tuneTab, widget.tune[widget.tuneTab]
  end
  roundRect(ratesTabX, tabY, tabW, tabH, 4, (tab == "rates") and C_TEAL or C_SURFACE_HI)
  lcdDrawText(ratesTabX + tabW / 2, tabY + 6, "Rates", SMALL + CENTER + C_WHITE)

  if isBtnPressed(widget, tx, ty, clickEvent, govTabX, tabY, tabW, tabH) then
    selectTab(widget, "gov")
    tab, t = widget.tuneTab, widget.tune[widget.tuneTab]
  end
  roundRect(govTabX, tabY, tabW, tabH, 4, (tab == "gov") and C_TEAL or C_SURFACE_HI)
  lcdDrawText(govTabX + tabW / 2, tabY + 6, "Gov", SMALL + CENTER + C_WHITE)

  lcdDrawText(zx + PT.statusX, tabY + 6, t.status or "", SMALL + C_LABEL)

  -- Waiting for FC Check
  if type(t.data) ~= "table" or next(t.data) == nil then
    lcdDrawText(zx + PT.msgX, zy + PT.msgY1, "Waiting for flight controller...", SMALL + C_LABEL)
    lcdDrawText(zx + PT.msgX, zy + PT.msgY2, "Status: " .. tostring(t.status or "Offline"), SMALL + C_LABEL)
    if tab == "gov" and not widget.govTuning then
      lcdDrawText(zx + PT.msgX, zy + PT.msgY3, "Error: MSP/mspGovernorProfile script not found.", SMALL + C_RED)
    end
    return nil
  end

  if tab == "rates" then
    local ratesType = t.data.rates_type
    local typeTable = type(ratesType) == "table" and ratesType.table
    local typeVal   = type(ratesType) == "table" and ratesType.value
    local typeName  = typeTable and typeVal and typeTable[typeVal]
    if typeName ~= "ROTORFL" then
      lcdDrawText(zx + PT.msgX, zy + PT.msgY1, "Unsupported rate type: " .. tostring(typeName or "Unknown"), SMALL + L_ORANGE)
      lcdDrawText(zx + PT.msgX, zy + PT.msgY2, "This screen only supports ROTORFL rates.", SMALL + C_LABEL)
      return nil
    end
  end

  local now = (type(getTime) == "function" and getTime()) or 0
  if not t.dirty and rf2 and rf2.mspQueue and (now - (t.lastRead or 0)) > (AUTO_REFRESH_SECONDS * 100) then
    if tab == "rates" then requestReadRates(widget)
    elseif tab == "gov" then requestReadGov(widget)
    else requestReadPid(widget) end
  end

  -- Render Governor Tab -- compact 3-column grid so everything fits on
  -- screen without needing to scroll (the previous single-column layout
  -- ran well past the visible body area for anything past ~row 6).
  if tab == "gov" then
    local govItems = getGovFields(t.data)
    local cols = 3
    local colW = PT.govColW
    local itemH = 36
    local startX, startY = zx + PT.govStartX, zy + PT.govStartY

    for i, item in ipairs(govItems) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local cellX = startX + col * colW
      local cellY = startY + row * itemH
      local field = item.field
      local isFocused = (t.cursor == i)
      local scale = field.scale or 1
      local mult = field.mult or 1

      lcdDrawText(cellX, cellY, item.label, SMALL + C_CARD_TXT)

      local mX, mY, mW, mH = cellX, cellY + 14, 22, 22
      if isBtnPressed(widget, tx, ty, clickEvent, mX, mY, mW, mH) then
        field.value = math.max(field.min or 0, (field.value or 0) - mult)
        t.dirty = true
        t.cursor = i
      end
      roundRect(mX, mY, mW, mH, 4, btnColor(widget, mX, mY, mW, mH, C_SURFACE_HI))
      lcdDrawText(mX + 6, mY, "-", MEDIUM + C_WHITE)

      if isFocused then
        local haloColor = t.editing and L_GREEN or L_ORANGE
        roundRect(mX + 21, mY - 3, 66, 27, 4, haloColor)
      end
      roundRect(mX + 23, mY, 62, 21, 4, C_CARD)
      local displayVal = (field.value or 0) / scale
      local valText = (scale ~= 1) and string.format("%.1f", displayVal) or tostring(math.floor(displayVal + 0.5))
      lcdDrawText(mX + 54, cellY + 15, valText, SMALL + C_CARD_TXT + CENTER)

      local pX, pY, pW, pH = mX + 88, cellY + 14, 22, 22
      if isBtnPressed(widget, tx, ty, clickEvent, pX, pY, pW, pH) then
        field.value = math.min(field.max or 10000, (field.value or 0) + mult)
        t.dirty = true
        t.cursor = i
      end
      roundRect(pX, pY, pW, pH, 4, btnColor(widget, pX, pY, pW, pH, C_SURFACE_HI))
      lcdDrawText(pX + 5, pY, "+", MEDIUM + C_WHITE)
    end

    local saveIdx = #govItems + 1
    local sX, sY, sW, sH = zx + PT.saveX, zy + PT.saveY, PT.saveW, PT.saveH
    if t.dirty and isBtnPressed(widget, tx, ty, clickEvent, sX, sY, sW, sH) then
      if widget.govTuning and widget.govTuning.write then widget.govTuning.write(t.data) end
      t.status = "Saved"
      t.dirty = false
    end
    if t.cursor == saveIdx then
      roundRect(sX - 3, sY - 3, sW + 6, sH + 6, 6, L_ORANGE)
    end
    roundRect(sX, sY, sW, sH, 4, t.dirty and C_TEAL or C_SURFACE_HI)
    lcdDrawText(sX + sW / 2, sY + 10, "Save", MEDIUM + CENTER + C_WHITE)

    if t.dirty then
      lcdDrawText(sX + sW + 20, sY + 10, "Unsaved -- auto-refresh paused", SMALL + L_ORANGE)
    end

    return nil
  end

  -- Render PID and Rates Tabs
  local index       = (tab == "rates") and RATE_INDEX or PID_INDEX
  local axisLabels  = (tab == "rates") and RATE_AXIS_LABELS or PID_AXIS_LABELS
  local fieldLabels = (tab == "rates") and RATE_FIELD_LABELS or PID_FIELD_LABELS
  local fieldColors = (tab == "rates") and RATE_FIELD_COLORS or PID_FIELD_COLORS
  local cols        = (tab == "rates") and 3 or 4
  local nRows       = (tab == "rates") and 4 or 3

  local rowH  = (tab == "rates") and 52 or 70
  local colW  = PT.pidColW
  local startX, startY = zx + PT.pidStartX, zy + PT.pidStartY

  for a = 1, nRows do
    local rowY = startY + (a - 1) * rowH
    roundRect(startX, rowY+18, 34, 25, 4, C_BLACK)
    lcdDrawText(startX, rowY+20, axisLabels[a] or "", SMALL + C_CARD_TXT)

    for f = 1, cols do
      local idx   = index[a] and index[a][f]
      local field = idx and t.data[idx]
      if type(field) == "table" then
        local cellX = startX + 34 + (f - 1) * colW
        local fieldColor  = fieldColors[f] or C_CARD_TXT
        local cursorIndex = (a - 1) * cols + f
        local isFocused   = (t.cursor == cursorIndex)
        local scale       = field.scale or 1
        local mult        = field.mult or 1

        lcdDrawText(cellX, rowY, fieldLabels[f] or "", SMALL + fieldColor)

        local mX, mY, mW, mH = cellX, rowY + 16, 20, 26
        if isBtnPressed(widget, tx, ty, clickEvent, mX, mY, mW, mH) then
          field.value = math.max(field.min or 0, (field.value or 0) - mult)
          t.dirty = true
          t.cursor = cursorIndex
        end
        roundRect(mX, mY, mW, mH, 4, btnColor(widget, mX, mY, mW, mH, C_SURFACE_HI))
        lcdDrawText(mX + 8, mY, "-", MEDIUM + C_WHITE)

        if isFocused then
          local haloColor = t.editing and L_GREEN or L_ORANGE
          roundRect(cellX + 21, mY - 3, 64, 31, 4, haloColor)
        end
        roundRect(cellX + 23, mY, 60, 25, 4, C_CARD)
        local displayVal = (field.value or 0) / scale
        local valText = (scale ~= 1) and string.format("%.1f", displayVal) or tostring(math.floor(displayVal + 0.5))
        lcdDrawText(cellX + 55, rowY + 15, valText, MEDIUM + C_CARD_TXT+CENTER)

        local pX, pY, pW, pH = cellX + 86, rowY + 16, 20, 26
        if isBtnPressed(widget, tx, ty, clickEvent, pX, pY, pW, pH) then
          field.value = math.min(field.max or 1000, (field.value or 0) + mult)
          t.dirty = true
          t.cursor = cursorIndex
        end
        roundRect(pX, pY, pW, pH, 4, btnColor(widget, pX, pY, pW, pH, C_SURFACE_HI))
        lcdDrawText(pX + 4, pY, "+", MEDIUM + C_WHITE)
      end
    end
  end

  local sX, sY, sW, sH = zx + PT.saveX, zy + PT.saveY, PT.saveW, PT.saveH
  if t.dirty and isBtnPressed(widget, tx, ty, clickEvent, sX, sY, sW, sH) then
    if tab == "rates" then
      if widget.rcTuning and widget.rcTuning.write then widget.rcTuning.write(t.data) end
    else
      if widget.pidTuning and widget.pidTuning.write then widget.pidTuning.write(t.data) end
    end
    t.status = "Saved"
    t.dirty = false
  end
  if t.cursor == 13 then
    roundRect(sX - 3, sY - 3, sW + 6, sH + 6, 6, L_ORANGE)
  end
  roundRect(sX, sY, sW, sH, 4, t.dirty and C_TEAL or C_SURFACE_HI)
  lcdDrawText(sX + sW / 2, sY + 10, "Save", MEDIUM + CENTER + C_WHITE)

  if t.dirty then
    lcdDrawText(sX + sW + 20, sY + 10, "Unsaved -- auto-refresh paused", SMALL + L_ORANGE)
  end

  return nil
end

return M