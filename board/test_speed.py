"""Speed (RPM) readout test.

Reads RPM_X100 / PERIOD_CYC / STATUS every 0.5 s for ~6 s.
Spin the motor, or wave a slotted card through the photoelectric sensor,
and watch RPM / period change.

If period stays 0 / RPM stays 0 -> no pulses are reaching pin U18.
"""
from pynq import Overlay
import time

o = Overlay('/home/xilinx/vib/vib.bit')
top = o.vib_top_0
top.write(0x00, 0x1)          # enable (speed capture runs regardless)

print('Reading RPM for 6 s ... spin the motor / wave a slotted card through the sensor.')
for i in range(12):
    raw = top.read(0x10)
    per = top.read(0x4C)
    st  = top.read(0x0C)
    print('t=%4.1fs  RPM=%10.2f  rpm_x100=%10d  period=%10d  status=0x%02X'
          % (i * 0.5, raw / 100.0, raw, per, st))
    time.sleep(0.5)
