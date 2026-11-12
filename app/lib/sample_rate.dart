/// The sample rate the app asks the Aspen for at startup (CF:sample_rate=...) and plots at, so the two always
/// agree. 200 samples per second unless the user picks another from the menu; not saved between app runs.
/// Same as serial_spectrogram.py's --rate option.
class SampleRate {
  static const choices = [100, 200, 400, 800, 1000]; // the rates the logger accepts
  static const standard = 200;
  static int current = standard;
}
