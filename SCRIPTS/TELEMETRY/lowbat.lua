-- lowbat.lua v9  EdgeTX telemetry script: low cell-voltage alarm, no logical switches needed.
-- Install: /SCRIPTS/TELEMETRY/lowbat.lua
-- Enable:  MODEL > DISPLAY (telemetry screens) > Screen 1: Script > lowbat
-- Thresholds: GV8 (min) / GV9 (warn) in 0.01 V, set when a profile is applied in BF Battery.
-- Sensor / arm switch / delay / repeat / vibrate / voice: edit in BF Battery > Settings.
-- Runs in the background while the model is loaded; alarms only while the arm switch is on.
-- On the telemetry screen: ENTER plays a test beep. Not active while a Tools script is open.

local CFG = "/SCRIPTS/BFBatt.cfg"
local CANDIDATES = { "Cels", "Cell", "VCel", "RxBt" }   -- used when sensor = Auto
local GV_MIN, GV_WARN = 7, 8          -- 0-based (7 = GV8, 8 = GV9)
local DEF_MIN, DEF_WARN = 330, 350    -- used if GVs are empty
local GV_SATS = 6                     -- 0-based (6 = GV7): min sats from BF GPS Rescue (BF Battery)
local SATS_MIN = 6                    -- min sats used if GV7 is empty
-- hold = alarm delay in seconds (filters throttle sag); arm = "Always" or e.g. "SA down"
local S = { hold = 0.5, wrep = 5, crep = 1, hapt = 1, voice = 0, sensor = "RxBt", arm = "SA down" }

local sensor, linked = nil, false
local armSw, armPos, armedNow = "sa", "down", true
local lowSince, critSince, nextBeep = nil, nil, 0
local cellV, level, lastLevel = 0, 0, 0   -- level: 0 ok, 1 warn, 2 critical

local function loadCfg()
  local f = io.open(CFG, "r")
  if f then
    local data = io.read(f, 1024) or ""
    io.close(f)
    for k, val in string.gmatch(data, "([%w_]+)=([^\r\n]*)") do
      if k == "sensor" or k == "arm" then S[k] = val
      elseif S[k] ~= nil then S[k] = tonumber(val) or S[k] end
    end
  end
  sensor = nil                        -- re-resolve with new setting
  local sw, pos = string.match(S.arm, "^S(%a) (%a+)$")
  armSw, armPos = sw and ("s" .. string.lower(sw)), pos      -- nil = "Always"
end

local function val(name)                    -- getValue that tolerates a missing name
  if type(name) ~= "string" then return nil end
  return getValue(name)
end

local function isArmed()
  if not armSw then return true end
  local x = val(armSw)
  if type(x) ~= "number" then return true end   -- switch not found: never silence the alarm
  if armPos == "up" then return x < -512 end
  if armPos == "down" then return x > 512 end
  return x >= -512 and x <= 512                  -- mid
end

local function findSensor()
  if S.sensor ~= "Auto" then
    if type(S.sensor) == "string" and getFieldInfo(S.sensor) then sensor = S.sensor end
    return
  end
  for _, n in ipairs(CANDIDATES) do
    if getFieldInfo(n) then sensor = n; return end
  end
end

local function readCell()
  local x = val(sensor)
  if type(x) == "table" then          -- multi-cell sensor: use lowest cell
    local m
    for _, c in pairs(x) do
      if c > 0 and (not m or c < m) then m = c end
    end
    return m or 0
  end
  return x or 0
end

local function thr(idx, def)
  local x = model.getGlobalVariable(idx, 0)
  if x and x > 0 then return x end
  return def
end

local lastErr

-- One-time FC check per connection, only while disarmed: read Betaflight's
-- vbat_min/vbat_warning (MSP_BATTERY_CONFIG) and copy them into GV8/GV9.
local syncState, syncTries, syncAt, linkAt = "wait", 0, 0, 0   -- wait / busy / done / fail
local SYNC_TIMEOUT, SYNC_TRIES = 250, 5

local function syncSend(now)
  if crossfireTelemetryPush == nil or crossfireTelemetryPush() == nil then syncState = "fail"; return end
  if not crossfireTelemetryPush() then return end              -- output buffer busy, next cycle
  while crossfireTelemetryPop() do end                          -- drop stale frames
  -- MSPv1 request, single 8-byte chunk: status, size 0, cmd 32, crc 32, zero fill
  crossfireTelemetryPush(0x7A, { 0xC8, 0xEA, 0x30, 0, 32, 32, 0, 0, 0, 0 })
  syncState, syncAt, syncTries = "busy", now, syncTries + 1
end

local function syncPoll(now)
  local t, d = crossfireTelemetryPop()
  while t do
    if t == 0x7B and d[1] == 0xEA and d[2] == 0xC8 and bit32.btest(d[3], 0x10)
       and not bit32.btest(d[3], 0x80) then
      local size, p = d[4], 5
      if bit32.band(d[3], 0x60) == 0x20 then                    -- BF 4.3+: cmd byte present
        if d[5] ~= 32 then size = 0 end
        p = 6
      end
      if size >= 13 and d[p + 12] then
        local mn = d[p + 7] + d[p + 8] * 256
        local wn = d[p + 11] + d[p + 12] * 256
        if mn >= 250 and wn > mn and wn <= 450 then
          if model.getGlobalVariable(GV_MIN, 0) ~= mn then model.setGlobalVariable(GV_MIN, 0, mn) end
          if model.getGlobalVariable(GV_WARN, 0) ~= wn then model.setGlobalVariable(GV_WARN, 0, wn) end
        end
        syncState = "done"
        return
      end
    end
    t, d = crossfireTelemetryPop()
  end
  if now - syncAt > SYNC_TIMEOUT then
    syncState = (syncTries >= SYNC_TRIES) and "fail" or "wait"
  end
