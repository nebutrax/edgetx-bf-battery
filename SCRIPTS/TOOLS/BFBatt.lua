-- toolName = TNS|BF Battery|TNE
-- BF Battery: switch Betaflight battery cell-voltage thresholds (LiPo / LiHV / Li-ion)
-- over CRSF MSP (ExpressLRS / TBS Crossfire). EdgeTX, B&W 128x64 radios (Boxer etc.).
-- Install: /SCRIPTS/TOOLS/BFBatt.lua  -> SYS > Tools > "BF Battery"
-- Quad must be powered, linked, telemetry on, and DISARMED.
-- Active min/warn go to GV8/GV9 (for lowbat.lua). Settings file: /SCRIPTS/BFBatt.cfg
-- Menu: wheel = select, ENTER = apply profile. "Settings >" edits profiles + lowbat alarm.

local CFG = "/SCRIPTS/BFBatt.cfg"

-- defaults, editable on the radio under "Settings" (cell voltages in 0.01 V)
local PROFILES = {
  { key = "lipo", name = "LiPo",   min = 330, warn = 350, max = 430 },
  { key = "lihv", name = "LiHV",   min = 340, warn = 360, max = 435 },
  { key = "lion", name = "Li-ion", min = 290, warn = 310, max = 420 },
}
-- alarm settings used by lowbat.lua
-- hold = alarm delay in 0.1 s (file stores seconds); arm = "Always" or e.g. "SA down"
local S = { hold = 5, wrep = 5, crep = 1, hapt = 1, voice = 0, sensor = "RxBt", arm = "SA down" }

local MSP_BATTERY_CONFIG     = 32
local MSP_SET_BATTERY_CONFIG = 33
local MSP_EEPROM_WRITE       = 250

local ADDR_FC, ADDR_RADIO = 0xC8, 0xEA
local FT_REQ, FT_RESP, FT_WRITE = 0x7A, 0x7B, 0x7C
local TX_CHUNK = 8     -- MSP bytes per CRSF frame (incl. status byte)
local TIMEOUT  = 250   -- 2.5 s per try (getTime() = 10 ms ticks); ELRS Std telem ratio is slow
local RETRIES  = 5     -- for writes; reads retry until you press EXIT
local GV_MIN, GV_WARN = 7, 8   -- 0-based (7 = GV8, 8 = GV9)
local ROWS = 7

local page, sel, state, msg = "main", 1, "read", "Reading FC..."
local cfg, cur, target = nil, nil, nil
local ITEMS, LISTS = {}, { sensor = { "Auto" }, arm = { "Always" } }
local si, top, edit, old, dirty, dirtyP = 1, 1, false, nil, false, false

-- TX state
local txBuf, txIdx, txCrc, txType, txPending, seq = {}, 1, 0, FT_REQ, false, 0
local lastCmd, lastSend, tries = nil, 0, 0
-- RX state
local rxBuf, rxSize, rxCmd, rxErr, rxSeq, rxOn = {}, 0, nil, false, 0, false

local function u16(b, i) return b[i] + b[i + 1] * 256 end
local function v(x) return string.format("%.2f", x / 100) end

---------------------------------------------------------------- settings file
local function loadCfg()
  local f = io.open(CFG, "r")
  if not f then return end
  local data = io.read(f, 1024) or ""
  io.close(f)
  for k, val in string.gmatch(data, "([%w_]+)=([^\r\n]*)") do
    local pk, fld = string.match(k, "^(%w+)_(%w+)$")
    if pk then
      for _, p in ipairs(PROFILES) do
        if p.key == pk and p[fld] then p[fld] = tonumber(val) or p[fld] end
      end
    elseif k == "sensor" or k == "arm" then
      S[k] = val
    elseif k == "hold" then
      local x = tonumber(val)
      if x then S.hold = math.floor(x * 10 + 0.5) end
    elseif S[k] ~= nil then
      S[k] = tonumber(val) or S[k]
    end
  end
end

