-- Bigger Reactors + CC:Tweaked monitor/alarm starter
-- Place computer next to a Reactor Computer Port (or connected via modem)
-- Place a speaker adjacent to the computer.

local reactor =
    peripheral.find("BiggerReactors_Reactor")
    or peripheral.find("BiggerReactors:Reactor")
    or peripheral.find("BigReactors-Reactor")
    or peripheral.find("extreme_reactor") -- some packs use different names

if not reactor then
  error("No reactor peripheral found. Is the computer connected to a Reactor Computer Port?")
end

local speaker = peripheral.find("speaker") -- optional but requested
local mon = peripheral.find("monitor")     -- optional

-- ---------- CONFIG ----------
local POLL_SECONDS = 0.5

-- Temperatures are usually in C in these APIs (depends on pack/config).
local WARN_FUEL_TEMP = 1200
local CRIT_FUEL_TEMP = 1400

local WARN_CASE_TEMP = 800
local CRIT_CASE_TEMP = 950

-- Fuel thresholds (fraction of max)
local WARN_FUEL_FRAC = 0.10
local CRIT_FUEL_FRAC = 0.03

-- Alarm spam control
local SOUND_COOLDOWN_SEC = 6

-- If true: shut down reactor on critical events
local AUTO_SCRAM = true
-- ----------------------------

local lastSoundAt = 0
local lastState = "OK" -- OK, WARN, CRIT

local function now() return os.epoch("utc") / 1000 end

local function safeCall(fn, ...)
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then return a, b, c, d end
  return nil
end

local function play(kind)
  if not speaker then return end
  if now() - lastSoundAt < SOUND_COOLDOWN_SEC then return end

  if kind == "WARN" then
    speaker.playSound("minecraft:block.note_block.pling", 1.5, 1.0)
  elseif kind == "CRIT" then
    speaker.playSound("minecraft:block.note_block.bell", 2.0, 0.8)
  elseif kind == "OK" then
    speaker.playSound("minecraft:block.note_block.chime", 1.0, 1.2)
  end

  lastSoundAt = now()
end

local function fmt(n)
  if n == nil then return "n/a" end
  if n >= 1e9 then return string.format("%.2fG", n/1e9) end
  if n >= 1e6 then return string.format("%.2fM", n/1e6) end
  if n >= 1e3 then return string.format("%.2fk", n/1e3) end
  return tostring(math.floor(n))
end

local function setOut(termObj)
  if termObj then term.redirect(termObj) end
end

local function draw(data, state, reason)
  local t = mon or term.native()
  setOut(t)

  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1,1)

  local color = colors.lime
  if state == "WARN" then color = colors.yellow end
  if state == "CRIT" then color = colors.red end

  term.setTextColor(colors.white)
  print("Bigger Reactors Monitor")
  term.setTextColor(color)
  print(("STATE: %s"):format(state))
  term.setTextColor(colors.lightGray)
  print(reason or "")

  term.setTextColor(colors.white)
  print(("-"):rep(math.min(w, 40)))

  term.setTextColor(colors.cyan)
  print(("Active: %s"):format(tostring(data.active)))

  term.setTextColor(colors.white)
  print(("FuelTemp:  %s C"):format(data.fuelTemp or "n/a"))
  print(("CaseTemp:  %s C"):format(data.caseTemp or "n/a"))

  term.setTextColor(colors.white)
  print(("RF Stored: %s"):format(fmt(data.energy)))
  term.setTextColor(colors.lightGray)
  print(("RF/t (last): %s"):format(fmt(data.rfPerTick)))

  term.setTextColor(colors.white)
  print(("Fuel:  %s / %s"):format(fmt(data.fuel), fmt(data.fuelMax)))
  print(("Waste: %s / %s"):format(fmt(data.waste), fmt(data.wasteMax)))

  term.setTextColor(colors.gray)
  print("")
  print("CTRL+C to stop")

  term.redirect(term.native())
end

local function scram()
  -- Try common shutdown strategies.
  safeCall(reactor.setActive, false)
  -- Raise all control rods to 100% if available.
  local rodCount = safeCall(reactor.getControlRodCount)
  if rodCount then
    for i = 0, rodCount - 1 do
      safeCall(reactor.setControlRodLevel, i, 100)
    end
  end
end

while true do
  local data = {}

  data.active   = safeCall(reactor.getActive)
  data.fuelTemp = safeCall(reactor.getFuelTemperature)
  data.caseTemp = safeCall(reactor.getCasingTemperature)
  data.energy   = safeCall(reactor.getEnergyStored)
  data.rfPerTick= safeCall(reactor.getEnergyProducedLastTick)

  data.fuel     = safeCall(reactor.getFuelAmount)
  data.fuelMax  = safeCall(reactor.getFuelAmountMax)
  data.waste    = safeCall(reactor.getWasteAmount)
  data.wasteMax = safeCall(reactor.getWasteAmountMax)

  -- Decide state
  local state, reason = "OK", "All within thresholds."

  -- fuel fraction checks (avoid div by nil/0)
  local fuelFrac = nil
  if data.fuel and data.fuelMax and data.fuelMax > 0 then
    fuelFrac = data.fuel / data.fuelMax
  end

  local crit = false
  local warn = false

  if data.fuelTemp and data.fuelTemp >= CRIT_FUEL_TEMP then
    crit = true; reason = ("Fuel temperature critical (%dC)"):format(data.fuelTemp)
  elseif data.caseTemp and data.caseTemp >= CRIT_CASE_TEMP then
    crit = true; reason = ("Casing temperature critical (%dC)"):format(data.caseTemp)
  elseif fuelFrac and fuelFrac <= CRIT_FUEL_FRAC then
    crit = true; reason = ("Fuel critically low (%.1f%%)"):format(fuelFrac*100)
  end

  if not crit then
    if data.fuelTemp and data.fuelTemp >= WARN_FUEL_TEMP then
      warn = true; reason = ("Fuel temperature high (%dC)"):format(data.fuelTemp)
    elseif data.caseTemp and data.caseTemp >= WARN_CASE_TEMP then
      warn = true; reason = ("Casing temperature high (%dC)"):format(data.caseTemp)
    elseif fuelFrac and fuelFrac <= WARN_FUEL_FRAC then
      warn = true; reason = ("Fuel low (%.1f%%)"):format(fuelFrac*100)
    end
  end

  if crit then state = "CRIT"
  elseif warn then state = "WARN"
  end

  -- Actions on transition
  if state ~= lastState then
    play(state) -- play WARN/CRIT/OK on changes
    -- If we just cleared to OK, play OK sound too
    if state == "OK" then play("OK") end
    lastState = state
  end

  -- Auto scram if critical
  if state == "CRIT" and AUTO_SCRAM and data.active then
    scram()
  end

  draw(data, state, reason)

  sleep(POLL_SECONDS)
end