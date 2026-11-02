## Generate FFT ROM init files into build/: twiddle.mem and hann.mem
set _bl [file join [file dirname [info script]]]
set f [open [file join $_bl twiddle.mem] w]
for {set i 0} {$i < 512} {incr i} {
    set ang [expr {-2.0*acos(-1.0)*$i/1024.0}]
    set re [expr {int(round(cos($ang)*32767.0))}]
    set im [expr {int(round(sin($ang)*32767.0))}]
    puts $f [format "%04X%04X" [expr {$im & 0xFFFF}] [expr {$re & 0xFFFF}]]
}
close $f
set f [open [file join $_bl hann.mem] w]
for {set n 0} {$n < 1024} {incr n} {
    set w [expr {int(round((0.5-0.5*cos(2.0*acos(-1.0)*$n/1023.0))*32767.0))}]
    puts $f [format "%04X" [expr {$w & 0xFFFF}]]
}
close $f
puts "gen_roms: twiddle.mem + hann.mem written"