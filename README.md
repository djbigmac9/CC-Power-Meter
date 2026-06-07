# Beyond Energy — CC Power Meter

A ComputerCraft (CC:Tweaked) electric utility system for BeyondSMP. Meters track player energy usage, charge balances in Linden Coins (LC), and support both consumer and producer connections to the grid. An admin panel and pocket computer provide full remote management.

---

## Files

| File | Description |
|---|---|
| `meter.lua` | Customer-facing energy meter, runs on the meter computer |
| `admin.lua` | Admin monitor panel, shows all meters and controls |
| `pocket.lua` | Pocket computer remote management interface |
| `setup.lua` | Interactive installer — run this first |

---

## Quick Start

Run this on any fresh CC computer, pocket computer, or admin machine:

```
wget https://raw.githubusercontent.com/djbigmac9/CC-Power-Meter/main/setup.lua setup.lua
setup.lua
```

The setup script will:
1. Ask which machine type this is (Meter / Admin / Pocket)
2. Check all required peripherals are connected
3. Download the correct script from GitHub
4. Optionally write a `startup.lua` so it runs on reboot

---

## Hardware Requirements

### Energy Meter
| Peripheral | Side | Required |
|---|---|---|
| Advanced Monitor | Any | Yes |
| Ender Modem | Any | Yes |
| Energy Detector (import) | **Left** | One of these two |
| Energy Detector (export) | **Right** | is required |

- **Left** detector measures power drawn **from** the grid (consumers)
- **Right** detector measures power exported **to** the grid (producers)
- Both detectors can be installed for meters that may switch type

### Admin Panel
| Peripheral | Required |
|---|---|
| Advanced Monitor | Yes |
| Ender Modem | Yes |
| Energy Detector (any side) | Yes — for live generation monitoring |
| Chat Box (any side) | Optional — enables player whisper notifications |

### Pocket Monitor
| Peripheral | Required |
|---|---|
| Ender Modem | Yes |

Runs on a pocket computer (Advanced Peripherals Ender Modem attached).

---

## Networking

All machines communicate over wireless modem channels:

| Channel | Purpose |
|---|---|
| `1001` | Meters broadcast status every 5 seconds |
| `1002` | Admin/pocket send commands to meters |

All machines must be within Ender Modem range (or use Ender Modems, which are global).

---

## Meter Features

### Customer Registration
On first boot the meter walks a new customer through a 3-step setup:
1. Enter player name (typed on computer keyboard)
2. Choose billing plan — **Pay As You Go** or **Periodic Billing**
3. Choose connection type — **Consumer** or **Producer**

### Billing Plans

**Pay As You Go (PAYG)**
- Balance drains in real time as energy is consumed
- Power cuts automatically when balance reaches zero
- Rate: configurable per FE (default `0.0001 LC/FE`)

**Periodic Billing**
- Usage accumulates across a billing period (~20 minutes / 1200 ticks)
- Charged in one lump at the end of the period
- Meter shows current period cost and countdown to next bill
- **PAY NOW** button lets the customer pay early and reset the period
- Power only cuts if balance goes negative after a charge

### Producer Mode
- Exports power to the grid instead of consuming it
- Earns **75%** of the standard rate per FE exported
- Balance accumulates — producer can switch to consumer at any time
- Outstanding periodic usage is settled before switching type
- Producers can set their own export rate cap (`SET EXPORT CAP` button — choose Unlimited or a preset FE/t limit) to avoid overloading their own generation setup — this cap is independent of the admin-set consumer rate cap, and each is restored automatically when switching type back

### On-Screen Information
- Customer name, billing plan, connection type
- Live draw or export rate in FE/t
- Current balance (colour-coded: green / yellow / red)
- Total energy consumed or exported
- For periodic consumers: period cost so far and countdown to next bill
- Power status bar — green ON / red OFF
- Low balance warning banner
- Update available banner (tap to install)

### Meter Buttons
| Button | Function |
|---|---|
| `[TEMP] +200 LC` | Add 200 LC temporary credit |
| `CHANGE PLAN` | Switch between PAYG and Periodic (charges any outstanding usage first) |
| `CHANGE TYPE` | Switch between Consumer and Producer (charges any outstanding usage first) |
| `SET EXPORT CAP` | Producers only — choose an export rate cap (Unlimited or a preset FE/t limit) |
| `CUT POWER / RESTORE` | Toggle power manually |
| `PAY NOW (X.XXXX LC)` | Periodic only — pay current period immediately |

