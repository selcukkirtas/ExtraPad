# ExtraPad

Turns an old iPad into a **wireless second display** for your Mac. Does what
Duet or Sidecar does, is free, and needs nothing installed on the iPad.

A real virtual display is created on the Mac - System Settings sees it as an
ordinary monitor and you can drag windows onto it - then captured and streamed
live to Safari on the iPad. Touching the iPad drives the Mac's cursor.

## Why this architecture

The iPad runs iOS 9-11, so a native iPad app **cannot be built**: current Xcode
cannot sign and install below iOS 15. The iPad side therefore has to be Safari,
and that decides the codec:

| Approach | On Safari for iOS 9-11 |
|---|---|
| WebRTC | Absent (arrived in iOS 11, nothing before) |
| H.264 + Media Source Extensions | Absent (MSE came to iOS much later) |
| **JPEG regions** | **Works** - Safari decodes with its own JPEG path |

So every update is JPEG. What changed over time is *how much* JPEG: the first
working version sent whole frames, the current one sends only the rectangles
that changed.

## Result measured on an iPad 2 (A1395)

Numbers the device itself reported, at 1024x768:

| | First working version | Now |
|---|---|---|
| Frames the iPad received | 4.8 fps | **42 fps** |
| Bandwidth | 8.3 Mbit/s | **0.90 Mbit/s** |
| Quality | 0.6 | **0.95** |
| Draw time on the iPad | - | 10 ms/frame |
| Client queue | - | 0 |
| Share of the link ceiling used | 55% | **6%** |

Nine times the frame rate on a ninth of the bandwidth, at higher quality.

## Install

```bash
cd ExtraPad
./scripts/build-app.sh
open "$HOME/Library/Application Support/ExtraPad/ExtraPad.app"
```

The bundle is built outside the project on purpose: if the repo sits in iCloud
Drive (`~/Documents` and `~/Desktop` do by default), the file provider stamps
`com.apple.FinderInfo` onto the bundle while `codesign` is sealing it, and
signing fails every time.

On first run macOS asks for **Screen Recording**: System Settings > Privacy &
Security > Screen & System Audio Recording > ExtraPad. Restart the app once
after granting it. Touch input additionally needs **Accessibility**; without it
macOS silently swallows synthetic events, so the app checks up front and puts a
shortcut in the menu bar if it is missing.

The build script prefers a real signing certificate over an ad-hoc signature.
This matters more than it looks: macOS ties the Screen Recording permission to
the app's code identity, and an ad-hoc signature changes its hash on every
build, so the permission is revoked each time you rebuild.

## Use

1. Click the ExtraPad icon in the menu bar. It shows the address and a
   six-digit pairing code.
2. On the iPad, open Safari and go to the address - just `http://192.168.x.x:8777`.
3. Enter the six-digit code. iOS shows a number pad for it.
4. **Share > Add to Home Screen** to run it full screen without Safari's chrome.

The code is entered once; a cookie carries the session afterwards, so the
home-screen shortcut opens straight into the screen.

On the iPad, keep the display awake: Settings > Display & Brightness >
Auto-Lock > Never.

### Options

```bash
"$HOME/Library/Application Support/ExtraPad/ExtraPad.app/Contents/MacOS/ExtraPad" --help
```

| Option | Default | Notes |
|---|---|---|
| `--size WxH` | `1024x768` | Old 9.7" iPads report 1024x768 to Safari |
| `--fps N` | `24` | Remembered. Setting it higher than the link can carry is harmless |
| `--quality Q` | `0.8` | Remembered. Can sit near 1.0 - only changed regions are sent |
| `--scale 1\|2` | `1` | 2 = HiDPI; wasted on a non-Retina iPad |
| `--position DIR` | `right` | `left`/`right`/`above`/`below`; also in the menu |
| `--hud` | off | Diagnostic strip on the iPad; also toggled from the menu |
| `--no-input` | input on | View only, no touch control |
| `--no-auth` | key on | Disables the access key - trusted networks only |
| `--port N` | `8777` | |
| `--mirror` | off | Mirror the main display instead of creating one |

