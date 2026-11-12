#!/usr/bin/env python3
import argparse
import re
import time
import serial
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import itertools
import numpy as np
from scipy.signal import spectrogram
import utils
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

# Sample rate: 200 sps unless --rate gives another. The plotter sends it to the logger at startup (CF:sample_rate=),
# so the two always agree. Window lengths are set for 200 sps and scaled with the rate (set_sample_rate), so the plot
# always spans ~20 s and the spectrogram's frequency resolution stays the same.
sample_rates = [100, 200, 400, 800, 1000] # the rates the logger accepts
sample_rate = 200
N_full = 4096 # samples shown (20.48 s at 200 sps)
#N_full = 1024
N_sub = 128 # samples per spectrogram window, and per plot update
n_warmup = 10 # samples to discard at startup; they contain large transients that would distort the plot scales
n_chan = 4
overlap = 0.875
dt = 1 / sample_rate
ylim = [-1, 1]

def set_sample_rate(rate):
    global sample_rate, dt, N_full, N_sub
    sample_rate = rate
    dt = 1 / rate
    N_full = 4096 * rate // 200
    N_sub = 128 * rate // 200
    utils.set_sample_rate(rate) # the high-pass filter in parse_line

show_infrasound = True
show_seismic = True
show_traces = True

gains = b'128,32,32,32' # standard gains sent to the logger at startup

def firmware_checks_gains(version_line):
    # Firmware 0.8.2 and later reply "Gains accepted: ..." or "Gains rejected ..." to a GN: command
    m = re.search(rb'Firmware: (\d+)\.(\d+)\.(\d+)', version_line)
    return m is not None and tuple(int(x) for x in m.groups()) >= (0, 8, 2)

def firmware_takes_config(version_line):
    # Firmware 0.8.5-15 and later take "CF:<name>=<value>" commands and reply "Config set: ..." or "Config rejected ...".
    # (0.8.6-x builds came before the version numbers went back to 0.8.5 on 2026-10-30, and don't.)
    m = re.search(rb'Firmware: (\d+)\.(\d+)\.(\d+)-(\d+)', version_line)
    if m is None:
        return False
    major, minor, patch, build = (int(x) for x in m.groups())
    return (major, minor) >= (0, 9) or (major, minor, patch) == (0, 8, 5) and build >= 15

def wait_for_config_reply(ser, timeout = 3):
    # returns the reply line containing "Config set" or "Config rejected", or None if none arrives in time
    t_start = time.time()
    while time.time() - t_start < timeout:
        line = ser.readline()
        if b'Config set' in line or b'Config rejected' in line:
            return line.strip()
    return None

def send_sample_rate(ser, takes_config, max_sends = 3):
    # Sends CF:sample_rate=<rate>. Returns True once the logger has accepted it (or, for older firmware that can't
    # take it, if the rate is the 200 sps those loggers use by default), False otherwise.
    if not takes_config:
        if sample_rate != 200:
            print(f'This firmware cannot be told the sample rate; the plot assumes {sample_rate} sps')
        return True
    command = f'sample_rate={sample_rate}'.encode()
    for send in range(max_sends):
        ser.write(b'CF:' + command + b'\r\n')
        reply = wait_for_config_reply(ser)
        print(reply)
        if reply is None:
            return False # no reply: restart and try again
        if b'Config rejected' in reply:
            continue # the logger is still listening: send again
        return reply.split(b':', 1)[-1].strip() == command # accepted, but garbled into another setting: restart
    return False

def wait_for_gain_reply(ser, timeout = 3):
    # returns the reply line containing "Gains accepted" or "Gains rejected", or None if none arrives in time
    t_start = time.time()
    while time.time() - t_start < timeout:
        line = ser.readline()
        if b'Gains accepted' in line or b'Gains rejected' in line:
            return line.strip()
    return None

