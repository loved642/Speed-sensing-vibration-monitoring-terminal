import sys, os, traceback
print('python', sys.version.split()[0])
try:
    import pynq
    print('pynq', pynq.__version__, 'at', os.path.dirname(pynq.__file__))
except Exception as e:
    print('import pynq FAILED:', repr(e))
try:
    from pynq import Overlay
    print('loading overlay...')
    ol = Overlay('/home/xilinx/vib/vib.bit')
    print('ip_dict:', sorted(ol.ip_dict.keys()))
except Exception as e:
    print('overlay FAILED:')
    traceback.print_exc()