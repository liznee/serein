# Local WebRTC Stage 0 Lab

This lab proves browser-to-ArkWeb WebRTC video and DataChannel behavior before
the native Windows Host is linked to libwebrtc. It is not a production relay.

- signaling is held in memory and disappears when the process stops;
- one random room token authorizes one host and one phone client;
- SDP and ICE payloads are never logged or persisted;
- media is peer-to-peer and never passes through this HTTP/WebSocket server;
- the Windows page starts with an animated synthetic stream;
- desktop sharing only starts after a user clicks the button and confirms the
  browser picker.

Run the broker self-test:

```powershell
node .\remote\web-poc\signal-server.mjs --self-test
```

Start a LAN lab:

```powershell
node .\remote\web-poc\signal-server.mjs
```

Open the printed `host_url` on the PC. Paste the printed `phone_signal_url` into
the Serein App's Remote Lab page. Windows Firewall may require an explicit
private-network allowance for the chosen port.
