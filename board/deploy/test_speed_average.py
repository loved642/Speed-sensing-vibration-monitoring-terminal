"""Check full-turn speed averaging on hardware; motor starts only with --duty > 0."""
import argparse
import time
from vib_monitor import VibMonitor, REG


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bit', default='/home/xilinx/vib/vib.bit')
    parser.add_argument('--duty', type=float, default=0)
    parser.add_argument('--frames', type=int, default=8)
    args = parser.parse_args()
    if not 0 <= args.duty <= 1 or args.frames < 1:
        parser.error('duty must be 0..1 and frames must be positive')
    v = VibMonitor(args.bit)
    try:
        v.motor_stop()
        v.enable(False, axis=0)
        if v._rd(REG['VERSION']) != 0x00020002:
            raise RuntimeError('Load the matching 0x00020002 bit/hwh before this test')
        depth = v._rd(REG['SPEED_AVG_PERIODS'])
        print(f'Firmware=0x00020002; rolling window={depth} slot periods; X axis', flush=True)
        if args.duty:
            print(f'Motor duty={args.duty:.0%}; Ctrl+C stops. Starting in 3 s.', flush=True)
            for _ in range(30):
                v.heartbeat()
                time.sleep(0.1)
            steps = max(1, int(args.duty / 0.05 + 0.999999))
            for step in range(1, steps + 1):
                v.heartbeat()
                v.motor(args.duty * step / steps)
                time.sleep(0.05)
        v.enable(True, axis=0)
        steady = 0
        for i in range(args.frames):
            if not v.wait_frame():
                raise RuntimeError(f'No completed frame: {v.sensor_status()}')
            f = v.features()
            span = 100 * (f['rpm_max'] - f['rpm_min']) / f['rpm'] if f['rpm'] else float('inf')
            raw = v._rd(REG['PERIOD_CYC'])
            raw_rpm = 60 * 100_000_000 / (raw * f['slots']) if raw else 0
            filled = v._rd(REG['SPEED_WINDOW_COUNT'])
            steady += bool(f['frame_flags'] & 4)
            print(f'{i+1}/{args.frames} frame={f["frame_id"]} '
                  f'RPM={f["rpm"]:.2f} range={f["rpm_min"]:.2f}..{f["rpm_max"]:.2f} '
                  f'span={span:.1f}% rawSlotRPM_now={raw_rpm:.2f} '
                  f'window_now={filled}/{depth} RMS={f["rms"]} '
                  f'flags=0x{f["frame_flags"]:02X} I2C={f["i2c_errors"]} '
                  f'drops={f["dropped"]}', flush=True)
        print(f'Steady flag set on {steady}/{args.frames} frames. '
              'This does not calibrate RPM or validate anomaly detection.', flush=True)
    finally:
        try:
            v.motor_stop()
        finally:
            v.enable(False, axis=0)
        print('Motor stopped; acquisition disabled.', flush=True)


if __name__ == '__main__':
    main()
