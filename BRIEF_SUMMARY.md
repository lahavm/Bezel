Bezel v0.0.1 — macOS 26 native app, native scrcpy mirroring/recording over USB.

Changes since the last check-in:
- ✅ Welcome screen with 4-step USB debugging guide; persists via `hasSeenWelcome`
- ✅ About panel (⌘⇧?) with version + GitHub source link
- ✅ Mouse & keyboard control — opt-in via inspector toggle; click/drag/scroll/type to phone
- ✅ Still-screen recording fix: seed from last keyframe + wall-clock final-frame hold
- ✅ Circle default for webcam shape, persisted across launches
- ✅ Full-screen REC badge UI-only; never in exported files
- ✅ Finder auto-open removed; explicit Open/Show buttons only
- ✅ Empty state uses `iphone.gen3` "Ready to mirror" symbol
- ✅ New graphite squircle icon (already bundled)
- ✅ Separate-files vs combined-file behavior unchanged and verified
- ✅ All builds pass `swift build` / `./Scripts/build-app.sh`

What's not verified end-to-end:
- Physical taps from Mac → phone (control socket works, but the phone was on the dialer screen during testing; touch events were sent but not visually confirmed in-app)
- Typing real text in Android apps from Mac keyboard (key mapping exists but IME/composition text not sent; risk: some key combos may not map as expected)
- HEVC + control interaction (control is screen-only)
- Full-screen focus behavior with mouse control active

Risk: the control socket is accepted after the audio socket; if audio is off, control still opens. Modifier combos like Shift+letter work, but system IME/composition is not supported. The welcome screen and about panel are fully functional; the app builds and launches cleanly.