# Architecture

## Data flow

```
CGVirtualDisplay (private CoreGraphics API)
        │  registers with macOS as a second monitor, returns a displayID
        ▼
ScreenCaptureKit (SCStream)
        │  BGRA CVPixelBuffer, fps frames per second
        ▼
DeltaEncoder
        │  32px tile diff → merged rectangles → one JPEG atlas
        ▼
PatchBroadcaster
        │  fan-out, with per-client backpressure
        ▼
MJPEGServer (Network.framework)
        │  WebSocket binary frames
        ▼
iPad Safari: one decode per frame, drawImage per region onto a canvas
        │
        └── touches travel back over the same socket → CGEvent on the Mac
```

## Design decisions

### Why a private API
There is no public way to add a display on macOS. `CGVirtualDisplay` is the
route tools like BetterDisplay take as well. The risk is contained by keeping
the declarations at runtime: if the class is missing, `EPVirtualDisplay.supported`
returns false and the app falls back to `--mirror`.

macOS attaches a newly created display in mirror mode, so capturing it would
return a squashed copy of the built-in screen. `CGConfigureDisplayMirrorOfDisplay`
turns that off, and the display is parked past the edge of *every* existing
display - not just the main one, or it lands on top of an attached monitor.

### Why a dependency-free HTTP and WebSocket server
Two endpoints and one push stream. Network.framework covers it in a few hundred
lines; adding a package would grow build time and supply-chain surface for
nothing. Server-to-client WebSocket frames are never masked, which removes the
fiddliest half of RFC 6455. Client frames are masked and are parsed properly,
because they now carry touch coordinates rather than a single "resync" byte.

### Why backpressure matters, and why it differs per stream
An old iPad cannot decode every frame produced.

- **Full frames** use latest-wins: if the previous send has not completed, the
  new frame is dropped. Without this, latency grows without bound - the most
  common mistake in an MJPEG implementation.
- **Delta updates cannot be dropped**: a missed patch leaves a stale rectangle
  on the canvas until the next keyframe. A client that falls behind is therefore
  marked desynchronised and skipped entirely until a keyframe arrives.

The hard lesson from this project is that the server cannot see the whole
picture: a browser keeps draining a socket into its own buffer, so a client that
is slow at *decoding* produces no backpressure at all. That is why the client
keeps its own queue short and asks for a resync over the open socket.

### Why `scale = 1`
Most iPads still on iOS 9-11 are not Retina, and those that are still report
1024x768 CSS pixels to Safari. Encoding 2048x1536 costs GPU on the Mac,
bandwidth on the air and decode time on the iPad, and gives nothing visible back.

### Why the host tells the client when it is locked
An iPad is only a second display while somebody is at the Mac. The client holds
the iPad's screen awake (`isIdleTimerDisabled`) so it does not go dark mid-use,
and that lock has to be released by something - otherwise the iPad has to be set
to Auto-Lock: Never, and then it sits lit up all night next to a locked Mac.

So the host watches its own state (`HostPresence`: the screen-lock distributed
notifications plus `NSWorkspace` sleep - not the screen saver and not display
sleep, because somebody watching a video on the iPad touches nothing for twenty
minutes and must not have the stream cut off) and pushes `S locked` / `S awake` to every connected client as a WebSocket *text* frame - the one thing
on that socket that is not pixels. A text frame rather than a flag inside the
frame payload for two reasons: the two protocol versions share no payload
format, and a locked Mac has stopped producing frames to piggyback on, which is
exactly when the signal has to arrive.

Locking does three more things, in the same place: capture stops (a locked Mac
that keeps streaming its screen has not really been locked), injected input is
refused, and the client blanks the last frame it was given. The virtual display
itself stays - destroying it makes macOS relocate every window on it, and a lock
must not rearrange the user's desk.

### Why there is a video file inside the web client
The native client holds the iPad awake with `isIdleTimerDisabled`. The web
client runs on an iPad 2, where that API does not exist and the Screen Wake Lock
API is seven major versions away - so the only state iOS has ever honoured is
"a video is playing". A 1.5 KB silent 16x16 clip loops for exactly as long as
frames are arriving and the Mac is unlocked, and is paused on `S locked` or a
dead socket.

Two things make it awkward, and both are visible in the page. iOS starts no
playback outside a user gesture, and a gesture does not survive the navigation
onto the page - hence the "Tap once to keep this screen awake" hint, dismissed
by the first touch, which is a touch the user was going to make anyway. And the
iPad 2's hardware decoder is the bottleneck in the real stream, which is why the
clip is one frame per second at 16x16 rather than anything more convenient.

iOS 9 does honour it: measured on the iPad 2 this client is for, the screen
stayed lit well past its two-minute Auto-Lock with nothing touching it.

## What measurement changed

Every significant decision here came from a number, and several reversed an
assumption:

| Assumption | What measurement showed |
|---|---|
| The iPad's CPU is the bottleneck | It was the link: halving bytes tripled the frame rate while throughput stayed flat |
| The IoT network was 2.4 GHz | It was 5 GHz; the real problem was both devices sharing one radio |
| Settings tuning matters most | Separating the radios beat every settings change combined |
| A frozen screen means the encoder stopped | The encoder produced 222 frames while the client received 0 - a latch had deadlocked |
| Client-side `onload` counts frames | It fires once for a multipart stream; the counter was measuring nothing |

## If the iPad were newer

On iOS 15+ the architecture improves considerably: VideoToolbox hardware H.264
or HEVC decode, roughly a tenth of the bandwidth again, a wired connection over
USB (usbmuxd), and a native back channel for input. The virtual display and
capture layers stay exactly as they are; only the encoder and the transport
change.
