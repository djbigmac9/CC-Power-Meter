-- ============================================================
--  BeyondSMP Electric Meter v2.1
--  Peripherals:
--    Import Detector = LEFT side  (grid → player, consumers)
--    Export Detector = RIGHT side (player → grid, producers)
--    Monitor         = any side
--    Ender Modem     = any side
--  Networking:
--    STATUS_CH  : meter broadcasts status every 5s
--    COMMAND_CH : meter listens for admin commands
-- ============================================================

-- ── Version & update ─────────────────────────────────────────
local VERSION      = "2.1"
local RAW_URL      = "https://raw.githubusercontent.com/djbigmac9/CC-Power-Meter/main/meter.lua"
local UPDATE_EVERY = 300

local updateAvailable = false

local function parseVersion(v)
  local major, minor = v:match("(%d+)%.(%d+)")
  return tonumber(major) or 0, tonumber(minor) or 0
end

local function isNewer(latest, current)
  local lMaj, lMin = parseVersion(latest)
  local cMaj, cMin = parseVersion(current)
  if lMaj ~= cMaj then return lMaj > cMaj end
  return lMin > cMin
end

local function getLatestVersion()
  local ok, res = pcall(function()
    return http.get(RAW_URL)
  end)
  if not ok or not res then return nil end
  local body = res.readAll(); res.close()
  return body:match('VERSION%s*=%s*"([%d%.]+)"')
end

local function doUpdate()
  term.setTextColor(colors.lime)
  print("Downloading update...")
  local path = shell.getRunningProgram()
  local tmp  = path .. ".tmp"
  if fs.exists(tmp) then fs.delete(tmp) end
  local ok, res = pcall(function()
    return http.get(RAW_URL)
  end)
  if ok and res then
    local body = res.readAll(); res.close()
    local f = fs.open(tmp, "w"); f.write(body); f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    print("Done. Rebooting...")
    os.sleep(1); os.reboot()
  else
    if fs.exists(tmp) then fs.delete(tmp) end
    term.setTextColor(colors.red)
    print("Download failed.")
    term.setTextColor(colors.white)
  end
end

local function bootUpdateCheck()
  term.setTextColor(colors.lightGray)
  io.write("Checking for updates... ")
  local latest = getLatestVersion()
  if not latest then
    term.setTextColor(colors.gray); print("offline, skipping")
    term.setTextColor(colors.white); return
  end
  if isNewer(latest, VERSION) then
    term.setTextColor(colors.orange)
    print("update found (v" .. latest .. ")")
    doUpdate()
  else
    term.setTextColor(colors.lime); print("up to date (v" .. VERSION .. ")")
    term.setTextColor(colors.white)
  end
end

local function backgroundUpdateCheck()
  local latest = getLatestVersion()
  if latest and isNewer(latest, VERSION) then
    updateAvailable = true
  end
end

-- ── Config ───────────────────────────────────────────────────
local RATE_PER_FE     = 0.0001
local POLL_INTERVAL   = 1.0
local WARN_BALANCE    = 50
local DATA_FILE       = "meter_data"
local TEMP_TOP_UP     = 200
local MAX_FLOW        = 2147483647
local STATUS_CH       = 1001
local COMMAND_CH      = 1002
local BROADCAST_EVERY = 5

-- ── Peripheral detection ─────────────────────────────────────
local importDetector = nil   -- left:  grid → player
local exportDetector = nil   -- right: player → grid
local monitor = peripheral.find("monitor")
local modem   = peripheral.find("modem")

if peripheral.isPresent("left") and peripheral.getType("left") == "energy_detector" then
  importDetector = peripheral.wrap("left")
end
if peripheral.isPresent("right") and peripheral.getType("right") == "energy_detector" then
  exportDetector = peripheral.wrap("right")
end

