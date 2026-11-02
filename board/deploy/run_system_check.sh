#!/bin/bash
set -euo pipefail
export XILINX_XRT=/usr
export BOARD="${BOARD:-Pynq-Z2}"
cd /home/xilinx/vib
exec /usr/local/share/pynq-venv/bin/python3 -u system_check.py
