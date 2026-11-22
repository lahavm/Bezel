# Bezel

A native macOS app that mirrors and records an Android phone over USB — and now
browses files on both devices in one window. Bezel bundles its own `adb` and the
[scrcpy](https://github.com/Genymobile/scrcpy) server, so nothing needs to be
installed on the Mac or on the phone, and no paid Apple account is required.

## Screenshot

<img width="2552" height="1413" alt="Bezel mirroring an Android phone, with the inspector open on the right" src="https://github.com/user-attachments/assets/49fef1fe-b848-419a-ba46-ff2f78796f76" />

## Features

**Mirror**
- Mirror the phone screen or its camera over USB, switching without reconnecting.
- Native refresh rate or 30/60 fps; 720p–4K; H.264 or HEVC.
- Record with phone audio or the phone mic. Start at a keyframe so files stay seekable.
- Picture-in-picture: add the Mac camera as a movable, shaped overlay (rounded,
  rectangle, circle, heart, optional background blur). "Separate files" writes a
  second full-frame webcam recording.
- Live level meters and gain sliders for phone audio and the Mac microphone; the
  Mac mic is mixed into the same MP4 as one normal audio track.
- Screenshots at the mirrored resolution. Full-screen preview.
- Optional mouse & keyboard control (off by default) — clicks, drags, scroll and
  typed keys are sent to the phone.

**Files** (⌘B)
- A Finder-like browser that shows this Mac and every connected Android device in
  one sidebar. List and icon views, path bar, quick look, search, sort, rename,
  new folder, split panes and an info pane.
- Drag files either direction between Mac and phone with exact progress, speed
  and ETA. Folders merge, conflicts ask (Replace / Keep Both / Skip), and uploads
  land via a temporary file so transfers are atomic.
- Drop files on the mirror window to send them to the phone's Download folder, or
  select files in Finder and use the **Send to Android** service.
- Copy/move within one phone stays on the device. Files can open as a tab (⌘B)
  or in their own window (⇧⌘B).

**Help**
- **Bezel Help** (Help ▶ Bezel Help) — a native help window.
- **About Bezel** (Help ▶ About Bezel) — version and source link.

## Shortcuts

| Shortcut | Action |
|---|---|
| `⌘R` | Start/stop recording |
| `⌘S` | Screenshot |
| `⌃⌘F` | Full screen |
| `⌘\` | Show/hide inspector |
| `⌘B` | Toggle Files tab |
| `⇧⌘B` | Open Files in a new window |
| `⇧⌘2` | Split the Files pane |
| `⇧⌘P` | Show/hide the Files info pane |
| `⇧⌘N` | New folder (Files) |
| `⌘F` | Search in the current folder |
| `⌘↑` | Go up a folder (Files) |
| `⌘↩` | Connect/stop |

## Requirements

- macOS 26 or newer, Xcode 26.x to build from source.
- A data-capable USB cable and an Android device with USB debugging enabled.
- ~100 MB of disk space for the bundled `adb` and scrcpy server.

## Quick start

1. Download `Bezel.app` from the [Releases](https://github.com/lahavm/Bezel/releases)
   page, or build it yourself (below). Move it to Applications or anywhere.
2. On the phone, enable **Developer options** (Settings → About phone, tap
   *Build number* seven times) and **USB debugging** (Settings → System →
   Developer options).
3. Connect with a data-capable USB cable. Approve **Allow USB debugging?** on the
   phone (check *Always allow*) and macOS's accessory prompt.
4. In Bezel, pick your device from the top bar and press **Connect** (⌘↩). The
   first launch shows a short welcome walkthrough.
5. Mirror, record, or press **⌘B** to browse files.

## Build from source

```bash
git clone https://github.com/lahavm/Bezel.git
cd Bezel
./Scripts/fetch-vendor.sh   # one-time: download adb + scrcpy-server
./Scripts/build-app.sh      # produces build/Bezel.app
open build/Bezel.app
```

For development: `swift build` / `swift run` (finds `Vendor/` automatically).
Tests: `swift test` (the live-device round-trip test runs only when
`BEZEL_TEST_SERIAL` is set).

## What touches the phone

- One temporary `/data/local/tmp/bezel-server-5.0.1.jar`, pushed before a session
  and deleted when it ends.
- Fixed adb commands: `getprop`, `push`, `reverse`, `rm`, and starting the scrcpy
  server. No installs; no account; no data leaves your Mac except the files you
  transfer. Input injection happens only if mouse & keyboard control is enabled.
- Quitting (⌘Q) removes the server jar, stops the reverse tunnel and kills the
  private adb daemon — no residual processes.

## Known limitations

- macOS 26 or newer is required.
- Mouse & keyboard control is opt-in, works only while mirroring the screen, and
  sends keycodes only (no clipboard sync or IME composition).
- Background blur needs a visible person; without one the camera is unblurred.
- 4K60 depends on the phone encoder and the Mac; the frame-rate readout shows
  what actually arrives.
- The file browser needs the phone unlocked with USB debugging authorized; a
  locked phone can mirror but may refuse `adb shell` file access.
- Quick Look downloads a remote file first, so very large videos can take a moment.
- Filenames containing a newline are not supported by the phone listing parser;
  spaces, quotes, unicode and `|` are handled.
- **Send to Android** from Finder must be registered once: launch Bezel, then log
  out and back in if the Service is missing from Finder's menu.

## Third-party software

Bezel is free, ad-hoc signed, and built for personal use. Third-party code is
used under its own license; full license texts are copied into the app bundle by
`Scripts/build-app.sh`.

| Project | License | Purpose |
|---|---|---|
| [scrcpy](https://github.com/Genymobile/scrcpy) (Genymobile) | Apache-2.0 | USB mirroring and capture; server jar v5.0.1 bundled |
| [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) (Google) | Apache-2.0 | bundled `adb` |
| [Swift](https://swift.org) / SwiftUI / AVFoundation / CoreAnimation (Apple) | Apple terms | language and frameworks |
| [HeartPath](Sources/Bezel/Core/HeartPath.swift) (this repo) | — | path for the heart-shaped webcam mask |

Created by Lahav Meshulam. Source: <https://github.com/lahavm/Bezel>
