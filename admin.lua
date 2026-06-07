-- ============================================================
--  BeyondSMP Admin Panel v3.9
--  Peripherals (fully auto-detected):
--    Energy Detector = any side (generation monitor)
--    Monitor         = any size, auto-scales
--    Ender Modem     = any side
--    Chat Box        = any side (optional, AP - enables player whispers)
-- ============================================================

-- ── Version & update ─────────────────────────────────────────
local VERSION      = "3.9"
local RAW_URL = "https://raw.githubusercontent.com/djbigmac9/CC-Power-Meter/main/admin.lua"
local UPDATE_EVERY = 300

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

local STATUS_CH     = 1001
local COMMAND_CH    = 1002
local METER_TIMEOUT = 30
local DEFAULT_RATE  = 0.0001

-- ── Peripherals ──────────────────────────────────────────────
local detector, detectorSide
local monitor  = peripheral.find("monitor")
local modem    = peripheral.find("modem")
local chatBox  = peripheral.find("chat_box")

for _, side in ipairs({"top","bottom","left","right","front","back"}) do
  if peripheral.isPresent(side) and peripheral.getType(side) == "energy_detector" then
    detector = peripheral.wrap(side); detectorSide = side
  end
end

local function bootError(msg)
  term.setBackgroundColor(colors.black); term.setTextColor(colors.red)
  term.clear(); term.setCursorPos(1,1)
  print("=== BEYOND ENERGY ADMIN ===\n")
  term.setTextColor(colors.white); print("STARTUP ERROR:\n"..msg.."\n")
  term.setTextColor(colors.lightGray); print("Check connections and reboot.")
  error(msg, 0)
end

if not monitor  then bootError("No monitor found.")  end
if not modem    then bootError("No modem found.")    end
if not detector then bootError("No Energy Detector found.") end

modem.open(STATUS_CH)
monitor.setTextScale(0.5)

-- ── Monitor helpers ──────────────────────────────────────────
local W, H
local function refreshSize() W, H = monitor.getSize() end

local function cls()
  monitor.setBackgroundColor(colors.black)
  monitor.clear(); refreshSize()
end

local function writeAt(x, y, text, fg, bg)
  if not W or not H then return end
  if x > W or y > H or x < 1 or y < 1 then return end
  monitor.setCursorPos(x, y)
  monitor.setTextColor(fg or colors.white)
  monitor.setBackgroundColor(bg or colors.black)
  monitor.write(text)
end

