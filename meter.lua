-- ============================================================
--  BeyondSMP Electric Meter v3.13
--  Peripherals:
--    Import Detector = LEFT side  (grid → player, consumers)
--    Export Detector = RIGHT side (player → grid, producers)
--    Energy Cube(s)  = any side / wired network (Balanced mode buffer,
--                      auto-detected by name e.g. basicEnergyCube_1)
--    Monitor         = any side
--    Ender Modem     = any side
--  Networking:
--    STATUS_CH  : meter broadcasts status every 5s
--    COMMAND_CH : meter listens for admin commands
-- ============================================================

-- ── Version & update ─────────────────────────────────────────
local VERSION      = "3.13"
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
local BROADCAST_EVERY  = 5
local PERIOD_TICKS     = 1200
local ticksSincePeriod = 0

-- Balanced (Auto P2P) mode — buffer thresholds, hardcoded for now
-- (hysteresis: once selling/buying starts it continues until the buffer
--  returns to the idle release point, so the meter doesn't flicker state
--  right at the 80%/25% trigger lines)
local BUFFER_SELL_PCT = 80   -- charge %  — start selling surplus to the grid
local BUFFER_BUY_PCT  = 25   -- charge %  — start buying to top up the buffer
local BUFFER_IDLE_PCT = 60   -- charge %  — release point; trade stops here

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

