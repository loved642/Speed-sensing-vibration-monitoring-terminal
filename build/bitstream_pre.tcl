# Pre-hook for write_bitstream: this is a standalone PL build
# (no pins assigned / no I/O standard). Downgrade the related DRCs to warnings
# so the bitstream can be generated for flow/report completeness.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]