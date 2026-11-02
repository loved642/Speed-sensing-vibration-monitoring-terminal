"""Collect one physical condition per invocation; evaluate independent runs."""
import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import time
import uuid

import numpy as np

COND_CODES = {'normal': 0, 'unbalance': 1, 'loose': 1}
KEYS = ['run_id', 't', 'elapsed_s', 'condition', 'label', 'axis', 'duty',
        'frame_id', 'frame_flags', 'rpm', 'rpm_min', 'rpm_max', 'bin1x', 'bin2x',
        'rms', 'peak', 'mean', 'sumsq', 'total_energy', 'band1_energy',
        'band2_energy', 'dom_bin', 'dom_pow', 'fs_hz', 'nfft', 'power_scale',
        'slots', 'version', 'speed_valid', 'steady', 'bands_valid',
        'dropped', 'i2c_errors', 'host_skipped']


def _load_driver(bit):
    from vib_monitor import VibMonitor
    return VibMonitor(bit)


def cmd_collect(args):
    from baseline import usable
    if args.frames < 1 or args.settle_frames < 0 or args.settle_timeout <= 0:
        raise ValueError('Invalid frame count or settling timeout')
    if args.duty is not None and not 0 <= args.duty <= 1:
        raise ValueError('Duty must be between 0 and 1')
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex
    with out.open('x', newline='', encoding='utf-8') as fh:
        writer = csv.DictWriter(fh, fieldnames=KEYS)
        writer.writeheader()
        fh.flush()
        vm = _load_driver(args.bit)
        started = time.monotonic()
        try:
            vm.motor_stop()
            vm.enable(False, axis=args.axis)
            if args.duty is not None and args.duty > 0:
                # Open-loop duty control; actual RPM is measured, never inferred.
                steps = max(1, int(np.ceil(args.duty / 0.05)))
                for step in range(1, steps + 1):
                    vm.motor(args.duty * step / steps)
                    vm.heartbeat()
                    time.sleep(0.05)
            vm.enable(True, axis=args.axis)
            print(f'[collect] run={run_id} condition={args.condition}; '
                  'the physical condition must already be installed')
            stable, count, last = 0, 0, None
            settling = args.settle_frames
            deadline = time.monotonic() + args.settle_timeout
            while count < args.frames:
                if not vm.wait_frame():
                    raise RuntimeError(f'No new frame: {vm.sensor_status()}')
                f = vm.features()
                if f['frame_id'] == last:
                    continue
                previous, last = last, f['frame_id']
                if settling:
                    good = usable(f, 'broadband')
                    stable = stable + 1 if good else 0
                    span = (100 * (f['rpm_max'] - f['rpm_min']) / f['rpm']
                            if f['rpm'] > 0 else float('inf'))
                    print(f'[settle] {stable}/{settling} RPM={f["rpm"]:.2f} '
                          f'range={f["rpm_min"]:.2f}..{f["rpm_max"]:.2f} '
                          f'span={span:.1f}% flags=0x{f["frame_flags"]:02x} '
                          f'I2C={f.get("i2c_errors", "?")}', flush=True)
                    if stable >= settling:
                        settling = 0
                    elif time.monotonic() >= deadline:
                        raise RuntimeError('Speed did not settle; check measured RPM and frame flags')
                    continue
                now = time.monotonic()
                f.update(run_id=run_id, t=datetime.now(timezone.utc).isoformat(),
                         elapsed_s=now-started, condition=args.condition,
                         label=COND_CODES[args.condition], axis=args.axis,
                         duty='' if args.duty is None else args.duty,
                         host_skipped=0 if previous is None else
                         max(0, ((last-previous) & 0xFFFFFFFF)-1))
                writer.writerow({key: f.get(key, '') for key in KEYS})
                fh.flush()
                count += 1
                print(f'[collect] {count}/{args.frames} RPM={f["rpm"]:.2f} '
                      f'AC_RMS={f["rms"]} flags=0x{f["frame_flags"]:02x}')
        finally:
            try:
                vm.motor_stop()
            finally:
                vm.enable(False, axis=args.axis)
    print(f'[collect] saved {count} frames -> {out}')


def _read_runs(paths):
    rows = []
    for path in paths:
        with open(path, newline='', encoding='utf-8-sig') as fh:
            for raw in csv.DictReader(fh):
                if not raw.get('run_id'):
                    raise ValueError(f'{path}: missing run_id; recollect with the new collector')
                row = dict(raw)
                for key in ('rpm', 'rpm_min', 'rpm_max', 'rms', 'peak'):
                    row[key] = float(raw[key])
                for key in ('label', 'frame_id', 'frame_flags', 'total_energy',
                            'band1_energy', 'band2_energy', 'fs_hz', 'nfft',
                            'power_scale', 'axis', 'slots', 'version'):
                    row[key] = int(raw[key])
                if row['label'] not in (0, 1):
                    raise ValueError('Labels must be 0/1')
                rows.append(row)
    if not rows:
        raise ValueError('Dataset is empty')
    ids = [(r['run_id'], r['frame_id']) for r in rows]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate frames within a dataset')
    return rows


