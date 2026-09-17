# TLS 1.3 client ownership

`client.Handshake` is the transport-independent TLS 1.3 handshake engine.
When its handshake completes, it hands the connection to a small
`tls13.established.Established` record, which `client.finish` moves out (see
[`established.md`](established.md)). `tls.stream` adds TLS records and a
completion-driven ordered byte transport. QUIC consumes the engine directly and
does not make either package depend on the other.

## Configuration and bounds

`client.init` snapshots the `config.ClientConfig`, entropy, trust-store, and
optional identity descriptors. The arrays, certificate encodings, private key,
ALPN bytes, and extension bytes reached through those descriptors remain
immutable caller-owned borrows for the lifetime of the connection, including the
established record it finishes into, which borrows the server name and the
selected ALPN bytes. Mutation of an
outer descriptor after initialization cannot redirect a live handshake. The
server name is an explicit bounded byte view, so validation and SNI encoding do
not depend on a terminator scan. The configuration requires one TLS 1.3 version,
one to three supported cipher
suites, one or two supported groups, one to five supported signature schemes,
at least one ALPN name, a bounded trust store, an operating-system or
application entropy source, a clock source, and explicit finite limits. SNI is
required and is always authenticated against the leaf certificate subject
alternative name.
An application entropy source declares the exact size of its public callback
context with `entropy_context_size`. The context is retained and must contain
all mutable provider state. TLS rejects secret callback context so provider
state cannot alias handshake keys or record plaintext through an address that
ordinary ownership checks cannot inspect.

The limits separate peer input from locally generated output:

- `max_peer_handshake_bytes` (default 16 KiB) bounds every peer handshake
  message except Certificate, including its four-byte header.
- A Certificate message is bounded by `max_chain_bytes` (default 64 KiB), which
  limits its entries together, plus its fixed framing
  (`config.certificate_message_bytes`). `max_certificate_bytes` (default 16 KiB)
  limits each entry.
- `max_ticket_bytes` (default 16 KiB) bounds a NewSessionTicket's ticket.
- `max_client_hello_bytes` and `max_client_flight_bytes` bound the largest
  configured ClientHello and client authentication flight. Initialization
  calculates exact output requirements from the configured names, extensions,
  chain, signature maximum, retry cookie and key share, so a large peer input
  policy does not force equally large output or ClientHello buffers.

Every limit can be raised to the protocol maximum. A deployment that must
accept longer chains raises `max_chain_bytes`, and the input buffer grows to
match when such a chain arrives.

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

`client.init` takes a `buffer.Lease` on the connection's account (see
[`memory.md`](memory.md)). The input, output, retained ClientHello and optional
peer-extension buffers are chunks from it, reserved when a message needs them
and returned once it is processed, so the input grows only to the largest
message actually received, at most `max_peer_handshake_bytes` or
`config.certificate_message_bytes(limits)`. Consumed prefixes are compacted so
the bound does not apply to the cumulative lifetime of a connection. The parsed
certificate array is part of the engine record. `start`, `ingest` and `poll`
return `WAITING` when memory is short, with nothing consumed.

`client.ExtraExtension.kind == 0` means that no opaque ClientHello extension is
present. A nonzero kind is present even when its body is empty. If a peer
extension is requested, its kind must match the offered extra extension and the
its body is retained in a chunk from the lease. This makes an empty QUIC
transport-parameters extension representable without a sentinel body.

## Incremental handshake

Call `client.init`, then `client.start`. Feed complete or fragmented handshake
bytes with `client.ingest`. The level is `INITIAL` for ServerHello,
`HANDSHAKE` for the encrypted handshake flight, and `APPLICATION` for legal
post-handshake messages, which the established core handles once the handshake
events have drained. `ingest` copies accepted input before returning. It
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
7. Handover to the established core, which validates bounded NewSessionTickets
   and processes stream-only KeyUpdates.

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
configuration, storage, output state, and handshake state must remain stable
across the call. Mutation restores the retained ownership descriptors and fails
terminally. Any failed or partially successful fill wipes the complete requested
secret destination before control returns.
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
When the last handshake event is accepted, the engine seeds the established
core with the application traffic secrets and destroys its key schedule,
transcript and offered PSK. From then on, `ingest`, `poll`, `next_event`,
`complete_event`, `traffic_keys`, `close`, `request_key_update` and the
snapshot are served by the core. `client.finish` moves the core out and
releases the handshake. Destruction is rejected while an event is borrowed.
Successful destruction wipes the ephemeral private key, transcript hash state,
key schedule, the core and every owned traffic secret.

Selected ALPN and peer parameters are copied out of the incremental input
buffer. Their snapshot views remain stable until `finish` or destruction. After
`finish`, the selected ALPN is a view of the configured protocol name and peer
parameters are no longer reported. Certificate public
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
- at handshake confirmation (RFC 9001 section 4.1.2) the adapter takes the
  snapshot and calls `client.finish`. A NewSessionTicket that arrives earlier
  is served by the embedded core, and one that arrives later by the finished
  core. Under QUIC the core keeps no application secret, since TLS KeyUpdate is
  refused.

