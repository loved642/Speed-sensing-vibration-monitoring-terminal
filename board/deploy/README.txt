PYNQ-Z2 测速一圈滑动平均更新（2026-10-29）

版本：0x00020002。仅供当前100 MHz / 800 Hz / 1024点 / 20槽设计。

1. 改动
最近20个有效槽周期相加，按跨20槽的时间计算RPM，每个新槽更新一次。
首沿只建立计时，随后收满20个周期才发布有效RPM；停转1秒清空历史。
原始单槽周期仍在0x4C。0xA0/A4为当前窗口时钟总数；0xA8为20；0xAC为已收周期数。
帧内5%稳态门限没有放宽。它现在衡量的是一圈平均速度，不能声称圈内瞬时转速没有波动。
在80 RPM附近，一圈窗口约0.75秒；115 RPM附近约0.52秒。真实速度变化也会被平滑并延迟反映。

2. 部署（安装不会启动电机）
保持已有/home/xilinx/vib目录。复制整个pynq-speed-average-20261029文件夹至U盘。
板上挂载U盘后运行：
  sudo bash /mnt/usb/pynq-speed-average-20261029/install.sh
程序先校验SHA-256，再备份被替换的旧程序到/home/xilinx/vib_speed_backup_*。
只替换程序文件，已有logs目录保留。系统检查加载新bit/hwh但不启用电机或采集。
看到SYSTEM: PASS; version=0x00020002; AVG_PERIODS=20后再进行试转。

3. 正常轮70%诊断（会启动电机；8帧后停止，Ctrl+C提前停止）
  sudo bash /home/xilinx/vib/run_speed_average.sh --duty 0.70
观察RPM范围、span、flags、I2C和drops。稳态期通常期望flags=0x07；不能以此替代实测。
rawSlotRPM_now为当前单槽瞬时换算值，和帧均值不在完全相同时间点，仅用于诊断。

4. 诊断通过后采集
  cd /home/xilinx/vib
  tag=$(date +%Y%m%d_%H%M%S)
  sudo bash ./run_measure.sh collect --bit ./vib.bit --condition normal --axis 0 --duty 0.70 --frames 20 --settle-frames 2 --settle-timeout 30 --out "logs/avg20_normal_1to48_X_${tag}_duty0.70.csv"
新采集器会打印每个等待帧的RPM范围和flags，不再只在超时后报错。
不要混用0x00020001和0x00020002的数据训练/测试。评估器会拒绝混合固件版本。

5. 验证边界
离线仿真已通过：槽距交替误差、窗口未满、真实速度变化、停转重启；以及原I2C/FFT/AXI/主机回归。
Vivado构建通过后才生成此包；资源与时序见同目录报告。
初版固件已由用户部署：系统检查通过，正常轮70%档第2至8帧稳态通过，约112 RPM、帧内极差0.4%至0.9%、I2C和丢帧均为0。
初版诊断脚本rawSlotRPM_now误显示RPM乘100，本包已改正该显示及哈希；未修改FPGA或CSV转速算法。修正后的诊断脚本还未在板上复跑。
尚未完成独立RPM标定、异常识别和报警性能验收。
