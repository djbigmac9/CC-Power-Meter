-- ============================================================
--  Beyond Energy - Setup Script
--  Run this on a fresh computer to install and configure
--  the correct Beyond Energy software for this machine type.
-- ============================================================

local BASE_URL = "https://raw.githubusercontent.com/djbigmac9/CC-Power-Meter/main/"

-- Wireless (Ender) modems talk to the admin/pocket over the broadcast
-- channels; wired modems instead bridge onto a local Mekanism cable network
-- (which is how Energy Cubes become visible). A meter benefits from having
-- both, but they serve two different jobs - check for them separately.
local function isWirelessModem(w) return w.isWireless ~= nil and w.isWireless() end

local function findModem(wireless)
  return peripheral.find("modem", function(_, w) return isWirelessModem(w) == wireless end)
end

local function hasEnergyCube()
  for _, name in ipairs(peripheral.getNames()) do
    if name:match("[Ee]nergy[Cc]ube_%d+") then return true end
  end
  return false
end

local MACHINES = {
  {
    key  = "meter",
    name = "Energy Meter",
    file = "meter.lua",
    desc = "Customer-facing power meter on a CC monitor",
    checks = {
      { name = "Ender Modem (wireless)",    required = true,
        fn = function() return findModem(true) ~= nil end,
        fix = "Attach an Ender Modem (wireless) to any side - this is what lets the meter talk to the admin panel/pocket computer" },
      { name = "CC Monitor",                required = true,
        fn = function() return peripheral.find("monitor") ~= nil end,
        fix = "Attach a CC Advanced Monitor to any side" },
      { name = "Import Detector (LEFT)",    required = false,
        fn = function()
          return peripheral.isPresent("left")
             and peripheral.getType("left") == "energy_detector"
        end,
        fix = "Place an Energy Detector on the LEFT side (grid → player)" },
      { name = "Export Detector (RIGHT)",   required = false,
        fn = function()
          return peripheral.isPresent("right")
             and peripheral.getType("right") == "energy_detector"
        end,
        fix = "Place an Energy Detector on the RIGHT side (player → grid)" },
      { name = "Wired Modem (Balanced mode)", required = false,
        fn = function() return findModem(false) ~= nil end,
        fix = "Attach a Wired Modem and connect it to a Mekanism cable network - without one, Energy Cubes can't be seen and Balanced mode stays unavailable (Consumer/Producer still work fine)" },
      { name = "Energy Cube(s) (Balanced mode)", required = false,
        fn = hasEnergyCube,
        fix = "Wire one or more Mekanism Energy Cubes onto the network as a shared buffer - required for Balanced mode" },
    },
    -- at least one detector is required even though neither alone is
    extra = function()
      local l = peripheral.isPresent("left")  and peripheral.getType("left")  == "energy_detector"
      local r = peripheral.isPresent("right") and peripheral.getType("right") == "energy_detector"
      if not l and not r then
        return false, "At least one Energy Detector is required (LEFT=import, RIGHT=export)"
      end
      return true
    end,
  },
  {
    key  = "admin",
    name = "Admin Panel",
    file = "admin.lua",
    desc = "Admin monitor panel for managing all meters",
    checks = {
      { name = "Ender Modem (wireless)", required = true,
        fn = function() return findModem(true) ~= nil end,
        fix = "Attach an Ender Modem (wireless) to any side" },
      { name = "CC Monitor",       required = true,
        fn = function() return peripheral.find("monitor") ~= nil end,
        fix = "Attach a CC Advanced Monitor to any side" },
      { name = "Energy Detector",  required = true,
        fn = function()
          for _, s in ipairs({"top","bottom","left","right","front","back"}) do
            if peripheral.isPresent(s) and peripheral.getType(s) == "energy_detector" then
              return true
            end
          end
          return false
        end,
        fix = "Attach an Advanced Peripherals Energy Detector to any side" },
      { name = "Chat Box (optional)", required = false,
        fn = function() return peripheral.find("chat_box") ~= nil end,
        fix = "Attach a Chat Box for player whisper notifications" },
    },
  },
  {
    key  = "pocket",
    name = "Pocket Monitor",
    file = "pocket.lua",
    desc = "Pocket computer remote for managing meters on the go",
    checks = {
      { name = "Ender Modem (wireless)", required = true,
        fn = function() return findModem(true) ~= nil end,
        fix = "Attach an Ender Modem (wireless) to the pocket computer" },
    },
  },
}

-- ── Helpers ──────────────────────────────────────────────────

local W, H = term.getSize()

local function cls()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
end

