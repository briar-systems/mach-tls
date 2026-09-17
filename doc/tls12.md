# TLS 1.2 ownership

`tls12.connection.Handshake` is the TLS 1.2 handshake engine. It implements both
roles in one module because the two share their secrets, their transcript, and
their record structure and differ only in the order of their state machine.
It publishes the same `tls.engine` contract as the TLS 1.3 engines, so
`tls.stream` drives a TLS 1.2 connection with the same operations, the same
completion-based transport, and the same ownership rules. A completed handshake
hands the connection to a `tls.tls12.established` record, and
`tls12.connection.finish` moves it out (see [`established.md`](established.md)).

## Modules

- `tls.tls12` holds the registry values and the per-suite properties: PRF hash,
  key size, derived IV size, AEAD, and whether a suite authenticates with an
  ECDSA or EdDSA certificate.
- `tls.tls12.prf` implements the RFC 5246 PRF and the secrets it produces.
- `tls.tls12.messages` provides borrowed typed views and transactional encoders
  for the TLS 1.2 handshake messages.
- `tls.tls12.connection` is the engine.
- `tls.tls12.established` is what an established connection keeps: close and
  alert state, the record limits and the negotiated facts. The record keys
  already live in the stream's ciphers, so it holds no secret, and the PRF
  secrets, transcript and credential lease go with the handshake once both
  traffic secrets are delivered.

`tls.handshake` frames both versions but keeps their message sets apart:
`parse_version` and `serialize_version` accept the TLS 1.2 set only when asked
for it, so a TLS 1.3 connection still rejects a ServerKeyExchange as an unknown
message type rather than as an out-of-state one.

## Key schedule

The PRF is `P_hash` from RFC 5246 section 5, and every intermediate value stays
secret-typed: `hkdf.extract` is HMAC with a secret key, a secret message, and a
secret output, so the `A(i)` chain, the output blocks, and the seed copy never
pass through a public buffer. The published RFC test vector for the SHA-256 PRF
is checked in.

The master secret is always the RFC 7627 extended master secret, computed over
the session hash through ClientKeyExchange. Both roles require the
`extended_master_secret` extension and abort with `insufficient_security` if the
peer does not offer it, so a connection is always bound to the handshake that
produced it. The RFC 5246 master secret is implemented and tested but is never
selected by the engine.

The key block is `PRF(master, "key expansion", server_random + client_random)`
and yields one write key and one derived IV per direction. AES-GCM derives a
four-byte implicit nonce and carries the eight-byte explicit nonce on the wire;
ChaCha20-Poly1305 derives the full twelve bytes and XORs the sequence number.
Both are already implemented in `tls.record`.

Finished values are `PRF(master, "client finished" | "server finished", hash)`
truncated to twelve bytes and compared without a data-dependent branch.

## Handshake

The client offers its suites, groups, point formats, signature algorithms,
ALPN, SNI, `extended_master_secret`, and an empty `renegotiation_info`. The
server replies with ServerHello, Certificate, ServerKeyExchange, and
ServerHelloDone in one flight; the client answers with ClientKeyExchange,
ChangeCipherSpec, and Finished; the server answers with ChangeCipherSpec and
Finished.

Key changes are explicit events. `engine.CHANGE_CIPHER_SPEC` tells the stream to
emit that record, and the traffic-secret event that follows installs the new
cipher, so the engine never needs to know about records and the stream never
needs to know about TLS 1.2 message ordering. The receiving key is published
only when the peer's plaintext flight is complete, so a plaintext message can
never arrive after the read cipher is installed.

The ServerKeyExchange signature covers `client_random + server_random` followed
by the exact `curve_type || named_curve || point` prefix that the message
carries, and it is verified against the leaf key that the certificate path
validation just authenticated. The suite constrains the certificate: an ECDSA
suite refuses an RSA leaf and an RSA suite refuses anything else.

Peer signature verification accepts Ed25519, ECDSA P-256 with SHA-256, ECDSA
P-384 with SHA-384, RSA-PSS with SHA-256 or SHA-384, and legacy RSA PKCS #1
with SHA-256 or SHA-384. P-384 is not a named group and is never selected for
local signing.

Both roles reject a record whose legacy version is outside `{3,1}` to `{3,3}`
when it is unprotected, and require exactly `{3,3}` once it is protected.
RFC 5246 appendix E.1 permits the lower value in a first ClientHello, and every
deployed client uses it.

## Downgrade protection

A listener whose configured versions include TLS 1.3 but which negotiates
TLS 1.2 writes the RFC 8446 section 4.1.3 sentinel into the last eight bytes of
its ServerHello random, and refuses a ClientHello carrying `TLS_FALLBACK_SCSV`
with `inappropriate_fallback`.

A client whose configured versions include TLS 1.3 sends `TLS_FALLBACK_SCSV`,
because in that configuration it is a TLS 1.3 capable client that has fallen
back, and it aborts with `illegal_parameter` if the ServerHello random carries
either sentinel. A client configured for TLS 1.2 only never offers the signal
and records a sentinel it sees without failing, which is what RFC 8446 requires:
the check belongs to a client that could have offered a higher version.

A listener configured for TLS 1.3 only cannot be reached over TLS 1.2 at all.
The TLS 1.3 server answers a ClientHello without TLS 1.3 in
`supported_versions` with `protocol_version`, and the TLS 1.2 engine refuses a
configuration whose versions do not include TLS 1.2.

## Renegotiation

Renegotiation is refused, always. Both roles send an empty
`renegotiation_info` and reject a non-empty one on an initial handshake. Once
established, any handshake byte fails the connection at its first byte: a
HelloRequest or a second ClientHello with `error.NO_RENEGOTIATION`, signalled on
the wire as `unexpected_message` because the connection is terminal rather than
merely declining, and any other message with `UNEXPECTED_MESSAGE`.

## Not implemented

TLS 1.2 client authentication is not supported. A TLS 1.2 CertificateVerify
signs the raw concatenation of every prior handshake message rather than a
running transcript hash, which would require retaining the whole handshake. Our
server never sends a CertificateRequest, and a listener whose credential
generation requires client authentication refuses TLS 1.2 with
`insufficient_security` rather than silently accepting an unauthenticated peer.
A client that receives a CertificateRequest answers with the empty Certificate
message RFC 5246 defines for a client with no suitable certificate.

Session resumption is TLS 1.3 only. The TLS 1.2 engine issues no session
tickets and offers no session id, so every TLS 1.2 connection is a full
handshake.

## Validation

Unit coverage checks the published RFC 5246 PRF vector, that the two directions
never share key material, that a legacy master secret differs from an extended
one over identical inputs, that a tampered Finished never verifies, that the
TLS 1.2 message codecs round trip through exact framing and reject a point of
the wrong length for its curve, and that an unprotected TLS 1.2 record may carry
a lower legacy version while a protected one may not.

Two engine-level tests drive the TLS 1.2 client against the TLS 1.2 server in
process: one completes an ECDHE handshake and compares both master secrets and
both directional keys byte for byte, then confirms a HelloRequest is refused;
the other confirms a fallback signal is refused by a dual-version listener, that
such a listener marks its random, and that a TLS 1.2 only client completes the
handshake while recording the mark.

The external harness runs both roles against OpenSSL and GnuTLS forced to
TLS 1.2. See [`../test/interop/README.md`](../test/interop/README.md).
