"""Host regression with fake MMIO; never connects to or claims physical hardware."""
import csv
import importlib
import io
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'board'))
sys.modules.setdefault('pynq', types.SimpleNamespace(Overlay=None, MMIO=None))
from baseline import FixedThreshold, SpeedBaseline, score, usable
from run_measure import evaluate, cmd_collect, KEYS
from vib_monitor import VibMonitor, REG
from test_speed_average import main as speed_check_main


def feature(**overrides):
    row = dict(run_id='train', condition='normal', label=0, rpm=105.,
               rpm_min=104., rpm_max=106., frame_id=1, frame_flags=15,
               total_energy=10000, band1_energy=4000, band2_energy=2000,
               rms=10, peak=20, fs_hz=800, nfft=1024, axis=2,
               slots=20, power_scale=256, version=0x20001)
    row.update(overrides)
    return row


class FakeMMIO:
    def __init__(self):
        self.data = {REG['FRAME_ID']: 1, REG['STATUS']: 16,
                     REG['I2C_STATUS']: 13, REG['FRAME_FLAGS']: 15,
                     REG['FRAME_RPM']: 10500, REG['MEAN_Q8']: (-100*256) & 0xFFFFFFFF,
                     REG['FS_HZ']: 800, REG['NFFT']: 1024}
        self.writes = []

    def read(self, off):
        return self.data.get(off, 0)

    def write(self, off, val):
        self.writes.append((off, val))
        self.data[off] = val


