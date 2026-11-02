# Reusable PYNQ measurement and verification workflow

## Scope
AXI-Lite register/spectrum peripherals on PYNQ-compatible platforms. Transfer the workflow to other sensors or boards by changing the register contract, pin constraints, clock and scaling. Pin numbers and sensor voltage are never portable defaults.

## 1. State the interface contract
Document register offsets, widths, signedness, units, snapshot semantics, firmware version and quality bits before writing a host driver. Keep bit/hwh paired. Validate the version before starting an actuator. Source case: an incorrect diagnostic RPM factor printed RPM x100; the snapshot CSV path was unaffected. Unit tests with a known clock/period exposed this.

## 2. Bring up without motion
Keep acquisition and motor disabled; check hashes, version, sensor device ID, sampling counter and bus idle state first. Only then start an explicitly requested finite motor test with finally cleanup and heartbeat. A software watchdog is not a substitute for physical restraint.

## 3. Read coherent snapshots
Read frame_id, features, frame_id again. Retry when IDs differ. Publish a complete frame and its metadata together. Reject incomplete/unstable/clipped/overflow data as unknown. A nonzero cumulative I2C value is not an error per frame: report first, last and increases separately. Final-data audit has 600 frames with counters zero and no gaps; this validates this dataset only.

## 4. Validate numeric hardware independently
Use deterministic fixtures and an independent NumPy model. Match DC removal, window, FFT normalization, rounding, saturation and bin order, rather than only checking a dominant frequency. RTL regression compared 6144 positive-frequency bins. Synchronous RAM and explicit multiplier widths are part of the contract. Use PASS markers and reject fatal text even if xsim exits zero.

## 5. Preserve physical and statistical boundaries
Duty is not RPM. Gear ratio is not output RPM. Three sequential axes are not simultaneous vectors. Labels entered by an operator are not predictions. Reject overlapping rotation-order bands; at 800 Hz/1024 points the bin spacing is 0.78125 Hz and a ~1.25-1.9 Hz fundamental cannot meet the current separated +/-2-bin band condition.

## 6. Calibrate, freeze, then assess
Use disjoint physical runs for training/normal validation/tests. Do not split adjacent frames of one run and call them independent assemblies. Once a test informs feature selection, describe it as development. Keep failed runs as evidence. Refit after mounting changes; do not delete a batch merely because detection failed.

## Use
Use board/vib_monitor.py as a concrete MMIO example, sim/test_host.py for fake-MMIO tests, tools/analyze_final.py for frame/counter/config checks, and build/build_overlay.tcl for a path-relative PYNQ overlay recipe. Their register fields and clocks must be adapted for a different project.

## Failure conditions
Unknown firmware, wrong logic voltage, mismatched bit/hwh, inconsistent sample settings, incomplete windows, counter resets, duplicated frames, unresolved bands or absent calibration coverage require stopping that specific claim. Simulation success does not prove real wiring or fault separability. Final physical alarm latency and external RPM calibration remain unverified.
