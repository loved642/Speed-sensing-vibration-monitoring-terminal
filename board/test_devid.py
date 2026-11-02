"""PYNQ bring-up: validate DEVID, configuration and live sample progress.

Use with the matching updated vib.bit AND vib.hwh. Historical spi_* port names
now carry I2C: SCL=Y18, SDA=Y19, CS=Y16 HIGH. SDO=GND -> address 0x53.
"""
import time
from pynq import Overlay

BIT = '/home/xilinx/vib/vib.bit'
ERRORS = {0: 'none', 1: 'NACK (address/register/data not acknowledged)',
          2: 'SDA stuck low (check shorts, CS and pull-up)',
          3: 'SCL timeout (check clock wiring/pull-up)',
          4: 'unexpected DEVID (expected E5)'}

o = Overlay(BIT)
print('IPs:', sorted(o.ip_dict))
ip = o.ip_dict['vib_top_0']
print('vib_top_0 base = 0x%X' % ip.get('phys_addr', ip.get('base_address', 0)))
top = o.vib_top_0
top.write(0x00, 0)
time.sleep(0.01)
top.write(0x00, 1)
deadline = time.monotonic() + 2.0
while time.monotonic() < deadline:
    sensor = top.read(0x58)
    if sensor == 0xDEADBEEF:
        raise RuntimeError('Old overlay: replace both vib.bit and vib.hwh')
    if sensor & 1:
        break
    time.sleep(0.01)

devid = top.read(0x50) & 0xFF
code = (sensor >> 4) & 0xF
print('DEVID = 0x%02X; ready=%d' % (devid, sensor & 1))
print('I2C   = 0x%08X; SCL=%d SDA=%d; error=%s' % (
    sensor, (sensor >> 2) & 1, (sensor >> 3) & 1, ERRORS.get(code, 'unknown')))
print('Faults=%d; failed transaction=%d step=%d' % (
    sensor >> 16, (sensor >> 12) & 7, (sensor >> 8) & 0xF))
print('FS_HZ=%d; CTRL=0x%08X' % (top.read(0x04), top.read(0x00)))
first = top.read(0x5C)
time.sleep(0.1)
last = top.read(0x5C)
progress = (last - first) & 0xFFFFFFFF
print('Samples in 0.1 s = %d; total=%d' % (progress, last))
for label, offset in [('X', 0x60), ('Y', 0x64), ('Z', 0x68)]:
    value = top.read(offset) & 0xFFFF
    print('RAW_%s=%d' % (label, value - 65536 if value & 0x8000 else value))
print('RPMx100=%d; PEAK=%d; RMS=%d' % (
    top.read(0x10), top.read(0x1C), top.read(0x20)))
final_status = top.read(0x58)
ok = devid == 0xE5 and bool(final_status & 1) and ((final_status >> 4) & 0xF) == 0 and progress > 0
if not ok:
    raise SystemExit('SENSOR: FAIL (see I2C diagnostics above)')
print('SENSOR: PASS (ID/configuration and sample progress; verify motion on hardware)')