class HostTests(unittest.TestCase):
    def test_speed_diagnostic_displays_rpm_not_rpm_x100(self):
        class Board:
            enabled = False
            stopped = False
            def motor_stop(self): self.stopped = True
            def enable(self, en, axis): self.enabled = en
            def wait_frame(self): return True
            def features(self): return feature(rpm=300, rpm_min=300, rpm_max=300,
                                               i2c_errors=0, dropped=0)
            def _rd(self, offset):
                return {REG['VERSION']: 0x20002, REG['SPEED_AVG_PERIODS']: 20,
                        REG['PERIOD_CYC']: 1_000_000, REG['SPEED_WINDOW_COUNT']: 20}[offset]
        # 100 MHz / 1,000,000 cycles = 100 pulses/s; 20 pulses/turn = 300 RPM.
        board = Board()
        output = io.StringIO()
        with patch('test_speed_average.VibMonitor', return_value=board), \
             patch('sys.argv', ['test_speed_average.py', '--frames', '1']), \
             patch('sys.stdout', new=output):
            speed_check_main()
        self.assertIn('rawSlotRPM_now=300.00 ', output.getvalue())
        self.assertTrue(board.stopped and not board.enabled)

    def test_unknown_quality_and_untrained_speed(self):
        sb = SpeedBaseline(feature_mode='broadband')
        for _ in range(6):
            sb.update(feature(frame_flags=7))
        self.assertIsNotNone(sb.alarm(feature(frame_flags=7)))
        self.assertIsNone(sb.alarm(feature(rpm=305)))
        for flags in (0, 1, 3, 15 | 16, 15 | 32):
            self.assertIsNone(sb.alarm(feature(frame_flags=flags)))
        self.assertIsNone(sb.alarm(feature(rpm=0)))
        self.assertIsNone(sb.alarm(feature(rms=float('nan'))))
        self.assertIsNone(sb.alarm(feature(rpm=float('inf'))))
        self.assertIsNone(FixedThreshold(10).alarm(feature(frame_flags=0)))
        with self.assertRaises(ValueError):
            SpeedBaseline(k=float('nan'))
        self.assertEqual(score([], [])['coverage'], 0)
        self.assertFalse(usable(feature(frame_flags=7), 'orders'))
        self.assertTrue(usable(feature(frame_flags=7), 'broadband'))

    def test_evaluation_run_isolation_and_coverage(self):
        train = [feature(frame_id=i) for i in range(8)]
        test = [feature(run_id='test'), feature(run_id='test', frame_id=2, rpm=305)]
        report = evaluate(train, test)
        self.assertEqual(report['speed_baseline']['coverage'], 0.5)
        self.assertEqual(report['common_frames']['fixed']['coverage'], 0.5)
        with self.assertRaisesRegex(ValueError, 'disjoint'):
            evaluate(train, [feature()])
        with self.assertRaisesRegex(ValueError, 'configurations'):
            evaluate(train, [feature(run_id='other', fs_hz=200)])
        with self.assertRaisesRegex(ValueError, 'Training accepts'):
            evaluate([feature(condition='unbalance', label=1)], test)
        val = [feature(run_id='validation', frame_id=i) for i in range(6)]
        self.assertEqual(evaluate(train, test, validation=val)['threshold_source'], 'validation')
        self.assertEqual(score([0, 1], [None, None])['n_unknown'], 2)

    def driver(self):
        vm = VibMonitor.__new__(VibMonitor)
        vm.mmio = FakeMMIO()
        vm._last_frame = 1
        return vm

    def test_overlay_revisions_and_reject_unknown(self):
        fake_overlay = types.SimpleNamespace(ip_dict={'vib_top_0': {'phys_addr': 0x40000000}})
        for version in (0x00020001, 0x00020002, 0x00010000):
            mmio = FakeMMIO()
            mmio.data[REG['VERSION']] = version
            with patch('vib_monitor.Overlay', return_value=fake_overlay), \
                 patch('vib_monitor.MMIO', return_value=mmio):
                if version == 0x00010000:
                    with self.assertRaisesRegex(RuntimeError, 'frame-snapshot'):
                        VibMonitor('fake.bit')
                else:
                    self.assertEqual(VibMonitor('fake.bit').mmio, mmio)

    def test_settling_timeout_reports_quality_and_stops(self):
        class Board:
            stopped = False
            enabled = False
            def motor_stop(self): self.stopped = True
            def enable(self, en, axis): self.enabled = en
            def wait_frame(self): return True
            def features(self): return feature(frame_flags=3, i2c_errors=0)
        board = Board()
        with tempfile.TemporaryDirectory() as tmp:
            args = types.SimpleNamespace(frames=1, settle_frames=2, settle_timeout=0.01,
                duty=None, condition='normal', out=str(Path(tmp)/'timeout.csv'), bit='fake', axis=0)
            output = io.StringIO()
            with patch('run_measure._load_driver', return_value=board), \
                 patch('run_measure.time.monotonic', side_effect=[0, 0, 1]), \
                 patch('sys.stdout', new=output):
                with self.assertRaisesRegex(RuntimeError, 'Speed did not settle'):
                    cmd_collect(args)
            self.assertIn('range=104.00..106.00', output.getvalue())
            self.assertIn('flags=0x03', output.getvalue())
            self.assertTrue(board.stopped and not board.enabled)
            with open(args.out, newline='') as f:
                self.assertEqual(list(csv.DictReader(f)), [])

    def test_snapshot_coherence_and_signed_mean(self):
        vm = self.driver()
        self.assertEqual(vm.features()['mean'], -100.)
        original = vm.mmio.read
        calls = 0

        def read(off):
            nonlocal calls
            if off == REG['FRAME_ID']:
                calls += 1
                if calls == 2:
                    vm.mmio.data[off] = 2
            return original(off)
        vm.mmio.read = read
        self.assertEqual(vm.features()['frame_id'], 2)
        vm.mmio.data[REG['STATUS']] = 0
        with self.assertRaisesRegex(RuntimeError, 'No complete'):
            vm.features()

    def test_wait_frame_and_motor_validation(self):
        vm = self.driver()
        vm.mmio.data[REG['FRAME_ID']] = 2
        self.assertTrue(vm.wait_frame(timeout=0.01))
        self.assertFalse(vm.wait_frame(timeout=0.01))
        self.assertIn((REG['HEARTBEAT'], 1), vm.mmio.writes)
        for duty in (-0.1, 1.1, float('nan')):
            with self.assertRaises(ValueError):
                vm.motor(duty)
        vm.motor(0.5)
        self.assertIn((REG['MOTOR_DUTY'], 500), vm.mmio.writes)
        vm.motor_stop()
        self.assertEqual(vm.mmio.writes[-2:], [(REG['MOTOR_CTRL'], 0), (REG['MOTOR_DUTY'], 0)])

    def test_collector_explicit_label_streaming_and_exception_stop(self):
        class FakeBoard:
            def __init__(self):
                self.i = 0
                self.stopped = False
                self.enabled = False
            def enable(self, en, axis): self.enabled = en
            def motor_stop(self): self.stopped = True
            def wait_frame(self): self.i += 1; return True
            def features(self): return feature(frame_id=self.i)
            def heartbeat(self): pass
        with tempfile.TemporaryDirectory() as tmp:
            board = FakeBoard()
            args = types.SimpleNamespace(frames=2, settle_frames=2, settle_timeout=120,
                                         duty=None, condition='loose', out=str(Path(tmp)/'one.csv'),
                                         bit='fake.bit', axis=2)
            with patch('run_measure._load_driver', return_value=board), patch('sys.stdout', new=io.StringIO()):
                cmd_collect(args)
            with open(args.out, newline='') as fh:
                rows = list(csv.DictReader(fh))
            self.assertEqual(len(rows), 2)
            self.assertEqual([int(r['frame_id']) for r in rows], [3, 4])
            self.assertTrue(all(r['condition']=='loose' and r['label']=='1' for r in rows))
            self.assertTrue(board.stopped and not board.enabled)
            with self.assertRaises(FileExistsError):
                cmd_collect(args)
            args.out = str(Path(tmp)/'failed.csv')
            board.features = lambda: (_ for _ in ()).throw(RuntimeError('sensor failed'))
            with patch('run_measure._load_driver', return_value=board), patch('sys.stdout', new=io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, 'sensor failed'):
                    cmd_collect(args)
            self.assertTrue(board.stopped and not board.enabled)


if __name__ == '__main__':
    unittest.main(verbosity=2)
