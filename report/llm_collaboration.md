# LLM collaboration evidence (selected conversation excerpts)

These are selected human/assistant excerpts retained from the development conversation, not a complete exported transcript. Human wiring, fastening, wheel changes and board commands produced the physical measurements. No AMD ROSS toolkit was used. The assistant is Codex; the precise model version is not asserted. Full original chat can be exported by the entrant if needed; these excerpts preserve the correction trajectory without private account or school data.

## Case 1: speed settling
Human evidence: frames near 113 RPM had roughly 8-12% intra-frame ranges, flags=0x03, no I2C faults/drops; collector raised "Speed did not settle".
Assistant action: investigated slot-period measurement; implemented a rolling sum over 20 slot periods. Did not relax the 5% steady criterion. Regression covered window fill, alternating slot spacing, true speed step, stop and restart.
Human board feedback: firmware 0x00020002, AVG_PERIODS=20; after the startup frame, seven frames showed flags=0x07 and 0.4-0.9% filtered span.
Correction: rawSlotRPM_now diagnostic used factor 6000 where RPM requires 60, displaying x100. Only that diagnostic script was fixed; no claim that single-slot and frame-time samples coincide. A one-turn window also smooths real within-turn motion, so reduced span is not a calibrated precision claim.

## Case 2: invalid orders feature
Assistant instruction: "下一步用同一批新安装数据测试包含频带能量的 orders 模型".
Human feedback: ValueError: No usable calibration frames; inspect quality flags and feature mode.
Assistant correction: "之前直接让你运行这个模式，遗漏了对 flags=0x07 的检查。" Source review showed orders requires bit3 / separated 1x/2x bands, while final low-speed frames only have flags=0x07. Broadband remained usable. No flags or band values were fabricated to bypass validity.

## Case 3: avoid test-driven threshold claims
Human evidence: original fixed threshold TP=1,FN=79; speed baseline TP=2,FN=78 on a recheck batch. Peak/RMS threshold scan also produced poor false-alarm/miss tradeoffs.
Assistant correction: retained failed results; later thresholds inspected on the same batch were explicitly called development candidates. The final new wheel had larger RMS differences; these are descriptive comparisons, not independent classification accuracy.

## Case 4: mounting and axes
Human prompts: "怀疑是加速度传感器松了"; "我的建议是把XYZ三个方向都测一下"; "多测一点数据，再测一次正常轮，后续就不测了".
Assistant workflow: preserved suspect history, separated mounting batches, switched software axis with sensor fixed, then collected 50 frames per condition/duty/axis. Final 12 CSVs/600 frames passed counter/flag/gap audit.
Correction in final submission: sequential axis means cannot be described as synchronous three-axis vector RMS. A different wheel is a different mechanical configuration, not repeat validation of the old wheel.

## Reusable results
The extracted skill/ workflow covers interface contracts, coherent snapshots, units, frame-quality auditing, independent numeric reference, run isolation and physical validity. The source, simulation scripts, data hashes and limitations make the collaboration inspectable rather than attributing physical testing to the assistant.
