# 开发板部署与系统检查记录（2026-10-20）

来源：用户在 PuTTY 中执行命令后提供的原始输出。系统部署时仅连接供电与 USB；随后接入 ADXL345 并通过短时采集检查，电机和测速头尚未验证。本会话未通过串口或网络直接读取板上输出。

## 已通过的实板检查

- 安装所需四个文件 SHA-256 校验通过；部署完成，旧目录已备份。
- 板上 bit/hwh SHA-256 与构建清单一致。
- Overlay 加载后 AXI 基址为 `0x40000000`，固件版本为 `0x00020001`。
- 800 Hz / 1024 点 / 20 槽配置寄存器及 CTRL 读写检查通过。
- 电机及传感器采集均保持禁用；禁用期间样本计数不增加，没有完成帧。
- 无传感器且采集禁用时，I2C_STATUS=`0x0000000C`，表示采样到的 SCL/SDA 均为高；此结果不能验证接上传感器后的总线电气性能。

这不证明实际 FPGA 时钟已被独立测量，也不代表传感器、FFT 实际信号链、测速、电机或异常检测已通过实测。此前离线仿真与构建记录仍单独保留。

## 用户提供的板上输出

```text
install.sh: OK
run_system_check.sh: OK
system_check.py: OK
vib_deploy_20261019.zip: OK
INSTALL: PASS -> /home/xilinx/vib
PREVIOUS FILES: /home/xilinx/vib_backup_20250503-202819-685035
Motor remains disabled. Starting system-only check (no sensor required).
BIT/HWH SHA-256: PASS
Linux: 6.6.10-xilinx-v2024.1-g3c0eca68c652 Python: 3.10.4
AXI base=0x40000000; version=0x00020001
Configuration: 100 MHz design / 800 Hz / 1024 samples / 20 slots
AXI CTRL write/read: PASS
Motor: DISABLED; sensor acquisition: DISABLED
I2C_STATUS=0x0000000C; motor status=0x00000000
SYSTEM: PASS
This checks board/overlay/AXI only; sensor, speed and motor are NOT verified.
After power-off and sensor wiring: sudo bash /home/xilinx/vib/run_test.sh
Log: /home/xilinx/vib/logs/system_check_20250503-202820.txt
```

## 后续

1. 关机、切断供电后按项目 PmodA 接线连接 ADXL345，重新启动后执行 `sudo bash /home/xilinx/vib/run_test.sh`。
2. 验证 DEVID=E5、ready=1、采样计数增加、静止与移动响应，再进行连续帧检查。
3. 板上日期显示为 2025-05-03，与本次会话日期 2026-10-20 不符。现有日志保留其原名；正式实验采集前校正板上时钟，避免会话时间及实验记录混淆。

## ADXL345 首次实板通过

用户执行 `sudo bash /home/xilinx/vib/run_test.sh` 后提供：

```text
IPs: ['ps7', 'vib_top_0']
vib_top_0 base = 0x40000000
DEVID = 0xE5; ready=1
I2C   = 0x00000007; SCL=1 SDA=0; error=none
Faults=0; failed transaction=0 step=0
FS_HZ=800; CTRL=0x00000001
Samples in 0.1 s = 80; total=89
RAW_X=17
RAW_Y=-225
RAW_Z=-102
RPMx100=0; PEAK=0; RMS=0
SENSOR: PASS (ID/configuration and sample progress; verify motion on hardware)
```

该结果支持地址/初始化配置成功、设备ID正确、短时采样进度符合800Hz且无已记录的通信错误。总样本数89小于每帧1024，尚未发布FFT/特征帧；此时RMS与PEAK为零不能据此判断后续特征链正常或异常。SDA=0为启用采集时的瞬间状态，不是空闲总线测量。

接下来使用 `board/test_frames.py` 检查12个连续快照、频谱求和与总能量一致性、I2C错误计数，并由人观察静止→轻动→静止时RMS/峰值响应。脚本仅在电脑工程内新增，尚未更新先前部署包或传至开发板。完整运动响应、长时间稳定性和独立转换采样节奏仍待验证。

## 12帧实板检查：数据通路通过，运动响应待确认

用户执行在PuTTY中粘贴的12帧检查后提供：