def evaluate(train, test, *, validation=None, bin_width=20.0, k=3.0,
             feature_mode='broadband', percentile=99.5):
    from baseline import FixedThreshold, SpeedBaseline, score, usable
    if not 0 < percentile < 100:
        raise ValueError('Percentile must be between 0 and 100')
    sets = [train, test] + ([validation] if validation is not None else [])
    if any(not rows for rows in sets):
        raise ValueError('Dataset is empty')
    seen = set()
    for rows in sets:
        runs = {r['run_id'] for r in rows}
        if seen & runs:
            raise ValueError('Training, validation and test must have disjoint run_id values')
        seen |= runs
    configs = {(r['fs_hz'], r['nfft'], r['power_scale'], r['axis'], r['slots'], r['version'])
               for rows in sets for r in rows}
    if len(configs) != 1:
        raise ValueError('Do not mix sampling, axis, slots, power scale or firmware configurations')
    if any(r['label'] != 0 or r['condition'] != 'normal' for r in train):
        raise ValueError('Training accepts only normal-condition runs')
    sb = SpeedBaseline(bin_width=bin_width, k=k, feature_mode=feature_mode)
    normal = [r for r in train if usable(r, feature_mode)]
    if not normal:
        raise ValueError('No usable calibration frames; inspect quality flags and feature mode')
    for row in normal:
        sb.update(row)
    th = float(np.percentile([r['rms'] for r in normal], percentile)) * 1.2
    if validation is not None:
        if any(r['label'] != 0 or r['condition'] != 'normal' for r in validation):
            raise ValueError('Threshold validation accepts only independent normal runs')
        val = [r for r in validation if usable(r, feature_mode)]
        zs = [sb.zscore(r) for r in val]
        zs = [z for z in zs if z is not None]
        if not val or len(zs) != len(val) or len(val) != len(validation):
            raise ValueError('Validation contains invalid or uncalibrated speed ranges')
        th = float(np.percentile([r['rms'] for r in val], percentile))
        sb.k = max(float(np.percentile(zs, percentile)), 1e-6)
    if not any(n >= sb.min_samples for _, _, n in sb.bins.values()):
        raise ValueError('Not enough valid calibration frames in any speed bin')
    ft = FixedThreshold(th)
    fixed = [ft.alarm(r) if usable(r, feature_mode) else None for r in test]
    speed = [sb.alarm(r) for r in test]
    labels = [r['label'] for r in test]
    common = [a is not None and b is not None for a, b in zip(fixed, speed)]
    return {
        'feature_mode': feature_mode, 'n_train_usable': len(normal), 'n_test': len(test),
        'threshold_source': 'validation' if validation is not None else 'training (preliminary)',
        'fixed_threshold': {'rms_threshold': th, **score(labels, fixed)},
        'speed_baseline': {'k': sb.k, 'bin_width': bin_width, **score(labels, speed)},
        'common_frames': {
            'fixed': score(labels, [p if ok else None for p, ok in zip(fixed, common)]),
            'speed': score(labels, [p if ok else None for p, ok in zip(speed, common)])},
        'runs': {'train': sorted({r['run_id'] for r in train}),
                 'validation': sorted({r['run_id'] for r in validation or []}),
                 'test': sorted({r['run_id'] for r in test})},
        'alarm_latency_s': None,
        'latency_note': 'Requires measured physical fault-onset timestamps; not inferred from labels.'}


def cmd_eval(args):
    report = evaluate(_read_runs(args.train), _read_runs(args.test),
                      validation=_read_runs(args.validation) if args.validation else None,
                      bin_width=args.bin_width, k=args.k,
                      feature_mode=args.feature_mode, percentile=args.percentile)
    result = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False)
    print(result)
    if args.report:
        Path(args.report).write_text(result + '\n', encoding='utf-8')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('collect')
    c.add_argument('--bit', required=True)
    c.add_argument('--out', required=True)
    c.add_argument('--condition', choices=sorted(COND_CODES), required=True)
    c.add_argument('--axis', type=int, choices=(0, 1, 2), default=2)
    c.add_argument('--frames', type=int, default=30)
    c.add_argument('--duty', type=float, help='PL PWM duty 0..1; omit for an external motor source')
    c.add_argument('--settle-frames', type=int, default=2)
    c.add_argument('--settle-timeout', type=float, default=120)
    c.set_defaults(func=cmd_collect)
    e = sub.add_parser('eval')
    e.add_argument('--train', nargs='+', required=True)
    e.add_argument('--test', nargs='+', required=True)
    e.add_argument('--validation', nargs='+')
    e.add_argument('--k', type=float, default=3.0)
    e.add_argument('--bin-width', type=float, default=20.0)
    e.add_argument('--feature-mode', choices=('broadband', 'orders'), default='broadband')
    e.add_argument('--percentile', type=float, default=99.5)
    e.add_argument('--report')
    e.set_defaults(func=cmd_eval)
    args = ap.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
