import numpy as np
import scipy.signal
import matplotlib.pyplot as plt
import glob
import serial

sensitivity_infrasound = 0.01/125 * 3.2/12 # V/Pa
sensitivity_seismic = 30 # V/m/s; probably order-of-magnitude accurate.
bitweight_V = 5/2**24 # differential measurement can go up to +/- 2.5V
gain_infrasound = 128 / 16 # FW divides by 16 to avoid writing noise bits
gain_seismic = 32 / 16
bitweight_infrasound = bitweight_V/gain_infrasound/sensitivity_infrasound
bitweight_seismic = bitweight_V/gain_seismic/sensitivity_seismic * 1e3 # mm/s

baud_rate = 500000

dt = 0.005
corner_freq = 1 # Hz
nyquist = 0.5/dt
[b, a] = scipy.signal.butter(1, corner_freq/nyquist, 'highpass')

def set_sample_rate(rate):
    # the high-pass filter in parse_line depends on the sample rate (200 sps unless this is called)
    global dt, nyquist, b, a
    dt = 1 / rate
    nyquist = 0.5 / dt
    [b, a] = scipy.signal.butter(1, corner_freq/nyquist, 'highpass')

def get_serial():
    port_list = sorted(glob.glob('/dev/ttyUSB*') + # linux serial ports
                       glob.glob('/dev/tty.usbserial*')) # mac serial ports
    print(port_list)
    for port in port_list:
        print(port)
        try:
            ser = serial.Serial(port, baud_rate, timeout=2)  # Open port and read data.
        except Exception as e:
            print(e)
            print(f'failed to open {port}')
            continue
        else:
            print(f'opened {port}')
            break
    else:
        raise(Exception('Could not open ttyUSB0 or ttyUSB1. Please confirm that pySerial is installed and device is plugged in.'))
    return ser




        
_new_format = False     # a T line has been seen (AspenCSV0.4 firmware): data lines have no time code
_absolute_next = False  # the next data line holds absolute values (it follows a T line)

def parse_line(ser, filtered_data, raw_data, n_chan, i):
    global _new_format, _absolute_next
    bitweights = [bitweight_infrasound] + [bitweight_seismic for i in range(n_chan - 1)]
    while True:
        try:
            line = ser.readline().decode('utf-8', errors = 'ignore').strip().split(',')
            if line[0] == 'T':
                _new_format, _absolute_next = True, True
                continue
            first = 0 if _new_format else 1  # older firmware puts a time code first
            float(line[0]) # raises an exception if the first character isn't numeric
            # newer FW drops trailing zero diffs, so a line may have fewer than n_chan values; missing ones are zero diffs
            diffs = [float(line[j+first]) if j + first < len(line) else 0.0 for j in range(n_chan)]
            if _absolute_next:  # absolute values, not changes: treat as no change
                diffs, _absolute_next = [0.0] * n_chan, False
            raw_data[:,i] = np.array([diffs[j] * bitweights[j] for j in range(n_chan)]) + raw_data[:,i-1] # integrate it before filtering
            filtered_data[:,i] = -a[1] * filtered_data[:,i-1] + b[0] * raw_data[:,i] + b[1] * raw_data[:,i-1]
            return filtered_data, raw_data
        except Exception as e:
            print(line)
            #print(e)

        
def set_up_line_plot(ax, N_full, n_chan, ylim):
    dy = np.abs(np.diff(ylim))/n_chan
    y_baseline = np.max(ylim) - dy/2 - dy * np.arange(n_chan)
    lines = [
        #ax.plot([], [], color = 'black', lw = 1)[0], # vertical line # can't get this to work
        ax.plot([], [], color = 'red', lw = 2)[0], # infrasound
        ax.plot([], [], color = 'lightblue', lw = 2)[0], # V
        ax.plot([], [], color = 'blue', lw = 2)[0], # N
        ax.plot([], [], color = 'darkblue', lw = 2)[0] # E
    ]
    ax.set_ylim(np.min(ylim), np.max(ylim))  # Set limitation in y
    ax.set_xlim(0, N_full) # Set limitation in x
    #dy = [5 * np.std(data[i]) for i in range(n_chan)]
    text_offset = 0.15
    labels = ['Infrasound', 'Vertical', 'North', 'East']
    for i in range(n_chan):
        ax.text(0, y_baseline[i] + text_offset, labels[i])

    return lines, y_baseline

def image(Z, x = None, y = None, aspect = 'equal', zmin = None, zmax = None, ax = plt, crosshairs=False, log_x = False, log_y = False, qmin = 0.02, qmax = 0.98):
    # Z rows are x, columns are y
    if x is None:
        x = np.arange(Z.shape[0])
    if y is None:
        y = np.arange(Z.shape[1])


    if log_x:
        w = x > 0
        plot_x = np.log10(x[w])
        x = x[w]
        Z = Z[:,w]
    else:
        plot_x = x

    if log_y:
        w = y > 0
        plot_y = np.log10(y[w])
        y = y[w]
        Z = Z[:,w]
    else:
        plot_y = y
        
    # zmin/zmax are the color axis limits. if not set by user, use the 2% and 98% percentiles
    # this prevents outliers from dominating the dataset
    if zmin is None:
        ZZ = Z[:]
        wz = ~np.isinf(ZZ) & ~np.isnan(ZZ)
        zmin = np.quantile(ZZ[wz], qmin)
    if zmax is None:
        ZZ = Z[:]
        wz = ~np.isinf(ZZ) & ~np.isnan(ZZ)
        zmax = np.quantile(Z[wz], qmax)

    im = ax.pcolormesh(plot_x, plot_y, Z.T[1:,1:], vmin = zmin, vmax = zmax, shading = 'auto')#, cmap='YlOrRd')
    if crosshairs:
        ax.hlines(0, x[0], x[-1], 'k', linewidth=0.5)
        ax.vlines(0, y[0], y[-1], 'k', linewidth=0.5)
    if log_x:
        if ax is plt:
            xt = round_sig(10**plt.xticks()[0],0)
            xt = xt[(np.log10(xt) > plt.xlim()[0]) & (np.log10(xt) < plt.xlim()[1])]
            plt.xticks(np.log10(xt), xt)
        else:
            xt = round_sig(10**ax.get_xticks(),0)
            xt = xt[(np.log10(xt) > ax.get_xlim()[0]) & (np.log10(xt) < ax.get_xlim()[1])]
            ax.set_xticks(np.log10(xt), xt)
            
    if log_y:
        if ax is plt:
            yt = round_sig(10**plt.yticks()[0],0)
            yt = yt[(np.log10(yt) > plt.ylim()[0]) & (np.log10(yt) < plt.ylim()[1])]
            plt.yticks(np.log10(yt), yt)
        else:
            yt = round_sig(10**ax.get_yticks(),0)
            yt = yt[(np.log10(yt) > ax.get_ylim()[0]) & (np.log10(yt) < ax.get_ylim()[1])]
            ax.set_yticks(np.log10(yt), yt)
    return im

def round_sig(f, p): # thanks StackOverflow denizb
    ## function to put a list of numbers in scientific notation
    ## f: list of numbers
    ## p: number of decimal places
    f = np.array(f)
    return np.array([float(('%.' + str(p) + 'e') % ff) for ff in f])

    
