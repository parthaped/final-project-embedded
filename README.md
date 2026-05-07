# After-Hours Perimeter Monitor — Zybo (xc7z010clg400-1)

A pure-VHDL FPGA system that watches a single corridor or doorway with an
ultrasonic rangefinder, contextualises every detection by the surrounding
ambient light, and presents the result as a live surveillance console on
HDMI plus a compact status panel on a Pmod OLED.

The original "smart threat detector" has been promoted to a small but
legitimate **perimeter monitor**: presence on its own is not a threat,
but presence in the dark, or after hours, is.  Severity is a function of
*who is here* (sonar) **and** *what time it is* (ambient light).

## What the board is doing

* Reads a Pmod ALS (ambient light) and a Pmod MAXSONAR (ultrasonic
  rangefinder, in PW mode), each through its own moving-average filter.
* Maps the ALS reading into one of four **ambient modes** with hysteresis:
  `NIGHT`, `DIM`, `DAY`, `BRIGHT`.
* Compares the filtered range against a runtime-selectable pair of
  thresholds (`near` / `warn`) to classify the sonar band.
* Combines `(sonar band, ambient mode)` combinationally into a 2-bit
  **severity** (`LOW`, `MED`, `HIGH`, `CRIT`).
* Runs a **non-sticky** linear FSM
  `Idle -> Monitor -> Candidate -> Verify -> S_Contact -> S_Cooldown -> Monitor`.
  The FSM does not "hold the alert"; instead, the moment the candidate
  is confirmed it emits a one-cycle `log_pulse` and the live severity is
  captured into a **contact log** (8-slot register file, newest-first
  eviction, age-based invalidation).
* Renders an information-rich console over HDMI (640x480, DVI mode) that
  shows the full severity model, a 10-second strip-chart history of both
  sensors with thresholds and event ticks overlaid, and a scrolling
  6-row event log of past intrusions with timestamps and severity tints.
* Drives a Pmod OLED as a compact secondary status panel (state /
  ambient mode + contact count / last contact / severity + sensitivity).

The design is **pure PL** — no Zynq PS, no AXI, no MicroBlaze, no DDR.
The only Xilinx primitives used are `MMCME2_BASE`, `IBUFG`, `BUFG`,
`OSERDESE2`, `OBUFDS`, plus a small `RAMB36` inferred from the history
buffer.

## Hardware setup

### Pmod placement (Zybo Rev B)

| Pmod        | Connector              | Notes                                                     |
| ----------- | ---------------------- | --------------------------------------------------------- |
| OLED        | `JB` (12-pin)          | All 8 signal pins (CS, MOSI, SCK, DC, RES, VBATC, VDDC).  |
| ALS         | `JC` top row (1..6)    | 6-pin SPI (CS, MISO, SCK).                                |
| MAXSONAR    | `JE` top row (1..6)    | PW mode.  PW (Pmod pin 4) lands on JE4 = `H15`; RX (Pmod pin 2) is driven high on JE2 = `W16` so the MB1010 stays in free-run ranging mode.  Originally placed on `JD` but moved to `JE` because `JD` is a high-speed Pmod with no series protection resistors and its top-row trace appeared damaged.  `JE` has 200-ohm series resistors — safe and plenty fast for the slow PW signal. |

### Buttons / switches / LEDs

| Control | Pin       | Function                                              |
| ------- | --------- | ----------------------------------------------------- |
| `BTN0`  | start     | Issues an FSM `start` pulse (one-shot).               |
| `BTN3`  | reset     | Issues an FSM `reset` pulse (one-shot).               |
| `SW0`   | arm       | High = system armed (FSM leaves IDLE on `start`).     |
| `SW1`   | sens      | `0` = standard thresholds (24 / 48 in), `1` = paranoid (36 / 72 in). |
| `SW2`   | clear     | Drains the contact log on rising edge / while held.   |
| `SW3`   | inject    | Demo mode: synthesises one fake contact per second, walking through `(LOW, MED, HIGH, CRIT)`. |
| `LD0`   | ARM       | Lit when armed AND not parked in IDLE.                |
| `LD1`   | AMBIENT   | Lit while ambient mode is `NIGHT` or `DIM`.           |
| `LD2`   | CONTACT   | Lit while the contact log has at least one valid entry. |
| `LD3`   | ALERT/HB  | Blinks ~2 Hz during cooldown; otherwise echoes the raw sonar PW heartbeat (a useful "is the sensor alive?" indicator). |

