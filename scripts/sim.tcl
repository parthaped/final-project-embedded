# =============================================================================
# sim.tcl - run every testbench under src/sim using xvhdl/xelab/xsim.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/sim.tcl
# =============================================================================

file mkdir build/sim
cd build/sim

set rtl_files {
    ../../src/rtl/oled/oled_init_rom.vhd
    ../../src/rtl/oled/font_5x8_rom.vhd

    ../../src/rtl/sensors/contact_pkg.vhd
    ../../src/rtl/hdmi/font_render_pkg.vhd

    ../../src/rtl/common/synchronizer.vhd
    ../../src/rtl/common/synchronizer_rst.vhd
    ../../src/rtl/common/debouncer.vhd
    ../../src/rtl/common/clock_div.vhd
    ../../src/rtl/common/moving_average8.vhd
    ../../src/rtl/common/system_clock.vhd

    ../../src/rtl/sensors/pmod_als_spi.vhd
    ../../src/rtl/sensors/pmod_maxsonar_pw.vhd
    ../../src/rtl/sensors/ambient_mode_detect.vhd
    ../../src/rtl/sensors/threshold_detect.vhd
    ../../src/rtl/sensors/contact_log.vhd

    ../../src/rtl/fsm/threat_fsm.vhd

    ../../src/rtl/oled/oled_spi_master.vhd
    ../../src/rtl/oled/oled_framebuffer.vhd
    ../../src/rtl/oled/pmod_oled_top.vhd

    ../../src/rtl/hdmi/clk_wiz_hdmi.vhd
    ../../src/rtl/hdmi/vga_timing_640x480.vhd
    ../../src/rtl/hdmi/history_buffer.vhd
    ../../src/rtl/hdmi/risk_banner_renderer.vhd
    ../../src/rtl/hdmi/risk_matrix_renderer.vhd
    ../../src/rtl/hdmi/strip_chart_renderer.vhd
    ../../src/rtl/hdmi/event_log_renderer.vhd
    ../../src/rtl/hdmi/console_renderer.vhd
    ../../src/rtl/hdmi/tmds_encoder.vhd
    ../../src/rtl/hdmi/tmds_serializer.vhd
    ../../src/rtl/hdmi/hdmi_top.vhd

    ../../src/rtl/top_threat_system.vhd
}

set tb_files {
    ../../src/sim/tb_synchronizer.vhd
    ../../src/sim/tb_debouncer.vhd
    ../../src/sim/tb_clock_div.vhd
    ../../src/sim/tb_moving_average8.vhd
    ../../src/sim/tb_threshold_detect.vhd
    ../../src/sim/tb_pmod_als_spi.vhd
    ../../src/sim/tb_pmod_maxsonar_pw.vhd
    ../../src/sim/tb_threat_fsm.vhd
    ../../src/sim/tb_oled_init.vhd
    ../../src/sim/tb_contact_log.vhd
}

# Compile every RTL + TB source.
foreach f [concat $rtl_files $tb_files] {
    puts "xvhdl -2008 $f"
    if { [catch { exec xvhdl -2008 $f } msg] } { puts $msg; exit 1 }
}

# Elaborate + run each testbench (entity name = file stem).
foreach tb $tb_files {
    set name [file rootname [file tail $tb]]
    puts "==== $name ===="
    if { [catch { exec xelab -debug typical -L unisim -L unisims_ver $name -s ${name}_sim } msg] } {
        puts $msg; exit 1
    }
    if { [catch { exec xsim ${name}_sim -runall } msg] } {
        puts $msg; exit 1
    }
}

puts "INFO: all testbenches finished"
exit 0
