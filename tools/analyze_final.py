"""Audit the final measurements and reproduce descriptive comparisons.

Run from any directory: python tools/analyze_final.py
No hardware access. A successful audit does not validate a fault classifier.
"""
from pathlib import Path
from collections import Counter
import csv
import hashlib
import json
import math
import statistics

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'data' / 'analysis'
DEST.mkdir(parents=True, exist_ok=True)
summaries, samples, identities = [], {}, set()
for path in sorted((ROOT / 'data' / 'final').glob('*.csv')):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 50:
        raise ValueError(f'{path.name}: expected 50 frames')
    for r in rows:
        for k in ('rpm', 'rpm_min', 'rpm_max', 'rms', 'duty'):
            r[k] = float(r[k])
            if not math.isfinite(r[k]):
                raise ValueError(f'{path.name}: nonfinite {k}')
        for k in ('axis', 'frame_id', 'frame_flags', 'i2c_errors', 'dropped',
                  'host_skipped', 'label', 'fs_hz', 'nfft', 'slots', 'version', 'power_scale'):
            r[k] = int(r[k], 0) if k == 'frame_flags' else int(r[k])
        ident = r['run_id'], r['frame_id']
        if ident in identities:
            raise ValueError('Duplicate frame identity')
        identities.add(ident)
        if (r['frame_flags'] != 7 or r['i2c_errors'] or r['dropped'] or r['host_skipped']
                or not 0 < r['rpm_min'] <= r['rpm'] <= r['rpm_max']
                or r['rms'] < 0):
            raise ValueError(f'{path.name}: failed final quality criteria')
    if len({(r['run_id'], r['condition'], r['axis'], r['duty'], r['label'],
             r['fs_hz'], r['nfft'], r['slots'], r['version'], r['power_scale']) for r in rows}) != 1:
        raise ValueError(f'{path.name}: mixed run/configuration')
    if any(b['frame_id'] != a['frame_id'] + 1 for a, b in zip(rows, rows[1:])):
        raise ValueError(f'{path.name}: frame gap')
    r = rows[0]
    if (r['fs_hz'], r['nfft'], r['slots'], r['version'], r['power_scale']) != (800, 1024, 20, 131074, 256):
        raise ValueError(f'{path.name}: unexpected sampling/firmware configuration')
    if (r['condition'], r['label']) not in (('normal', 0), ('unbalance', 1)):
        raise ValueError(f'{path.name}: invalid physical label')
    key = r['duty'], r['axis'], r['condition']
    if key in samples:
        raise ValueError('Repeated condition/duty/axis cell')
    samples[key] = rows
    values = [r['rms'] for r in rows]
    summaries.append(dict(file=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                          run_id=r['run_id'], condition=r['condition'], axis=r['axis'], duty=r['duty'],
                          frames=len(rows), rpm_mean=statistics.mean(r['rpm'] for r in rows),
                          rms_mean=statistics.mean(values), rms_sd=statistics.stdev(values),
                          rms_min=min(values), rms_max=max(values),
                          flags='0x07', i2c_max=0, dropped=0, host_skipped=0, frame_gaps=0))
expected = {(d, a, c) for d in (0.5, 0.7) for a in range(3) for c in ('normal', 'unbalance')}
if set(samples) != expected or len(identities) != 600 or len({s['run_id'] for s in summaries}) != 12:
    raise ValueError('Expected 12 distinct runs and 600 frames')
comparisons = []
for duty in (0.5, 0.7):
    for axis in range(3):
        n, u = [next(s for s in summaries if (s['duty'], s['axis'], s['condition']) == (duty, axis, c))
                for c in ('normal', 'unbalance')]
        comparisons.append(dict(duty=duty, axis='XYZ'[axis], normal_rpm=n['rpm_mean'],
                                unbalance_rpm=u['rpm_mean'], normal_rms=n['rms_mean'],
                                unbalance_rms=u['rms_mean'],
                                increase_pct=100*(u['rms_mean']/n['rms_mean']-1)))
report = dict(n_files=len(summaries), n_frames=len(identities), audit='PASS',
              summaries=summaries, comparisons=comparisons,
              limits=['Sequential axes, no synchronous vector fusion',
                      'One run per condition/duty/axis; frames are not independent assemblies',
                      'No independent classifier accuracy or alarm latency is claimed',
                      'Raw counts; RPM has not been externally calibrated',
                      'Board timestamp incorrect; raw filenames retained',
                      'Orders bands invalid: flags 0x07 lack bit3'])
(DEST/'quality.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
for name, records in [('summary.csv', summaries), ('comparisons.csv', comparisons)]:
    with (DEST/name).open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=list(records[0])); w.writeheader(); w.writerows(records)
try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(2, 3, figsize=(12, 6.4), constrained_layout=True)
    for comp, ax in zip(comparisons, axes.flat):
        axis = 'XYZ'.index(comp['axis']); duty = comp['duty']
        groups = [[r['rms'] for r in samples[duty, axis, c]] for c in ('normal', 'unbalance')]
        bp = ax.boxplot(groups, tick_labels=['Normal', 'New unbalance'], patch_artist=True)
        for box, color in zip(bp['boxes'], ['#1D5C96', '#D65B35']):
            box.set_facecolor(color); box.set_alpha(.7)
        ax.set_title(f"{duty:.0%} PWM / {comp['axis']} / +{comp['increase_pct']:.1f}%")
        ax.set_ylabel('AC RMS (raw counts)'); ax.grid(axis='y', alpha=.2)
    fig.suptitle('Descriptive comparison: 50 frames per run; no independent accuracy claim')
    fig.savefig(DEST/'rms_comparison.png', dpi=180); plt.close(fig)
except ImportError:
    print('Plots skipped: install matplotlib to generate figures')
print('PASS: 12 files / 12 distinct runs / 600 frames; counters and gaps zero')
for c in comparisons:
    print(f"{c['duty']:.0%} PWM / {c['axis']}: {c['normal_rms']:.2f} -> {c['unbalance_rms']:.2f} raw counts (+{c['increase_pct']:.1f}%)")
print('Outputs:', DEST)