### Monitor

Any HDMI display.  The design holds HPD high and runs in 640x480@60 Hz
DVI mode, so EDID-less monitors lock immediately.

## Clock tree

The 125 MHz on-board oscillator (`sysclk`) feeds an `MMCME2_BASE` that
generates three phase-aligned clocks:

| Clock        | Freq.    | Purpose                                                    |
| ------------ | -------- | ---------------------------------------------------------- |
| `clk_sys`    | 125 MHz  | sensors, FSM, contact log, OLED, system clock.             |
| `clk_pixel`  |  25 MHz  | VGA timing, console renderer, TMDS encoders, history buf.  |
| `clk_serial` | 125 MHz  | OSERDESE2 high-speed input (5x pixel, 10:1 DDR).           |

`clk_pixel` and `clk_serial` are kept synchronous (CLKDIV / CLK pair into
each `OSERDESE2`).  `clk_sys` is treated as asynchronous to the HDMI pair;
all sys-to-pixel crossings (range, ALS, ambient mode, severity, presence,
arm, near/warn thresholds, contact array, t_seconds) go through 2-stage
`ASYNC_REG` synchronisers.  The single-cycle FSM `log_pulse` crosses
through a toggle handshake.

## FSM (non-sticky)

```
            start (BTN0) +  arm (SW0)
        Idle ------------------------> Monitor
                                          |
                                          | trig
                                          v
                                      Candidate
                                          | T_DWELL expires
                                          v
                                       Verify
                                          | trig still asserted
                                          v
                                     S_Contact   --(log_pulse 1 cycle,
                                          |       contact_log captures
                                          |       severity_now)
                                          v
                                    S_Cooldown
                                          | T_COOLDOWN expires
                                          v
                                       Monitor
```

`reset` (BTN3) and `clear` (SW2) both unwind any in-flight contact and
drain the log.  The FSM never sits in an "ALERT" state — every contact
becomes a *record* in the contact log instead, with its own timestamp,
range, ambient mode, and severity captured at the moment of detection.

## Severity model

`severity_now` is a combinational function of `(sonar band, ambient mode)`:

| Sonar band → / Ambient ↓ | warn (= near..warn in) | alert (< near in) |
| ------------------------ | ---------------------- | ----------------- |
| `BRIGHT` (very lit)      | `LOW`                  | `CRIT`            |
| `DAY`    (normal day)    | `LOW`                  | `LOW`             |
| `DIM`    (dusk / late)   | `LOW`                  | `MED`             |
| `NIGHT`  (lights off)    | `LOW`                  | `HIGH`            |

The intuition: presence in the dark or in unexpected lighting is the
threatening case.  Bright + close (e.g. someone holding a flashlight to
the sensor) is treated as a tampering signature and gets the highest
severity.  Plain presence under daylight is the lowest severity.  The
`warn` band only escalates above `LOW` once the room is also dark.

## Ambient mode (with hysteresis)

The 8-bit ALS byte is mapped through hysteresis to a 2-bit
`ambient_mode`.  Bands and hysteresis margins are picked so the mode
does not chatter when the lighting hovers near a band edge:

| Mode      | ALS byte (typical) |
| --------- | ------------------ |
| `NIGHT`   | < 12               |
| `DIM`     | 12 ..  60          |
| `DAY`     | 60 .. 200          |
| `BRIGHT`  | > 200              |

`ambient_mode` is consumed by `threshold_detect`, the OLED panel, the
HDMI console (background tint, risk matrix, strip-chart bands), and
LD1.

## Console layout (HDMI)

```
+--------------------------------------------------------------+
| HEADER strip:  PERIMETER MONITOR    T+MM:SS    SW0..SW3      |
+----------------------+---------------------------------------+
|                      |                                       |
|   RISK BANNER        |   RISK MATRIX (4 ambient x 2 presence)|
|   (giant SAFE/LOW/   |                                       |
|    MED/HIGH/CRIT)    |   live cell highlighted               |
|                      |                                       |
|   PRESENCE: YES NN IN|                                       |
|   LIGHT: NIGHT  XXX  |                                       |
+----------------------+---------------------------------------+
|   STRIP CHART (10 s history, dual trace)                     |
|     top half : range vs time (with NEAR / WARN bands)        |
|     bottom   : ALS  vs time (with ambient-mode bands)        |
|     event ticks : severity-coloured                          |
+--------------------------------------------------------------+
|   EVENT LOG (6 rows, severity-tinted backgrounds)            |
|     T-MM:SS  RNG  IN  LIGHT  SEV                             |
+--------------------------------------------------------------+
```

