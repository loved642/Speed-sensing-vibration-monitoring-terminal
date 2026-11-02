"""Overlay/hash check; motor and acquisition remain disabled."""
import hashlib
import json
import time
from pathlib import Path
from vib_monitor import VibMonitor, REG

def main():
    root = Path(__file__).resolve().parent
    manifest = json.loads((root/'build_manifest_20261029.json').read_text())
    for name, expected in manifest['payload_sha256'].items():
        actual = hashlib.sha256((root/name).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError('SHA-256 mismatch: ' + name)
    print('Program/bit/hwh SHA-256: PASS', flush=True)
    v = VibMonitor(str(root/'vib.bit'))
    try:
        v.motor_stop()
        v.enable(False, axis=0)
        version = v._rd(REG['VERSION'])
        if version != 0x00020002:
            raise RuntimeError('Expected version 0x00020002; got 0x%08X' % version)
        for key, expected in [('FS_HZ',800),('NFFT',1024),('SLOTS',20),('SPEED_AVG_PERIODS',20)]:
            if v._rd(REG[key]) != expected:
                raise RuntimeError('Configuration mismatch: ' + key)
        first = v._rd(REG['SAMPLE_COUNT'])
        time.sleep(0.1)
        if v._rd(REG['SAMPLE_COUNT']) != first:
            raise RuntimeError('Unexpected acquisition while disabled')
        if v._rd(REG['MOTOR_CTRL']) or v._rd(REG['MOTOR_DUTY']):
            raise RuntimeError('Motor control did not stay off')
        print('SYSTEM: PASS; version=0x00020002; AVG_PERIODS=20', flush=True)
        print('Motor OFF; acquisition OFF. Physical speed/steady flags still require a board test.', flush=True)
    finally:
        try:
            v.motor_stop()
        finally:
            v.enable(False, axis=0)

if __name__ == '__main__':
    main()
