# iPhone/iPad screen sharing (view only)

Status: in progress on branch `ios-screen-share`. Builds in CI; **not yet tested on a real device**.

The person on the iPhone/iPad starts a ReplayKit broadcast from the Remotless app, reads out
their ID and one-time password, and a technician on the Windows or Mac Remotless app watches
their screen live. There is no remote control: iOS has no API that lets an app inject touches
or keys into other apps, so AnyDesk and TeamViewer are view-only on iOS too.

## What exists already

- **Android** (`flutter/lib/mobile/pages/server_page.dart`, only added to the tabs when
  `isAndroid` in `home_page.dart`): MediaProjection frames go over JNI into
  `scrap::android::ffi` (`VIDEO_RAW`), `scrap::common::android::Capturer` reads them, and the
  normal `video_service` encodes them. The Rust server, the rendezvous mediator and the
  connection manager (`ui_cm_interface::start_listen` + Flutter's `FlutterHandler`) all run in
  the app process. The accept window shows the scam-shield badge
  (`flutter/lib/common/widgets/remotless_peer_badge.dart`, asks `/api/peer-check`).
- **iOS** (before this branch): client only. `src/lib.rs` compiled out `server`,
  `rendezvous_mediator` and `ipc` on iOS, `scrap` had no iOS capturer, and the Flutter app had
  no Share screen tab. Upstream RustDesk has never shipped iOS hosting; its server code still
  carries some `target_os = "ios"` branches from an earlier attempt (e.g. `KeyEvent` ignored,
  `start_server(_)` for mobile), which this branch builds on.

## How iOS lets an app share its screen

Only a **Broadcast Upload Extension** (ReplayKit, `RPBroadcastSampleHandler`) receives the
frames of the whole screen, including other apps. The user starts it from
`RPSystemBroadcastPickerView` (a system button and sheet) or Control Center. Limits:

- The extension is a separate process with roughly **50 MB of memory**; above that iOS kills it
  and the broadcast stops.
- The **main app is suspended** a few seconds after the user leaves it. The extension keeps
  running for as long as the broadcast does.
- Frames arrive as `CMSampleBuffer`s with a full-resolution 420f (NV12) pixel buffer, up to
  60 per second, plus an orientation attachment.
- iOS 27 adds a ScreenCaptureKit path and deprecates the ReplayKit broadcast APIs (per a third-party guide; not yet checked against Apple's documentation);
  deprecated APIs keep working, and the extension stays the only option for iOS 15-26. Revisit
  when the deployment target moves past iOS 26.

## Design

### Where the Remotless server runs: in the extension

Options considered:

1. **Server in the main app, frames from the extension through the App Group** (shared
   memory file + Darwin notifications). Simple for frames, but the main app is suspended
   seconds after the user switches to the app they need help with, which drops the session.
   Keeping it alive needs a background mode Apple only allows for its real purpose (silent
   audio playback, VoIP): App Review rejects that.
2. **Server in the extension** (what TeamViewer QuickSupport and AnyDesk do). The extension
   lives exactly as long as the broadcast, so the session survives the user leaving the app.
   Costs: the Rust library is linked into the extension too (bigger download), and everything
   must fit in ~50 MB.

We use **option 2**. The extension links the same `liblibrustdesk.a` as the app and calls
`src/ios_broadcast.rs`:

| C function | When |
| --- | --- |
| `remotless_bc_start(dir, share_json, callback)` | `broadcastStarted`: sets `APP_DIR` to the extension's folder in the App Group, applies the share settings, runs `start_server(true)` (rendezvous mediator + connections) on a thread |
| `remotless_bc_push_frame(bgra, len, w, h, stride)` | each kept frame |
| `remotless_bc_authorize(conn_id, accept)` | the user's answer from the app |
| `remotless_bc_disconnect_all()` | "Stop" for the technician |
| `remotless_bc_stop()` | `broadcastFinished` |

`callback` receives JSON events (`started`, `add_connection`, `remove_connection`, `stopped`,
`error`) from an in-process connection manager (`IosHandler`, the iOS counterpart of Android's
`FlutterHandler`; it reuses `ui_cm_interface::start_listen`).

### Frames: scaled and converted in the extension, encoded in Rust

- The extension keeps at most **15 frames per second** and drops the rest.
- It scales with vImage **before** converting: the Y plane and the CbCr plane are scaled
  separately (`vImageScale_Planar8` / `vImageScale_CbCr8`) to fit **1280 px on the long side**,
  then the small NV12 image is converted to BGRA (`vImageConvert_420Yp8_CbCr8ToARGB8888`) and
  rotated if the phone is in landscape. All buffers are allocated once (~6 MB in total); no
  full-resolution RGB copy is ever made.
- `scrap::ios` (`libs/scrap/src/common/ios.rs`) keeps the newest frame; its `Capturer` hands it
  to the normal `video_service`, which converts BGRA to I420 with libyuv and encodes with the
  software VP9/VP8 encoder (libvpx), as for any other host. A size change (rotation) makes the
  capturer fail once, and the video service restarts it with the new size.
- Encoding in the extension rather than the app is forced by option 2. Hardware H.264/H.265 via
  VideoToolbox would use less CPU and memory; it can be added later through `hwcodec` if VP9 at
  1280 px turns out too slow or too big.

Memory estimate (to be measured on a device): Swift + ReplayKit ~8 MB, Rust runtime and
networking ~5-8 MB, frame buffers ~10 MB, libvpx at 1280x590 ~10-15 MB. Under 50 MB, with
margin. If a device gets killed, lower the long side to 960 px (`maxLongSide` in
`SampleHandler.swift`).

### App and extension talk through the App Group

App Group `group.com.remotless.app`, folder `share/` in its container:

| File | Written by | Read by | Content |
| --- | --- | --- | --- |
| `share.json` | app | extension (at start, and on `share.config`) | Remotless ID, one-time password, device name, server options |
| `state.json` | extension | app | `sharing`, the ID actually registered, the technicians (`clients`), `updated` |
| `command.json` | app | extension | `{"seq", "cmd": "authorize" / "deny" / "disconnect" / "stop", "id"}` |
| `ext/` | extension | extension | its own Remotless config (keys, options), as `APP_DIR` |

Darwin notifications (no payload, `CFNotificationCenterGetDarwinNotifyCenter`) say that a file
changed: `com.remotless.app.share.state` (extension to app), `com.remotless.app.share.command`
and `com.remotless.app.share.config` (app to extension). The app also re-reads `state.json`
whenever it comes back to the foreground, because a suspended app misses notifications.

### Who the technician is: ID, password, accept/deny, scam shield

- The extension registers **the app's own Remotless ID** (`share.json`), so the user reads out
  the number the app shows. It has its own key pair (in `ext/`). If the server ever refuses
  the ID, the mediator picks a new one and the app shows the ID from `state.json`.
- The Share screen tab makes a **new one-time password** each time it opens and whenever the
  user taps refresh. A technician who types it gets in right away (as on Android).
- A technician who connects **without** the password needs the user's OK: the extension
  writes the request to `state.json`; the app (in the foreground) shows the accept/deny sheet
  with the **scam-shield badge** (`RemotlessPeerBadge`, same as Android and Windows). If the app
  is in the background, the extension posts a local notification ("… wants to see your
  screen"); tapping it opens the app with the sheet. No answer within 60 s: denied.
- Everything except watching is switched off in the extension's config (keyboard/mouse,
  clipboard, files, audio, TCP tunnels, restart, recording, block input, privacy mode, camera,
  terminal, remote settings), so the technician's app shows those as unavailable.
- The technician's toolbar shows a blue **View only** badge for iOS peers and hides the
  keyboard menu (`flutter/lib/desktop/widgets/remote_toolbar.dart`).

### Stopping

The user stops from the red status bar / Control Center, or with "Stop sharing" in the app.
iOS gives apps no API to end a broadcast, so the app sends `stop` and the extension calls
`finishBroadcastWithError` itself. `broadcastFinished` closes the sessions and stops answering
the rendezvous server.

## Signing and build

- New target `RemotlessBroadcast` (`flutter/ios/RemotlessBroadcast/`), bundle ID
  `com.remotless.app.broadcast`, embedded in `Runner.app/PlugIns`.
- Both targets get the App Group entitlement `group.com.remotless.app`.
- Apple side (Team K42MDMGU82): App Group, second App ID, second App Store profile; the app's
  profile must be regenerated after the App Group is added to `com.remotless.app`. The exact
  steps and GitHub secrets are in `.github/workflows/remotless-ios.yml` and in the hand-over
  notes.
- `.github/workflows/remotless-ios-check.yml` is a quick `cargo check` for iOS used while
  porting; `remotless-ios.yml` builds the whole app (unsigned with `sign: false`).

## Not done / open

- Not run on a real iPhone/iPad yet: memory under 50 MB, frame rate, rotation, background
  behaviour, local notifications from the extension and the relay path are all untested.
- No audio sharing (ReplayKit offers app/mic audio; Remotless iOS sharing is video only).
- One technician at a time is what we test; several work in theory (same as Android).
- Chat from the technician arrives as an event but is not shown in the app yet.
