-- ============================================================
--  BeyondSMP Admin Panel v1.9
--  Peripherals (fully auto-detected):
--    Energy Detector = any side (generation monitor)
--    Monitor         = any size, auto-scales
--    Ender Modem     = any side
--    Chat Box        = any side (optional, AP - enables player whispers)
-- ============================================================

-- ── Version & update ─────────────────────────────────────────
local VERSION      = "2.0"
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
local chatBox  = peripheral.find("chatBox")

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

-- ── State ────────────────────────────────────────────────────
local meters        = {}
local alerts        = {}
local selectedMeter = nil
local currentScreen = "dashboard"
local rateInput    = ""
local rateInputRow = 1

local function sendCommand(id, cmd, value)
  modem.transmit(COMMAND_CH, STATUS_CH, {id=id, cmd=cmd, value=value})
end

local function sendBroadcast(cmd, value)
  modem.transmit(COMMAND_CH, STATUS_CH, {id="all", cmd=cmd, value=value})
end

local function sendToAll(cmd, value)
  sendBroadcast(cmd, value)
end

local function addAlert(msg)
  table.insert(alerts, 1, "[" .. textutils.formatTime(os.time()) .. "] " .. msg)
  if #alerts > 20 then table.remove(alerts) end
end

local function backgroundUpdateCheck()
  local latest = getLatestVersion()
  if latest and isNewer(latest, VERSION) then
    addAlert("Admin update available: v" .. latest .. " - reboot to install")
  end
end