TLS does not own QUIC offsets, retransmission, packet-number spaces, key discard
timing, or CRYPTO reassembly. QUIC does not parse TLS records. The event token is
the only ownership acknowledgement between the two layers.

## Secure stream operations

`tls.stream` snapshots a valid `tls.transport.Transport` descriptor and retains
its bounded callback context. The descriptor, runtime, context, application
buffers, scopes, completions, and the lease records are rejected when their
public ranges overlap. `init_*`, `connect*` and `serve*` take a `buffer.Lease`
and a `buffer.SecretLease` on the connection's one account. The Stream reads
into a wire buffer that starts at `stream.READ_START` and grows to what a
record header announces, seals and opens records in secret chunks held only
for that record, and returns every buffer when an operation ends. `connect`
combines initialization and handshake. Separate `handshake`, `read`, `write`,
`alert`, `half_close`, and `close` operations are also available. Every
operation retains its application token, cancellation scope, deadline, and
application buffer through terminal resolution. The caller must inspect the
terminal snapshot and call `destroy_operation` before starting the next
operation.

An operation that must wait for memory parks until `stream.resume`, and
settles through `stream.accept` like any other. The contract is in
[`memory.md`](memory.md).

Destroying the completed handshake operation finishes the engine into the
stream's own established core and releases the handshake object, whose
snapshot then reports `destroyed`, so its owner can reuse it. Read
`stream.negotiated` before that point for the peer name and peer parameters.
Afterwards the snapshot comes from the core. A finish that cannot happen yet
because an event is still borrowed is retried when the next operation starts.

Submission callbacks run outside the operation lock. The operation enters an
explicit submitting state first, so synchronous inspection cannot deadlock and
cancellation cannot release a buffer before a returned lower token settles.
Stream transitions use an entrant gate (see the ownership contract in
[`established.md`](established.md)). A call that finds another call in
progress, from another thread or from a reentering callback, is refused. A provider descriptor is pinned for every lower submission. If the
live descriptor changes, the operation retains its lower ownership until the
matching completion, validates that completion against the pinned provider
state, then fails terminally. Completion fields are snapshotted before the
provider alias query. Query reentry or mutation is consumed as the matching
lower completion and resolves to internal error without stranding its buffer.

The stream serializes application operations over one ordered transport. Read
and write record sequence numbers remain independent. Each operation can submit
as many partial lower reads and writes as needed while keeping one stable
application token. Incoming records and handshake messages can fragment at every
byte. Outgoing handshake flights and application writes split at the TLS
plaintext limit and advance application ownership only after the complete record
has settled.

A cancelled, timed-out or failed completion still reports the transfer that
finished before it, and the stream accounts for that transfer before the
operation resolves. This needs mach-std 5.3.0 or later, which reports it on
every backend.

- **Read.** A cancelled read keeps every byte and the end of stream the lower
  transport reported, and the following record still decodes. Cancelling a
  read is a control-flow decision and never a data-loss one, so a caller that
  pre-empts a read to make room for a write may do so at any point.
- **Write that finished its record.** A cancelled write whose transfer
  completed its record settles that record. Its application bytes count, and
  the stream stays `OPEN`.
- **Write that fails the stream.** The stream becomes `FAILED` for a write
  cancelled with a sealed record partly unsent, a zero-progress write, or a
  failed write, since a partially published ciphertext record cannot be
  retried or skipped.
- **Write between records.** A write that ends between records, including one
  parked for memory, leaves the stream `OPEN`.

After the terminal operation is destroyed, `close` on a failed stream submits
the distinct abortive lower-close callback without attempting another TLS
record.

A lower transport must report in a cancelled completion the bytes its request
already moved. A transfer larger than the request is refused as
`INTERNAL_ERROR`, however the request ended.

`half_close` writes close_notify completely, shuts down only the lower write
side, and keeps reads available. A later `close` submits the lower close without
emitting a second close_notify. Normal `close` writes close_notify completely
before the configured lower close. A fatal local alert moves the stream to
`FAILED`. A received close_notify resolves a read as clean end of stream. EOF
without close_notify is an unclean terminal failure.

`stream.destroy` is rejected while a lower completion or client event still owns
a buffer. It returns every buffer to the lease, wiping what it held, and
destroys terminal operation state, both record ciphers, and the established
core. The handshake object stays with its owner.
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

The external harness performs real TCP handshakes, bidirectional application
records, pre-cancelled and pre-timed-out reads, half-close, and final close
against OpenSSL and GnuTLS. Its checked-in test credentials cover Ed25519,
ECDSA P-256, verification-only ECDSA P-384 peer authentication, RSA-PSS
authentication, required client authentication, X25519, P-256 retry, and all
three TLS 1.3 cipher suites. See
[`../test/interop/README.md`](../test/interop/README.md).
