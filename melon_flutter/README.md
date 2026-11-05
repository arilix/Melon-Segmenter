# Melon Segmenter (Flutter / Android)

Android port of the iOS app in the parent repository. It cuts a melon out of a photo with one tap
(MobileSAM, ONNX Runtime, fully on-device) and measures the rind netting with a Dart port of
DBL-GNG. Results can be uploaded to your own Google Drive.

Same features as the iOS version: melon library with HST, capture schedule and reminders, kept
photos and a processing queue, six-panel analysis with thickness sliders, polarity toggle, and
Drive upload with `density_log.csv`.

## Build

```bash
flutter pub get
flutter build apk --release --split-per-abi   # arm64-v8a is the one for modern phones
```

Install `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` on the phone (allow installs
from unknown sources). Requires Android 8.0 (API 26) or later.

## Google Drive setup (optional)

The iOS client ID does not work on Android. In the same Google Cloud project:

1. Enable the Drive API and configure the OAuth consent screen (add yourself as a test user).
2. Create an **OAuth client ID of type Android** with package name `com.arilix.melon_segmenter`
   and the SHA-1 of the key that signs the APK (`keytool -list -v -keystore ~/.android/debug.keystore`
   for the debug key the release build currently uses).
3. Create an **OAuth client ID of type Web application** and pass it at build time:

```bash
flutter build apk --release --split-per-abi \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>.apps.googleusercontent.com
```

Only the `drive.file` scope is requested. Without this setup the app still segments and analyzes;
use "Continue without signing in".

## Models

`assets/models/mobilesam.encoder.onnx` and `mobilesam.decoder.onnx` come from the
[PulpCut/mobilesam-onnx](https://huggingface.co/PulpCut/mobilesam-onnx) export of
[MobileSAM](https://github.com/ChaoningZhang/MobileSAM) (Apache-2.0). The encoder takes the photo
resized to a 1024 px long side and pads it itself.

## Notes

- Photos are decoded in Dart (`image` package), so a 12 MP photo takes a few seconds to prepare.
  Segmentation after that is quick, and a second tap on the same photo reuses the encoding.
- Metrics follow the iOS algorithm. Because image resizing and the random shuffle differ slightly
  between platforms, numbers can differ a little from the iPad for the same photo.

## Tests

```bash
flutter test
```
