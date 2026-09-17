# mach-tls

A lightweight TLS implementation for Mach.

The package targets complete TLS 1.2 and TLS 1.3 clients and servers. It owns TLS records,
handshakes, key scheduling, certificates, authentication, session resumption,
and encrypted transport. Cryptographic algorithms come from `mach-crypto`.

## Modules

- `tls.tls12` and `tls.tls13` define protocol and algorithm registry values.
- `tls.tls12.prf` implements the TLS 1.2 pseudorandom function and its secrets.
- `tls.tls12.messages` provides borrowed views and encoders for TLS 1.2 messages.
- `tls.tls12.connection` implements the TLS 1.2 handshake for both roles.
- `tls.tls12.established` holds what an established TLS 1.2 connection keeps.
- `tls.config` defines bounded client and server configuration.
- `tls.cert` defines borrowed certificate, chain, and trust store contracts.
- `tls.cert.x509` parses strict borrowed X.509 certificate views.
- `tls.cert.verify` constructs and verifies bounded certificate paths.
- `tls.cert.load` loads certificate chains and owned private keys from DER and PEM.
- `tls.cert.credentials` selects and safely rotates immutable credential generations.
- `tls.engine` defines the role-independent handshake engine contract.
- `tls.transport` provides completion-based TLS operation ownership and ordered-byte adapters.
- `tls.record` implements TLS 1.2 and TLS 1.3 framing, alerts, padding, sequencing, and AEAD protection.
- `tls.handshake` defines handshake framing and progress.
- `tls.handshake.extensions` validates extension structure, placement, uniqueness, and ordering.
- `tls.handshake.codec` provides borrowed typed views and transactional encoders for TLS 1.3 messages.
- `tls.handshake.negotiation` selects suites, groups, signatures, and ALPN by server policy.
- `tls.tls13.transcript` owns SHA-256 and SHA-384 transcript lifecycle and retry rewrites.
- `tls.tls13.key_schedule` implements the complete TLS 1.3 HKDF schedule and traffic derivation.
- `tls.tls13.established` holds what an established TLS 1.3 connection keeps, for both roles: application secrets, key updates, tickets, and close state.
- `tls.buffer` borrows every variable-size buffer from the caller's `std.memory.buffers` sources, one account per connection (see [`doc/memory.md`](doc/memory.md)).
- `tls.transition` is the entrant gate every engine, core, and stream call passes.
- `tls.state` defines client and server connection state.
- `tls.session` implements ticket keys and rotation, sealed session state, bounded replay control, and bounded client ticket storage.
- `tls.client` implements the incremental TLS 1.3 client handshake (`client.Handshake`).
- `tls.server` implements the incremental TLS 1.3 server handshake and
  credential selection (`server.Handshake`).
- `tls.stream` implements a completion-driven TLS 1.3 secure byte stream for
  either role.

- `tls.validation` holds the deterministic mutation corpora for every parsing
  surface.

`tls.lib` re-exports these modules for consumers that prefer one import.

## Status

The transport layer is implemented against the shared `mach-std` completion runtime. It retains stable application tokens, borrowed buffers, cancellation scopes, and their deadlines until terminal resolution. One application operation may sequence any required transport reads and writes without exposing readiness states. Partial completions, EOF, timeout, cancellation, and close have one terminal ownership path.

A native TCP adapter is included. QUIC handshake streams implement the same submission callbacks without creating a dependency from TLS back to QUIC.

TLS 1.2 and TLS 1.3 record protection is implemented with mach-crypto AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305. TLS 1.3 handshake framing, message codecs, extension validation, transcript hashing, negotiation, and the complete key schedule are also implemented. X.509 parsing, certificate path verification, identity matching, credential loading, SNI selection, client-auth trust snapshots, and safe credential rotation are implemented.

The TLS 1.3 client is complete. It supports authenticated SNI and ALPN negotiation, X25519 and P-256 including HelloRetryRequest, all three TLS 1.3 cipher suites, optional client authentication, post-handshake tickets and KeyUpdate, alerts, bounded incremental input, exact secret transitions, and deterministic destruction.

The TLS 1.3 server is complete. It selects credentials by SNI with exact, wildcard, and default precedence, or through an ALPN-aware server credential selector that sees SNI and the complete offered ALPN list before leasing one generation. RFC 8737 TLS-ALPN challenge credentials are accepted only through their explicit transient-store contract. It negotiates ALPN, suites, groups, and signatures against the leased private key, issues at most one HelloRetryRequest, requests and verifies optional client authentication, and answers invalid ClientHellos with protocol-correct alerts and bounded work. Certificate rotation retires a generation without disturbing any established connection.

TLS 1.2 is implemented for both roles over the same engine contract, the same records, and the same transport. It negotiates the six declared ECDHE AEAD suites, always uses the RFC 7627 extended master secret, refuses renegotiation outright, and implements downgrade protection in both directions: a dual-version listener marks its random and refuses `TLS_FALLBACK_SCSV`, and a client that could have offered TLS 1.3 refuses a marked random. A listener configured for TLS 1.3 only cannot be reached over TLS 1.2. TLS 1.2 client authentication and TLS 1.2 resumption are deliberately absent; the contract and the reasons are in [`doc/tls12.md`](doc/tls12.md).

