# Serein Windows Remote Host — Stage 2 media and capability-scoped input

This is a local-only Desktop Duplication capability PoC with a Go WebRTC
bridge. It proves that the current interactive Windows session can enumerate
and capture one DXGI output, encode H.264, and feed the NAL units to a Pion
PeerConnection for remote display with an explicitly granted input channel.

Implemented:

- adapter-aware monitor enumeration;
- Desktop Duplication capture on the monitor's own D3D11 adapter;
- BGRA staging copy for PoC diagnostics;
- rotation normalization;
- aspect-fit local preview;
- `DXGI_ERROR_ACCESS_LOST` rebuild;
- first-frame, FPS, frame-count, and recovery metrics;
- headless metric mode for repeatable manual tests.
- synthetic BGRA rotation self-test that never reads desktop pixels.
- in-memory Media Foundation H.264 encode/decode self-test using generated pixels only.
- runtime `--capabilities` probe that reports monitor metadata and whether an
  H.264 MFT can actually initialize, without reading desktop pixels;
- single-instance `--service` mode with a local-only named pipe;
- fixed `PING`, `STATUS`, `CONSENT`, `GRANT`, `AUTHORIZE`, `STREAM_START`,
  `STREAM_STOP`, `END`, and `SHUTDOWN` IPC commands;
- primary-device auto-authorization through `GRANT`; the legacy `CONSENT`
  command still fails closed with a local deny-by-default dialog.
- one-time Host-ticket handoff after consent. The ticket is accepted only for
  the matching session/revision before expiry, is never included in `STATUS`,
  and is wiped from memory on replacement, expiry, end and shutdown. A native
  expiry worker removes it even if no further IPC request arrives.
- `STREAM_START` / `STREAM_STOP` IPC commands that run a capture/encode loop
  and write length-prefixed H.264 NAL units to a local named pipe
  (`\\.\pipe\serein-remote-host-stream-v1`) for the Go bridge to consume.
- Go WebRTC bridge (`bridge/serein-remote-bridge.exe`) that reads NAL units
  from the stream pipe, creates a Pion H.264 video track, and exchanges
  Offer/Answer/ICE with the controller through the backend signaling
  WebSocket using the one-time Host ticket.
- capability-scoped `serein-input` DataChannel with pointer, keyboard and text
  injection through `SendInput`; view-only sessions never create this channel.

Intentionally not implemented:

- clipboard, audio, or file transfer;
- unattended access or Windows Service installation;
- TURN relay (direct LAN P2P only at this stage);
- token, project, Agent, or approval-hook access.

## Build prerequisites

- Windows 10 or Windows 11;
- Visual Studio 2022 Build Tools;
- the `Desktop development with C++` workload;
- a Windows 10/11 SDK and CMake component;
- Go 1.22+ (optional; required for the WebRTC bridge).

Build:

```powershell
cd C:/workspace/serein\remote\windows-host
& .\build.ps1
```

The build runs `--self-test` and `--encoder-self-test` automatically. Also run
`--service-self-test` to verify strict IPC parsing. These tests
validate identity/90/180/270 degree BGRA transforms and the local Media
Foundation H.264 encoder and decoder using generated pixels. Neither reads the desktop.

If Go is installed, the build also compiles the WebRTC bridge
(`bridge/serein-remote-bridge.exe`) and runs `go vet`. If Go is absent, the
native host still builds, but the lifecycle manager will not declare the
`webrtc` transport and the phone will refuse view requests.

The optional Python lifecycle manager starts `--service` with
`CREATE_NO_WINDOW` and no shell only when `SEREIN_REMOTE_HOST_ENABLE=1`.
It is off by default. When enabled, the manager bootstraps a per-Host
operational credential, stores it with current-user Windows DPAPI, and uses it
instead of the global Hook Token for heartbeat, consent and Host session
operations. The backend keeps only a SHA-256 hash and supports explicit
credential rotation and revocation. Only a paired primary device may create a
remote session. After the user confirms on that phone, the manager records the
trusted-device decision through `GRANT` without another desktop popup, then
validates the short-lived ticket and sends it to the native process
through the owner-only pipe, starts the native stream, and launches the Go
bridge with the ticket/host-token/backend-URL passed via environment
variables. The manager monitors bridge exits and tears down both the bridge
and the native stream on session end or relay shutdown. A handoff or stream
start failure closes the local request and ends the backend session
fail-closed.

List displays:

```powershell
.\build\serein-remote-host.exe --list-monitors
```

Probe the native capture/encoder facts (no desktop pixels are read):

```powershell
.\build\serein-remote-host.exe --capabilities
```

The native probe deliberately reports no transport or input capability. The
manager separately runs `bridge\serein-remote-bridge.exe --capabilities` and
publishes `webrtc` plus `pointer`/`keyboard`/`text` only when both probes pass.
These facts are refreshed through the authenticated Host heartbeat after an
upgrade.

Open a local 15 FPS preview:

```powershell
.\build\serein-remote-host.exe --monitor 0 --fps 15
```

Capture 300 frames without a preview window and print JSON metrics:

```powershell
.\build\serein-remote-host.exe --monitor 0 --fps 15 --frames 300 --no-preview
```

The preview and headless capture commands read the selected desktop. Run them
only with the interactive user's explicit consent. `--list-monitors` reads
display metadata only; `--self-test` uses generated pixels only.

The current implementation intentionally maps frames to CPU memory for the
local preview. The production capture-to-encoder path must keep frames on the
GPU and feed Media Foundation/WebRTC without this readback.
