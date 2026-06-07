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
| Ender Modem (wireless) | Any | Yes |
| Energy Detector (import) | **Left** | One of these two |
| Energy Detector (export) | **Right** | is required |
| Wired Modem + Mekanism Energy Cube(s) | Any / wired network | Required for **Balanced** mode only |

- **Left** detector measures power drawn **from** the grid (consumers)
- **Right** detector measures power exported **to** the grid (producers)
- Both detectors can be installed for meters that may switch type, and are **required** for Balanced mode (it both buys and sells)
- The meter needs **two different kinds of modem for two different jobs**:
  - A **wireless (Ender) Modem** is what lets it "speak back" to the admin panel and pocket computer over the broadcast/command channels — without one, the meter boots into an error screen, since it has no way to report status or receive commands
  - A **Wired Modem** bridges it onto a local Mekanism cable network — this is the *only* way Energy Cube(s) become visible to the meter, so **no wired modem means no cubes, which means Balanced mode is unavailable** (the meter can still be a Consumer or Producer)
- Energy Cubes are auto-detected over the wired network by name (e.g. `basicEnergyCube_1`, `ultimateEnergyCube_1`) — one or many can be wired together as a shared buffer. This also covers the case of a customer who'd rather feed their own private power plant directly (Producer-only) than join a shared buffer

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
3. Choose connection type — **Consumer**, **Producer**, or **Balanced** (Auto P2P)

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

### Balanced Mode (Auto P2P)
- A third connection type, selectable at registration **or** any time afterwards via `CHANGE TYPE` (on the meter, admin panel, or pocket computer) — switching to/from Balanced takes effect immediately and settles any outstanding periodic usage first
- Requires one or more **Mekanism Energy Cubes** reachable over a **Wired Modem** network — auto-detected by name (e.g. `basicEnergyCube_1`) and combined into a single shared buffer
- **Gated by hardware**: a meter only offers Balanced as an option (at registration, in `CHANGE TYPE` on the meter itself, and in the remote pickers on the admin panel/pocket computer) if it actually detects at least one Energy Cube — no wired modem or no cubes means the option is shown disabled/unavailable, and the meter quietly refuses any `settype "balanced"` command. Customers without a buffer simply pick Consumer or Producer (e.g. someone feeding their own private power plant straight into the grid as a Producer)
- Automatically switches between **buying**, **selling**, and **idle** based on the buffer's combined charge percentage, using hardcoded thresholds:
  - Buffer ≥ **80%** → start **selling** surplus to the grid (earns at the producer rate, subject to `SET EXPORT CAP`)
  - Buffer ≤ **25%** → start **buying** to top up the buffer (charged at the standard rate, subject to the admin `SET CAP`)
  - Once trading starts it continues until the buffer returns to **60%**, then goes **idle** — this hysteresis prevents rapid flickering between states right at the trigger thresholds
