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
- `tls.record` implements TLS 1.2 and TLS 1.3 framing, alerts, padding, sequencing, and AEAD protection.
- `tls.handshake` defines handshake framing and progress.
- `tls.handshake.extensions` validates extension structure, placement, uniqueness, and ordering.
- `tls.handshake.codec` provides borrowed typed views and transactional encoders for TLS 1.3 messages.
- `tls.handshake.negotiation` selects suites, groups, signatures, and ALPN by server policy.
- `tls.tls13.transcript` owns SHA-256 and SHA-384 transcript lifecycle and retry rewrites.
- `tls.tls13.key_schedule` implements the complete TLS 1.3 HKDF schedule and traffic derivation.
- `tls.state` defines client and server connection state.
- `tls.session` defines bounded session ticket storage.

`tls.lib` re-exports these modules for consumers that prefer one import.

## Status

The transport layer is implemented against the shared `mach-std` completion runtime. It retains stable application tokens, borrowed buffers, cancellation scopes, and their deadlines until terminal resolution. One application operation may sequence any required transport reads and writes without exposing readiness states. Partial completions, EOF, timeout, cancellation, and close have one terminal ownership path.

A native TCP adapter is included. QUIC handshake streams implement the same submission callbacks without creating a dependency from TLS back to QUIC.

TLS 1.2 and TLS 1.3 record protection is implemented with mach-crypto AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305. TLS 1.3 handshake framing, message codecs, extension validation, transcript hashing, negotiation, and the complete key schedule are also implemented. Certificate verification and the client and server connection state machines remain under subsequent implementation issues. This revision does not yet expose a complete TLS connection.

## Record protection

Record parsing is incremental and reports the exact byte requirement without consuming fragmented input. Plaintext, ciphertext, inner plaintext, and TLS 1.3 padding limits are checked before cryptographic work. Sequence exhaustion fails before nonce construction or provider invocation.

TLS 1.2 AES-GCM uses the four-byte fixed IV plus the received eight-byte explicit nonce. TLS 1.2 ChaCha20-Poly1305 and all TLS 1.3 suites XOR the static IV with the padded sequence number. TLS 1.3 authenticates the outer application-data header and encrypts the inner content type and complete standards-permitted padding envelope.

Opening a record authenticates the complete ciphertext before releasing secret plaintext. Authentication failure clears the full possible plaintext prefix, makes the receive cipher terminal, and emits `bad_record_mac`. Key installation is transactional, key transitions reset sequence state, and destruction zeroizes keys and IVs.

Checked-in record vectors match independently generated Python cryptography AES-GCM and ChaCha20-Poly1305 output for both protocol versions. Hostile tests cover truncation, fragmentation, malformed headers and inners, record overflow, sequence exhaustion, output retry, invalid alerts, provider failure, authentication failure, and maximum TLS 1.3 padding.

## TLS 1.3 handshake primitives

Handshake framing borrows complete input without consuming partial messages. It reports the exact complete-frame requirement at every fragmentation boundary and rejects unknown message types and bodies above the caller's configured limit. Typed codecs cover ClientHello, ServerHello and HelloRetryRequest, EncryptedExtensions, CertificateRequest, Certificate, CertificateVerify, Finished, EndOfEarlyData, NewSessionTicket, KeyUpdate, and synthetic message hashes. Encoding is transactional and reports exact output requirements before writing.

Extension parsing enforces context placement, duplicate rejection, `pre_shared_key` ordering, vector lengths, canonical cardinality, supported key-share encodings, PSK binder sizes, and the structural rules for every TLS 1.3 extension used by this package. Negotiation applies server preference while proving that selected suites, groups, signatures, ALPN values, PSK identities, and PSK exchange modes were offered by the client. HelloRetryRequest selection rejects an already offered key share and cannot trigger a second retry.

`tls.tls13.transcript.Transcript` owns exactly one active hash algorithm. Complete accepted handshake frames advance the main transcript. Partial PSK ClientHello prefixes advance a separate binder transcript so binder computation cannot contaminate the main transcript. HelloRetryRequest rewriting is single-use, validates the retry message before mutation, and replaces ClientHello1 with its synthetic `message_hash` frame. Snapshot is non-consuming. Finalization consumes the hash context, and destruction zeroizes both possible context records.

The key schedule derives early, binder, handshake, master, application, exporter, resumption, Finished, traffic-key, traffic-IV, and traffic-update values. Secret transitions are transactional and temporary key material is zeroized. Derive the resumption master secret before `discard_handshake`, since that operation intentionally clears the master secret together with early and handshake traffic state.

RFC 8448 vectors cover exact ClientHello and ServerHello decoding, the HelloRetryRequest transcript rewrite, every key-schedule stage, traffic keys and IVs, Finished keys, application traffic, exporter state, and resumption PSKs. Hostile coverage includes every framing boundary, malformed message bodies, truncated extensions, duplicate and misplaced extensions, mismatched PSK identities and binders, illegal retry combinations, unsupported selections, output retry, state misuse, and authentication failure.

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
