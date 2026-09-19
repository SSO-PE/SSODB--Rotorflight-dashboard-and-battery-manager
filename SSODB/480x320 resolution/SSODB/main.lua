-- /WIDGETS/RFBattmgr/RFBattmgr.lua
-- Battery Manager widget for RadioMaster / EdgeTX (480x320 fullscreen)

local name = "SSODB"

local options = {
  { "MinCell", SOURCE, "Vcel-" }, { "MaxCurr", SOURCE, "Iesc+" }, { "MaxEscT", SOURCE, "Tesc+" }, { "MinRQly", SOURCE, "Rqly-" },
  { "GV_Select", VALUE, 8, 1, 9 }, { "TimerSrc", VALUE, 1, 1, 3 },
  { "ArmSrc", SOURCE, "ARM" }, { "ModeSrc", SOURCE, 1 },
  { "RpmSrc", SOURCE, "Hspd" },
  { "RateSrc", SOURCE, 1 }, { "NumRates", VALUE, 3, 1, 6 },
  { "ThrSrc", SOURCE, "Thr" },
  { "ProfSrc", SOURCE, 1 }, { "NumProfs", VALUE, 3, 1, 6 },
  { "BkGround", COLOR, lcd.RGB(255,255,255) }
}

-- ===========================================================================
-- DYNAMIC TELEMETRY RETRIEVAL ARCHITECTURE
-- ===========================================================================
local RESOLVED = {}
local F = {}

local ROTORFLIGHT_SENSOR = {
  batPct = { "Bat%", "BatP", "BatPct" },
  capa   = { "Capa", "Cap", "Mah" },
  vbat   = { "Vbat", "VFAS", "Vfas", "Volts", "Volt" },
  vcel   = { "Vcel", "Cels", "Cell" },
  curr   = { "Iesc", "Current", "A","Curr" },
  tesc   = { "Tesc", "EscT", "ESC T" },
  vbec   = { "Vbec", "BecV", "BEC", "Bec" },
  hspd   = { "Hspd", "HSpd", "Hspeed", "HeadSpd", "Head", "RPM", "Rpm" },
  gov    = { "Gov", "GovState" },
  lq     = { "RQly", "RQLY", "LQ", "RSSI" },
  thr    = { "Thr", "Thr%", "THR", "Throttle" }
}

-- Sentinel meaning "looked this up already this frame, it wasn't there".
-- Storing plain nil for a miss doesn't work: `F[k] ~= nil` then reads as a
-- cache miss, so every absent sensor was re-probed on every single lookup.
local NO_VALUE = {}

local function clearFrameCache()
  for k in pairs(F) do F[k] = nil end
end

-- Sensor-name -> field-id resolution is cached across frames, including
-- negative results. Previously a miss cleared the cache entry, so a missing
-- sensor meant a getFieldInfo() call for every alias on every frame -- about
-- 53 telemetry API calls per frame with nothing connected, which is exactly
-- when the widget is left sitting on the bench. Instead the cache is dropped
-- explicitly whenever the set of available sensors could have changed.
local function invalidateSensorCache()
  for k in pairs(RESOLVED) do RESOLVED[k] = nil end
end

local function resolveSensorId(sensorName)
  if RESOLVED[sensorName] ~= nil then
    return RESOLVED[sensorName]
  end

  if type(getFieldInfo) == "function" then
    local info = getFieldInfo(sensorName)
    if info and info.id then
      RESOLVED[sensorName] = info.id
      return info.id
    end
  end

  RESOLVED[sensorName] = false
  return false
end

local function get(src)
  if not src then return nil end

  local cached = F[src]
  if cached ~= nil then
    if cached == NO_VALUE then return nil end
    return cached
  end

  local val = nil

  if type(src) == "number" then
    if type(getSourceValue) == "function" then
      local res = getSourceValue(src)
      if type(res) == "table" then
        if res.isCurrent or res.isFresh then val = res.value end
      else
        val = res
      end
    elseif type(getValue) == "function" then
      val = getValue(src)
    end
  elseif type(src) == "string" then
    local id = resolveSensorId(src)
    if id then
      if type(getSourceValue) == "function" then
        local res = getSourceValue(id)
        if type(res) == "table" then
          if res.isCurrent or res.isFresh then val = res.value end
        else
          val = res
        end
      elseif type(getValue) == "function" then
        val = getValue(id)
      end
    elseif type(getValue) == "function" then
      val = getValue(src)
    end

  end

  F[src] = (val == nil) and NO_VALUE or val
  return val
end

local function resolveNamed(sensorKey)
  local cached = F[sensorKey]
  if cached ~= nil then
    if cached == NO_VALUE then return nil end
    return cached
  end

  local candidates = ROTORFLIGHT_SENSOR[sensorKey]

  if not candidates then
    local val = get(sensorKey)
    F[sensorKey] = val
    return val
  end

  -- Always try Rotorflight's aliases in order. Do not cache the selected
  -- alias: telemetry fields can appear/disappear as the model connects.
  for i = 1, #candidates do
    local val = get(candidates[i])
    if val ~= nil then
      F[sensorKey] = val
      return val
    end
  end

  F[sensorKey] = NO_VALUE
  return nil
end

local function safeGetTelemetry(optSrc, sensorKey, default)
  if sensorKey then
    local val = resolveNamed(sensorKey)
    if type(val) == "number" then return val end
  end
  if optSrc ~= nil then
    local val = get(optSrc)
    if type(val) == "number" then return val end
  end
  return default
end

-- ===========================================================================
-- HARDWARE EVENT MAPPER
-- ===========================================================================
local function getEvtType(evt)
  if type(evt) ~= "number" or evt == 0 then return nil end

  if (EVT_VIRTUAL_PREV_PAGE and evt == EVT_VIRTUAL_PREV_PAGE) or
     (EVT_PAGEUP_FIRST and evt == EVT_PAGEUP_FIRST) or
     (EVT_PAGE_BREAK and evt == EVT_PAGE_BREAK) or
     evt == 0x62 or evt == 0x1E then
    return "PAGE_DN"
  end

  if (EVT_VIRTUAL_NEXT_PAGE and evt == EVT_VIRTUAL_NEXT_PAGE) or
     (EVT_PAGEDN_FIRST and evt == EVT_PAGEDN_FIRST) or
     evt == 0x63 or evt == 0x1F then
    return "PAGE_UP"
  end

  if (EVT_VIRTUAL_ENTER and evt == EVT_VIRTUAL_ENTER) or
     (EVT_ENTER_BREAK and evt == EVT_ENTER_BREAK) or
     evt == 0x60 or evt == 0x1A then
    return "ENTER"
  end

  if (EVT_VIRTUAL_EXIT and evt == EVT_VIRTUAL_EXIT) or
     (EVT_EXIT_BREAK and evt == EVT_EXIT_BREAK) or
     evt == 0x61 or evt == 0x1B then
    return "EXIT"
  end

  if (EVT_VIRTUAL_NEXT and evt == EVT_VIRTUAL_NEXT) or
     (EVT_ROT_RIGHT and evt == EVT_ROT_RIGHT) or
     (EVT_PLUS_FIRST and evt == EVT_PLUS_FIRST) or
     evt == 0x65 or evt == 0x1C then
    return "NEXT"
  end

  if (EVT_VIRTUAL_PREV and evt == EVT_VIRTUAL_PREV) or
     (EVT_ROT_LEFT and evt == EVT_ROT_LEFT) or
     (EVT_MINUS_FIRST and evt == EVT_MINUS_FIRST) or
     evt == 0x64 or evt == 0x1D then
    return "PREV"
  end

  return nil
end

-- ===========================================================================
-- LOCALIZED ENV & API LOOKUPS
-- ===========================================================================
local getValue, getTime, getDateTime = getValue, getTime, getDateTime
local type, math, string, table, io   = type, math, string, table, io
local lcd, model                      = lcd, model
local SMALL, MEDIUM, BIG              = SMLSIZE, MIDSIZE, DBLSIZE

-- Rendered height of each font, used to centre label text vertically inside
-- buttons and rows. lcdDrawText's CENTER flag only centres horizontally, so
-- the vertical offset previously had to be hand-tuned at every call site --
-- which is why some labels sat centred and others noticeably high or low.
local FONT_H = { [SMLSIZE] = 13, [MIDSIZE] = 24, [DBLSIZE] = 32 }

-- Vertical offset that centres `font` inside a box of height `h`.
local function textCenterY(h, font)
  return math.max(0, math.floor((h - (FONT_H[font] or 17)) / 2))
end
local BOLD, CENTER, RIGHT             = BOLD, CENTER, RIGHT

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
    local val = get(src)
    if type(val) == "number" then return val end
  end
  return default or 0
end

-- The size model pictures are drawn at on this screen. Declared here rather
-- than beside the picker, because the loader below captures it -- a local
-- declared later would leave that reference pointing at a nil global.
local MODEL_IMG_W, MODEL_IMG_H = 192, 114

-- Model pictures are drawn at a fixed size, and lcdDrawBitmap does not
-- scale, so an image that isn't already the right size would otherwise be
-- drawn at its own dimensions -- overflowing its area or leaving a gap.
-- Bitmap.resize is used where the firmware provides it; if it doesn't, the
-- image is returned unscaled rather than not at all, so an existing install
-- keeps working.
local function bitmapSize(bmp)
  if Bitmap and type(Bitmap.getSize) == "function" then
    local ok, w, h = pcall(Bitmap.getSize, bmp)
    if ok and type(w) == "number" then return w, h end
  end
  if lcd and type(lcd.getBitmapSize) == "function" then
    local ok, w, h = pcall(lcd.getBitmapSize, bmp)
    if ok and type(w) == "number" then return w, h end
  end
  return nil, nil
end

local function scaleBitmap(bmp, w, h)
  if not bmp or not w or not h then return bmp end
  local bw, bh = bitmapSize(bmp)
  if bw == w and bh == h then return bmp end          -- already correct
  if Bitmap and type(Bitmap.resize) == "function" then
    local ok, scaled = pcall(Bitmap.resize, bmp, w, h)
    if ok and scaled then return scaled end
  end
  return bmp
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
  widget.popupFocus = 1
  widget.selectFocusedIndex = widget.batteryIndex or 1
  widget.clickEvent = false
  widget.touchActive = true
  widget.lastClickTime = getTime()
  widget.showModelsModal = false
  widget.slotPickerModel = nil
  widget.modelPicker     = false
  widget.modelPickerScroll = 0
end

-- ===========================================================================
-- CALCULATIONS FOR SOURCE-BASED SELECTION (RATE / PROFILE)
-- ===========================================================================
local function calculateSelection(val, count)
  val = safeNum(val, -1024)
  count = safeNum(count, 3)
  if count <= 1 then return 1 end

  -- Maps EdgeTX source range [-1024, 1024] into equal step ranges 1..count
  local norm = val + 1024
  if norm <= 0 then return 1 end
  if norm >= 2048 then return count end

  local step = 2048 / count
  local idx = math.floor(norm / step) + 1
  return math.max(1, math.min(count, idx))
end

local function prepareSelectionConfig(widget, opts)
  opts = opts or {}
  local rateCount = math.max(1, safeNum(opts.NumRates, 3))
  local profCount = math.max(1, safeNum(opts.NumProfs, 3))
  widget.rateCount = rateCount
  widget.profCount = profCount
  widget.rateStep = (rateCount > 1) and (2048 / rateCount) or 2048
  widget.profStep = (profCount > 1) and (2048 / profCount) or 2048
end

local function calculateSelectionCached(val, count, step)
  val = safeNum(val, -1024)
  count = safeNum(count, 3)
  if count <= 1 then return 1 end

  local norm = val + 1024
  if norm <= 0 then return 1 end
  if norm >= 2048 then return count end

  local idx = math.floor(norm / step) + 1
  return math.max(1, math.min(count, idx))
end

-- ===========================================================================
-- FIXED 480x320 FLIGHT SCREEN LAYOUT
-- ===========================================================================
-- The widget is intentionally fullscreen at 480x320, so flight-screen
-- geometry is fixed rather than calculated or stored per widget instance.
local FLIGHT = {
  modelTitleX = 3, modelTitleY = 0,
  clockX = 441, clockY = 11,

  row1Y = 38, row2Y = 68, rowH = 30, cardW = 190,
  cardXL = 2, cardXR = 190,

  txBarX = 375, txBarY = 10, txBarW = 50, txBarH = 20,
  txTextX = 337, txTextY = 12,

  -- modelY is bounded on both sides: the row-2 cards end at row2Y+rowH (98)
  -- and the battery bar starts at 215. Model bitmaps are 192x114, so the
  -- image spans modelY..modelY+114 -- at 105 that reached 219 and ran 4px
  -- into the battery bar. 101 clears both (98 above, 215 below).
  -- 192x114 is the picture size; row-2 cards end at 98 and the battery bar
  -- starts at 215, so 101..215 fits it exactly. Images of any other size are
  -- scaled to this when loaded.
  modelX = 0, modelY = 101, modelW = 192, modelH = 114,

  -- Card rectangles come from Background.png: flight-time card y 104..153,
  -- throttle card y 160..209, both x 197..475. Each card already carries its
  -- own printed label along the bottom ("Flight time" at y 138..148,
  -- "Throttle (%)" at y 194..204), so the widget draws no label of its own
  -- and the bars occupy the free area above, with the value inside the bar.
  timerX = 197, timerY = 104, timerW = 278, timerH = 49,
  timerSweepX = 207, timerSweepY = 106,
  timerSweepW = 258, timerSweepH = 30,

  thrX = 197, thrY = 160, thrW = 278, thrH = 49,
  thrBarX = 207, thrBarY = 162, thrBarW = 258, thrBarH = 30,

  batteryX = 6, batteryY = 215, batteryW = 468, batteryH = 42,
  
  -- Top telemetry cards from Background.bmp: Rate / Profile / live Vcell / live Current / RQly.
  rateX = 215, profX = 257,
  topCardY = 45,
  minCellX = 309, minCellY = 51,
  maxCurrX = 370, maxCurrY = 51,
  rqlyIconX = 398, rqlyIconY = 52,
  rqlyTextX = 430, rqlyTextY = 54,
  imgY = 110,

  telem = {
    {key="volt", x=15,  y=260},
    {key="minCell", x=15,  y=290},
    {key="temp", x=174, y=260},
    {key="maxCurr", x=174, y=290},
    {key="bec",  x=333, y=260},
    {key="rqly", x=333, y=290},
  },
}

-- ===========================================================================
-- COLORS
-- ===========================================================================
local C_NAVY   = lcd.RGB(0, 196, 106)
local C_BLUE   = lcd.RGB(255, 149, 0)
local C_GREY   = lcd.RGB(92, 98, 107)
local C_BLACK  = lcd.RGB(28, 30, 34)
local C_WHITE  = lcd.RGB(255, 255, 255)
local C_RED    = lcd.RGB(220, 53, 53)
local C_ORANGE = lcd.RGB(255, 149, 0)
local C_YELLOW = lcd.RGB(217, 180, 30)
local C_GREEN  = lcd.RGB(0, 196, 106)
local C_SLATE  = lcd.RGB(36, 39, 45)
local C_DKGREY = lcd.RGB(16, 18, 20)
local C_TEAL   = lcd.RGB(22, 163, 74)
local C_VGREEN = lcd.RGB(168,254,23)
local C_CARD= lcd.RGB(239,233,232)
-- Editor rows reuse the light card treatment from the battery select
-- screen (C_CARD panels on the dark background) so the two screens read as
-- one product. Dark-on-light also beats any light-on-dark combination for
-- contrast on a sunlit transmitter screen.
local C_ROW      = C_CARD                 -- row background
local C_LABEL    = lcd.RGB(104, 110, 120) -- property label, on the light card
local C_ROW_TXT  = lcd.RGB(24, 26, 30)    -- property value / battery name
local C_ROW_EDGE = lcd.RGB(22, 163, 74)   -- leading edge marker (C_TEAL tone)
local C_HV       = lcd.RGB(186, 88, 0)    -- HV accent, darkened to stay legible on the light card
local C_MUTED    = lcd.RGB(176, 184, 196) -- secondary text on DARK backgrounds (C_LABEL is for light cards)
-- Panel / modal body. The widget background (the BkGround option) defaults
-- to WHITE, which is what the battery select screen shows. Modals and the
-- pidtune panel paint their own opaque background over it, so anything dark
-- here reads as a black island dropped onto a light app. This is near-white
-- to match, with C_CARD rows sitting on it exactly like the select screen's
-- cards sit on the page.
local C_SURFACE  = lcd.RGB(252, 251, 250)
-- Controls sitting ON C_SURFACE: keys, tabs, steppers. Dark grey with white
-- text, so they read as raised controls against the light body.
local C_SURFACE_HI = lcd.RGB(88, 96, 110)

local BTN_PRESS_MAP = {
  [C_BLUE]  = lcd.RGB(255, 180, 80),
  [C_GREY]  = lcd.RGB(130, 138, 148),
  [C_NAVY]  = lcd.RGB(80, 225, 150),
  [C_BLACK] = lcd.RGB(60, 64, 70),
  [C_RED]   = lcd.RGB(255, 110, 110),
  [C_TEAL]  = lcd.RGB(60, 200, 110),
  [C_CARD]  = lcd.RGB(210, 204, 203), -- light rows darken slightly when pressed
  [C_SLATE] = lcd.RGB(72, 80, 94),
  [C_SURFACE_HI] = lcd.RGB(112, 122, 138),
}

