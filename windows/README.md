# ExtraPad for Windows (v1 - mirror mode)

A first, testable slice of the Windows host. It speaks the exact same wire
protocol as the Mac host's atlas/JPEG dialect (protocol 1), so the existing
iPad web client (Safari, `/delta`) connects to it unmodified - no changes
needed on the iPad side.

## What this v1 does and does not do

- **Does**: mirrors the PC's primary display (like the Mac host does when
  `EPVirtualDisplay` isn't available), streams it as JPEG over a WebSocket,
  accepts touch input back as mouse movement/clicks, shows a tray icon with
  the address + 6-digit pairing code, pauses the stream when the PC locks.
- **Does not yet**: create a *separate* virtual display (that's the next
  phase - see below), do per-device "Allow/Deny" approval (anyone with the
  key or pairing code gets straight in), do dirty-rect diffing (every frame
  is sent as a full keyframe, so bandwidth is higher than the Mac host until
  this is added), advertise itself over Bonjour (type the address into
  Safari directly, same as the Mac host's documented fallback).

## Build & run

Needs the [.NET 8 SDK](https://dotnet.microsoft.com/download) on the Windows
machine.

```
cd windows\ExtraPadWindows
dotnet run
```

A tray icon should appear. Right-click it for the address to type into
Safari on the iPad, and the pairing code. Open that address on the iPad,
enter the code once, and the PC's screen should start streaming.

## What to check and report back

1. Does `dotnet run` build and launch cleanly? Any errors, paste them as-is.
2. Does the tray icon show up with a real LAN address (not just
   `127.0.0.1`)?
3. Does the iPad's Safari actually connect at that address and show the
   screen?
4. Does touching the iPad move the Windows mouse cursor?
5. Does locking the PC (Win+L) blank the iPad's view, and does unlocking
   bring it back?

## Next phase: a real virtual display

For an actual second screen (not a mirror), the plan is to bundle the
open-source, already code-signed **Virtual Display Driver**
(https://github.com/VirtualDrivers/Virtual-Display-Driver) - no
test-signing/driver-signing hassle on your machine, since it ships
pre-signed via SignPath. Once v1 above is confirmed working end to end, the
next step is installing VDD on your test machine and wiring this host up to
add/resize a virtual monitor through it instead of mirroring the primary
display - I'll need to see its actual runtime control surface on your
machine to nail that down precisely (its docs describe an XML settings file
rather than a documented live API, so this needs a look at the real thing).