def start_logger(max_restarts = 3, max_sends = 3):
    # Opens the serial port, which restarts the logger. When the logger prints its prompt, sends the setup commands:
    # NCM (no compression, data on the serial port), NSD (no SD card required), and the gains. The logger listens for commands for only a couple of
    # seconds. Newer firmware says whether it accepted the gains: if it rejected them (e.g. a byte was garbled in
    # transmission), they are sent again; if there was no reply, or the accepted gains aren't the ones sent, the logger
    # is restarted (by reopening the port) and setup starts over.
    for restart in range(max_restarts):
        ser = get_serial()
        ser.reset_input_buffer()  # Flush input buffer, discarding all its contents.
        # Wait for the prompt by time rather than by line count (the number of startup lines before it varies), and match it
        # as a substring because newer FW can run it together with other output. If the logger was already running, no prompt
        # will come; stop waiting once data lines are streaming.
        prompt_timeout = 30 # s
        n_data_lines = 0
        checks_gains = False
        takes_config = False
        t_start = time.time()
        while time.time() - t_start < prompt_timeout:
            line = ser.readline()
            if b'Firmware:' in line:
                checks_gains = firmware_checks_gains(line)
                takes_config = firmware_takes_config(line)
            if b'Enter Serial Number' in line:
                break
            n_data_lines = n_data_lines + 1 if line.split(b',')[0].strip().lstrip(b'-').isdigit() else 0
            if n_data_lines >= 20:
                print('Logger was already running; continuing without sending setup commands')
                return ser
        else:
            print('Did not see the logger\'s "Enter Serial Number" prompt; continuing without sending setup commands')
            return ser

        ser.write(b'NCM\r\n') # command for "no compression"
        ser.write(b'NSD\r\n') # "no SD card required": plotting works without a card, and SD errors aren't shown (older firmware ignores it)
        if not send_sample_rate(ser, takes_config):
            print('The sample rate was not set; restarting the logger and trying again')
            ser.close()
            continue
        if not checks_gains: # older firmware: send once, no reply to check
            ser.write(b'GN:' + gains + b'\r\n\n') # the extra blank line tells the logger no more commands are coming, so it skips its wait
            return ser
        for send in range(max_sends):
            ser.write(b'GN:' + gains + b'\r\n\n')
            reply = wait_for_gain_reply(ser)
            print(reply)
            if reply is None:
                break # no reply: restart and try again
            if b'Gains rejected' in reply:
                continue # the logger is still listening: send again
            if reply.split(b':')[-1].strip() == gains:
                return ser
            break # accepted, but not the gains sent (e.g. a dropped digit): restart and try again
        print('Gains were not set correctly; restarting the logger and trying again')
        ser.close()
    raise Exception(f'Could not set the logger\'s gains to {gains.decode()} and sample rate to {sample_rate} after '
                    f'{max_restarts} tries')

class UsbDisconnected(BaseException):
    # A BaseException rather than an Exception: utils.parse_line catches every Exception (a garbled line) and keeps
    # reading, which would loop forever on a port that's gone.
    pass

class SerialPortWatcher:
    # Wraps the serial port so that losing the logger (USB unplugged, or no data for several seconds) stops the plot
    # instead of being treated as a bad line. Everything else passes through to the port.
    max_empty_reads = 3 # each empty read is a readline() timeout (2 s), so this is about 6 s with no data
    def __init__(self, ser):
        self.ser = ser
        self.empty_reads = 0
    def readline(self):
        try:
            line = self.ser.readline()
        except (serial.SerialException, OSError) as e:
            raise UsbDisconnected(str(e))
        self.empty_reads = self.empty_reads + 1 if line == b'' else 0
        if self.empty_reads >= self.max_empty_reads:
            raise UsbDisconnected('no data from the logger')
        return line
    def __getattr__(self, name):
        return getattr(self.ser, name)

def show_disconnected(reason):
    # Stops the animation and says so on the plot; the window and its last data stay up until it's closed.
    print(f'Logger disconnected ({reason}); the plot has stopped. Close the window to exit.')
    if 'ani' in globals():
        ani.event_source.stop()
    if 'fig' in globals():
        fig.suptitle('USB disconnected: plot stopped', color = 'red')
        fig.canvas.draw_idle()

_state = {} # serial port and sample buffers; shared by every generator (see data_gen_serial)

