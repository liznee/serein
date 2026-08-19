# Serein Remote Protocol

This directory is the cross-platform protocol baseline for Serein remote desktop.
It is deliberately independent from Agent sessions and tool approval messages.

Current scope:

- protocol version 1;
- Windows host capability reports;
- monotonic remote-session state updates;
- normalized pointer movement test vectors;
- versioned manual WebRTC Offer/Answer/ICE signaling envelopes;
- Stage 1 authenticated envelopes with a session ID, monotonic revision and a
  single-use 90-second ticket on `client_ready`.

The schema describes SDP and ICE envelopes because they must interoperate across
implementations. Test vectors, logs, caches, and diagnostics deliberately omit
SDP, ICE candidates, reusable tokens, keyboard text, file paths, screenshots,
and media frames. The backend stores only a SHA-256 nonce hash for each
short-lived ticket. Raw tickets, SDP and ICE are never persisted or logged.

Compatibility rules:

1. Unknown protocol versions fail closed.
2. Unknown capabilities are not enabled implicitly.
3. Capture, codec and transport readiness are independent facts. A Host is not
   view-capable until it reports all three; encoder availability alone is not a
   usable remote connection.
4. Session state revisions only move forward.
5. Input coordinates are normalized to the inclusive range `[0, 1]`.
6. Media never travels through the existing command relay.

Run the protocol checks from the repository root with `npm test`.
