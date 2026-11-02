"""Wait for a complete snapshot instead of reading RMS during initialization."""
from vib_monitor import VibMonitor

vm = VibMonitor('vib.bit')
vm.motor_stop()
vm.enable(True)
try:
    if not vm.wait_frame():
        raise RuntimeError(f'No complete frame: {vm.sensor_status()}')
    print('DEVID', hex(vm.devid()))
    print('Frame', vm.features())
finally:
    vm.enable(False)