end

local function syncStep(now)
  if syncState == "done" or syncState == "fail" then return end
  if now - linkAt < 200 then return end                         -- let telemetry settle 2 s
  if syncState == "wait" then syncSend(now) else syncPoll(now) end
end

local function tick()
  local now = getTime()
  if getRSSI() == 0 then              -- no link
    linked, lowSince, critSince, level, cellV = false, nil, nil, 0, 0
    syncState, syncTries = "wait", 0                             -- check again on next connect
    return
  end
  if not linked then linked, linkAt = true, now; loadCfg() end   -- refresh settings on every connect
  if not sensor then findSensor(); if not sensor then return end end

  cellV = readCell()
  armedNow = isArmed()
  if armedNow then
    if syncState == "busy" then syncState = "wait" end          -- armed mid-check: retry after disarm
  else
    syncStep(now)
  end
  if cellV < 0.5 or not armedNow then            -- no data or disarmed: silent, delay restarts
    lowSince, critSince, level, lastLevel = nil, nil, 0, 0
    return
  end
  local c = cellV * 100
  local warn, min = thr(GV_WARN, DEF_WARN), thr(GV_MIN, DEF_MIN)

  if c < warn then lowSince = lowSince or now else lowSince = nil end
  if c < min then critSince = critSince or now else critSince = nil end

  level = 0
  if critSince and now - critSince >= S.hold * 100 then
    level = 2
  elseif lowSince and now - lowSince >= S.hold * 100 then
    level = 1
  end
  if level ~= lastLevel then nextBeep, lastLevel = now, level end   -- beep at once on change

  if level > 0 and now >= nextBeep then
    if level == 2 then
      for _ = 1, 3 do playTone(2500, 80, 60) end
      if S.hapt == 1 then playHaptic(80, 60); playHaptic(80, 60) end
      nextBeep = now + S.crep * 100
    else
      playTone(1500, 250, 100)
      if S.hapt == 1 then playHaptic(200, 100) end
      if S.voice == 1 then playNumber(math.floor(cellV * 10 + 0.5), UNIT_VOLTS, PREC1) end
      nextBeep = now + S.wrep * 100
    end
  end
end

local function background()
  local ok, err = pcall(tick)
  if not ok then lastErr = tostring(err) end
end

local testUntil = 0

local function run(event)
  background()
  if event == EVT_VIRTUAL_ENTER then           -- ENTER on this screen: test the alarm sound
    playTone(1500, 250, 100)
    if S.hapt == 1 then playHaptic(200, 100) end
    testUntil = getTime() + 100
  end
  lcd.clear()
  lcd.drawText(1, 0, "LowBat v9", SMLSIZE + INVERS)
  local fs = (syncState == "done") and "FC synced" or (syncState == "fail") and "FC no reply"
             or (linked and "FC check..." or "")
  lcd.drawText(48, 0, fs, SMLSIZE)
  if getTime() < testUntil then lcd.drawText(100, 0, "TEST", SMLSIZE + INVERS) end
  if not sensor then
    lcd.drawText(2, 14, linked and "No cell sensor" or "No telemetry", 0)
  elseif cellV > 0 then
    lcd.drawText(2, 11, string.format("%.2fV", cellV), DBLSIZE + ((level > 0) and BLINK or 0))
    lcd.drawText(80, 15, sensor, MIDSIZE)
  else
    lcd.drawText(2, 14, "No telemetry", 0)
  end
  lcd.drawText(2, 36, string.format("Warn %.2f  Min %.2f",
    thr(GV_WARN, DEF_WARN) / 100, thr(GV_MIN, DEF_MIN) / 100), SMLSIZE)
  lcd.drawText(2, 45, string.format("Delay %.1fs  Rep %d/%ds", S.hold, S.wrep, S.crep), SMLSIZE)
  local st = (not armedNow) and "DISARMED" or (level == 2) and "CRITICAL" or (level == 1) and "LOW" or "OK"
  lcd.drawText(2, 54, st, SMLSIZE + ((level > 0) and INVERS or 0))
  lcd.drawText(84, 54, armSw and S.arm or "Always", SMLSIZE)
  if lastErr then
    lcd.drawText(2, 27, string.sub(lastErr, -25), SMLSIZE + INVERS)   -- last error, tail end
  else
    local sats = getFieldInfo("Sats") and val("Sats")           -- GPS satellites (CRSF "Sats")
    if type(sats) == "number" then
      local need = model.getGlobalVariable(GV_SATS, 0)
      if not need or need <= 0 then need = SATS_MIN end
      sats = math.floor(sats)
      if sats >= need then
        lcd.drawText(74, 27, "Sats " .. sats .. " OK", SMLSIZE)
      else
        lcd.drawText(74, 27, "Sats " .. sats .. "<" .. need, SMLSIZE + INVERS)
      end
    else
      lcd.drawText(74, 27, "Sats --", SMLSIZE)
    end
  end
  return 0
end

return { init = loadCfg, run = run, background = background }
