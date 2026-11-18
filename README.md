# Bezel

Native macOS app that mirrors and records an Android phone or tablet over USB.
Self-contained: the app bundles its own `adb` and the scrcpy server, so nothing
has to be installed on the Mac (beyond macOS 26) or on the device.

Status: mirroring, phone screen/camera recording, phone audio, Mac microphone
and picture-in-picture with an (external) Mac camera work. Touch/keyboard control is not
implemented.

## Features

- Mirror the phone screen or its camera over USB, switching between them without
  reconnecting. Native refresh rate, or 30/60 fps; 720p, 1080p, 1440p, 4K or
  native resolution; H.264 or HEVC.
- Record the phone with no re-encoding, with phone audio or the phone mic.
- "Phone + Mac camera" turns the Mac camera into a movable overlay in the phone
  video. Drag it in the preview, change its size, pick rounded, rectangle,
  circle or heart, and optionally blur the background behind the person. The
  live preview and the exported file use the same settings.
- Turn on "Separate files" to get two files instead: the phone recording with
  its chosen phone audio, and a full-frame Mac camera recording with the chosen
  microphone. The shape, size and blur controls shape the combined file.
- Live level meters for the phone audio and the Mac microphone, with gain
  sliders (0–200%) so a silent or quiet take is visible before and during
  recording. The Mac microphone is mixed into the same MP4 as one normal audio
  track.
- Screenshots at the mirrored resolution.
- Recordings start at a keyframe (up to a second after pressing record), which
  keeps the files seekable.
- Full-screen preview with the controls hidden.
- Choose the recordings folder (defaults to `~/Movies/Bezel`).

Shortcuts: `⌘R` start/stop recording, `⌘S` screenshot, `⌃⌘F` full screen,
`⌘↩` connect/stop.

Camera notes:
- The phone camera works regardless of the Mac's lid state.
- The built-in Mac camera is unavailable while the lid is closed; an external
  webcam is used automatically when one is connected.

## Build

Requirements: Xcode 26.x, macOS 26.

```bash
./Scripts/fetch-vendor.sh   # once: downloads adb + scrcpy-server
./Scripts/build-app.sh      # builds build/Bezel.app
open build/Bezel.app
```

For development: `swift build` and `swift run` (the app finds `Vendor/` when run
from the repository root).

## Device setup

1. On the phone: enable Developer options and USB debugging.
2. Connect with a data-capable USB-C cable.
3. Approve the "Allow USB debugging?" prompt (check "Always allow") and macOS's
   "Allow accessory to connect?" prompt.

## What touches the phone

- One temporary file, `/data/local/tmp/bezel-server-5.0.1.jar`, pushed before a
  session and deleted when it ends.
- A fixed set of adb commands: `getprop`, `push`, `reverse`, `rm`, and starting
  the scrcpy server. No installs, no file access, no input injection.
- The camera is activated only in camera mode; Android shows its indicator.
- Recording writes to the chosen folder (`~/Movies/Bezel` by default).
- The app decodes the stream locally for the preview; a screenshot is that
  displayed frame, so it works in screen and camera mode alike.

The app reuses an adb server that is already running (Android Studio, Homebrew).
If none is running, it starts the bundled adb with its own key store under
`~/Library/Application Support/Bezel/` and stops that daemon on quit. Reverse
tunnels and the temporary server jar are removed on stop and on quit. There is
no telemetry and no network access.

## Layout

```
Sources/Bezel/
  App/        AppState, entry point
  Core/       ADB wrapper, scrcpy session, parsers, preview, recorders, PiP/mix
  UI/         SwiftUI window and preview view
Resources/    Info.plist
Vendor/       adb + scrcpy-server (downloaded, not committed)
Scripts/      fetch-vendor.sh, build-app.sh
```

## Known limitations

- No touch, keyboard or clipboard control (viewing and recording only).
- The picture-in-picture overlay is written after recording stops, so a very
  long take takes a moment to finish.
- Background blur uses person segmentation. It needs a visible person; when no
  person is found the camera is shown unblurred.
- 4K60 is limited by the phone's encoder and the fanless Mac; the frame-rate
  readout shows what actually arrives.
- Some phones expose only their main and front cameras, so ultrawide or tele
  lenses appear only when Android lists them.
- macOS 26 or newer is required.

## Third-party software

- scrcpy (Apache-2.0), Genymobile — server jar, pinned to 5.0.1.
- Android platform-tools `adb` (Apache-2.0), Google.

License texts are copied into the app bundle by `build-app.sh`.
