"""
Speed-aware vibration monitor - PYNQ host driver.

Loads the PL overlay and exposes the register map + spectrum memory.
Register map (byte offsets from the AXI-Lite base):
  0x00 CTRL   : [0]=enable, [9:8]=axis_sel (0=x,1=y,2=z)          (RW)
  0x04 FS_HZ  : sample rate (RO)
  0x08 SLOTS  : photoelectric slots per revolution (RO)
  0x0C STATUS : [0]=fft_busy,[2]=speed_valid,
                [1,3,4]=complete snapshot available (sticky)        (RO)
  0x10 RPM_X100, 0x14 BIN1X, 0x18 BIN2X, 0x1C PEAK, 0x20 RMS      (RO)
  0x24 SUMSQ_LO, 0x28 SUMSQ_HI
  0x2C TOTAL_E_LO, 0x30 TOTAL_E_HI
  0x34 BAND1_LO,  0x38 BAND1_HI
  0x3C BAND2_LO,  0x40 BAND2_HI
  0x44 DOM_BIN, 0x48 DOM_POW, 0x4C PERIOD_CYC
  0x50 DEVID  : ADXL345 device id sampled at bring-up (expect 0xE5)  (RO)
  0x58 I2C_STATUS : ready/busy, bus levels, last error/step, error count
  0x5C SAMPLE_COUNT; 0x60/64/68 RAW_X/Y/Z (sign-extended)
  0x6C FRAME_ID; 0x70 FLAGS: complete/speed/steady/bands/overflow/clipping
  0x74..0x80 snapshot speed/min/max/mean; 0x84 drops; 0x88 version; 0x8C NFFT
  0x90 MOTOR_CTRL; 0x94 DUTY (0..1000); 0x98 heartbeat; 0x9C motor status
  v0x00020002: RPM is a rolling one-revolution period average; 0x4C stays raw.
  0xA0/A4 SPEED_WINDOW_LO/HI; 0xA8 AVG_PERIODS; 0xAC WINDOW_COUNT (live)
  0x1000.. : spectrum, 512 x 32-bit (|FFT(Hann*(x-mean))/N|^2 * 256)
"""
import time
import numpy as np
from pynq import Overlay, MMIO

REG = {
    'CTRL': 0x00, 'FS_HZ': 0x04, 'SLOTS': 0x08, 'STATUS': 0x0C,
    'RPM_X100': 0x10, 'BIN1X': 0x14, 'BIN2X': 0x18, 'PEAK': 0x1C, 'RMS': 0x20,
    'SUMSQ_LO': 0x24, 'SUMSQ_HI': 0x28,
    'TOTAL_E_LO': 0x2C, 'TOTAL_E_HI': 0x30,
    'BAND1_LO': 0x34, 'BAND1_HI': 0x38,
    'BAND2_LO': 0x3C, 'BAND2_HI': 0x40,
    'DOM_BIN': 0x44, 'DOM_POW': 0x48, 'PERIOD_CYC': 0x4C,
    'DEVID': 0x50, 'FRAME_ID': 0x6C, 'FRAME_FLAGS': 0x70,
    'FRAME_RPM': 0x74, 'RPM_MIN': 0x78, 'RPM_MAX': 0x7C,
    'MEAN_Q8': 0x80, 'DROPPED': 0x84, 'VERSION': 0x88, 'NFFT': 0x8C,
    'MOTOR_CTRL': 0x90, 'MOTOR_DUTY': 0x94, 'HEARTBEAT': 0x98, 'MOTOR_STATUS': 0x9C,
    'SPEED_WINDOW_LO': 0xA0, 'SPEED_WINDOW_HI': 0xA4,
    'SPEED_AVG_PERIODS': 0xA8, 'SPEED_WINDOW_COUNT': 0xAC,
    'I2C_STATUS': 0x58, 'SAMPLE_COUNT': 0x5C,
    'RAW_X': 0x60, 'RAW_Y': 0x64, 'RAW_Z': 0x68,
}
SPECTRUM_BASE = 0x1000
SPECTRUM_BINS = 512


