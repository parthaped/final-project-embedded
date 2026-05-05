# =============================================================================
# Zybo Z7-10 (xc7z010clg400-1) constraints for the Smart Threat Detection
# system.  Only the pins used by this project are uncommented.
#
# Reference: Digilent Zybo Z7 Master XDC.
# =============================================================================

# -----------------------------------------------------------------------------
# 125 MHz on-board clock (PL)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { sysclk }];

# -----------------------------------------------------------------------------
# Buttons (active high)
#   BTN0 -> start, BTN3 -> reset
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports { btn_start  }];   ;# BTN0
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 } [get_ports { btn_reset  }];   ;# BTN3

# -----------------------------------------------------------------------------
# LEDs (LD0..LD3)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }];       ;# LD0
set_property -dict { PACKAGE_PIN M15  IOSTANDARD LVCMOS33 } [get_ports { led[1] }];       ;# LD1
set_property -dict { PACKAGE_PIN G14  IOSTANDARD LVCMOS33 } [get_ports { led[2] }];       ;# LD2
set_property -dict { PACKAGE_PIN D18  IOSTANDARD LVCMOS33 } [get_ports { led[3] }];       ;# LD3

# -----------------------------------------------------------------------------
# Pmod JB (Pmod OLED, SSD1306, 12-pin)
#   JB1=CS  JB2=MOSI JB3=(unused) JB4=SCK
#   JB7=DC  JB8=RES  JB9=VBATC    JB10=VDDC
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V8   IOSTANDARD LVCMOS33 } [get_ports { oled_cs_n  }];   ;# JB1
set_property -dict { PACKAGE_PIN W8   IOSTANDARD LVCMOS33 } [get_ports { oled_mosi  }];   ;# JB2
set_property -dict { PACKAGE_PIN V7   IOSTANDARD LVCMOS33 } [get_ports { oled_sclk  }];   ;# JB4
set_property -dict { PACKAGE_PIN Y7   IOSTANDARD LVCMOS33 } [get_ports { oled_dc    }];   ;# JB7
set_property -dict { PACKAGE_PIN Y6   IOSTANDARD LVCMOS33 } [get_ports { oled_res_n }];   ;# JB8
set_property -dict { PACKAGE_PIN V6   IOSTANDARD LVCMOS33 } [get_ports { oled_vbat_n }];  ;# JB9
set_property -dict { PACKAGE_PIN W6   IOSTANDARD LVCMOS33 } [get_ports { oled_vdd_n }];   ;# JB10

# -----------------------------------------------------------------------------
# Pmod JC top row (Pmod ALS, ADC081S021, 6-pin SPI)
#   JC1=CS  JC3=MISO  JC4=SCK
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 } [get_ports { als_cs_n }];     ;# JC1
set_property -dict { PACKAGE_PIN T11  IOSTANDARD LVCMOS33 } [get_ports { als_miso }];     ;# JC3
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 } [get_ports { als_sclk }];     ;# JC4

# -----------------------------------------------------------------------------
# Pmod JC bottom row (Pmod MAXSONAR, PW mode)
#   JC9 = PW input (pin 3 of the 6-pin Pmod plugged into bottom row)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN T12  IOSTANDARD LVCMOS33 } [get_ports { sonar_pw }];     ;# JC9

# -----------------------------------------------------------------------------
# HDMI TX (source) on bank 35 - TMDS_33
#   D0_P=D19 / D0_N=D20
#   D1_P=C20 / D1_N=B20
#   D2_P=B19 / D2_N=A20
#   CLK_P=H16 / CLK_N=H17
#   HPD =E18 (input from sink, but we drive it to '1' on this design)
#   CEC =E19, SCL=G17, SDA=G18 (left unconnected in this design)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H16  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_clk_p }];
set_property -dict { PACKAGE_PIN H17  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_clk_n }];
set_property -dict { PACKAGE_PIN D19  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[0] }];
set_property -dict { PACKAGE_PIN D20  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[0] }];
set_property -dict { PACKAGE_PIN C20  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[1] }];
set_property -dict { PACKAGE_PIN B20  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[1] }];
set_property -dict { PACKAGE_PIN B19  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[2] }];
set_property -dict { PACKAGE_PIN A20  IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[2] }];
set_property -dict { PACKAGE_PIN E18  IOSTANDARD LVCMOS33 } [get_ports { hdmi_tx_hpd  }];

# -----------------------------------------------------------------------------
# CDC / asynchronous-clock-group constraints
#   The MMCM generates three clocks (clk_sys, clk_pixel, clk_serial).
#   clk_sys and clk_pixel are asynchronous to one another from the
#   point of view of timing analysis (the only crossings are slow-changing
#   data through ASYNC_REG synchronisers).
# -----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_pin] \
    -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ */mmcm_i/CLKOUT0}]] \
    -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ */mmcm_i/CLKOUT1}]] \
    -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ */mmcm_i/CLKOUT2}]]

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
set_property CFGBVS VCCO         [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]