```text
--- KEEP STILL ---
frame=1 RMS=51 peak=377 flags=0x1 errors=0 drops=0
frame=2 RMS=15 peak=424 flags=0x1 errors=0 drops=0
frame=3 RMS=2 peak=9 flags=0x1 errors=0 drops=0
frame=4 RMS=2 peak=10 flags=0x1 errors=0 drops=0
--- GENTLY MOVE OR TAP ---
frame=5 RMS=2 peak=9 flags=0x1 errors=0 drops=0
frame=6 RMS=2 peak=10 flags=0x1 errors=0 drops=0
frame=7 RMS=2 peak=9 flags=0x1 errors=0 drops=0
frame=8 RMS=2 peak=10 flags=0x1 errors=0 drops=0
--- KEEP STILL AGAIN ---
frame=9 RMS=2 peak=9 flags=0x1 errors=0 drops=0
frame=10 RMS=2 peak=9 flags=0x1 errors=0 drops=0
frame=11 RMS=2 peak=8 flags=0x1 errors=0 drops=0
frame=12 RMS=2 peak=11 flags=0x1 errors=0 drops=0
PIPELINE: PASS; inspect motion response.
```

检查脚本逐帧读取512个频点并核对去DC频谱和等于发布的总能量，12帧均通过；帧号连续且已记录通信错误、处理丢帧均为零。此结果支持实际传感器到特征/频谱快照的数据通路工作，尚不能独立证明频谱数值正确或采样转换无重复/遗漏。

flags=0x1表示完整帧；未接测速时速度、稳态及阶次频带有效位未置位符合预期。没有报告FFT溢出或传感器裁剪标志。第1/2帧有较大波动，后续RMS约2、峰值8至11；不能从输出确定最初波动的原因。用户随后澄清，第一轮整个测试期间没有晃动传感器，因此该轮不能作为运动响应测试；原计划增加三轴原始值诊断，已由下面的重复运动测试取代。

## 重复运动测试：观察到静止/晃动差异

用户按提示重新测试后提供：

```text
--- KEEP STILL ---
frame=1 RMS=2 peak=13 flags=0x1 errors=0 drops=0
frame=2 RMS=2 peak=12 flags=0x1 errors=0 drops=0
frame=3 RMS=1 peak=10 flags=0x1 errors=0 drops=0
frame=4 RMS=2 peak=10 flags=0x1 errors=0 drops=0
--- GENTLY MOVE OR TAP ---
frame=5 RMS=1 peak=8 flags=0x1 errors=0 drops=0
frame=6 RMS=1 peak=11 flags=0x1 errors=0 drops=0
frame=7 RMS=11 peak=101 flags=0x1 errors=0 drops=0
frame=8 RMS=15 peak=82 flags=0x1 errors=0 drops=0
--- KEEP STILL AGAIN ---
frame=9 RMS=8 peak=64 flags=0x1 errors=0 drops=0
frame=10 RMS=2 peak=11 flags=0x1 errors=0 drops=0
frame=11 RMS=8 peak=110 flags=0x1 errors=0 drops=0
frame=12 RMS=2 peak=21 flags=0x1 errors=0 drops=0
PIPELINE: PASS; inspect motion response.
```

静止阶段RMS=1至2，运动阶段第7/8帧RMS升至11/15、峰值101/82，随后有帧恢复RMS=2，支持实际运动输入会改变振动特征。第二静止阶段第9/11帧仍有波动，原因尚不能从本日志判定；不能据此宣称稳定性已完全验证或用这些手动动作数据建立电机故障检测性能指标。12帧的频谱求和一致性检查通过，通信错误及处理丢帧均为零。当前结论为传感器和特征数据通路初步实板通过；下一步识别测速头引脚/供电、接线并验证脉冲输入。

核对购买清单中的图片：测速头为“码盘计数传感器3脚”，码盘为“20栅格方孔”；清单没有明确测速模块型号、引脚顺序或供电范围，需先核对实物，再将数字输出接至PmodA第7脚/U18。该核对不改变RTL或既有部署包。

## 测速头手动遮挡：脉冲输入与周期换算通过初步实测

用户提供的测速头照片中可辨认三引脚丝印为OUT/VCC/GND，尚未确认具体型号及额定供电范围。按3.3V试测方案连接：OUT至PmodA第7脚/U18，VCC至第12脚/3.3V，GND至第11脚。用户随后执行既有run_speed.sh并提供输出：