-- ── Boot error screen ────────────────────────────────────────
local function bootError(msg)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.red)
  term.clear(); term.setCursorPos(1,1)
  print("=== BEYOND ENERGY METER ===\n")
  term.setTextColor(colors.white)
  print("STARTUP ERROR:\n" .. msg .. "\n")
  term.setTextColor(colors.lightGray)
  print("Check connections and reboot.")
  error(msg, 0)
end

if not importDetector and not exportDetector then
  bootError("No Energy Detector found.\nLeft = grid import, Right = grid export.")
end
if not monitor then bootError("No monitor found.\nAttach a CC Advanced Monitor to any side.") end
if not modem   then bootError("No modem found.\nAttach an Ender Modem to any side.") end

modem.open(COMMAND_CH)

print("Import Detector : " .. (importDetector and "left"  or "not found"))
print("Export Detector : " .. (exportDetector and "right" or "not found"))
print("Modem           : found")
print("Monitor         : found")
print("Listening on ch : " .. COMMAND_CH)
print("Broadcasting on : " .. STATUS_CH)
print("Computer ID     : " .. os.getComputerID())
bootUpdateCheck()
print("Booting...")
os.sleep(1)

monitor.setTextScale(0.5)

-- ── Persistent data ──────────────────────────────────────────
local data = {
  playerName    = nil,
  billingModel  = nil,
  balance       = 0,
  totalConsumed = 0,
  totalExported = 0,
  periodUsage   = 0,
  powerOn       = false,
  registered    = false,
  isProducer    = false,
  ratePerFE     = RATE_PER_FE,
}

local function saveData()
  local f = fs.open(DATA_FILE, "w")
  f.write(textutils.serialize(data))
  f.close()
end

local function loadData()
  if fs.exists(DATA_FILE) then
    local f = fs.open(DATA_FILE, "r")
    local raw = f.readAll(); f.close()
    local loaded = textutils.unserialize(raw)
    if loaded then
      data = loaded
      RATE_PER_FE           = data.ratePerFE     or RATE_PER_FE
      data.totalExported    = data.totalExported  or 0
      data.isProducer       = data.isProducer     or false
    end
  end
end

-- ── Power control ────────────────────────────────────────────
local function setPower(state)
  data.powerOn = state
  if data.isProducer then
    if exportDetector then exportDetector.setTransferRateLimit(state and MAX_FLOW or 0) end
    if importDetector then importDetector.setTransferRateLimit(0) end  -- always blocked
  else
    if importDetector then importDetector.setTransferRateLimit(state and MAX_FLOW or 0) end
    if exportDetector then exportDetector.setTransferRateLimit(0) end  -- always blocked
  end
  saveData()
end

-- ── Networking ───────────────────────────────────────────────
local function broadcastStatus(importRate, exportRate)
  modem.transmit(STATUS_CH, COMMAND_CH, {
    type          = "status",
    id            = os.getComputerID(),
    player        = data.playerName,
    plan          = data.billingModel,
    balance       = data.balance,
    draw          = importRate,
    export        = exportRate,
    isProducer    = data.isProducer,
    cap           = importDetector and importDetector.getTransferRateLimit and importDetector.getTransferRateLimit() or 0,
    powerOn       = data.powerOn,
    total         = data.totalConsumed,
    totalExported = data.totalExported,
    ratePerFE     = data.ratePerFE,
  })
end