Position, quality, frame rate and the diagnostic strip are **remembered**: the
virtual display is recreated on every launch, so macOS cannot remember them for
you.

Run the binary inside the bundle directly to see logs.

### Tests

```bash
./scripts/test.sh
```

The wrapper forces the build directory outside the project. If the repo sits in
iCloud Drive, signing the test bundle fails there for the same reason the app
bundle is built elsewhere.

### Endpoints

- `/` - the iPad client (delta mode)
- `/mjpeg` + `/stream` - fallback full-frame client and stream
- `/ws` - the delta stream (WebSocket)
- `/snapshot` - one JPEG frame
- `/info` - JSON status: frames produced, per-client **sent/skipped** counts,
  bytes, achieved fps, and delta-encoder counters. This is the diagnostic tool
  that matters.
- `/set?quality=0.3&fps=12` - retunes a **running** stream; clients stay
  connected and nothing has to be reloaded

## Access control

Anyone who can reach the port could otherwise watch the screen and - since touch
input landed - drive the mouse. Three gates, in order:

1. **The address** - is the device on your network at all.
2. **A six-digit pairing code** - does it know the secret. Wrong guesses are
   slowed down progressively and the code retires itself after 20 of them.
3. **Device approval on the Mac** - is it one of your devices.

A device that enters the correct code is let straight in; the secret has just
been checked, and confirming the same thing again on the Mac would be friction
rather than security. The approval prompt remains for what it was meant for: a
device that turns up already holding a cookie but has never entered a code.

The menu bar lists **currently connected** devices, not every device that has
ever paired, and can clear stored approvals.

**Why iCloud accounts are not matched:** Safari gives a web page nothing about
the Apple ID, and matching accounts through CloudKit needs a native app, which
means iOS 15+. This iPad is on iOS 9, so that route is closed. Asking the person
at the Mac answers the same question better under these constraints.

**Be clear about what this is:** a shared secret over plain HTTP on a LAN. It
stops someone who knows the address. It does not stop someone who can read your
network traffic, because the key and the screen both travel in the clear. TLS
would fix that, but iOS 9 makes a self-signed certificate painful enough that it
would cost more than it buys here. Fine on a home network; do not leave it
running on a shared one.

## Touch input

One finger drives the Mac's cursor: tapping clicks, dragging drags. Coordinates
travel back over the same WebSocket as text (`D`/`M`/`U` plus x and y) in the
virtual display's own pixel space; the server adds the display's position in the
global arrangement and posts a `CGEvent`. That position is read fresh each time,
because you can move the display from the menu.

Two details worth knowing:

- **Move messages are capped at ~60/s.** The Mac cannot use more than the
  capture rate, and the iPad pays for every message.
- **If the connection drops mid-drag the button is released**, so the Mac is not
  left with a stuck mouse button.

## The network matters more than the settings

The single biggest gain in this project came from the network, not from tuning.

While the Mac and the iPad shared one radio, every byte crossed the air twice
(Mac to router, router to iPad) and the slower client set the pace for the whole
medium:

| Topology | Ceiling | iPad at quality 0.25-0.3 |
|---|---|---|
| Mac and iPad on the same 5 GHz radio | 8-9 Mbit/s | 12-13 fps |
| **Mac on 5 GHz, iPad on 2.4 GHz (separate radios)** | **15 Mbit/s** | **27 fps** |

So put them on **separate radios** first. Note also that old iPads often run
802.11n on 2.4 GHz only and fall back to 802.11a on 5 GHz - for those devices
2.4 GHz can be the *faster* band, the opposite of the usual advice.

If the iPad cannot see a 5 GHz network at all, the usual cause is the router:
iOS 9 joins **WPA2-PSK (AES)** only, not WPA2/WPA3 transition mode, and old
devices never see DFS channels (52-144). Fix the security mode and pin the
channel to 36-48.

## How the delta stream works

The screen is compared with the previous frame in 32px tiles; changed tiles are
merged into a few large rectangles, packed into a **single JPEG atlas**, and sent
with their coordinates. The client decodes once per frame and blits each region
out of the atlas with a cheap, synchronous `drawImage`.

Every part of that shape was forced by measurement:

