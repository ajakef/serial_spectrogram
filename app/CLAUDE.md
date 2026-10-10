# serial spectrogram app project priorities

## Interaction with developer
- This is my very first and possibly last time developing a phone app. I hardly know anything about the process. Previous relevant experience includes making a Python package (gemlog) and two major embedded systems firmware (aspen-firmware and gem-firmware). I am a scientist first, not a trained software engineer.
- Avoid jargon that is not likely to be understandable to me. If it is necessary for me to learn it, define it on first use. Teach me what I need to know, but not more than that.
- Tell me which things I'm asking for are easy and which are hard. If a feature request would involve a major expansion of the project's scope, tell me first.
- Tell me if something I'm asking for is likely to cause problems, because I basically do not know how phone apps work.
- Tell me how I can test whether a new change succeeded. I have an Android phone (Samsung Galaxy S20 FE).

## Development and maintenance strategy
- The app should be bare-bones, low-maintenance, and cross-platform by design. I want to do minimal if any maintenance work on it post-completion.
- The purpose is to connect to an Aspen geophysical data logger (a separate project I am developing), read a serial data stream at 500,000 baud, and plot waveforms and spectrograms in real time.
- The included Python code serial_spectrogram.py already does everything I need, including parsing the data stream and plotting it. Do not ever change any files in the root directory (e.g., serial_spectrogram.py, serial_plot.py, utils.py, or README.md) without telling me very explicitly and getting my approval. All new files, edits, and subdirectories should go in the app/ directory.
- Replicate the behavior seen in the Python files. If minor changes can make something easier to implement in a phone app, tell me.
- Prioritize UX simplicity over features.

