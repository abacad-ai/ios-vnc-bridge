# iOS VNC Bridge

A macOS menu-bar app that turns a **paired iPhone or iPad into a standard VNC
(RFB) server**. No app on the device, no jailbreak, no cloud, no terminal.

```
 iPhone / iPad ──USB or Wi-Fi──▶  iOS VNC Bridge (this Mac)  ──RFB :5970──▶  abacad
                                                                          macOS Screen Sharing
                                                                          TigerVNC / noVNC
```

It is the device-facing companion for [abacad](https://github.com/abacad-ai/abacad),
but it speaks plain RFB, so any VNC client can connect to it directly.

## What it does

| | |
|---|---|
| Frame rate | 25–40 fps while the screen changes |
| Frame size | ~700 px wide (Tight/JPEG, a few tens of KB per frame) |
| Input | tap, drag and swipe — a press shorter than 80 ms is ignored by iOS, the bridge enforces the dwell |
| Keep-awake | a power assertion on the device, renewed every 2 minutes |
| Recovery | the device session is rebuilt after a dropped tunnel or a wedged process; viewers are disconnected rather than shown a frozen picture |
| Connection | USB by default; Wi-Fi once the device is set to "connect over network" |

## Requirements

- **macOS 26 or later** (Apple Silicon).
- **Xcode 27**, installed and opened once (the device stream comes from Apple's
  CoreDevice developer services, the same ones Xcode's device window uses).
- **iPhone or iPad on iOS/iPadOS 27+**, with **Developer Mode** enabled,
  **paired and trusted**, and **unlocked** when you start the session.
- **Python 3.9+** — Xcode's toolchain is enough; Homebrew `python3` also works.
  The app installs `pymobiledevice3` into its own environment on first run.

## Install

1. Download the DMG from [Releases](https://github.com/abacad-ai/ios-vnc-bridge/releases)
   and drag **iOS VNC Bridge** into `/Applications`.
2. Launch it. Release builds are ad-hoc signed for now, so Gatekeeper asks once:
   right-click → **Open**.
3. The app lives in the menu bar (no Dock icon, no window).

## First run

1. **Install device runtime** — one network download (it creates a private
   Python environment in `~/Library/Application Support/ios-vnc-bridge`).
2. Pick the **device** and the **connection** (USB / Wi-Fi), then **Start**.
   The first frame takes 15–30 s: tunnel, video stream, keyframe.
3. With **Start when a device is found** on (the default), the app serves as
   soon as a device is visible — opening the app is enough.
4. When the pill says **Live**, copy the address and the password into abacad:
   **Host** the Mac's LAN address, **Port** `5970`, **Sign-in → VNC password**,
   **Platform** iOS/iPadOS, **Mode** Gateway.

The password is generated on first launch and always required; see
[Security](#security).

## Limits, honestly

- **No typing.** Tap, drag and swipe work; there is no keyboard path yet.
- **No pinch or multi-touch.** One contact at a time.
- **Rotation is not handled yet.** The bridge streams the device's main display
  in its native orientation and does not follow rotation. An iPad held in
  landscape when you press Start will most likely come out sideways, and
  rotating mid-session leaves the viewer stretched until it reconnects. This is
  the next thing on the list (iPhone landscape has the same gap).
- **Protected video renders black**, as it does in any screen recording.
- The device must stay reachable. Pulling the cable ends the session; the app
  rebuilds it within a few seconds and disconnects viewers in the meantime.
- Wi-Fi works only after the device has been paired for the network once
  ("Connect to this iPhone over network", with the cable in).

## How it works

The menu-bar app is a supervisor, not a VNC implementation. It launches two
helpers and shows their state:

```
iOS VNC Bridge.app (SwiftUI, menu bar)
   ├── engine           (Go)     RFB framing, encodings, scaling, auth
   └── bridge/iosbridge.py (Python, pymobiledevice3)
          └── CoreDevice: HEVC stream, HID touch, keep-awake
```

The split is deliberate. iOS only delivers HID reports from a process that
holds a display stream, and the digitizer surface is matched asynchronously
*after* that stream settles — splitting stream and input across processes
produces input that works intermittently. So one process owns the whole device
session (Python, where pymobiledevice3 lives), and everything commodity and
stable stays in Go.

The engine's log is the app's status channel: `listening on`, `viewer …
connected`, `device session …` are a stable contract between the two halves.

## Development

```bash
make test    # go test ./... + swift build
make run     # run the app from the checkout (engine in build/, bridge in bridge/)
make app     # build "iOS VNC Bridge.app" (ad-hoc signed) into build/
make dmg     # + a DMG
```

Signing for distribution:

```bash
CODESIGN_ID="Developer ID Application: …" DMG=1 NOTARIZE=1 \
  NOTARY_PROFILE=ac-notary make app
```

Layout: `app/` (SwiftUI), `cmd/engine` + `internal/` (Go), `bridge/`
(Python device bridge), `packaging/` (Info.plist), `docs/`.

## Security

- The VNC password is generated on first launch and required by the engine;
  there is no unauthenticated mode.
- It lives in a `0600` file under `~/Library/Application Support/ios-vnc-bridge`,
  **not the keychain**: every ad-hoc-signed rebuild changes the app's code
  identity, and a keychain ACL then blocks `SecItemCopyMatching` behind a
  password prompt the app cannot show before its UI exists.
- It reaches the engine over a pipe, never argv, so `ps` does not show it.
- The engine binds `0.0.0.0:5970` so a hub on another machine can reach it;
  turn **Anyone on the LAN** off to keep it on loopback.
- Developer Mode makes the Mac a privileged host: whoever reaches the port can
  drive the device. Keep it on a trusted network and scope TCP 5970 to the
  hub's address in the firewall.

## License

MIT — see [LICENSE](LICENSE). At runtime the app installs
[pymobiledevice3](https://github.com/doronz88/pymobiledevice3) (GPL-3.0-or-later)
on the user's machine; it is not part of the distributed bundle. See
[NOTICE](NOTICE).