class VibMonitor:
    def __init__(self, bitfile, ip_name='vib_top_0'):
        self.ol = Overlay(bitfile)
        ip = self.ol.ip_dict[ip_name]
        base = ip.get('phys_addr', ip.get('base_address'))
        if base is None:
            raise ValueError('Overlay IP metadata has no physical base address')
        self.mmio = MMIO(base, 0x1000 + 4 * SPECTRUM_BINS)
        if self._rd(REG['VERSION']) not in (0x00020001, 0x00020002):
            raise RuntimeError('Replace both vib.bit and vib.hwh with the frame-snapshot overlay')
        self._last_frame = self._rd(REG['FRAME_ID'])

    # ---- low level ----
    def _rd(self, off):
        return self.mmio.read(off)

    def _wr(self, off, val):
        self.mmio.write(off, val)

    def enable(self, en=True, axis=2):
        if axis not in (0, 1, 2):
            raise ValueError('axis must be 0, 1 or 2')
        self._wr(REG['CTRL'], (1 if en else 0) | (axis << 8))
        self._last_frame = self._rd(REG['FRAME_ID'])

    def status(self):
        s = self._rd(REG['STATUS'])
        return {'fft_busy': s & 1, 'fft_done': (s >> 1) & 1, 'speed_valid': (s >> 2) & 1,
                'ft_valid': (s >> 3) & 1, 'feat_valid': (s >> 4) & 1}

    def rpm(self):
        return self._rd(REG['RPM_X100']) / 100.0

    def devid(self):
        return self._rd(REG['DEVID'])

    def sensor_status(self):
        s = self._rd(REG['I2C_STATUS'])
        if s == 0xDEADBEEF:
            raise RuntimeError('Load the updated overlay to access I2C diagnostics')
        errors = {0: 'none', 1: 'NACK', 2: 'SDA stuck low',
                  3: 'SCL timeout', 4: 'unexpected DEVID'}
        code = (s >> 4) & 0xF
        return {'ready': bool(s & 1), 'busy': bool(s & 2),
                'scl': (s >> 2) & 1, 'sda': (s >> 3) & 1,
                'error_code': code, 'error': errors.get(code, 'unknown'),
                'failed_transaction': (s >> 12) & 7,
                'failed_step': (s >> 8) & 0xF, 'error_count': s >> 16,
                'sample_count': self._rd(REG['SAMPLE_COUNT'])}

    def motor_stop(self):
        self._wr(REG['MOTOR_CTRL'], 0)
        self._wr(REG['MOTOR_DUTY'], 0)

    def motor(self, duty, reverse=False):
        if not 0 <= duty <= 1:
            raise ValueError('duty must be between 0 and 1')
        self._wr(REG['MOTOR_DUTY'], round(duty * 1000))
        self._wr(REG['MOTOR_CTRL'], (1 if duty else 0) | (int(reverse) << 1))

    def heartbeat(self):
        # Required at least once per second while armed; collection uses 5 ms.
        self._wr(REG['HEARTBEAT'], 1)

    def features(self, include_spectrum=False):
        for _ in range(5):
            first = self._rd(REG['FRAME_ID'])
            if not (self._rd(REG['STATUS']) & 16):
                raise RuntimeError('No complete valid frame is available')
            def pair(low, high):
                return self._rd(REG[low]) | (self._rd(REG[high]) << 32)
            flags = self._rd(REG['FRAME_FLAGS'])
            mean = self._rd(REG['MEAN_Q8'])
            if mean & 0x80000000:
                mean -= 1 << 32
            result = {
                'frame_id': first, 'frame_flags': flags,
                'rpm': self._rd(REG['FRAME_RPM']) / 100.0,
                'rpm_min': self._rd(REG['RPM_MIN']) / 100.0,
                'rpm_max': self._rd(REG['RPM_MAX']) / 100.0,
                'bin1x': self._rd(REG['BIN1X']), 'bin2x': self._rd(REG['BIN2X']),
                'rms': self._rd(REG['RMS']), 'peak': self._rd(REG['PEAK']),
                'sumsq': pair('SUMSQ_LO', 'SUMSQ_HI'),
                'total_energy': pair('TOTAL_E_LO', 'TOTAL_E_HI'),
                'band1_energy': pair('BAND1_LO', 'BAND1_HI'),
                'band2_energy': pair('BAND2_LO', 'BAND2_HI'),
                'dom_bin': self._rd(REG['DOM_BIN']), 'dom_pow': self._rd(REG['DOM_POW']),
                'mean': mean / 256.0, 'fs_hz': self._rd(REG['FS_HZ']),
                'nfft': self._rd(REG['NFFT']), 'power_scale': 256,
                'slots': self._rd(REG['SLOTS']), 'version': self._rd(REG['VERSION']),
                'dropped': self._rd(REG['DROPPED']),
                'i2c_errors': self.sensor_status()['error_count'],
                'speed_valid': bool(flags & 2), 'steady': bool(flags & 4),
                'bands_valid': bool(flags & 8),
            }
            if include_spectrum:
                result['spectrum'] = np.array([
                    self._rd(SPECTRUM_BASE + 4*k) for k in range(SPECTRUM_BINS)
                ], dtype=np.uint32)
            if (first == self._rd(REG['FRAME_ID']) and
                    self._rd(REG['STATUS']) & 16 and self.sensor_status()['ready']):
                return result
        raise RuntimeError('Frame changed during read; retry acquisition')

    def spectrum(self):
        return self.features(include_spectrum=True)['spectrum']

    def wait_frame(self, timeout=None):
        if timeout is None:
            timeout = 3 * self._rd(REG['NFFT']) / self._rd(REG['FS_HZ']) + 1
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.heartbeat()
            current = self._rd(REG['FRAME_ID'])
            if current != self._last_frame and self._rd(REG['STATUS']) & 16:
                self._last_frame = current
                return True
            time.sleep(0.005)
        return False

    # ---- feature vector used for baseline/anomaly ----
    def feature_vector(self):
        f = self.features()
        total = max(f['total_energy'], 1)
        # rotation-relative, speed-normalized features (dimensionless, rpm-independent)
        return np.array([
            f['band1_energy'] / total,      # energy fraction near 1x
            f['band2_energy'] / total,      # energy fraction near 2x
            f['rms'] / max(f['rpm'], 1.0),  # rms per rpm
            f['peak'] / max(f['rms'], 1),   # crest factor
        ], dtype=float)
