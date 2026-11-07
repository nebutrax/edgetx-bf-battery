# EdgeTX BF Battery

Two EdgeTX Lua scripts for black-and-white 128×64 radios (RadioMaster Boxer etc.) flying Betaflight quads over ExpressLRS / Crossfire:

- **BF Battery** (`BFBatt.lua`, Tools script): switch Betaflight battery cell-voltage thresholds between **LiPo / LiHV / Li-ion** from the radio, over MSP-over-CRSF. No Configurator needed.
- **Low Battery Alarm** (`lowbat.lua`, telemetry script): per-cell low-voltage alarm with a short hold delay to ignore throttle sag, active only while armed. Also shows the GPS satellite count.

## Install

Copy the `SCRIPTS` folder to the root of the radio's SD card:

```
/SCRIPTS/TOOLS/BFBatt.lua
/SCRIPTS/TELEMETRY/lowbat.lua
```

Then enable the alarm: **MODEL → DISPLAY → Screen 1 → Script → lowbat**. Telemetry scripts only run in the background once they are assigned to a screen.

### Betaflight: send per-cell voltage

The alarm expects a **per-cell** voltage. By default Betaflight sends the total pack voltage in the CRSF battery sensor (**RxBt** on the radio). Switch it to the average cell voltage in the Betaflight CLI:

```
set report_cell_voltage = ON
save
```

Then go to **MODEL → TELEMETRY → Discover new sensors** on the radio. RxBt should now read about 3.5–4.35 V instead of the pack voltage.

### Betaflight: force the cell count

Betaflight guesses the cell count from the pack voltage when you plug in. The guess can be wrong, for example with a half-discharged pack, a storage-charged pack or a fully charged LiHV. A wrong count makes the per-cell voltage (and so every warning) wrong. If you always fly the same cell count, fix it:

```
get force_battery_cell_count
set force_battery_cell_count = 1
save
```

Use your pack's cell count (1 for 1S, 4 for 4S…). `0` restores auto-detection. If `get` returns nothing, your Betaflight version doesn't have this setting.

CRSF sends this value in 0.1 V steps, so the alarm sees, for example, 3.4 / 3.5 / 3.6 V. Thresholds like 3.45 are effectively rounded.

When updating, delete any old `.luac` files next to the scripts so the radio doesn't keep running the previously compiled version.

## BF Battery (Tools)

**SYS → Tools → BF Battery**. The quad must be powered, linked with telemetry on, and **disarmed**.

| Profile | min | warn | max |
|---|---|---|---|
| LiPo   | 3.30 | 3.50 | 4.30 |
| LiHV   | 3.40 | 3.60 | 4.35 |
| Li-ion | 2.90 | 3.10 | 4.20 |

- Scroll to a profile and press **ENTER** to write it to Betaflight. The script saves to EEPROM, reads the values back to check them, then stores min/warn in **GV8/GV9** for the alarm.
- `FC x/y/z` shows what Betaflight currently has. `*` marks the matching profile.
- `R x.xx` is the radio-side alarm threshold (GV9). On open, if Betaflight's warn/min differ from GV9/GV8 (for example after a change in Configurator), they are copied to the radio and the status line shows `R synced to FC`.
- On open, the script also reads Betaflight's GPS Rescue minimum satellites (`gps_rescue_min_sats`) and stores it in **GV7**. The status line then shows `Sats>=8`. If the FC has no GPS Rescue, this step is skipped.
- **Settings >** lets you edit the profile voltages and the alarm options. Pressing RTN saves them to `/SCRIPTS/BFBatt.cfg`. After editing voltages, re-apply the profile.

The bottom-right corner shows the link status while the script waits for the quad:

| Shown | Meaning |
|---|---|
| `noCRSF` | No CRSF/ELRS module active on this model |
| `noTLM` | No telemetry from the quad |
| `t3` | Waiting for the reply to attempt 3 |
| `t3b` | Radio output buffer busy |

Requires Betaflight 4.0 or newer.

## Low Battery Alarm (telemetry)

- Reads a per-cell voltage sensor (RxBt by default, or Auto picks the first of Cels / Cell / VCel / RxBt). A multi-cell sensor uses its lowest cell.
- **Warn** (below GV9 for the hold time): one beep, plus vibration, repeated every 5 s.
- **Critical** (below GV8 for the hold time): three quick beeps every 1 s.
- **Hold delay** 0.5 s by default, adjustable in 0.1 s steps, so short sag under high throttle doesn't trigger the alarm.
- Only active while the arm switch is on (default **SA down**). It can also be set to "Always".
- Settings are reloaded each time the quad connects.
- **FC check:** once per connection, about 2 s after the quad links and only while disarmed, the script reads Betaflight's battery thresholds and updates GV8/GV9 if they differ. The header shows `FC check...`, then `FC synced`, or `FC no reply` after 5 tries. If you arm first, it waits until you disarm. Nothing is sent while armed.
- On the telemetry screen, **ENTER** plays a test beep.
- **Sats** shows the GPS satellite count:
  - `Sats 9 OK`: at or above the minimum.
  - `Sats 4<8`: below the minimum, shown inverted.
  - `Sats --`: no GPS sensor.

  The minimum is Betaflight's `gps_rescue_min_sats`, read by BF Battery into GV7. Open BF Battery once per model with the quad connected; the value is stored per model. Until then the minimum is 6.

Until a profile has been applied, the alarm uses 3.50 / 3.30 V. If you already use GV7/GV8/GV9 for something else, change `GV_SATS` / `GV_MIN` / `GV_WARN` in both scripts.

## Notes

- ELRS module settings (packet rate, telemetry ratio, bind phrase) live in the module itself and are not part of these scripts.
- Tested on a RadioMaster Boxer with EdgeTX and ELRS.

## License

MIT
