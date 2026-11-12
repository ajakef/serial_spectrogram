# Aspen Plot (Android app)

Three tabs (along the bottom; down the left side when the phone is sideways):
- **Check**: plug in a logger and see whether it started properly: a checklist for the field tech, the full startup
  report for an engineer, CONFIG.TXT checked line by line, and a form to fix it. Each check is saved on the phone.
- **Plot**: live waveforms and spectrograms.
- **Sites**: waypoints, codes, photos with markers on hidden sensors, notes, and navigation back to a site.

The Plot tab plots live waveforms and spectrograms from an Aspen geophysical data logger on an Android phone.
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
4. The app opens on the **Check** tab (below). For plots, tap **Plot**: a card shows what's happening (connecting,
   the logger responding, data arriving), and after about two seconds of data the plots appear. Turning the phone
   sideways gives a bigger plot.
5. Unplugging and replugging the cable starts over. The screen stays on while the app is open.

**The Plot tab changes the logger's settings** (gains, sample rate, and SD-card errors hidden) until the logger
restarts. Leaving the Plot tab restarts it with CONFIG.TXT's settings, but unplugging on the Plot tab doesn't. So
before unplugging a logger that's being deployed, go to the Check tab (a reminder shows on the plots).

**Check tab:** plugging in restarts the logger, and the checklist fills in as it starts: power, clock, sensors,
SD card, CONFIG.TXT, station codes, GPS, ADCs, recording. The banner at the top says when it's safe to unplug
("Logging: OK to unplug" once the logger has GPS time and its files are open). Amber items are warnings (allowed
but probably not intended, e.g. a GPS quota under 20); red items are problems. **Field** shows the checklist and
the settings in plain words; **Engineer** adds the firmware version, reset cause, error codes, the "Config:" line,
CONFIG.TXT as it is on the card with each line labeled (a missing or extra line is caught from the comments), the
latest health line, and the whole startup log. The circular-arrow button restarts the logger to check again.
- **Change settings / Fix CONFIG.TXT** opens a form. **Save to logger** restarts the logger, sends the settings
  (the same GN:/CF: commands as the Python plotter), and has the logger save them to CONFIG.TXT (the old file is
  kept on the card as CONFIG.BAK); then it restarts it again and checks that it reads the new file. This needs
  Aspen firmware 1.0.0-2 or newer (older firmware says so and nothing changes).
- **Saved startup logs** (folder button): every check is saved on the phone, so a log from a site without cell
  service can be read or sent later (Share menu: email, Quick Share, Drive...).

**Sites tab:** **New site** (with the logger plugged in and checked, its serial number and codes are filled in),
then **Take waypoint** while standing at the sensors (it averages 30 s of GPS), then **Add the setup visit**:
notes (tap the keyboard's microphone to dictate; check that dictation works in airplane mode before going to a site
without service) and photos. After taking a photo, tap where each sensor is hidden and pick Logger, Seismic,
Infrasound, or Battery and an optional number. On a return trip, open the site and tap **Navigate here**: an arrow
and the distance, with the photos below (tap a photo to make it big or small, tap a big one to see it full screen;
the arrow gives way to "look for the markers in the photos" within GPS accuracy, usually 5-10 m). **Add visit**
records the new photos and notes.
- **Sharing sites, no accounts needed:** menu, **Send all sites** makes one zip file and opens the Share menu;
  **Quick Share** sends it straight to a nearby phone without cell service. On the other phone: Sites, menu,
  **Import sites from a file**, and pick the zip (Quick Share puts it in Downloads). Importing merges: new sites and
  visits are added, edits made later win, and nothing is duplicated, so phones can swap files as often as they like.
- **Save a copy to Downloads** puts the same zip in Download/Aspen, where a computer can copy it over USB. Inside:
  README.txt, sites.csv (one row per site: serial number, SEED codes, coordinates, setup/pickup times),
  visits.csv (notes), photos.csv (markers), sites.kml (for Google Earth), the photos, and copies with the markers
  drawn on.
- Sites are kept in the app's own storage. Uninstalling the app asks whether to keep its data; say yes, and export
  now and then as a backup.

