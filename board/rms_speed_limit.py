"""Freeze normal-only RMS upper limits, then evaluate fresh independent runs.

This candidate supplements the existing two-feature distance model. It does not
load an overlay, access hardware, or change the original baseline/evaluator.
Only the standard library is required.
"""
import argparse
import csv
import hashlib
import json
import math
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 'speed-rms-upper-v1'
CONFIG_KEYS = ('fs_hz', 'nfft', 'power_scale', 'axis', 'slots', 'version')


def read_rows(paths):
    rows, seen = [], set()
    for path in paths:
        with open(path, newline='', encoding='utf-8-sig') as fh:
            loaded = list(csv.DictReader(fh))
        if not loaded:
            raise ValueError(f'No data rows: {path}')
        for raw in loaded:
            r = dict(raw)
            if not r.get('run_id'):
                raise ValueError(f'Missing run_id: {path}')
            for key in ('rpm', 'rpm_min', 'rpm_max', 'rms'):
                r[key] = float(raw[key])
                if not math.isfinite(r[key]) or r[key] < 0:
                    raise ValueError(f'Invalid {key}: {path}')
            for key in (*CONFIG_KEYS, 'frame_id', 'frame_flags', 'label',
                        'i2c_errors', 'dropped', 'host_skipped'):
                r[key] = int(raw[key])
                if r[key] < 0:
                    raise ValueError(f'Invalid {key}: {path}')
            if r['label'] not in (0, 1):
                raise ValueError(f'Invalid label: {path}')
            identity = r['run_id'], r['frame_id']
            if identity in seen:
                raise ValueError(f'Duplicate frame: {identity}')
            seen.add(identity)
            rows.append(r)
    if not rows:
        raise ValueError('No input rows')
    if len({tuple(r[k] for k in CONFIG_KEYS) for r in rows}) != 1:
        raise ValueError('Do not mix firmware, sampling, axis, slots or power scale')
    return rows


def usable(r):
    return (r['rpm'] > 0 and r['rpm_min'] <= r['rpm'] <= r['rpm_max']
            and r['frame_flags'] & 7 == 7 and r['frame_flags'] & 48 == 0)


def run_ids(rows):
    return {r['run_id'] for r in rows}


def check_disjoint(*datasets):
    seen = set()
    for rows in datasets:
        ids = run_ids(rows)
        if seen & ids:
            raise ValueError('Train, validation, development and fresh test run_ids must be disjoint')
        seen |= ids


def quality(rows):
    """Report cumulative startup faults separately from subsequent increases."""
    groups = defaultdict(list)
    for r in rows:
        groups[r['run_id']].append(r)
    details = []
    for run_id, group in sorted(groups.items()):
        group.sort(key=lambda r: r['frame_id'])
        errors = [r['i2c_errors'] for r in group]
        dropped = [r['dropped'] for r in group]
        if any(b < a for a, b in zip(errors, errors[1:])):
            raise ValueError('I2C counter reset inside a run')
        if any(b < a for a, b in zip(dropped, dropped[1:])):
            raise ValueError('Dropped counter reset inside a run')
        ids = [r['frame_id'] for r in group]
        if len(set(r['condition'] for r in group)) != 1 or len(set(r['label'] for r in group)) != 1:
            raise ValueError('A run must contain one physical condition')
        details.append({
            'run_id': run_id, 'n': len(group),
            'i2c_first': errors[0], 'i2c_last': errors[-1],
            'i2c_increase': errors[-1] - errors[0],
            'dropped_max': max(dropped),
            'host_skipped': sum(r['host_skipped'] for r in group),
            'frame_gaps': sum(max(0, b-a-1) for a, b in zip(ids, ids[1:])),
        })
    return details