Session resumption is implemented for both roles. A server seals sessions under a rotating ticket key with an exact retirement overlap, verifies PSK binders on a separate transcript, and can require a ticket to be single-use. A client retains tickets in a bounded store and offers one PSK per connection. Either role can initiate a post-handshake key update. Early data is not implemented and is never offered. The contract is in [`doc/sessions.md`](doc/sessions.md).

`tls.engine` defines the one handshake-engine contract both roles implement, so `tls.stream` drives either over the same records and the same transport. A stream borrows a caller-owned engine and never destroys it. Once the handshake completes, the stream finishes the engine into its own small established core and releases the engine to its owner, so an idle established connection holds no handshake state. The split, `finish`, the ownership contract, and the per-connection memory figures are in [`doc/established.md`](doc/established.md). `tls.stream` adds incremental record I/O, partial completion handling, read, write, half-close, alert, graceful close, and abortive failure cleanup. The exact ownership contracts and the record-free QUIC adapter surface are documented in [`doc/client.md`](doc/client.md) and [`doc/server.md`](doc/server.md).

## Certificates and credentials

Certificate parsing is strict DER and publishes only borrowed views after the entire certificate validates. Path construction backtracks across unordered intermediates and trust anchors within an explicit depth bound. It verifies signatures, validity, basic constraints, path length, key usage, extended key usage, authority key identifiers, DNS and IP name constraints, and the requested server or client purpose. Unknown critical extensions fail closed.

Certificate paths authenticate Ed25519, ECDSA P-256 SHA-256, ECDSA P-384
SHA-384, RSA-PSS SHA-256/SHA-384, and RSA PKCS #1 v1.5 SHA-256/SHA-384
signatures within explicit depth and public-key-operation bounds. P-384 is
verification-only. It is accepted for certificate paths and peer signatures but
never selected for local signing or key exchange. Server identities use subject
alternative names only. DNS matching is ASCII case-insensitive, permits one
complete leftmost wildcard label, and never allows a wildcard to span labels.
IP literals are parsed to network bytes and match only `iPAddress` entries.
Common-name fallback is intentionally absent.

PEM bundle loading validates every block before publishing a chain. Private keys are owned by `mach-crypto` secret allocators and support PKCS #8, SEC 1, and RSA PKCS #1 containers. Credential initialization proves that the private key matches the leaf certificate before publication.

Credential generations are immutable after initialization and can be published by only one store. A rotation retires the old generation while leases held by active handshakes remain valid. The caller may reclaim certificate arrays, trust anchors, and private keys only after the retired generation reports that it is reclaimable. The complete contract and supported algorithms are in [`doc/certificates.md`](doc/certificates.md).

## Record protection

Record parsing is incremental and reports the exact byte requirement without consuming fragmented input. Plaintext, ciphertext, inner plaintext, and TLS 1.3 padding limits are checked before cryptographic work. Sequence exhaustion fails before nonce construction or provider invocation.

TLS 1.2 AES-GCM uses the four-byte fixed IV plus the received eight-byte explicit nonce. TLS 1.2 ChaCha20-Poly1305 and all TLS 1.3 suites XOR the static IV with the padded sequence number. TLS 1.3 authenticates the outer application-data header and encrypts the inner content type and complete standards-permitted padding envelope.

Opening a record authenticates the complete ciphertext before releasing secret plaintext. Authentication failure clears the full possible plaintext prefix, makes the receive cipher terminal, and emits `bad_record_mac`. Key installation is transactional, key transitions reset sequence state, and destruction zeroizes keys and IVs.

Record providers receive only the exact writable ciphertext or plaintext
extent. Public and secret inputs validate representable ownership before use,
including partial secret subrange overlap and cipher-state aliasing.

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

## Record literals

A record literal leaves every field it does not name holding the previous stack
frame's contents rather than zero, which covers `T{}` as well as any partial
form (briar-systems/mach#3108). Clearing a security-bearing record with a
literal therefore does not clear it.

Name every field of every literal. A record containing an array cannot satisfy
that, because an array field cannot be named in a literal at all, so those are
built by declaring `var value: T;` — which does zero the whole record including
its arrays — and assigning each field. The `no_transport`, `no_client_config`,
`no_server_config`, `no_entropy`, `no_identity`, `no_trust_store` and
`no_certificate` constructors exist for exactly this: they return a value
cleared by declaration, and teardown paths copy from them rather than assigning
a literal.

Nothing enforces this automatically. Enumerating the violations was a
workaround for briar-systems/mach#3108, and that defect is being fixed in the
compiler, so the constructors above are what keep the rule in one place rather
than at every teardown site.

## Local development

Dependencies use pinned Git tags. Build output uses Mach's default `out/`
directory inside this repository.

```sh
mach dep pull .
mach build .
mach test .
mach dep pull test/interop
mach dep update test/interop tls
mach build test/interop
```

The interoperability project builds three binaries: `tls-client-interop` dials
an external server, `tls-server-interop` accepts external clients, and
`tls-evidence` prints the supported algorithm matrix from the library's own
predicates.

`./test/interop/run.sh` runs the complete client and server matrix against
OpenSSL and GnuTLS, prints the release evidence, and exits non-zero naming any
leg that failed. What it covers, and what it does not, is in
[`doc/validation.md`](doc/validation.md).

External OpenSSL and GnuTLS interoperability commands are in
[`test/interop/README.md`](test/interop/README.md).