local function whisper(player, msg)
  if chatBox and player then
    local ok, err = pcall(function()
      chatBox.sendMessageToPlayer(msg, player, "Beyond Energy")
    end)
    if not ok then
      addAlert("Whisper error: " .. tostring(err))
    end
  end
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

  hline(5)

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
  writeAt(x1,    6, "CUSTOMER",  colors.yellow)
  writeAt(x1+17, 6, "PLAN",      colors.yellow)
  writeAt(x1+26, 6, "BALANCE",   colors.yellow)
  writeAt(x1+37, 6, "DRAW",      colors.yellow)
  writeAt(x1+47, 6, "CAP",       colors.yellow)
  writeAt(x1+56, 6, "STATUS",    colors.yellow)
  hline(7)

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
  local rowY = 9
  local maxY = H - 4

  for _, entry in ipairs(sorted) do
    if rowY > maxY then break end
    local id  = entry.id
    local m   = entry.m
    local bal = m.balance or 0
    local stTx = m.powerOn and "ON" or "OFF"
    local line = string.format("%-16s %-8s %8s LC %7s/t %7s  %s",
      (m.player or "?"):sub(1,16),
      (m.plan or "?"):sub(1,8),
      formatCurrency(bal),
      formatFE(m.draw or 0),
      (m.cap or 0) >= 2147483647 and "Unlim" or formatFE(m.cap or 0),
      stTx)
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

  hline(H - 3)
  local bw = math.floor((W - 6) / 5)
  addButton(2,          H-2, 1+bw,    H-2, "DASHBOARD",
    colors.black, colors.yellow,  function() currentScreen="dashboard" end)
  addButton(2+bw,       H-2, 1+bw*2,  H-2,
    "ALERTS" .. (#alerts>0 and " ("..#alerts..")" or ""),
    colors.black, #alerts>0 and colors.orange or colors.gray,
    function() currentScreen="alerts" end)
  addButton(2+bw*2,     H-2, 1+bw*3,  H-2, "SET RATE",
    colors.black, colors.cyan,    function() currentScreen="rate" end)
  addButton(2+bw*3,     H-2, 1+bw*4,  H-2, "UPD METERS",
    colors.black, colors.purple,  function()
      sendBroadcast("update")
      addAlert("Remote update sent to all meters")
    end)
  addButton(2+bw*4,     H-2, W,        H-2, anyOn and "CUT ALL" or "RESTORE ALL",
    colors.white, anyOn and colors.red or colors.green,
    function()
      if anyOn then
        sendBroadcast("cut");     addAlert("ADMIN: All meters cut")
      else
        sendBroadcast("restore"); addAlert("ADMIN: All meters restored")
      end
      currentScreen = "alerts"
    end)

  hline(H-1)
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
  hline(6)

  local bal = m.balance or 0
  local balFg = bal > 50 and colors.lime or (bal > 0 and colors.yellow or colors.red)

  writeAt(2, 7,  "Balance:        " .. formatCurrency(bal) .. " LC",          balFg)
  writeAt(2, 8,  "Live draw:      " .. formatFE(m.draw or 0) .. " FE/t",      colors.white)
  writeAt(2, 9,  "Rate cap:       " .. ((m.cap or 0)>=2147483647
                  and "Unlimited" or formatFE(m.cap or 0).." FE/t"),           colors.gray)
  writeAt(2, 10, "Total consumed: " .. formatFE(m.total or 0) .. " FE",       colors.white)
  writeAt(2, 11, "Rate/FE:        " .. string.format("%.6f LC", m.ratePerFE or DEFAULT_RATE), colors.gray)
  writeAt(2, 12, "Status:         " .. (isOnline and "Online" or "OFFLINE"),
    isOnline and colors.lime or colors.red)

  hline(13)
  if m.powerOn then
    centreText(14, " POWER ON ",  colors.black, colors.lime)
  else
    centreText(14, " POWER OFF ", colors.white, colors.red)
  end
  hline(15)

  local bw = math.floor((W - 6) / 3)
  addButton(2,       H-4, 1+bw,   H-4,
    m.powerOn and "CUT POWER" or "RESTORE",
    colors.white, m.powerOn and colors.red or colors.green, function()
      if m.powerOn then
        sendCommand(id, "cut")
        addAlert("Cut: "..(m.player or id))
        whisper(m.player, "Your power supply has been cut by an administrator. Please contact Beyond Energy if you believe this is an error.")
      else
        sendCommand(id, "restore")
        addAlert("Restored: "..(m.player or id))
        whisper(m.player, "Your power supply has been restored.")
      end
    end)
  addButton(2+bw,    H-4, 1+bw*2, H-4, "+500 LC",
    colors.black, colors.lime, function()
      local nb = (m.balance or 0) + 500
      sendCommand(id, "setbalance", nb)
      addAlert("Added 500 LC to "..(m.player or id))
      whisper(m.player, "500 LC has been added to your account. New balance: "..formatCurrency(nb).." LC.")
      m.balance = nb
    end)
  addButton(2+bw*2,  H-4, W,      H-4, "TOGGLE CAP",
    colors.black, colors.cyan, function()
      local nc = (m.cap or 0)>=2147483647 and 10000 or 2147483647
      sendCommand(id, "setcap", nc)
      addAlert("Cap "..(nc>=2147483647 and "Unlimited" or formatFE(nc)).." for "..(m.player or id))
      m.cap = nc
    end)

  addButton(2,       H-2, 1+bw,   H-2, "RENAME",
    colors.black, colors.orange, function()
      term.setTextColor(colors.orange)
      print("\nRename meter for: " .. (m.player or tostring(id)))
      term.setTextColor(colors.lightGray)
      term.write("New name: ")
      term.setTextColor(colors.white)
      local name = io.read()
      if name and #name > 0 then
        sendCommand(id, "setname", name)
        addAlert("Renamed " .. (m.player or tostring(id)) .. " to " .. name)
        m.player = name
      end
    end)
  addButton(2+bw,    H-2, 1+bw*2, H-2, "CHG PLAN",
    colors.black, colors.yellow, function()
      local newPlan  = (m.plan == "payg") and "periodic" or "payg"
      local newLabel = newPlan == "payg" and "Pay As You Go" or "Periodic"
      sendCommand(id, "setplan", newPlan)
      addAlert("Plan -> " .. newLabel .. ": " .. (m.player or tostring(id)))
      m.plan = newPlan
    end)
  addButton(2+bw*2,  H-2, W,      H-2, "UPDATE",
    colors.black, colors.purple, function()
      sendCommand(id, "update")
      addAlert("Update sent to "..(m.player or id))
    end)

  hline(H-1)
  addButton(1, H, W, H, "< BACK",
    colors.black, colors.gray, function() currentScreen="dashboard" end)

  drawButtons()
end

-- ── Rate screen ──────────────────────────────────────────────
local function drawRateScreen()
  cls(); clearButtons()
  centreText(2, "BEYOND ENERGY",       colors.yellow)
  centreText(3, "Global Rate Change",  colors.lightGray)
  hline(4)
  centreText(6,  "Current default rate:", colors.lightGray)
  centreText(7,  string.format("%.6f LC per FE", DEFAULT_RATE), colors.white)
  hline(9)
  centreText(10, "Type new rate then press ENTER", colors.lightGray)
  centreText(11, "e.g. 0.000001", colors.gray)
  centreText(13, "> " .. rateInput .. "_", colors.lime)
  hline(H-3)
  local bw = math.floor(W/2) - 3
  addButton(2,     H-2, 2+bw,   H-2, "BROADCAST",
    colors.black, colors.lime, function()
      local n = tonumber(rateInput)
      if n and n > 0 then
        DEFAULT_RATE = n; sendToAll("setrate", n)
        addAlert("Rate set to "..string.format("%.6f",n))
        rateInput = ""; currentScreen = "dashboard"
      end
    end)
  addButton(W-bw-1, H-2, W-1, H-2, "CANCEL",
    colors.white, colors.red, function() rateInput=""; currentScreen="dashboard" end)
  hline(H-1)
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
  centreText(H, "Beyond Energy Co. | BeyondSMP v"..VERSION, colors.gray)
  drawButtons()
end

-- ── Main loop ────────────────────────────────────────────────
local function mainLoop()
  local drawnScreen     = nil
  local lastUpdateCheck = os.clock()

  while true do
    local now = os.clock()

    -- Periodic background update check
    if now - lastUpdateCheck >= UPDATE_EVERY then
      lastUpdateCheck = now
      backgroundUpdateCheck()
    end
    refreshSize()
    if     currentScreen == "dashboard" then drawDashboard()
    elseif currentScreen == "customer"  then drawCustomerScreen()
    elseif currentScreen == "rate"      then
      drawRateScreen()
      if drawnScreen ~= "rate" then
        rateInputRow = select(2, term.getCursorPos())
        term.setCursorPos(1, rateInputRow)
        term.setTextColor(colors.lightGray)
        term.write("New rate (current: "..string.format("%.6f", DEFAULT_RATE)..") > ")
        term.setTextColor(colors.lime)
        term.write(rateInput)
        rateInputRow = select(2, term.getCursorPos())
      end
    elseif currentScreen == "alerts"    then drawAlertsScreen()
    end
    drawnScreen = currentScreen

    -- Wait for event
    local timer = os.startTimer(2)  -- redraw every 2 seconds
    while true do
      local ev = {os.pullEvent()}
      local e  = ev[1]

      if e == "monitor_touch" then
        checkClick(ev[3], ev[4]); break

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

      elseif e == "char" and currentScreen == "rate" then
        rateInput = rateInput .. ev[2]
        term.setCursorPos(1, rateInputRow)
        term.clearLine()
        term.setTextColor(colors.lime)
        term.write(rateInput)
        drawRateScreen()

      elseif e == "key" and currentScreen == "rate" then
        if ev[2] == keys.backspace and #rateInput > 0 then
          rateInput = rateInput:sub(1,-2)
          term.setCursorPos(1, rateInputRow)
          term.clearLine()
          term.setTextColor(colors.lime)
          term.write(rateInput)
          drawRateScreen()
        elseif ev[2] == keys.enter then
          local n = tonumber(rateInput)
          if n and n > 0 then
            DEFAULT_RATE = n; sendToAll("setrate", n)
            addAlert("Rate set to "..string.format("%.6f",n))
            term.setCursorPos(1, rateInputRow + 1)
            term.setTextColor(colors.white)
            term.write("Rate set to " .. string.format("%.6f", n))
            rateInput = ""; currentScreen = "dashboard"
            drawnScreen = nil
            break
          else
            term.setCursorPos(1, rateInputRow + 1)
            term.setTextColor(colors.red)
            term.write("Invalid - must be a positive number")
            term.setCursorPos(1, rateInputRow)
            term.clearLine()
            term.setTextColor(colors.lime)
            term.write(rateInput)
          end
        end

      elseif e == "timer" and ev[2] == timer then
        if currentScreen ~= "rate" then break end
        -- on rate screen: restart timer but don't break/redraw
        timer = os.startTimer(2)
      end
    end
  end
end

-- ── Boot ─────────────────────────────────────────────────────
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