local function header()
  term.setBackgroundColor(colors.yellow)
  term.setTextColor(colors.black)
  term.clearLine()
  local title = " BEYOND ENERGY - SETUP "
  term.setCursorPos(math.floor((W - #title) / 2) + 1, 1)
  term.write(title)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.setCursorPos(1, 2)
end

local function hline(char)
  term.setTextColor(colors.gray)
  print(string.rep(char or "-", W))
  term.setTextColor(colors.white)
end

local function ok(msg)
  term.setTextColor(colors.lime);  term.write("  [OK]  ")
  term.setTextColor(colors.white); print(msg)
end

local function warn(msg)
  term.setTextColor(colors.orange); term.write("  [--]  ")
  term.setTextColor(colors.gray);   print(msg)
end

local function fail(msg)
  term.setTextColor(colors.red);   term.write("  [!!]  ")
  term.setTextColor(colors.white); print(msg)
end

local function info(msg)
  term.setTextColor(colors.lightGray); print("  " .. msg)
  term.setTextColor(colors.white)
end

local function prompt(msg)
  term.setTextColor(colors.cyan)
  term.write(msg)
  term.setTextColor(colors.white)
  return io.read()
end

-- ── Machine selection ─────────────────────────────────────────

local function chooseMachine()
  cls(); header()
  print()
  term.setTextColor(colors.white)
  print("  What type of machine is this?")
  print()
  for i, m in ipairs(MACHINES) do
    term.setTextColor(colors.yellow)
    term.write("  [" .. i .. "] ")
    term.setTextColor(colors.white)
    term.write(m.name)
    term.setTextColor(colors.gray)
    print("  - " .. m.desc)
    term.setTextColor(colors.white)
  end
  print()
  hline()
  while true do
    local input = prompt("  Choose (1-" .. #MACHINES .. "): ")
    local n = tonumber(input)
    if n and MACHINES[n] then return MACHINES[n] end
    term.setTextColor(colors.red)
    print("  Invalid choice, try again.")
    term.setTextColor(colors.white)
  end
end

-- ── Prerequisite check ────────────────────────────────────────

local function runChecks(machine)
  cls(); header()
  print()
  term.setTextColor(colors.white)
  print("  Checking prerequisites for: " .. machine.name)
  print()

  local blocking = false

  for _, c in ipairs(machine.checks) do
    local passed = c.fn()
    if passed then
      ok(c.name)
    elseif c.required then
      fail(c.name)
      info("Fix: " .. c.fix)
      blocking = true
    else
      warn(c.name .. " (optional)")
      info("Tip: " .. c.fix)
    end
  end

  -- Extra cross-check (e.g. meter needs at least one detector)
  if machine.extra then
    local passed, msg = machine.extra()
    if not passed then
      print()
      fail(msg)
      blocking = true
    end
  end

  print()
  hline()

  if blocking then
    term.setTextColor(colors.red)
    print("  Missing required peripherals. Fix the above")
    print("  then re-run setup.")
    term.setTextColor(colors.white)
    print()
    prompt("  Press ENTER to exit. ")
    return false
  end

  term.setTextColor(colors.lime)
  print("  All required peripherals found.")
  term.setTextColor(colors.white)
  print()
  return true
end

-- ── Download ──────────────────────────────────────────────────

local function download(machine)
  cls(); header()
  print()
  print("  Downloading " .. machine.file .. "...")
  print()

  local url = BASE_URL .. machine.file
  local ok2, res = pcall(function() return http.get(url) end)

  if not ok2 or not res then
    term.setTextColor(colors.red)
    print("  Download failed. Check your internet connection.")
    term.setTextColor(colors.white)
    print()
    prompt("  Press ENTER to exit. ")
    return false
  end

  local body = res.readAll(); res.close()
  local version = body:match('VERSION%s*=%s*"([%d%.]+)"') or "?"

  -- PIN prompt for admin/pocket machines
  if machine.key == "admin" or machine.key == "pocket" then
    hline()
    print()
    term.setTextColor(colors.white)
    print("  Set an Admin PIN for this terminal.")
    term.setTextColor(colors.lightGray)
    print("  This PIN will be required to unlock the interface.")
    print("  (digits only, 4-8 characters)")
    print()
    local pin = ""
    while true do
      while true do
        pin = prompt("  Enter PIN: ")
        if pin:match("^%d+$") and #pin >= 4 and #pin <= 8 then break end
        term.setTextColor(colors.red)
        print("  PIN must be 4-8 digits. Try again.")
        term.setTextColor(colors.white)
      end
      local confirm = prompt("  Confirm PIN: ")
      if confirm == pin then
        term.setTextColor(colors.lime)
        print("  PIN set.")
        term.setTextColor(colors.white)
        break
      end
      term.setTextColor(colors.red)
      print("  PINs do not match. Try again.")
      term.setTextColor(colors.white)
    end
    body = body:gsub('ADMIN_PIN%s*=%s*"[^"]*"', 'ADMIN_PIN = "' .. pin .. '"', 1)
    print()
  end

  local f = fs.open(machine.file, "w")
  f.write(body); f.close()

  term.setTextColor(colors.lime)
  print("  Downloaded " .. machine.file .. " (v" .. version .. ")")
  term.setTextColor(colors.white)
  print()
  return true, version
end

-- ── Startup config ────────────────────────────────────────────

local function configureStartup(machine)
  hline()
  print()
  term.setTextColor(colors.white)
  print("  Set " .. machine.file .. " to run on startup?")
  print()
  local ans = prompt("  (y/n): ")

  if ans:lower() == "y" then
    local f = fs.open("startup.lua", "w")
    f.write('shell.run("' .. machine.file .. '")\n')
    f.close()
    term.setTextColor(colors.lime)
    print()
    print("  startup.lua written.")
  else
    term.setTextColor(colors.gray)
    print()
    print("  Skipped. Run manually with:  " .. machine.file)
  end
  term.setTextColor(colors.white)
end

-- ── Main ──────────────────────────────────────────────────────

local machine   = chooseMachine()
local prereqsOk = runChecks(machine)
if not prereqsOk then return end

local ans = prompt("  Continue with installation? (y/n): ")
if ans:lower() ~= "y" then
  print()
  term.setTextColor(colors.gray); print("  Aborted."); term.setTextColor(colors.white)
  return
end

print()
local ok3 = download(machine)
if not ok3 then return end

configureStartup(machine)

print()
hline()
term.setTextColor(colors.yellow)
print("  Setup complete!")
term.setTextColor(colors.white)
print()
print("  Run it now with:")
term.setTextColor(colors.lime)
print("    " .. machine.file)
term.setTextColor(colors.white)
print()
