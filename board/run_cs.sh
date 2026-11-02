#!/bin/bash
export XILINX_XRT=/usr
export BOARD=$(cat /proc/device-tree/chosen/pynq_board 2>/dev/null | tr -d "\0")
source /usr/local/share/pynq-venv/bin/activate
cd /home/xilinx/vib
python3 test_cs.py
