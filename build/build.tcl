## ============================================================
##  Build script: speed_aware_vibration_monitor (PL core)
##  Vivado 2025.2 batch build -> synthesis + implementation + reports
##  Usage:  vivado -mode batch -source build/build.tcl
## ============================================================

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set SRC  [file join $ROOT src]
set BLD  [file join $ROOT build]
set RPT  [file join $ROOT report]
set PROJ [file join $BLD vivado_proj]

puts "ROOT = $ROOT"

# ---------- 1) generate ROM init files ----------
source [file join $BLD gen_roms.tcl]

# ---------- 2) create project ----------
create_project -part xc7z020clg400-1 $PROJ -force
add_files -fileset sources_1 [glob [file join $SRC *.v]]
add_files -fileset sources_1 [file join $SRC vib_top.xdc]
set_property top vib_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# ---------- 3) synthesis ----------
# copy ROM init files into synth run dir BEFORE launch (for \$readmemh)
set syncdir [get_property DIRECTORY [get_runs synth_1]]
file mkdir $syncdir
file copy -force [file join $BLD twiddle.mem] [file join $syncdir twiddle.mem]
file copy -force [file join $BLD hann.mem]    [file join $syncdir hann.mem]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "SYNTHESIS FAILED"
}

open_run synth_1 -name synth_1
file mkdir $RPT
report_utilization      -file [file join $RPT utilization_synth.rpt]
report_timing_summary   -file [file join $RPT timing_synth.rpt]
report_clock_utilization -file [file join $RPT clocks_synth.rpt]

# ---------- 4) implementation ----------
# allow bitstream generation for a standalone PL build (no pin/IO-standard constraints)
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file join $BLD bitstream_pre.tcl] [get_runs impl_1]

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "IMPLEMENTATION FAILED"
}

open_run impl_1
report_utilization    -file [file join $RPT utilization_impl.rpt]
report_timing_summary -file [file join $RPT timing_impl.rpt]

puts "DONE: reports in $RPT"
exit