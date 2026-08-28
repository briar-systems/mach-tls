# TLS 1.3 client ownership

`tls.client` is the transport-independent TLS 1.3 handshake engine.
`tls.stream` adds TLS records and a completion-driven ordered byte transport.
The two layers share the same cryptographic state machine. QUIC consumes the
first layer directly and does not make either package depend on the other.

## Configuration and bounds

`client.init` snapshots the `config.ClientConfig`, entropy, trust-store, and
optional identity descriptors. The arrays, certificate encodings, private key,
ALPN bytes, and extension bytes reached through those descriptors remain
immutable caller-owned borrows for the lifetime of the client. Mutation of an
outer descriptor after initialization cannot redirect a live handshake. The
server name is an explicit bounded byte view, so validation and SNI encoding do
not depend on a terminator scan. The configuration requires one TLS 1.3 version,
one to three supported cipher
suites, one or two supported groups, one to four supported signature schemes,
at least one ALPN name, a bounded trust store, an operating-system or
application entropy source, and explicit finite limits. SNI is required and is
always authenticated against the leaf certificate subject alternative name.

The limits separate peer input from locally generated output. The
`max_peer_handshake_bytes` bound includes the four-byte handshake header.
`max_client_hello_bytes` and `max_client_flight_bytes` independently bound the
largest configured ClientHello and client authentication flight. Initialization
calculates exact output requirements from the configured names, extensions,
chain, signature maximum, retry cookie, and key share. A large peer input policy
therefore does not force equally large output or ClientHello storage.
`max_chain_bytes` and `max_ticket_bytes` apply to their specific peer objects.

`max_receive_record_plaintext` and `max_send_record_plaintext` are directional
content limits. The receive limit is advertised with the RFC 8449
record_size_limit extension, including the TLS 1.3 inner content-type byte. A
peer can omit the optional response. If it responds, the effective send limit
is the smaller of local policy and the peer's returned limit. The minimum
receive content is 63 bytes, corresponding to the protocol's minimum advertised
value of 64.

An optional client identity is validated against its private key during
initialization. Its chain and key remain caller-owned until the client is
destroyed. A CertificateRequest with no compatible signature scheme produces an
empty Certificate message as required by RFC 8446. A compatible request sends
Certificate, CertificateVerify, and Finished under one exact transcript.

`client.Storage` holds all variable-size handshake state. The input, output,
ClientHello retention, parsed certificate array, and optional peer-extension
retention buffers are caller-owned. Every range must be representable and every
mutable region must be disjoint. Configuration and extension input cannot
overlap those regions. Every pointer range and array product is validated before
the first nested descriptor is traversed or handshake state is published. A
single handshake frame can use at most `limits.max_peer_handshake_bytes`,
including its header. Consumed prefixes are compacted so the bound does not
accidentally apply to the cumulative lifetime of a connection.

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
   one key share, an optional record-size limit, and an optional opaque
   extension.
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

Entropy callbacks cannot reenter or destroy the active client. Their descriptor,
configuration pointer, and handshake state must remain stable across the call.
Every public output descriptor is validated and proven disjoint from client,
storage, callback-context, and retained configuration ownership before event
state is committed.

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
- QUIC Retry and version negotiation call `restart`, which republishes the exact
  retained ClientHello at Initial offset zero without regenerating TLS state.
- traffic-secret events install packet and header protection for the indicated
  level and direction before acknowledgement.
- peer transport parameters use `ExtraExtension` and `PEER_PARAMETERS`.
- early-data disposition, authentication, completion, and terminal alerts map
  without inference or fallback behavior.

TLS does not own QUIC offsets, retransmission, packet-number spaces, key discard
timing, or CRYPTO reassembly. QUIC does not parse TLS records. The event token is
the only ownership acknowledgement between the two layers.

## Secure stream operations

`tls.stream` snapshots a valid `tls.transport.Transport` descriptor and retains
its bounded callback context. The descriptor, runtime, context, application
buffers, scopes, completions, and TLS storage are rejected when their public
ranges overlap. Its caller-owned `stream.Storage` has disjoint public
handshake and wire regions plus one secret-welded arena of exactly partitioned
plaintext, content, and AEAD scratch regions. One arena makes secret subrange
aliasing unrepresentable without exposing secret storage through a public
address. `connect` combines initialization and handshake. Separate
`handshake`, `read`, `write`, `alert`, `half_close`, and `close` operations are
also available. Every operation retains its application token, cancellation
scope, deadline, and application buffer through terminal resolution. The caller
must inspect the terminal snapshot and call `destroy_operation` before starting
the next operation. Application buffers, cancellation scopes, completions, wire
storage, and operation state have disjoint ownership while active.

The secret arena requirement is calculated as
`receive + 2 * send + 2` bytes. This holds one bounded incoming TLSInnerPlaintext
region, one outgoing content region, and one outgoing TLSInnerPlaintext scratch
region. Applications using smaller directional record policies do not pay for
three maximum-size records. The public input and output wire buffers scale to
`receive + 22` and `send + 22` bytes respectively, covering the record header,
TLS 1.3 inner content type, and AEAD tag.

Submission callbacks run outside the operation lock. The operation enters an
explicit submitting state first, so synchronous inspection cannot deadlock and
cancellation cannot release a buffer before a returned lower token settles.
Stream transitions use an atomic thread-owner gate. Concurrent callers serialize,
while a callback that reenters on the owning thread is rejected without
deadlock. A provider descriptor is pinned for every lower submission. If the
live descriptor changes, the operation retains its lower ownership until the
matching completion, validates that completion against the pinned provider
state, then fails terminally.

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
client, then wipes the complete secret arena in one operation.
If `connect` initializes successfully but rejects the handshake before an
application operation takes ownership, it rolls initialization back and clears
every retained pointer. Once an operation is accepted, including immediate
cancellation or a synchronous provider error, the call returns accepted and the
terminal result is reported through its snapshot.

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
