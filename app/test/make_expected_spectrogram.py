#!/usr/bin/env python
"""Regenerates expected_spectrogram.csv: scipy's spectrogram of a made-up test signal, computed
exactly as serial_spectrogram.py does. The Dart tests compare the app's spectrogram against it.
Run from anywhere: python app/test/make_expected_spectrogram.py
"""
import os
import numpy as np
from scipy.signal import spectrogram

here = os.path.dirname(os.path.abspath(__file__))
N_full, N_sub, overlap = 4096, 128, 0.875

n = np.arange(N_full)
x = np.sin(0.37 * n) + 0.3 * np.cos(1.91 * n) + 1e-3 * n + 0.05 * np.sin(1.23e-4 * n**2)  # same formula in the Dart test

freqs, times, sg = spectrogram(x, fs=200, window='hamming', nperseg=N_sub, noverlap=overlap*N_sub, detrend='linear')
Z = np.log(sg.T[:, 1:])  # what serial_spectrogram.py passes to image()
columns = [0, 1, 123, len(times) - 1]
with open(os.path.join(here, 'expected_spectrogram.csv'), 'w') as f:
    f.write('# line 1: number of segments, first and last time, 2% and 98% quantiles of Z\n')
    f.write('# then: segment index, log(psd) at all 65 frequencies\n')
    f.write('%d,%r,%r,%r,%r\n' % (len(times), times[0], times[-1], np.quantile(Z, 0.02), np.quantile(Z, 0.98)))
    for c in columns:
        f.write('%d,' % c + ','.join(repr(float(v)) for v in np.log(sg[:, c])) + '\n')
print(len(times), 'segments')
