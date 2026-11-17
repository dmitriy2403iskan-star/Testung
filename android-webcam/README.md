# Android WebCam Studio

OBS-style scene compositor for Android: camera preview + draggable image overlays + recording.

## Important limitation
A normal third-party Android app cannot register itself as a system-wide camera device visible to Telegram/Discord/Teams. Android camera providers are system/privileged components on normal devices. This project therefore implements the **OBS-like scene/compositor layer** and records the composed output. A real system virtual camera requires a device/ROM/root-level camera-provider solution or an external bridge.

## Build
Open `android-webcam` in Android Studio and build the APK, or use the included GitHub Actions workflow.
