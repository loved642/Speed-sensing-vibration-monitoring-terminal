"""Current I2C firmware diagnostic, replacing the obsolete SPI mode-latch test."""
import runpy
from pathlib import Path

print('SPI CS-hold mode was removed. Running I2C ID/sample diagnostics instead.')
runpy.run_path(str(Path(__file__).with_name('test_devid.py')), run_name='__main__')
