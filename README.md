# Smart Threat Detection & Situational Awareness — Zybo Z7-10

A pure-VHDL FPGA system for the Digilent Zybo Z7-10 (Xilinx `xc7z010clg400-1`)
that:

1. Reads a Pmod ALS (ambient light) and Pmod MAXSONAR (ultrasonic distance,
   in PW mode).
2. Runs a six-state FSM:
   `Idle -> Monitor -> Candidate -> Verify -> {Alert | Classify} -> Monitor`.
3. Reports state and live sensor values on a Pmod OLED (SSD1306, 128x32).
4. Drives the on-board HDMI TX port with a 640x480 polar-radar visualization
   (rings, rotating sweep, target dot whose position tracks the live distance
   reading).
5. Uses on-board LEDs and buttons for state indication and `start`/`reset`.

The design is **pure PL** — no Zynq PS, no AXI, no MicroBlaze, no DDR.  The
only Xilinx primitives used are `MMCME2_BASE`, `IBUFG`, `BUFG`, `OSERDESE2`,
`OBUFDS`.

## Hardware setup

### Pmod placement

| Pmod        | Connector              | Notes                                                     |
| ----------- | ---------------------- | --------------------------------------------------------- |
| OLED        | `JB` (12-pin)          | Needs all 8 signal pins (CS, MOSI, SCK, DC, RES, VBATC, VDDC). |
| ALS         | `JC` top row (1..6)    | 6-pin SPI (CS, MISO, SCK).                                |
| MAXSONAR    | `JC` bottom row (7..12) | PW mode (pin 9 of the lower row).                        |

### Buttons / LEDs

- `BTN0` -> FSM `start`
- `BTN3` -> FSM `reset`
- `LD0` lit in `Idle`,
  `LD1` lit in `Monitor` and `Candidate`,
  `LD2` lit in `Verify` and `Classify`,
  `LD3` blinks in `Alert` (~2 Hz).

### Monitor

Connect any HDMI display to the on-board HDMI TX port.  The design drives
HPD high so EDID-less monitors will lock at 640x480@60Hz in DVI mode.

## Clock tree

The 125 MHz on-board oscillator (`sysclk`) feeds an `MMCME2_BASE` that
generates three phase-aligned clocks:

| Clock        | Freq.    | Purpose                                       |
| ------------ | -------- | --------------------------------------------- |
| `clk_sys`    | 125 MHz  | sensors, FSM, OLED, threshold logic           |
| `clk_pixel`  |  25 MHz  | VGA timing, radar renderer, TMDS encoders     |
| `clk_serial` | 125 MHz  | OSERDESE2 high-speed input (5x pixel for 10:1 DDR) |

`clk_sys` and `clk_pixel` are treated as asynchronous.  Sensor values cross
the boundary through a 2-stage `ASYNC_REG` synchroniser (multi-bit sync is
safe because the values change roughly every 1..50 ms versus a 25 MHz
sample rate).

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
`xelab` / `xsim`.  `tb_radar_renderer` produces `build/sim/radar.ppm`,
which can be viewed in any image tool (GIMP, IrfanView, online PPM viewers).

## Source layout

```
src/rtl/
  top_threat_system.vhd
  common/      synchronizer, debouncer, pulse_gen, moving_average8
  sensors/     pmod_als_spi, pmod_maxsonar_pw, threshold_detect
  fsm/         threat_fsm
  oled/        pmod_oled_top, oled_spi_master, oled_init_rom,
               oled_framebuffer, font_5x8_rom
  hdmi/        hdmi_top, clk_wiz_hdmi, vga_timing_640x480,
               tmds_encoder, tmds_serializer, radar_renderer
src/sim/       testbenches (one per leaf block + tb_radar_renderer)
xdc/           zybo_z7_10.xdc (pin map + CDC clock-group constraint)
scripts/       build.tcl, sim.tcl
```

## FSM transitions

```
                     start (BTN0)
        Idle  ----------------->  Monitor
                                    |
                              trig  | (sonar < 24 in or
                                    |  ALS too dark / too bright)
                                    v
                                Candidate
                                    | T = 100 ms dwell expires
                                    v
                                  Verify
                                  /     \
                              ok /       \ conf
                                /         \
                          Classify        Alert
                                |           ^
                          T = 100 ms        | reset (BTN3)
                                v           |
                              Alert  -------+
```

* `trig` = `(distance < SONAR_NEAR_TH)` OR ALS outside `[ALS_DARK_TH, ALS_BRIGHT_TH]`
* `ok`   = both sonar AND ALS still triggered (multi-sensor agreement)
* `conf` = sonar triggered, ALS not (single-sensor confirm)

## Phase milestones (independently testable)

1. **Sensors only** — light LEDs from filtered ALS / sonar values.
2. **+ FSM**       — LEDs walk through `Idle / Monitor / Verify / Alert`.
3. **+ OLED**      — SSD1306 shows live `STATE / DIST / LUX / SEV` strings.
4. **+ HDMI**      — Monitor shows the radar grid, sweep, and target dot.
5. **Final**       — All clock domains, full system integration.

Each phase compiles and runs independently; the build script always
produces a valid bitstream after every step.
