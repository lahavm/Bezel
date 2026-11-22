# Bezel

Native macOS app that mirrors and records an Android phone or tablet over USB,
using [scrcpy](https://github.com/Genymobile/scrcpy) under the hood. Self-contained:
the app bundles its own `adb` and the scrcpy server, so nothing needs to be installed
on the Mac (beyond macOS 26) or on the device.

## Status

Mirroring, phone screen/camera recording, phone audio, Mac microphone and
picture-in-picture with an (external) Mac camera work. Direct mouse/keyboard
control is **opt-in** (off by default); click/drag/scroll/type on the mirror to
send events to the phone. Touch, scroll, click, and keyboard are supported when
control is enabled.

## Screenshots

<img width="2552" height="1413" alt="Bezel mirroring an Android phone, with the inspector open on the right" src="https://github.com/user-attachments/assets/49fef1fe-b848-419a-ba46-ff2f78796f76" />

## Features

- **Mirror the phone screen or its camera** over USB, switching between them
  without reconnecting. Native refresh rate, or 30/60 fps; 720p, 1080p, 1440p,
  4K or native resolution; H.264 or HEVC.
- **Record the phone** with no re-encoding, with phone audio or the phone mic.
- **"Phone + Mac camera"** turns the Mac camera into a movable overlay in the
  phone video. Drag it in the preview, change its size, pick rounded, rectangle,
  circle or heart, and optionally blur the background behind the person. The live
  preview and the exported file use the same settings.
- **Turn on "Separate files"** to get two files instead: the phone recording
  with its chosen phone audio, and a full-frame Mac camera recording with the
  chosen microphone. The shape, size and blur controls shape the combined file.
- **Live level meters** for the phone audio and the Mac microphone, with gain
  sliders (0–200%) so a silent or quiet take is visible before and during
  recording. The Mac microphone is mixed into the same MP4 as one normal audio
  track.
- **Screenshots** at the mirrored resolution.
- **Recordings start at a keyframe** (up to a second after pressing record), which
  keeps the files seekable even on still screens.
- **Full-screen preview** with the controls hidden.
- **Choose the recordings folder** (defaults to `~/Movies/Bezel`).
- **Inspector** can be folded away with the sidebar button (or `⌘\`) to give the
  preview the full window. It folds automatically when a recording starts and
  comes back when the recording is saved.
- **Mouse & keyboard control** (opt-in). With "Mouse & keyboard control" on in
  the inspector, clicks, drags and the scroll wheel on the mirror are sent to
  the phone as touch events, and Mac keyboard keys are typed as Android keycodes.
  Right-click (or Esc) acts as back. Control only works while mirroring the phone
  screen; turning it on or off reconnects the session.
- **About panel** (⌘⇧? or Help ▶ About Bezel) shows the version and a link to
  the source code on GitHub.

### Shortcuts

| Shortcut | Action |
|---|---|
| `⌘R` | Start/stop recording |
| `⌘S` | Screenshot |
| `⌃⌘F` | Full screen |
| `⌘\` | Show/hide inspector |
| `⌘↩` | Connect/stop |

## Build

### Requirements

- Xcode 26.x, macOS 26.
- About 2 GB of disk space for the bundled adb + scrcpy-server.

### Quick start (pre-built app)

1. Download the latest `build/Bezel.app` from the [Releases](https://github.com/lahavm/Bezel/releases) page (or build it yourself — see below).
2. Move `Bezel.app` to your Applications folder (or keep it anywhere).
3. Run **Bezel** once. If this is the first launch, a welcome screen appears;
   click **Get started**.
4. On your phone: enable **Developer options** (Settings → About phone, tap
   "Build number" seven times), then **USB debugging** (Settings → System →
   Developer options). Turn Developer options on if not already.
5. Connect the phone to your Mac with a data-capable USB-C cable.
6. Approve **"Allow USB debugging?"** on the phone (check "Always allow") and
   macOS's **"Allow accessory to connect?"** prompt.
7. In Bezel, pick your device from the top bar and press **Connect** (⌘↩).
8. When the mirror appears you're ready to record, take screenshots, or add the
   Mac camera as a picture-in-picture overlay.

### Build from source

```bash
# 1. Clone the repo
git clone https://github.com/lahavm/Bezel.git
cd Bezel

# 2. (One-time) download adb + scrcpy-server
./Scripts/fetch-vendor.sh

# 3. Build
./Scripts/build-app.sh   # produces build/Bezel.app

# 4. Run
open build/Bezel.app
```

For development (run from the repo root):

```bash
swift build          # builds the binary
swift run            # runs the app (finds Vendor/ automatically)
```

### First-launch welcome screen

If this is the first time you run Bezel, a welcome view explains the four steps
to enable USB debugging:

1. **Turn on Developer options** — on the phone: Settings → About phone, tap
   "Build number" seven times until it says "You are now a developer."
2. **Enable USB debugging** — Settings → System → Developer options, turn it on,
   then enable "USB debugging."
3. **Plug in and approve** — connect with a data-capable USB cable, then approve
   "Allow USB debugging?" on the phone (check "Always allow") and macOS's
   "Allow accessory to connect?" prompt.
4. **Connect in Bezel** — pick your device from the top bar and press Connect
   (⌘↩). When the mirror appears you're ready to record, screenshot, or add the
   Mac camera as a picture-in-picture overlay.

The welcome screen is shown only once; the setting `hasSeenWelcome` persists
across launches (stored in `~/Library/Application Support/Bezel/`).

## Device setup

1. **Phone**: enable Developer options and USB debugging (see above).
2. **Connect**: use a data-capable USB-C cable. Approve the prompts on both the
   phone and macOS.
3. **First use**: Bezel will push a temporary `bezel-server-5.0.1.jar` to the
   phone, start the scrcpy server over a reverse tunnel, and begin mirroring.
4. **Quit**: quit Bezel (⌘Q). The app removes the temporary server jar, stops
   the reverse tunnel, and kills its private adb daemon. No residual processes
   remain.

## What touches the phone

- One temporary file, `/data/local/tmp/bezel-server-5.0.1.jar`, pushed before a
  session and deleted when it ends.
- A fixed set of adb commands: `getprop`, `push`, `reverse`, `rm`, and starting
  the scrcpy server. **No installs, no file access, no input injection** (unless
  "Mouse & keyboard control" is turned on).
- The camera is activated only in camera mode; Android shows its indicator.
- Recording writes to the chosen folder (`~/Movies/Bezel` by default).
- The app decodes the stream locally for the preview; a screenshot is that
  displayed frame, so it works in screen and camera mode alike.

The app reuses an adb server that is already running (Android Studio, Homebrew).
If none is running, it starts the bundled adb with its own key store under
`~/Library/Application Support/Bezel/` and stops that daemon on quit. There is
**no telemetry and no network access** beyond the local USB connection.

## Layout

```
Sources/Bezel/
  App/        AppState, entry point
  Core/       ADB wrapper, scrcpy session, parsers, preview, recorders, PiP/mix
  UI/         SwiftUI window and preview view
Docs/         screenshots used by this README
Resources/    Info.plist, app icon
Vendor/       adb + scrcpy-server (downloaded, not committed)
Scripts/      fetch-vendor.sh, build-app.sh
```

## Known limitations

- macOS 26 or newer is required.
- **Mouse & keyboard control** is opt-in and only works while mirroring the screen.
  It reconnects automatically when turned on or off. Keyboard input sends
  keycodes only: clipboard sync and IME composition are not forwarded.
- The picture-in-picture overlay is written after recording stops, so a very long
  take takes a moment to finish.
- Background blur uses person segmentation. It needs a visible person; when no
  person is found the camera is shown unblurred.
- 4K60 is limited by the phone's encoder and the fanless Mac; the frame-rate
  readout shows what actually arrives.
- Some phones expose only their main and front cameras, so ultrawide or tele
  lenses appear only when Android lists them.

## Third-party software

Bezel depends on the following open‑source projects. All are used under their
respective licenses.

| Project | License | Purpose |
|---|---|---|
| **[scrcpy](https://github.com/Genymobile/scrcpy)** (Genymobile) | Apache‑2.0 | USB mirroring + video+audio capture; server jar v5.0.1 bundled |
| **[Android platform-tools](https://developer.android.com.platform-tools)** (Google) | Apache‑2.0 | `adb` binary for device communication |
| **[Swift](https://swift.org)** (Apple) | Apache‑2.0 / LLVM Exception | Language |
| **[SwiftUI](https://developer.apple.com/swiftui)** (Apple) | Proprietary | UI toolkit |
| **[AVFoundation](https://developer.apple.com/avfoundation)** (Apple) | Proprietary | Audio/video capture and mixing |
| **[CAShapeLayer / CoreAnimation](https://developer.apple.com/quartzcore)** (Apple) | Proprietary | Layer masking and PiP overlay shapes |
| **[HeartPath](https://github.com/lahavm/Bezel/blob/main/Sources/Bezel/Core/HeartPath.swift)** (this repo) | — | SVG‑derived path for heart-shaped webcam mask |

License texts are copied into the app bundle by `Scripts/build-app.sh`.

## How to use — step by step

### 1. Connect your phone

- Enable Developer options and USB debugging on the phone (see above).
- Connect with a data-capable USB-C cable.
- Approve the prompts on both devices.

### 2. Choose your input source

- **Screen** — mirror the phone's display. This is the default.
- **Camera** — use the phone's rear or front camera as a video source. Pick the
  lens (back/front/external) in the inspector.

### 3. Choose your audio

- **Phone** — record the phone's audio output.
- **Phone mic** — record using the phone's microphone.
- **Mac microphone** — record using your Mac's microphone (toggle "Record Mac
  mic" in the inspector).
- **None** — recording has no audio track.

### 4. Optional: Add a Mac camera overlay

- Connect an external webcam (the built-in iSight is unavailable while the Mac
  lid is closed).
- In the inspector, turn on "Record Mac microphone" if you want audio from the
  webcam.
- Toggle "Separate files" if you want two output files: one phone recording +
  one full-frame Mac camera recording. Otherwise the webcam appears as a shaped
  PiP overlay in the single combined file.
- Adjust the overlay: drag it, resize with the slider, pick a shape (rounded,
  rectangle, circle, heart), and optionally blur the background.

### 5. Record

- Click the **Record** button (⌘R) or press the toolbar button.
- A red REC badge appears at the top of the preview (UI‑only; never in the
  exported file).
- Recording continues until you click **Stop** (⌘R) or press the button again.
- If "Separate files" is on, you get two MP4 files when recording stops. If off,
  you get one MP4 with the phone video, the webcam PiP, and the mixed audio.

### 6. Screenshot

- Click the **Screenshot** button (⌘S) or press the toolbar button.
- The current mirror frame is saved as a PNG to your recordings folder.

### 7. Manage recordings

- Recordings land in `~/Movies/Bezel/` by default. Change the folder in the
  inspector under "Save to".
- Right‑click (or Control‑click) a recording in the Finder to **Show in Finder**,
  or use the **Show Recordings in Finder** button in the Help menu.
- Recordings are ordinary MP4/PNG files — playable in QuickTime, VLC, etc.

### 8. Quit Bezel

- Press ⌘Q or choose Bezel ▶ Quit Bezel.
- The app cleans up: removes the server jar, stops the reverse tunnel, and kills
  its private adb daemon. No residual processes remain on the Mac or the phone.

## Credits & license

**Bezel** is a personal‑use macOS app created by **Lahav Meshulam**. It is free,
ad‑hoc signed, and requires no paid Apple account or sandbox.

All third‑party code is used under its own license. The full license text for
each dependency is included in the app bundle (see the "Third‑party software"
section above, and the licenses copied by `Scripts/build-app.sh`).

- **scrcpy** (Genymobile) — Apache‑2.0 — server jar v5.0.1, bundled.
- **Android platform-tools adb** (Google) — Apache‑2.0 — bundled.
- **Swift, SwiftUI, AVFoundation, CoreAnimation** (Apple) — per Apple's
  developer terms.
- **HeartPath** (this repo) — custom path for heart-shaped webcam mask.

If you find Bezel useful, consider starring the repo on GitHub:
<https://github.com/lahavm/Bezel>

---

