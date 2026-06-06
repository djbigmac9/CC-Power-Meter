-- ============================================================
--  BeyondSMP Pocket Monitor v1.7
--  Advanced Pocket Computer + Ender Modem
-- ============================================================

local STATUS_CH     = 1001
local COMMAND_CH    = 1002
local METER_TIMEOUT = 30
local MAX_FLOW      = 2147483647

-- ── Version ──────────────────────────────────────────────────
local VERSION      = "2.3"
local RAW_URL = "https://raw.githubusercontent.com/djbigmac9/CC-Power-Meter/main/pocket.lua"
local UPDATE_EVERY = 300
local updateAvail  = false
local modem = peripheral.find("modem")
if not modem then
  print("No Ender Modem found."); return
end
modem.open(STATUS_CH)

-- ── State ────────────────────────────────────────────────────
local meters   = {}
local alerts   = {}
local screen   = "list"
local selected = nil
local W, H     = term.getSize()

-- ── Helpers ──────────────────────────────────────────────────
local function cls()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1,1)
end

local function at(x, y, text, fg, bg)
  if y < 1 or y > H or x < 1 or x > W then return end
  term.setCursorPos(x, y)
  if bg  then term.setBackgroundColor(bg)  end
  if fg  then term.setTextColor(fg)        end
  local maxLen = W - x + 1
  if #text > maxLen then text = text:sub(1, maxLen) end
  term.write(text)
end

local function hline(y)
  at(1, y, string.rep("-", W), colors.gray, colors.black)
end

local function formatFE(n)
  n = n or 0
  if n >= 1e9 then return string.format("%.1fG",n/1e9)
  elseif n >= 1e6 then return string.format("%.1fM",n/1e6)
  elseif n >= 1e3 then return string.format("%.1fk",n/1e3)
  else return string.format("%d", math.floor(n)) end
end

local function fmtLC(n)
  return string.format("%.2f LC", n or 0)
end

local function sendCmd(id, cmd, val)
  modem.transmit(COMMAND_CH, STATUS_CH, {id=id, cmd=cmd, value=val})
end

local function broadcast(cmd, val)
  modem.transmit(COMMAND_CH, STATUS_CH, {id="all", cmd=cmd, value=val})
end

local function pushAlert(msg)
  table.insert(alerts, 1, msg)
  if #alerts > 20 then table.remove(alerts) end
end

local function drawUpdateBanner()
  if not updateAvail then return end
  at(1, H-1, string.rep(" ", W), colors.black, colors.yellow)
  at(1, H-1, "** UPDATE AVAILABLE - TAP TO INSTALL **", colors.black, colors.yellow)
  table.insert(btns, {x1=1, x2=W, y=H-1, fn=function()
    doUpdate()
  end})
end

-- ── Update ───────────────────────────────────────────────────
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
  cls()
  at(1, 1, "Downloading update...", colors.lime)
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
    at(1, 2, "Done. Rebooting...", colors.white)
    os.sleep(1); os.reboot()
  else
    if fs.exists(tmp) then fs.delete(tmp) end
    at(1, 2, "Download failed.", colors.red)
    os.sleep(3)
  end
end

local function bootUpdateCheck()
  cls()
  at(1, 1, "BEYOND ENERGY",           colors.yellow)
  at(1, 2, "Checking for updates...", colors.lightGray)
  local latest = getLatestVersion()
  if latest and isNewer(latest, VERSION) then
    at(1, 3, "Update found: v"..latest, colors.orange)
    os.sleep(1); doUpdate()
  else
    at(1, 3, latest and "Up to date (v"..VERSION..")"
             or "Offline, skipping", colors.gray)
    os.sleep(1)
  end
end

local function backgroundUpdateCheck()
  local latest = getLatestVersion()
  if latest and isNewer(latest, VERSION) then
    updateAvail = true
    pushAlert("Pocket update available: v"..latest.." - reboot to install")
  end
end

-- ── Buttons ──────────────────────────────────────────────────
local btns = {}
local function clearBtns() btns = {} end