```text
Reading RPM for 6 s ... spin the motor / wave a slotted card through the sensor.
t= 0.0s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x00
t= 0.5s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x00
t= 1.0s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x00
t= 1.5s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x1A
t= 2.0s  RPM=     15.68  rpm_x100=      1568  period=  19127747  status=0x1E
t= 2.5s  RPM=     24.03  rpm_x100=      2403  period=  12481817  status=0x1E
t= 3.0s  RPM=     27.78  rpm_x100=      2778  period=  10797700  status=0x1E
t= 3.5s  RPM=     18.26  rpm_x100=      1826  period=  16427300  status=0x1E
t= 4.0s  RPM=     23.63  rpm_x100=      2363  period=  12692631  status=0x1E
t= 4.5s  RPM=     58.65  rpm_x100=      5865  period=   5114689  status=0x1E
t= 5.0s  RPM=     14.07  rpm_x100=      1407  period=  21319003  status=0x1E
t= 5.5s  RPM=     23.68  rpm_x100=      2368  period=  12666289  status=0x1E
```

status=0x1E包含测速有效位(bit2)，周期和RPM在更新。以100MHz设计时钟、20脉冲/圈计算，period=19127747应换算约15.684RPM，与输出15.68一致。手动遮挡的数值不是实际电机转速，也未与独立时间/转速参考比较；本次只支持测速头输入、PL周期捕获及换算链路初步工作。停止后约1秒归零、码盘实际每圈脉冲数、电机运行时脉冲质量及测速精度仍待实测。

## 停止遮挡后的归零检查通过

用户再次运行run_speed.sh，在前段遮挡、后段停止后提供：

```text
t= 0.0s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x00
t= 0.5s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x00
t= 1.0s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x00
t= 1.5s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x1A
t= 2.0s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x1A
t= 2.5s  RPM=     25.35  rpm_x100=      2535  period=  11833686  status=0x1E
t= 3.0s  RPM=     25.54  rpm_x100=      2554  period=  11746124  status=0x1E
t= 3.5s  RPM=     21.25  rpm_x100=      2125  period=  14111419  status=0x1E
t= 4.0s  RPM=     21.25  rpm_x100=      2125  period=  14111419  status=0x1E
t= 4.5s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x1A
t= 5.0s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x1A
t= 5.5s  RPM=      0.00  rpm_x100=         0  period=         0  status=0x1A
```

停止动作后RPM及周期归零，status的bit2由1清零，并连续保持零，支持停脉冲超时清除机制已实板工作。最后脉冲的实际时间未独立记录，0.5秒间隔的输出不足以精确测定1秒超时时长。下一步核对TB6612FNG实物丝印与电机电源参数，再进行断电接线、空载启动和实际码盘测速；PWM/方向/心跳停机尚未实板验证。

## 电机驱动与供电核对（尚未试转）

用户提供驱动模块正反面照片，背面丝印可辨认：左列由上至下PWMA、AIN2、AIN1、STBY、BIN1、BIN2、PWMB、GND；右列VM、VCC、GND、AO1、AO2、BO2、BO1、GND。芯片具体字样在照片中不够清晰，模块布局/丝印符合本项目TB6612FNG驱动方案。用户说明电机电源为5V/2A，极性及负载能力尚未独立测量。

已重新核对overlay_pins.xdc：PmodB第1脚/W14为PWMA，第2脚/Y14为AIN1，第3脚/T11为AIN2，第4脚/T10为STBY；VCC拟接PmodB第6脚3.3V，GND接第5脚。外部5V正极接VM，负极接驱动GND并与开发板共地；电机两线接AO1/AO2。AIN2在实物上排列于AIN1上方，接线应按丝印识别，不可顺次猜测。外部电机电源不能接入Pmod的3.3V电源脚，驱动逻辑VCC本方案使用3.3V。

本节为接线方案核对，未宣称用户已完成接线或电机已运行。接线需在板子和电机电源断电时进行，后续先固定电机再做短时试转。

## 部署兼容性修复

原 U 盘 SHA256SUMS 包含中文说明文件名，板上无法按该名字打开说明文件，导致安装前校验中止。用户将文件复制到 `/tmp/pynq-usb-deploy-20261020` 并保留清单前四个程序文件条目后安装成功，四个程序文件的完整性校验仍执行。本地安装资料已改为 ASCII 说明文件名 README.txt，清单仅包含四个必需程序文件；板上的只读 U 盘未被改写。
