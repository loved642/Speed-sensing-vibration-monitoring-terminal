# Speed-aware vibration monitor terminal

2026 AMD FPGA contest, open-topic junior group. Platform: PYNQ-Z2 / XC7Z020CLG400-1; Vivado 2025.2; PYNQ Linux with Python.

## What actually works

PL implements ADXL345 I2C acquisition, 1024-sample frames at configured 800 Hz, demeaning, Hann window, fixed-point FFT, AC RMS/peak/spectral features, encoder capture, atomic AXI snapshots and motor PWM/watchdog. Firmware 0x00020002 averages 20 slot periods on a 20-slot wheel (one revolution), and requires a full fresh window after start/stop.

The final dataset contains 12 runs / 600 frames: normal and new-unbalance wheels, 50%/70% PWM, X/Y/Z selected sequentially, 50 frames per run. All retained final frames have flags 0x07, I2C errors 0, no recorded dropped/host-skipped/missing frames. The candidate new wheel shows higher RMS in this installation. This is descriptive evidence, not independent fault-classification accuracy. Earlier wheel/installation batches failed classification and are retained in the archive.

## Limits

- PWM duty is not RPM. The final mean speeds are about 75 and 113-115 RPM, measured by the encoder. No external RPM calibration or calibrated physical acceleration is claimed.
- XYZ are acquired in separate runs; do not align frame numbers as simultaneous vector samples.
- At 800 Hz / 1024 samples and low output RPM, 1x/2x +/-2-bin bands overlap or approach DC. Flags 0x07 mean broadband features are valid; orders mode requires bit3 as well and must reject these frames. Do not force flags or use overlapping bands to claim orders detection.
- Previously inspected data are development data. A Y-axis 70% RMS limit near 200 is a retrospective demonstration candidate, not a validated universal threshold. Physical alarm-onset latency was not measured.
- Board time was incorrect (CSV filenames show May 2025). Raw times are preserved; packaging/analysis date is 2026-11-02. Raw archive hash is in data/final_data_quality.json.

## Layout

src/ RTL; board/ PYNQ software, constraints and PS preset; board/deploy/ exact deployed package; build/ Tcl/ROMs and implementation reports; sim/ regressions; data/final/ 12 final CSVs; data/archive/ untouched complete logs archive; tools/ reproducible final analysis; skill/ reusable workflow; report/ design and collaboration evidence.

## Build the working PS+PL overlay

From this repository root, with Vivado 2025.2 in PATH:

    vivado -mode batch -source build/build_overlay.tcl

This uses the included TUL PYNQ-Z2 PS preset and board/overlay_pins.xdc. It outputs board/vib_monitor/vib.bit and vib.hwh. Keep bit/hwh paired. board/deploy/ contains the release used for the final measurements; never program the standalone PL-only build as a PYNQ overlay. Build outputs may differ byte-for-byte across environments. Baseline timing/resource evidence is in build/overlay_*.rpt.

## Verify

Install NumPy for host tests. On Windows with Vivado in PATH:

    powershell -File sim/run_sim.ps1
    python sim/test_host.py
    python sim/test_rms_speed_limit.py

See sim/verification_notes.md for environment setup and historical evidence. Test failures must be investigated; an xsim exit code alone is insufficient.

## Board setup and collection

Inspect board/overlay_pins.xdc before wiring. ADXL345 logic and FPGA signals are 3.3 V; use I2C pull-ups to 3.3 V. TB6612 uses separate motor power and a common ground. Fit the motor, wheel, encoder and sensor firmly before starting. The motor watchdog is an aid, not a mechanical guard.

Copy board/deploy/ to a USB drive. On the PYNQ board run its install.sh with sudo. It validates hashes, backs up replaced program files, preserves logs, and performs a motor-OFF system check.

    cd /home/xilinx/vib
    sudo bash ./run_speed_average.sh --duty 0.70
    sudo bash ./run_measure.sh collect --bit ./vib.bit --condition normal --axis 1 --duty 0.70 --frames 20 --settle-frames 2 --settle-timeout 30 --out logs/example_normal_y.csv

The collection command starts the motor. Change a wheel only after stopping. --condition is a human-provided physical label, not automatic recognition. axis=0/1/2 selects X/Y/Z; acquisition is sequential. Finally blocks stop the motor and disable acquisition on errors or Ctrl+C.

## Reproduce final data analysis without hardware

    python -m pip install matplotlib numpy
    python tools/analyze_final.py

Outputs under data/analysis/: summary, quality JSON and RMS plots. All input files are raw, not curated to remove misclassifications. Final analysis makes no independent accuracy claim.

## License and third-party material

Original project code is MIT licensed. TUL board preset/pin information, AMD Vivado-generated hardware handoff/bitstream and external dependencies retain their respective rights; see THIRD_PARTY_NOTICES.md. No proprietary tool executable is included. Public hosting and final upload require the entrant's review.

## Experiment and debugging notes

See [report/lessons_learned.md](report/lessons_learned.md) for the layered method, FFT arithmetic/memory/ordering, AXI address/handshake issues, the historical SPI-to-I2C transition, and quality-gated evaluation. It distinguishes developer recollections from final-source verification. Related historical repair/board records are in report/history/; their old resource numbers are not the final release metrics.
