# mach-tls

A lightweight TLS implementation for Mach.

The package targets complete TLS 1.2 and TLS 1.3 clients and servers. It owns TLS records,
handshakes, key scheduling, certificates, authentication, session resumption,
and encrypted transport. Cryptographic algorithms come from `mach-crypto`.

## Modules

- `tls.tls12` and `tls.tls13` define protocol and algorithm registry values.
- `tls.config` defines bounded client and server configuration.
- `tls.cert` defines borrowed certificate, key, chain, and trust store contracts.
- `tls.transport` provides completion-based TLS operation ownership and ordered-byte adapters.
- `tls.record` defines record framing and limits.
- `tls.handshake` defines handshake framing and progress.
- `tls.state` defines client and server connection state.
- `tls.session` defines bounded session ticket storage.

`tls.lib` re-exports these modules for consumers that prefer one import.

## Status

The transport layer is implemented against the shared `mach-std` completion runtime. It retains stable application tokens, borrowed buffers, cancellation scopes, and their deadlines until terminal resolution. One application operation may sequence any required transport reads and writes without exposing readiness states. Partial completions, EOF, timeout, cancellation, and close have one terminal ownership path.

A native TCP adapter is included. QUIC handshake streams implement the same submission callbacks without creating a dependency from TLS back to QUIC.

Protocol record, handshake, certificate, and secure-stream work remains under the subsequent implementation issues. This revision does not yet expose a complete TLS connection.

Mach constant-time support is technically capable of implementing this package.
Production assurance will be accumulated through official vectors,
interoperability tests, differential tests, generated-code inspection, leakage
testing, and independent review.

## Local development

Dependencies use pinned Git tags. Build output uses Mach's default `out/`
directory inside this repository.

```sh
mach dep pull .
mach build .
mach test .
mach dep pull test/transport
mach test test/transport
```