local function btn(x1, y, x2, label, fg, bg, fn)
  local bw  = x2 - x1 + 1
  local pad = math.max(0, math.floor((bw - #label) / 2))
  local str = string.rep(" ", pad) .. label
  str = str .. string.rep(" ", math.max(0, bw - #str))
  at(x1, y, str, fg or colors.black, bg or colors.gray)
  table.insert(btns, {x1=x1, x2=x2, y=y, fn=fn})
end

local function click(x, y)
  for _, b in ipairs(btns) do
    if y == b.y and x >= b.x1 and x <= b.x2 then
      b.fn(); return true
    end
  end
  return false
end

-- ── Sorted meters ─────────────────────────────────────────────
local function sorted()
  local now = os.clock()
  local t   = {}
  for id, m in pairs(meters) do
    table.insert(t, {id=id, m=m,
      online=(now-(m.lastSeen or 0)) <= METER_TIMEOUT})
  end
  table.sort(t, function(a,b)
    if a.online ~= b.online then return a.online end
    return (a.m.player or "") < (b.m.player or "")
  end)
  return t
end

-- ── LIST SCREEN ───────────────────────────────────────────────
local function drawList()
  cls(); clearBtns()

  -- Header
  at(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  at(1, 1, "BEYOND ENERGY v"..VERSION, colors.black, colors.yellow)
  if #alerts > 0 then
    local ind = "["..#alerts.."]"
    at(W - #ind + 1, 1, ind, colors.black, colors.orange)
    table.insert(btns, {x1=W-#ind+1, x2=W, y=1, fn=function()
      screen = "alerts"
    end})
  end

  hline(2)

  -- Customer rows — one per line, just name + status dot
  local list = sorted()
  local rowY = 3

  if #list == 0 then
    at(1, 3, "Waiting for meters...", colors.gray)
  else
    for _, e in ipairs(list) do
      if rowY > H - 2 then break end
      local m   = e.m
      local dot, dotFg
      if not e.online then
        dot = " ?? "; dotFg = colors.gray
      elseif m.powerOn then
        dot = " ON "; dotFg = colors.lime
      else
        dot = "OFF "; dotFg = colors.red
      end

      -- Low balance warning marker
      local warn = (m.balance or 0) > 0 and (m.balance or 0) <= 50
      local nameFg = warn and colors.orange or (e.online and colors.white or colors.gray)

      at(1, rowY, string.rep(" ", W), colors.white, colors.black)
      at(1, rowY, (m.player or "Unknown"), nameFg, colors.black)
      at(W - 3, rowY, dot, dotFg, colors.black)

      local cid = e.id
      table.insert(btns, {x1=1, x2=W, y=rowY, fn=function()
        selected = cid; screen = "detail"
      end})

      rowY = rowY + 1
    end
  end

  drawUpdateBanner()
  hline(H - 1)
  local bw = math.floor(W / 3)
  btn(1,      H, bw,     "CUT ALL",  colors.white, colors.red,    function()
    broadcast("cut"); pushAlert("All meters cut") end)
  btn(bw+1,   H, bw*2,   "REST ALL", colors.black, colors.green,  function()
    broadcast("restore"); pushAlert("All meters restored") end)
  btn(bw*2+1, H, W,      "UPD ALL",  colors.black, colors.purple, function()
    broadcast("update"); pushAlert("Update sent to all meters") end)
end

-- ── DETAIL SCREEN ─────────────────────────────────────────────
local function drawDetail()
  if not selected or not meters[selected] then
    screen = "list"; return
  end
  cls(); clearBtns()

  local m       = meters[selected]
  local now     = os.clock()
  local online  = (now - (m.lastSeen or 0)) <= METER_TIMEOUT
  local bal     = m.balance or 0
  local balFg   = bal > 50 and colors.lime or (bal > 0 and colors.yellow or colors.red)

  -- Header: player name
  at(1, 1, string.rep(" ", W), colors.black, colors.yellow)
  at(1, 1, (m.player or "Unknown"), colors.black, colors.yellow)

  hline(2)

  -- Details
  at(1, 3,  "Plan:    ", colors.gray)
  at(10, 3, m.plan == "payg" and "Pay As You Go" or "Periodic", colors.cyan)

  at(1, 4,  "Type:    ", colors.gray)
  at(10, 4, m.isProducer and "Producer" or "Consumer",
    m.isProducer and colors.yellow or colors.cyan)

  at(1, 5,  "Balance: ", colors.gray)
  at(10, 5, fmtLC(bal), balFg)

  if m.isProducer then
    at(1, 6,  "Export:  ", colors.gray)
    at(10, 6, formatFE(m.exportRate or 0).." FE/t", colors.yellow)
  else
    at(1, 6,  "Draw:    ", colors.gray)
    at(10, 6, formatFE(m.draw or 0).." FE/t", colors.white)
  end

  at(1, 7,  "Cap:     ", colors.gray)
  at(10, 7, (m.cap or 0) >= MAX_FLOW and "Unlimited"
            or formatFE(m.cap or 0).." FE/t", colors.gray)

  at(1, 8,  "Total:   ", colors.gray)
  at(10, 8, m.isProducer
            and formatFE(m.totalExported or 0).." FE out"
            or  formatFE(m.total or 0).." FE", colors.gray)

  at(1, 9,  "Status:  ", colors.gray)
  at(10, 9, online and "Online" or "OFFLINE",
    online and colors.lime or colors.red)

  local o = 0  -- row offset per extra periodic row shown
  if not m.isProducer and m.plan == "periodic" then
    if m.periodCost then
      at(1, 10 + o, "Cost:    ", colors.gray)
      at(10, 10 + o, string.format("%.4f LC", m.periodCost), colors.orange)
      o = o + 1
    end
    if m.billSecsLeft then
      local mins = math.floor(m.billSecsLeft / 60)
      local secs = m.billSecsLeft % 60
      at(1, 10 + o, "Next:    ", colors.gray)
      at(10, 10 + o, string.format("%dm %02ds", mins, secs), colors.cyan)
      o = o + 1
    end
  end

  hline(10 + o)

  -- Power status bar
  if m.powerOn then
    at(1, 11 + o, string.rep(" ", W), colors.black, colors.lime)
    at(1, 11 + o, "  POWER ON", colors.black, colors.lime)
  else
    at(1, 11 + o, string.rep(" ", W), colors.white, colors.red)
    at(1, 11 + o, "  POWER OFF", colors.white, colors.red)
  end

  hline(12 + o)

  -- Action buttons
  local bw = math.floor(W / 2)
  btn(1,    13 + o, bw,   m.powerOn and "CUT" or "RESTORE",
    colors.white, m.powerOn and colors.red or colors.green,
    function()
      if m.powerOn then
        sendCmd(selected, "cut")
        pushAlert("Cut: "..(m.player or selected))
      else
        sendCmd(selected, "restore")
        pushAlert("Restored: "..(m.player or selected))
      end
    end)

  btn(bw+1, 13 + o, W,    "+500 LC",
    colors.black, colors.lime, function()
      local nb = bal + 500
      sendCmd(selected, "setbalance", nb)
      pushAlert("+500: "..(m.player or selected))
      m.balance = nb
    end)

  btn(1,    14 + o, bw,   "+100 LC",
    colors.black, colors.lime, function()
      local nb = bal + 100
      sendCmd(selected, "setbalance", nb)
      pushAlert("+100: "..(m.player or selected))
      m.balance = nb
    end)

  btn(bw+1, 14 + o, W,    "TOGGLE CAP",
    colors.black, colors.cyan, function()
      local nc = (m.cap or 0) >= MAX_FLOW and 10000 or MAX_FLOW
      sendCmd(selected, "setcap", nc)
      pushAlert("Cap "..(nc>=MAX_FLOW and "Unlim" or formatFE(nc))
        ..": "..(m.player or selected))
      m.cap = nc
    end)

  btn(1,    15 + o, W,    "UPDATE METER",
    colors.black, colors.purple, function()
      sendCmd(selected, "update")
      pushAlert("Update sent to "..(m.player or selected))
    end)

  btn(1,    16 + o, W,    "RENAME",
    colors.black, colors.orange, function()
      cls()
      at(1, 1, "RENAME METER",   colors.orange)
      at(1, 2, "Current: " .. (m.player or tostring(selected)), colors.lightGray)
      at(1, 4, "New name:", colors.white)
      term.setCursorPos(1, 5)
      term.setTextColor(colors.lime)
      local name = io.read()
      if name and #name > 0 then
        sendCmd(selected, "setname", name)
        pushAlert("Renamed to: " .. name)
        m.player = name
      end
      screen = "detail"
    end)

  btn(1,    17 + o, W,    "CHG PLAN",
    colors.black, colors.yellow, function()
      local newPlan  = (m.plan == "payg") and "periodic" or "payg"
      local newLabel = newPlan == "payg" and "Pay As You Go" or "Periodic"
      sendCmd(selected, "setplan", newPlan)
      pushAlert("Plan -> " .. newLabel .. ": " .. (m.player or tostring(selected)))
      m.plan = newPlan
    end)

  btn(1,    18 + o, W,
    m.isProducer and "TYPE: PRODUCER -> CONSUMER" or "TYPE: CONSUMER -> PRODUCER",
    colors.black, colors.orange, function()
      local newType = not m.isProducer
      sendCmd(selected, "settype", newType and "producer" or "consumer")
      pushAlert("Type -> "..(newType and "Producer" or "Consumer")
        ..": "..(m.player or tostring(selected)))
      m.isProducer = newType
    end)

  drawUpdateBanner()
  hline(H-1)
  btn(1,    H, bw,   "< BACK",
    colors.black, colors.gray, function() screen = "list" end)
  btn(bw+1, H, W,    #alerts>0 and "ALERTS["..#alerts.."]" or "ALERTS",
    colors.black, #alerts>0 and colors.orange or colors.gray,
    function() screen = "alerts" end)
end

-- ── ALERTS SCREEN ─────────────────────────────────────────────
local function drawAlerts()
  cls(); clearBtns()

  at(1, 1, string.rep(" ", W), colors.black, colors.orange)
  at(1, 1, "ALERTS", colors.black, colors.orange)
  hline(2)

  if #alerts == 0 then
    at(1, 3, "No alerts.", colors.gray)
  else
    for i, a in ipairs(alerts) do
      if i + 2 > H - 2 then break end
      at(1, i+2, a:sub(1,W), colors.white)
    end
  end

  hline(H-1)
  local bw = math.floor(W/2)
  btn(1,    H, bw,   "CLEAR",  colors.black, colors.red,  function() alerts = {} end)
  btn(bw+1, H, W,    "< BACK", colors.black, colors.gray, function() screen = "list" end)
end

-- ── Redraw ────────────────────────────────────────────────────
local function redraw()
  if     screen == "list"   then drawList()
  elseif screen == "detail" then drawDetail()
  elseif screen == "alerts" then drawAlerts()
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
end

bootUpdateCheck()
redraw()

-- ── Main loop ─────────────────────────────────────────────────
local lastUpdateCheck = os.clock()
while true do
  local ev = {os.pullEvent()}
  local e  = ev[1]

  if e == "modem_message" then
    local msg = ev[5]
    if type(msg) == "table" and msg.type == "status" and msg.id then
      local id  = msg.id
      local was = meters[id]
      meters[id]          = msg
      meters[id].lastSeen = os.clock()
      if msg.balance and msg.balance <= 50 and msg.balance > 0 then
        if not was or not was.balance or was.balance > 50 then
          pushAlert("Low bal: "..(msg.player or id).." "..fmtLC(msg.balance))
        end
      end
      if was and was.powerOn and not msg.powerOn then
        pushAlert("Power cut: "..(msg.player or id))
      end
    end
    -- Periodic background update check
    if os.clock() - lastUpdateCheck >= UPDATE_EVERY then
      lastUpdateCheck = os.clock()
      backgroundUpdateCheck()
    end
    redraw()

  elseif e == "mouse_click" then
    click(ev[3], ev[4]); redraw()

  elseif e == "key" then
    local k = ev[2]
    if k == keys.backspace or k == keys.q then
      if screen == "detail" or screen == "alerts" then
        screen = "list"; redraw()
      end
    end
  end
end