local function handleCommand(msg)
  if type(msg) ~= "table" then return end
  if msg.id ~= os.getComputerID() and msg.id ~= "all" then return end

  if msg.cmd == "cut" then
    setPower(false)

  elseif msg.cmd == "restore" then
    if data.isProducer or data.balance > 0 then setPower(true) end

  elseif msg.cmd == "update" then
    term.setTextColor(colors.orange)
    print("Remote update command received.")
    doUpdate()

  elseif msg.cmd == "setplan" and type(msg.value) == "string" then
    data.billingModel = msg.value
    saveData()

  elseif msg.cmd == "setname" and type(msg.value) == "string" then
    data.playerName = msg.value
    saveData()

  elseif msg.cmd == "setcap" and type(msg.value) == "number" then
    if importDetector then importDetector.setTransferRateLimit(msg.value) end

  elseif msg.cmd == "setbalance" and type(msg.value) == "number" then
    data.balance = msg.value
    if not data.isProducer then
      if data.balance > 0 and not data.powerOn then setPower(true) end
      if data.balance <= 0 and data.powerOn     then setPower(false) end
    end
    saveData()

  elseif msg.cmd == "setrate" and type(msg.value) == "number" then
    data.ratePerFE = msg.value
    RATE_PER_FE    = msg.value
    saveData()

  elseif msg.cmd == "settype" and type(msg.value) == "string" then
    data.isProducer = (msg.value == "producer")
    setPower(data.powerOn)
    saveData()
  end
end

-- ── Monitor helpers ──────────────────────────────────────────
local W, H

local function refreshSize() W, H = monitor.getSize() end

local function cls()
  monitor.setBackgroundColor(colors.black)
  monitor.clear(); refreshSize()
end

local function writeAt(x, y, text, fg, bg)
  monitor.setCursorPos(x, y)
  monitor.setTextColor(fg or colors.white)
  monitor.setBackgroundColor(bg or colors.black)
  monitor.write(text)
end

