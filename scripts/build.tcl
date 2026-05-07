# =============================================================================
# build.tcl - Vivado non-project flow build script for the
#             Smart Threat Detection system on Zybo Z7-10.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/build.tcl
# Output:
#   build/threat_system.bit
# =============================================================================

set part   "xc7z010clg400-1"
set top    "top_threat_system"
set outdir "build"

file mkdir $outdir

# -----------------------------------------------------------------------------
# Source list - explicitly ordered so packages are analyzed first.
# -----------------------------------------------------------------------------
set rtl_files {
    src/rtl/oled/oled_init_rom.vhd
    src/rtl/oled/font_5x8_rom.vhd

    src/rtl/sensors/contact_pkg.vhd
    src/rtl/hdmi/font_render_pkg.vhd

    src/rtl/common/synchronizer.vhd
    src/rtl/common/debouncer.vhd
    src/rtl/common/pulse_gen.vhd
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

# -----------------------------------------------------------------------------
# Synthesis + implementation
# -----------------------------------------------------------------------------
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
