#!/usr/bin/env python
"""Regenerates expected_sample.csv: what the original Python code (utils.parse_line)
produces from sample_data.txt, except that data lines with fewer than 4 values are
padded with zeros first (the app's one deliberate difference from the Python code). The Dart tests compare the app's parser against it.
Run from anywhere: python app/test/make_expected.py
"""
import os, sys, types
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))
sys.dont_write_bytecode = True
sys.modules['serial'] = types.ModuleType('serial')  # utils.py imports pyserial, which isn't needed here
sys.path.insert(0, root)
import utils

N_full, n_chan = 4096, 4

class EndOfData(BaseException):
    pass  # not an Exception subclass: utils.parse_line would swallow it and loop forever

class FakeSerial:
    def __init__(self, path):
        self.lines = open(path, 'rb').read().splitlines(keepends=True)
        self.pos = 0
    def readline(self):
        if self.pos >= len(self.lines):
            raise EndOfData
        self.pos += 1
        return self.pad(self.lines[self.pos - 1])
    @staticmethod
    def pad(line):
        text = line.decode('utf-8', errors='ignore').strip()
        fields = text.split(',')
        try:
            float(fields[0])
        except ValueError:
            return line
        if 2 <= len(fields) < n_chan + 1:
            text += ',0' * (n_chan + 1 - len(fields))
        return (text + '\r\n').encode()

ser = FakeSerial(os.path.join(here, '..', 'sample_data.txt'))
raw = np.zeros([n_chan, N_full])
filt = np.zeros([n_chan, N_full])
rows = []
i = 0
try:
    while True:
        filt, raw = utils.parse_line(ser, filt, raw, n_chan, i)
        rows.append(list(filt[:, i]) + list(raw[:, i]))
        i += 1
except EndOfData:
    pass

with open(os.path.join(here, 'expected_sample.csv'), 'w') as f:
    f.write('# filtered ch1-4, raw (integrated) ch1-4; one row per accepted data line\n')
    for r in rows:
        f.write(','.join(repr(float(x)) for x in r) + '\n')
print(len(rows), 'rows;', 'b =', utils.b, 'a =', utils.a)
