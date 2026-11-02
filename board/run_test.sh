#!/bin/bash
set -euo pipefail
export XILINX_XRT=/usr
export BOARD="${BOARD:-Pynq-Z2}"
source /usr/local/share/pynq-venv/bin/activate
cd /home/xilinx/vib
python3 test_devid.py