-- ===========================================================================
-- CONSTANTS & KEYBOARD LAYOUT
-- ===========================================================================
local CONN_DEBOUNCE_FRAMES = 15
local PRESS_FLASH_FRAMES   = 4
local BATTERIES_PATH       = "/WIDGETS/SSODB/batteries.lua"
local BATTERIES_BAK        = "/WIDGETS/SSODB/batteries.bak"
local PIDTUNE_PATH          = "/WIDGETS/RFBattmgr/pidtune.lua"
local MODEL_MAP_PATH        = "/WIDGETS/"..name.."/model.lua"
local MODEL_MAP_BAK         = "/WIDGETS/"..name.."/model.bak"
local MODEL_IMAGE_DIR       = "/WIDGETS/"..name.."/Modelimage/"
local MODEL_IMAGES_LIST_PATH= "/WIDGETS/"..name.."/modelimages.lua"
local CLICK_COOLDOWN_TICKS = 40
local RPM_RUNNING          = 100 -- headspeed below this = the head isn't turning
local THR_UPDATE_TICKS     = 100 -- getTime() is 10ms ticks -> 1 second
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

-- Fields that are numbers, not text. Having the range live here (rather
-- than only in the commit branch) lets the numeric pad show it, validate
-- against it live, and clamp to it -- instead of the old behaviour where
-- a stray letter made tonumber() return nil and the edit silently
-- reverted to the previous value with no feedback.
-- `step` is how much one encoder click changes the value. Capacity moves in
-- 50mAh increments because clicking from 0 to 5000 one unit at a time would
-- be unusable; the others are naturally fine at 1.
local NUMERIC_FIELDS = {
  cap       = { title = "EDIT CAPACITY",        unit = "mAh", min = 0, max = 20000, default = 2200, step = 50 },
  flights   = { title = "EDIT FLIGHT COUNT",    unit = "",    min = 0, max = 9999,  default = 0,    step = 1  },
  usablePct = { title = "EDIT USABLE CAPACITY", unit = "%",   min = 1, max = 100,   default = 100,  step = 1  },
}

-- Calculator layout (7-8-9 on top). "00" earns its place on packs like
-- 4500/5100 mAh.
local NUMPAD_ROWS = {
  { "7", "8", "9" },
  { "4", "5", "6" },
  { "1", "2", "3" },
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
local STR_ENGINE_ON      = "ENGINE ON"
local STR_LOADING        = "Loading model profile..."
local STR_SELECT_MODEL_IMAGE = "SELECT MODEL IMAGE"
local STR_SAVED          = "Saved!"
local STR_SAVE_ERR       = "Save failed!"
local SUMMARY_LABELS = {
  "Model Name:","Flight Time:","Capacity Used:","Max ESC Temp:",
  "Max Current:","Min Cell Voltage:","Min Link Qly:",
}

-- ===========================================================================
-- SHARED RF2 / MSP BOOTSTRAP
-- ===========================================================================
-- All RF2 loading, apiVersion handling and queue pumping lives in
-- rf2util.lua so main.lua and pidtune.lua can't drift apart -- see the
-- header of that file for the specific bugs that motivated it. Fails soft:
-- if the module is missing, every RF2.* call below is a harmless no-op and
-- the widget still runs without FC integration.
local RF2 = (function()
  local ok, mod = pcall(dofile, "/WIDGETS/"..name.."/rf2util.lua")
  if ok and type(mod) == "table" then return mod end
  return {
    ensure = function() return false end,
    script = function() return nil end,
    ensureApiVersion = function() return false end,
    isApiVersionPending = function() return false end,
    pump = function() end,
    lastError = "rf2util.lua missing",
  }
end)()

-- ===========================================================================
-- HELPER FUNCTIONS & SLOT UNIQUE ENFORCEMENT
-- ===========================================================================
-- Model name from the FC itself, via a direct one-shot MSP_NAME query --
-- independent of whether the separate RfTool widget happens to be running
-- and has already populated rf2.modelName. Queried once per connection
-- (triggered at the connection-transition point below, not every frame),
-- so this adds a single MSP request per flight rather than ongoing
-- telemetry traffic.
local rf2NameCache   = nil
local rf2NamePending = false

local function queryModelNameFromFC()
  if rf2NamePending then return end
  local mspName = RF2.script("MSP/mspName")
  if not (mspName and mspName.getModelName) then return end
  local ok = pcall(function()
    rf2NamePending = true
    mspName.getModelName(function(_, name)
      if type(name) == "string" and name ~= "" then
        rf2NameCache = name
      end
      rf2NamePending = false
    end, nil)
  end)
  if not ok then
    rf2NamePending = false
  end
end

local function resolveModelName()
  if rf2NameCache and rf2NameCache ~= "" then
    return rf2NameCache
  end

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

-- ===========================================================================
-- BATTERY -> FLIGHT CONTROLLER SYNC
-- ===========================================================================
-- Pushes a battery profile's usable capacity + HV/non-HV max cell voltage
-- to the FC via Rotorflight's MSP_BATTERY_CONFIG, for the given battery-
-- profile slot. Slot numbers here are the same 1-6 "unique number"
-- already used elsewhere in this widget (battery.models[modelName] =
-- slot) -- the FC's own battery profile slots are 0-5, so we subtract 1
-- when talking to MSP.
--
-- NOTE: this does NOT select the FC's *active* battery profile via MSP.
-- Rotorflight picks the active profile itself, continuously, from a
-- channel/GV range rule -- which is exactly what safeSetGV() already
-- drives elsewhere in this widget. A one-shot MSP_SET_BATTERY_PROFILE
-- write only "sticks" for an instant before the FC's own rule engine
-- re-evaluates that channel and switches back, which is the flicker
-- some users saw. So profile *selection* stays entirely on the GV/channel
-- mechanism; MSP here only ever updates the config (capacity/voltage)
-- for a slot, never which slot is active.
-- What gets written to the FC's vbatmaxcellvoltage (scale=100 per
-- mspBatteryConfig.lua). These are MAX cell voltages -- the ceiling the FC
-- allows -- deliberately a little above the nominal full-charge voltage of
-- each chemistry (4.20V LiPo / 4.35V HV), so a freshly charged pack doesn't
-- trip the limit. Don't confuse the two: the editor displays the nominal
-- charge voltage, which is what identifies the chemistry.
local VBAT_MAX_CELL_HV  = 440 -- 4.40V ceiling for 4.35V HV cells
local VBAT_MAX_CELL_STD = 430 -- 4.30V ceiling for 4.20V LiPo cells

-- One explicit state machine instead of the loose flags this used to be.
-- Every earlier bug here was an illegal combination of those flags:
-- "busy but nothing in flight" (dropped MSP reply deadlocked all later
-- syncs), "queued forever" (retry with no failure exit), "write enqueued
-- but pump already switched off" (value landed one selection late). With
-- a single `state` field those combinations can't be represented.
--
--   idle     -> nothing to do
--   pending  -> a sync is wanted; waiting on RF2/apiVersion to be ready
--   reading  -> MSP_BATTERY_CONFIG read issued, awaiting reply
--   failed   -> gave up; `error` explains why (shown in the UI)
--
-- `request` always holds the most recent desired state, so a newer
-- selection supersedes an older in-flight one rather than queueing behind
-- it -- the user only ever cares about the battery they picked last.
local FC_SYNC_TIMEOUT = 500 -- 5s (getTime() is 10ms ticks)

local battSync = {
  state   = "idle",
  request = nil,  -- { profile = <battery>, slot = 1-6 }
  started = 0,
  error   = nil,
}

local function battSyncFail(msg)
  battSync.state   = "failed"
  battSync.error   = msg
  battSync.request = nil
end

-- Public entry point: "make the FC match this battery". Safe to call as
-- often as you like -- it records intent and lets tickBatterySync() do the
-- work on subsequent frames, so no caller ever blocks on MSP.
local function requestBatterySync(battProfile, slotNum)
  if not battProfile or not slotNum or slotNum < 1 or slotNum > 6 then return end
  battSync.request = { profile = battProfile, slot = slotNum }
  battSync.error   = nil
  if battSync.state ~= "reading" then
    battSync.state = "pending"
  end
end

-- Issues the MSP read for the current request. The actual write happens in
-- the reply callback, because MSP_SET_BATTERY_CONFIG rewrites every field
-- and so needs the FC's current values as a base.
local function battSyncStartRead(req)
  local api = RF2.script("MSP/mspBatteryConfig")
  if not api then
    battSyncFail(RF2.lastError or "No mspBatteryConfig")
    return
  end

  battSync.state   = "reading"
  battSync.started = getTime()

  local ok = pcall(function()
    api.read(function(_, cfg)
      local usableCap = math.floor(safeNum(req.profile.cap, 0) * safeNum(req.profile.usablePct, 100) / 100)
      local slotIdx0  = req.slot - 1

      if cfg.batteryCapacity and cfg.batteryCapacity.value ~= nil then
        -- Pre-12.09 API: one single global capacity value, no per-slot array.
        cfg.batteryCapacity.value = usableCap
      elseif cfg.batteryCapacity and cfg.batteryCapacity[slotIdx0] then
        cfg.batteryCapacity[slotIdx0].value = usableCap
      end

      cfg.vbatmaxcellvoltage.value = (req.profile.isHV == true) and VBAT_MAX_CELL_HV or VBAT_MAX_CELL_STD
      api.write(cfg) -- enqueues only; RF2.pump() every frame actually sends it

      battSync.state = "idle"
    end, nil, api.getDefaults())
  end)

  if not ok then
    battSyncFail("MSP read failed")
  end
end

-- Drives the state machine. Must be called once per frame.
local function tickBatterySync()
  if battSync.state == "reading" then
    -- The MSP queue drops a message silently once it exhausts maxRetries,
    -- so the reply callback may simply never fire. Without this timeout
    -- the machine would sit in "reading" forever and block every later
    -- sync.
    if (getTime() - battSync.started) > FC_SYNC_TIMEOUT then
      battSyncFail("FC sync timeout")
    end
    return
  end

  if battSync.state ~= "pending" then return end

  local req = battSync.request
  if not req then
    battSync.state = "idle"
    return
  end

  if not RF2.ensure() then
    battSyncFail(RF2.lastError or "RF2 unavailable")
    return
  end
  -- getDefaults() compares rf2.apiVersion against a number, so it must be
  -- known before we touch mspBatteryConfig at all.
  if not RF2.ensureApiVersion() then
    if RF2.lastError then battSyncFail(RF2.lastError) end
    return -- otherwise still waiting; retry next frame
  end

  battSync.request = nil
  battSyncStartRead(req)
end

-- For the UI indicator.
local function battSyncStatus()
  if battSync.state == "failed" then return "error", battSync.error end
  if battSync.state ~= "idle" or RF2.isApiVersionPending() then return "busy", nil end
  return "idle", nil
end

-- Kick off loading the RF2/MSP scripts + apiVersion as soon as a model
-- connects, so the first battery selection doesn't have to wait for it.
local function beginBattFcInit()
  if RF2.ensure() then
    RF2.ensureApiVersion()
  end
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
      flights = safeNum(item.flights, 0),
      isHV = (item.isHV == true),
      usablePct = math.max(1, math.min(100, safeNum(item.usablePct, 100))),
    }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- CRASH-SAFE PERSISTENCE
-- ---------------------------------------------------------------------------
-- io.open(path, "w") truncates immediately, so switching the transmitter off
-- part-way through a write used to leave a half-written file -- and with it
-- every battery profile and flight count gone. EdgeTX's Lua io has no
-- rename() or remove(), so the usual write-temp-then-swap trick isn't
-- available. Instead we always write the backup copy FIRST and verify it
-- parses, and only then touch the real file. If power is lost while the real
-- file is being written, the verified backup still holds the previous good
-- data and the loader falls back to it.

-- Writes `body` (a function that emits the file contents) to `path`.
local function writeFileAtomicish(path, emit)
  local f = io.open(path, "w")
  if not f then return false end
  local ok = pcall(emit, f)
  io.close(f)
  return ok
end

-- Confirms a file parses as Lua and returns a table.
local function fileLoadsAsTable(path)
  local ok, data = pcall(dofile, path)
  return ok and type(data) == "table", data
end

-- Write to backup, verify, then write the live file. Returns false if the
-- live file could not be written OR came back unparseable.
local function saveVerified(path, bakPath, emit)
  if not writeFileAtomicish(bakPath, emit) then return false end
  if not fileLoadsAsTable(bakPath) then return false end
  if not writeFileAtomicish(path, emit) then return false end
  return (fileLoadsAsTable(path))
end

-- Loads `path`, falling back to the backup if the live file is missing or
-- was corrupted by a power loss mid-write.
local function loadVerified(path, bakPath)
  local ok, data = fileLoadsAsTable(path)
  if ok then return data, false end
  local okBak, bakData = fileLoadsAsTable(bakPath)
  if okBak then return bakData, true end
  return nil, false
end

local function emitProfiles(profiles)
  return function(f)
    io.write(f, "return {\n")
    for i = 1, #profiles do
      local p = profiles[i] or {}
      local eName = string.gsub(p.name or "", '"', '\\"')

      io.write(f, string.format('  { name="%s", cap=%d, flights=%d, isHV=%s, usablePct=%d, models={ ',
        eName, math.floor(safeNum(p.cap, 0)), math.floor(safeNum(p.flights, 0)),
        (p.isHV == true) and "true" or "false",
        math.floor(math.max(1, math.min(100, safeNum(p.usablePct, 100))))))

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
  end
end

local function saveProfilesToSD(profiles)
  return saveVerified(BATTERIES_PATH, BATTERIES_BAK, emitProfiles(profiles or {}))
end


-- ===========================================================================
-- MODEL IMAGE HELPERS
-- ===========================================================================
local function loadModelMap()
  local data = loadVerified(MODEL_MAP_PATH, MODEL_MAP_BAK)
  return data or {}
end

local function saveModelMap(modelMap)
  modelMap = modelMap or {}
  return saveVerified(MODEL_MAP_PATH, MODEL_MAP_BAK, function(f)
    io.write(f, "return {\n")
    for mName, imgName in pairs(modelMap) do
      local eName = string.gsub(mName or "", '"', '\\"')
      local eImg = string.gsub(imgName or "", '"', '\\"')
      io.write(f, string.format('  ["%s"] = "%s",\n', eName, eImg))
    end
    io.write(f, "}\n")
  end)
end

-- Recognized image file extensions for the model-image picker.
local IMAGE_EXTENSIONS = { bmp = true, png = true, jpg = true, jpeg = true }

