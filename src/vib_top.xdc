## vib_top timing constraints (PL core, standalone build)
create_clock -name clk -period 10.000 [get_ports clk]

set_false_path -from [get_ports spi_miso]
set_false_path -from [get_ports spi_mosi] -to [get_cells -hierarchical -filter {NAME =~ *sda_sync_reg*}]
set_false_path -from [get_ports spi_sclk] -to [get_cells -hierarchical -filter {NAME =~ *scl_sync_reg*}]
set_false_path -from [get_ports pulse]
set_false_path -to   [get_ports spi_sclk]
set_false_path -to   [get_ports spi_mosi]
set_false_path -to   [get_ports spi_cs_n]

# AXI is synchronous to clk; no extra constraints needed for a standalone PL build.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical {pulse_IBUF*}] -quiet
