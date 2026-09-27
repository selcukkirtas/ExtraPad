# Plan: App Store distribution, a native iPad app, and discovery

Status: Phase A complete, Phase B minimum viable running in the Simulator.

## Decisions

| Question | Answer |
|---|---|
| Mac distribution | Direct download, Developer ID signed and notarized |
| Pricing | iPad app paid once; Mac host free |
| Developer Program | Not yet purchased - blocks only notarization and submission |
| Native client floor | iOS 15 |
| Starting point | Phase A |

Individual vs Organization membership is still open and worth deciding before
purchase: Organization sells under a company name but needs a D-U-N-S number and
can take weeks; Individual is approved in a day or two but shows a personal name
as the seller. Changing it later is painful.

## 1. The blocker to settle first

**The Mac app cannot ship on the Mac App Store.** Three independent reasons,
each sufficient on its own:

| Reason | Detail |
|---|---|
| Private API | The virtual display needs `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings`. App Review rejects private API use, and there is no public replacement - Apple ships no API for adding a display. |
| Sandbox | Mac App Store apps must be sandboxed. Creating a display and posting system-wide input are outside what the sandbox grants. |
| Accessibility | Touch input posts `CGEvent`s to other applications, which needs Accessibility permission. A sandboxed App Store app cannot obtain it. |

Dropping to a Mac App Store-eligible feature set would mean: mirroring only, no
second display, no input. That is not this product.

**So the shape is:**

- **iPad app → iOS App Store.** Normal review, normal distribution.
- **Mac app → direct download, Developer ID signed and notarized.** This is what
  Duet Display, Luna Display and BetterDisplay all do, for exactly these reasons.

This is not a workaround; it is the standard distribution route for this class
of app. But it must be decided now, because it changes the signing setup, the
update mechanism and the support burden.

## 2. Device coverage: "all iPads" needs two clients, not one

This Xcode reports `MinimumDeploymentTarget = 15.0`. A native app therefore
covers **iOS 15 and later**: iPad 5th gen (2017) and later, iPad Air 2 and later,
iPad mini 4 and later, every iPad Pro.

It does **not** cover the iPad 2 this project was built for. There is no way to
make it - the toolchain cannot produce a binary that old device will load.

So both clients stay, permanently:

| Client | Devices | How it arrives |
|---|---|---|
| **Native iPad app** | iOS 15+ | App Store |
| **Web client** (today's code) | anything with Safari, including iOS 9 | already there, nothing to install |

Keeping the web client is not a compromise. It is the only thing that makes
"works on all iPads" true, it needs no App Store review to change, and it stays
the fallback when the native app misbehaves.

## 3. Discovery: how the iPad finds the Mac

Today the address is typed. For the native app:

1. The Mac advertises a Bonjour service. The listener already sets a service -
   it should move from the generic `_http._tcp` to a dedicated
   `_extrapad._tcp`, with a TXT record carrying the host name, protocol version
   and whether pairing is required.
2. The iPad app browses with `NWBrowser` and lists the Macs it finds by name.
3. The user taps one and enters the six-digit code already implemented.
4. On success the app stores a long-lived key in the Keychain and reconnects
   automatically afterwards - the code is entered once per device.

Requirements: `NSLocalNetworkUsageDescription` and `NSBonjourServices` in the
iPad app's Info.plist, plus the user granting Local Network permission on first
launch. On iOS this permission is mandatory and cannot be worked around.

The web client cannot browse Bonjour - a web page has no such API - so it keeps
the typed address. `macbook-pro.local:8777` works there via mDNS resolution.

## 4. What a native client unlocks

Worth doing, in rough order of value:

| Change | Why it needs a native app | Expected effect |
|---|---|---|
| **H.264/HEVC via VideoToolbox** | Safari on old iOS has no MSE; a native app decodes in hardware | Another large drop in bandwidth; makes Retina resolutions practical |
| **Retina resolution** | Bandwidth budget allows it once video coding lands | A 2048x1536 second display instead of 1024x768 |
| **Wired USB** | Safari cannot reach the Mac over USB; a native app can use usbmuxd | Lower, steadier latency, no Wi-Fi dependence |
| **Pencil and multi-touch** | Raw touch data is unavailable to a web page at useful fidelity | Pressure, tilt, gestures |
| **TLS with a pinned certificate** | Safari on iOS 9 makes self-signed certs impractical; a native client can pin at pairing time | Closes the "traffic is readable" hole honestly |

## 4b. Pairing without a code, via iCloud

Worth recording why the obvious idea does not work and what replaces it.

**Asking for the iCloud password is not an option.** Apple exposes no API for a
third-party app to verify an Apple ID password - there is nothing to check it
against. Beyond that, a field labelled "iCloud password" in a third-party app is
the shape of a phishing attack: App Review rejects it, and it teaches users to
type their Apple ID password into arbitrary software. Guarding a LAN screen
share with the credential that protects the user's entire account is the wrong
way round, and today that password would cross the network in the clear.

**What does work, once a native client exists:** prove that both devices are
signed into the same Apple ID by using the user's own private CloudKit database.

1. The iPad writes a short-lived pairing record into its **private** CloudKit
   database in our container.
2. The Mac tries to read that record from the same private database.
3. If it can, the two devices are on the same Apple ID - nobody else can write
   to or read that database.

This is a real proof rather than a claim. An iPad simply *asserting* an account
identifier would be forgeable; the write-then-read handshake is not.

Cost, stated plainly: CloudKit needs a paid membership, pairing needs the
internet at that moment, and it fails when the Mac and the iPad are on different
Apple IDs.

So the six-digit code stays as the fallback and remains the only path for
offline use, mixed accounts, and the web client on old iPads. iCloud pairing is
a convenience layer on top, not a replacement.

Slot this into Phase C, after the native client exists and a membership is in
place.

## 5. Security, revisited for a shipping product

The current model - shared secret over plain HTTP - is documented honestly as
LAN-only. For something distributed publicly that is not enough, because users
will run it on office and hotel networks regardless of what the README says.

Plan for the native path:

- Generate a self-signed certificate on the Mac at first launch, stored in the
  Keychain.
- During pairing, the iPad app pins that certificate's fingerprint alongside the
  key it receives.
- All later connections are TLS with the pinned certificate. No CA, no trust
  prompts, and a network attacker sees nothing useful.

The web client keeps plain HTTP with the current warnings. That asymmetry is
fine and should be stated in the UI, not buried in a README: the app can tell
the user which mode they are in.

## 6. Refactor so nothing that works today breaks

The current code is one executable. The work splits it without changing
behaviour:

```
ExtraPadCore      (shared)   capture, virtual display, delta encoder,
                             auth, device registry, input injection
ExtraPadHost      (macOS)    menu bar app, HTTP + WebSocket server,
                             Bonjour advertising, the web client
ExtraPadProtocol  (shared)   wire format, message types, version negotiation
ExtraPadClient    (iOS)      SwiftUI app, NWBrowser discovery, decoder,
                             touch capture
```

Rules that keep the current app working throughout:

- The web client and its endpoints stay exactly as they are. The native client
  gets **new** endpoints, it does not repurpose existing ones.
- The wire format gains an explicit version byte before anything else changes,
  so an old client and a new host can still talk.
- Every phase ends with the current setup still working on the iPad 2. That is
  the regression test - it exercises the oldest, least forgiving path.

## 7. App Store submission checklist (iPad app)

Beyond the code:

- Apple Developer Program membership, $99/year. Required for both the App Store
  and for Developer ID notarization of the Mac app.
- App name availability - "ExtraPad" needs checking against existing App Store
  names and trademarks.
- Privacy manifest (`PrivacyInfo.xcprivacy`) - now mandatory. This app collects
  nothing, which must still be declared explicitly.
- Privacy policy URL and support URL. Both required, both must be live pages.
- Screenshots for every required device class, app icon, description, keywords.
- Export compliance - adding TLS means answering the encryption questions;
  standard use of platform crypto is normally exempt, but it must be declared.
- Age rating questionnaire.

**The review risk worth planning for:** the reviewer needs a Mac running the
host app to test the iPad app at all. This has to be handled deliberately -
review notes with a download link to the notarized Mac app, clear pairing
instructions, and ideally a demo mode in the iPad app that renders a canned
screen so the app is not simply dead on arrival if the reviewer cannot set up a
Mac. Apps in this category get rejected for "cannot review functionality" more
often than for anything technical.

Precedent is good: Duet Display, Luna Display and Jump Desktop all ship an App
Store client paired with a separately distributed Mac host.

## 8. Phasing

Each phase is independently useful and leaves a working product.

**Phase A - Mac host, distributable.** Developer ID signing and notarization in
`build-app.sh`, a versioned wire protocol, `_extrapad._tcp` advertising with a
TXT record, an update check. No iPad work. Outcome: the current app becomes
something other people can install.

**Phase B - Native iPad client, minimum viable.** Discovery, pairing with the
existing six-digit code, and the existing delta-JPEG stream reused as-is.
Deliberately no new codec yet: this proves discovery, pairing, and the native
rendering path against a transport already known to work.

**Phase C - Video codec and TLS.** H.264/HEVC through VideoToolbox, Retina
resolutions, self-signed TLS with pinning. This is where the native app becomes
clearly better than the web client rather than merely native.

**Phase D - App Store submission.** Privacy manifest, metadata, screenshots,
review notes, demo mode. Submit.

**Phase E - The rest.** Wired USB, Pencil input, multiple independent displays.

## 9. Phase A breakdown

| Step | Needs membership | State |
|---|---|---|
| A1 - Protocol version and stale-client recovery | no | done |
| A2 - `_extrapad._tcp` advertising with a TXT record | no | done |
| A3 - Notarization wired into the build script | written now, runs later | done |
| A4 - Split into shared modules | no | done |

All four are done. Phase B's first milestone is also running: the native client
discovers hosts, pairs with the six-digit code, streams and renders, verified in
the Simulator against the live host.

Still to do in Phase B: touch input exercised on a real device (the Simulator
offers no way to tap from a script, so only the coordinate mapping is covered -
by tests), reconnect handling, and remembering a paired host in the Keychain.

A4 is the largest and the one that enables Phase B, so it is deliberately last:
each earlier step is small enough to verify on its own, and the old iPad has to
keep working after every one of them.