---

## Admin Panel Features

### Dashboard
- Live generation, total draw, and surplus for the whole network
- Per-meter table: name, plan, balance, draw/export rate, cap, power status, type tag `[P]`/`[C]`
- Click any row to open the customer detail screen

### Customer Detail Screen
| Control | Function |
|---|---|
| `CUT POWER / RESTORE` | Cut or restore this meter's power |
| `+500 LC` | Add 500 LC to balance |
| `TOGGLE CAP` | Switch rate cap between Unlimited and 10,000 FE/t |
| `RENAME` | Change the player name on this meter |
| `CHG PLAN` | Toggle billing plan (PAYG ↔ Periodic) |
| `UPDATE` | Push a remote update to this meter |
| `-> PRODUCER / -> CONSUMER` | Switch connection type remotely |

- For periodic consumers: shows live period cost and next billing countdown
- Player is whispered via Chat Box on power cut/restore and low balance (if Chat Box is attached)

### Global Controls
| Button | Function |
|---|---|
| `DASHBOARD` | Return to meter list |
| `ALERTS` | View event log (power cuts, low balances, etc.) |
| `SET RATE` | Broadcast a new LC/FE rate to all meters |
| `UPD METERS` | Send remote update command to all meters |
| `CUT ALL / RESTORE ALL` | Cut or restore every meter at once |

---

## Pocket Monitor Features

Runs on an Advanced Pocket Computer with an Ender Modem.

- **List screen** — all meters with online status and power state
- **Detail screen** — balance, draw/export, plan, type, period cost, countdown
- Per-meter actions: CUT/RESTORE, +500 LC, +100 LC, TOGGLE CAP, UPDATE METER, RENAME, CHG PLAN, toggle type
- Global: CUT ALL, RESTORE ALL, UPD ALL
- Alert log with count indicator
- Update available banner
- Back/Q key to return to list

---

## Auto-Update System

Every machine checks GitHub for a newer version on boot and again every 5 minutes in the background.

- On boot: if an update is found it downloads and reboots automatically
- While running: a yellow **UPDATE AVAILABLE** banner appears on screen
  - Meter: tap the banner to install
  - Admin/Pocket: tap/click the banner to install, or use the UPD METERS button to push to all meters at once

Updates are pulled from the `main` branch of this repository.

---

## Configuration (meter.lua)

Edit the config block near the top of `meter.lua` before deploying:

| Variable | Default | Description |
|---|---|---|
| `RATE_PER_FE` | `0.0001` | LC charged per FE consumed (also remotely settable) |
| `POLL_INTERVAL` | `1.0` | Seconds between billing ticks |
| `WARN_BALANCE` | `50` | LC threshold for low balance warning |
| `TEMP_TOP_UP` | `200` | LC added by the [TEMP] button on the meter |
| `PERIOD_TICKS` | `1200` | Billing ticks per period (~20 minutes at 1 tick/s) |
| `BROADCAST_EVERY` | `5` | Seconds between status broadcasts |
| `UPDATE_EVERY` | `300` | Seconds between background update checks |

---

## Commands Reference (modem channel 1002)

Meters accept these commands from the admin or pocket computer:

| Command | Value | Effect |
|---|---|---|
| `cut` | — | Cut power |
| `restore` | — | Restore power (if balance > 0) |
| `setbalance` | number | Set balance directly |
| `setrate` | number | Set LC/FE rate |
| `setplan` | `"payg"` or `"periodic"` | Change billing plan |
| `settype` | `"producer"` or `"consumer"` | Change connection type |
| `setname` | string | Rename the meter |
| `setcap` | number | Set the admin-controlled import (consumer-side) FE/t rate cap — producers manage their own export cap locally |
| `update` | — | Download latest version and reboot |

Commands can target a specific meter by `id` (computer ID) or use `"all"` to broadcast.

---

## Versions

| File | Current Version |
|---|---|
| meter.lua | 3.10 |
| admin.lua | 3.4 |
| pocket.lua | 2.12 |
| setup.lua | — |
