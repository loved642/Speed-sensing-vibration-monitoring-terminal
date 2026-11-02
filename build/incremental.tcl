## ============================================================
##  Incremental rebuild: reuse the existing project (much faster than build.tcl)
##  Usage:  vivado -mode batch -source build/incremental.tcl
##  Re-runs synth + impl + reports + bitstream on the current project.
## ============================================================
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set BLD  [file join $ROOT build]
set RPT  [file join $ROOT report]
set PROJ [file join $BLD vivado_proj]

if {![file exists [file join $BLD vivado_proj.xpr]]} {
    error "No project found. Run build.tcl once first."
}
open_project [file join $BLD vivado_proj.xpr]

# refresh ROM init files into the synth run dir
set syncdir [get_property DIRECTORY [get_runs synth_1]]
file mkdir $syncdir
file copy -force [file join $BLD twiddle.mem] [file join $syncdir twiddle.mem]
file copy -force [file join $BLD hann.mem]    [file join $syncdir hann.mem]

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1 -name synth_1
report_utilization    -file [file join $RPT utilization_synth.rpt]
report_timing_summary -file [file join $RPT timing_synth.rpt]

reset_run impl_1
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file join $BLD bitstream_pre.tcl] [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_utilization    -file [file join $RPT utilization_impl.rpt]
report_timing_summary -file [file join $RPT timing_impl.rpt]

puts "INCREMENTAL DONE"
exit