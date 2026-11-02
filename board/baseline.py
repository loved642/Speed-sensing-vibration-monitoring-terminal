"""
Two decision models compared in this project:

  1) FixedThreshold   - classic: alarm if rms > fixed constant (rpm-agnostic).
  2) SpeedBaseline    - our method: per-rpm-bin baseline of a rotation-relative
                        feature vector; alarm if Mahalanobis-like z-distance > k.

Training is explicit; models are frozen during evaluation. Decisions return
bool or None (unknown), with coverage reported separately.
"""
import numpy as np

FEATURE_NAMES = {
    'broadband': ['rms_per_rpm', 'crest'],
    'orders': ['band1_frac', 'band2_frac', 'rms_per_rpm', 'crest'],
}


def _vec(features, feature_mode='orders'):
    total = max(features['total_energy'], 1)
    rpm = max(features['rpm'], 1.0)
    broadband = [features['rms'] / rpm, features['peak'] / max(features['rms'], 1)]
    if feature_mode == 'broadband':
        values = broadband
    elif feature_mode == 'orders':
        values = [features['band1_energy'] / total,
                  features['band2_energy'] / total, *broadband]
    else:
        raise ValueError('feature_mode must be broadband or orders')
    return np.array(values, dtype=float)


class FixedThreshold:
    """Alarm when RMS exceeds a constant threshold (no rpm awareness)."""
    def __init__(self, rms_threshold):
        if not np.isfinite(rms_threshold) or rms_threshold < 0:
            raise ValueError('RMS threshold must be finite and nonnegative')
        self.th = rms_threshold

    def update(self, features):
        pass

    def alarm(self, features):
        if not usable(features, 'broadband'):
            return None
        return features['rms'] > self.th


class SpeedBaseline:
    """Per-rpm-bin baseline over the rotation-relative feature vector."""
    def __init__(self, bin_width=20.0, k=3.0, min_samples=5, feature_mode='orders'):
        if not np.all(np.isfinite([bin_width, k])) or bin_width <= 0 or k <= 0 or min_samples < 2:
            raise ValueError('Invalid baseline parameters')
        self.bin_width = bin_width
        self.k = k
        self.min_samples = min_samples
        if feature_mode not in FEATURE_NAMES:
            raise ValueError('feature_mode must be broadband or orders')
        self.feature_mode = feature_mode
        self.bins = {}   # bin_idx -> [sum_vec, sum_sq_vec, n]

    def _idx(self, rpm):
        return int(rpm // self.bin_width)

    def update(self, features):
        if not usable(features, self.feature_mode):
            raise ValueError('Invalid or unsteady calibration frame')
        i = self._idx(features['rpm'])
        v = _vec(features, self.feature_mode)
        if i not in self.bins:
            self.bins[i] = [np.zeros_like(v), np.zeros_like(v), 0]
        s, ss, n = self.bins[i]
        self.bins[i] = [s + v, ss + v * v, n + 1]

    def _stats(self, rpm):
        i = self._idx(rpm)
        if i in self.bins:
            s, ss, n = self.bins[i]
            if n >= self.min_samples:
                mean = s / n
                # Quantized integer RMS/peak must not create an almost-zero
                # variance and arbitrarily large scores on a one-count change.
                floors = np.array([0.5 / max(rpm, 1), 0.1])
                if self.feature_mode == 'orders':
                    floors = np.r_[0.01, 0.01, floors]
                var = np.maximum(ss / n - mean * mean,
                                 np.maximum(floors, np.abs(mean) * 0.05) ** 2)
                return mean, var, n
        return None, None, 0

    def alarm(self, features):
        if not usable(features, self.feature_mode):
            return None
        mean, var, n = self._stats(features['rpm'])
        if mean is None:
            return None                       # unknown is not healthy
        v = _vec(features, self.feature_mode)
        z = np.sqrt(np.sum((v - mean) ** 2 / var))
        return z > self.k

    def zscore(self, features):
        if not usable(features, self.feature_mode):
            return None
        mean, var, n = self._stats(features['rpm'])
        if mean is None:
            return None
        v = _vec(features, self.feature_mode)
        return float(np.sqrt(np.sum((v - mean) ** 2 / var)))


def usable(features, feature_mode='orders'):
    flags = features.get('frame_flags', 0)
    required = 7 if feature_mode == 'broadband' else 15
    scalars = [features.get(key, float('nan')) for key in
               ('rpm', 'rms', 'peak', 'total_energy', 'band1_energy', 'band2_energy')]
    return (all(np.isfinite(scalars)) and all(value >= 0 for value in scalars) and
            features.get('rpm', 0) > 0 and flags & required == required and
            flags & 48 == 0 and all(np.isfinite(_vec(features, feature_mode))))


def score(labels, preds):
    """Unknown predictions are excluded, with their coverage reported explicitly."""
    if len(labels) != len(preds):
        raise ValueError('Mismatched labels and predictions')
    valid = np.array([p is not None for p in preds], dtype=bool)
    labels = np.asarray(labels)
    if not np.all(np.isin(labels, [0, 1])):
        raise ValueError('Labels must be 0/1')
    predictions = np.array([bool(p) for p in preds], dtype=bool)[valid]
    scored = labels[valid]
    normal, abnormal = scored == 0, scored == 1
    fp, tn = int(np.sum(predictions & normal)), int(np.sum(~predictions & normal))
    fn, tp = int(np.sum(~predictions & abnormal)), int(np.sum(predictions & abnormal))
    return {'false_positive_rate': fp/(tn+fp) if tn+fp else None,
            'miss_rate': fn/(tp+fn) if tp+fn else None,
            'accuracy': (tp+tn)/len(scored) if len(scored) else None,
            'tp': tp, 'tn': tn, 'fp': fp, 'fn': fn,
            'n_unknown': int(np.sum(~valid)),
            'coverage': float(np.mean(valid)) if len(valid) else 0.0}
