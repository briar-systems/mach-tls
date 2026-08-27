# mach-tls

A lightweight TLS implementation for Mach.

The package targets complete TLS 1.2 and TLS 1.3 clients and servers. It owns TLS records,
handshakes, key scheduling, certificates, authentication, session resumption,
and encrypted transport. Cryptographic algorithms come from `mach-crypto`.

## Modules

- `tls.tls12` and `tls.tls13` define protocol and algorithm registry values.
- `tls.config` defines bounded client and server configuration.
- `tls.cert` defines borrowed certificate, key, chain, and trust store contracts.
- `tls.transport` isolates TLS from sockets and other byte transports.
- `tls.record` defines record framing and limits.
- `tls.handshake` defines handshake framing and progress.
- `tls.state` defines client and server connection state.
- `tls.session` defines bounded session ticket storage.

`tls.lib` re-exports these modules for consumers that prefer one import.

## Status

This revision is contract scaffolding. It does not expose connect, accept,
handshake, read, or write operations and cannot create a TLS connection yet.

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
```
