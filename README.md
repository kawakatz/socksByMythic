# socksByMythic🧦

<p align="center">
<a href="LICENSE"><img src="https://img.shields.io/badge/license-BSD--3--Clause-blue.svg"></a>
<a href="https://github.com/kawakatz/socksByMythic/issues"><img src="https://img.shields.io/badge/contributions-welcome-brightgreen.svg?style=flat"></a>
<a href="https://x.com/kawakatz"><img src="https://img.shields.io/twitter/follow/kawakatz"></a>
</p>

socksByMythic is a proof-of-concept reverse SOCKS5 tunnel over WebSockets. It
uses Mythic's proxy message shape without requiring a Mythic deployment:

- The Go server exposes a local SOCKS5 listener and a WebSocket endpoint
- The Objective-C client connects outbound over WebSockets and opens target
  connections from its macOS host

Only SOCKS5 `CONNECT` with no authentication is supported. UDP, reconnects,
and multiple simultaneous clients are intentionally out of scope.

<img src="_img/sample.png" width="850" style="border: 1px solid white; display: block; margin: 0 auto;" alt=""><br>

## Usage

Start the server:

```sh
cd server
go run . -http :8080 -socks :7000
```

Build and run the client on the remote macOS host:

```sh
cd client/client
mkdir -p ../../build
xcrun --sdk macosx clang \
  -fobjc-arc -fmodules -fblocks -std=gnu17 \
  -Ichannel -Isocks -Iwebsocket \
  -framework Foundation \
  main.m */*.m \
  -o ../../build/client
../../build/client ws://<server>:8080/ws
```

Use the SOCKS listener on the server host:

```sh
curl --proxy socks5://127.0.0.1:7000 https://example.com/
curl --proxy socks5h://127.0.0.1:7000 https://example.com/
```

The second form resolves hostnames from the client host.

## Attribution

The wire format and proxy behavior are derived from
[Mythic](https://github.com/its-a-feature/Mythic/tree/74864c180325be27cf2223382115fc4fd4333d5d/mythic-docker/src),
and the client follows
[Poseidon's SOCKS implementation](https://github.com/MythicAgents/poseidon/blob/47a19368b5edd766a4d5cb6229d57afff9c6edc7/Payload_Type/poseidon/poseidon/agent_code/socks/socks.go).
See [NOTICE.md](NOTICE.md) for third-party licenses.
