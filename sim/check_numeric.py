"""Independent NumPy reference for full FFT spectra, including low amplitudes."""
from pathlib import Path
import sys
import numpy as np
WORK=Path(__file__).resolve().parent/'work'
WORK.mkdir(exist_ok=True)
N=1024
if sys.argv[1]=='generate':
 n=np.arange(N);rng=np.random.default_rng(20261019)
 frames=[np.full(N,256),*[np.rint(3000*np.sin(2*np.pi*k*n/N)) for k in (1,8,13,17,127,255,511)],
  np.rint(256+4*np.sin(2*np.pi*17*n/N)+2*np.cos(2*np.pi*34*n/N)),
  np.rint(256+30*np.sin(2*np.pi*13.3*n/N)),rng.integers(-512,513,N),np.full(N,-1024)]
 frames=np.array(frames,dtype=np.int64)
 np.save(WORK/'numeric_frames.npy',frames)
 (WORK/'numeric_frames.mem').write_text('\n'.join(f'{int(v)&65535:04X}' for v in frames.flat)+'\n')
 print('Generated',len(frames),'reference frames')
else:
 frames=np.load(WORK/'numeric_frames.npy')
 rows=np.loadtxt(WORK/'fft_actual.csv',delimiter=',',dtype=np.int64)
 win=np.array([int(v,16) for v in (WORK/'hann.mem').read_text().split()])/32768
 for case,frame in enumerate(frames):
  r=rows[rows[:,0]==case]
  assert r.shape==(512,3), (case,r.shape)
  assert np.array_equal(r[:,1],np.arange(512)),f'case {case}: missing/reordered bins'
  # Hardware mean is Q8, arithmetic shift toward negative infinity.
  mean=((int(frame.sum())>>2)/256)
  expected=np.abs(np.fft.fft((frame-mean)*win)/1024)[:512]**2*256
  actual=r[:,2]
  # Q8 arithmetic has bounded rounding; compare amplitude errors, not large
  # relative errors in bins whose exact power is effectively zero.
  amplitude_error=np.abs(np.sqrt(actual/256)-np.sqrt(expected/256))
  assert np.max(amplitude_error)<0.13,(case,float(np.max(amplitude_error)))
  if np.max(expected)>256:
   assert np.argmax(actual)==np.argmax(expected),(case,np.argmax(actual),np.argmax(expected))
  print(f'FFT_REF case={case} peak={np.argmax(actual)} max_amplitude_error={np.max(amplitude_error):.6f} counts')
 print('NUMERIC: PASS all 6144 positive-frequency bins against NumPy')
