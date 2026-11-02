# Packaged-source verification, 2026-11-02

Windows / Vivado 2025.2 / Python 3.13 / NumPy. Executed from this packaged source tree.

- I2C: PASS, 6271 protocol/recovery checks.
- FFT: PASS, 12 frames and all 6144 positive-frequency bins against NumPy.
- Speed: PASS, warm-up, slot pitch, true step, timeout and fresh restart.
- AXI: PASS, transactions, snapshots, full spectrum, sensor recovery, motor PWM/watchdog.
- Host driver/collector: 8 tests PASS.
- Candidate RMS limit workflow: 8 tests PASS.
- Final-data audit: 12 CSVs, 12 distinct run IDs, 600 frames, flags 0x07, all counters/gaps zero.
- Release payload and recorded source SHA-256 entries: PASS; see release_hash_verification.json.

Implementation was not rebuilt on this packaging date. Timing and utilization are from the retained 2026-10-29 release reports. Physical evidence comes from the user's recorded board logs, not a new hardware test on this PC. No external RPM calibration, independent classifier validation or physical alarm latency was added.
