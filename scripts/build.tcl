# build.tcl
#   Non-project Vivado build for the Zybo Z7-10. Reads the VHDL
#   sources, generates the two IP-Catalog cores we use (Clocking
#   Wizard for the HDMI/sys MMCM and Block Memory Generator for the
#   strip-chart history buffer), runs synth + impl, and writes the
#   bitstream. Run from the repo root with:
#       vivado -mode batch -source scripts/build.tcl

set part   "xc7z010clg400-1"
set top    "top_threat_system"
set outdir "build"
set ipdir  "$outdir/ip"

file mkdir $outdir
file mkdir $ipdir

# Use a dummy in-memory project so the IP catalog and synth_ip work.
create_project -in_memory -part $part
set_property target_language VHDL [current_project]

# -----------------------------------------------------------------
# IP catalog instances. Generated on the fly so no .xci is committed.
# -----------------------------------------------------------------

# Clocking Wizard: 125 MHz in -> 25 MHz pixel, 125 MHz serial,
# 125 MHz sys. CLKOUT serial / CLKOUT pixel are a synchronous 5:1
# pair (required by OSERDESE2 in the TMDS serializer).
puts "INFO: generating Clocking Wizard IP (clk_wiz_hdmi_ip)"
create_ip -name clk_wiz -vendor xilinx.com -library ip \
          -module_name clk_wiz_hdmi_ip -dir $ipdir
set_property -dict {
    CONFIG.PRIM_IN_FREQ                {125.000}
    CONFIG.PRIM_SOURCE                 {Single_ended_clock_capable_pin}
    CONFIG.NUM_OUT_CLKS                {3}
    CONFIG.CLKOUT1_USED                {true}
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ  {25.000}
    CONFIG.CLKOUT2_USED                {true}
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ  {125.000}
    CONFIG.CLKOUT3_USED                {true}
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ  {125.000}
    CONFIG.CLKIN1_JITTER_PS            {80.0}
    CONFIG.RESET_TYPE                  {ACTIVE_HIGH}
    CONFIG.RESET_PORT                  {reset}
    CONFIG.MMCM_CLKFBOUT_MULT_F        {8.000}
    CONFIG.MMCM_CLKOUT0_DIVIDE_F       {40.000}
    CONFIG.MMCM_CLKOUT1_DIVIDE         {8}
    CONFIG.MMCM_CLKOUT2_DIVIDE         {8}
    CONFIG.USE_LOCKED                  {true}
} [get_ips clk_wiz_hdmi_ip]
generate_target {synthesis simulation} [get_ips clk_wiz_hdmi_ip]
synth_ip [get_ips clk_wiz_hdmi_ip]

# Block Memory Generator: 640 x 32 simple dual-port for the strip
# chart history buffer. Port A write-only, Port B read-only, no
# init file, 1-cycle read latency.
puts "INFO: generating Block Memory Generator IP (history_bram_ip)"
create_ip -name blk_mem_gen -vendor xilinx.com -library ip \
          -module_name history_bram_ip -dir $ipdir
set_property -dict {
    CONFIG.Memory_Type                 {Simple_Dual_Port_RAM}
    CONFIG.Use_Byte_Write_Enable       {false}
    CONFIG.Write_Width_A               {32}
    CONFIG.Write_Depth_A               {640}
    CONFIG.Read_Width_A                {32}
    CONFIG.Operating_Mode_A            {WRITE_FIRST}
    CONFIG.Write_Width_B               {32}
    CONFIG.Read_Width_B                {32}
    CONFIG.Operating_Mode_B            {READ_FIRST}
    CONFIG.Enable_A                    {Always_Enabled}
    CONFIG.Enable_B                    {Always_Enabled}
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false}
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false}
    CONFIG.Use_RSTA_Pin                {false}
    CONFIG.Use_RSTB_Pin                {false}
    CONFIG.Load_Init_File              {false}
} [get_ips history_bram_ip]
generate_target {synthesis simulation} [get_ips history_bram_ip]
synth_ip [get_ips history_bram_ip]

# -----------------------------------------------------------------
# RTL sources. Order matters so packages compile first.
# -----------------------------------------------------------------
set rtl_files {
    src/rtl/oled/oled_init_rom.vhd
    src/rtl/oled/font_5x8_rom.vhd

    src/rtl/sensors/contact_pkg.vhd
    src/rtl/hdmi/font_render_pkg.vhd

    src/rtl/common/synchronizer.vhd
    src/rtl/common/synchronizer_rst.vhd
    src/rtl/common/debouncer.vhd
    src/rtl/common/clock_div.vhd
    src/rtl/common/moving_average8.vhd
    src/rtl/common/system_clock.vhd

    src/rtl/sensors/pmod_als_spi.vhd
    src/rtl/sensors/pmod_maxsonar_pw.vhd
    src/rtl/sensors/ambient_mode_detect.vhd
    src/rtl/sensors/threshold_detect.vhd
    src/rtl/sensors/contact_log.vhd

    src/rtl/fsm/threat_fsm.vhd

    src/rtl/oled/oled_spi_master.vhd
    src/rtl/oled/oled_framebuffer.vhd
    src/rtl/oled/pmod_oled_top.vhd

    src/rtl/hdmi/clk_wiz_hdmi.vhd
    src/rtl/hdmi/vga_timing_640x480.vhd
    src/rtl/hdmi/history_buffer.vhd
    src/rtl/hdmi/risk_banner_renderer.vhd
    src/rtl/hdmi/risk_matrix_renderer.vhd
    src/rtl/hdmi/strip_chart_renderer.vhd
    src/rtl/hdmi/event_log_renderer.vhd
    src/rtl/hdmi/console_renderer.vhd
    src/rtl/hdmi/tmds_encoder.vhd
    src/rtl/hdmi/tmds_serializer.vhd
    src/rtl/hdmi/hdmi_top.vhd

    src/rtl/top_threat_system.vhd
}

puts "INFO: reading [llength $rtl_files] VHDL sources"
foreach f $rtl_files {
    if { ! [file exists $f] } {
        puts "ERROR: source not found: $f"
        exit 1
    }
    puts "       $f"
    read_vhdl -vhdl2008 $f
}

read_xdc xdc/zybo_z7_10.xdc

# -----------------------------------------------------------------
# Synthesis + implementation
# -----------------------------------------------------------------
synth_design -top $top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force $outdir/post_synth.dcp
report_utilization        -file $outdir/post_synth_util.rpt
report_timing_summary     -file $outdir/post_synth_timing.rpt

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $outdir/post_route.dcp
report_utilization     -file $outdir/post_route_util.rpt
report_timing_summary  -file $outdir/post_route_timing.rpt
report_drc             -file $outdir/post_route_drc.rpt

write_bitstream -force $outdir/threat_system.bit
puts "INFO: wrote $outdir/threat_system.bit"

exit 0