def data_gen_serial(): # this function must be iterable; every time it yields, what it yields is the input to run()
    # matplotlib (blit=True) calls this function again every time the window is resized, to redraw the first frame. Opening
    # the port resets the logger, so the startup steps must run only once; later calls pick up where the last one left off.
    if not _state:
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
        ser = SerialPortWatcher(start_logger())

        # Run the filter through the first n_warmup samples without plotting them. Then clear the buffers,
        # keeping only the last sample's state in column -1, which is the "previous sample" for i = 0.
        try:
            for i in range(n_warmup):
                filtered_data, raw_data = parse_line(ser, filtered_data, raw_data, n_chan, i)
        except UsbDisconnected as e:
            _state.update(disconnected = True, last_frame = None)
            show_disconnected(e)
            return
        last_filtered = filtered_data[:, n_warmup - 1].copy()
        last_raw = raw_data[:, n_warmup - 1].copy()
        filtered_data[:] = 0
        raw_data[:] = 0
        #filtered_data[:, -1] = last_filtered
        raw_data[:, -1] = last_raw

        _state.update(ser = ser, filtered_data = filtered_data, raw_data = raw_data, i = 0)
    if _state.get('disconnected'):
        # matplotlib asks for a frame again when the window is resized: redraw the last one, then stop
        if _state.get('last_frame') is not None:
            yield _state['last_frame']
        return
    ser, filtered_data, raw_data = _state['ser'], _state['filtered_data'], _state['raw_data']

    while True:
        i = _state['i']
        try:
            filtered_data, raw_data = parse_line(ser, filtered_data, raw_data, n_chan, i)
        except UsbDisconnected as e:
            _state['disconnected'] = True
            show_disconnected(e)
            return
        _state['i'] = (i + 1) % N_full # advance before yielding: a generator abandoned at a yield must not repeat its sample
        if (i % N_sub) == 0:
            _state['last_frame'] = [filtered_data[j,:].copy() for j in range(n_chan)] + [i]
            yield _state['last_frame']

def run(data): # this function accepts the "yields" of the data_gen function as its input, and must return a list of all artists (i.e., images and lines). If some feature in the plot isn't updating right, it may not be included in the returned list. note that axis.plot() returns a list of (typically 1) artists, not an artist itself. Seems like storing info in globals isn't an option.
    #eps = np.random.normal(0, 1e-9, N_full)
    eps = 1e-9 * (np.arange(N_full)==0)
    artists = []
    nplots = show_seismic+show_infrasound+show_traces
    current_time = data[-1] * dt
    freqticks = [f for f in [1, 3, 10, 30, 100, 300] if f < sample_rate / 2]
    if show_infrasound:
        plt.subplot(nplots, 1, 1)
        freqs, times, sg = spectrogram(data[0]+eps, fs = sample_rate, window = 'hamming', nperseg = N_sub, noverlap = overlap*N_sub, detrend = 'linear')#, axis = axes[0]) axis input doesn't work for some reason
        sg[sg == 0] = np.nan # prevent warnings when taking log(0)
        artists.append(image(np.log(sg.T[:,1:]), times, freqs[1:], log_y = True, ax = axes[0,0]))
        artists.append(axes[0,0].plot([current_time, current_time], axes[0,0].get_ylim(), 'k-')[0]) # axes[0,0].plot returns a list of artists, not just one
        axes[0,0].set_yticks(np.log10(freqticks), freqticks)
    if show_seismic:
        plt.subplot(nplots, 1, 1+show_infrasound)
        freqs, times, sg = spectrogram(data[1]+eps, fs = sample_rate, window = 'hamming', nperseg = N_sub, noverlap = overlap*N_sub, detrend = 'linear')#, axis = axes[0]) axis input doesn't work for some reason
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
    parser = argparse.ArgumentParser(description = 'Real-time plot of an Aspen logger\'s data on the serial port.')
    parser.add_argument('--rate', type = int, default = 200, choices = sample_rates,
                        help = 'sample rate (samples per second) to set on the logger and plot at; default 200')
    set_sample_rate(parser.parse_args().rate)
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

    # repeat = False: when the data stop (USB unplugged), the animation ends and the window stays open
    ani = animation.FuncAnimation(fig, run, frames=data_gen_serial, blit=True, interval=50, save_count = 0, repeat = False)
    plt.show()

