"""Sensor-to-FFT snapshot check; motion response still needs human inspection."""
from vib_monitor import VibMonitor

v = VibMonitor('/home/xilinx/vib/vib.bit')
v.motor_stop()
try:
    v.enable(True, axis=2)
    for phase in ('KEEP STILL', 'GENTLY MOVE OR TAP', 'KEEP STILL AGAIN'):
        print('\n--- %s (4 frames) ---' % phase, flush=True)
        for _ in range(4):
            if not v.wait_frame(timeout=5):
                raise RuntimeError('No new frame: %s' % v.sensor_status())
            f = v.features(include_spectrum=True)
            s = v.sensor_status()
            if sum(int(x) for x in f['spectrum'][1:]) != f['total_energy']:
                raise RuntimeError('Spectrum/feature energy mismatch')
            if s['error_count'] or not s['ready'] or s['error_code']:
                raise RuntimeError('I2C fault: %s' % s)
            hz = f['dom_bin'] * f['fs_hz'] / f['nfft']
            print('frame=%d RMS=%d peak=%d mean=%.2f domHz=%.2f flags=0x%X errors=%d drops=%d' %
                  (f['frame_id'], f['rms'], f['peak'], f['mean'], hz,
                   f['frame_flags'], s['error_count'], f['dropped']), flush=True)
    print('\nPIPELINE: PASS (12 snapshots, spectrum sums and I2C); inspect motion response.')
finally:
    v.motor_stop()
    v.enable(False)
