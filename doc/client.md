# TLS 1.3 client ownership

`tls.client` is the transport-independent TLS 1.3 handshake engine.
`tls.stream` adds TLS records and a completion-driven ordered byte transport.
The two layers share the same cryptographic state machine. QUIC consumes the
first layer directly and does not make either package depend on the other.

## Configuration and bounds

`config.ClientConfig` borrows all configuration for the lifetime of the client.
It requires one TLS 1.3 version, one to three supported cipher suites, one or two
supported groups, one to four supported signature schemes, at least one ALPN
name, a bounded trust store, an operating-system or application entropy source,
and explicit finite limits. SNI is required and is always authenticated against
the leaf certificate subject alternative name.

An optional client identity is validated against its private key during
initialization. Its chain and key remain caller-owned until the client is
destroyed. A CertificateRequest with no compatible signature scheme produces an
empty Certificate message as required by RFC 8446. A compatible request sends
Certificate, CertificateVerify, and Finished under one exact transcript.

`client.Storage` holds all variable-size handshake state. The input, output,
ClientHello retention, parsed certificate array, and optional peer-extension
retention buffers are caller-owned. Every capacity is validated before any
handshake state is published. A single handshake message can use at most
`limits.max_handshake_bytes`. Consumed prefixes are compacted so the bound does
not accidentally apply to the cumulative lifetime of a connection.

`client.ExtraExtension.kind == 0` means that no opaque ClientHello extension is
present. A nonzero kind is present even when its body is empty. If a peer
extension is requested, its kind must match the offered extra extension and the
caller must provide `Storage.peer_parameters`. This makes an empty QUIC
transport-parameters extension representable without a sentinel body.

## Incremental handshake

Call `client.init`, then `client.start`. Feed complete or fragmented handshake
bytes with `client.ingest`. The level is `INITIAL` for ServerHello,
`HANDSHAKE` for the encrypted handshake flight, and `APPLICATION` for legal
post-handshake messages. `ingest` copies accepted input before returning. It
reports the exact next byte requirement without publishing partial typed views.

The client implements these state transitions:

1. ClientHello with SNI, ALPN, supported versions, suites, signatures, groups,
   one key share, and an optional opaque extension.
2. At most one HelloRetryRequest with the RFC 8446 synthetic message hash,
   retained cookie, a newly generated share, and a suite-stable transcript.
3. ServerHello and handshake traffic-secret publication after the shared secret
   and transcript are committed.
4. EncryptedExtensions with exact ALPN validation and optional retained peer
   parameters.
5. Optional CertificateRequest, authenticated certificate path and server name,
   CertificateVerify, and Finished.
6. Client authentication flight when requested, client Finished, application
   traffic-secret publication, authentication disposition, and handshake
   completion.
7. Bounded NewSessionTicket validation and stream-only KeyUpdate processing.

Wrong encryption levels, duplicate or misplaced extensions, a second retry,
unsupported selections, illegal post-handshake messages, malformed certificates,
authentication failures, and bad Finished values fail closed with one alert.

## Event ownership

`client.next_event` publishes one event at a time. The event token, borrowed
data, and borrowed secret remain valid until the matching
`client.complete_event` call. A stale token cannot release a newer event.
Rejecting an event makes the client terminal and publishes one internal-error
alert through the same ownership path.

The event sequence can contain:

- `CRYPTO` with an encryption level and exact output bytes
- `TRAFFIC_SECRET` with level, direction, suite, and monotonically changing
  secret generation
- `PEER_PARAMETERS` retained in caller storage until destruction
- `EARLY_DATA` with its explicit disposition
- `AUTHENTICATION` after certificate and Finished authentication
- `HANDSHAKE_COMPLETE` after the client flight and application keys exist
- `ALERT` with the terminal TLS alert description

Consumers must copy or install a traffic secret before accepting its event.
The engine discards handshake keys only after the handshake-direction events are
accepted and the application schedule is live. Destruction is rejected while an
event is borrowed. Successful destruction wipes the ephemeral private key,
transcript hash state, key schedule, and every owned traffic secret.

Selected ALPN and peer parameters are copied out of the incremental input
buffer. Their snapshot views remain stable until destruction. Certificate public
key material needed for CertificateVerify is also retained independently of the
fragmented certificate input.

## QUIC adapter surface

A QUIC connection adapter can implement its handshake protocol directly over
`tls.client`:

- CRYPTO ingress calls `ingest` at the matching level.
- CRYPTO egress retains the event until all bytes are accepted by the QUIC
  crypto-stream owner.
- traffic-secret events install packet and header protection for the indicated
  level and direction before acknowledgement.
- peer transport parameters use `ExtraExtension` and `PEER_PARAMETERS`.
- early-data disposition, authentication, completion, and terminal alerts map
  without inference or fallback behavior.

TLS does not own QUIC offsets, retransmission, packet-number spaces, key discard
timing, or CRYPTO reassembly. QUIC does not parse TLS records. The event token is
the only ownership acknowledgement between the two layers.

## Secure stream operations

`tls.stream` borrows a valid `tls.transport.Transport` and caller-owned
`stream.Storage`. `connect` combines initialization and handshake. Separate
`handshake`, `read`, `write`, `alert`, `half_close`, and `close` operations are
also available. Every operation retains its application token, cancellation
scope, deadline, and application buffer through terminal resolution. The caller
must inspect the terminal snapshot and call `destroy_operation` before starting
the next operation.

The stream serializes application operations over one ordered transport. Read
and write record sequence numbers remain independent. Each operation can submit
as many partial lower reads and writes as needed while keeping one stable
application token. Incoming records and handshake messages can fragment at every
byte. Outgoing handshake flights and application writes split at the TLS
plaintext limit and advance application ownership only after the complete record
has settled.

A cancelled or timed-out read retains safely reusable record input. A cancelled,
timed-out, zero-progress, or failed write makes the stream `FAILED`, since a
partially published ciphertext record cannot be retried or skipped. After the
terminal operation is destroyed, `close` on a failed stream submits the distinct
abortive lower-close callback without attempting another TLS record.

`half_close` writes close_notify completely, shuts down only the lower write
side, and keeps reads available. Normal `close` writes close_notify completely
before the configured lower close. A fatal local alert moves the stream to
`FAILED`. A received close_notify resolves a read as clean end of stream. EOF
without close_notify is an unclean terminal failure.

`stream.destroy` is rejected while a lower completion or client event still owns
storage. It destroys terminal operation state, both record ciphers, and the
client, then wipes the full secret plaintext, content, and AEAD scratch buffers.

## Validation

Unit coverage includes RFC 8446 and RFC 8448 transcript and key-schedule values,
HelloRetryRequest fragmentation at every byte, complete authenticated server and
client flights, exact traffic-secret comparisons, retained peer-extension and
certificate-key lifetimes, corrupted CertificateVerify, wrong-state messages,
stale event acknowledgements, bounded configuration, record fragmentation at
every byte, partial writes, cancellation, zero progress, half-close ordering,
abortive cleanup, and destruction.

The external harness performs real TCP handshakes and secure closure against
OpenSSL and GnuTLS. Its checked-in test credentials cover Ed25519, ECDSA P-256,
RSA-PSS authentication, required client authentication, X25519, P-256 retry, and
all three TLS 1.3 cipher suites. See [`../test/interop/README.md`](../test/interop/README.md).