-- Scan MODEL_IMAGE_DIR directly via EdgeTX's dir() iterator, so images
-- dropped onto the SD card show up automatically without needing to be
-- listed by hand in modelimages.lua.
local function scanModelImageDir()
  if type(dir) ~= "function" then return nil end
  local out = {}
  local ok = pcall(function()
    for fname in dir(MODEL_IMAGE_DIR) do
      if type(fname) == "string" and fname ~= "" and string.sub(fname, -1) ~= "/" then
        local ext = string.lower(string.match(fname, "%.([%a%d]+)$") or "")
        if IMAGE_EXTENSIONS[ext] then
          out[#out + 1] = fname
        end
      end
    end
  end)
  if ok and #out > 0 then
    table.sort(out)
    return out
  end
  return nil
end

-- True only if the file is actually on the card right now.
local function modelImageExists(fname)
  if type(fname) ~= "string" or fname == "" then return false end
  local f = io.open(MODEL_IMAGE_DIR .. fname, "r")
  if f then io.close(f); return true end
  return false
end

local function loadAvailableImages()
  -- Candidates come from a directory scan where the radio supports dir(),
  -- otherwise from the hand-maintained modelimages.lua.
  local list = scanModelImageDir()
  if not list then
    local ok, data = pcall(dofile, MODEL_IMAGES_LIST_PATH)
    list = (ok and type(data) == "table") and data or {}
  end

  -- Either source can name files that are no longer on the card:
  -- modelimages.lua is edited by hand and goes stale as soon as an image is
  -- deleted, and a cached directory listing can lag too. Offering a file
  -- that cannot be opened just produces a blank model picture, so each
  -- candidate is confirmed to exist before it reaches the list.
  local out = {}
  for i = 1, #list do
    if modelImageExists(list[i]) then out[#out + 1] = list[i] end
  end
  return out
end

-- Opens a model picture and scales it to the size this screen draws them at.
local function openModelBitmap(path)
  local bmp = safeOpenBitmap(path)
  if not bmp then return nil end
  return scaleBitmap(bmp, MODEL_IMG_W, MODEL_IMG_H)
end

local function resolveModelImage(modelName, modelMap)
  if not modelName or modelName == "" then return nil end
  local imgFile = modelMap[modelName]
  if not imgFile or imgFile == "" then return nil end
  local path = MODEL_IMAGE_DIR .. imgFile
  local f = io.open(path, "r")
  if f then io.close(f); return path end
  return nil
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

local function borderedCard(x, y, w, h, fillColor, borderColor, borderPx)
  borderPx = borderPx or 2
  roundRect(x, y, w, h, 4, borderColor or C_NAVY)
  roundRect(x + borderPx, y + borderPx, w - borderPx*2, h - borderPx*2, 3, fillColor or C_BLACK)
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
  if fw > 4 then roundRect(x, y, fw, h,0, fillColor or pctColor(pct)) end
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
local RQLY_ICON_FILES={"icon_40_0.png","icon_40_1.png","icon_40_2.png","icon_40_3.png","icon_40_4.png"}
local ICON_DIR = "/WIDGETS/"..name.."/icons/"

-- ===========================================================================
-- TOUCH KEYBOARD MODAL
-- ===========================================================================
-- ===========================================================================
-- ENCODER / BUTTON NAVIGATION
-- ===========================================================================
-- Every screen that can be driven by touch should also be reachable with the
-- rotary encoder and the physical keys, since that is all you have with the
-- transmitter on a strap. The pattern below is deliberately uniform:
--
--   NEXT / PREV  move a focus index (wrapping, like an encoder should)
--   ENTER        activates whatever is focused
--   EXIT         backs out one level
--
-- Screens declare their focusable targets as a flat list, so "what does
-- ENTER do here" is answered by one table rather than by a branch per
-- control -- which is what kept the touch and key paths in sync earlier.

-- Advance a wrapping focus index. Returns the index unchanged for any other
-- key, so callers can pass every keyEvt through it.
local function focusStep(cur, count, keyEvt)
  if count <= 0 then return 1 end
  cur = math.max(1, math.min(count, safeNum(cur, 1)))
  if keyEvt == "NEXT" then
    return (cur % count) + 1
  elseif keyEvt == "PREV" then
    return ((cur - 2) % count) + 1
  end
  return cur
end

-- Keep a focused item inside a scrolling window of `visible` rows.
local function scrollToFocus(focus, scroll, visible, total)
  scroll = math.max(0, math.min(safeNum(scroll, 0), math.max(0, total - visible)))
  if focus <= scroll then
    scroll = focus - 1
  elseif focus > scroll + visible then
    scroll = focus - visible
  end
  return math.max(0, math.min(scroll, math.max(0, total - visible)))
end

-- Draw a button and report whether it was pressed this frame.
--
-- The hit-test, the filled rect and the label previously appeared as three
-- separate calls at ~47 sites, each repeating the same x/y/w/h four times.
-- Any typo among those copies silently desynced the touch target from the
-- visible button, which is invisible in review and annoying to find on the
-- radio. Passing the geometry once removes that whole class of bug.
--
-- opts (all optional):
--   color     fill colour (default C_SLATE)
--   font      MEDIUM / BIG etc; default SMALL
--   textColor default C_WHITE
--   dy        label vertical offset inside the button (default centred-ish)
--   radius    corner radius (default 4)
--   slop      extra touch margin passed to isBtnPressed
--   focus     draw the white keyboard-focus ring around the button
local function drawButton(widget, tx, ty, ce, x, y, w, h, label, opts)
  opts = opts or {}
  local pressed = isBtnPressed(widget, tx, ty, ce, x, y, w, h, opts.slop)

  if opts.focus then
    roundRect(x - 3, y - 3, w + 6, h + 6, 6, C_WHITE)
  end
  roundRect(x, y, w, h, opts.radius or 4, btnColor(widget, x, y, w, h, opts.color or C_SLATE))

  if label then
    local font = opts.font or SMALL
    -- dy is centred from the real font height; call sites only override it
    -- when a label is deliberately off-centre.
    local dy   = opts.dy or textCenterY(h, font)
    lcdDrawText(x + w/2, y + dy, label, font + CENTER + (opts.textColor or C_WHITE))
  end
  return pressed
end

-- Commit the edited buffer to the selected battery. Shared by the text
-- keyboard and the numeric pad so the two input methods can never disagree
-- about how a field is parsed or clamped.
-- Keyboard/numpad focus starts on Done: after typing on the touchscreen the
-- next thing you want is to commit, and it gives the encoder a safe default.
local function openFieldEditor(widget, field, initial)
  widget.editingField   = field
  widget.keyboardBuffer = tostring(initial or "")
  widget.kbFocus        = nil -- resolved to Done by the modal
end

local function commitEditField(widget, field, buffer)
  local target = widget.editProfiles and widget.editSelected
                 and widget.editProfiles[widget.editSelected]
  if not target then return end

  local spec = NUMERIC_FIELDS[field]
  if spec then
    local num = tonumber(buffer)
    if not num then num = safeNum(target[field], spec.default) end
    num = math.max(spec.min, math.min(spec.max, math.floor(num)))
    target[field] = num
    return
  end

  if field == "name" then
    target.name = (buffer ~= "") and buffer or "Battery"
  elseif field == "model" then
    if buffer ~= "" then
      target.models = target.models or {}
      local freeSlot = getNextFreeSlot(widget.editProfiles, buffer)
      assignModelSlot(widget.editProfiles, target, buffer, freeSlot)
    end
  end
end

-- Numeric entry pad. Used instead of the full keyboard for the fields in
-- NUMERIC_FIELDS: only digits are reachable, the valid range is shown, the
-- value is validated as you type, and for capacity/usable-% it previews the
-- figure that will actually be sent to the flight controller.
local function drawNumpadModal(widget, zx, zy, tx, ty, clickEvent, keyEvt)
  local field = widget.editingField
  local spec  = NUMERIC_FIELDS[field]
  widget.keyboardBuffer = widget.keyboardBuffer or ""

  -- On a numeric field the encoder adjusts the VALUE rather than cycling
  -- focus through sixteen keys -- that is what a rotary control is for, and
  -- it reaches any value in far fewer clicks than tabbing to digits.
  if keyEvt == "NEXT" or keyEvt == "PREV" then
    local cur  = tonumber(widget.keyboardBuffer) or safeNum(spec.default, spec.min)
    local step = safeNum(spec.step, 1)
    cur = cur + ((keyEvt == "NEXT") and step or -step)
    widget.keyboardBuffer = tostring(math.max(spec.min, math.min(spec.max, math.floor(cur))))
  elseif keyEvt == "ENTER" then
    commitEditField(widget, field, widget.keyboardBuffer)
    widget.editingField = nil
    return clickEvent
  elseif keyEvt == "EXIT" then
    widget.editingField = nil
    return clickEvent
  end

  local buf = widget.keyboardBuffer

  roundRect(zx, zy, 480, 320, 0, C_SURFACE)
  roundRect(zx, zy, 480, 38, 0, C_BLACK)
  lcdDrawText(zx+12, zy+5, spec.title, BIG+C_WHITE)
  lcdDrawText(zx+468, zy+10, spec.min .. " - " .. spec.max .. " " .. spec.unit, SMALL+RIGHT+C_LABEL)

  -- Value display. Out-of-range shows red immediately rather than silently
  -- clamping only once Done is pressed.
  local num = tonumber(buf)
  local inRange = (num ~= nil) and num >= spec.min and num <= spec.max
  local valColor = (buf == "") and C_LABEL or (inRange and C_ROW_TXT or C_RED)

  roundRect(zx+10, zy+44, 460, 40, 4, C_CARD)
  lcdDrawText(zx+20, zy+50, (buf == "" and "0" or buf) .. "_", BIG + valColor)
  if spec.unit ~= "" then
    lcdDrawText(zx+460, zy+54, spec.unit, MEDIUM+RIGHT+C_LABEL)
  end

  -- Keypad, left side. Heights are tight here: header + value box + four
  -- key rows + the action row have to fit 320px, so keyH/gap are sized so
  -- the "0"/"00" row clears the Done/Cancel row below it.
  local keyW, keyH, gap = 90, 38, 5
  local padX, padY = zx + 14, zy + 90

  for r, row in ipairs(NUMPAD_ROWS) do
    for c, digit in ipairs(row) do
      local kx = padX + (c - 1) * (keyW + gap)
      local ky = padY + (r - 1) * (keyH + gap)
      if drawButton(widget, tx, ty, clickEvent, kx, ky, keyW, keyH, digit, {color=C_SURFACE_HI, font=MEDIUM,slop=2}) then
        if #buf < 6 then widget.keyboardBuffer = buf .. digit end
        clickEvent = false
      end
    end
  end

  local zeroY = padY + 3 * (keyH + gap)
  if drawButton(widget, tx, ty, clickEvent, padX, zeroY, keyW * 2 + gap, keyH, "0", {color=C_SURFACE_HI, font=MEDIUM,slop=2}) then
    if #buf < 6 then widget.keyboardBuffer = buf .. "0" end
    clickEvent = false
  end
  if drawButton(widget, tx, ty, clickEvent, padX + 2*(keyW+gap), zeroY, keyW, keyH, "00", {color=C_SURFACE_HI, font=MEDIUM,slop=2}) then
    if #buf < 5 then widget.keyboardBuffer = buf .. "00" end
    clickEvent = false
  end

  -- Right-hand column: edit actions and the live hint.
  local rX, rW = zx + 310, 156

  if drawButton(widget, tx, ty, clickEvent, rX, padY, rW, keyH, "< Back", {color=C_ORANGE,slop=2}) then
    widget.keyboardBuffer = string.sub(buf, 1, -2)
    clickEvent = false
  end
  if drawButton(widget, tx, ty, clickEvent, rX, padY + (keyH + gap), rW, keyH, "Clear", {color=C_RED,slop=2}) then
    widget.keyboardBuffer = ""
    clickEvent = false
  end
  if drawButton(widget, tx, ty, clickEvent, rX, padY + 2*(keyH + gap), rW, keyH, "Max: " .. spec.max, {color=C_BLUE,slop=2}) then
    widget.keyboardBuffer = tostring(spec.max)
    clickEvent = false
  end

  -- Live feedback: for the two fields that feed the FC, preview the usable
  -- capacity that will actually be written, so the effect of the number is
  -- visible before committing it.
  local hintY = padY + 3*(keyH + gap) + 6
  lcdDrawText(rX, hintY + 16, "Encoder: +/-" .. safeNum(spec.step, 1), SMALL + C_LABEL)
  local target = widget.editProfiles and widget.editSelected and widget.editProfiles[widget.editSelected]
  if buf ~= "" and not inRange then
    lcdDrawText(rX, hintY, "Out of range", SMALL+C_RED)
  elseif target and (field == "cap" or field == "usablePct") then
    local cap = (field == "cap")       and (num or 0) or safeNum(target.cap, 0)
    local pct = (field == "usablePct") and (num or 0) or safeNum(target.usablePct, 100)
    if inRange then
      lcdDrawText(rX, hintY, "To FC: " .. math.floor(cap * pct / 100) .. " mAh", SMALL+C_TEAL)
    end
  end

  -- Bottom actions.
  local aY, aH = zy + 264, 46
  if drawButton(widget, tx, ty, clickEvent, zx + 14, aY, 220, aH, "Done", {color=C_TEAL, font=MEDIUM,slop=2, focus = (kbFocus == OK_F)}) then
    commitEditField(widget, field, widget.keyboardBuffer)
    widget.editingField = nil
    clickEvent = false
  end
  if drawButton(widget, tx, ty, clickEvent, zx + 246, aY, 220, aH, "Cancel", {color=C_GREY, font=MEDIUM,slop=2}) then
    widget.editingField = nil
    clickEvent = false
  end

  return clickEvent
end

local function drawKeyboardModal(widget, zx, zy, tx, ty, clickEvent, keyEvt)
  -- Numeric fields get a digits-only pad instead of the full keyboard.
  if NUMERIC_FIELDS[widget.editingField] then
    return drawNumpadModal(widget, zx, zy, tx, ty, clickEvent, keyEvt)
  end

  widget.keyboardBuffer = widget.keyboardBuffer or ""
  local field = widget.editingField or "name"

  local title = "EDIT BATTERY NAME"
  if field == "cap" then title = "EDIT CAPACITY (mAh)"
  elseif field == "model" then title = "ADD MODEL LOCK"
  elseif field == "flights" then title = "EDIT FLIGHT COUNT" end

  roundRect(zx, zy, 480, 320, 0, C_SURFACE)
  roundRect(zx, zy, 480, 38, 0, C_BLACK)
  lcdDrawText(zx+12, zy+5, title, BIG+C_WHITE)

  roundRect(zx+10, zy+44, 460, 36, 4, C_CARD)
  lcdDrawText(zx+20, zy+48, (widget.keyboardBuffer or "") .. "_", MEDIUM+C_ROW_TXT)

  local startY = zy + 88
  local keyH, gap = 34, 4

  -- Linear focus across every character key, then the five action buttons.
  -- Cycling ~38 keys with an encoder is slow, but it is the only way to
  -- enter text without the touchscreen, and EXIT always gets you out.
  local flatKeys = {}
  for _, row in ipairs(KEYBOARD_ROWS) do
    for _, ch in ipairs(row) do flatKeys[#flatKeys+1] = ch end
  end
  local nKeys = #flatKeys
  local BS_F, SP_F, CLR_F, OK_F, CAN_F = nKeys+1, nKeys+2, nKeys+3, nKeys+4, nKeys+5
  local kbFocus = focusStep(safeNum(widget.kbFocus, OK_F), nKeys + 5, keyEvt)
  widget.kbFocus = kbFocus

  if keyEvt == "EXIT" then
    widget.editingField = nil
    return clickEvent
  elseif keyEvt == "ENTER" then
    if kbFocus <= nKeys then
      if #(widget.keyboardBuffer or "") < 18 then
        widget.keyboardBuffer = (widget.keyboardBuffer or "") .. flatKeys[kbFocus]
      end
    elseif kbFocus == BS_F then
      widget.keyboardBuffer = string.sub(widget.keyboardBuffer or "", 1, -2)
    elseif kbFocus == SP_F then
      if #(widget.keyboardBuffer or "") < 18 then
        widget.keyboardBuffer = (widget.keyboardBuffer or "") .. " "
      end
    elseif kbFocus == CLR_F then
      widget.keyboardBuffer = ""
    elseif kbFocus == OK_F then
      commitEditField(widget, field, widget.keyboardBuffer)
      widget.editingField = nil
    else
      widget.editingField = nil
    end
    return clickEvent
  end

  local keyOrdinal = 0

  for rIdx, row in ipairs(KEYBOARD_ROWS) do
    local keyW = (#row == 10) and 44 or 48
    local rowW = #row * keyW + (#row - 1) * gap
    local startX = zx + math.floor((480 - rowW) / 2)
    local kY = startY + (rIdx - 1) * (keyH + gap)

    for cIdx, char in ipairs(row) do
      local kX = startX + (cIdx - 1) * (keyW + gap)
      keyOrdinal = keyOrdinal + 1
      if drawButton(widget, tx, ty, clickEvent, kX, kY, keyW, keyH, char,
                    {color=C_SURFACE_HI,slop=2, focus = (kbFocus == keyOrdinal)}) then
        if #widget.keyboardBuffer < 18 then
          widget.keyboardBuffer = widget.keyboardBuffer .. char
        end
        clickEvent = false
      end
    end
  end

  local actY = zy + 256
  local actH = 54

  local bsX, bsW = zx + 8, 84
  if drawButton(widget, tx, ty, clickEvent, bsX, actY, bsW, actH, "< Back", {color=C_ORANGE,slop=2, focus = (kbFocus == BS_F)}) then
    if #widget.keyboardBuffer > 0 then
      widget.keyboardBuffer = string.sub(widget.keyboardBuffer, 1, -2)
    end
    clickEvent = false
  end

  local spX, spW = bsX + bsW + 6, 96
  if drawButton(widget, tx, ty, clickEvent, spX, actY, spW, actH, "Space", {color=C_SURFACE_HI,slop=2, focus = (kbFocus == SP_F)}) then
    if #widget.keyboardBuffer < 18 then
      widget.keyboardBuffer = widget.keyboardBuffer .. " "
    end
    clickEvent = false
  end

  local clrX, clrW = spX + spW + 6, 76
  if drawButton(widget, tx, ty, clickEvent, clrX, actY, clrW, actH, "Clear", {color=C_RED,slop=2, focus = (kbFocus == CLR_F)}) then
    widget.keyboardBuffer = ""
    clickEvent = false
  end

  local okX, okW = clrX + clrW + 6, 104
  local okPressed = drawButton(widget, tx, ty, clickEvent, okX, actY, okW, actH, "Done", {color=C_TEAL, font=MEDIUM,slop=2})
  if okPressed then
    commitEditField(widget, field, widget.keyboardBuffer)
    widget.editingField = nil
    clickEvent = false
  end

  local canX, canW = okX + okW + 6, 86
  if drawButton(widget, tx, ty, clickEvent, canX, actY, canW, actH, "Cancel", {color=C_GREY,slop=2, focus = (kbFocus == CAN_F)}) then
    widget.editingField = nil
    clickEvent = false
  end

  return clickEvent
end

-- ===========================================================================
-- MODELS MANAGEMENT MODAL & NUMBER PICKER
-- ===========================================================================
-- Scratch buffers for the model lists below. These are rebuilt every frame
-- (cheap for a handful of entries) but reusing the tables avoids allocating
-- a fresh list, a seen-set and an entry table per model on every redraw.
local mmKnown, mmSeen, mmList = {}, {}, {}
local function mmByName(a, b) return a.name < b.name end

local function clearArray(t)
  for i = #t, 1, -1 do t[i] = nil end
end

local function drawModelsModal(widget, zx, zy, tx, ty, clickEvent, keyEvt)
  local selIdx = safeNum(widget.editSelected, 1)
  local eps = widget.editProfiles or {}
  local sel = eps[selIdx]
  if not sel then
    widget.showModelsModal = false
    return clickEvent
  end

  sel.models = sel.models or {}

  -- ---------------------------------------------------------------------
  -- Model picker: choose from the models already known in model.lua rather
  -- than retyping a name. model.lua auto-populates whenever a new model
  -- connects, so this is effectively "every model this radio has seen".
  -- Tapping a row toggles assignment for the battery being edited.
  -- ---------------------------------------------------------------------
  if widget.modelPicker then
    local popW, popH = 440, 280
    -- Focus: 1..#known = model rows, then Type name, then Done.
    local pickFocus = safeNum(widget.modelPickerFocus, 1)
    local popX = zx + math.floor((480 - popW) / 2)
    local popY = zy + math.floor((320 - popH) / 2)

    roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_TEAL)
    roundRect(popX, popY, popW, popH, 6, C_SURFACE)
    roundRect(popX, popY, popW, 36, 6, C_BLACK)
    lcdDrawText(popX + popW/2, popY + textCenterY(36, MEDIUM), "ASSIGN MODELS", MEDIUM+CENTER+C_WHITE)

    -- Known models = keys of model.lua, plus anything already assigned to
    -- this battery (so a hand-typed name that predates model.lua still
    -- shows up and can be removed here).
    local known, seen = mmKnown, mmSeen
    clearArray(known)
    for k in pairs(seen) do seen[k] = nil end
    for mName in pairs(widget.modelImageMap or {}) do
      if mName ~= "" and not seen[mName] then seen[mName] = true; known[#known+1] = mName end
    end
    for mName in pairs(sel.models) do
      if mName ~= "" and not seen[mName] then seen[mName] = true; known[#known+1] = mName end
    end
    table.sort(known)

    local VISIBLE = 4
    local itemH   = 34
    local scroll  = safeNum(widget.modelPickerScroll, 0)
    local maxScroll = math.max(0, #known - VISIBLE)
    if scroll > maxScroll then scroll = maxScroll; widget.modelPickerScroll = scroll end

    -- Toggle assignment for a model. Shared by tap and ENTER so the two
    -- paths can't drift.
    local function togglePickerModel(mName)
      if not mName then return end
      if safeNum(sel.models[mName], 0) >= 1 then
        sel.models[mName] = nil
      else
        assignModelSlot(widget.editProfiles, sel, mName, getNextFreeSlot(widget.editProfiles, mName))
      end
    end

    local TYPE_FOCUS, DONE_FOCUS = #known + 1, #known + 2
    pickFocus = focusStep(pickFocus, #known + 2, keyEvt)
    widget.modelPickerFocus = pickFocus
    -- Only follow focus when the encoder moved it; otherwise this fights the
    -- up/down buttons (see the same note on the battery list).
    if (keyEvt == "NEXT" or keyEvt == "PREV") and pickFocus <= #known then
      scroll = scrollToFocus(pickFocus, scroll, VISIBLE, #known)
      widget.modelPickerScroll = scroll
    end

    if keyEvt == "EXIT" then
      widget.modelPicker = false
      return clickEvent
    elseif keyEvt == "ENTER" then
      if pickFocus == DONE_FOCUS then
        widget.modelPicker = false
      elseif pickFocus == TYPE_FOCUS then
        widget.modelPicker = false
        openFieldEditor(widget, "model", "")
      else
        togglePickerModel(known[pickFocus])
      end
      return clickEvent
    end

    if #known == 0 then
      lcdDrawText(popX + popW/2, popY + 100, "No models known yet", SMALL+CENTER+C_LABEL)
      lcdDrawText(popX + popW/2, popY + 120, "Connect a model, or type a name", SMALL+CENTER+C_LABEL)
    else
      local listY = popY + 45
      for vi = 1, VISIBLE do
        local i = vi + scroll
        local mName = known[i]
        if not mName then break end
        local iy = listY + (vi - 1) * (itemH + 4)
        local assignedSlot = safeNum(sel.models[mName], 0)
        local isAssigned = assignedSlot >= 1

        local rowW = popW - 20 - 60 -- leave room for the scroll buttons
        if isBtnPressed(widget, tx, ty, clickEvent, popX + 10, iy, rowW, itemH) then
          togglePickerModel(mName)
          clickEvent = false
        end
        if pickFocus == i then
          roundRect(popX + 7, iy - 3, rowW + 6, itemH + 6, 5, C_ORANGE)
        end
        -- Both states use the same card; assignment is shown by the green
        -- edge, the [x] and the darker text. Two near-white tints measured
        -- 1.04:1 apart, which is invisible -- one card plus clear markers
        -- beats two shades nobody can tell apart.
        roundRect(popX + 10, iy, rowW, itemH, 4,
          btnColor(widget, popX + 10, iy, rowW, itemH, C_CARD))
        if isAssigned then
          lcdDrawFilledRectangle(popX + 10, iy, 4, itemH, C_ROW_EDGE)
        end

        local rowTextY = iy + textCenterY(itemH, SMALL)
        lcdDrawText(popX + 22, rowTextY, isAssigned and "[x]" or "[ ]",
                    SMALL + (isAssigned and C_ROW_EDGE or C_LABEL))
        local mDisp = mName
        if #mDisp > 20 then mDisp = string.sub(mDisp, 1, 18) .. ".." end
        lcdDrawText(popX + 52, rowTextY, mDisp, SMALL + (isAssigned and C_ROW_TXT or C_LABEL))
        if isAssigned then
          lcdDrawText(popX + rowW - 5, rowTextY, "#" .. assignedSlot, SMALL+RIGHT+C_ROW_TXT)
        end
      end

      -- Scroll buttons down the right-hand edge.
      local sbX, sbW = popX + popW - 55, 45
      if scroll > 0 then
        if drawButton(widget, tx, ty, clickEvent, sbX, popY + 45, sbW, 34, "^", {color=C_BLUE}) then
          scroll = scroll - 1
          widget.modelPickerScroll = scroll
          if pickFocus <= #known then
            widget.modelPickerFocus = math.max(scroll + 1, math.min(scroll + VISIBLE, pickFocus))
          end
          clickEvent = false
        end
      end
      if scroll < maxScroll then
        local dY = popY + 45 + 3 * (itemH + 4)
        if drawButton(widget, tx, ty, clickEvent, sbX, dY, sbW, 34, "v", {color=C_BLUE}) then
          scroll = scroll + 1
          widget.modelPickerScroll = scroll
          if pickFocus <= #known then
            widget.modelPickerFocus = math.max(scroll + 1, math.min(scroll + VISIBLE, pickFocus))
          end
          clickEvent = false
        end
      end
    end

    local pbY, pbH = popY + 230, 38
    local typeX, typeW = popX + 10, 140
    if drawButton(widget, tx, ty, clickEvent, typeX, pbY, typeW, pbH, "Type name...",
                  {color=C_BLUE,focus = (pickFocus == TYPE_FOCUS)}) then
      widget.modelPicker = false
      openFieldEditor(widget, "model", "")
      clickEvent = false
    end

    local dbX, dbW = popX + popW - 10 - 140, 140
    if drawButton(widget, tx, ty, clickEvent, dbX, pbY, dbW, pbH, "Done",
                  {color=C_TEAL, font=MEDIUM,focus = (pickFocus == DONE_FOCUS)}) then
      widget.modelPicker = false
      clickEvent = false
    end

    return clickEvent
  end

  if widget.slotPickerModel then
    local mName = widget.slotPickerModel
    local popW, popH = 340, 220
    local popX = zx + math.floor((480 - popW) / 2)
    local popY = zy + math.floor((320 - popH) / 2)

    roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_TEAL)
    roundRect(popX, popY, popW, popH, 6, C_SURFACE)
    roundRect(popX, popY, popW, 36, 6, C_BLACK)

    local titleStr = "CHANGE NUMBER: " .. mName
    if #titleStr > 25 then titleStr = string.sub(titleStr, 1, 23) .. ".." end
    lcdDrawText(popX + popW/2, popY + textCenterY(36, SMALL), titleStr, SMALL+CENTER+C_WHITE)

    lcdDrawText(popX + popW/2, popY + 45, "Select Battery Number (1-6):", SMALL+CENTER+C_LABEL)

    local used = getUsedSlotsForModel(widget.editProfiles, mName, sel)
    local curSlot = safeNum(sel.models[mName], 1)

    -- Focus: slots 1-6, then Cancel (7). Used slots are skipped by ENTER
    -- rather than removed from the ring, so the numbers keep their fixed
    -- positions as you rotate through them.
    local slotFocus = focusStep(safeNum(widget.slotPickerFocus, curSlot), 7, keyEvt)
    widget.slotPickerFocus = slotFocus

    if keyEvt == "EXIT" then
      widget.slotPickerModel = nil
      return clickEvent
    elseif keyEvt == "ENTER" then
      if slotFocus == 7 then
        widget.slotPickerModel = nil
      elseif used[slotFocus] ~= true then
        assignModelSlot(widget.editProfiles, sel, mName, slotFocus)
        widget.slotPickerModel = nil
      end
      return clickEvent
    end

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

      if slotFocus == slot then
        roundRect(bx - 3, by - 3, btnW + 6, btnH + 6, 6, C_ORANGE)
      end

      if isUsed then
        roundRect(bx, by, btnW, btnH, 4, C_SURFACE_HI)
        lcdDrawText(bx + btnW/2, by + textCenterY(btnH, SMALL), "#" .. slot .. " (Used)", SMALL+CENTER+C_LABEL)
      elseif isCurrent then
        roundRect(bx, by, btnW, btnH, 4, C_TEAL)
        lcdDrawText(bx + btnW/2, by + textCenterY(btnH, MEDIUM), "#" .. slot, MEDIUM+CENTER+C_WHITE)
      else
        if drawButton(widget, tx, ty, clickEvent, bx, by, btnW, btnH, "#" .. slot, {color=C_BLUE, font=MEDIUM}) then
          assignModelSlot(widget.editProfiles, sel, mName, slot)
          widget.slotPickerModel = nil
          clickEvent = false
        end
      end
    end

    local canX, canY, canW, canH = popX + math.floor((popW - 100) / 2), popY + 175, 100, 32
    if drawButton(widget, tx, ty, clickEvent, canX, canY, canW, canH, "Cancel",
                  {color=C_GREY,focus = (slotFocus == 7)}) then
      widget.slotPickerModel = nil
      clickEvent = false
    end

    return clickEvent
  end

  local popW, popH = 440, 270
  local popX = zx + math.floor((480 - popW) / 2)
  local popY = zy + math.floor((320 - popH) / 2)

  roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_TEAL)
  roundRect(popX, popY, popW, popH, 6, C_SURFACE)
  roundRect(popX, popY, popW, 36, 6, C_BLACK)

  local headTitle = "MODELS FOR: " .. (sel.name or "Battery")
  if #headTitle > 30 then headTitle = string.sub(headTitle, 1, 28) .. ".." end
  lcdDrawText(popX + 15, popY + textCenterY(36, MEDIUM), headTitle, MEDIUM+C_WHITE)

  -- Entry tables are reused in place; only the trailing unused slots are
  -- dropped, so a redraw allocates nothing here.
  local modelList = mmList
  local nList = 0
  for mName, sNum in pairs(sel.models) do
    nList = nList + 1
    local e = modelList[nList]
    if e then e.name, e.slot = mName, safeNum(sNum, 1)
    else modelList[nList] = { name = mName, slot = safeNum(sNum, 1) } end
  end
  for i = #modelList, nList + 1, -1 do modelList[i] = nil end
  table.sort(modelList, mmByName)

  local listY = popY + 45
  local itemH = 34
  local shown = math.min(4, #modelList)

  -- Focus: for each visible row, its Num button then its Delete button;
  -- then Set Current, Choose Models, Close.
  local CUR_FOCUS   = 2 * shown + 1
  local PICK_FOCUS  = 2 * shown + 2
  local CLOSE_FOCUS = 2 * shown + 3
  local mFocus = focusStep(safeNum(widget.modelsModalFocus, CLOSE_FOCUS), CLOSE_FOCUS, keyEvt)
  widget.modelsModalFocus = mFocus

  if keyEvt == "EXIT" then
    widget.showModelsModal = false
    return clickEvent
  elseif keyEvt == "ENTER" then
    if mFocus == CLOSE_FOCUS then
      widget.showModelsModal = false
    elseif mFocus == PICK_FOCUS then
      widget.modelPicker = true
      widget.modelPickerScroll = 0
      widget.modelPickerFocus = 1
    elseif mFocus == CUR_FOCUS then
      if widget.cachedModelName and widget.cachedModelName ~= "" then
        assignModelSlot(widget.editProfiles, sel, widget.cachedModelName,
                        getNextFreeSlot(widget.editProfiles, widget.cachedModelName))
      end
    else
      local rowIdx = math.ceil(mFocus / 2)
      local item = modelList[rowIdx]
      if item then
        if mFocus % 2 == 1 then
          widget.slotPickerModel = item.name
          widget.slotPickerFocus = safeNum(item.slot, 1)
        else
          sel.models[item.name] = nil
        end
      end
    end
    return clickEvent
  end

  if #modelList == 0 then
    lcdDrawText(popX + popW/2, popY + 95, "No models assigned (Global Battery)", SMALL+CENTER+C_LABEL)
  else
    for i = 1, math.min(4, #modelList) do
      local item = modelList[i]
      local iy = listY + (i - 1) * (itemH + 4)

      roundRect(popX + 10, iy, popW - 20, itemH, 4, C_CARD)
      lcdDrawFilledRectangle(popX + 10, iy, 4, itemH, C_ROW_EDGE)

      local mDisp = item.name
      if #mDisp > 16 then mDisp = string.sub(mDisp, 1, 14) .. ".." end
      lcdDrawText(popX + 22, iy + textCenterY(itemH, SMALL), mDisp, SMALL+C_ROW_TXT)

      local numBtnX = popX + 210
      local numBtnW = 105
      if drawButton(widget, tx, ty, clickEvent, numBtnX, iy + 3, numBtnW, itemH - 6,
                    "Num: #" .. item.slot, {color=C_BLUE,focus = (mFocus == 2*i - 1)}) then
        widget.slotPickerModel = item.name
        widget.slotPickerFocus = safeNum(item.slot, 1)
        clickEvent = false
      end

      local delBtnX = popX + 325
      local delBtnW = 85
      if drawButton(widget, tx, ty, clickEvent, delBtnX, iy + 3, delBtnW, itemH - 6, "Delete",
                    {color=C_RED,focus = (mFocus == 2*i)}) then
        sel.models[item.name] = nil
        clickEvent = false
      end
    end
  end

  local bY = popY + 220
  local bH = 38

  local addCurX, addCurW = popX + 10, 130
  if drawButton(widget, tx, ty, clickEvent, addCurX, bY, addCurW, bH, "+ Set Current",
                {color=C_TEAL,focus = (mFocus == CUR_FOCUS)}) then
    if widget.cachedModelName and widget.cachedModelName ~= "" then
      local freeSlot = getNextFreeSlot(widget.editProfiles, widget.cachedModelName)
      assignModelSlot(widget.editProfiles, sel, widget.cachedModelName, freeSlot)
    end
    clickEvent = false
  end

  local addNewX, addNewW = addCurX + addCurW + 8, 130
  if drawButton(widget, tx, ty, clickEvent, addNewX, bY, addNewW, bH, "Choose Models",
                {color=C_BLUE,focus = (mFocus == PICK_FOCUS)}) then
    widget.modelPicker = true
    widget.modelPickerScroll = 0
    widget.modelPickerFocus = 1
    clickEvent = false
  end

  local closeX, closeW = addNewX + addNewW + 8, 134
  if drawButton(widget, tx, ty, clickEvent, closeX, bY, closeW, bH, "Close",
                {color=C_GREY, font=MEDIUM,focus = (mFocus == CLOSE_FOCUS)}) then
    widget.showModelsModal = false
    clickEvent = false
  end

  return clickEvent
end

-- ===========================================================================
-- EDITOR SCREENS
-- ===========================================================================
-- Split across two screens:
--   "edit"     -- pick / add / delete a battery (the list)
--   "editbatt" -- edit the parameters of the battery you picked
--
-- One screen couldn't do both: six property rows at a readable size need
-- the full width, which left no room for the list beside them. Splitting
-- also removes the label/value overlap, since each row now owns the whole
-- 460px width instead of sharing a 314px panel.
local ED = {
  headH  = 36,

  -- list screen
  lRowX  = 10,  lRowW = 414, lRowH = 38, lRowGap = 4, lVisible = 5, lTop = 42,
  lSbarX = 432, lSbarW = 38,
  lAddY  = 256, lAddH = 44,

  -- parameter screen
  pRowX  = 10,  pRowW = 460, pRowH = 40, pRowGap = 5, pTop = 44,

  -- header buttons (both screens)
  hBtnY  = 4,   hBtnH = 28,
}

-- A settings row on a light card, matching the battery select screen:
-- muted label on the left, strong dark value on the right, whole row is the
-- touch target.
local function drawPropRow(widget, tx, ty, ce, x, y, w, h, label, value, opts)
  opts = opts or {}
  local pressed = isBtnPressed(widget, tx, ty, ce, x, y, w, h)
  if opts.focus then
    roundRect(x - 3, y - 3, w + 6, h + 6, 6, C_ORANGE)
  end
  roundRect(x, y, w, h, 4, btnColor(widget, x, y, w, h, opts.color or C_ROW))

  local textY = y + textCenterY(h, MEDIUM)
  lcdDrawText(x + 12, textY, label, MEDIUM + C_LABEL)

  local chevW = opts.chevron and 16 or 0
  lcdDrawText(x + w - 12 - chevW, textY, value, MEDIUM + RIGHT + (opts.accent or C_ROW_TXT))
  if opts.chevron then
    lcdDrawText(x + w - 10, textY, ">", MEDIUM + RIGHT + C_LABEL)
  end
  return pressed
end

-- Shared by the Save button on both screens, so they can't diverge.
local function saveEditProfiles(widget)
  local ok = saveProfilesToSD(widget.editProfiles)
  if ok then
    widget.allProfiles  = deepCopyProfiles(widget.editProfiles)
    widget.profiles     = getFilteredProfiles(widget.cachedModelName, widget.allProfiles)
    widget.batteryIndex = math.max(1, math.min(safeNum(widget.batteryIndex, 1), #widget.profiles))
    widget.editStatusMsg = STR_SAVED
    -- If a model is currently connected and already has a battery
    -- selected, re-push it to the FC in case what just got edited
    -- (capacity, usable %, HV flag) belongs to that same battery.
    if widget.wasConnected then
      local curProf = widget.profiles[widget.batteryIndex]
      if curProf then
        local slot = getBatterySlotForModel(curProf, widget.cachedModelName)
        if slot then requestBatterySync(curProf, slot) end
      end
    end
  else
    widget.editStatusMsg = STR_SAVE_ERR
  end
  widget.editStatusEnd = getTime() + 300
end

-- Transient "Saved" / "Save failed!" chip. Drawn in the header strip on
-- both screens; returns true while visible so the caller can hide whatever
-- else lives there rather than overlapping it.
local function editToastActive(widget)
  if (widget.editStatusMsg or "") == "" then return false end
  if getTime() >= safeNum(widget.editStatusEnd, 0) then
    widget.editStatusMsg = ""
    return false
  end
  return true
end

local function drawEditToast(widget, zx, zy)
  local err = (widget.editStatusMsg == STR_SAVE_ERR)
  local tW, tH = 130, 24
  local tX = zx + 140
  roundRect(tX, zy + 6, tW, tH, 4, err and C_RED or C_TEAL)
  lcdDrawText(tX + tW/2, zy + 9, widget.editStatusMsg, SMALL+CENTER+C_WHITE)
end

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
  widget.modelPicker     = false
  widget.modelPickerScroll = 0
  widget.pendingDeleteIndex = nil
  widget.editListFocus  = 1
  widget.editBattFocus  = 1
  widget.modelsModalFocus = 1
  widget.modelPickerFocus = 1
  setScreen(widget, "edit")
end

-- ---------------------------------------------------------------------------
-- SCREEN 1: battery list
-- ---------------------------------------------------------------------------
local function drawEditListScreen(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt)
  local eps  = widget.editProfiles or {}
  local scr  = safeNum(widget.editScrollOff, 0)
  local step = ED.lRowH + ED.lRowGap

  local maxScroll = math.max(0, #eps - ED.lVisible)
  if scr > maxScroll then scr = maxScroll; widget.editScrollOff = scr end

  -- Delete confirmation. Deletes are written to SD immediately, so there is
  -- no "just don't save" undo -- the confirm step is the only thing standing
  -- between a mis-tap and a lost battery. Index is re-validated because the
  -- list can change between frames.
  local delIdx = widget.pendingDeleteIndex
  if delIdx and not eps[delIdx] then delIdx = nil; widget.pendingDeleteIndex = nil end
  local hasModal = (delIdx ~= nil)
  local bodyClick = (not hasModal) and clickEvent

  -- Focus map. Each battery gets two stops -- the row itself and its X --
  -- so the encoder can reach delete without a separate mode. The Add button
  -- is the last stop, and Back the one after that.
  --   battery i  ->  row = 2i-1, delete = 2i
  --   add        ->  2n+1
  --   back       ->  2n+2
  local nBatt     = #eps
  local ADD_FOCUS = 2 * nBatt + 1
  local BACK_FOCUS= 2 * nBatt + 2
  local focus     = safeNum(widget.editListFocus, 1)

  if hasModal then
    -- While the confirm dialog is up the encoder drives the dialog, not the
    -- list underneath it.
    local dFocus = focusStep(widget.delConfirmFocus, 2, keyEvt)
    widget.delConfirmFocus = dFocus
    if keyEvt == "ENTER" then
      if dFocus == 1 then
        table.remove(eps, delIdx)
        widget.pendingDeleteIndex = nil
        widget.editScrollOff = math.max(0, math.min(scr, #eps - ED.lVisible))
        widget.editSelected  = math.max(1, math.min(safeNum(widget.editSelected, 1), #eps))
        widget.editListFocus = 1
        saveEditProfiles(widget)
      else
        widget.pendingDeleteIndex = nil
      end
      return clickEvent
    end
  else
    focus = focusStep(focus, BACK_FOCUS, keyEvt)
    widget.editListFocus = focus

    -- Keep the focused battery on screen -- but ONLY when the encoder just
    -- moved the focus. Running this every frame fought the up/down buttons:
    -- the tap changed editScrollOff, then the next frame snapped it straight
    -- back to wherever the (unmoved) focus was, so the buttons looked dead.
    if (keyEvt == "NEXT" or keyEvt == "PREV") and focus <= 2 * nBatt then
      local battIdx = math.ceil(focus / 2)
      scr = scrollToFocus(battIdx, scr, ED.lVisible, nBatt)
      widget.editScrollOff = scr
    end

    if keyEvt == "ENTER" then
      if focus == BACK_FOCUS then
        widget.editProfiles = nil
        setScreen(widget, "flight")
        return clickEvent
      elseif focus == ADD_FOCUS then
        eps[#eps+1] = { name="Batt "..(#eps+1), cap=2200, models={}, flights=0, isHV=false, usablePct=100 }
        widget.editSelected  = #eps
        widget.editScrollOff = math.max(0, #eps - ED.lVisible)
        saveEditProfiles(widget)
        setScreen(widget, "editbatt")
        return clickEvent
      else
        local battIdx = math.ceil(focus / 2)
        if focus % 2 == 1 then
          widget.editSelected = battIdx
          widget.editBattFocus = 1
          setScreen(widget, "editbatt")
          return clickEvent
        elseif nBatt > 1 then
          widget.pendingDeleteIndex = battIdx
          widget.delConfirmFocus = 2 -- default to Cancel on a destructive dialog
          return clickEvent
        end
      end
    end
  end

  roundRect(zx, zy, 480, ED.headH, 0, C_BLACK)
  if editToastActive(widget) then
    drawEditToast(widget, zx, zy)
  else
    lcdDrawText(zx + 14, zy + 4, STR_EDIT, BIG + C_WHITE)
  end

  if hasModal and keyEvt == "EXIT" then
    widget.pendingDeleteIndex = nil
    return clickEvent
  end

  -- No Save button here: parameter edits are saved from the battery screen,
  -- and the only changes this screen can make (add / delete) are written to
  -- SD immediately -- so there is never an unsaved change to lose by
  -- leaving. Back is therefore just "leave the editor".
  if drawButton(widget, tx, ty, bodyClick, zx+380, zy+ED.hBtnY, 90, ED.hBtnH, "Back",
                {color=C_GREY,focus = (not hasModal) and (focus == BACK_FOCUS)})
     or (not hasModal and keyEvt == "EXIT") then
    widget.editProfiles = nil
    setScreen(widget, "flight")
    return clickEvent
  end

  if #eps == 0 then
    lcdDrawText(zx+240, zy+120, "No batteries yet", MEDIUM+CENTER+C_LABEL)
  end

  for vi = 1, ED.lVisible do
    local i = vi + scr
    local b = eps[i]
    if not b then break end
    local ry = zy + ED.lTop + (vi - 1) * step
    local rx = zx + ED.lRowX

    -- Per-row delete, so the list needs no separate selection step: tap the
    -- row to edit it, tap X to remove it. Hit-tested before the row so the
    -- row's own box doesn't swallow the press; drawn after, so the row fill
    -- doesn't cover it.
    local delW    = 34
    local delX    = rx + ED.lRowW - delW - 6
    local canDel  = (#eps > 1)
    local delY, delH = ry + 5, ED.lRowH - 10

    if canDel and isBtnPressed(widget, tx, ty, bodyClick, delX, delY, delW, delH) then
      widget.pendingDeleteIndex = i -- ask first; the modal below does the work
      widget.delConfirmFocus = 2     -- default to Cancel on a destructive dialog
      clickEvent = false
      bodyClick = false
    end

    if isBtnPressed(widget, tx, ty, bodyClick, rx, ry, ED.lRowW - delW - 10, ED.lRowH) then
      widget.editSelected = i
      setScreen(widget, "editbatt")
      clickEvent = false
    end

    if (not hasModal) and focus == (2 * i - 1) then
      roundRect(rx - 3, ry - 3, ED.lRowW + 6, ED.lRowH + 6, 6, C_ORANGE)
    end
    roundRect(rx, ry, ED.lRowW, ED.lRowH, 4, btnColor(widget, rx, ry, ED.lRowW, ED.lRowH, C_ROW))
    lcdDrawFilledRectangle(rx, ry, 4, ED.lRowH, C_ROW_EDGE)

    local dn = b.name or "Battery"
    if #dn > 20 then dn = string.sub(dn, 1, 19) .. "~" end
    lcdDrawText(rx + 12, ry + 9, dn, MEDIUM + C_ROW_TXT)

    local info = safeNum(b.cap, 0) .. "mAh  " .. math.max(1, math.min(100, safeNum(b.usablePct, 100))) .. "%"
                 .. ((b.isHV == true) and "  HV" or "")
    lcdDrawText(delX - 10, ry + 11, info, SMALL + RIGHT + C_LABEL)

    if canDel then
      if (not hasModal) and focus == (2 * i) then
        roundRect(delX - 3, delY - 3, delW + 6, delH + 6, 5, C_ORANGE)
      end
      roundRect(delX, delY, delW, delH, 4, btnColor(widget, delX, delY, delW, delH, C_RED))
      lcdDrawText(delX + delW/2, delY + textCenterY(delH, MEDIUM), "X", MEDIUM + CENTER + C_WHITE)
    end
  end

  -- Scroll column beside the list.
  if maxScroll > 0 then
    local colTop = zy + ED.lTop
    local colH   = ED.lVisible * step - ED.lRowGap
    local halfH  = math.floor((colH - 6) / 2)
    local sx     = zx + ED.lSbarX

    local canUp = scr > 0
    if drawButton(widget, tx, ty, canUp and bodyClick, sx, colTop, ED.lSbarW, halfH, "^",
                  {color = canUp and C_BLUE or C_SLATE, font=MEDIUM}) and canUp then
      scr = scr - 1
      widget.editScrollOff = scr
      -- Drag the focus into the newly visible window so a following encoder
      -- click continues from what is on screen rather than jumping back.
      if focus <= 2 * nBatt then
        local b = math.max(scr + 1, math.min(scr + ED.lVisible, math.ceil(focus / 2)))
        widget.editListFocus = 2 * b - (focus % 2 == 1 and 1 or 0)
      end
      clickEvent = false
    end
    local canDn = scr < maxScroll
    if drawButton(widget, tx, ty, canDn and bodyClick, sx, colTop + halfH + 6, ED.lSbarW, halfH, "v",
                  {color = canDn and C_BLUE or C_SLATE, font=MEDIUM}) and canDn then
      scr = scr + 1
      widget.editScrollOff = scr
      if focus <= 2 * nBatt then
        local b = math.max(scr + 1, math.min(scr + ED.lVisible, math.ceil(focus / 2)))
        widget.editListFocus = 2 * b - (focus % 2 == 1 and 1 or 0)
      end
      clickEvent = false
    end
  end

  if drawButton(widget, tx, ty, bodyClick, zx+ED.lRowX, zy+ED.lAddY, 460, ED.lAddH,
                "+ Add Battery", {color=C_TEAL, font=MEDIUM,focus = (not hasModal) and (focus == ADD_FOCUS)}) then
    eps[#eps+1] = { name="Batt "..(#eps+1), cap=2200, models={}, flights=0, isHV=false, usablePct=100 }
    widget.editSelected  = #eps
    widget.editScrollOff = math.max(0, #eps - ED.lVisible)
    saveEditProfiles(widget)      -- structural change: persist right away
    setScreen(widget, "editbatt") -- straight into editing the new entry
    clickEvent = false
  end

  -- Confirm dialog, drawn last so it sits above the list. Styled like the
  -- battery-select confirmation, but with red framing to mark it as
  -- destructive rather than routine.
  if hasModal then
    local b = eps[delIdx]
    local popW, popH = 380, 210
    local popX = zx + math.floor((480 - popW) / 2)
    local popY = zy + math.floor((320 - popH) / 2)

    roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_RED)
    roundRect(popX, popY, popW, popH, 6, C_SURFACE)
    roundRect(popX, popY, popW, 36, 6, C_RED)
    lcdDrawText(popX + popW/2, popY + textCenterY(36, MEDIUM), "DELETE BATTERY?", MEDIUM+CENTER+C_WHITE)

    local pName = b.name or "Battery"
    if #pName > 22 then pName = string.sub(pName, 1, 20) .. "~" end
    lcdDrawText(popX + popW/2, popY + 50, pName, BIG+CENTER+C_ROW_TXT)

    local info = safeNum(b.cap, 0) .. " mAh  |  " .. safeNum(b.flights, 0) .. " flights"
    lcdDrawText(popX + popW/2, popY + 88, info, MEDIUM+CENTER+C_LABEL)
    lcdDrawText(popX + popW/2, popY + 112, "This cannot be undone.", SMALL+CENTER+C_LABEL)

    local bW, bH = 160, 44
    local bY     = popY + popH - bH - 16

    local dFocus = safeNum(widget.delConfirmFocus, 2)
    if drawButton(widget, tx, ty, clickEvent, popX + 16, bY, bW, bH, "Delete",
                  {color=C_RED, font=MEDIUM,focus = (dFocus == 1)}) then
      table.remove(eps, delIdx)
      widget.pendingDeleteIndex = nil
      widget.editScrollOff = math.max(0, math.min(scr, #eps - ED.lVisible))
      widget.editSelected  = math.max(1, math.min(safeNum(widget.editSelected, 1), #eps))
      saveEditProfiles(widget) -- structural change: persist right away
      clickEvent = false
    end

    if drawButton(widget, tx, ty, clickEvent, popX + popW - bW - 16, bY, bW, bH, "Cancel",
                  {color=C_GREY, font=MEDIUM,focus = (dFocus == 2)}) then
      widget.pendingDeleteIndex = nil
      clickEvent = false
    end
  end

  return clickEvent
end

-- ---------------------------------------------------------------------------
-- SCREEN 2: parameters of one battery
-- ---------------------------------------------------------------------------
-- Allocated once and refilled each frame; see the note in drawEditBattScreen.
local editRowBuf = {
  { label = "Name",      value = "", opts = {chevron=true} },
  { label = "Capacity",  value = "", opts = {chevron=true} },
  { label = "Usable",    value = "", opts = {chevron=true} },
  { label = "Cell type", value = "", opts = {} },
  { label = "Flights",   value = "", opts = {chevron=true} },
  { label = "Models",    value = "", opts = {chevron=true} },
}

local function drawEditBattScreen(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt)
  if widget.editingField then
    return drawKeyboardModal(widget, zx, zy, tx, ty, clickEvent, keyEvt)
  end
  if widget.showModelsModal then
    return drawModelsModal(widget, zx, zy, tx, ty, clickEvent, keyEvt)
  end

  local eps = widget.editProfiles or {}
  local sel = eps[safeNum(widget.editSelected, 1)]
  if not sel then
    setScreen(widget, "edit")
    return clickEvent
  end

  -- Focus is resolved before anything is drawn, so the ring reflects this
  -- frame's key event rather than lagging a frame behind.
  -- Order: 1-6 = property rows, 7 = Save, 8 = < List.
  local PROP_ROWS = 6
  local SAVE_FOCUS, BACK_FOCUS = PROP_ROWS + 1, PROP_ROWS + 2
  local focus = focusStep(widget.editBattFocus, PROP_ROWS + 2, keyEvt)
  widget.editBattFocus = focus

  roundRect(zx, zy, 480, ED.headH, 0, C_BLACK)
  if drawButton(widget, tx, ty, clickEvent, zx+8, zy+ED.hBtnY, 96, ED.hBtnH, "< List",
                {color=C_GREY,focus = (focus == BACK_FOCUS)})
     or keyEvt == "EXIT" then
    setScreen(widget, "edit")
    return clickEvent
  end

  if editToastActive(widget) then
    drawEditToast(widget, zx, zy)
  else
    local hdr = sel.name or "Battery"
    if #hdr > 20 then hdr = string.sub(hdr, 1, 19) .. "~" end
    lcdDrawText(zx + 245, zy + 8, hdr, MEDIUM + CENTER + C_WHITE)
  end

  if drawButton(widget, tx, ty, clickEvent, zx+386, zy+ED.hBtnY, 86, ED.hBtnH, "Save",
                {color=C_TEAL,focus = (focus == SAVE_FOCUS)}) then
    saveEditProfiles(widget)
    clickEvent = false
  end

  local capVal  = safeNum(sel.cap, 2200)
  local pctVal  = math.max(1, math.min(100, safeNum(sel.usablePct, 100)))
  local nameVal = sel.name or "Battery"
  if #nameVal > 20 then nameVal = string.sub(nameVal, 1, 19) .. "~" end

  sel.models = sel.models or {}
  local mCount = 0
  for _ in pairs(sel.models) do mCount = mCount + 1 end

  -- Row contents are written into a reusable buffer rather than a fresh
  -- table of tables with a closure per row. Rebuilding that structure every
  -- frame allocated ~2.1 KB/frame -- around 60 KB/s of garbage at 30fps, on
  -- a VM with a small heap. The buffer is filled in place and the actions
  -- are dispatched by row index, so a redraw now allocates nothing beyond
  -- the value strings themselves.
  local rows = editRowBuf
  rows[1].value = nameVal
  rows[2].value = capVal .. " mAh"
  -- Usable % shows the derived figure too, since that -- not the rated
  -- capacity -- is what actually gets written to the flight controller.
  rows[3].value = pctVal .. "%   (" .. math.floor(capVal * pctVal / 100) .. " mAh)"
  -- Chemistry row has no chevron: tapping toggles it in place rather than
  -- opening an editor. The cell voltage is spelled out so the consequence of
  -- the toggle is visible without the manual.
  rows[4].value = sel.isHV and "HV LiPo   4.35 V/cell" or "LiPo   4.20 V/cell"
  rows[4].opts.accent = sel.isHV and C_HV or C_ROW_TXT
  rows[5].value = tostring(safeNum(sel.flights, 0))
  rows[6].value = (mCount == 0) and "Global (all models)" or (mCount .. " assigned")

  -- Dispatch by index instead of a per-row closure.
  local function actRow(i)
    if     i == 1 then openFieldEditor(widget, "name", sel.name or "Battery")
    elseif i == 2 then openFieldEditor(widget, "cap", capVal)
    elseif i == 3 then openFieldEditor(widget, "usablePct", pctVal)
    elseif i == 4 then sel.isHV = not (sel.isHV == true)
    elseif i == 5 then openFieldEditor(widget, "flights", safeNum(sel.flights, 0))
    elseif i == 6 then widget.showModelsModal = true; widget.modelsModalFocus = 1
    end
  end

  if keyEvt == "ENTER" then
    if focus <= PROP_ROWS then
      actRow(focus)
    elseif focus == SAVE_FOCUS then
      saveEditProfiles(widget)
    else
      setScreen(widget, "edit")
      return clickEvent
    end
  end

  local step = ED.pRowH + ED.pRowGap
  for i = 1, PROP_ROWS do
    local row = rows[i]
    local ry  = zy + ED.pTop + (i - 1) * step
    row.opts.focus = (focus == i)
    if drawPropRow(widget, tx, ty, clickEvent, zx+ED.pRowX, ry, ED.pRowW, ED.pRowH,
                   row.label, row.value, row.opts) then
      actRow(i)
      clickEvent = false
    end
  end

  return clickEvent
end

-- ===========================================================================
-- FLIGHT SCREEN
-- ===========================================================================
local function drawFlightScreen(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt)
  if keyEvt == "PAGE_UP" then
    widget.selectInitTime = getTime()
    setScreen(widget, "select")
    return clickEvent
  end

  local tick = safeNum(widget.tick, 0)
  local v    = widget.vals or {}
  local s    = widget.strs or {}

  if widget.bgBmp then
    lcdDrawBitmap(widget.bgBmp, zx, zy)
  else
    roundRect(zx, zy, 480, 36, 5, C_NAVY)
  end

  lcdDrawText(zx + FLIGHT.modelTitleX, zy + FLIGHT.modelTitleY, widget.cachedModelName or "", BIG+C_WHITE)

  if tick % 20 == 0 or not s.clock or s.clock == "" then
    local dt = getDateTime and getDateTime() or nil
    if dt then s.clock = string.format("%02d:%02d", safeNum(dt.hour, 0), safeNum(dt.min, 0)) end
  end
  lcdDrawText(zx + FLIGHT.clockX, zy + FLIGHT.clockY, s.clock or "", SMALL+C_WHITE)

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
  drawTxBar(zx + FLIGHT.txBarX, zy + FLIGHT.txBarY, FLIGHT.txBarW, FLIGHT.txBarH, widget.txPctCached or 100)
  lcdDrawText(zx + FLIGHT.txTextX, zy + FLIGHT.txTextY, s.txPct or "", SMALL+C_WHITE)

  local isArmed = safeGetValue(opts and opts.ArmSrc, 0) > 0
  -- Headspeed: auto-detected sensor name first, then whatever RpmSrc is set
  -- to. RpmSrc was referenced here long before it existed as a widget option,
  -- so if the auto-detect missed the sensor there was no way to point at it
  -- and this silently stayed 0 -- which is why the card showed a permanent
  -- "0 RPM".
  local rpm     = safeGetTelemetry(opts and opts.RpmSrc, "hspd", 0)
  local mode    = safeGetValue(opts and opts.ModeSrc, -1024)

  -- Engine state card.
  --
  -- ModeSrc is the authority for whether the engine is COMMANDED on, and
  -- headspeed only decides whether a number is worth showing. That ordering
  -- matters for safety: this card is what you check before plugging the
  -- model in, so it must never read ENGINE OFF while the engine switch is
  -- on. A head that has not spun up yet is ENGINE ON, not ENGINE OFF.
  --
  -- The failure direction is deliberate too. If ModeSrc is misconfigured and
  -- reads high, the card says ENGINE ON when it might not be -- a false
  -- warning, which is the safe way to be wrong.
  --
  --   mode < -512  : switch off                    -> ENGINE OFF
  --   mode <  512  : mid position                  -> IDLE
  --   mode >= 512  : commanded on, head below 100  -> ENGINE ON
  --                  commanded on, head turning    -> "1850 RPM"
  if mode ~= v.mode or rpm ~= v.rpm then
    v.mode, v.rpm = mode, rpm
    if mode < -512 then
      s.eTxt, s.eCol = STR_ENGINE_OFF, C_BLACK
    elseif mode < 512 then
      s.eTxt, s.eCol = STR_IDLE, C_BLACK
    elseif safeNum(rpm, 0) >= RPM_RUNNING then
      s.eTxt, s.eCol = math.floor(rpm) .. " RPM", C_BLACK
    else
      -- Commanded on but not yet turning. Coloured, because this is exactly
      -- the state that is dangerous to mistake for "off".
      s.eTxt, s.eCol = STR_ENGINE_ON, C_HV
    end
  end

  -- Armed/Disarmed
  roundRect(zx + FLIGHT.cardXL, zy + FLIGHT.row1Y, FLIGHT.cardW, FLIGHT.rowH, 4, isArmed and C_RED or C_GREEN)
  lcdDrawText(zx + FLIGHT.cardXL+FLIGHT.cardW/2, zy + FLIGHT.row1Y+2, isArmed and STR_ARMED or STR_DISARMED, MEDIUM+CENTER+C_WHITE)

  -- Engine/Headspeed
  -- Was hardcoded to (98,72), ignoring the zone offset -- correct only while
  -- the widget sits at 0,0.
  lcdDrawText(zx + FLIGHT.cardXL + FLIGHT.cardW/2, zy + FLIGHT.row2Y + 4,
              s.eTxt or "", MEDIUM+CENTER+(s.eCol or C_BLACK))

  -- Dynamic calculation of Rates & Profile using cached switch configuration.
  local rateVal = safeGetValue(opts and opts.RateSrc, -1024)
  local rateIdx = calculateSelectionCached(rateVal, widget.rateCount, widget.rateStep)

  local profVal = safeGetValue(opts and opts.ProfSrc, -1024)
  local profIdx = calculateSelectionCached(profVal, widget.profCount, widget.profStep)

  if rateIdx ~= widget.cachedRateIdx then
    widget.cachedRateIdx = rateIdx
    widget.cachedRateText =rateIdx
  end
  if profIdx ~= widget.cachedProfIdx then
    widget.cachedProfIdx = profIdx
    widget.cachedProfText = profIdx
  end

  lcdDrawText(zx + FLIGHT.rateX, zy + FLIGHT.topCardY, widget.cachedRateText or (rateIdx), MEDIUM+CENTER+BOLD+C_BLACK)
  lcdDrawText(zx + FLIGHT.profX, zy + FLIGHT.topCardY, widget.cachedProfText or (profIdx), MEDIUM+CENTER+BOLD+ C_BLACK)

  -- Live Vcell / Live Current / RQly in the top telemetry cards.
  lcdDrawText(zx + FLIGHT.minCellX, zy + FLIGHT.minCellY, s.cell or "--", MEDIUM+CENTER+C_BLACK)
  lcdDrawText(zx + FLIGHT.maxCurrX, zy + FLIGHT.maxCurrY, s.curr or "--", MEDIUM+CENTER+C_BLACK)

  local rIdx = rqlyIconIndex(math.max(0, safeNum(v.rqly, 0)))
  local rqlyIcon = widget.rqlyIcons and widget.rqlyIcons[rIdx]
  if rqlyIcon then
    lcdDrawBitmap(rqlyIcon, zx + FLIGHT.rqlyIconX, zy + FLIGHT.rqlyIconY)
  end
  lcdDrawText(zx + FLIGHT.rqlyTextX, zy + FLIGHT.rqlyTextY, s.rqly or "--", MEDIUM+C_BLACK)

  -- Model image
  if widget.modelBmp then
    lcdDrawBitmap(widget.modelBmp, zx + FLIGHT.modelX, zy + FLIGHT.modelY)
  elseif not widget.bgBmp then
    roundRect(zx + FLIGHT.modelX, zy + FLIGHT.modelY, FLIGHT.modelW, FLIGHT.modelH, 0, C_DKGREY)
    lcdDrawText(zx + FLIGHT.modelX+92, zy + FLIGHT.modelY+42, STR_NO_IMAGE, SMALL+CENTER+C_WHITE)
  end

  -- Model image tap -> Model image selection screen
  if isBtnPressed(widget, tx, ty, clickEvent, zx + FLIGHT.modelX, zy + FLIGHT.modelY, FLIGHT.modelW, FLIGHT.modelH) then
    widget.availableImages = loadAvailableImages()
    widget.pendingModelImage = nil
    widget.pendingModelBmp = nil
    -- Start focus on the image already assigned to this model, so the
    -- encoder begins where the user is rather than at the top of the list.
    widget.modelSelectFocus  = 1
    widget.modelSelectScroll = 0
    local assigned = (widget.modelImageMap or {})[widget.cachedModelName or ""]
    if assigned then
      for i, img in ipairs(widget.availableImages) do
        if img == assigned then widget.modelSelectFocus = i break end
      end
    end
    setScreen(widget, "modelselect")
    clickEvent = false
  end

  -- Model name tap (top left) -> PID tuning
  if isBtnPressed(widget, tx, ty, clickEvent, zx + FLIGHT.modelTitleX, zy + FLIGHT.modelTitleY, 200, 36) then
    -- isArmed was already read at the top of this frame; re-reading it here
    -- went through the telemetry layer again for the same value.
    if isArmed then
      playTone(400, 150, 0) -- denial beep -- disarm to open PID tuning
    else
      playTone(1000, 100, 0)
      local ok, mod = pcall(dofile, "/WIDGETS/"..name.."/pidtune.lua")
      if ok and type(mod) == "table" then
        widget.pidTuneModule = mod
        mod.onEnter(widget)
        setScreen(widget, "pidtune")
      end
    end
    clickEvent = false
  end

  -- Timer progress bar. Cache timer configuration (`index` + `start`),
  -- but sample the changing remaining value periodically.
  if tick % 10 == 0 or not s.timer or s.timer == "" or widget.timerStart <= 0 then
    local td = safeGetTimer(widget.timerIdx)
    if td then
      if safeNum(td.start, 0) > 0 then widget.timerStart = safeNum(td.start, 0) end
      local t = safeNum(td.value, 0)
      if t ~= v.timer then
        v.timer = t; local a = math.abs(t)
        s.timer = string.format("%s%02d:%02d",(t<0 and "-" or ""),math.floor(a/60),a%60)
      end
    end
  end

  -- Countdown timer bar: full at the configured starting time, empty at 00:00.
  -- `timerStart` is cached because it is configuration, not live telemetry.
  local timerStart = safeNum(widget.timerStart, 0)
  local timerRemaining = safeNum(v.timer, 0)
  local pctRemaining = 0
  if timerStart > 0 then
    pctRemaining = math.max(0, math.min(1, timerRemaining / timerStart))
  end
  local sweepX, sweepY, sweepW, sweepH = zx + FLIGHT.timerSweepX, zy + FLIGHT.timerSweepY, FLIGHT.timerSweepW, FLIGHT.timerSweepH
  roundRect(sweepX, sweepY, sweepW, sweepH, 4, C_SLATE)
  local fillW = math.floor(sweepW * pctRemaining)
  if fillW > 4 then roundRect(sweepX, sweepY, fillW, sweepH, 4, C_ORANGE) end
  -- Value inside the bar. White reads on both the filled and unfilled parts,
  -- so it stays legible wherever the fill edge happens to fall.
  lcdDrawText(sweepX + sweepW/2, sweepY + textCenterY(sweepH, MEDIUM),
              s.timer or "00:00", MEDIUM+CENTER+C_WHITE)

  -- ---------------------------------------------------------------------
  -- Throttle bar
  -- ---------------------------------------------------------------------
  -- Throttle is sampled on a wall-clock interval rather than every frame.
  -- It is a fast-moving signal, and a bar that tracks it frame-by-frame is
  -- a distracting flicker in peripheral vision while flying -- a value you
  -- glance at once a second is more readable. getTime() is 10ms ticks, so
  -- THR_UPDATE_TICKS = 100 is one second.
  if getTime() >= safeNum(widget.thrNextUpdate, 0) then
    widget.thrNextUpdate = getTime() + THR_UPDATE_TICKS
    -- Treated as a straight 0-100 percentage sensor. An earlier version
    -- tried to auto-detect a raw -1024..1024 channel as well, but the two
    -- ranges overlap (0 means 0% to one and mid-stick to the other), so it
    -- misread ordinary values. If a raw channel is ever needed it should be
    -- a separate, explicit option rather than a guess.
    local raw = safeGetTelemetry(opts and opts.ThrSrc, "thr", 0)
    local pct = math.max(0, math.min(100, math.floor(safeNum(raw, 0) + 0.5)))
    if pct ~= v.thr then
      v.thr = pct
      s.thr = pct .. "%"
    end
  end

  local thrPct = safeNum(v.thr, 0)
  local thrX, thrY = zx + FLIGHT.thrBarX, zy + FLIGHT.thrBarY
  drawBattBar(thrX, thrY, FLIGHT.thrBarW, FLIGHT.thrBarH, thrPct, C_NAVY)
  lcdDrawText(thrX + FLIGHT.thrBarW/2, thrY + textCenterY(FLIGHT.thrBarH, MEDIUM),
              s.thr or "0%", MEDIUM+CENTER+C_WHITE)

  -- Battery bar
  local profs  = widget.profiles or {}
  local bIdx   = safeNum(widget.batteryIndex, 1)
  local prof   = profs[bIdx] or profs[1] or {name="Default", cap=2200, flights=0}

  local barX, barY, barW, barH = zx + FLIGHT.batteryX, zy + FLIGHT.batteryY, FLIGHT.batteryW, FLIGHT.batteryH

  if isBtnPressed(widget, tx, ty, clickEvent, barX, barY, barW, barH) then
    widget.selectInitTime = getTime()
    setScreen(widget, "select")
    clickEvent = false
  end

  local rawPct  = safeGetTelemetry(opts and opts["Rem%"], "batPct", 100)
  local rawUsed = safeGetTelemetry(opts and opts.Capa, "capa", 0)

  if tick % 4 == 0 then
    local lvl = (rawPct < 20) and 2 or (rawPct < 80) and 1 or 0
    if lvl ~= widget.lastWarnLevel then
      widget.warnChangeTimer = safeNum(widget.warnChangeTimer, 0) + 1
      if widget.warnChangeTimer >= 4 then widget.lastWarnLevel, widget.warnChangeTimer = lvl, 0 end
    else widget.warnChangeTimer = 0 end
  end
  local themeC = (widget.lastWarnLevel == 2 and C_RED) or (widget.lastWarnLevel == 1 and C_ORANGE) or C_GREEN

  drawBattBar(barX, barY, barW, barH, rawPct, themeC)

  local displayName = prof.name or "Default"
  if #displayName > 16 then displayName = string.sub(displayName, 1, 15) .. "~" end

  -- Battery %/mAh text only needs to be re-formatted when the underlying
  -- (whole-number) value actually changes, not every single frame -- the
  -- bar fill above already redraws live each frame for visual smoothness.
  local pctWhole, usedWhole = math.floor(rawPct), math.floor(rawUsed)
  if pctWhole ~= v.battPct then v.battPct = pctWhole; s.battPct = pctWhole .. "%" end
  if usedWhole ~= v.battUsed then v.battUsed = usedWhole; s.battUsed = usedWhole .. "mAh" end

  lcdDrawText(barX + 10,  barY + 6, displayName, MEDIUM+C_WHITE)
  lcdDrawText(barX + 260, barY + 2, s.battPct or "100%", MEDIUM+BOLD+C_WHITE)
  lcdDrawText(barX + 458, barY + 2, s.battUsed or "0mAh", MEDIUM+BOLD+RIGHT+C_WHITE)

  if tick % 5 == 0 then
    local tVolt   = safeGetTelemetry(opts and opts.Volt, "vbat", 0)
    local cell    = safeGetTelemetry(nil, "vcel", 0)
    local curr    = safeGetTelemetry(nil, "curr", 0)
    local minCell = safeGetTelemetry(opts and opts.MinCell, nil, 0)
    local maxCurr = safeGetTelemetry(opts and opts.MaxCurr, nil, 0)
    local eTemp   = safeGetTelemetry(opts and opts.EscT, "tesc", 0)
    local becV    = (opts and opts.Bec) and safeGetTelemetry(opts.Bec, "vbec", nil) or resolveNamed("vbec")
    local rqly    = safeGetTelemetry(opts and opts.RQly, "lq", -1)

    if tVolt ~= v.volt then v.volt=tVolt; s.volt=string.format("Voltage: %.2f V",tVolt) end
    if cell ~= v.cell then v.cell=cell; s.cell=string.format("%.2f",cell) end
    if curr ~= v.curr then v.curr=curr; s.curr=string.format("%.1f",curr) end
    if minCell ~= v.minCell then v.minCell=minCell; s.minCell=string.format("Vcel min: %.2f V/c",minCell) end
    if maxCurr ~= v.maxCurr then v.maxCurr=maxCurr; s.maxCurr=string.format("Max current: %.1f A",maxCurr) end
    if eTemp ~= v.temp then v.temp=eTemp; s.temp=string.format("ESC temp: %d C",math.floor(eTemp)) end
    if becV and becV ~= v.bec then v.bec=becV; s.bec=string.format("BEC: %.2f V",becV)
    elseif not becV and (not s.bec or s.bec=="") then s.bec="BEC: --" end
    if rqly ~= v.rqly then v.rqly=rqly; s.rqly=string.format("%d%%", math.floor(math.max(0, rqly))) end
  end

  -- Remaining lower telemetry: Voltage / ESC temp / BEC.
  for _, lay in ipairs(FLIGHT.telem) do
    local bx, by = zx + lay.x, zy + lay.y
    lcdDrawText(bx+8, by+7, s[lay.key] or "", SMALL+C_BLACK)
  end

  return clickEvent
end

-- ===========================================================================
-- SHARED COMMIT ACTIONS
-- ===========================================================================
-- Each screen below is reachable by both touch and the physical
-- rotary/keys, so every confirm action previously existed twice -- once in
-- the keyEvt == "ENTER" branch and once in the isBtnPressed() branch, with
-- the bodies kept in sync by hand. That's how the FC battery sync came to
-- be added to one path and not the other. These helpers hold the single
-- copy of each action; the two input paths now only decide *when* to call
-- them, never *what* they do.

-- Commit the pending model-image choice to model.lua and reload the bitmap.
local function commitModelImageSelection(widget)
  local img = widget.pendingModelImage
  widget.modelImageMap[widget.cachedModelName or ""] = img
  saveModelMap(widget.modelImageMap)
  local path = resolveModelImage(widget.cachedModelName, widget.modelImageMap)
  if path then widget.modelBmp = openModelBitmap(path) end
  widget.pendingModelImage = nil
  widget.pendingModelBmp = nil
  setScreen(widget, "flight")
end

local function cancelModelImageSelection(widget)
  widget.pendingModelImage = nil
  widget.pendingModelBmp = nil
end

-- Commit the pending battery choice: set the failsafe GV (which is what
-- actually selects the profile on the FC) and push that battery's capacity
-- and HV voltage limit over MSP.
local function commitBatterySelection(widget, opts, profs)
  widget.batteryIndex = widget.pendingBatteryIndex
  widget.pendingBatteryIndex = nil

  local selProf = (profs or {})[widget.batteryIndex] or {}
  local gvIdx   = safeNum(opts and opts.GV_Select, 8) - 1
  local gvValue = getFailsafeGVValue(selProf, widget.cachedModelName, widget.batteryIndex)

  safeSetGV(gvIdx, gvValue)
  if widget.wasConnected then
    local slot = getBatterySlotForModel(selProf, widget.cachedModelName)
    if slot then requestBatterySync(selProf, slot) end
  end
  setScreen(widget, "flight")
end

-- ===========================================================================
-- MODEL IMAGE SELECT SCREEN
-- ===========================================================================
-- Model bitmaps on the SD card are 192x114. FLIGHT.modelW/H (185x94) is the
-- box the flight screen reserves, NOT the bitmap size -- sizing the preview
-- from those constants made it 7px too narrow and 20px too short, so it ran
-- off the right edge of the screen and over the list.

-- Layout for the model-image picker: a single-column list on the left, the
-- preview in its own column on the right.
local MI = {
  listX = 10,  listW = 250, rowH = 30, rowGap = 4, visible = 5, contentY = 88,
  prevX = 280, prevY = 88,
  btnY  = 268, btnW = 110, btnH = 42,
}

local function drawModelSelectScreen(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt)
  roundRect(zx, zy, 480, 40, 0, C_BLACK)
  lcdDrawText(zx+90, zy+4, STR_SELECT_MODEL_IMAGE, BIG+C_WHITE)

  local images     = widget.availableImages or {}
  local nImg       = #images
  local hasPending = widget.pendingModelImage ~= nil

  local modelMap   = widget.modelImageMap or {}
  local currentImg = modelMap[widget.cachedModelName or ""] or "None"

  local scroll = safeNum(widget.modelSelectScroll, 0)
  widget.modelSelectFocus = math.max(1, math.min(nImg > 0 and nImg or 1, safeNum(widget.modelSelectFocus, 1)))

  if keyEvt then
    if hasPending then
      if keyEvt == "NEXT" or keyEvt == "PREV" then
        widget.popupFocus = (widget.popupFocus == 1) and 2 or 1
      elseif keyEvt == "ENTER" then
        if widget.popupFocus == 1 then
          commitModelImageSelection(widget)
        else
          cancelModelImageSelection(widget)
        end
        return clickEvent
      elseif keyEvt == "EXIT" then
        cancelModelImageSelection(widget)
        return clickEvent
      end
    else
      if keyEvt == "EXIT" or keyEvt == "PAGE_DN" then
        setScreen(widget, "flight")
        return clickEvent
      elseif (keyEvt == "NEXT" or keyEvt == "PREV") and nImg > 0 then
        widget.modelSelectFocus = focusStep(widget.modelSelectFocus, nImg, keyEvt)
      elseif keyEvt == "ENTER" and nImg > 0 then
        local img = images[widget.modelSelectFocus]
        widget.pendingModelImage = img
        widget.pendingModelBmp   = openModelBitmap(MODEL_IMAGE_DIR .. img)
        widget.popupFocus = 1
        return clickEvent
      end
    end
  end

  if nImg > 0 then
    scroll = scrollToFocus(widget.modelSelectFocus, scroll, MI.visible, nImg)
    widget.modelSelectScroll = scroll
  end

  lcdDrawText(zx+15, zy+48, "Model: " .. (widget.cachedModelName or ""), MEDIUM+C_LABEL)
  lcdDrawText(zx+15, zy+70, "Image: " .. currentImg, SMALL+C_ROW_TXT)

  -- Position indicator sits on the header line above the list -- below it
  -- there is only 14px before the button row, which is not enough.
  if nImg > MI.visible then
    lcdDrawText(zx + MI.listX + MI.listW, zy + 70,
                widget.modelSelectFocus .. " / " .. nImg, SMALL + RIGHT + C_LABEL)
  end

  -- Preview, in its own column clear of the list.
  local pvX, pvY = zx + MI.prevX, zy + MI.prevY
  local previewBmp = widget.pendingModelBmp or widget.modelBmp
  roundRect(pvX - 2, pvY - 2, MODEL_IMG_W + 4, MODEL_IMG_H + 4, 4, C_SURFACE_HI)
  if previewBmp then
    lcdDrawBitmap(previewBmp, pvX, pvY)
  else
    roundRect(pvX, pvY, MODEL_IMG_W, MODEL_IMG_H, 0, C_CARD)
    lcdDrawText(pvX + MODEL_IMG_W/2, pvY + MODEL_IMG_H/2 - 8, "No preview", SMALL+CENTER+C_LABEL)
  end
  lcdDrawText(pvX + MODEL_IMG_W/2, pvY + MODEL_IMG_H + 8,
              hasPending and "Preview" or "Current", SMALL+CENTER+C_LABEL)

  if nImg == 0 then
    lcdDrawText(zx + MI.listX + MI.listW/2, zy+150, "No images found in", MEDIUM+CENTER+C_LABEL)
    lcdDrawText(zx + MI.listX + MI.listW/2, zy+172, "/Modelimage", MEDIUM+CENTER+C_LABEL)
  end

  local step = MI.rowH + MI.rowGap
  for slot = 1, MI.visible do
    local i = scroll + slot
    local img = images[i]
    if not img then break end
    local cX = zx + MI.listX
    local cY = zy + MI.contentY + (slot - 1) * step

    if not hasPending then
      if isBtnPressed(widget, tx, ty, clickEvent, cX, cY, MI.listW, MI.rowH) then
        widget.modelSelectFocus  = i
        widget.pendingModelImage = img
        widget.pendingModelBmp   = openModelBitmap(MODEL_IMAGE_DIR .. img)
        widget.popupFocus = 1
        clickEvent = false
      end
    end

    if not hasPending and widget.modelSelectFocus == i then
      roundRect(cX - 3, cY - 3, MI.listW + 6, MI.rowH + 6, 6, C_ORANGE)
    end
    roundRect(cX, cY, MI.listW, MI.rowH, 4, btnColor(widget, cX, cY, MI.listW, MI.rowH, C_CARD))
    if currentImg == img then
      lcdDrawFilledRectangle(cX, cY, 4, MI.rowH, C_ROW_EDGE)
      lcdDrawText(cX + MI.listW - 10, cY + textCenterY(MI.rowH, SMALL), "in use", SMALL + RIGHT + C_LABEL)
    end

    local disp = img
    if #disp > 24 then disp = string.sub(disp, 1, 22) .. "~" end
    lcdDrawText(cX + 12, cY + textCenterY(MI.rowH, SMALL), disp, SMALL + C_ROW_TXT)
  end

  local btnY = zy + MI.btnY

  if not hasPending then
    if drawButton(widget, tx, ty, clickEvent, zx + 185, btnY, MI.btnW, MI.btnH, STR_BACK,
                  {color=C_GREY, font=MEDIUM}) then
      setScreen(widget, "flight")
      clickEvent = false
    end
  else
    local focus1 = (widget.popupFocus == 1)
    if drawButton(widget, tx, ty, clickEvent, zx + 110, btnY, MI.btnW, MI.btnH, STR_CONFIRM,
                  {color = focus1 and C_TEAL or C_SURFACE_HI, font=MEDIUM, focus=focus1}) then
      commitModelImageSelection(widget)
      clickEvent = false
    end

    local focus2 = (widget.popupFocus == 2)
    if drawButton(widget, tx, ty, clickEvent, zx + 260, btnY, MI.btnW, MI.btnH, STR_BACK,
                  {color = focus2 and C_TEAL or C_GREY, font=MEDIUM, focus=focus2}) then
      cancelModelImageSelection(widget)
      clickEvent = false
    end
  end

  return clickEvent
end
local function drawSelectScreen(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt)
  roundRect(zx, zy, 480, 40, 0, C_BLACK)
  lcdDrawText(zx+111, zy+4, STR_SELECT_BATTERY, BIG+C_WHITE)

  -- If batteries.lua was unreadable at boot and we fell back to the backup,
  -- say so once here rather than letting a silent recovery pass unnoticed.
  if widget.recoveredBatteries then
    lcdDrawText(zx+240, zy+300, "Batteries restored from backup", SMALL+CENTER+C_ORANGE)
  elseif getTime() < safeNum(widget.saveFailedNotice, 0) then
    lcdDrawText(zx+240, zy+300, "SD write failed - flight not saved", SMALL+CENTER+C_RED)
  end

  local syncState, syncErr = battSyncStatus()
  if syncState == "error" then
    lcdDrawText(zx+470, zy+4, syncErr or "FC error", SMALL+RIGHT+C_RED)
  elseif syncState == "busy" then
    lcdDrawText(zx+470, zy+4, "FC sync...", SMALL+RIGHT+C_ORANGE)
  end

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
  local maxIdx = math.min(6, #profs)
  local hasModal = (widget.pendingBatteryIndex ~= nil)

  widget.selectFocusedIndex = math.max(1, math.min(maxIdx > 0 and maxIdx or 1, safeNum(widget.selectFocusedIndex, widget.batteryIndex or 1)))
  widget.popupFocus = safeNum(widget.popupFocus, 1)

  if keyEvt then
    if hasModal then
      if keyEvt == "NEXT" or keyEvt == "PREV" then
        widget.popupFocus = (widget.popupFocus == 1) and 2 or 1
      elseif keyEvt == "ENTER" then
        if widget.popupFocus == 1 then
          commitBatterySelection(widget, opts, profs)
          return clickEvent
        else
          widget.pendingBatteryIndex = nil
        end
      elseif keyEvt == "EXIT" then
        widget.pendingBatteryIndex = nil
      end
    else
      if keyEvt == "PAGE_UP" then
        enterEditScreen(widget)
        return clickEvent
      elseif keyEvt == "PAGE_DN" or keyEvt == "EXIT" then
        setScreen(widget, "flight")
        return clickEvent
      elseif keyEvt == "NEXT" then
        if maxIdx > 0 then
          widget.selectFocusedIndex = math.min(maxIdx, widget.selectFocusedIndex + 1)
        end
      elseif keyEvt == "PREV" then
        if maxIdx > 0 then
          widget.selectFocusedIndex = math.max(1, widget.selectFocusedIndex - 1)
        end
      elseif keyEvt == "ENTER" then
        if maxIdx > 0 then
          widget.pendingBatteryIndex = widget.selectFocusedIndex
          widget.popupFocus = 1
        end
      end
    end
  end

  local btnY, btnW, btnH = zy+268, 110, 42
  local backX = zx + 110
  local editX = zx + 260

  -- Drawn unconditionally, but only clickable when no modal is covering it.
  if drawButton(widget, tx, ty, (not hasModal) and clickEvent, backX, btnY, btnW, btnH,
                STR_BACK, {color=C_GREY, font=MEDIUM}) then
    setScreen(widget, "flight")
    clickEvent = false
  end

  if drawButton(widget, tx, ty, (not hasModal) and clickEvent, editX, btnY, btnW, btnH,
                "Edit", {color=C_TEAL, font=MEDIUM}) then
    enterEditScreen(widget)
    clickEvent = false
  end

  for i = 1, maxIdx do
    local b = profs[i]
    if b then
      local isLeft = (i % 2 ~= 0)
      local cW, cH = 220, 58
      local cX = zx + (isLeft and 15 or 245)
      local cY = zy + 50 + math.floor((i - 1) / 2) * 70

      if not hasModal then
        if isBtnPressed(widget, tx, ty, clickEvent, cX, cY, cW, cH) then
          widget.selectFocusedIndex = i
          widget.pendingBatteryIndex = i
          widget.popupFocus = 1
          clickEvent = false
        end
      end

      if not hasModal and widget.selectFocusedIndex == i then
        roundRect(cX - 3, cY - 3, cW + 6, cH + 6, 6, C_ORANGE)
      end

      local base = C_BLACK
      roundRect(cX, cY, cW, cH, 4, btnColor(widget, cX, cY, cW, cH, C_CARD))
      lcdDrawText(cX+11, cY+8, b.name or "Battery", MEDIUM+C_BLACK)
      lcdDrawText(cX+11, cY+32, "(" .. safeNum(b.flights, 0) .. " flt)", SMALL+C_GREY)
    end
  end

  if widget.pendingBatteryIndex then
    local popW, popH = 360, 200
    local popX = zx + math.floor((480 - popW) / 2)
    local popY = zy + math.floor((320 - popH) / 2)

    roundRect(popX - 2, popY - 2, popW + 4, popH + 4, 8, C_TEAL)
    roundRect(popX, popY, popW, popH, 6, C_SURFACE)
    roundRect(popX, popY, popW, 36, 6, C_BLACK)
    lcdDrawText(popX + popW/2, popY + textCenterY(36, MEDIUM), "CONFIRM SELECTION", MEDIUM+CENTER+C_WHITE)

    local selProf = profs[widget.pendingBatteryIndex] or {}
    local pName = selProf.name or "Battery"
    if #pName > 22 then pName = string.sub(pName, 1, 20) .. "~" end

    lcdDrawText(popX + popW/2, popY + 48, pName, BIG+CENTER+C_ROW_TXT)
    local infoStr = safeNum(selProf.cap, 0) .. " mAh  |  " .. safeNum(selProf.flights, 0) .. " flights"
    lcdDrawText(popX + popW/2, popY + 88, infoStr, MEDIUM+CENTER+C_LABEL)

    local mBtnW, mBtnH = 130, 44
    local mBtnY = popY + 136
    local cnfX = popX + 30
    local canX = popX + popW - 30 - mBtnW

    -- Focus ring must contrast with the light popup body, not with a dark one.
    if widget.popupFocus == 1 then
      roundRect(cnfX - 3, mBtnY - 3, mBtnW + 6, mBtnH + 6, 6, C_ORANGE)
    else
      roundRect(canX - 3, mBtnY - 3, mBtnW + 6, mBtnH + 6, 6, C_ORANGE)
    end

    local focus1 = (widget.popupFocus == 1)
    if drawButton(widget, tx, ty, clickEvent, cnfX, mBtnY, mBtnW, mBtnH, STR_CONFIRM,
                  {color = focus1 and C_TEAL or C_SURFACE_HI, font=MEDIUM}) then
      commitBatterySelection(widget, opts, profs)
      clickEvent = false
    end

    local focus2 = (widget.popupFocus == 2)
    if drawButton(widget, tx, ty, clickEvent, canX, mBtnY, mBtnW, mBtnH, STR_BACK,
                  {color = focus2 and C_TEAL or C_GREY, font=MEDIUM}) then
      widget.pendingBatteryIndex = nil
      clickEvent = false
    end
  end

  return clickEvent
end

-- ===========================================================================
-- SUMMARY SCREEN
-- ===========================================================================
local function drawSummaryScreen(widget, opts, zx, zy, tx, ty, clickEvent, keyEvt)
  -- Single action here, so ENTER dismisses as well as EXIT rather than doing
  -- nothing -- the other screens all respond to ENTER.
  if keyEvt == "EXIT" or keyEvt == "PAGE_DN" or keyEvt == "ENTER" then
    setScreen(widget, "flight")
    return clickEvent
  end

  roundRect(zx,zy,480,40,0,C_BLACK)
  lcdDrawText(zx+14,zy+4,STR_SUMMARY,BIG+C_WHITE)

  local now = getTime()
  local sumT = safeNum(widget.summaryStartTime, now)
  if now - sumT > 30000 then setScreen(widget, "flight") end

  local bX,bY,bW,bH = zx+185,zy+268,110,42
  if drawButton(widget, tx, ty, clickEvent, bX, bY, bW, bH, STR_BACK,
                {color=C_GREY, font=MEDIUM, focus=true}) then
    setScreen(widget, "flight"); clickEvent=false
  end

  -- Light cards with dark text, matching the select and editor screens. The
  -- card is 42 tall and holds two stacked lines: a SMALL label (13px) above a
  -- MEDIUM value (24px), which is 37px of text plus padding.
  local cache = widget.summaryCache or {}
  local rH,rW = 48,225
  for idx = 1, 7 do
    local col = (idx%2==1) and 10 or 245
    local rY  = zy+48+math.floor((idx-1)/2)*rH
    roundRect(zx+col,rY,rW,42,4,C_ROW)
    lcdDrawFilledRectangle(zx+col,rY,4,42,C_ROW_EDGE)
    lcdDrawText(zx+col+12,rY+3,  SUMMARY_LABELS[idx], SMALL+C_LABEL)
    lcdDrawText(zx+col+12,rY+17, cache[idx] or "-",   MEDIUM+C_ROW_TXT)
  end
  return clickEvent
end

-- ===========================================================================
-- CREATE & UPDATE
-- ===========================================================================
local function create(zone, opts)
  opts = opts or {}
  local initName     = resolveModelName()
  -- Falls back to batteries.bak if the live file was truncated by a power
  -- loss mid-write; recoveredBatteries drives the warning shown on the
  -- flight screen so a silent fallback doesn't go unnoticed.
  local lp, recovered = loadVerified(BATTERIES_PATH, BATTERIES_BAK)
  local profiles     = (type(lp)=="table" and #lp > 0) and lp
                       or {{name="Default",cap=2200,models={},flights=0,isHV=false,usablePct=100}}

  local bgBmp = safeOpenBitmap("/WIDGETS/"..name.."/background.bmp") or 
                safeOpenBitmap("/WIDGETS/"..name.."/background.png") or 
                safeOpenBitmap("/WIDGETS/"..name.."/background.jpg")

  local modelMap = loadModelMap()
  local modelImgPath = resolveModelImage(initName, modelMap)
  local modelBmp = nil
  if modelImgPath then
    modelBmp = openModelBitmap(modelImgPath)
  end
  if not modelBmp then
    local info = safeGetModelInfo()
    if info and type(info.bitmap)=="string" and info.bitmap~="" then
      modelBmp = openModelBitmap("/IMAGES/"..info.bitmap)
    end
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

  local timerIdx = safeNum(opts.TimerSrc, 1) - 1
  local timerData = safeGetTimer(timerIdx)

  local widget = {
    zone=zone, options=opts, batteryIndex=initBatt, pendingBatteryIndex=nil,
    selectFocusedIndex=initBatt, popupFocus=1,
    cachedModelName=initName, allProfiles=profiles, profiles=filteredProfs,
    screen="flight", wasConnected=false, clickEvent=false,
    touchX=0, touchY=0, touchActive=false, lastClickTime=0, noTouchFrames=0,
    bgBmp=bgBmp, modelBmp=modelBmp, rqlyIcons=rqlyIcons, tick=0,
    recoveredBatteries=recovered, saveFailedNotice=0, thrNextUpdate=0,
    pidTuneModule=nil,
    modelImageMap=modelMap, availableImages={}, pendingModelImage=nil, pendingModelBmp=nil,
    totalFlightTicks=0, armStartTick=0, lastArmState=false,
    bootModelCheck=0,
    txMin=txMin, txMax=txMax, summaryStartTime=0, selectInitTime=getTime(),
    rateCount=0, rateStep=0, profCount=0, profStep=0,
    timerIdx=timerIdx, timerStart=safeNum(timerData and timerData.start, 0),
    lastWarnLevel=0, warnChangeTimer=0,
    flashRect=nil, flashTimer=0,
    connCandidate=false, connStableCount=0,
    armedTime=0, flightQualified=false,
    editProfiles=nil, editSelected=1, editScrollOff=0, editPropScroll=0,
    pendingDeleteIndex=nil,
    -- encoder/button focus indices, one per navigable menu
    editListFocus=1, editBattFocus=1, delConfirmFocus=2,
    modelPickerFocus=1, modelsModalFocus=1, slotPickerFocus=1, kbFocus=1,
    modelSelectFocus=1, modelSelectScroll=0,
    editingField=nil, keyboardBuffer="",
    showModelsModal=false, slotPickerModel=nil,
    modelPicker=false, modelPickerScroll=0,
    editStatusMsg="", editStatusEnd=0,
    vals={volt=-1,cell=-1,curr=-1,minCell=-1,maxCurr=-1,temp=-1,bec=-1,rqly=-2,thr=-1,timer=-99999,txVolt=-1,clockMin=-1,mode=-999,rpm=-999,bank=-999},
    strs={volt="",cell="",curr="",minCell="",maxCurr="",temp="",bec="",rqly="",thr="",eCol=nil,timer="",txPct="",clock="",eTxt="",bTxt=""},
    summaryCache={initName,"00:00","0 mAh","0 C","0.0 A","0.00 V/c","0%"},
  }
  prepareSelectionConfig(widget, opts)
  return widget
end

local function update(widget, opts)
  widget.options = opts or {}
  prepareSelectionConfig(widget, widget.options)
  widget.timerIdx = safeNum(widget.options.TimerSrc, 1) - 1
  widget.timerStart = 0
end

-- ===========================================================================
-- MAIN DRAW / REFRESH
-- ===========================================================================
-- ===========================================================================
-- PER-FRAME UPDATE STEPS
-- ===========================================================================
-- draw() used to be one 215-line function doing MSP pumping, flight-time
-- accounting, model-name resolution, boot retries, connection transitions,
-- summary caching AND screen dispatch. Each of those is an independent
-- concern with its own state, so they now live in their own tickX()
-- functions and draw() just sequences them. Order matters and is
-- documented at the call site.

-- Advance the battery-sync state machine, then flush the MSP queue.
-- The pump is unconditional: an MSP *write* only enqueues a message, so
-- gating the pump on "something is in flight" left writes sitting unsent
-- until the next operation re-enabled it (values landed one selection
-- late). processQueue() is a no-op on an empty queue.
local function tickMsp(widget)
  if widget.pidTuneModule and widget.screen == "pidtune" then
    widget.pidTuneModule.tick(widget)
  end
  tickBatterySync()
  RF2.pump()
end

-- Accumulate real armed time across arm/disarm edges (never negative).
local function tickFlightTime(widget, isArmedNow)
  if isArmedNow and not widget.lastArmState then
    widget.armStartTick = getTime()
  elseif not isArmedNow and widget.lastArmState then
    if widget.armStartTick and widget.armStartTick > 0 then
      widget.totalFlightTicks = widget.totalFlightTicks + (getTime() - widget.armStartTick)
      widget.armStartTick = 0
    end
  end
  widget.lastArmState = isArmedNow
end

-- Resolve the current model name and reload its image when it changes.
-- Runs before screen dispatch and covers every screen, so individual
-- screen-draw functions must NOT re-check the model name themselves (that
-- was previously duplicated and always a no-op).
local function tickModelIdentity(widget)
  local currentModel = resolveModelName()
  if currentModel == widget.cachedModelName then return end

  widget.cachedModelName = currentModel
  widget.profiles = getFilteredProfiles(currentModel, widget.allProfiles)

  -- If this model has never connected before, create a placeholder entry
  -- in model.lua ("" = no image assigned yet) so it shows up immediately
  -- in the models/image pickers instead of needing a manual first-time
  -- assignment.
  if currentModel ~= "" and currentModel ~= "Unknown" and widget.modelImageMap[currentModel] == nil then
    widget.modelImageMap[currentModel] = ""
    saveModelMap(widget.modelImageMap)
  end

  local imgPath = resolveModelImage(currentModel, widget.modelImageMap)
  if imgPath then
    widget.modelBmp = openModelBitmap(imgPath)
  else
    widget.modelBmp = nil
    local info = safeGetModelInfo()
    if info and type(info.bitmap)=="string" and info.bitmap~="" then
      widget.modelBmp = openModelBitmap("/IMAGES/"..info.bitmap)
    end
  end
end

-- EdgeTX may not have the SD card fully ready at create() time, so the
-- very first loadModelMap() read can silently come back empty even though
-- model.lua exists on disk -- which made a previously-assigned image look
-- "lost" for the whole session. Retry the map load (not just the bitmap
-- open) for the first 3 seconds after boot until it yields a result.
local function tickBootModelRetry(widget)
  if widget.bootModelCheck >= 300 then return end
  widget.bootModelCheck = widget.bootModelCheck + 1
  if widget.bootModelCheck % 60 ~= 0 then return end

  if not next(widget.modelImageMap or {}) then
    local reloaded = loadModelMap()
    if next(reloaded) then widget.modelImageMap = reloaded end
  end
  local imgPath = resolveModelImage(widget.cachedModelName, widget.modelImageMap)
  if imgPath and not widget.modelBmp then
    widget.modelBmp = openModelBitmap(imgPath)
  end
end

-- Credit a flight to the active battery once it has been armed long
-- enough to qualify. Shared by the disarm path and the disconnect path.
local function creditFlightIfQualified(widget)
  if not widget.flightQualified then return end
  local profs = widget.profiles or {}
  local curProf = profs[safeNum(widget.batteryIndex, 1)]
  if curProf then
    curProf.flights = safeNum(curProf.flights, 0) + 1

    -- If the editor is open it is holding a snapshot of allProfiles taken
    -- when it was entered, and saving that snapshot would write this
    -- increment straight back out. Mirror the credit into the snapshot so
    -- the flight survives.
    --
    -- Index alignment holds because editProfiles starts as a deep copy of
    -- allProfiles in the same order, add/delete on the list screen saves
    -- immediately (which re-copies allProfiles from editProfiles), and there
    -- is no reordering. If reordering is ever added, this needs a stable id
    -- per profile instead.
    if widget.editProfiles then
      local all = widget.allProfiles or {}
      for i = 1, #all do
        if all[i] == curProf then
          local mirror = widget.editProfiles[i]
          if mirror then mirror.flights = safeNum(mirror.flights, 0) + 1 end
          break
        end
      end
    end

    if not saveProfilesToSD(widget.allProfiles) then
      -- Don't let a failed write pass silently: the flight is otherwise lost
      -- with no indication that anything went wrong.
      widget.saveFailedNotice = getTime() + 500
    end
  end
  widget.flightQualified = false
end

local function tickFlightCounter(widget, isArmed, mode)
  if isArmed and mode >= -512 then
    widget.armedTime = safeNum(widget.armedTime, 0) + 1
    if widget.armedTime >= MIN_FLIGHT_TICKS then
      widget.flightQualified = true
    end
  elseif widget.flightQualified then
    creditFlightIfQualified(widget)
    widget.armedTime = 0
  end
end

-- Debounced connect/disconnect edge detection, and everything that should
-- happen on each transition.
local function tickConnection(widget, opts)
  -- Both editor screens are excluded: a connect/disconnect mid-edit would
  -- otherwise yank the user to the select/summary screen and discard their
  -- unsaved changes.
  if widget.screen == "edit" or widget.screen == "editbatt" then return end

  local rqlyVal = safeGetTelemetry(opts and opts.RQly, "lq", -1)
  local rawConn = rqlyVal > 10
  if rawConn == widget.connCandidate then
    widget.connStableCount = safeNum(widget.connStableCount, 0) + 1
  else
    widget.connCandidate = rawConn; widget.connStableCount = 1
  end

  if safeNum(widget.connStableCount, 0) < CONN_DEBOUNCE_FRAMES then return end
  if rawConn == widget.wasConnected then return end

  -- Telemetry sensors appear and disappear with the link, so the resolution
  -- cache is dropped on both edges rather than being re-probed every frame.
  invalidateSensorCache()

  if rawConn then
    safeSetGV(safeNum(opts and opts.GV_Select, 8) - 1, 0)
    widget.selectInitTime = getTime()
    setScreen(widget, "select")
    widget.armedTime = 0
    widget.flightQualified = false
    widget.totalFlightTicks = 0
    widget.armStartTick = 0
    widget.lastArmState = false
    rf2NameCache = nil     -- new connection -- don't show a stale name from a previous model
    rf2NamePending = false -- don't let a stuck query from a prior connection block this one
    queryModelNameFromFC()
    beginBattFcInit()
  else
    creditFlightIfQualified(widget)
    if widget.armStartTick and widget.armStartTick > 0 then
      widget.totalFlightTicks = widget.totalFlightTicks + (getTime() - widget.armStartTick)
      widget.armStartTick = 0
    end
    widget.lastArmState = false
    widget.summaryStartTime = getTime()
    setScreen(widget, "summary")
    widget.armedTime = 0
    widget.flightQualified = false
  end
  widget.wasConnected = rawConn
end

-- Keep the post-flight summary values up to date while connected, so the
-- summary screen has them ready the moment the link drops.
local function tickSummaryCache(widget, opts, isArmedNow)
  if not widget.wasConnected then return end
  local cache = widget.summaryCache or {}

  cache[1] = widget.cachedModelName or "Model"

  local ticks = widget.totalFlightTicks
  if isArmedNow and widget.armStartTick and widget.armStartTick > 0 then
    ticks = ticks + (getTime() - widget.armStartTick)
  end
  local totalSec = math.floor(ticks / 100)
  cache[2] = string.format("%02d:%02d", math.floor(totalSec / 60), totalSec % 60)

  local lc = safeGetTelemetry(opts and opts.Capa, "capa", 0);   if lc > 0 then cache[3] = math.floor(lc).." mAh" end
  local mt = safeGetTelemetry(opts and opts.MaxEscT, "tesc", 0); if mt > 0 then cache[4] = math.floor(mt).." C" end
  local mc = safeNum(widget.vals and widget.vals.maxCurr, 0);    if mc > 0 then cache[5] = string.format("%.1f A", mc) end
  local ml = safeNum(widget.vals and widget.vals.minCell, 0);    if ml > 1.0 then cache[6] = string.format("%.2f V/c", ml) end
  local mr = safeGetTelemetry(opts and opts.MinRQly, "lq", 0);   if mr > 0 then cache[7] = math.floor(mr).."%" end
end

-- Colour/flag names the PID tune module expects, mapped onto this
-- widget's palette. Built once rather than per frame.
local PIDTUNE_HELPERS = nil
local function pidTuneHelpers()
  -- Colours are passed straight through by their real names now. This used
  -- to remap them (C_BLUE=C_NAVY, C_NAVY=C_SLATE, C_ORANGE=C_BLUE...) which
  -- meant pidtune's source said one colour and rendered another -- easy to
  -- get wrong when restyling. C_CARD/C_CARD_TXT/C_MUTED are the shared
  -- light-card treatment used by the editor and select screens.
  PIDTUNE_HELPERS = PIDTUNE_HELPERS or {
    isBtnPressed=isBtnPressed, btnColor=btnColor, roundRect=roundRect, lcdDrawText=lcdDrawText,
    SMALL=SMALL, MEDIUM=MEDIUM, BIG=BIG, CENTER=CENTER,
    C_WHITE=C_WHITE, C_GREY=C_GREY, C_BLACK=C_BLACK, C_DKGREY=C_DKGREY, C_SLATE=C_SLATE,
    C_GREEN=C_GREEN, C_RED=C_RED, C_YELLOW=C_YELLOW, C_ORANGE=C_ORANGE, C_TEAL=C_TEAL,
    C_CARD=C_CARD, C_CARD_TXT=C_ROW_TXT, C_MUTED=C_MUTED,
    C_SURFACE=C_SURFACE, C_SURFACE_HI=C_SURFACE_HI, C_LABEL=C_LABEL,
  }
  return PIDTUNE_HELPERS
end

local function dispatchScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  local screen = widget.screen
  if screen == "modelselect" then
    drawModelSelectScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  elseif screen == "select" then
    drawSelectScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  elseif screen == "summary" then
    drawSummaryScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  elseif screen == "edit" then
    drawEditListScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  elseif screen == "editbatt" then
    drawEditBattScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  elseif screen == "pidtune" then
    local result = widget.pidTuneModule.draw(widget, opts, zx, zy, tx, ty, ce, keyEvt, pidTuneHelpers())
    if result == "back" then setScreen(widget, "flight") end
  else
    drawFlightScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
  end
end

-- ===========================================================================
-- MAIN DRAW
-- ===========================================================================
local function draw(widget, keyEvt)
  if not widget or not widget.options then return end
  local opts = widget.options

  tickMsp(widget)

  local zw = safeNum(widget.zone and widget.zone.w, 480)
  local zh = safeNum(widget.zone and widget.zone.h, 320)
  local zx = safeNum(widget.zone and widget.zone.x, 0)
  local zy = safeNum(widget.zone and widget.zone.y, 0)

  if zw < 480 or zh < 320 then
    lcdDrawText(zx+2, zy+zh-14, "Set to fullscreen", SMALL+C_WHITE)
    return
  end

  widget.tick       = safeNum(widget.tick, 0) + 1
  -- Safety net: sensors sometimes register a little after the link comes up,
  -- which is not a connection edge. Re-probing every ~2.5s costs one pass and
  -- stops a sensor from staying invisible until the next disconnect.
  if widget.tick % 250 == 0 then invalidateSensorCache() end
  widget.flashTimer = math.max(0, safeNum(widget.flashTimer, 0) - 1)

  local isArmed    = safeGetValue(opts and opts.ArmSrc, 0) > 0
  local mode       = safeGetValue(opts and opts.ModeSrc, -1024)
  local isArmedNow = isArmed and mode >= -512

  tickFlightTime(widget, isArmedNow)
  tickModelIdentity(widget)
  tickBootModelRetry(widget)

  if widget.screen == "pidtune" and isArmed then
    playTone(300, 200, 1) -- warning tone -- kicked out of PID tuning on arm
    setScreen(widget, "flight")
  end

  tickFlightCounter(widget, isArmed, mode)
  -- Must run after tickFlightCounter: a disconnect credits the in-progress
  -- flight, which depends on flightQualified being current for this frame.
  tickConnection(widget, opts)
  tickSummaryCache(widget, opts, isArmedNow)

  local tx = safeNum(widget.touchX, 0)
  local ty = safeNum(widget.touchY, 0)
  local ce = widget.clickEvent
  widget.clickEvent = false

  lcdClear((opts and opts.BkGround) or C_DKGREY)
  dispatchScreen(widget, opts, zx, zy, tx, ty, ce, keyEvt)
end

local function background(wgt) end

return {
  name = name, options = options, create = create, update = update, background = background,
  refresh = function(w, event, touchState)
    if not w then return end

    clearFrameCache()

    local keyEvt = getEvtType(event)

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

    draw(w, keyEvt)
  end,
}