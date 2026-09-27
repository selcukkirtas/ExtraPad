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
