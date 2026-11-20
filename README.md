### Installation
* First, set up the conda environment with dependencies.
```
conda config --add channels conda-forge
conda create -y -n serial_spectrogram python=3.10 numpy obspy matplotlib scipy pytest
```

* Next, from the right project folder, clone the github repository.
```
git clone https://github.com/ajakef/serial_spectrogram/
```

* Then, activate the conda environment and, from that folder, run the code.
```
conda activate serial_spectrogram
cd serial_spectrogram
./serial_spectrogram.py
```
* It will probably have to restart a few times before it begins plotting. You may have to create a CONFIG.TXT file on the microSD card telling it to run all 4 channels. 
