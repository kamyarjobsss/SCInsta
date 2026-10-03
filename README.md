# Instagram X
A rebranded, stability-focused fork of [SCInsta](https://github.com/SoCuul/SCInsta) v1.1.1 for Instagram on iOS.\
`Version v1.2.0` | `Tested target: Instagram 418.2.0` | `Package: com.kamyar.instagramx`

The injected library is still named `SCInsta.dylib` so the existing sideload tooling keeps finding it. Everything the tweak shows the user is labeled **Instagram X**.

Install steps for a Mac and an iPhone are in [INSTALL.md](INSTALL.md) (English and Persian).

---

## What this release adds

- **Instagram X settings** inside Instagram's own Settings screen, directly under the Accounts Center row, with the holographic icon and a moving gradient border. Existing shortcuts still work: hold the profile menu button, or hold the home tab when that shortcut is on.
- **In-app VLESS proxy.** Paste one or more `vless://` links, pick one, test TCP latency, and turn it on. Traffic is handled inside the Instagram process. There is no Network Extension and no system VPN profile.
- **Fake location.** A MapKit map inside the tweak. Drop a pin or search, then enable it. Optional matching timezone and locale.
- **Stability fixes** from an audit of v1.1.1 (see below).

The bundle id stays `com.burbn.instagram` unless you set `IX_BUNDLE_ID` for a sideload build. That option installs Instagram X next to the App Store app.

## VPN: what is covered

When the proxy is connected, this process does the following:

| Path | Behavior |
| --- | --- |
| `connect` / `connectx` (TCP) | Redirected through a local SOCKS5 listener (`127.0.0.1:61850`) after a SOCKS5 handshake. Covers CFNetwork, BSD sockets, and Instagram stacks that dial with `connect`, including Liger/Tigon and MQTT when they use those calls. |
| `NSURLSession` | `connectionProxyDictionary` is forced to the local HTTP proxy (`127.0.0.1:61851`), so HTTPS uses CONNECT to localhost and the session itself does not open a direct socket. |
| DNS (`getaddrinfo`, `gethostbyname`) | Non-numeric destinations are replaced with a fake `240.0.0.0/4` address. The SOCKS handshake sends the original hostname, and the remote server resolves it. IPv6 lookups return "no name" so clients retry IPv4. |
| UDP, including calls | Blocked (`EPERM`) while "Block UDP and calls" is on (the default). Call buttons show an alert instead of starting WebRTC. UDP is not relayed. |
| Kill switch | Default on. If the local proxy is not up, outbound TCP returns "network unreachable" instead of connecting directly. |

The engine is [Xray-core](https://github.com/xtls/xray-core) `v1.260327.0`, built on the macOS CI runner as an iOS arm64 static library and linked into the tweak. REALITY, xtls-rprx-vision, gRPC, XHTTP, and HTTP/2 are handled by that library. If Xray is not linked (a Linux build, or Xray failed to start on a simple TCP/TLS/WebSocket link), a built-in engine speaks VLESS over TCP, TLS, and WebSocket only.

### Known limitations (not verified on a device)

These are real gaps. Do not treat the VPN as a complete IP-hiding system until you have checked it on your phone.

- **Not tested on a device.** The Go runtime inside an injected dylib, the socket hooks, and Xray startup can fail or crash on a real iPhone even when CI links successfully.
- **WKWebView** runs networking in another process. In-process `connect` hooks do not see it. The iOS 17 proxy setter is only logged; no proxy object is installed.
- **AVPlayer / mediaserverd** can fetch media outside this process. Those bytes never enter the hooks.
- **Network.framework** paths that do not call `connect` or `connectx` are not redirected.
- **UDP is blocked, not tunneled.** A half-finished UDP relay would leak, so it is not implemented. SDP can still contain local addresses if a call is started with UDP blocking turned off.
- **IPv6 sockets** are sent to `::ffff:127.0.0.1`. If that mapped address cannot connect, the call fails closed.
- **One DNS lookup of the proxy hostname** is required so Xray (or the built-in engine) can dial the server. Destination names are not resolved locally by the hooks. If Xray resolves a destination itself despite `domainStrategy: AsIs`, that lookup is outside these hooks.
- **Caller detection** skips the hooks when the return address belongs to an image whose path contains `SCInsta` or `InstagramX`. If the injected image is renamed, the engine could loop or the bypass could miss.
- **Latency test** is a TCP handshake to the server, not a VLESS login.
- **No system VPN.** A free sideload certificate cannot use NetworkExtension. Traffic from other apps is unchanged.

## Fake location

While the toggle is on, `CLLocationManager` reports the saved coordinate (location, authorization, accuracy, updates, significant-change, and heading start/stop). Delegate callbacks receive that coordinate. `MKMapView` inside Instagram is not the picker map; the picker turns off its own user-location dot while spoofing so the pin stays where you dropped it.

`CLLocation.coordinate` is not hooked globally, so the map pin is not rewritten. `CLGeocoder` is not hooked either: Instagram reverse-geocodes the coordinate it was given, which is already the fake one.

Matching timezone and locale are off unless you enable them. They hook `NSTimeZone` local/system and `NSLocale` current/autoupdating. Locale spoofing can change dates and text; turn it off if Instagram looks wrong.

If an Instagram class named `IGLocationManager` exists and its `location` / `currentLocation` methods return an object, those are hooked too. A missing class is ignored.

## Stability fixes

- Hide Meta AI's "Click to summarize" pill now checks `hide_meta_ai` before returning nil.
- Cache cleanup no longer deletes `tmp`. It skips files modified in the last 10 minutes and ignores per-item errors.
- Story likes are covered by a persistent overlay and a story-footer `sendAction:` gate, not a one-shot view.
- A voice-message long-press no longer ends the gesture (and sends) until you confirm.
- `EnableHomecomingUI.x_` and `EnableAllTextEffects.xm_` stay uncompiled. The text-effect file expands animation indexes past the range Instagram ships and can crash story editing.

New hooks check for a missing class or a failed lookup before calling into Instagram.

## Existing SCInsta features

### General
- Hide ads
- Hide Meta AI
- Copy description
- Do not save recent searches
- Use detailed (native) color picker
- Enable liquid glass buttons
- Enable teen app icons
- IG Notes: hide notes tray, hide friends map, note theming, custom note themes
- Focus: no suggested users, no suggested chats, hide trending searches, hide explore posts grid

### Feed
- Hide stories tray, hide the feed, no suggested posts, no suggested accounts, no suggested reels, no suggested Threads posts, disable video autoplay

### Reels
- Tap controls, progress scrubber, disable auto-unmuting, confirm reel refresh, hide header, hide blend button, disable scrolling, doom-scroll limit

### Saving
- Download feed posts, reels, and stories; save profile picture; custom long-press fingers and duration

### Stories and messages
- Keep deleted messages, mark messages seen, disable typing status, unlimited direct-story replay, disable view-once, disable screenshot detection, disable story seen receipt, disable instants creation

### Navigation
- Tab icon order, swipe between tabs, hide feed / explore / reels / create

### Confirm actions
- Like (posts, stories, reels), follow, repost, call, voice message, follow requests, shh mode, comment, DM theme, sticker interaction

## Building

macOS, Xcode command-line tools, Homebrew, [Theos](https://theos.dev/docs/installation), and the iOS 16.2 SDK in `$THEOS/sdks`. Sideload builds also need [cyan](https://github.com/asdfzxcvbn/pyzule-rw) and [ipapatch](https://github.com/asdfzxcvbn/ipapatch/releases/latest). The Xray static library needs Go 1.26 or newer and is built only on macOS.

```sh
git clone --recurse-submodules https://github.com/kamyarjobsss/SCInsta
cd SCInsta
chmod +x build.sh scripts/build_ixray.sh
./build.sh rootless          # jailbreak / rootless .deb
./build.sh rootful           # rootful .deb
# Sideload: put your decrypted IPA at packages/com.burbn.instagram.ipa first.
IX_BUNDLE_ID=com.example.instagramx ./build.sh sideload
```

GitHub Actions (macOS, iOS 16.2 SDK, Logos pinned to `a623700`) builds the rootless deb on pull requests. The sideload IPA workflow is `workflow_dispatch` and needs a decrypted IPA URL you supply. See [INSTALL.md](INSTALL.md).

## Credits
- [@SoCuul](https://github.com/SoCuul) for SCInsta. Instagram X is a fork of that project.
- [@BandarHL](https://github.com/BandarHL) for BHInstagram, which SCInsta is based on.
- [Xray-core](https://github.com/xtls/xray-core) and [libXray](https://github.com/XTLS/libXray) for the in-process proxy engine.