def fit(train, validation, development=(), *, bin_width=20., margin=.05, min_samples=5):
    if not math.isfinite(bin_width) or bin_width <= 0:
        raise ValueError('bin_width must be finite and positive')
    if not math.isfinite(margin) or not 0 <= margin <= 1:
        raise ValueError('margin must be between 0 and 1')
    if min_samples < 2:
        raise ValueError('min_samples must be at least 2')
    if not train or not validation:
        raise ValueError('Both training and independent normal validation runs are required')
    check_disjoint(train, validation, development)
    all_rows = train + validation + list(development)
    configs = {tuple(r[k] for k in CONFIG_KEYS) for r in all_rows}
    if len(configs) != 1:
        raise ValueError('Do not mix firmware or measurement configurations')
    for r in train + validation:
        if r['label'] != 0 or r['condition'] != 'normal':
            raise ValueError('Calibration accepts normal-condition runs only')
        if not usable(r):
            raise ValueError('Calibration contains invalid or unsteady frames')
    q = quality(train + validation)
    if any(r['i2c_increase'] or r['dropped_max'] or r['host_skipped'] or r['frame_gaps'] for r in q):
        raise ValueError('Calibration contains new I2C faults, dropped or missing frames')
    tr, va = defaultdict(list), defaultdict(list)
    for r in train: tr[int(r['rpm'] // bin_width)].append(r)
    for r in validation: va[int(r['rpm'] // bin_width)].append(r)
    if set(tr) != set(va):
        raise ValueError('Every speed bin needs both train and validation coverage')
    bins = {}
    for index in sorted(tr):
        if len(tr[index]) < min_samples or len(va[index]) < min_samples:
            raise ValueError('Not enough normal samples in a speed bin')
        observed = tr[index] + va[index]
        maximum = max(r['rms'] for r in observed)
        bins[str(index)] = {
            'rpm_bin_lower': index * bin_width,
            'rpm_bin_upper_exclusive': (index + 1) * bin_width,
            'observed_mean_rpm_min': min(r['rpm'] for r in observed),
            'observed_mean_rpm_max': max(r['rpm'] for r in observed),
            'normal_rms_max': maximum, 'rms_upper': maximum * (1 + margin),
            'n_train': len(tr[index]), 'n_validation': len(va[index]),
        }
    return {
        'schema': SCHEMA, 'created_utc': datetime.now(timezone.utc).isoformat(),
        'rule': 'alarm iff AC RMS > normal upper limit; one-sided amplitude candidate',
        'calibration_rule': 'max(normal train RMS, normal validation RMS) * (1 + margin)',
        'margin': margin, 'margin_status': 'engineering candidate, not an estimated error bound',
        'bin_width': bin_width, 'min_samples': min_samples,
        'config': dict(zip(CONFIG_KEYS, next(iter(configs)))), 'bins': bins,
        'global_rms_upper': max(r['rms'] for r in train + validation) * (1 + margin),
        'runs': {'train': sorted(run_ids(train)), 'validation': sorted(run_ids(validation)),
                 'development': sorted(run_ids(development))},
        'calibration_quality': q,
        'scope': 'sampled stable speed bins; no proof of generalization within or outside a bin',
        'latency_note': 'Frame decisions only; physical alarm latency has not been measured.',
    }


def predictions(model, rows):
    if model.get('schema') != SCHEMA:
        raise ValueError('Unknown model schema')
    fixed, speed = [], []
    for r in rows:
        if any(r[k] != model['config'][k] for k in CONFIG_KEYS):
            raise ValueError('Test firmware or sampling configuration differs from frozen model')
        if not usable(r):
            fixed.append(None); speed.append(None)
            continue
        fixed.append(r['rms'] > model['global_rms_upper'])
        entry = model['bins'].get(str(int(r['rpm'] // model['bin_width'])))
        speed.append(None if entry is None else r['rms'] > entry['rms_upper'])
    return fixed, speed


def scores(rows, preds):
    tp = tn = fp = fn = unknown = 0
    for r, p in zip(rows, preds):
        if p is None: unknown += 1
        elif r['label'] == 0:
            if p: fp += 1
            else: tn += 1
        elif p: tp += 1
        else: fn += 1
    n = tp + tn + fp + fn
    return {'tp': tp, 'tn': tn, 'fp': fp, 'fn': fn,
            'false_positive_rate': fp/(fp+tn) if fp+tn else None,
            'miss_rate': fn/(fn+tp) if fn+tp else None,
            'accuracy': (tp+tn)/n if n else None,
            'n_unknown': unknown, 'coverage': n/len(rows) if rows else 0}


def evaluate(model, rows, *, purpose='fresh'):
    if purpose not in ('fresh', 'diagnostic'):
        raise ValueError('purpose must be fresh or diagnostic')
    calibration = set(model['runs']['train']) | set(model['runs']['validation'])
    if calibration & run_ids(rows):
        raise ValueError('Evaluation must be disjoint from calibration runs')
    if purpose == 'fresh' and set(model['runs']['development']) & run_ids(rows):
        raise ValueError('Previously inspected development runs cannot be reported as fresh tests')
    fixed, speed = predictions(model, rows)
    common = [a is not None and b is not None for a, b in zip(fixed, speed)]
    per_run = []
    for rid in sorted(run_ids(rows)):
        idx = [i for i, r in enumerate(rows) if r['run_id'] == rid]
        group = [rows[i] for i in idx]
        per_run.append({
            'run_id': rid, 'condition': group[0]['condition'], 'n': len(group),
            'rpm_mean_range': [min(r['rpm'] for r in group), max(r['rpm'] for r in group)],
            'rms_range': [min(r['rms'] for r in group), max(r['rms'] for r in group)],
            'global': scores(group, [fixed[i] for i in idx]),
            'per_speed': scores(group, [speed[i] for i in idx]),
        })
    return {
        'purpose': purpose,
        'interpretation': ('development diagnostic; not an independent accuracy claim'
                           if purpose == 'diagnostic' else
                           'fresh run IDs; independence of physical assembly/session still requires verification'),
        'n_test': len(rows),
        'global_rms_upper': {'threshold': model['global_rms_upper'], **scores(rows, fixed)},
        'per_speed_rms_upper': {'bins': model['bins'], **scores(rows, speed)},
        'common_frames': {
            'global': scores(rows, [p if ok else None for p, ok in zip(fixed, common)]),
            'per_speed': scores(rows, [p if ok else None for p, ok in zip(speed, common)])},
        'per_run': per_run, 'quality': quality(rows),
        'test_run_ids': sorted(run_ids(rows)), 'alarm_latency_s': None,
    }


def write_new(path, data):
    encoded = json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n'
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8') as fh:
        fh.write(encoded)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='command', required=True)
    f = sub.add_parser('fit')
    f.add_argument('--train', nargs='+', required=True)
    f.add_argument('--validation', nargs='+', required=True)
    f.add_argument('--development', nargs='+', default=[])
    f.add_argument('--bin-width', type=float, default=20.)
    f.add_argument('--margin', type=float, default=.05)
    f.add_argument('--min-samples', type=int, default=5)
    f.add_argument('--model', required=True)
    e = sub.add_parser('eval')
    e.add_argument('--model', required=True)
    e.add_argument('--test', nargs='+', required=True)
    e.add_argument('--purpose', choices=('fresh', 'diagnostic'), default='fresh')
    e.add_argument('--report', required=True)
    args = ap.parse_args()
    if args.command == 'fit':
        model = fit(read_rows(args.train), read_rows(args.validation),
                    read_rows(args.development) if args.development else [],
                    bin_width=args.bin_width, margin=args.margin, min_samples=args.min_samples)
        # Check that inputs were unchanged while the model was being fitted.
        model['input_sha256'] = {str(p): hashlib.sha256(Path(p).read_bytes()).hexdigest()
                                for p in args.train + args.validation + args.development}
        model['tool_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        write_new(args.model, model)
        print('MODEL FROZEN:', args.model)
        for index, b in model['bins'].items():
            print(f'RPM bin [{b["rpm_bin_lower"]:.0f}, {b["rpm_bin_upper_exclusive"]:.0f}): '
                  f'observed mean RPM={b["observed_mean_rpm_min"]:.2f}..{b["observed_mean_rpm_max"]:.2f}; '
                  f'normal RMS max={b["normal_rms_max"]:.2f}; upper={b["rms_upper"]:.2f}')
        print('GLOBAL RMS UPPER:', model['global_rms_upper'])
        print('CANDIDATE ONLY. Collect fresh independent normal/unbalance runs next. Motor not accessed.')
    else:
        model_path = Path(args.model)
        digest = hashlib.sha256(model_path.read_bytes()).hexdigest()
        report = evaluate(json.loads(model_path.read_text(encoding='utf-8')), read_rows(args.test), purpose=args.purpose)
        report['model_sha256'] = digest
        report['tool_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report['input_sha256'] = {str(p): hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in args.test}
        write_new(args.report, report)
        print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
