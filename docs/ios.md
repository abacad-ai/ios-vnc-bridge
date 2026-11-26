# iPhone and iPad setup

An iPhone or iPad has no VNC server and cannot run one without a jailbreak.
iOS VNC Bridge gives it one anyway: a menu-bar app on a Mac the device is
paired to turns Apple's developer screen stream into a standard RFB endpoint,
and the hub treats that endpoint like any other VNC server.

```
iPhone / iPad ──USB──▶ Mac running iOS VNC Bridge ──RFB :5970──▶ abacad ──▶ browser
```

## Before the first start

On the Mac:

- macOS 26+, **Xcode 27** installed and opened once.
- The device **paired and trusted**, **Developer Mode** enabled in
  Settings → Privacy & Security → Developer Mode, then rebooted once.
- The device **unlocked** when the bridge starts.

On the device: nothing to install.

## Start serving

1. Open **iOS VNC Bridge** (menu bar icon).
2. The first run offers **Install device runtime** — this creates a private
   Python environment and installs `pymobiledevice3` (one network download).
3. Pick the device, keep **USB**, press **Start**.
   The first frame takes 15–30 s: tunnel, video stream, keyframe.
4. The pill turns **Live**. Copy the address and password.

## Add it to the hub

Click **Add device** and fill in:

- **Name:** `iphone` or `ipad`
- **Host:** the Mac's LAN address, shown in the app
- **Port:** `5970`
- **Sign-in → VNC password:** the password from the app
- **Platform:** iOS or iPadOS
- **Mode:** Gateway

Agents reach it through the hub's `/ws/vnc/<id>` like any other device.

## Wi-Fi

USB is the default because it cannot be flaky. To use the network:

```bash
pymobiledevice3 lockdown wifi-connections on   # once, with the cable in
```

Then switch the app's connection to **Wi-Fi** and start. Pairing always needs
the cable; renaming the device or resetting its trust requires pairing again.

## Troubleshooting

- **No device in the list** — unlock the device, tap **Trust**, and use
  **Refresh devices**. A device that is only on Wi-Fi shows up only after
  "connect over network" has been enabled once.
- **Start fails immediately** — the log in the app names the failing stage.
  Most often it is Developer Mode off, or Xcode never opened on this Mac.
- **"Device session ended"** — the cable was pulled, the device locked, or the
  tunnel dropped. The app rebuilds the session; viewers reconnect when a fresh
  frame arrives.
- **First frame is slow** — expected (15–30 s); a quiet screen afterwards sends
  almost no data, so an idle bridge looks idle.

## Limits

- **No typing.** Tap, drag and swipe work; there is no keyboard path yet.
- **No pinch / multi-touch.**
- **Rotation is not handled yet** — start the device in the orientation you
  want to view. iPad landscape is the first thing being fixed.
- **Protected video renders black**, as in any screen recording.

## Security

Driving a device through **Developer Mode** makes the Mac a privileged host:
anyone who can reach the RFB port can control the device. The app always sets a
password (generated once, kept in a `0600` file in Application Support, passed
to the engine over a pipe rather than argv) and binds to the LAN. Keep the port
on a trusted network and treat the Mac accordingly.
