"""I2C wiring diagnostic; CS is permanently HIGH in the current firmware."""
from pathlib import Path
from vib_monitor import VibMonitor

vm = VibMonitor(str(Path(__file__).with_name('vib.bit')))
vm.motor_stop()
vm.enable(False)
try:
    print('I2C mode: CS must measure 3.3 V; this firmware never pulses CS.')
    print('Idle SCL and SDA must BOTH be HIGH. MISO/0x54 is unused.')
    print('Idle diagnostics:', vm.sensor_status())
    vm.enable(True)
    if not vm.wait_frame():
        raise RuntimeError(f'No complete frame: {vm.sensor_status()}')
    print('Live diagnostics:', vm.sensor_status())
    print('DEVID:', hex(vm.devid()), 'frame:', vm.features())
finally:
    vm.enable(False)