local function centreText(y, text, fg, bg)
  writeAt(math.floor((W - #text) / 2) + 1, y, text, fg, bg)
end

local function hline(y, char, fg, bg)
  writeAt(1, y, string.rep(char or "-", W), fg or colors.gray, bg or colors.black)
end

local function formatFE(n)
  if n >= 1e9 then return string.format("%.2f GFE", n/1e9)
  elseif n >= 1e6 then return string.format("%.2f MFE", n/1e6)
  elseif n >= 1e3 then return string.format("%.2f kFE", n/1e3)
  else return string.format("%d FE", n) end
end

local function formatCurrency(n)
  return string.format("%.4f LC", n)
end

-- ── Button system ────────────────────────────────────────────
local buttons = {}
local function clearButtons() buttons = {} end

local function addButton(x1, y1, x2, y2, label, fg, bg, action)
  table.insert(buttons, {x1=x1,y1=y1,x2=x2,y2=y2,label=label,fg=fg,bg=bg,action=action})
end

local function drawButtons()
  for _, b in ipairs(buttons) do
    local bw  = b.x2 - b.x1 + 1
    local pad = math.floor((bw - #b.label) / 2)
    local str = string.rep(" ", pad) .. b.label .. string.rep(" ", bw - pad - #b.label)
    writeAt(b.x1, b.y1, str, b.fg or colors.black, b.bg or colors.lime)
  end
end

local function checkClick(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      b.action(); return true
    end
  end
  return false
end

-- ── Registration screens ─────────────────────────────────────
local regName = ""

local function drawRegisterName()
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY", colors.yellow)
  centreText(3, "New Customer Setup", colors.lightGray)
  hline(4)
  centreText(6,  "Step 1 of 3: Your Player Name", colors.white)
  centreText(8,  "Type your name on the computer keyboard,", colors.lightGray)
  centreText(9,  "then press ENTER.", colors.lightGray)
  centreText(11, "> " .. regName .. "_", colors.lime)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

local function drawRegisterPlan(name)
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY", colors.yellow)
  centreText(3, "New Customer Setup", colors.lightGray)
  hline(4)
  centreText(6, "Step 2 of 3: Choose Your Billing Plan", colors.white)
  centreText(7, "Hi " .. name .. "! Select a plan below.", colors.lightGray)
  hline(9)
  local mid  = math.floor(W / 2)
  local btnW = math.floor(W / 2) - 3
  writeAt(2,     10, "PAY AS YOU GO",    colors.lime)
  writeAt(2,     11, "Balance drains in", colors.lightGray)
  writeAt(2,     12, "real time. Power",  colors.lightGray)
  writeAt(2,     13, "cuts if you run",   colors.lightGray)
  writeAt(2,     14, "out of funds.",     colors.lightGray)
  writeAt(mid+1, 10, "PERIODIC BILLING",  colors.cyan)
  writeAt(mid+1, 11, "Usage logged and",  colors.lightGray)
  writeAt(mid+1, 12, "charged once per",  colors.lightGray)
  writeAt(mid+1, 13, "billing period.",   colors.lightGray)
  writeAt(mid+1, 14, "Grace period inc.", colors.lightGray)
  hline(16)
  addButton(2,     17, 2+btnW,     17, "SELECT PAYG",     colors.black, colors.lime, function()
    data.billingModel = "payg"
  end)
  addButton(mid+1, 17, mid+1+btnW, 17, "SELECT PERIODIC", colors.black, colors.cyan, function()
    data.billingModel = "periodic"
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

local function drawRegisterType(name)
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY", colors.yellow)
  centreText(3, "New Customer Setup", colors.lightGray)
  hline(4)
  centreText(6, "Step 3 of 3: Connection Type", colors.white)
  centreText(7, "How will " .. name .. " connect to the grid?", colors.lightGray)
  hline(9)
  local mid  = math.floor(W / 2)
  local btnW = math.floor(W / 2) - 3
  writeAt(2,     10, "CONSUMER",          colors.cyan)
  writeAt(2,     11, "Draws power from",  colors.lightGray)
  writeAt(2,     12, "the grid. Needs",   colors.lightGray)
  writeAt(2,     13, "LEFT detector.",    colors.lightGray)
  writeAt(mid+1, 10, "PRODUCER",          colors.lime)
  writeAt(mid+1, 11, "Sells surplus to",  colors.lightGray)
  writeAt(mid+1, 12, "the grid. Needs",   colors.lightGray)
  writeAt(mid+1, 13, "RIGHT detector.",   colors.lightGray)
  hline(15)
  addButton(2,     16, 2+btnW,     16, "CONSUMER", colors.black, colors.cyan, function()
    data.isProducer = false
    data.playerName = name
    data.registered = true
    setPower(true)
    saveData()
  end)
  addButton(mid+1, 16, mid+1+btnW, 16, "PRODUCER", colors.black, colors.lime, function()
    data.isProducer = true
    data.playerName = name
    data.registered = true
    setPower(true)
    saveData()
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Plan / type change screens ────────────────────────────────
local planChangeActive = false
local typeChangeActive = false

local function drawPlanChangeScreen()
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY",       colors.yellow)
  centreText(3, "Change Billing Plan", colors.lightGray)
  hline(4)
  local newPlan  = data.billingModel == "payg" and "periodic" or "payg"
  local newLabel = newPlan == "payg" and "Pay As You Go" or "Periodic Billing"
  local curLabel = data.billingModel == "payg" and "Pay As You Go" or "Periodic Billing"
  centreText(6, "Current plan: " .. curLabel, colors.white)
  centreText(7, "Switch to:    " .. newLabel, colors.cyan)
  hline(9)
  if data.billingModel == "periodic" and data.periodUsage > 0 then
    local charge = data.periodUsage * data.ratePerFE
    centreText(10, "Outstanding period usage will be", colors.orange)
    centreText(11, "charged now: " .. formatCurrency(charge), colors.orange)
    centreText(12, "New balance: " .. formatCurrency(data.balance - charge), colors.white)
    hline(14)
  else
    centreText(11, "No outstanding charges.", colors.lightGray)
    centreText(12, "Switch takes effect immediately.", colors.lightGray)
    hline(14)
  end
  local btnW = math.floor(W/2) - 3
  local mid  = math.floor(W/2)
  addButton(2,     15, 2+btnW,     15, "CONFIRM SWITCH", colors.black, colors.lime, function()
    if data.billingModel == "periodic" and data.periodUsage > 0 then
      local charge = data.periodUsage * data.ratePerFE
      data.balance = data.balance - charge
      data.periodUsage = 0
      if data.balance <= 0 then
        data.balance = 0
        if data.powerOn then setPower(false) end
      end
    end
    data.billingModel = newPlan; saveData(); planChangeActive = false
  end)
  addButton(mid+1, 15, mid+1+btnW, 15, "CANCEL", colors.white, colors.red, function()
    planChangeActive = false
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

local function drawTypeChangeScreen()
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY",         colors.yellow)
  centreText(3, "Change Connection Type", colors.lightGray)
  hline(4)
  local curLabel = data.isProducer and "Producer" or "Consumer"
  local newLabel = data.isProducer and "Consumer" or "Producer"
  centreText(6, "Current type: " .. curLabel, colors.white)
  centreText(7, "Switch to:    " .. newLabel, colors.cyan)
  hline(9)
  if data.isProducer then
    centreText(10, "Switching will block export and",  colors.orange)
    centreText(11, "enable grid import (LEFT side).",  colors.orange)
  else
    centreText(10, "Switching will block grid import", colors.orange)
    centreText(11, "and enable export (RIGHT side).",  colors.orange)
  end
  centreText(12, "Switch takes effect immediately.", colors.lightGray)
  hline(14)
  local btnW = math.floor(W/2) - 3
  local mid  = math.floor(W/2)
  addButton(2,     15, 2+btnW,     15, "CONFIRM", colors.black, colors.lime, function()
    data.isProducer = not data.isProducer
    setPower(data.powerOn)
    saveData(); typeChangeActive = false
  end)
  addButton(mid+1, 15, mid+1+btnW, 15, "CANCEL", colors.white, colors.red, function()
    typeChangeActive = false
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Main meter screen ────────────────────────────────────────
local function drawMeterScreen(importRate, exportRate)
  importRate = importRate or 0
  exportRate = exportRate or 0
  cls(); clearButtons(); refreshSize()

  writeAt(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  centreText(1, " BEYOND ENERGY METER ", colors.black, colors.yellow)

  writeAt(2, 2, " Customer: ", colors.lightGray)
  monitor.setTextColor(colors.white)
  monitor.write(data.playerName or "Unknown")

  writeAt(2, 3, " Plan:     ", colors.lightGray)
  monitor.setTextColor(colors.cyan)
  monitor.write(data.billingModel == "payg" and "Pay As You Go" or "Periodic Billing")

  writeAt(2, 4, " Type:     ", colors.lightGray)
  monitor.setTextColor(data.isProducer and colors.lime or colors.cyan)
  monitor.write(data.isProducer and "Producer" or "Consumer")

  hline(5)

  if data.isProducer then
    writeAt(2, 6, " Exporting: ", colors.lightGray)
    monitor.setTextColor(colors.lime)
    monitor.write(formatFE(exportRate) .. "/t   ")
    writeAt(2, 7, " Earning:   ", colors.lightGray)
    monitor.setTextColor(colors.lime)
    monitor.write(string.format("%.4f LC/t   ", exportRate * data.ratePerFE * 0.75))
  else
    writeAt(2, 6, " Draw:     ", colors.lightGray)
    monitor.setTextColor(colors.white)
    monitor.write(formatFE(importRate) .. "/t   ")
    writeAt(2, 7, " Rate cap: ", colors.lightGray)
    monitor.setTextColor(colors.gray)
    local cap = importDetector and importDetector.getTransferRateLimit and importDetector.getTransferRateLimit() or 0
    monitor.write(cap >= MAX_FLOW and "Unlimited" or formatFE(cap).."/t")
  end

  hline(8)

  writeAt(2, 9, " Balance:       ", colors.lightGray)
  local balCol = data.balance > WARN_BALANCE and colors.lime
              or (data.balance > 0 and colors.yellow or colors.red)
  monitor.setTextColor(balCol)
  monitor.write(formatCurrency(data.balance).."   ")

  writeAt(2, 10, " Total consumed:", colors.lightGray)
  monitor.setTextColor(colors.white)
  monitor.write(formatFE(data.totalConsumed).."   ")

  if data.isProducer then
    writeAt(2, 11, " Total exported:", colors.lightGray)
    monitor.setTextColor(colors.lime)
    monitor.write(formatFE(data.totalExported).."   ")
  elseif data.billingModel == "periodic" then
    writeAt(2, 11, " Period usage:  ", colors.lightGray)
    monitor.setTextColor(colors.white)
    monitor.write(formatFE(data.periodUsage).."   ")
  end

  hline(12)

  if data.isProducer then
    if data.powerOn then
      centreText(13, " ● EXPORTING TO GRID ", colors.black, colors.lime)
    else
      centreText(13, " ● EXPORT DISABLED ", colors.white, colors.red)
    end
  else
    if data.powerOn then
      centreText(13, " ● POWER ON ", colors.black, colors.lime)
    else
      centreText(13, " ● POWER OFF - TOP UP TO RECONNECT ", colors.white, colors.red)
    end
    if data.balance <= WARN_BALANCE and data.balance > 0 then
      centreText(14, "  Low balance - please top up soon  ", colors.black, colors.orange)
    end
  end

  if updateAvailable then
    local label = " ** UPDATE AVAILABLE - TAP TO INSTALL ** "
    local bx    = math.floor((W - #label) / 2) + 1
    addButton(bx, 15, bx + #label - 1, 15, label, colors.black, colors.yellow, function()
      doUpdate()
    end)
    centreText(15, label, colors.black, colors.yellow)
  end

  hline(H-3)
  local btnW = math.floor((W-4)/4)
  local b2x  = 2 + btnW + 1
  local b3x  = b2x + btnW + 1
  local b4x  = b3x + btnW + 1

  addButton(2,   H-2, 2+btnW-1,   H-2, "[TEMP] +"..TEMP_TOP_UP.." LC",
    colors.black, colors.purple, function()
      data.balance = data.balance + TEMP_TOP_UP
      if not data.isProducer and not data.powerOn and data.balance > 0 then setPower(true) end
      saveData()
    end)
  addButton(b2x, H-2, b2x+btnW-1, H-2, "CHANGE PLAN",
    colors.black, colors.cyan, function() planChangeActive = true end)
  addButton(b3x, H-2, b3x+btnW-1, H-2, "CHANGE TYPE",
    colors.black, colors.orange, function() typeChangeActive = true end)
  addButton(b4x, H-2, W-1,        H-2,
    data.powerOn and (data.isProducer and "STOP EXPORT" or "CUT POWER")
                 or  (data.isProducer and "START EXPORT" or "RESTORE"),
    colors.white, data.powerOn and colors.red or colors.green, function()
      if data.powerOn then
        setPower(false)
      elseif data.isProducer or data.balance > 0 then
        setPower(true)
      end
    end)

  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Registration flow ────────────────────────────────────────
local regStep = 1

local function runRegistration()
  regName = ""; regStep = 1; drawRegisterName()
  while not data.registered do
    local ev = { os.pullEvent() }
    local e  = ev[1]
    if regStep == 1 then
      if e == "char" then
        regName = regName .. ev[2]; drawRegisterName()
      elseif e == "key" then
        if ev[2] == keys.backspace and #regName > 0 then
          regName = regName:sub(1,-2); drawRegisterName()
        elseif ev[2] == keys.enter and #regName > 0 then
          regStep = 2; drawRegisterPlan(regName)
        end
      elseif e == "monitor_touch" then
        checkClick(ev[3], ev[4])
      end
    elseif regStep == 2 then
      if e == "monitor_touch" then
        checkClick(ev[3], ev[4])
        if data.billingModel then
          regStep = 3; drawRegisterType(regName)
        end
      elseif e == "key" and ev[2] == keys.backspace then
        regStep = 1; regName = ""; drawRegisterName()
      end
    elseif regStep == 3 then
      if e == "monitor_touch" then
        checkClick(ev[3], ev[4])
        if data.registered then break end
      elseif e == "key" and ev[2] == keys.backspace then
        regStep = 2; data.billingModel = nil; drawRegisterPlan(regName)
      end
    end
  end
end

-- ── Billing logic ────────────────────────────────────────────
local ticksSincePeriod = 0
local PERIOD_TICKS     = 1200

local function doPaygBilling(fe)
  data.balance       = data.balance - (fe * data.ratePerFE)
  data.totalConsumed = data.totalConsumed + fe
  if data.balance <= 0 then
    data.balance = 0
    if data.powerOn then setPower(false) end
  end
  saveData()
end

local function doPeriodicBilling(fe)
  data.periodUsage   = data.periodUsage + fe
  data.totalConsumed = data.totalConsumed + fe
  ticksSincePeriod   = ticksSincePeriod + 1
  if ticksSincePeriod >= PERIOD_TICKS then
    data.balance     = data.balance - (data.periodUsage * data.ratePerFE)
    data.periodUsage = 0
    ticksSincePeriod = 0
    if data.balance <= 0 then
      data.balance = 0
      if data.powerOn then setPower(false) end
    end
  end
  saveData()
end

local function doProducerBilling(fe)
  data.balance       = data.balance + (fe * data.ratePerFE * 0.75)
  data.totalExported = (data.totalExported or 0) + fe
  saveData()
end

-- ── Main loop ────────────────────────────────────────────────
local function mainLoop()
  local lastBroadcast   = 0
  local lastUpdateCheck = os.clock()

  while true do
    local importRate = importDetector and importDetector.getTransferRate and importDetector.getTransferRate() or 0
    local exportRate = exportDetector and exportDetector.getTransferRate and exportDetector.getTransferRate() or 0

    if data.powerOn then
      if data.isProducer then
        if exportRate > 0 then doProducerBilling(exportRate) end
      else
        if importRate > 0 then
          if data.billingModel == "payg" then doPaygBilling(importRate)
          else doPeriodicBilling(importRate) end
        end
      end
    end

    local now = os.clock()

    if now - lastUpdateCheck >= UPDATE_EVERY then
      lastUpdateCheck = now
      backgroundUpdateCheck()
    end

    if now - lastBroadcast >= BROADCAST_EVERY then
      broadcastStatus(importRate, exportRate)
      lastBroadcast = now
    end

    if typeChangeActive then drawTypeChangeScreen()
    elseif planChangeActive then drawPlanChangeScreen()
    else drawMeterScreen(importRate, exportRate) end

    local timer = os.startTimer(POLL_INTERVAL)
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "monitor_touch" then
        checkClick(ev[3], ev[4]); break
      elseif ev[1] == "modem_message" then
        handleCommand(ev[5]); break
      elseif ev[1] == "timer" and ev[2] == timer then
        break
      end
    end
  end
end

-- ── Boot ─────────────────────────────────────────────────────
loadData()

if not data.playerName then
  data.playerName = "Meter-" .. os.getComputerID()
  saveData()
end

monitor.setBackgroundColor(colors.black)
monitor.clear()

-- Apply correct detector limits on boot based on saved state
if importDetector then
  importDetector.setTransferRateLimit(
    data.isProducer and 0 or (data.powerOn and MAX_FLOW or 0))
end
if exportDetector then
  exportDetector.setTransferRateLimit(
    data.isProducer and (data.powerOn and MAX_FLOW or 0) or 0)
end

if not data.registered then runRegistration() end
mainLoop()
