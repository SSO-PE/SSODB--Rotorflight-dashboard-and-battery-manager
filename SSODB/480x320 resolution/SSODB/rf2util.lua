-- ===========================================================================
-- rf2util.lua -- shared RF2 / MSP bootstrap for the SSODB widget
-- ===========================================================================
-- This exists because the same ~20 lines of RF2 setup were previously
-- duplicated three times (twice in main.lua, once in pidtune.lua), and every
-- MSP bug we hit came from those copies drifting apart:
--
--   * rf2.apiVersion starts nil (RF2's own background_init, which we never
--     run, normally sets it). Several MSP modules do an unconditional
--     `rf2.apiVersion < 12.09` in getDefaults(), which throws "attempt to
--     compare nil with number". pidtune.lua worked around this; main.lua
--     didn't, until it hit the same crash.
--   * mspQueue:processQueue() must be pumped every frame. A *write* only
--     ADDS a message to the queue -- gating the pump on "is a read in
--     flight" left writes sitting unsent until the next operation
--     re-enabled the pump, so values landed one action late.
--
-- Both are now handled in exactly one place. Callers should:
--   1. call ensure() before touching any MSP script
--   2. call pump() unconditionally, once per frame
--   3. call ensureApiVersion() and wait for true before any getDefaults()

local M = {}

local API_VERSION_TIMEOUT = 500 -- 5s; getTime() is 10ms ticks

local scriptCache       = {}
local apiVersionPending = false
local apiVersionStarted = 0

M.lastError = nil

-- Loads rf2.lua (if not already global) plus the mspQueue/mspHelper that
-- every other MSP module depends on. Safe and cheap to call repeatedly.
function M.ensure()
  local ok, err = pcall(function()
    if rawget(_G, "rf2") == nil then
      assert(loadScript("/SCRIPTS/RF2/rf2.lua"))()
    end
    if not rf2.mspQueue then
      rf2.mspQueue = rf2.executeScript("MSP/mspQueue")
      if rf2.mspQueue then rf2.mspQueue.maxRetries = 3 end
    end
    if not rf2.mspHelper then
      rf2.mspHelper = rf2.executeScript("MSP/mspHelper")
    end
  end)
  if not ok then
    M.lastError = "RF2 load failed"
    return false
  end
  if not (rf2 and rf2.mspQueue and rf2.mspHelper) then
    M.lastError = "RF2 incomplete"
    return false
  end
  return true
end

-- Loads and caches an MSP module by path, e.g. script("MSP/mspBatteryConfig").
-- Returns nil (and sets lastError) rather than throwing, so callers can
-- fail soft.
function M.script(path)
  if scriptCache[path] then return scriptCache[path] end
  if not M.ensure() then return nil end
  local ok, mod = pcall(function() return rf2.executeScript(path) end)
  if not ok or not mod then
    M.lastError = "No " .. tostring(path)
    return nil
  end
  scriptCache[path] = mod
  return mod
end

-- Returns true once rf2.apiVersion is known. Kicks off a single MSP query
-- on first call and returns false while it's in flight. Times out rather
-- than pending forever, so a dropped reply can't wedge callers.
function M.ensureApiVersion()
  if not M.ensure() then return false end
  if rf2.apiVersion ~= nil then return true end

  if apiVersionPending then
    if (getTime() - apiVersionStarted) > API_VERSION_TIMEOUT then
      apiVersionPending = false
      M.lastError = "API ver timeout"
    end
    return false
  end

  local mspApiVersion = M.script("MSP/mspApiVersion")
  if not (mspApiVersion and mspApiVersion.getApiVersion) then
    M.lastError = "No mspApiVersion"
    return false
  end

  apiVersionPending = true
  apiVersionStarted = getTime()
  mspApiVersion.getApiVersion(function(_, version)
    rf2.apiVersion = version
    apiVersionPending = false
  end, nil)
  return false
end

function M.isApiVersionPending()
  return apiVersionPending
end

-- Must be called once per frame. processQueue() is a no-op on an empty
-- queue, so this is unconditional by design -- see the header note about
-- writes sitting unsent when the pump was gated on an in-flight read.
function M.pump()
  if rawget(_G, "rf2") and rf2.mspQueue then
    rf2.mspQueue:processQueue()
  end
end

return M
