#!/bin/bash
set -euo pipefail
export XILINX_XRT=/usr
export BOARD="${BOARD:-Pynq-Z2}"
source /usr/local/share/pynq-venv/bin/activate
cd "$(dirname "$0")"
exec python3 run_measure.py "$@"