local function saveCfg()
  local t = {}
  for _, p in ipairs(PROFILES) do
    t[#t + 1] = p.key .. "_min=" .. p.min
    t[#t + 1] = p.key .. "_warn=" .. p.warn
    t[#t + 1] = p.key .. "_max=" .. p.max
  end
  t[#t + 1] = string.format("hold=%.1f", S.hold / 10)
  for _, k in ipairs({ "wrep", "crep", "hapt", "voice", "sensor", "arm" }) do
    t[#t + 1] = k .. "=" .. S[k]
  end
  local out = ""
  for _, l in ipairs(t) do out = out .. l .. "\n" end
  local f = io.open(CFG, "w")
  if not f then return false end
  io.write(f, out)
  io.close(f)
  return true
end

---------------------------------------------------------------- radio alarm GVs
local function setGV(p)
  model.setGlobalVariable(GV_MIN, 0, p.min)
  model.setGlobalVariable(GV_WARN, 0, p.warn)
end

local function gvText()
  local w = model.getGlobalVariable(GV_WARN, 0)
  if not w or w <= 0 then return "R --" end
  return "R " .. v(w)
end

local function same(p)
  return cur and cur.min == p.min and cur.warn == p.warn and cur.max == p.max
end

---------------------------------------------------------------- MSP over CRSF
local function send(cmd, data, write)
  while crossfireTelemetryPop() do end           -- drop stale replies from earlier requests
  rxOn = false
  txType = write and FT_WRITE or FT_REQ
  txBuf = { #data, cmd }
  for i = 1, #data do txBuf[i + 2] = bit32.band(data[i], 0xFF) end
  txIdx, txCrc, txPending = 1, 0, true
  lastCmd, lastSend, tries = cmd, getTime(), 0
end

local function resend()
  txIdx, txCrc, txPending = 1, 0, true
  lastSend, tries = getTime(), tries + 1
end

local function pumpTx()
  if not txPending or not crossfireTelemetryPush() then return end
  local f = { ADDR_FC, ADDR_RADIO }
  local status = seq + 0x20                      -- MSP v1
  if txIdx == 1 then status = status + 0x10 end  -- start of packet
  seq = bit32.band(seq + 1, 0x0F)
  f[3] = status
  local i = 2
  while i <= TX_CHUNK and txIdx <= #txBuf do
    f[i + 2] = txBuf[txIdx]
    txCrc = bit32.bxor(txCrc, txBuf[txIdx])
    txIdx, i = txIdx + 1, i + 1
  end
  if i <= TX_CHUNK then                          -- last chunk: CRC + zero fill
    f[i + 2] = txCrc
    i = i + 1
    while i <= TX_CHUNK do f[i + 2] = 0; i = i + 1 end
    txPending = false
  end
  crossfireTelemetryPush(txType, f)
end

local function sizeOk(cmd, n)                   -- BF <= 4.2 replies carry no cmd byte:
  if cmd == MSP_BATTERY_CONFIG then return n >= 7 end   -- reject late duplicates by size
  return n == 0
end

local function handleChunk(d)
  local idx = 3
  local status = d[idx]; idx = idx + 1
  local s = bit32.band(status, 0x0F)
  if bit32.btest(status, 0x10) then              -- start frame
    rxBuf, rxErr = {}, bit32.btest(status, 0x80)
    rxSize = d[idx]; idx = idx + 1
    rxCmd = lastCmd
    if bit32.rshift(bit32.band(status, 0x60), 5) == 1 then
      rxCmd = d[idx]; idx = idx + 1
    end
    rxOn = (rxCmd == lastCmd) and (rxErr or sizeOk(rxCmd, rxSize))
    if not rxOn then return nil end
  elseif not rxOn or bit32.band(rxSeq + 1, 0x0F) ~= s then
    rxOn = false
    return nil
  end
  rxSeq = s
  while idx <= #d and #rxBuf < rxSize do
    rxBuf[#rxBuf + 1] = d[idx]
    idx = idx + 1
  end
  if #rxBuf < rxSize then return nil end
  rxOn = false
  return rxCmd, rxBuf, rxErr
end

local function pollRx()
  local t, d = crossfireTelemetryPop()
  while t do
    if t == FT_RESP and d[1] == ADDR_RADIO and d[2] == ADDR_FC then
      local c, b, e = handleChunk(d)
      if c then return c, b, e end
    end
    t, d = crossfireTelemetryPop()
  end
end

local function setPayload(p)
  local d = {}
  local function put8(x) d[#d + 1] = bit32.band(x, 0xFF) end
  local function put16(x) put8(x); put8(bit32.rshift(x, 8)) end
  put8(math.floor((p.min + 5) / 10))
  put8(math.floor((p.max + 5) / 10))
  put8(math.floor((p.warn + 5) / 10))
  for i = 4, 7 do put8(cfg[i]) end               -- keep capacity + meter sources
  put16(p.min); put16(p.max); put16(p.warn)
  return d
end

local function onReply(cmd, d, err)
  if err then state, msg = "idle", "FC error (armed?)"; return end
  if cmd == MSP_BATTERY_CONFIG then
    if #d < 13 then state, msg = "idle", "BF too old (<4.0)"; return end
    cfg = d
    cur = { min = u16(d, 8), max = u16(d, 10), warn = u16(d, 12) }
    if state == "verify" then
      if same(target) then
        setGV(target)
        msg = "Saved: " .. target.name
      else
        msg = "Verify mismatch!"
      end
    else
      if sel <= #PROFILES then                   -- don't move cursor off "Settings"
        for i, p in ipairs(PROFILES) do if same(p) then sel = i end end
      end
      msg = "ENTER = apply"
    end
    state = "idle"
  elseif cmd == MSP_SET_BATTERY_CONFIG then
    state, msg = "save", "Saving EEPROM..."
    send(MSP_EEPROM_WRITE, {}, false)
  elseif cmd == MSP_EEPROM_WRITE then
    state, msg = "verify", "Verifying..."
    send(MSP_BATTERY_CONFIG, {}, false)
  end
end

local function apply()
  local p = PROFILES[sel]
  if not (p.min < p.warn and p.warn < p.max) then msg = "Need min<warn<max"; return end
  if cfg then
    target = { name = p.name, min = p.min, warn = p.warn, max = p.max }  -- snapshot
    state, msg = "write", "Writing..."
    send(MSP_SET_BATTERY_CONFIG, setPayload(p), true)
  else
    state, msg = "read", "Reading FC..."
    send(MSP_BATTERY_CONFIG, {}, false)
  end
end

---------------------------------------------------------------- settings page
for _, p in ipairs(PROFILES) do
  ITEMS[#ITEMS + 1] = { label = p.name .. " min",  t = p, f = "min",  lo = 250, hi = 450, volt = true }
  ITEMS[#ITEMS + 1] = { label = p.name .. " warn", t = p, f = "warn", lo = 250, hi = 450, volt = true }
  ITEMS[#ITEMS + 1] = { label = p.name .. " max",  t = p, f = "max",  lo = 380, hi = 450, volt = true }
end
ITEMS[#ITEMS + 1] = { label = "Cell sensor", t = S, f = "sensor", list = "sensor" }
ITEMS[#ITEMS + 1] = { label = "Active when", t = S, f = "arm",    list = "arm" }
ITEMS[#ITEMS + 1] = { label = "Alarm delay", t = S, f = "hold",  lo = 0, hi = 100, tenths = true }
ITEMS[#ITEMS + 1] = { label = "Warn repeat", t = S, f = "wrep",  lo = 1, hi = 30, unit = "s" }
ITEMS[#ITEMS + 1] = { label = "Crit repeat", t = S, f = "crep",  lo = 1, hi = 30, unit = "s" }
ITEMS[#ITEMS + 1] = { label = "Vibrate",     t = S, f = "hapt",  lo = 0, hi = 1, bool = true }
ITEMS[#ITEMS + 1] = { label = "Voice",       t = S, f = "voice", lo = 0, hi = 1, bool = true }

local function valText(it)
  local x = it.t[it.f]
  if it.list then return x end
  if it.volt then return v(x) .. "V" end
  if it.bool then return (x == 1) and "ON" or "OFF" end
  if it.tenths then return string.format("%.1fs", x / 10) end
  return x .. it.unit
end

local function adjust(it, d)
  if it.list then
    local l, idx = LISTS[it.list], 1
    for k, n in ipairs(l) do if n == it.t[it.f] then idx = k end end
    it.t[it.f] = l[(idx - 1 + d) % #l + 1]
  else
    local x = it.t[it.f] + d
    if x < it.lo then x = it.lo elseif x > it.hi then x = it.hi end
    it.t[it.f] = x
  end
end

local function openSettings()
  local sl, al = { "Auto" }, { "Always" }
  if model.getSensor then
    for i = 0, 59 do
      local s = model.getSensor(i)
      if not s then break end
      if s.name and s.name ~= "" then sl[#sl + 1] = s.name end
    end
  end
  for _, c in ipairs({ "a", "b", "c", "d", "e", "f", "g", "h" }) do   -- switches on this radio
    if getFieldInfo("s" .. c) then
      for _, p in ipairs({ "up", "mid", "down" }) do al[#al + 1] = "S" .. string.upper(c) .. " " .. p end
    end
  end
  LISTS.sensor, LISTS.arm = sl, al
  page, si, top, edit, dirty, dirtyP = "set", 1, 1, false, false, false
end

local function drawSettings()
  lcd.clear()
  lcd.drawText(1, 0, "Settings  " .. si .. "/" .. #ITEMS, SMLSIZE + INVERS)
  if si < top then top = si elseif si > top + ROWS - 1 then top = si - ROWS + 1 end
  for r = 0, ROWS - 1 do
    local i = top + r
    local it = ITEMS[i]
    if not it then break end
    local y = 8 + r * 8
    lcd.drawText(2, y, it.label, SMLSIZE)
    local fl = SMLSIZE
    if i == si then fl = fl + INVERS + (edit and BLINK or 0) end
    lcd.drawText(84, y, valText(it), fl)
  end
end

local function runSettings(event)
  local it = ITEMS[si]
  if edit then                                   -- wheel: INC == NEXT; keys: INC == UP
    if event == EVT_VIRTUAL_INC or event == EVT_VIRTUAL_INC_REPT then adjust(it, 1)
    elseif event == EVT_VIRTUAL_DEC or event == EVT_VIRTUAL_DEC_REPT then adjust(it, -1)
    elseif event == EVT_VIRTUAL_ENTER then
      edit, dirty = false, true
      if it.volt then dirtyP = true end
    elseif event == EVT_VIRTUAL_EXIT then
      it.t[it.f], edit = old, false              -- cancel edit
    end
  else
    if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_NEXT_REPT then si = math.min(si + 1, #ITEMS)
    elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_PREV_REPT then si = math.max(si - 1, 1)
    elseif event == EVT_VIRTUAL_ENTER then old, edit = it.t[it.f], true
    elseif event == EVT_VIRTUAL_EXIT then
      if dirty then
        if not saveCfg() then msg = "Save failed!"
        elseif dirtyP then msg = "Saved - re-apply"
        else msg = "Settings saved" end
      end
      page = "main"
    end
  end
  drawSettings()
end

---------------------------------------------------------------- main page
local function drawMain()
  lcd.clear()
  lcd.drawText(1, 0, "BF Battery  min/warn/max", SMLSIZE + INVERS)
  for i, p in ipairs(PROFILES) do
    local y = 9 + (i - 1) * 9
    lcd.drawText(2, y, p.name, (i == sel) and INVERS or 0)
    if same(p) then lcd.drawText(39, y, "*", 0) end
    lcd.drawText(46, y + 1, v(p.min) .. "/" .. v(p.warn) .. "/" .. v(p.max), SMLSIZE)
  end
  lcd.drawText(2, 36, "Settings >", (sel == #PROFILES + 1) and INVERS or 0)
  if cur then
    lcd.drawText(2, 47, "FC " .. v(cur.min) .. "/" .. v(cur.warn) .. "/" .. v(cur.max), SMLSIZE)
  end
  lcd.drawText(94, 47, gvText(), SMLSIZE)
  lcd.drawText(2, 56, msg, (state ~= "idle") and (SMLSIZE + BLINK) or SMLSIZE)
  if state ~= "idle" then
    local d = crossfireTelemetryPush()
    local st = (d == nil) and "noCRSF" or (getRSSI() == 0 and "noTLM") or ("t" .. (tries + 1) .. (d and "" or "b"))
    lcd.drawText(98, 56, st, SMLSIZE)
  end
end

local function init()
  loadCfg()
  send(MSP_BATTERY_CONFIG, {}, false)
end

local function run(event)
  if state ~= "idle" then                        -- MSP engine runs on every page
    pumpTx()
    local c, d, e = pollRx()
    if c then
      onReply(c, d, e)
    elseif getTime() - lastSend > TIMEOUT then
      if tries >= RETRIES and lastCmd ~= MSP_BATTERY_CONFIG then
        state, msg = "idle", "No reply - telem?"
      else
        resend()
      end
    end
  end

  if page == "set" then runSettings(event); return 0 end

  if event == EVT_VIRTUAL_EXIT then
    if state ~= "idle" then
      state, msg, txPending = "idle", "Cancelled", false
      drawMain()
      return 0
    end
    return 1
  end
  local n = #PROFILES + 1
  if event == EVT_VIRTUAL_NEXT then
    sel = sel % n + 1
  elseif event == EVT_VIRTUAL_PREV then
    sel = (sel - 2) % n + 1
  elseif event == EVT_VIRTUAL_ENTER then
    if sel == n then openSettings()
    elseif state == "idle" then apply() end
  end
  drawMain()
  return 0
end

return { init = init, run = run }
