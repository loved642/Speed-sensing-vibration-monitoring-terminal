"""Offline candidate-model tests with synthetic data; no hardware accuracy claim."""
import contextlib
import copy
import csv
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'board'))
from rms_speed_limit import fit, evaluate, predictions, read_rows, write_new, main


def rows(run, rpm, rms, label=0, **changes):
    data = []
    for i in range(6):
        row = dict(run_id=run, frame_id=i+1, condition='unbalance' if label else 'normal',
                   label=label, rpm=rpm, rpm_min=rpm-.1, rpm_max=rpm+.1, rms=rms,
                   frame_flags=7, fs_hz=800, nfft=1024, axis=0, power_scale=256,
                   slots=20, version=0x20002, i2c_errors=0, dropped=0, host_skipped=0)
        row.update(changes)
        data.append(row)
    return data


def normal_sets():
    return (rows('train-low', 75, 100) + rows('train-high', 110, 200),
            rows('validation-low', 76, 102) + rows('validation-high', 111, 198))


def save_csv(path, data):
    with path.open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=list(data[0]))
        writer.writeheader(); writer.writerows(data)


class RmsLimitTests(unittest.TestCase):
    def test_threshold_calibration_and_common_coverage(self):
        tr, va = normal_sets()
        model = fit(tr, va)
        self.assertAlmostEqual(model['bins']['3']['rms_upper'], 107.1)
        self.assertEqual(model['bins']['5']['rms_upper'], 210)
        self.assertEqual(model['global_rms_upper'], 210)
        test = (rows('new-normal', 75, 101) + rows('new-fault', 75, 120, 1)
                + rows('untrained-speed', 90, 130))
        report = evaluate(model, test)
        self.assertEqual(report['per_speed_rms_upper']['tp'], 6)
        self.assertEqual(report['global_rms_upper']['fn'], 6)
        self.assertEqual(report['per_speed_rms_upper']['n_unknown'], 6)
        self.assertEqual(report['common_frames']['global']['n_unknown'], 6)

    def test_test_values_do_not_update_frozen_thresholds(self):
        tr, va = normal_sets()
        model = fit(tr, va)
        original = copy.deepcopy(model)
        evaluate(model, rows('wild-test', 75, 1e9, 1))
        self.assertEqual(model, original)

    def test_run_isolation_and_previously_inspected_runs(self):
        tr, va = normal_sets()
        dev = rows('old-test', 75, 120, 1)
        model = fit(tr, va, dev)
        self.assertEqual(model['bins']['3']['rms_upper'], fit(tr, va)['bins']['3']['rms_upper'])
        with self.assertRaisesRegex(ValueError, 'development'):
            evaluate(model, dev)
        self.assertEqual(evaluate(model, dev, purpose='diagnostic')['purpose'], 'diagnostic')
        with self.assertRaisesRegex(ValueError, 'calibration'):
            evaluate(model, tr)
        with self.assertRaisesRegex(ValueError, 'disjoint'):
            fit(tr, tr)

    def test_invalid_frames_are_unknown_and_new_version_rejected(self):
        tr, va = normal_sets()
        model = fit(tr, va)
        for flags in (1, 3, 7 | 16, 7 | 32):
            report = evaluate(model, rows('bad', 75, 100, frame_flags=flags))
            self.assertEqual(report['per_speed_rms_upper']['n_unknown'], 6)
        with self.assertRaisesRegex(ValueError, 'configuration'):
            evaluate(model, rows('old-version', 75, 100, version=0x20001))

    def test_calibration_faults_labels_and_sparse_bins(self):
        tr, va = normal_sets()
        with self.assertRaisesRegex(ValueError, 'normal-condition'):
            fit(tr, rows('fault', 75, 200, 1))
        with self.assertRaisesRegex(ValueError, 'coverage'):
            fit(tr, va[:6])
        with self.assertRaisesRegex(ValueError, 'enough'):
            fit(tr, va, min_samples=7)
        bad = copy.deepcopy(va); bad[3]['i2c_errors']=1
        for r in bad[4:6]: r['i2c_errors']=1
        with self.assertRaisesRegex(ValueError, 'I2C'):
            fit(tr, bad)
        # An error already present on the first retained frame need not be repeated.
        good = copy.deepcopy(va)
        for r in good: r['i2c_errors']=1
        self.assertTrue(fit(tr, good)['bins'])
        for kwargs in ({'bin_width': 0}, {'margin': -1}, {'margin': float('nan')}):
            with self.assertRaises(ValueError): fit(tr, va, **kwargs)

    def test_missing_frames_and_configuration_mix_rejected(self):
        tr, va = normal_sets()
        bad = copy.deepcopy(va); bad[3]['frame_id']=10
        with self.assertRaisesRegex(ValueError, 'missing'):
            fit(tr, bad)
        bad = copy.deepcopy(va); bad[0]['version']=0x20001
        with self.assertRaisesRegex(ValueError, 'configuration'):
            fit(tr, bad)

    def test_csv_validation_and_exclusive_model_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'data.csv'; save_csv(p, rows('one', 75, 100))
            self.assertEqual(len(read_rows([p])), 6)
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                read_rows([p, p])
            bad = rows('nan', 75, float('nan')); save_csv(p, bad)
            with self.assertRaisesRegex(ValueError, 'Invalid rms'):
                read_rows([p])
            model = Path(tmp)/'model.json'; write_new(model, {'x': 1})
            with self.assertRaises(FileExistsError): write_new(model, {'x': 2})
            self.assertEqual(json.loads(model.read_text()), {'x': 1})

    def test_cli_fit_eval_diagnostic_and_fresh_refusal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); tr, va = normal_sets()
            for name, data in [('tr',tr),('va',va),('dev',rows('old',75,120,1)),
                               ('new',rows('fresh',75,120,1))]: save_csv(root/(name+'.csv'), data)
            model = str(root/'frozen.json')
            argv = ['rms_speed_limit.py','fit','--train',str(root/'tr.csv'),
                    '--validation',str(root/'va.csv'),'--development',str(root/'dev.csv'),
                    '--model',model]
            with patch('sys.argv',argv), contextlib.redirect_stdout(io.StringIO()): main()
            digest = json.loads(Path(model).read_text())['tool_sha256']
            self.assertEqual(len(digest), 64)
            report = root/'report.json'
            argv = ['rms_speed_limit.py','eval','--model',model,'--test',str(root/'new.csv'),
                    '--report',str(report)]
            with patch('sys.argv',argv), contextlib.redirect_stdout(io.StringIO()): main()
            self.assertEqual(json.loads(report.read_text())['per_speed_rms_upper']['tp'], 6)
            argv[argv.index(str(root/'new.csv'))] = str(root/'dev.csv')
            argv[argv.index(str(report))] = str(root/'must-not-exist.json')
            with patch('sys.argv',argv), self.assertRaisesRegex(ValueError, 'development'): main()
            self.assertFalse((root/'must-not-exist.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
