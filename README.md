# Bezel

Native macOS app that mirrors and records an Android phone or tablet over USB.
Self-contained: the app bundles its own `adb` and the scrcpy server, so nothing
has to be installed on the Mac (beyond macOS 26) or on the device.

Status: **Phase 0** — device discovery and live h.264 preview work. Camera source
selection and recording are next.

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

The app runs its own adb server on port 5038 with its own key store under
`~/Library/Application Support/Bezel/`, so it never reads or modifies `~/.android`.
There is no control channel, no telemetry, and no network access.

## Layout

```
Sources/Bezel/
  App/        AppState, entry point
  Core/       ADB wrapper, scrcpy session, h.264 parser, preview renderer
  UI/         SwiftUI window and preview view
Resources/    Info.plist
Vendor/       adb + scrcpy-server (downloaded, not committed)
Scripts/      fetch-vendor.sh, build-app.sh
```

## Third-party software

- scrcpy (Apache-2.0), Genymobile — server jar, pinned to 5.0.1.
- Android platform-tools `adb` (Apache-2.0), Google.

License texts are copied into the app bundle by `build-app.sh`.
