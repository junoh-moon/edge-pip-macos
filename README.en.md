# Edge PiP for macOS

[한국어](README.md)

Use Microsoft Edge’s built-in Picture-in-Picture (PiP) button to keep watching when you swipe to another desktop or full-screen app. The Mac app displays the video Edge is already playing, so playback continues from the same point without reloading.

## How it works

- For ordinary videos, the Mac app shows one floating PiP window across Spaces. Edge’s original PiP window supplies the video frames from offscreen and resizes with the floating window.
- Hover over the video to resize it, close PiP, or return to the original tab. The Edge extension connects the controls to the video. You can play or pause, seek, adjust the volume, and skip to the previous or next video when the site supports it.
- For protected playback on services such as TVING, the Mac app pauses screen capture and Edge shows its native PiP window. The app resumes capture for ordinary videos once protected playback ends. Video and audio are never saved to disk.

## Download and install

Download both files from the same [GitHub release](https://github.com/junoh-moon/edge-pip-macos/releases/latest). The **DMG contains the Mac app** for Apple silicon and Intel Macs. The **ZIP contains the Edge extension**. You’ll need macOS 15 or later, Microsoft Edge, and Python 3. Public builds use an ad hoc signature and are not notarized by Apple.

1. Open the DMG and copy `Edge PiP.app` to Applications. Keep the DMG open for step 3.
2. Unzip the extension into a folder you’ll keep. In Edge, open `edge://extensions`, turn on **Developer mode**, and choose **Load unpacked**. Select the folder containing `manifest.json`.
3. Run this command in Terminal to connect the extension to the Mac app.

   ```sh
   python3 "/Volumes/Edge PiP/Setup/register-host.py" "/Applications/Edge PiP.app/Contents/MacOS/EdgePiPRelay"
   ```

4. Open **Edge PiP** from Applications and grant the requested Screen Recording and Accessibility permissions. Screen Recording lets the app display Edge’s PiP video. Accessibility lets it move Edge’s original PiP window offscreen and restore it. From then on, use Edge’s usual PiP button.

## Build from source

Install the Xcode Command Line Tools, then run the following from the repository root.

```sh
./scripts/build.sh
```

Move `build/Edge PiP.app` to Applications and register the connection with the script in this checkout. Adjust the app path if you installed it elsewhere.

```sh
python3 scripts/register-host.py "/Applications/Edge PiP.app/Contents/MacOS/EdgePiPRelay"
```

In `edge://extensions`, turn on **Developer mode** and use **Load unpacked** to select this repository’s `extension` folder. Launch the Mac app and grant the permissions described above.

Local builds use ad hoc signing by default. To preserve permissions across your own builds, set `EDGE_PIP_SIGNING_SHA1` to the SHA-1 fingerprint of the same code-signing certificate in your keychain each time you build.

## Releases

When app, extension, resource, or build-script changes land on `main`, GitHub Actions publishes the DMG, extension ZIP, and SHA-256 checksums together. The version combines the app’s major and minor version numbers with the first-parent commit count on `main` through the release commit. The tag and both packages share that version. Rerunning the workflow for the same commit preserves the published release.

```sh
python3 scripts/release-version.py
python3 scripts/package-release.py
./scripts/publish-release.sh
```

## Test resolution and window recovery

After building, run these commands from the repository root. The test resizes a video window and checks the frame dimensions in pixels and the capture scale. It then moves the floating window offscreen and verifies that the same video surface returns to the display.

```sh
xcrun swiftc -D CAPTURE_RESOLUTION_TEST Sources/*.swift Tests/CaptureResolution.swift -o build/test-resolution
./build/test-resolution
```

## Version history

- **1.5.8** — Mission Control shows a single video preview. When you leave Mission Control, PiP continues in its previous position.
- **1.5.7** — If a swipe leaves the floating window on the previous desktop, the app restores the same video and controls on the current desktop. It keeps the last frame visible during the transition.
- **1.5.6** — The app checks that the floating window is visible on the current desktop before hiding Edge’s original PiP window. If recovery fails after a full-screen transition, it brings Edge’s window back onscreen.
- **1.5** — Ordinary videos use one floating window across Spaces. Protected videos automatically use Edge’s native PiP. Quitting the Mac app restores Edge’s original window.
- **1.4.1** — Capture resolution follows Edge’s PiP window when it grows or moves to a display with a different pixel density. The floating window uses the current display’s Retina scale.
- **1.4** — First public source release. It added PiP across desktops and full-screen apps, resizing and playback controls, last-frame retention during Space changes, and automatic capture suspension and resumption for protected playback.