local function centreText(y, text, fg, bg)
  writeAt(math.floor((W - #text) / 2) + 1, y, text, fg, bg)
end

local function hline(y, fg, bg)
  writeAt(1, y, string.rep("-", W), fg or colors.gray, bg or colors.black)
end

local function padRight(s, n)
  s = tostring(s or "")
  if #s >= n then return s:sub(1,n) end
  return s .. string.rep(" ", n - #s)
end

local function formatFE(n)
  n = n or 0
  if n >= 1e9 then return string.format("%.1fG", n/1e9)
  elseif n >= 1e6 then return string.format("%.1fM", n/1e6)
  elseif n >= 1e3 then return string.format("%.1fk", n/1e3)
  else return string.format("%d", math.floor(n)) end
end

local function formatCurrency(n)
  return string.format("%.2f", n or 0)
end

-- ── Button system ────────────────────────────────────────────
local buttons = {}
local function clearButtons() buttons = {} end

local function addButton(x1, y1, x2, y2, label, fg, bg, action)
  table.insert(buttons, {x1=x1,y1=y1,x2=x2,y2=y2,
                         label=label,fg=fg,bg=bg,action=action})
end

local function drawButtons()
  for _, b in ipairs(buttons) do
    local bw  = b.x2 - b.x1 + 1
    local pad = math.max(0, math.floor((bw - #b.label) / 2))
    local str = string.rep(" ", pad) .. b.label
    str = str .. string.rep(" ", math.max(0, bw - #str))
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

-- ── PIN lock ─────────────────────────────────────────────────
local ADMIN_PIN     = "1234"   -- default; overridden by PIN_FILE on boot
local PIN_FILE      = "admin_pin"
local LOCK_TIMEOUT  = 300      -- seconds of inactivity before auto-lock
local pinUnlocked   = false
local pinInput      = ""
local pinError      = false
local lastActivity  = 0

local function loadPin()
  if fs.exists(PIN_FILE) then
    local f = fs.open(PIN_FILE, "r")
    local p = f.readAll(); f.close()
    if p and p:match("^%d+$") then ADMIN_PIN = p end
  end
end

local function savePin(pin)
  local f = fs.open(PIN_FILE, "w")
  f.write(pin); f.close()
  ADMIN_PIN = pin
end

local function touchActivity() lastActivity = os.clock() end

local function checkAutoLock()
  if pinUnlocked and os.clock() - lastActivity > LOCK_TIMEOUT then
    pinUnlocked = false; pinInput = ""; pinError = false
  end
end

-- ── State ────────────────────────────────────────────────────
local meters         = {}
local alerts         = {}
local selectedMeter  = nil
local currentScreen  = "dashboard"
local confirmPending = nil  -- {lines={}, action=fn, returnScreen=str}

-- Numeric keypad input (touch-only, replaces keyboard-driven entry)
local numInput             = ""
local numInputTitle        = ""
local numInputSubtitle     = ""
local numInputAllowDecimal = true
local numInputOnConfirm    = nil
local numInputExtra        = nil   -- optional {label=str, value=num} third button
local numInputReturn       = "dashboard"

local function openNumericInput(title, subtitle, allowDecimal, onConfirm, extra, returnScreen)
  numInput             = ""
  numInputTitle        = title
  numInputSubtitle     = subtitle or ""
  numInputAllowDecimal = allowDecimal
  numInputOnConfirm    = onConfirm
  numInputExtra        = extra
  numInputReturn       = returnScreen or currentScreen
  currentScreen        = "numinput"
end

local function confirm(lines, action, returnScreen)
  if type(lines) == "string" then lines = {lines} end
  confirmPending = {lines=lines, action=action, returnScreen=returnScreen or currentScreen}
  currentScreen  = "confirm"
end

local function sendCommand(id, cmd, value)
  modem.transmit(COMMAND_CH, STATUS_CH, {id=id, cmd=cmd, value=value})
end

local function sendBroadcast(cmd, value)
  modem.transmit(COMMAND_CH, STATUS_CH, {id="all", cmd=cmd, value=value})
end


local function addAlert(msg)
  table.insert(alerts, 1, "[" .. textutils.formatTime(os.time()) .. "] " .. msg)
  if #alerts > 20 then table.remove(alerts) end
end

local updateAvail = false

local function backgroundUpdateCheck()
  local latest = getLatestVersion()
  if latest and isNewer(latest, VERSION) then
    updateAvail = true
    addAlert("Admin update available: v" .. latest .. " - reboot to install")
  end
end

local function drawUpdateBanner()
  if not updateAvail then return end
  local label = " ** UPDATE AVAILABLE - REBOOT TO INSTALL ** "
  local bx    = math.floor((W - #label) / 2) + 1
  addButton(bx, H-1, bx + #label - 1, H-1, label, colors.black, colors.yellow, function()
    doUpdate()
  end)
  centreText(H-1, label, colors.black, colors.yellow)
end

local function whisper(player, msg)
  if chatBox and player then
    pcall(function()
      chatBox.sendMessageToPlayer(msg, player, "Beyond Energy")
    end)
  end
end

-- ── Confirm screen ───────────────────────────────────────────
local function drawConfirmScreen()
  if not confirmPending then currentScreen = "dashboard"; return end
  cls(); clearButtons(); refreshSize()
  writeAt(1, 1, string.rep(" ", W), colors.white, colors.red)
  centreText(1, " CONFIRM ACTION ", colors.white, colors.red)
  hline(2)
  for i, line in ipairs(confirmPending.lines) do
    centreText(3 + i, line, colors.white)
  end
  local mid  = math.floor(H / 2)
  hline(mid - 1)
  local bw  = math.floor(W / 2) - 3
  local bmid = math.floor(W / 2)
  addButton(2,      mid + 1, 2 + bw,      mid + 1, "CONFIRM", colors.black, colors.lime, function()
    confirmPending.action()
    currentScreen  = confirmPending.returnScreen
    confirmPending = nil
  end)
  addButton(bmid+1, mid + 1, bmid+1 + bw, mid + 1, "CANCEL",  colors.white, colors.red,  function()
    currentScreen  = confirmPending.returnScreen
    confirmPending = nil
  end)
  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── PIN screen ───────────────────────────────────────────────
local function drawPinScreen()
  cls(); clearButtons(); refreshSize()

  writeAt(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  centreText(1, " BEYOND ENERGY - ADMIN ACCESS ", colors.black, colors.yellow)
  hline(2)
  centreText(4, "Enter Admin PIN", colors.lightGray)

  -- Show entered digits as dots
  local dots = string.rep("* ", #pinInput)
  centreText(6, dots ~= "" and dots or "- - - -", #pinInput > 0 and colors.white or colors.gray)

  if pinError then
    centreText(7, "Incorrect PIN", colors.red)
  end

  hline(8)

  -- Keypad layout: 1 2 3 / 4 5 6 / 7 8 9 / DEL 0 OK
  local kw   = math.floor((W - 8) / 3)
  local kh   = 2
  local kx1  = 3
  local kx2  = kx1 + kw + 1
  local kx3  = kx2 + kw + 1
  local ky   = 10

  local function numBtn(x, y, label, digit)
    addButton(x, y, x + kw - 1, y, label,
      colors.black, colors.lightGray, function()
        if #pinInput < 8 then
          pinInput = pinInput .. digit
          pinError = false
        end
      end)
    local pad = math.floor((kw - #label) / 2)
    writeAt(x, y, string.rep(" ", kw), colors.black, colors.lightGray)
    writeAt(x + pad, y, label, colors.black, colors.lightGray)
  end

  numBtn(kx1, ky,   "1", "1"); numBtn(kx2, ky,   "2", "2"); numBtn(kx3, ky,   "3", "3")
  numBtn(kx1, ky+2, "4", "4"); numBtn(kx2, ky+2, "5", "5"); numBtn(kx3, ky+2, "6", "6")
  numBtn(kx1, ky+4, "7", "7"); numBtn(kx2, ky+4, "8", "8"); numBtn(kx3, ky+4, "9", "9")

  -- DEL
  addButton(kx1, ky+6, kx1 + kw - 1, ky+6, "DEL", colors.white, colors.red, function()
    if #pinInput > 0 then pinInput = pinInput:sub(1, -2); pinError = false end
  end)
  writeAt(kx1, ky+6, string.rep(" ", kw), colors.white, colors.red)
  writeAt(kx1 + math.floor((kw-3)/2), ky+6, "DEL", colors.white, colors.red)

  -- 0
  numBtn(kx2, ky+6, "0", "0")

  -- OK
  addButton(kx3, ky+6, kx3 + kw - 1, ky+6, "OK", colors.black, colors.lime, function()
    if pinInput == ADMIN_PIN then
      pinUnlocked = true; pinInput = ""; pinError = false
      touchActivity()
    else
      pinError = true; pinInput = ""
    end
  end)
  writeAt(kx3, ky+6, string.rep(" ", kw), colors.black, colors.lime)
  writeAt(kx3 + math.floor((kw-2)/2), ky+6, "OK", colors.black, colors.lime)

  hline(H-1)
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Dashboard ────────────────────────────────────────────────
local function drawDashboard()
  local ok, err = pcall(function()
  cls(); clearButtons()

  -- Header bar
  writeAt(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  centreText(1, " BEYOND ENERGY  -  ADMIN PANEL ", colors.black, colors.yellow)

  -- Generation stats (rows 2-4)
  local gen      = detector.getTransferRate and detector.getTransferRate() or 0
  local totalDraw, online, offline, lowBal = 0, 0, 0, 0
  local now      = os.clock()

  for _, m in pairs(meters) do
    if now - m.lastSeen <= METER_TIMEOUT then
      online    = online + 1
      totalDraw = totalDraw + (m.draw or 0)
      if (m.balance or 0) > 0 and (m.balance or 0) <= 50 then lowBal = lowBal + 1 end
    else
      offline = offline + 1
    end
  end

  local surplus    = gen - totalDraw
  local surplusCol = surplus >= 0 and colors.lime or colors.red
  local half       = math.floor(W / 2)

  writeAt(2, 2, "Gen:     " .. formatFE(gen) .. " FE/t", colors.lime)
  writeAt(2, 3, "Draw:    " .. formatFE(totalDraw) .. " FE/t", colors.white)
  writeAt(2, 4, "Surplus: " .. formatFE(surplus) .. " FE/t", surplusCol)

  writeAt(half+1, 2, "Customers: " .. online .. " online",                 colors.white)
  writeAt(half+1, 3, "Offline:   " .. offline,                             offline > 0 and colors.orange or colors.gray)
  writeAt(half+1, 4, "Low bal:   " .. lowBal,                              lowBal  > 0 and colors.orange or colors.gray)

  -- Company balance — total revenue collected from consumers/buyers minus
  -- total payouts to producers/sellers (i.e. the operator's running profit)
  local companyBalance = 0
  for _, m in pairs(meters) do
    companyBalance = companyBalance + (m.totalRevenue or 0) - (m.totalPayout or 0)
  end
  local companyCol = companyBalance >= 0 and colors.lime or colors.red
  writeAt(2, 5, "Company balance: " .. formatCurrency(companyBalance) .. " LC", companyCol)

  hline(6)

  -- Column layout — percentages of W
  local cN = math.floor(W * 0.17)  -- name
  local cP = math.floor(W * 0.09)  -- plan
  local cB = math.floor(W * 0.11)  -- balance
  local cD = math.floor(W * 0.09)  -- draw
  local cC = math.floor(W * 0.08)  -- cap
  local cS = 7                      -- status

  local x1 = 2
  local x2 = x1 + cN + 1
  local x3 = x2 + cP + 1
  local x4 = x3 + cB + 1
  local x5 = x4 + cD + 1
  local x6 = x5 + cC + 1

  -- Headers match string.format("%-16s %-8s %8s LC %7s/t %7s  %s") at x1
  -- Col positions relative to x1: 0, 17, 26, 38, 47, 56
  writeAt(x1,    7, "CUSTOMER",  colors.yellow)
  writeAt(x1+17, 7, "PLAN",      colors.yellow)
  writeAt(x1+26, 7, "BALANCE",   colors.yellow)
  writeAt(x1+37, 7, "DRAW",      colors.yellow)
  writeAt(x1+47, 7, "CAP",       colors.yellow)
  writeAt(x1+56, 7, "STATUS",    colors.yellow)
  hline(8)

  -- Sort: online first, then alphabetical
  local sorted = {}
  for id, m in pairs(meters) do
    table.insert(sorted, {id=id, m=m})
  end
  table.sort(sorted, function(a, b)
    local aOn = (now - a.m.lastSeen) <= METER_TIMEOUT
    local bOn = (now - b.m.lastSeen) <= METER_TIMEOUT
    if aOn ~= bOn then return aOn end
    return (a.m.player or "") < (b.m.player or "")
  end)

  -- Build row data for rendering AFTER drawButtons
  local rowRenders = {}
  local rowY = 10
  local maxY = H - 4

  for _, entry in ipairs(sorted) do
    if rowY > maxY then break end
    local id  = entry.id
    local m   = entry.m
    local bal = m.balance or 0
    local stTx    = m.powerOn and "ON" or "OFF"
    local typeTag  = m.balanced and "[B]" or (m.isProducer and "[P]" or "[C]")
    local rateDisp = m.isProducer and (m.export or 0) or (m.draw or 0)
    local planDisp
    if m.balanced then
      local labels = { buying = "Buying", selling = "Selling", idle = "Idle", suspended = "Suspended" }
      planDisp = (labels[m.pState] or "Balanced"):sub(1,8)
    else
      planDisp = (m.plan or "?"):sub(1,8)
    end
    local line = string.format("%-13s %-8s %8s LC %7s/t %7s  %s %s",
      (m.player or "?"):sub(1,13),
      planDisp,
      formatCurrency(bal),
      formatFE(rateDisp),
      (m.cap or 0) >= 2147483647 and "Unlim" or formatFE(m.cap or 0),
      stTx, typeTag)
    table.insert(rowRenders, {x=x1, y=rowY, text=line})
    local cid = id
    addButton(1, rowY, W, rowY, "", colors.white, colors.black, function()
      selectedMeter = cid; currentScreen = "customer"
    end)
    rowY = rowY + 1
  end

  -- Determine if any meters are currently on for cut/restore toggle
  local anyOn = false
  for _, m in pairs(meters) do
    if m.powerOn then anyOn = true; break end
  end

  hline(H - 4)
  local bw4 = math.floor((W - 2) / 4)
  addButton(1,          H-3, bw4,      H-3, "DASHBOARD",
    colors.black, colors.yellow,  function() currentScreen="dashboard" end)
  addButton(bw4+1,      H-3, bw4*2,   H-3,
    "ALERTS" .. (#alerts>0 and " ("..#alerts..")" or ""),
    colors.black, #alerts>0 and colors.orange or colors.gray,
    function() currentScreen="alerts" end)
  addButton(bw4*2+1,    H-3, bw4*3,   H-3, "SET RATE",
    colors.black, colors.cyan,    function()
      openNumericInput(
        "Set Global Rate (LC/FE)",
        string.format("Current: %.6f LC/FE", DEFAULT_RATE),
        true,
        function(n)
          DEFAULT_RATE = n
          sendBroadcast("setrate", n)
          addAlert("Rate set to "..string.format("%.6f", n))
          currentScreen = "dashboard"
        end,
        nil, "dashboard")
    end)
  addButton(bw4*3+1,    H-3, W,       H-3, "UPD METERS",
    colors.black, colors.purple,  function()
      confirm({"Push update to ALL meters?", "They will reboot immediately."}, function()
        sendBroadcast("update")
        addAlert("Remote update sent to all meters")
      end, "dashboard")
    end)

  local bw3 = math.floor((W - 2) / 3)
  addButton(1,          H-2, bw3,      H-2, anyOn and "CUT ALL" or "RESTORE ALL",
    colors.white, anyOn and colors.red or colors.green,
    function()
      if anyOn then
        confirm({"Cut power to ALL meters?"}, function()
          sendBroadcast("cut"); addAlert("ADMIN: All meters cut")
          currentScreen = "alerts"
        end, "dashboard")
      else
        sendBroadcast("restore"); addAlert("ADMIN: All meters restored")
        currentScreen = "alerts"
      end
    end)
  addButton(bw3+1,      H-2, bw3*2,   H-2, "CHG PIN",
    colors.black, colors.gray, function()
      term.setTextColor(colors.yellow)
      print("\n-- Change Admin PIN --")
      term.setTextColor(colors.lightGray); term.write("Current PIN: ")
      term.setTextColor(colors.white)
      local cur = io.read()
      if cur ~= ADMIN_PIN then
        term.setTextColor(colors.red); print("Incorrect PIN.")
        term.setTextColor(colors.white); return
      end
      local new1
      while true do
        term.setTextColor(colors.lightGray); term.write("New PIN (4-8 digits): ")
        term.setTextColor(colors.white)
        new1 = io.read()
        if new1:match("^%d+$") and #new1 >= 4 and #new1 <= 8 then break end
        term.setTextColor(colors.red); print("Must be 4-8 digits.")
        term.setTextColor(colors.white)
      end
      while true do
        term.setTextColor(colors.lightGray); term.write("Confirm new PIN: ")
        term.setTextColor(colors.white)
        local new2 = io.read()
        if new2 == new1 then break end
        term.setTextColor(colors.red); print("PINs don't match. Try again.")
        term.setTextColor(colors.white)
      end
      savePin(new1)
      term.setTextColor(colors.lime); print("PIN updated.")
      term.setTextColor(colors.white)
      currentScreen = "dashboard"
    end)
  addButton(bw3*2+1,    H-2, W,        H-2, "LOCK",
    colors.white, colors.gray, function()
      pinUnlocked = false; pinInput = ""; pinError = false
    end)

  hline(H-1)
  drawUpdateBanner()
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION.."  ID:"..os.getComputerID(), colors.gray)
  drawButtons()

  -- Draw row text AFTER buttons so it isn't overwritten
  for _, r in ipairs(rowRenders) do
    monitor.setCursorPos(r.x, r.y)
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(colors.black)
    monitor.write(r.text)
  end
end) -- end pcall
  if not ok then
    monitor.setCursorPos(1, H-5)
    monitor.setTextColor(colors.red)
    monitor.setBackgroundColor(colors.black)
    monitor.write(tostring(err):sub(1, W))
  end
end

-- ── Customer detail ──────────────────────────────────────────
local function drawCustomerScreen()
  if not selectedMeter or not meters[selectedMeter] then
    currentScreen = "dashboard"; return
  end
  local m  = meters[selectedMeter]
  local id = selectedMeter
  local now = os.clock()
  local isOnline = (now - m.lastSeen) <= METER_TIMEOUT

  cls(); clearButtons()
  writeAt(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  centreText(1, " CUSTOMER DETAIL ", colors.black, colors.yellow)

  writeAt(2, 3,  "Player:    " .. (m.player or "Unknown"),                    colors.white)
  writeAt(2, 4,  "Plan:      " .. (m.plan=="payg" and "Pay As You Go" or "Periodic"), colors.cyan)
  writeAt(2, 5,  "Meter ID:  " .. tostring(id),                               colors.gray)
  local typeLabel, typeColor
  if m.balanced then
    typeLabel, typeColor = "Balanced (Auto P2P)", colors.purple
  elseif m.isProducer then
    typeLabel, typeColor = "Producer", colors.yellow
  else
    typeLabel, typeColor = "Consumer", colors.cyan
  end
  writeAt(2, 6,  "Type:      " .. typeLabel, typeColor)
  hline(7)

  local bal = m.balance or 0
  local balFg = bal > 50 and colors.lime or (bal > 0 and colors.yellow or colors.red)

  writeAt(2, 8,  "Balance:        " .. formatCurrency(bal) .. " LC",          balFg)
  if m.balanced then
    local stateLabel, stateColor = "Idle", colors.gray
    if     m.pState == "buying"    then stateLabel, stateColor = "Buying",    colors.cyan
    elseif m.pState == "selling"   then stateLabel, stateColor = "Selling",   colors.lime
    elseif m.pState == "suspended" then stateLabel, stateColor = "Suspended", colors.red
    end
    writeAt(2, 9,  "P2P status:     " .. stateLabel,                              stateColor)
    writeAt(2, 10, "Buffer:         " .. string.format("%.0f%%", m.bufferPct or 0) ..
                   "  (" .. formatFE(m.isProducer and (m.export or 0) or (m.draw or 0)) .. " FE/t)", colors.yellow)
  elseif m.isProducer then
    writeAt(2, 9,  "Exporting:      " .. formatFE(m.export or 0) .. " FE/t",   colors.yellow)
    writeAt(2, 10, "Total exported: " .. formatFE(m.totalExported or 0) .. " FE",  colors.white)
  else
    writeAt(2, 9,  "Live draw:      " .. formatFE(m.draw or 0) .. " FE/t",         colors.white)
    writeAt(2, 10, "Total consumed: " .. formatFE(m.total or 0) .. " FE",          colors.white)
  end
  writeAt(2, 11, "Rate cap:       " .. ((m.cap or 0)>=2147483647
                  and "Unlimited" or formatFE(m.cap or 0).." FE/t"),           colors.gray)
  writeAt(2, 12, "Rate/FE:        " .. string.format("%.6f LC", m.ratePerFE or DEFAULT_RATE), colors.gray)
  local statusRow = 14
  if not m.isProducer and m.plan == "periodic" then
    local row = 13
    if m.periodCost then
      writeAt(2, row, "Period cost:    " .. formatCurrency(m.periodCost) .. " LC", colors.orange)
      row = row + 1
    end
    if m.billSecsLeft then
      local mins = math.floor(m.billSecsLeft / 60)
      local secs = m.billSecsLeft % 60
      writeAt(2, row, "Next bill in:   " .. string.format("%dm %02ds", mins, secs), colors.cyan)
      row = row + 1
    end
    writeAt(2, row, "Status:         " .. (isOnline and "Online" or "OFFLINE"),
      isOnline and colors.lime or colors.red)
    statusRow = row + 1
  else
    writeAt(2, 13, "Status:         " .. (isOnline and "Online" or "OFFLINE"),
      isOnline and colors.lime or colors.red)
  end

  hline(statusRow)
  if m.powerOn then
    centreText(statusRow + 1, " POWER ON ",  colors.black, colors.lime)
  else
    centreText(statusRow + 1, " POWER OFF ", colors.white, colors.red)
  end
  hline(statusRow + 2)

  local bw  = math.floor((W - 6) / 3)
  local bw4 = math.floor((W - 6) / 4)
  addButton(2,       H-4, 1+bw,   H-4,
    m.powerOn and "CUT POWER" or "RESTORE",
    colors.white, m.powerOn and colors.red or colors.green, function()
      if m.powerOn then
        confirm({"Cut power for "..(m.player or tostring(id)).."?"}, function()
          sendCommand(id, "cut")
          addAlert("Cut: "..(m.player or id))
          whisper(m.player, "Your power supply has been cut by an administrator. Please contact Beyond Energy if you believe this is an error.")
        end, "customer")
      else
        sendCommand(id, "restore")
        addAlert("Restored: "..(m.player or id))
        whisper(m.player, "Your power supply has been restored.")
      end
    end)
  addButton(2+bw,    H-4, 1+bw*2, H-4, "+500 LC",
    colors.black, colors.lime, function()
      local nb = (m.balance or 0) + 500
      confirm({"Add 500 LC to "..(m.player or tostring(id)).."?",
               "New balance: "..formatCurrency(nb).." LC"}, function()
        sendCommand(id, "setbalance", nb)
        addAlert("Added 500 LC to "..(m.player or id))
        whisper(m.player, "500 LC has been added to your account. New balance: "..formatCurrency(nb).." LC.")
        m.balance = nb
      end, "customer")
    end)
  addButton(2+bw*2,  H-4, W,      H-4, "SET CAP",
    colors.black, colors.cyan, function()
      local curLabel = (m.cap or 0)>=2147483647 and "Unlimited" or formatFE(m.cap or 0).." FE/t"
      openNumericInput(
        "Set Rate Cap for "..(m.player or tostring(id)),
        "Current: "..curLabel.."  (UNLIMITED = no cap)",
        false,
        function(n)
          local nc    = math.floor(n)
          local label = nc >= 2147483647 and "Unlimited" or (formatFE(nc).." FE/t")
          confirm({"Set cap for "..(m.player or tostring(id)).."?",
                   "New cap: "..label}, function()
            sendCommand(id, "setcap", nc)
            addAlert("Cap "..label.." for "..(m.player or id))
            m.cap = nc
          end, "customer")
        end,
        { label = "UNLIMITED", value = 2147483647 },
        "customer")
    end)

  addButton(2,          H-2, 1+bw4,    H-2, "RENAME",
    colors.black, colors.orange, function()
      term.setTextColor(colors.orange)
      print("\nRename meter for: " .. (m.player or tostring(id)))
      term.setTextColor(colors.lightGray)
      term.write("New name: ")
      term.setTextColor(colors.white)
      local name = io.read()
      if name and #name > 0 then
        confirm({"Rename to '"..name.."'?"}, function()
          sendCommand(id, "setname", name)
          addAlert("Renamed " .. (m.player or tostring(id)) .. " to " .. name)
          m.player = name
        end, "customer")
      end
    end)
  if m.balanced then
    addButton(2+bw4,      H-2, 1+bw4*2,  H-2, "PAYG (FIXED)",
      colors.black, colors.gray, function() end)
  else
    addButton(2+bw4,      H-2, 1+bw4*2,  H-2, "CHG PLAN",
      colors.black, colors.yellow, function()
        local newPlan  = (m.plan == "payg") and "periodic" or "payg"
        local newLabel = newPlan == "payg" and "Pay As You Go" or "Periodic"
        confirm({"Change plan for "..(m.player or tostring(id)).."?",
                 "New plan: "..newLabel}, function()
          sendCommand(id, "setplan", newPlan)
          addAlert("Plan -> " .. newLabel .. ": " .. (m.player or tostring(id)))
          m.plan = newPlan
        end, "customer")
      end)
  end
  addButton(2+bw4*2,    H-2, 1+bw4*3,  H-2, "UPDATE",
    colors.black, colors.purple, function()
      confirm({"Push update to "..(m.player or tostring(id)).."?",
               "Meter will reboot."}, function()
        sendCommand(id, "update")
        addAlert("Update sent to "..(m.player or id))
      end, "customer")
    end)
  addButton(2+bw4*3,    H-2, W,         H-2, "CHANGE TYPE",
    colors.black, colors.orange, function()
      currentScreen = "typepicker"
    end)

  hline(H-1)
  drawUpdateBanner()
  addButton(1, H, W, H, "< BACK",
    colors.black, colors.gray, function() currentScreen="dashboard" end)

  drawButtons()
end

-- ── Connection-type picker screen ────────────────────────────
local TYPE_PICKER_LABELS = { consumer = "Consumer", producer = "Producer", balanced = "Balanced (Auto P2P)" }
local TYPE_PICKER_COLORS = { consumer = colors.cyan, producer = colors.lime, balanced = colors.yellow }

local function drawTypePickerScreen()
  local m  = meters[selectedMeter]
  local id = selectedMeter
  if not m then currentScreen = "dashboard"; return end

  cls(); clearButtons()
  writeAt(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  centreText(1, " CHANGE CONNECTION TYPE ", colors.black, colors.yellow)

  local curType = m.balanced and "balanced" or (m.isProducer and "producer" or "consumer")

  writeAt(2, 3, "Player:        " .. (m.player or tostring(id)),       colors.white)
  writeAt(2, 4, "Current type:  " .. TYPE_PICKER_LABELS[curType],      colors.white)
  hline(6)
  centreText(7, "Select a new connection type:", colors.lightGray)

  local order = { "consumer", "producer", "balanced" }
  local rowY  = 9
  for _, t in ipairs(order) do
    if t == curType then
      writeAt(2, rowY, string.rep(" ", W-2), colors.lightGray, colors.gray)
      writeAt(3, rowY, TYPE_PICKER_LABELS[t] .. "  (current)", colors.lightGray, colors.gray)
    elseif t == "balanced" and m.canBalance == false then
      writeAt(2, rowY, string.rep(" ", W-2), colors.gray, colors.black)
      writeAt(3, rowY, TYPE_PICKER_LABELS[t] .. "  (no Energy Cube on meter)", colors.gray, colors.black)
    else
      local label = TYPE_PICKER_LABELS[t]
      addButton(2, rowY, W-1, rowY, label, colors.black, TYPE_PICKER_COLORS[t], function()
        confirm({"Switch "..(m.player or tostring(id)).." to "..label.."?",
                 "The meter applies the change immediately."}, function()
          sendCommand(id, "settype", t)
          addAlert("Type -> "..label..": "..(m.player or tostring(id)))
          if t == "balanced" then
            m.balanced, m.isProducer = true, false
          else
            m.balanced, m.isProducer = false, (t == "producer")
          end
        end, "customer")
      end)
    end
    rowY = rowY + 2
  end

  hline(H-1)
  drawUpdateBanner()
  addButton(1, H, W, H, "< BACK",
    colors.black, colors.gray, function() currentScreen="customer" end)

  drawButtons()
end

-- ── Numeric input screen (touch keypad) ──────────────────────
local function drawNumericInputScreen()
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY",  colors.yellow)
  centreText(3, numInputTitle,    colors.lightGray)
  hline(4)
  if numInputSubtitle ~= "" then
    centreText(6, numInputSubtitle, colors.lightGray)
  end
  centreText(7, "> " .. numInput .. "_", colors.lime)
  hline(8)

  -- Touch numeric keypad
  local rows = {
    {"7", "8", "9"},
    {"4", "5", "6"},
    {"1", "2", "3"},
    {numInputAllowDecimal and "." or "C", "0", "<-"},
  }
  local kw = math.floor((W - 4) / 3)
  for r, row in ipairs(rows) do
    for c, label in ipairs(row) do
      local x1 = 2 + (c - 1) * (kw + 1)
      local x2 = x1 + kw - 1
      local y  = 9 + (r - 1)
      addButton(x1, y, x2, y, label, colors.white, colors.gray, function()
        if label == "<-" then
          numInput = numInput:sub(1, -2)
        elseif label == "C" then
          numInput = ""
        elseif label == "." then
          if not numInput:find("%.", 1, true) then numInput = numInput .. "." end
        else
          numInput = numInput .. label
        end
      end)
    end
  end

  hline(13)
  local by = 14
  if numInputExtra then
    local bw3 = math.floor((W - 4) / 3)
    addButton(2,       by, 1+bw3,   by, "CONFIRM", colors.black, colors.lime, function()
      local n = tonumber(numInput)
      if n and n > 0 and numInputOnConfirm then numInputOnConfirm(n) end
    end)
    addButton(2+bw3,   by, 1+bw3*2, by, numInputExtra.label, colors.black, colors.cyan, function()
      if numInputOnConfirm then numInputOnConfirm(numInputExtra.value) end
    end)
    addButton(2+bw3*2, by, W-1,     by, "CANCEL", colors.white, colors.red, function()
      currentScreen = numInputReturn
    end)
  else
    local bw2 = math.floor((W - 4) / 2)
    addButton(2,     by, 1+bw2, by, "CONFIRM", colors.black, colors.lime, function()
      local n = tonumber(numInput)
      if n and n > 0 and numInputOnConfirm then numInputOnConfirm(n) end
    end)
    addButton(2+bw2, by, W-1,   by, "CANCEL", colors.white, colors.red, function()
      currentScreen = numInputReturn
    end)
  end

  hline(H-1)
  drawUpdateBanner()
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Alerts screen ────────────────────────────────────────────
local function drawAlertsScreen()
  cls(); clearButtons()
  writeAt(1, 1, string.rep(" ", W), colors.black, colors.orange)
  centreText(1, " ALERTS ", colors.black, colors.orange)
  hline(2)
  if #alerts == 0 then
    centreText(4, "No alerts.", colors.gray)
  else
    for i, a in ipairs(alerts) do
      if i + 2 > H - 4 then break end
      writeAt(2, i+2, a, colors.white)
    end
  end
  hline(H-3)
  local bw = math.floor(W/2) - 2
  addButton(2,       H-2, 2+bw,  H-2, "CLEAR ALL", colors.black, colors.red,  function() alerts={} end)
  addButton(W-bw-1,  H-2, W-1,   H-2, "< BACK",    colors.black, colors.gray, function() currentScreen="dashboard" end)
  hline(H-1)
  drawUpdateBanner()
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Main loop ────────────────────────────────────────────────
local function mainLoop()
  local lastUpdateCheck = os.clock()

  while true do
    local now = os.clock()

    -- Periodic background update check
    if now - lastUpdateCheck >= UPDATE_EVERY then
      lastUpdateCheck = now
      backgroundUpdateCheck()
    end
    refreshSize()
      checkAutoLock()
    if not pinUnlocked              then drawPinScreen()
    elseif currentScreen == "confirm"   then drawConfirmScreen()
    elseif currentScreen == "dashboard" then drawDashboard()
    elseif currentScreen == "customer"  then drawCustomerScreen()
    elseif currentScreen == "typepicker" then drawTypePickerScreen()
    elseif currentScreen == "numinput" then drawNumericInputScreen()
    elseif currentScreen == "alerts"    then drawAlertsScreen()
    end

    -- Wait for event
    local timer = os.startTimer(2)  -- redraw every 2 seconds
    while true do
      local ev = {os.pullEvent()}
      local e  = ev[1]

      if e == "monitor_touch" then
        touchActivity(); checkClick(ev[3], ev[4]); break

      elseif e == "modem_message" then
        local msg = ev[5]
        if type(msg) == "table" and msg.type == "status" and msg.id then
          local id  = msg.id
          local was = meters[id]
          meters[id]          = msg
          meters[id].lastSeen = os.clock()
          if msg.balance and msg.balance <= 50 and msg.balance > 0 then
            if not was or not was.balance or was.balance > 50 then
              addAlert("Low bal: "..(msg.player or id).." ("..formatCurrency(msg.balance).." LC)")
              whisper(msg.player, "Low balance warning: "..formatCurrency(msg.balance).." LC remaining. Please top up to avoid a power cut.")
            end
          end
          if was and was.powerOn and not msg.powerOn then
            addAlert("Power cut: "..(msg.player or id))
            whisper(msg.player, "Your power supply has been cut. Please top up your balance to reconnect.")
          end
        end

      elseif e == "timer" and ev[2] == timer then
        break
      end
    end
  end
end

-- ── Boot ─────────────────────────────────────────────────────
loadPin()
W, H = monitor.getSize()
monitor.setBackgroundColor(colors.black)
monitor.clear()
if chatBox then
  term.setTextColor(colors.lime);  print("Chat Box       : found")
else
  term.setTextColor(colors.orange); print("Chat Box       : not found (whispers disabled)")
end
term.setTextColor(colors.white)
bootUpdateCheck()
mainLoop()
