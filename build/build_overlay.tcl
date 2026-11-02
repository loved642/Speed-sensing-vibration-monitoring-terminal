## ============================================================
##  Build a PYNQ-loadable overlay: PS (Zynq-7000 / PYNQ-Z2) + vib_top PL core
##  Vivado 2025.2 batch:
##     vivado -mode batch -source build/build_overlay.tcl
##  Output: board/vib_monitor/vib.bit + vib.hwh  (copy both to the PYNQ board)
##
##  The PS is configured from the official TUL PYNQ-Z2 preset
##  (board/pynq_z2_preset.tcl), so no board files need to be installed and
##  the resulting bitstream boots with the standard PYNQ image.
## ============================================================
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set SRC  [file join $ROOT src]
set BRD  [file join $ROOT board]
set BLD  [file join $ROOT build]
set PROJ [file join $BLD overlay_proj]

# ROM init files
source [file join $BLD gen_roms.tcl]

# ---------- project ----------
create_project -part xc7z020clg400-1 $PROJ -force
add_files -fileset sources_1 [glob [file join $SRC *.v]]
# Resolve $readmemh by registering memory files with the project, including
# out-of-context module-reference synthesis runs in their own directories.
add_files -norecurse [list [file join $BLD twiddle.mem] [file join $BLD hann.mem]]
set_property FILE_TYPE {Memory Initialization Files} [get_files *.mem]
update_compile_order -fileset sources_1

# ---------- block design ----------
create_bd_design "system"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

# apply the TUL PYNQ-Z2 PS preset (parse CONFIG.PCW_* from the preset tcl)
set fh [open [file join $BRD pynq_z2_preset.tcl] r]
set data [read $fh]; close $fh
set opts {}
foreach line [split $data "\n"] {
    if {[regexp {CONFIG\.(PCW_[A-Za-z0-9_]+)} $line -> key]} {
        set i [string first "\{" $line]
        set j [string last "\}" $line]
        if {$i > 0 && $j > $i} {
            set val [string range $line [expr {$i+1}] [expr {$j-1}]]
            lappend opts "CONFIG.$key" $val
        }
    }
}
puts "PS preset properties: [llength $opts]"
set_property -dict $opts [get_bd_cells ps7]

# ensure only GP0 master + FCLK0 are enabled (disable unused PS AXI ports so
# validate_bd_design has no unconnected AXI clocks/paths)
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_M_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
    CONFIG.PCW_USE_S_AXI_HP3 {0} \
    CONFIG.PCW_USE_S_AXI_ACP {0} \
    CONFIG.PCW_USE_S_AXI_ACE {0} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] [get_bd_cells ps7]

# external DDR / FIXED_IO
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT {0} [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "0"} [get_bd_cells ps7]

# our PL core
create_bd_cell -type module -reference vib_top vib_top_0

# PS M_AXI_GP0 -> vib_top S_AXI (auto: interconnect + address + clock + reset)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} [get_bd_intf_pins vib_top_0/S_AXI]

# make sure clk + reset reach the core (automation may not match "rst_n")
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins vib_top_0/clk]]] == 0} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins vib_top_0/clk]
}
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins vib_top_0/rst_n]]] == 0} {
    set rc [get_bd_cells -quiet -hier -filter {VLNV =~ "*proc_sys_reset*"}]
    if {[llength $rc]} {
        connect_bd_net [get_bd_pins $rc/peripheral_aresetn] [get_bd_pins vib_top_0/rst_n]
    }
}

# I2C bus + pulse as external ports (spi_mosi is the I2C SDA, bidirectional)
foreach p {spi_cs_n motor_pwm motor_in1 motor_in2 motor_stby} {
    create_bd_port -dir O $p
    connect_bd_net [get_bd_ports $p] [get_bd_pins vib_top_0/$p]
}
foreach p {spi_sclk spi_mosi} {
    create_bd_port -dir IO $p
    connect_bd_net [get_bd_ports $p] [get_bd_pins vib_top_0/$p]
}
create_bd_port -dir I spi_miso
connect_bd_net [get_bd_ports spi_miso] [get_bd_pins vib_top_0/spi_miso]
create_bd_port -dir I pulse
connect_bd_net [get_bd_ports pulse] [get_bd_pins vib_top_0/pulse]

assign_bd_address
validate_bd_design
save_bd_design

# wrapper as design top
make_wrapper -files [get_files system.bd] -top
set wr [glob -nocomplain [file join $BLD overlay_proj.gen sources_1 bd system hdl system_wrapper.v]]
if {[llength $wr] == 0} { error "wrapper not found" }
add_files -norecurse $wr
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# pin constraints (PmodA)
add_files -fileset constrs_1 [file join $BRD overlay_pins.xdc]

# ---------- build ----------
# All overlay package pins and standards are required; keep DRC errors enabled.
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "OVERLAY IMPL FAILED" }
# Treat missing ROM contents as a build failure even when synthesis continues.
foreach run [get_runs -filter {IS_SYNTHESIS == 1}] {
    set logfile [file join [get_property DIRECTORY $run] runme.log]
    if {[file exists $logfile]} {
        set loghandle [open $logfile r]
        set logdata [read $loghandle]
        close $loghandle
        if {[string first {could not open $readmem data file} $logdata] >= 0} {
            error "ROM initialization missing in $run; exported overlay was not replaced."
        }
        if {[string first {Synth 8-5799} $logdata] >= 0} {
            error "Internal tristate converted to logic in $run; exported overlay was not replaced."
        }
    }
}

# ---------- export ----------
open_run impl_1
foreach busport {spi_sclk spi_mosi} {
    set padpins [get_pins -quiet -of_objects [get_nets -segments -of_objects [get_ports $busport]] -filter {REF_PIN_NAME == IO}]
    set pads [get_cells -quiet -of_objects $padpins -filter {REF_NAME == IOBUF}]
    if {[llength $pads] != 1} {
        error "$busport must connect to exactly one IOBUF; exported overlay was not replaced."
    }
    puts "VERIFIED OPEN-DRAIN PAD: $busport -> $pads"
}
file mkdir [file join $ROOT report]
report_timing_summary -file [file join $ROOT report overlay_timing.rpt]
report_utilization -file [file join $ROOT report overlay_utilization.rpt]
foreach delay_type {max min} {
    if {[get_property SLACK [get_timing_paths -delay_type $delay_type -max_paths 1]] < 0} {
        error "Overlay failed $delay_type timing; existing exported bitstream was not replaced."
    }
}
set out [file join $BRD vib_monitor]
file mkdir $out
file copy -force [glob [file join $BLD overlay_proj.runs impl_1 system_wrapper.bit]] [file join $out vib.bit]
file copy -force [glob [file join $BLD overlay_proj.gen sources_1 bd system hw_handoff system.hwh]] [file join $out vib.hwh]
puts "OVERLAY EXPORTED -> $out"
exit