- **Suspended/Isolated** when power is cut — trading stops entirely until power is restored (see the unified status vocabulary below for how this is shown remotely)
- Always billed **Pay As You Go** (dynamic buy/sell doesn't fit a periodic billing cycle)
- Shows a live **Buffer** readout (combined charge %, energy, and capacity of all connected cubes) and a live trading status on the meter, admin panel, and pocket computer

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
| `CHANGE TYPE` | Opens a picker listing **Consumer / Producer / Balanced** — pick a different type and confirm to switch (charges any outstanding usage first) |
| `SET EXPORT CAP` | Producers and Balanced meters — choose an export/sell-side rate cap (Unlimited or a preset FE/t limit) |
| `CUT POWER / RESTORE` | Toggle power manually (Balanced: also forces Suspended / re-evaluates state) |
| `PAY NOW (X.XXXX LC)` | Periodic only — pay current period immediately |

> **Balanced meters** show a reduced button set — `[TEMP]`, `CHANGE TYPE`, `SET EXPORT CAP`, and `CUT POWER / RESTORE`. There's no `CHANGE PLAN` since Balanced meters are always billed PAYG.

---

## Status Vocabulary (Admin Panel & Pocket Monitor)

The admin panel and pocket computer show every meter's live status using one unified, plain-text vocabulary — no brackets, no generic ON/OFF — regardless of whether it's a Consumer, Producer, or Balanced meter:

| Status | Meaning |
|---|---|
| `BUY` | Powered on and currently buying/drawing power from the grid (Consumer, or a Balanced meter mid-buy) |
| `SELL` | Powered on and currently selling/exporting power to the grid (Producer, or a Balanced meter mid-sell) |
| `IDLE` | Powered on but not currently trading (Balanced meter sitting between buy/sell thresholds) |
| `SUSPENDED` | Power is cut **and** the customer owes money (balance ≤ 0) — they can't restore it themselves until they top up |
| `ISOLATED` | Power is cut but the customer is in good standing (balance > 0) — they cut it themselves (or it was cut on their behalf) and can simply press `RESTORE` any time, no payment needed |

The meter's own on-screen display keeps its existing wording (`POWER ON`, `EXPORTING TO GRID`, `BUYING FROM GRID`, etc.), but uses the same SUSPENDED-vs-ISOLATED distinction under the hood — a customer who has cut their own power with a healthy balance is told to tap `RESTORE` to reconnect, not to top up.

---

## Admin Panel Features

All numerical entry (`SET RATE`, `SET CAP`) is done via an on-screen touch keypad — no physical keyboard required, consistent with the monitor's touch-driven interface.

### Dashboard
- Live generation, total draw, and surplus for the whole network
- **Company balance** — running total of all LC collected from consumers/buyers minus all LC paid out to producers/sellers (i.e. the operator's net profit, normally the 25% margin between the buy and sell rates)
- Per-meter table: name, plan, balance, draw/export rate, cap, live status (`BUY`/`SELL`/`IDLE`/`SUSPENDED`/`ISOLATED` — see [Status Vocabulary](#status-vocabulary-admin-panel--pocket-monitor)), and a type tag `[P]`/`[C]`/`[B]`
- Balanced meters (`[B]`) show their buffer % in place of a fixed plan/type
- Click any row to open the customer detail screen

### Customer Detail Screen
| Control | Function |
|---|---|
| `CUT POWER / RESTORE` | Cut or restore this meter's power |
| `+500 LC` | Add 500 LC to balance |
| `SET CAP` | Enter a new admin-controlled rate cap on the on-screen keypad (or tap UNLIMITED) |
| `RENAME` | Change the player name on this meter |
| `CHG PLAN` | Toggle billing plan (PAYG ↔ Periodic) |
| `UPDATE` | Push a remote update to this meter |
| `CHANGE TYPE` | Opens a picker listing **Consumer / Producer / Balanced** — pick a different type and confirm to switch remotely |

- For periodic consumers: shows live period cost and next billing countdown
- Player is whispered via Chat Box on power cut/restore and low balance (if Chat Box is attached)

### Global Controls
| Button | Function |
|---|---|
| `DASHBOARD` | Return to meter list |
| `ALERTS` | View event log (power cuts, low balances, etc.) |
| `SET RATE` | Enter a new global LC/FE rate on the on-screen keypad and broadcast it to all meters |
| `UPD METERS` | Send remote update command to all meters |
| `CUT ALL / RESTORE ALL` | Cut or restore every meter at once |

---

## Pocket Monitor Features

Runs on an Advanced Pocket Computer with an Ender Modem.

- **List screen** — company balance (operator's net profit), all meters with online status and a live status indicator (`BUY`/`SELL`/`IDLE`/`SUSPENDED`/`ISOLATED` — see [Status Vocabulary](#status-vocabulary-admin-panel--pocket-monitor))
- **Detail screen** — balance, draw/export, plan, type, period cost, countdown, and the same live status bar
- Per-meter actions: CUT/RESTORE, +500 LC, +100 LC, SET CAP (keyboard entry), UPDATE METER, RENAME, CHG PLAN, CHANGE TYPE (Consumer/Producer/Balanced picker)
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
| `setplan` | `"payg"` or `"periodic"` | Change billing plan (ignored by Balanced meters — always PAYG) |
| `settype` | `"producer"`, `"consumer"`, or `"balanced"` | Change connection type — handles every transition, including switching to/from Balanced (settles outstanding periodic usage and sets up/tears down buffer detection as needed) |
| `setname` | string | Rename the meter |
| `setcap` | number | Set the admin-controlled import (consumer-side) FE/t rate cap — producers manage their own export cap locally |
| `update` | — | Download latest version and reboot |

Commands can target a specific meter by `id` (computer ID) or use `"all"` to broadcast.

---

## Versions

| File | Current Version |
|---|---|
| meter.lua | 3.16 |
| admin.lua | 3.10 |
| pocket.lua | 2.19 |
| setup.lua | — |
