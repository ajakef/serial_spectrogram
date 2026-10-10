#!/usr/bin/env python3
import time
import serial
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import itertools
import numpy as np
from scipy.signal import spectrogram
from utils import get_serial, parse_line, baud_rate, set_up_line_plot, image

#sensitivity_infrasound = 0.01/125 * 3.2/12
#sensitivity_seismic = 30 # V/m/s; probably order-of-magnitude accurate.
#bitweight_V = 5/2**24 # differential measurement can go up to +/- 2.5V
#gain_infrasound = 128
#gain_seismic = 32
#bitweight_infrasound = bitweight_V/gain_infrasound/sensitivity_infrasound
#bitweight_seismic = bitweight_V/gain_seismic/sensitivity_seismic * 1e3 # um/s

seismic_plot_gain = 1
infrasound_plot_gain = -0.125
#seismic_plot_gain = 100

N_full = 4096
#N_full = 1024
N_sub = 128
n_chan = 4
overlap = 0.875
dt = 0.005
ylim = [-1, 1]

show_infrasound = True
show_seismic = True
show_traces = True

def data_gen_serial(): # this function must be iterable; every time it yields, what it yields is the input to run()
    infrasound = np.zeros(N_full) 
    seismic = np.zeros(N_full)
    filtered_data = np.zeros([n_chan, N_full])
    raw_data = np.zeros([n_chan, N_full])
    print('startup')
    #try:
    #    ser = serial.Serial('/dev/ttyUSB0', baud_rate, timeout=2)  # Open port and read data.
    #except:
    #    try:
    #        ser = serial.Serial('/dev/ttyUSB1', baud_rate, timeout=2)  # Open port and read data.
    #    except:
    #        raise(Exception('Could not open ttyUSB0 or ttyUSB1. Please confirm that pySerial is installed and device is plugged in.'))
    ser = get_serial()

    ser.reset_input_buffer()  # Flush input buffer, discarding all its contents.
    for i in range(100):
        line = ser.readline()
        if line == b'Enter Serial Number\r\n':
            ser.write(b'NCM\r\n') # command for "no compression"
            ser.write(b'GN:128,32,32,32\r\n') # standard gains
        #print(line)

    while True:
        for i in range(N_full):
            filtered_data, raw_data = parse_line(ser, filtered_data, raw_data, n_chan, i) 
            if (i % N_sub) == 0:
                yield [filtered_data[j,:] for j in range(n_chan)] + [i]
        
def run(data): # this function accepts the "yields" of the data_gen function as its input, and must return a list of all artists (i.e., images and lines). If some feature in the plot isn't updating right, it may not be included in the returned list. note that axis.plot() returns a list of (typically 1) artists, not an artist itself. Seems like storing info in globals isn't an option.
    eps = np.random.normal(0, 1e-9, N_full)
    artists = []
    nplots = show_seismic+show_infrasound+show_traces
    current_time = data[-1] * dt
    freqticks = [1, 3, 10, 30, 100]
    if show_infrasound:
        plt.subplot(nplots, 1, 1)
        freqs, times, sg = spectrogram(data[0]+eps, fs = 200, window = 'hamming', nperseg = N_sub, noverlap = overlap*N_sub, detrend = 'linear')#, axis = axes[0]) axis input doesn't work for some reason
        sg[sg == 0] = np.nan # prevent warnings when taking log(0)
        artists.append(image(np.log(sg.T[:,1:]), times, freqs[1:], log_y = True, ax = axes[0,0]))
        artists.append(axes[0,0].plot([current_time, current_time], axes[0,0].get_ylim(), 'k-')[0]) # axes[0,0].plot returns a list of artists, not just one
        axes[0,0].set_yticks(np.log10(freqticks), freqticks)
    if show_seismic:
        plt.subplot(nplots, 1, 1+show_infrasound)
        freqs, times, sg = spectrogram(data[1]+eps, fs = 200, window = 'hamming', nperseg = N_sub, noverlap = overlap*N_sub, detrend = 'linear')#, axis = axes[0]) axis input doesn't work for some reason
        sg[sg == 0] = np.nan
        artists.append(image(np.log(sg.T[:,1:]), times, freqs[1:], log_y = True, ax = axes[show_infrasound+0,0]))
        artists.append(axes[show_infrasound+0,0].plot([current_time, current_time], axes[0,0].get_ylim(), 'k-')[0]) # axes[0,0].plot returns a list of artists, not just one
        axes[show_infrasound+0,0].set_yticks(np.log10(freqticks), freqticks)
    if show_traces:
        plt.subplot(nplots, 1, nplots)
        t = np.arange(N_full) * dt
        if show_infrasound:
            lines[0].set_data(t, infrasound_plot_gain*(data[0] - data[0][0])+y_baseline[0]+eps)
            artists.append(lines[0])
        if show_seismic:
            for i in range(1, n_chan):
                lines[i].set_data(t, seismic_plot_gain*(data[i] - data[i][0]+eps)+y_baseline[i])
                artists.append(lines[i])
        axes[-1,0].set_ylim(np.min(ylim), np.max(ylim))
        artists.append(axes[-1,0].plot([current_time, current_time], [-1,1], 'k-')[0])
    return artists
    


if __name__ == '__main__':
    fig, axes = plt.subplots(show_seismic + show_infrasound + show_traces, 1, squeeze = False)  # Setup figure and axis
    if show_infrasound:
        axes[0,0].set_title('Infrasound')
    if show_seismic:
        axes[0+show_infrasound,0].set_title('Vertical Seismic')
    if show_infrasound or show_seismic:
        axes[-2,0].set_ylabel('Frequency (Hz)')
    if show_traces:
        lines, y_baseline = set_up_line_plot(axes[-1,0], N_full, n_chan, ylim)
        #line_infrasound, = axes[-1,0].plot([], [], color = 'red', lw = 1)  # Setup line
        #line_seismic, = axes[-1,0].plot([], [], color = 'blue', lw = 1)  # Setup line

    #ax.set_ylim(-1, 1)  # Set limitation in y
    for j in range(len(axes)):
        axes[j,0].set_xlim(0, N_full * dt) # Set limitation in x

    fig.set_size_inches(12, 9)
    fig.tight_layout()
    fig.show()
    
    # Frames: Receives the generated data from the serial connection
    # Run: Provides the line data

    ani = animation.FuncAnimation(fig, run, frames=data_gen_serial, blit=True, interval=50, save_count = 0)
    plt.show()

