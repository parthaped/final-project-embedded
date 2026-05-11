# create_project.tcl
#   Project-mode counterpart to build.tcl. Creates a real Vivado project
#   (with Flow Navigator) on the Zybo Z7-10, adds every RTL source, the
#   simulation testbenches, the XDC, and generates the two IPs we need
#   (Clocking Wizard + Block Memory Generator).
#
#   From the repo root, in a shell:
#       vivado -mode gui -source scripts/create_project.tcl
#
#   Or from the Vivado Tcl console (with no project open):
#       cd <repo-root>
#       source scripts/create_project.tcl
#
#   The project is written to ./vivado_project/threat_system.xpr.

set part     "xc7z010clg400-1"
set top      "top_threat_system"
set proj_dir "vivado_project"
set proj     "threat_system"
set ipdir    "$proj_dir/$proj.srcs/sources_1/ip"

# Refuse to clobber an existing project silently.
if { [file exists "$proj_dir/$proj.xpr"] } {
    puts "ERROR: $proj_dir/$proj.xpr already exists. Delete the"
    puts "       $proj_dir folder (or pick a new name) and rerun."
    return
}

file mkdir $proj_dir

create_project $proj $proj_dir -part $part -force
set_property target_language   VHDL   [current_project]
set_property simulator_language VHDL   [current_project]
set_property default_lib       xil_defaultlib [current_project]

# -----------------------------------------------------------------
# RTL sources. Order matters at compile-order time (packages first);
# we explicitly run update_compile_order at the end to let Vivado
# resolve the dependency graph.
# -----------------------------------------------------------------
set rtl_files [list \
    src/rtl/oled/oled_init_rom.vhd \
    src/rtl/oled/font_5x8_rom.vhd \
    src/rtl/sensors/contact_pkg.vhd \
    src/rtl/hdmi/font_render_pkg.vhd \
    src/rtl/common/synchronizer.vhd \
    src/rtl/common/synchronizer_rst.vhd \
    src/rtl/common/debouncer.vhd \
    src/rtl/common/clock_div.vhd \
    src/rtl/common/moving_average8.vhd \
    src/rtl/common/system_clock.vhd \
    src/rtl/sensors/pmod_als_spi.vhd \
    src/rtl/sensors/pmod_maxsonar_pw.vhd \
    src/rtl/sensors/ambient_mode_detect.vhd \
    src/rtl/sensors/threshold_detect.vhd \
    src/rtl/sensors/contact_log.vhd \
    src/rtl/fsm/threat_fsm.vhd \
    src/rtl/oled/oled_spi_master.vhd \
    src/rtl/oled/oled_framebuffer.vhd \
    src/rtl/oled/pmod_oled_top.vhd \
    src/rtl/hdmi/clk_wiz_hdmi.vhd \
    src/rtl/hdmi/vga_timing_640x480.vhd \
    src/rtl/hdmi/history_buffer.vhd \
    src/rtl/hdmi/risk_banner_renderer.vhd \
    src/rtl/hdmi/risk_matrix_renderer.vhd \
    src/rtl/hdmi/strip_chart_renderer.vhd \
    src/rtl/hdmi/event_log_renderer.vhd \
    src/rtl/hdmi/console_renderer.vhd \
    src/rtl/hdmi/tmds_encoder.vhd \
    src/rtl/hdmi/tmds_serializer.vhd \
    src/rtl/hdmi/hdmi_top.vhd \
    src/rtl/top_threat_system.vhd \
]

foreach f $rtl_files {
    if { ! [file exists $f] } {
        puts "ERROR: source not found: $f"
        return
    }
}

add_files -fileset sources_1 $rtl_files
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sources_1] *.vhd]
set_property library xil_defaultlib [get_files -of_objects [get_filesets sources_1] *.vhd]

# -----------------------------------------------------------------
# Simulation testbenches
# -----------------------------------------------------------------
set sim_files [list \
    src/sim/tb_clock_div.vhd \
    src/sim/tb_synchronizer.vhd \
    src/sim/tb_debouncer.vhd \
    src/sim/tb_moving_average8.vhd \
    src/sim/tb_pmod_als_spi.vhd \
    src/sim/tb_pmod_maxsonar_pw.vhd \
    src/sim/tb_threshold_detect.vhd \
    src/sim/tb_contact_log.vhd \
    src/sim/tb_threat_fsm.vhd \
    src/sim/tb_oled_init.vhd \
]

set sim_existing [list]
foreach f $sim_files {
    if { [file exists $f] } { lappend sim_existing $f }
}
if { [llength $sim_existing] > 0 } {
    add_files -fileset sim_1 $sim_existing
    set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1] *.vhd]
    set_property library xil_defaultlib [get_files -of_objects [get_filesets sim_1] *.vhd]
}

# -----------------------------------------------------------------
# Constraints
# -----------------------------------------------------------------
add_files -fileset constrs_1 xdc/zybo_z7_10.xdc

# -----------------------------------------------------------------
# IP: Clocking Wizard (125 MHz -> 25 MHz pixel + 125 MHz serial +
# 125 MHz sys). Matches build.tcl exactly.
# -----------------------------------------------------------------
puts "INFO: creating Clocking Wizard IP (clk_wiz_hdmi_ip)"
create_ip -name clk_wiz -vendor xilinx.com -library ip \
          -module_name clk_wiz_hdmi_ip
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
generate_target all [get_ips clk_wiz_hdmi_ip]

# -----------------------------------------------------------------
# IP: Block Memory Generator, 640 x 32 simple dual-port for the
# strip-chart history buffer. Matches build.tcl exactly.
# -----------------------------------------------------------------
puts "INFO: creating Block Memory Generator IP (history_bram_ip)"
create_ip -name blk_mem_gen -vendor xilinx.com -library ip \
          -module_name history_bram_ip
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
generate_target all [get_ips history_bram_ip]

# -----------------------------------------------------------------
# Top + compile order
# -----------------------------------------------------------------
set_property top $top [get_filesets sources_1]
update_compile_order -fileset sources_1
if { [llength $sim_existing] > 0 } {
    update_compile_order -fileset sim_1
}

puts "INFO: project created at $proj_dir/$proj.xpr"
puts "INFO: top set to $top"
puts "INFO: Flow Navigator should now show Run Synthesis / Implementation / Generate Bitstream"
