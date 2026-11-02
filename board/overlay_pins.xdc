# PYNQ-Z2 (xc7z020clg400-1) pin constraints for the vib_top overlay.
# Pmod pin map taken from the official TUL "PYNQ-Z2 v1.0.xdc".
#   PmodA: ja[0]=Y18 ja[1]=Y19 ja[2]=Y16 ja[3]=Y17
#          ja[4]=U18 ja[5]=U19 ja[6]=W18 ja[7]=W19
#   PmodB: jb[0]=W14 jb[1]=Y14 jb[2]=T11 jb[3]=T10
#          jb[4]=V16 jb[5]=W16 jb[6]=V12 jb[7]=W13
#
# Wiring used here (ADXL345 on PmodA, I2C mode; + photoelectric speed sensor):
#   spi_sclk -> ja[0] Y18   (I2C SCL)
#   spi_mosi -> ja[1] Y19   (I2C SDA, bidirectional)
#   spi_cs_n -> ja[2] Y16   (driven HIGH -> I2C mode)
#   spi_miso -> ja[3] Y17   (unused)
#   pulse    -> ja[4] U18   (photoelectric DO)
# Power the ADXL345 3V3 and the sensor VCC from PmodA 3.3V (pin 6), GND from pin 5.

set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports spi_sclk]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports spi_mosi]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports spi_cs_n]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports spi_miso]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports pulse]

# clk comes from the PS (FCLK_CLK0) in the overlay - no LOC needed.
# I2C: BOTH signals are open-drain. Install external 2.2k-4.7k pull-ups
# to 3.3V (including any pull-ups already on the sensor module).
# Internal weak pull-ups alone do not guarantee 400 kHz rise times.
set_property PULLUP true [get_ports spi_mosi]
set_property PULLUP true [get_ports spi_sclk]

# TB6612 on PmodB: pin1 PWM, pin2 AIN1, pin3 AIN2, pin4 STBY.
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports motor_pwm]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports motor_in1]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports motor_in2]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports motor_stby]

# Asynchronous external inputs end at the first synchronizer stage only.
set_false_path -from [get_ports spi_sclk] -to [get_cells -hier -regexp {.*u_acc/scl_sync_reg\[0\]}]
set_false_path -from [get_ports spi_mosi] -to [get_cells -hier -regexp {.*u_acc/sda_sync_reg\[0\]}]
set_false_path -from [get_ports pulse] -to [get_cells -hier -regexp {.*u_spd/sync_reg\[0\]}]