* The whole frame is overlaid with a screen border whose colour follows
  the live severity.  The border only lights up while presence is asserted.
* The background colour of the empty regions is a low-alpha tint of the
  current ambient mode — at a glance the operator sees whether the room
  is dark or lit, even before reading anything.

## OLED layout (Pmod, 128x32)

```
STATE: monitor
MODE: NIGHT  C:3
LAST: 014 IN T-007 S
SEV: HIGH    LIM:24
```

Line 1: current FSM state (`idle/monitor/candidat/verify/contact/cooldown`).
Line 2: ambient mode and contact-log count.
Line 3: last contact's range and age (seconds since logged).
Line 4: last contact's severity and the live `near` threshold.

## Build

```powershell
# from the repo root, with Vivado 2020.x or newer in PATH
vivado -mode batch -source scripts/build.tcl
# bitstream lands at:
#   build/threat_system.bit
```

## Simulate

```powershell
vivado -mode batch -source scripts/sim.tcl
```

`scripts/sim.tcl` runs every testbench under `src/sim/` with `xvhdl` /
`xelab` / `xsim`.  Notable testbenches:

* `tb_threshold_detect` — exhaustively walks `(sonar band, ambient mode)`
  to verify the severity table and the FSM trigger.
* `tb_threat_fsm` — verifies the non-sticky linear path, log-pulse
  generation, and cooldown behaviour.
* `tb_contact_log` — single writes, full-fill eviction, clear, and
  age-based invalidation.

## Source layout

```
src/rtl/
  top_threat_system.vhd
  common/      synchronizer, debouncer, pulse_gen, moving_average8,
               system_clock
  sensors/     contact_pkg, pmod_als_spi, pmod_maxsonar_pw,
               ambient_mode_detect, threshold_detect, contact_log
  fsm/         threat_fsm
  oled/        pmod_oled_top, oled_spi_master, oled_init_rom,
               oled_framebuffer, font_5x8_rom
  hdmi/        hdmi_top, clk_wiz_hdmi, vga_timing_640x480,
               history_buffer, font_render_pkg,
               risk_banner_renderer, risk_matrix_renderer,
               strip_chart_renderer, event_log_renderer,
               console_renderer,
               tmds_encoder, tmds_serializer
src/sim/       testbenches (one per leaf block)
xdc/           zybo_z7_10.xdc (pin map + CDC clock-group constraints)
scripts/       build.tcl, sim.tcl
```

## Demo flow

1. Power-up: with `SW0..SW3` low, the board comes up in IDLE and the
   console shows `RISK: SAFE` over a daylight-tinted background.
2. Flip `SW0` (arm), press `BTN0` (start).  FSM enters MONITOR and the
   `T+` timer in the header begins counting.
3. Wave a hand in front of the sonar.  The strip-chart range trace dips
   below the `NEAR` band, the FSM walks `Candidate -> Verify -> S_Contact`,
   a one-cycle `log_pulse` fires, and a new event row appears at the top
   of the event log with severity and timestamp.
4. Cover the ALS to step the ambient mode through `DAY -> DIM -> NIGHT`.
   The risk matrix's highlighted cell follows in real time and the
   severity of the next contact escalates accordingly.
5. Flip `SW3` to inject a synthetic contact every second walking through
   the entire severity table (`LOW -> MED -> HIGH -> CRIT`) — useful for
   demoing the console without choreographing a person in front of the
   sensor.
6. Flip `SW2` to drain the log.

## Phase milestones (independently testable)

1. **Sensors only** — LEDs follow the filtered ALS / sonar.
2. **+ Ambient + Threshold** — `severity_now` table verified in sim.
3. **+ FSM**       — LEDs walk `Idle / Monitor / Candidate / Verify / Contact / Cooldown`.
4. **+ Contact log** — OLED `LAST` line populates and ages out.
5. **+ HDMI console** — Risk banner, matrix, strip chart, and event log
   light up.  Severity border tracks live presence.
6. **Final**       — All clock domains, full system integration.

Each phase compiles and runs independently; the build script always
produces a valid bitstream after every step.