- **One image per frame, not one per region.** The first version sent each
  region as its own image, which meant a Blob -> objectURL -> Image -> decode
  round trip per region. On iOS 9 each of those costs 10-20 ms, so at tens of
  regions per second the client fell behind and the picture lagged behind the
  mouse - while the server saw no backpressure at all, because Safari kept
  draining the socket into its own buffer.
- **The queue is short (3 frames).** Whatever is queued is already stale; a long
  queue *is* latency.
- **No update may be skipped.** A missed patch leaves a stale rectangle on the
  canvas until the next keyframe, so a client that cannot keep up is skipped
  entirely rather than fed a partial update.
- **Quality follows motion.** When most of the screen is changing, quality drops
  - detail is already blurred by motion, and a 270 KB full frame takes long
  enough to send that the client falls behind. When the screen settles, tiles
  that were sent at reduced quality are repainted sharp a batch at a time, using
  bandwidth that would otherwise sit idle.
- **A client that falls behind asks for one keyframe, not one per frame**, and
  the request is time-throttled rather than latched. A latch deadlocks: if the
  keyframe it waits for is itself dropped, it never opens and the client is
  skipped silently forever - the symptom is a frozen picture while the server
  happily keeps producing frames.
- **A send that never completes drops the connection** after five seconds, so
  the client reconnects instead of staring at a frozen screen.

Measured on the same machine at the same quality (0.6): full frames cost
8.3 Mbit/s for 6.8 fps; deltas cost 1.1 Mbit/s for roughly 30 fps, with an idle
screen costing nothing at all.

## Two streaming modes

| Address | Path | Use |
|---|---|---|
| `/` (and `/delta`) | Changed rectangles, WebSocket + canvas | **Default.** Far less bandwidth and a much higher frame rate at the same quality |
| `/mjpeg` | Full-frame MJPEG inside an `<img>` | Fallback: needs no WebSocket, no canvas and no JavaScript in the pixel path |

## Known limits

- **No wired connection.** Safari cannot reach the Mac over USB. The one
  exception is a cellular iPad, where USB tethering gives a steadier IP link.
  Real wired support needs a native iPad app, which means iOS 15+.
- **Bluetooth is not an alternative**, for three separate reasons: Safari on iOS
  has no Bluetooth API at all, so there is no code path; BLE on that generation
  of iPad carries roughly 0.1-0.3 Mbit/s against the 15 Mbit/s needed; and
  Bluetooth shares the 2.4 GHz band, so it would degrade the Wi-Fi link in use.
- **The virtual display uses a private API** (`CGVirtualDisplay`). Verified on
  macOS 27. If a macOS update breaks it the app does not crash - it falls back
  to `--mirror`.
- **Rebuilding can reset permissions** if no signing certificate is available
  and the app falls back to an ad-hoc signature.

## Layout

| File | Responsibility |
|---|---|
| `Sources/VirtualDisplayBridge/` | Objective-C declarations of the private `CGVirtualDisplay` classes. Instances come from `NSClassFromString` and fields are set through KVC, so a renamed field costs one skipped field instead of a crash |
| `Sources/ExtraPad/AppController.swift` | Menu bar app, pipeline setup, permission flows |
| `Sources/ExtraPad/ScreenStreamer.swift` | ScreenCaptureKit capture and JPEG encoding |
| `Sources/ExtraPad/DeltaEncoder.swift` | Tile diffing, rectangle merging, atlas packing, progressive refresh |
| `Sources/ExtraPadProtocol/` | Everything both sides of the wire need and nothing platform specific: version, wire format with encoder *and* decoder, WebSocket framing. The future iOS client depends on exactly this target |
| `Sources/ExtraPad/MJPEGServer.swift` | Hand-written HTTP/1.1 server, routing, access control |
| `Sources/ExtraPad/Auth.swift` | Access key, pairing code, cookies |
| `Sources/ExtraPad/DeviceRegistry.swift` | Per-device approval |
| `Sources/ExtraPad/InputInjector.swift` | Touches to `CGEvent` mouse events |
| `Sources/ExtraPad/WebClient.swift` | Every page the iPad sees, ES5 |

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
