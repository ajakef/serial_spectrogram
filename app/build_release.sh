#!/bin/bash
# Builds the APK to share (build/aspen-plot.apk), signed with your release key.
# Refuses to run if the key isn't set up, so a debug-signed APK can't be shared by accident.
# Before each new release, raise the number after "+" in "version:" in pubspec.yaml.
set -e
cd "$(dirname "$0")"
if [ ! -f android/key.properties ]; then
    echo "android/key.properties not found. See 'Releasing' in README.md." >&2
    exit 1
fi
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk build/aspen-plot.apk
apksigner=$(ls -d "$HOME"/Android/Sdk/build-tools/*/apksigner | sort -V | tail -1)
"$apksigner" verify --print-certs build/aspen-plot.apk | grep -E "Signer #1 certificate (DN|SHA-256)"
echo "Built: $(pwd)/build/aspen-plot.apk"