If the card says "Plug in the Aspen logger" with the cable attached, tap **Connect**. The logger may restart a few times
before data starts, as with the Python version. You may need a `CONFIG.TXT` file on its microSD card
telling it to run all 4 channels.

**Updating the Aspen's firmware:** tap the small download icon at the top right of the plot screen. The screen
shows the firmware now on the Aspen (it restarts the Aspen and reads the "Firmware:" line it prints at startup).
Then either tap the firmware you used last time (offered at the top, so reinstalling is one tap), **Download the
newest from GitHub** (the newest release of `ajakef/aspen-firmware`, which must have the Arduino IDE's `.bin` file
attached), or **Choose a .bin file from this phone** (such as an email attachment; it shows your Downloads folder).
The firmware goes through the cable at 115,200 baud. Stay on the screen until it says "Done".

**Differences from the Python version:**
- The first 10 samples (0.05 s) are discarded, because the logger's startup values are extreme.
  (The Python script does this too now.)
- Data lines with fewer than four values have the missing ones taken as zero (the logger leaves out
  trailing zeros), instead of being dropped.
- No y-axis numbers on the traces, and time labels only on the bottom panel.

## For developers

Everything is in this `app/` folder; nothing in the folder above is modified by the app.
It is a [Flutter](https://flutter.dev) app (Dart code) with a small amount of Kotlin for the USB connection.

| File | What it does |
| --- | --- |
| `lib/main.dart` | The Plot tab: three panels, status card, redraw timer |
| `lib/home_screen.dart` | The tabs; owns the connection to the logger |
| `lib/boot_report.dart` | Reads the logger's startup report into the Check tab's checklist (matches the firmware's wording) |
| `lib/check_session.dart` | Check tab's side of the connection: asks for CONFIG.TXT (GT:), saves settings (GN:/CF:, then SVC), saves logs |
| `lib/check_screen.dart`, `lib/config_editor.dart`, `lib/saved_logs_screen.dart` | Check tab screens |
| `lib/config_file.dart` | CONFIG.TXT line checker; the editor's settings and the commands that set them |
| `lib/sites/` | Sites tab: data (`site_model.dart`), storage, export/import zip (`site_exchange.dart`), GPS and compass math (`geo.dart`), screens |
| `lib/signal_processor.dart` | Line parsing, scaling, integration, 1 Hz high-pass filter (as `utils.py`), 10-sample warm-up |
| `lib/spectrogram.dart` | Spectrogram math (as `scipy.signal.spectrogram`) |
| `lib/spectrogram_plot.dart`, `lib/trace_plot.dart`, `lib/plot_axes.dart`, `lib/viridis.dart` | Drawing |
| `lib/firmware_screen.dart`, `lib/firmware_source.dart` | Firmware update screen; finds and downloads the file from GitHub |
| `lib/svl_uploader.dart` | Loads the file into the Artemis bootloader (a port of SparkFun's `svl.py`) |
| `lib/serial_link.dart` | Dart side of the USB connection; on the Plot tab, answers the logger's `Enter Serial Number` prompt |
| `android/.../MainActivity.kt` | Android side of the USB connection (500,000 baud, 8N1), file picking, saving to Downloads, magnetic declination |
| `android/.../res/xml/device_filter.xml` | USB IDs that make Android offer to open the app (FT232 only) |
| `icon.png`, `make_icons.py` | Icon artwork and the script that makes the Android icons from it |

**Setup:** install Flutter and Android Studio (for the Android SDK), then run `flutter doctor` in this folder.
On the phone, turn on Developer options and USB debugging.

**Everyday commands** (run in this folder):
- `flutter run --release`: build and install on the connected phone. (`flutter install` alone does *not* rebuild.)
- `flutter test`: run the tests. Add `--update-goldens` to redraw the test pictures in `test/goldens/`.
- `flutter analyze`: check the code for problems.

**Tests** compare the Dart code against the Python code on `sample_data.txt`, a real logger capture. The Check tab's
tests use `test/fixtures/boot_400x4_no_config.txt` (a real startup, from a bench serial capture) and a pretend
logger that answers GN:/CF:/SVC/GT: as the firmware does.
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