-- Mekanism Energy Cube(s) — buffer for Balanced (Auto P2P) mode.
-- Auto-detected anywhere on the network by name, e.g. "basicEnergyCube_1",
-- "advancedEnergyCube_2", "ultimateEnergyCube_1" ...
local cubes = {}
for _, name in ipairs(peripheral.getNames()) do
  if name:match("[Ee]nergy[Cc]ube_%d+") then
    local ok, p = pcall(peripheral.wrap, name)
    if ok and p then table.insert(cubes, p) end
  end
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
print("Energy Cube(s)  : " .. (#cubes > 0 and (#cubes .. " found") or "not found (Balanced mode unavailable)"))
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
  totalRevenue  = 0,   -- cumulative LC charged to this meter as a consumer/buyer (company income)
  totalPayout   = 0,   -- cumulative LC paid out by this meter as a producer/seller (company expense)
  periodUsage   = 0,
  powerOn       = false,
  registered    = false,
  isProducer    = false,
  ratePerFE     = RATE_PER_FE,
  cap           = MAX_FLOW,   -- admin-set import cap (consumer mode / balanced buying)
  exportCap     = MAX_FLOW,   -- self-set export cap (producer mode / balanced selling)

  -- Balanced (Auto P2P) mode — selected at initial setup, sticky for the meter's life
  balanced       = false,
  pState         = "idle",    -- buying | selling | idle | suspended
  bufferPct      = 0,
  bufferEnergy   = 0,
  bufferCapacity = 0,
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
      data.totalRevenue     = data.totalRevenue    or 0
      data.totalPayout      = data.totalPayout     or 0
      data.isProducer       = data.isProducer     or false
      data.cap              = data.cap            or MAX_FLOW
      data.exportCap        = data.exportCap      or MAX_FLOW
      data.balanced         = data.balanced       or false
      data.pState           = data.pState         or "idle"
      data.bufferPct        = data.bufferPct      or 0
      data.bufferEnergy     = data.bufferEnergy   or 0
      data.bufferCapacity   = data.bufferCapacity or 0
    end
  end
end

-- ── Power control ────────────────────────────────────────────
local function setPower(state)
  data.powerOn = state
  if data.isProducer then
    if exportDetector then exportDetector.setTransferRateLimit(state and (data.exportCap or MAX_FLOW) or 0) end
    if importDetector then importDetector.setTransferRateLimit(0) end  -- always blocked
  else
    if importDetector then importDetector.setTransferRateLimit(state and (data.cap or MAX_FLOW) or 0) end
    if exportDetector then exportDetector.setTransferRateLimit(0) end  -- always blocked
  end
  saveData()
end

-- ── Balanced (Auto P2P) mode ─────────────────────────────────
-- Reads aggregate charge across all detected energy cubes (handles a single
-- cube or a networked bank — sums whatever each one reports). Defensive about
-- exact method names since Mekanism's CC integration can vary by version.
local function readCubeEnergy(p)
  local ok1, e = pcall(function()
    return (p.getEnergy and p.getEnergy())
        or (p.getEnergyStored and p.getEnergyStored())
  end)
  local ok2, c = pcall(function()
    return (p.getMaxEnergy and p.getMaxEnergy())
        or (p.getEnergyCapacity and p.getEnergyCapacity())
        or (p.getMaxEnergyStored and p.getMaxEnergyStored())
  end)
  return (ok1 and e) or 0, (ok2 and c) or 0
end

local function sampleBuffer()
  local energy, capacity = 0, 0
  for _, cube in ipairs(cubes) do
    local e, c = readCubeEnergy(cube)
    energy   = energy   + (e or 0)
    capacity = capacity + (c or 0)
  end
  data.bufferEnergy   = energy
  data.bufferCapacity = capacity
  data.bufferPct      = capacity > 0 and (energy / capacity * 100) or 0
end

-- Hysteresis: once selling/buying starts, it continues until the buffer
-- returns to the idle release point (BUFFER_IDLE_PCT) — prevents flapping
-- right at the 80%/25% trigger lines.
local function nextBalancedState(pState, pct)
  if pState == "selling" and pct > BUFFER_IDLE_PCT then return "selling" end
  if pState == "buying"  and pct < BUFFER_IDLE_PCT then return "buying"  end
  if pct >= BUFFER_SELL_PCT then return "selling"
  elseif pct <= BUFFER_BUY_PCT then return "buying"
  else return "idle" end
end

-- Drives the detectors directly from the live trade state — unlike
-- setPower(), "idle"/"suspended" block BOTH directions at once, which the
-- binary isProducer model can't express.
local function applyBalancedDetectors()
  local impLimit, expLimit = 0, 0
  if data.pState == "buying"  then impLimit = data.cap       or MAX_FLOW end
  if data.pState == "selling" then expLimit = data.exportCap or MAX_FLOW end
  if importDetector then importDetector.setTransferRateLimit(impLimit) end
  if exportDetector then exportDetector.setTransferRateLimit(expLimit) end
end

-- Cut/restore for balanced meters — bypasses setPower()'s binary
-- producer/consumer detector logic so it doesn't force a trade direction.
local function setBalancedPower(state)
  data.powerOn = state
  if not state then
    data.pState     = "suspended"
    data.isProducer = false
    applyBalancedDetectors()
  end
  saveData()
end

-- Re-evaluates the live trade state from the current buffer charge. Called
-- once per poll tick before billing so isProducer/detector limits are current
-- when rates are sampled and bills applied.
local function updateBalancedState()
  if not data.balanced then return end
  sampleBuffer()

  if not data.powerOn then
    if data.pState ~= "suspended" then
      data.pState     = "suspended"
      data.isProducer = false
      applyBalancedDetectors()
      saveData()
    end
    return
  end

  -- No buffer detected — nothing to balance against, hold idle rather than
  -- reading 0% and perpetually thinking it needs to buy
  if #cubes == 0 or data.bufferCapacity <= 0 then
    if data.pState ~= "idle" then
      data.pState     = "idle"
      data.isProducer = false
      applyBalancedDetectors()
      saveData()
    end
    return
  end

  local newState = nextBalancedState(data.pState or "idle", data.bufferPct)
  if newState ~= data.pState then
    data.pState     = newState
    data.isProducer = (newState == "selling")
    applyBalancedDetectors()
    saveData()
  end
end

-- ── Networking ───────────────────────────────────────────────
local function broadcastStatus(importRate, exportRate)
  local billSecsLeft = nil
  local periodCost   = nil
  if not data.isProducer and data.billingModel == "periodic" then
    billSecsLeft = math.floor((PERIOD_TICKS - ticksSincePeriod) * POLL_INTERVAL)
    periodCost   = data.periodUsage * data.ratePerFE
  end
  modem.transmit(STATUS_CH, COMMAND_CH, {
    type          = "status",
    id            = os.getComputerID(),
    player        = data.playerName,
    plan          = data.billingModel,
    balance       = data.balance,
    draw          = importRate,
    export        = exportRate,
    isProducer    = data.isProducer,
    cap           = data.isProducer and (data.exportCap or MAX_FLOW) or (data.cap or MAX_FLOW),
    powerOn       = data.powerOn,
    total         = data.totalConsumed,
    totalExported = data.totalExported,
    totalRevenue  = data.totalRevenue,
    totalPayout   = data.totalPayout,
    ratePerFE     = data.ratePerFE,
    billSecsLeft  = billSecsLeft,
    periodCost    = periodCost,
    balanced      = data.balanced,
    pState        = data.balanced and data.pState or nil,
    bufferPct     = data.balanced and data.bufferPct or nil,
  })
end

local function handleCommand(msg)
  if type(msg) ~= "table" then return end
  if msg.id ~= os.getComputerID() and msg.id ~= "all" then return end

  if msg.cmd == "cut" then
    if data.balanced then setBalancedPower(false) else setPower(false) end

  elseif msg.cmd == "restore" then
    if data.balanced then
      if data.balance > 0 then setBalancedPower(true) end
    elseif data.isProducer or data.balance > 0 then
      setPower(true)
    end

  elseif msg.cmd == "update" then
    term.setTextColor(colors.orange)
    print("Remote update command received.")
    doUpdate()

  elseif msg.cmd == "setplan" and type(msg.value) == "string" then
    if data.balanced then return end  -- balanced meters are always PAYG
    if not data.isProducer and data.billingModel == "periodic" and data.periodUsage > 0 then
      local charge = data.periodUsage * data.ratePerFE
      data.balance     = data.balance - charge
      data.periodUsage = 0
      ticksSincePeriod = 0
      if data.balance <= 0 and data.powerOn then setPower(false) end
    end
    data.billingModel = msg.value
    saveData()

  elseif msg.cmd == "setname" and type(msg.value) == "string" then
    data.playerName = msg.value
    saveData()

  elseif msg.cmd == "setcap" and type(msg.value) == "number" then
    data.cap = msg.value
    if data.balanced then
      if importDetector and data.pState == "buying" then
        importDetector.setTransferRateLimit(data.cap)
      end
    elseif importDetector and not data.isProducer and data.powerOn then
      importDetector.setTransferRateLimit(data.cap)
    end
    saveData()

  elseif msg.cmd == "setbalance" and type(msg.value) == "number" then
    data.balance = msg.value
    if data.balanced then
      if data.balance <= 0 and data.pState == "buying" then
        setBalancedPower(false)
      elseif data.balance > 0 and not data.powerOn then
        setBalancedPower(true)
      end
    elseif not data.isProducer then
      setPower(data.balance > 0)
    end
    saveData()

  elseif msg.cmd == "setrate" and type(msg.value) == "number" then
    data.ratePerFE = msg.value
    RATE_PER_FE    = msg.value
    saveData()

  elseif msg.cmd == "settype" and type(msg.value) == "string" then
    if data.balanced then return end  -- balanced type is fixed at registration
    local becomingProducer = (msg.value == "producer")
    if becomingProducer and not data.isProducer
        and data.billingModel == "periodic" and data.periodUsage > 0 then
      local charge = data.periodUsage * data.ratePerFE
      data.balance     = data.balance - charge
      data.periodUsage = 0
      ticksSincePeriod = 0
      if data.balance <= 0 and data.powerOn then setPower(false) end
    end
    data.isProducer = becomingProducer
    if becomingProducer then
      setPower(true)
    else
      setPower(data.powerOn and data.balance > 0)
    end
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
  if n >= 1e9 then return string.format("%.2fG", n/1e9)
  elseif n >= 1e6 then return string.format("%.2fM", n/1e6)
  elseif n >= 1e3 then return string.format("%.2fk", n/1e3)
  else return string.format("%d", n) end
end

local function formatCurrency(n)
  return string.format("%.4f", n)
end

-- ── Button system ────────────────────────────────────────────
local buttons = {}
local immediateRedraw = false  -- set by actions that must refresh before the next tick
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
  local cw = math.floor((W - 6) / 3)
  local c1 = 2
  local c2 = c1 + cw + 2
  local c3 = c2 + cw + 2
  writeAt(c1, 10, "CONSUMER",          colors.cyan)
  writeAt(c1, 11, "Draws power from",  colors.lightGray)
  writeAt(c1, 12, "the grid. Needs",   colors.lightGray)
  writeAt(c1, 13, "LEFT detector.",    colors.lightGray)
  writeAt(c2, 10, "PRODUCER",          colors.lime)
  writeAt(c2, 11, "Sells surplus to",  colors.lightGray)
  writeAt(c2, 12, "the grid. Needs",   colors.lightGray)
  writeAt(c2, 13, "RIGHT detector.",   colors.lightGray)
  writeAt(c3, 10, "BALANCED",          colors.yellow)
  writeAt(c3, 11, "Auto buy/sell vs.", colors.lightGray)
  writeAt(c3, 12, "an energy cube",    colors.lightGray)
  writeAt(c3, 13, "buffer. Needs both",colors.lightGray)
  writeAt(c3, 14, "detectors + cube.", colors.lightGray)
  hline(16)
  addButton(c1, 17, c1+cw-1, 17, "CONSUMER", colors.black, colors.cyan, function()
    data.isProducer = false
    data.playerName = name
    data.registered = true
    setPower(true)
    saveData()
  end)
  addButton(c2, 17, c2+cw-1, 17, "PRODUCER", colors.black, colors.lime, function()
    data.isProducer = true
    data.playerName = name
    data.registered = true
    setPower(true)
    saveData()
  end)
  addButton(c3, 17, c3+cw-1, 17, "BALANCED", colors.black, colors.yellow, function()
    data.balanced     = true
    data.isProducer   = false
    data.pState       = "idle"
    data.billingModel = "payg"   -- dynamic buy/sell doesn't fit periodic billing
    data.playerName   = name
    data.registered   = true
    data.powerOn      = true
    sampleBuffer()
    applyBalancedDetectors()
    saveData()
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Plan / type change screens ────────────────────────────────
local planChangeActive = false
local typeChangeActive = false
local capChangeActive  = false

local CAP_PRESETS = {
  { label = "Unlimited",   value = MAX_FLOW },
  { label = "1,000 FE/t",  value = 1000 },
  { label = "5,000 FE/t",  value = 5000 },
  { label = "10,000 FE/t", value = 10000 },
  { label = "50,000 FE/t", value = 50000 },
}

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
    centreText(11, "charged now: " .. formatCurrency(charge) .. " LC", colors.orange)
    centreText(12, "New balance: " .. formatCurrency(data.balance - charge) .. " LC", colors.white)
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
      if data.balance <= 0 and data.powerOn then setPower(false) end
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
    centreText(12, "Switch takes effect immediately.", colors.lightGray)
  else
    centreText(10, "Switching will block grid import", colors.orange)
    centreText(11, "and enable export (RIGHT side).",  colors.orange)
    if data.billingModel == "periodic" and data.periodUsage > 0 then
      local charge = data.periodUsage * data.ratePerFE
      centreText(12, "Outstanding period usage will be", colors.orange)
      centreText(13, "charged now: " .. formatCurrency(charge) .. " LC", colors.orange)
      centreText(14, "New balance: " .. formatCurrency(data.balance - charge) .. " LC", colors.white)
    else
      centreText(12, "Switch takes effect immediately.", colors.lightGray)
    end
  end
  hline(16)
  local btnW = math.floor(W/2) - 3
  local mid  = math.floor(W/2)
  addButton(2,     17, 2+btnW,     17, "CONFIRM", colors.black, colors.lime, function()
    if not data.isProducer and data.billingModel == "periodic" and data.periodUsage > 0 then
      local charge = data.periodUsage * data.ratePerFE
      data.balance     = data.balance - charge
      data.periodUsage = 0
      ticksSincePeriod = 0
      if data.balance <= 0 and data.powerOn then setPower(false) end
    end
    data.isProducer = not data.isProducer
    if data.isProducer then
      setPower(true)
    else
      setPower(data.powerOn and data.balance > 0)
    end
    saveData(); typeChangeActive = false
  end)
  addButton(mid+1, 17, mid+1+btnW, 17, "CANCEL", colors.white, colors.red, function()
    typeChangeActive = false
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

local function drawCapChangeScreen()
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY",       colors.yellow)
  centreText(3, "Set Export Rate Cap", colors.lightGray)
  hline(4)
  local cur      = data.exportCap or MAX_FLOW
  local curLabel = cur >= MAX_FLOW and "Unlimited" or formatFE(cur) .. " FE/t"
  centreText(6, "Current cap: " .. curLabel, colors.white)
  centreText(7, "Choose a new export rate cap:", colors.lightGray)
  hline(8)
  local y = 9
  for _, preset in ipairs(CAP_PRESETS) do
    local selected = preset.value == cur
    local label    = preset.label .. (selected and "  (current)" or "")
    local fg       = selected and colors.gray or colors.black
    local bg       = selected and colors.lightGray or colors.cyan
    addButton(2, y, W-1, y, label, fg, bg, function()
      if not selected then
        data.exportCap = preset.value
        if data.powerOn and exportDetector then
          exportDetector.setTransferRateLimit(data.exportCap)
        end
        saveData()
      end
      capChangeActive = false
    end)
    centreText(y, label, fg, bg)
    y = y + 1
  end
  hline(y)
  addButton(2, y+1, W-1, y+1, "CANCEL", colors.white, colors.red, function()
    capChangeActive = false
  end)
  centreText(y+1, "CANCEL", colors.white, colors.red)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Main meter screen ────────────────────────────────────────
local function drawMeterScreen(importRate, exportRate)
  importRate = importRate or 0
  exportRate = exportRate or 0
  cls(); clearButtons(); refreshSize()

  -- Two-row header
  writeAt(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  centreText(1, " BEYOND ENERGY METER ", colors.black, colors.yellow)
  writeAt(1, 2, string.rep(" ", W), colors.white, colors.gray)
  centreText(2, data.playerName or "Unknown", colors.white, colors.gray)

  hline(3, "\140")  -- \140 = ─ in CC's font

  -- Right-aligned info rows
  local function infoRow(y, label, value, valColor)
    writeAt(2, y, label, colors.lightGray)
    local valStr = tostring(value)
    writeAt(W - #valStr, y, valStr, valColor or colors.white)
  end

  if data.balanced then
    if data.pState == "selling" then
      infoRow(4, "Exporting", formatFE(exportRate) .. " FE/t", colors.lime)
      infoRow(5, "Earning",   string.format("%.4f LC/t", exportRate * data.ratePerFE * 0.75), colors.lime)
    elseif data.pState == "buying" then
      infoRow(4, "Drawing",  formatFE(importRate) .. " FE/t", colors.cyan)
      infoRow(5, "Spending", string.format("%.4f LC/t", importRate * data.ratePerFE), colors.cyan)
    else
      infoRow(4, "Flow", "None (idle)", colors.gray)
      infoRow(5, "Buffer trend", data.bufferPct >= BUFFER_IDLE_PCT and "Holding (high)" or "Holding (low)", colors.gray)
    end
  elseif data.isProducer then
    infoRow(4, "Exporting", formatFE(exportRate) .. " FE/t", colors.lime)
    infoRow(5, "Earning",   string.format("%.4f LC/t", exportRate * data.ratePerFE * 0.75), colors.lime)
  else
    infoRow(4, "Draw",     formatFE(importRate) .. " FE/t", colors.white)
    local cap = data.cap or MAX_FLOW
    infoRow(5, "Rate cap", cap >= MAX_FLOW and "Unlimited" or formatFE(cap) .. " FE/t", colors.gray)
  end

  hline(6, "\140")

  -- Balance row — full-row colour based on status
  local balCol = data.balance > WARN_BALANCE and colors.lime
              or (data.balance > 0 and colors.yellow or colors.red)
  writeAt(1, 7, string.rep(" ", W), balCol, colors.black)
  writeAt(2, 7, "Balance", balCol)
  local balStr = formatCurrency(data.balance) .. " LC"
  writeAt(W - #balStr, 7, balStr, balCol)

  infoRow(8, "Plan", data.billingModel == "payg" and "Pay As You Go" or "Periodic", colors.cyan)
  if not data.balanced then
    infoRow(9, "Type", data.isProducer and "Producer" or "Consumer",
            data.isProducer and colors.lime or colors.cyan)
  end

  local nextRow = 12
  if data.balanced then
    local stateLabel, stateColor = "Idle", colors.gray
    if     data.pState == "buying"    then stateLabel, stateColor = "Buying",    colors.cyan
    elseif data.pState == "selling"   then stateLabel, stateColor = "Selling",   colors.lime
    elseif data.pState == "suspended" then stateLabel, stateColor = "Suspended", colors.red
    end
    infoRow(9, "Status", "Balanced - " .. stateLabel, stateColor)
    infoRow(10, "Buffer", string.format("%.0f%% (%s / %s)", data.bufferPct or 0,
            formatFE(data.bufferEnergy or 0), formatFE(data.bufferCapacity or 0)), colors.yellow)
    infoRow(11, "Total traded", formatFE((data.totalConsumed or 0) + (data.totalExported or 0)) .. " FE", colors.white)
  elseif data.isProducer then
    infoRow(10, "Total exported", formatFE(data.totalExported) .. " FE", colors.lime)
    local ecap = data.exportCap or MAX_FLOW
    infoRow(11, "Export cap", ecap >= MAX_FLOW and "Unlimited" or formatFE(ecap) .. " FE/t", colors.gray)
  elseif data.billingModel == "periodic" then
    infoRow(10, "Period cost", formatCurrency(data.periodUsage * data.ratePerFE) .. " LC", colors.orange)
    local secsLeft = math.max(0, math.floor((PERIOD_TICKS - ticksSincePeriod) * POLL_INTERVAL))
    local mins = math.floor(secsLeft / 60)
    local secs = secsLeft % 60
    infoRow(11, "Next bill", string.format("%dm %02ds", mins, secs), colors.cyan)
  else
    -- PAYG consumer
    infoRow(10, "Total consumed", formatFE(data.totalConsumed) .. " FE", colors.white)
    local costPerSec = importRate * data.ratePerFE
    if data.balance > 0 and costPerSec > 0 then
      local secs = math.floor(data.balance / costPerSec)
      local h = math.floor(secs / 3600)
      local m = math.floor((secs % 3600) / 60)
      local s = secs % 60
      local timeStr = h > 0 and string.format("%dh %02dm", h, m)
                   or m > 0 and string.format("%dm %02ds", m, s)
                   or string.format("%ds", s)
      local col = secs < 300 and colors.red or (secs < 1800 and colors.yellow or colors.lime)
      infoRow(11, "Est. time left", timeStr, col)
    elseif data.balance > 0 then
      infoRow(11, "Est. time left", "No draw", colors.gray)
    end
  end

  hline(nextRow, "\140")

  local statusRow = nextRow + 1
  local warnRow   = nextRow + 2
  local updRow    = nextRow + 3

  -- Full-width power status bar
  if data.balanced then
    if data.pState == "selling" then
      writeAt(1, statusRow, string.rep(" ", W), colors.black, colors.lime)
      centreText(statusRow, " \4 SELLING TO GRID ", colors.black, colors.lime)
    elseif data.pState == "buying" then
      writeAt(1, statusRow, string.rep(" ", W), colors.black, colors.cyan)
      centreText(statusRow, " \4 BUYING FROM GRID ", colors.black, colors.cyan)
    elseif data.pState == "idle" then
      writeAt(1, statusRow, string.rep(" ", W), colors.white, colors.gray)
      centreText(statusRow, " \4 IDLE - BUFFER BALANCED ", colors.white, colors.gray)
    else -- suspended
      writeAt(1, statusRow, string.rep(" ", W), colors.white, colors.red)
      centreText(statusRow, " \4 SUSPENDED - TOP UP TO RESUME ", colors.white, colors.red)
    end
    if data.balance < 0 then
      writeAt(1, warnRow, string.rep(" ", W), colors.black, colors.red)
      centreText(warnRow, " Outstanding debt \4 top up to restore ", colors.black, colors.red)
    elseif data.balance <= WARN_BALANCE then
      writeAt(1, warnRow, string.rep(" ", W), colors.black, colors.orange)
      centreText(warnRow, " Low balance \4 please top up soon ", colors.black, colors.orange)
    end
  elseif data.isProducer then
    if data.powerOn then
      writeAt(1, statusRow, string.rep(" ", W), colors.black, colors.lime)
      centreText(statusRow, " \4 EXPORTING TO GRID ", colors.black, colors.lime)
    else
      writeAt(1, statusRow, string.rep(" ", W), colors.white, colors.red)
      centreText(statusRow, " \4 EXPORT DISABLED ", colors.white, colors.red)
    end
  else
    if data.powerOn then
      writeAt(1, statusRow, string.rep(" ", W), colors.black, colors.lime)
      centreText(statusRow, " \4 POWER ON ", colors.black, colors.lime)
    elseif data.balance < 0 then
      writeAt(1, statusRow, string.rep(" ", W), colors.white, colors.red)
      centreText(statusRow, " \4 POWER OFF - DEBT MUST BE CLEARED ", colors.white, colors.red)
    else
      writeAt(1, statusRow, string.rep(" ", W), colors.white, colors.red)
      centreText(statusRow, " \4 POWER OFF - TOP UP TO RECONNECT ", colors.white, colors.red)
    end
    if data.balance < 0 then
      writeAt(1, warnRow, string.rep(" ", W), colors.black, colors.red)
      centreText(warnRow, " Outstanding debt \4 top up to restore ", colors.black, colors.red)
    elseif data.balance <= WARN_BALANCE and data.balance > 0 then
      writeAt(1, warnRow, string.rep(" ", W), colors.black, colors.orange)
      centreText(warnRow, " Low balance \4 please top up soon ", colors.black, colors.orange)
    end
  end

  if updateAvailable then
    local label = " UPDATE AVAILABLE - TAP TO INSTALL "
    local bx    = math.floor((W - #label) / 2) + 1
    addButton(bx, updRow, bx + #label - 1, updRow, label, colors.black, colors.yellow, doUpdate)
    centreText(updRow, label, colors.black, colors.yellow)
  end

  -- PAY NOW button for periodic consumers with outstanding usage
  if not data.isProducer and data.billingModel == "periodic" and data.periodUsage > 0 then
    hline(H-4, "\140")
    local charge = data.periodUsage * data.ratePerFE
    local label  = " PAY NOW (" .. formatCurrency(charge) .. " LC) "
    addButton(2, H-3, W-1, H-3, label, colors.black, colors.lime, function()
      data.balance     = data.balance - charge
      data.periodUsage = 0
      ticksSincePeriod = 0
      if data.balance <= 0 and data.powerOn then setPower(false) end
      saveData()
      immediateRedraw = true
    end)
    centreText(H-3, label, colors.black, colors.lime)
  elseif data.isProducer or data.balanced then
    -- Self-managed export rate cap, to avoid overloading own generation/sell setup
    hline(H-4, "\140")
    local label = " SET EXPORT CAP "
    addButton(2, H-3, W-1, H-3, label, colors.black, colors.cyan, function()
      capChangeActive = true
    end)
    centreText(H-3, label, colors.black, colors.cyan)
  else
    hline(H-3, "\140")
  end

  if data.balanced then
    -- Balanced meters skip CHANGE PLAN (always PAYG) and CHANGE TYPE
    -- (the balanced type is fixed at registration) — just TEMP + CUT/RESTORE
    local mid   = math.floor(W / 2)
    local btnW2 = math.floor(W / 2) - 3
    addButton(2, H-2, 2+btnW2, H-2, "[TEMP] +"..TEMP_TOP_UP.." LC",
      colors.black, colors.purple, function()
        data.balance = data.balance + TEMP_TOP_UP
        if not data.powerOn and data.balance > 0 then setBalancedPower(true) end
        saveData()
      end)
    addButton(mid+1, H-2, mid+1+btnW2, H-2,
      data.powerOn and "CUT POWER" or "RESTORE",
      colors.white, data.powerOn and colors.red or colors.green, function()
        if data.powerOn then
          setBalancedPower(false)
        elseif data.balance > 0 then
          setBalancedPower(true)
        end
      end)
  else
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
  end

  hline(H-1, "\140")
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

local function doPaygBilling(fe)
  local charge       = fe * data.ratePerFE
  data.balance       = data.balance - charge
  data.totalConsumed = data.totalConsumed + fe
  data.totalRevenue  = (data.totalRevenue or 0) + charge
  if data.balance <= 0 and data.powerOn then setPower(false) end
  saveData()
end

local function doPeriodicBilling(fe)
  data.periodUsage   = data.periodUsage + fe
  data.totalConsumed = data.totalConsumed + fe
  ticksSincePeriod   = ticksSincePeriod + 1
  if ticksSincePeriod >= PERIOD_TICKS then
    local charge      = data.periodUsage * data.ratePerFE
    data.balance      = data.balance - charge
    data.totalRevenue = (data.totalRevenue or 0) + charge
    data.periodUsage  = 0
    ticksSincePeriod  = 0
    if data.balance <= 0 and data.powerOn then setPower(false) end
  end
  saveData()
end

local function doProducerBilling(fe)
  local payout       = fe * data.ratePerFE * 0.75
  data.balance       = data.balance + payout
  data.totalExported = (data.totalExported or 0) + fe
  data.totalPayout   = (data.totalPayout or 0) + payout
  saveData()
end

-- ── Main loop ────────────────────────────────────────────────
local function mainLoop()
  local lastBroadcast   = 0
  local lastUpdateCheck = os.clock()
  local importRate      = 0
  local exportRate      = 0

  local timer = os.startTimer(POLL_INTERVAL)

  while true do
    local ev = { os.pullEvent() }
    local e  = ev[1]

    immediateRedraw = false

    if e == "monitor_touch" then
      local wasType = typeChangeActive
      local wasPlan = planChangeActive
      local wasCap  = capChangeActive
      checkClick(ev[3], ev[4])
      if immediateRedraw or typeChangeActive ~= wasType or planChangeActive ~= wasPlan or capChangeActive ~= wasCap then
        if typeChangeActive then drawTypeChangeScreen()
        elseif planChangeActive then drawPlanChangeScreen()
        elseif capChangeActive then drawCapChangeScreen()
        else drawMeterScreen(importRate, exportRate) end
        immediateRedraw = false
      end

    elseif e == "modem_message" then
      handleCommand(ev[5])
      if immediateRedraw then
        if typeChangeActive then drawTypeChangeScreen()
        elseif planChangeActive then drawPlanChangeScreen()
        elseif capChangeActive then drawCapChangeScreen()
        else drawMeterScreen(importRate, exportRate) end
        immediateRedraw = false
      end

    elseif e == "timer" and ev[2] == timer then
      -- Billing, rate sampling, and redraw only on the poll timer
      updateBalancedState()  -- re-evaluate buy/sell/idle/suspended before sampling rates
      importRate = importDetector and importDetector.getTransferRate and importDetector.getTransferRate() or 0
      exportRate = exportDetector and exportDetector.getTransferRate and exportDetector.getTransferRate() or 0

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

      timer = os.startTimer(POLL_INTERVAL)
      if typeChangeActive then drawTypeChangeScreen()
      elseif planChangeActive then drawPlanChangeScreen()
      elseif capChangeActive then drawCapChangeScreen()
      else drawMeterScreen(importRate, exportRate) end
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
if data.balanced then
  sampleBuffer()
  applyBalancedDetectors()
else
  if importDetector then
    importDetector.setTransferRateLimit(
      data.isProducer and 0 or (data.powerOn and (data.cap or MAX_FLOW) or 0))
  end
  if exportDetector then
    exportDetector.setTransferRateLimit(
      data.isProducer and (data.powerOn and (data.exportCap or MAX_FLOW) or 0) or 0)
  end
end

if not data.registered then runRegistration() end
mainLoop()
