# Verification provenance

RTL sources and release artifacts correspond to firmware 0x00020002. The original project build record reports I2C 6271 checks, FFT 12 frames/6144 positive-frequency bins, speed capture window/step/timeout/restart, AXI snapshots and PWM/watchdog tests passing. Existing evidence is retained in verification logs where available. Run the packaged sim/run_sim.ps1 to regenerate results.

Environment: Vivado 2025.2, Python with NumPy, PowerShell. Set VIVADO_BIN to the Vivado bin folder and VIB_PYTHON to a Python executable when these are not in PATH. All source/data references are relative to this repository. The simulation runner was adapted only for environment discovery; RTL and deployed bit/hwh were not modified in submission preparation.

Historical implementation evidence: 100 MHz, WNS 0.903 ns, TNS 0; LUT 5264, FF 4291, BRAM 3, DSP 16. See original reports for exact report scope. Software frame time is configured as 1024/800=1.28 seconds; no end-to-end fault onset latency measurement exists.
