# Aspen Plot (Android app)

Plots live waveforms and spectrograms from an Aspen geophysical data logger on an Android phone.
It does what `serial_spectrogram.py` in the folder above does, with the same processing and the same layout:
two spectrograms (infrasound and vertical seismic) and four traces (infrasound, vertical, north, east)
over a 20-second window. The black line marks the newest data; new data overwrites old from left to right.

## Installing

The app isn't in the Play Store. Download `aspen-plot.apk` from the
[Releases page](https://github.com/ajakef/SerialSpectrogram/releases) on your phone, open it, and
allow "Install unknown apps" for your browser or file manager when Android asks.

## Using it

**You need:** an Android phone with a USB-C port, an FTDI USB-serial cable (chip FT232, USB ID `0403:6001`;
the Adafruit cable the logger uses), and a USB-A to USB-C adapter if the cable doesn't fit the phone.

1. Install the APK (see "Installing" above).
2. Power on the Aspen. Plug the cable into the phone.
3. Android asks which app should open for the USB device. Choose **Aspen Plot** and tick "Always".
   Then allow access to the device when asked. (You can also open the app yourself first.)
4. A card shows what's happening: connecting, the logger responding, data arriving. After about
   two seconds of data, the plots appear. Turning the phone sideways gives a bigger plot.
5. Unplugging and replugging the cable starts over. The screen stays on while the app is open.

If the card says "Plug in the Aspen logger" with the cable attached, tap **Connect**. The logger may restart a few times
before data starts, as with the Python version. You may need a `CONFIG.TXT` file on its microSD card
telling it to run all 4 channels.

**Differences from the Python version:**
- The first 400 samples (2 s) are discarded, because the logger's startup values are extreme.
  (The Python script does this too now.)
- Data lines with fewer than four values have the missing ones taken as zero (the logger leaves out
  trailing zeros), instead of being dropped.
- No y-axis numbers on the traces, and time labels only on the bottom panel.

## For developers

Everything is in this `app/` folder; nothing in the folder above is modified by the app.
It is a [Flutter](https://flutter.dev) app (Dart code) with a small amount of Kotlin for the USB connection.

| File | What it does |
| --- | --- |
| `lib/main.dart` | The screen: three panels, status card, redraw timer |
| `lib/signal_processor.dart` | Line parsing, scaling, integration, 1 Hz high-pass filter (as `utils.py`), 400-sample warm-up |
| `lib/spectrogram.dart` | Spectrogram math (as `scipy.signal.spectrogram`) |
| `lib/spectrogram_plot.dart`, `lib/trace_plot.dart`, `lib/plot_axes.dart`, `lib/viridis.dart` | Drawing |
| `lib/serial_link.dart` | Dart side of the USB connection; answers the logger's `Enter Serial Number` prompt |
| `android/.../MainActivity.kt` | Android side of the USB connection (500,000 baud, 8N1) |
| `android/.../res/xml/device_filter.xml` | USB IDs that make Android offer to open the app (FT232 only) |
| `icon.png`, `make_icons.py` | Icon artwork and the script that makes the Android icons from it |

**Setup:** install Flutter and Android Studio (for the Android SDK), then run `flutter doctor` in this folder.
On the phone, turn on Developer options and USB debugging.

**Everyday commands** (run in this folder):
- `flutter run --release`: build and install on the connected phone. (`flutter install` alone does *not* rebuild.)
- `flutter test`: run the tests. Add `--update-goldens` to redraw the test pictures in `test/goldens/`.
- `flutter analyze`: check the code for problems.

**Tests** compare the Dart code against the Python code on `sample_data.txt`, a real logger capture.
The expected values come from `test/make_expected.py` and `test/make_expected_spectrogram.py`, which run the
original Python code (`utils.py`, scipy). Rerun them if the Python processing changes.

**App ID:** `io.github.ajakef.aspenplot`. Don't change it after the app is distributed, or users will get
a second copy instead of an update.

## Releasing

Android only accepts an update if it is signed with the same key as the installed version, so
**the release key must never be lost or shared.** It lives outside the repository
(`~/aspen-plot-signing/aspen-plot.jks`); keep a backup of that file and its password in at least two places.
`android/key.properties` (also not in git) tells the build where the key is and holds its password.

**Making the key (once):** in a normal terminal, choose a password and answer the questions:

    mkdir -p ~/aspen-plot-signing
    keytool -genkeypair -v -keystore ~/aspen-plot-signing/aspen-plot.jks -alias aspenplot -keyalg RSA -keysize 2048 -validity 10000

Then create `android/key.properties` without showing the password on screen (type the same password):

    read -rsp "Password: " p; printf 'storePassword=%s\nkeyPassword=%s\nkeyAlias=aspenplot\nstoreFile=%s\n' "$p" "$p" "$HOME/aspen-plot-signing/aspen-plot.jks" > android/key.properties; chmod 600 android/key.properties; unset p

**Each release:**
1. Raise the number after `+` in `version:` in `pubspec.yaml` (e.g. `1.0.0+2`); Android uses it to tell which APK is newer.
   Change the part before the `+` too if you like; users see it.
2. Run `./build_release.sh`. It builds `build/aspen-plot.apk`, checks that it is signed with your key, and prints the certificate.
   It refuses to run if `key.properties` is missing.
3. On the GitHub repository page: Releases, Draft a new release, give it a tag (e.g. `app-v1.0.0`), drag `build/aspen-plot.apk` into the box, and publish.

A phone that has a test build from `flutter run --release` (signed with the debug key) must uninstall it before
installing the real release, because the signatures differ.

