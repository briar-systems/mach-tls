# Session resumption, tickets, and key updates

`tls.session` owns everything a connection needs to be resumed later: the
server's ticket key ring, the sealed session state, the bounded replay window,
and the client's bounded ticket store. Every record is caller-owned and
explicitly bounded.

## Two clocks

Every client and server configuration names a `clock.Source`, a caller-owned
clock shared by all the connections that use it. An engine reads it at the
moment a time is needed, and each read returns one `clock.Moment` that holds two
separate readings: `wall`, a `time.Time`, and `monotonic`, a `time.Instant`.
`clock.system()` reads the process clocks. `clock.frozen` answers with a moment
the caller controls, for tests and replayed traces. The rule for which reading a
value uses:

- A value only ever compared with other readings from this process is an
  interval and uses `monotonic`: the ticket-key seal and open deadlines, and a
  client ticket's age.
- A value that must be compared with something from outside the process uses
  `wall`: certificate validity, a ticket's issue time and lifetime, and the
  replay window's expiry.

Neither reading is ever derived from the other, and no field of one moment is
compared with the other field of another. A wall-clock step therefore moves
neither key rotation nor a retired key's overlap, and a ticket's lifetime still
follows real time.

The engines read the source when a server seals a batch of tickets, when it
opens an offered ticket, when either side verifies a certificate chain, when a
client takes a ticket to offer, and when a client receives a ticket. Each read
comes before any state changes. A failed read during the handshake fails it
with `internal_error`. A failed read when a ticket arrives drops that ticket,
leaves the connection open, and counts it in the snapshot's
`ticket_clock_failures`.

`read_fn` runs inside a tls call, with that connection's entrant gate held. It
must not call into tls or block, and it must be safe to call from any thread
that drives a connection. A source must stay unchanged while any connection
names it. Its `context_size` bounds the bytes `context` names, and tls keeps
them apart from its own memory as it does an entropy context.

Callers that drive the lower layers directly still pass explicit times.
`verify.Options.now` is a `time.Time`, the key ring functions take a
`clock.Moment`, and the client store takes a `time.Instant`.

## Ticket keys and rotation

A server seals sessions under one ticket key at a time. `session.KeyRing` holds
at most `MAX_TICKET_KEYS` keys, exactly one of which is current for sealing.
`keyring_init` mints the first key and fixes three policy values. Each key
records a monotonic sealing deadline, a monotonic opening deadline, and the wall
time it was minted.

- `seal_lifetime_seconds`: how long a key stays current for sealing
- `overlap_seconds`: how long a retired key stays usable for opening
- `ticket_lifetime_seconds`: the lifetime written into each issued ticket

The ring is caller-owned and outlives connections, so the moments passed to
`keyring_init` and `keyring_rotate` must come from the same source as the
configurations that use it.

`keyring_rotate` mints a replacement and retires the current key exactly: the
retired key stops sealing immediately and stops opening `overlap_seconds` later,
whatever remained of its original window. That makes retirement bounded and
predictable rather than "at least the overlap". Keys past their opening window
are wiped and their slots reused. A ring with `MAX_TICKET_KEYS` live keys
refuses rotation until a key expires, preserving every configured overlap.

A ticket therefore survives rotation for exactly the configured overlap. Its own
lifetime is independent and is enforced against the wall clock from the issue
time sealed inside it, so a ticket cannot outlive its lifetime even if its key is
still openable. A ticket whose issue time is later than the current wall time is
refused.

## Ticket format

A ticket is opaque to the peer. It is `key_name || nonce || AES-256-GCM(state)`
with the key name authenticated as additional data. The sealed state carries the
protocol version, the cipher suite, the resumption secret, the issue time, the
lifetime, the age obfuscation value, the credential generation, whether the
original connection authenticated its client, the negotiated ALPN, and the
server name. Opening validates the key name, the tag, the encoding, and the
lifetime before publishing anything.

Tampering with any byte fails authentication, and a state that does not decode
exactly is rejected rather than partially applied.

## Server resumption

A server with a configured key ring attempts resumption on the first
ClientHello. It requires the `psk_dhe_ke` exchange mode, opens each offered
identity in turn, and accepts the first ticket whose suite it can select, whose
suite the client offered, and whose server name matches the connection's SNI.
The binder is verified on a separate transcript over the truncated ClientHello,
so binder computation never contaminates the main transcript. A binder that does
not match aborts with `decrypt_error`; RFC 8446 requires it.

A resumed handshake still performs (EC)DHE, still negotiates ALPN, and omits
Certificate, CertificateVerify, and CertificateRequest. The client's
authentication disposition is recovered from the ticket.

Resumption is attempted only on a ClientHello that did not follow a
HelloRetryRequest. A retried hello carries a rewritten transcript whose binder
covers the synthetic message hash and the retry, and rather than reconstruct
that, the server simply declines the PSK and completes a full handshake, which
is always legal.

## Replay control

`session.ReplayWindow` admits an opaque value exactly once inside a lifetime,
inside a bounded number of entries, and fails closed when it is full. A server
configured with `session.REPLAY_SINGLE_USE` admits the **ticket identity**, so a
ticket that is presented twice resumes once and then falls back to a full
handshake. Keying this on the PSK binder would not work: a binder covers the
ClientHello, so it is different on every presentation of the same ticket.

The default policy is `session.REPLAY_PERMISSIVE`, under which a ticket may be
presented more than once. Configuring `REPLAY_SINGLE_USE` requires both a
window and a key ring; a configuration that names the policy without them is
rejected.

## Client ticket retention

`session.ClientStore` retains at most `DEFAULT_MAX_TICKETS` tickets. Saving into
a full store evicts the oldest. Taking a ticket selects the freshest unexpired
one for the requested server name and **removes** it, so the same ticket is
never offered twice by this store, and expired tickets are dropped as they are
passed over. A retained ticket carries a monotonic receipt instant, and a taken
ticket carries its age in milliseconds measured from it.

A client with a store offers one PSK: it initializes its key schedule from the
ticket, writes `psk_key_exchange_modes` and a `pre_shared_key` extension last
with a zeroed binder, then computes the real binder over the truncated encoding
and patches it in. The identity's `obfuscated_ticket_age` is the ticket's age
plus its `age_add`, modulo 2^32. If the server does not select the PSK, the
resumption schedule is destroyed and the handshake continues as a full one. The
offered ticket, accepted or not, is wiped when the handshake completes.

Tickets arrive after the handshake and are retained by the established core,
which keeps the resumption master secret only when a store is configured. The
core reads the client's clock source as each ticket arrives, so a ticket's age
runs from its receipt, however late in the connection that is. It assembles a ticket in the handshake's input until `finish`, then in a
chunk from the engine's lease, reserved before the ticket's bytes are taken (a
shortage returns `WAITING` with nothing consumed) and returned once the ticket
is saved. A ticket nothing can retain is skipped without buffering its body.

## Key updates

Either role's established core accepts `request_key_update`, and
`stream.key_update` drives it as one operation: the KeyUpdate flight is written,
the sending traffic secret advances, and the operation settles. A peer's
KeyUpdate advances the receiving secret, and an update carrying
`update_requested` is answered with one of our own. A KeyUpdate must be the last
message in its record, so anything after it in the same ingest fails the
connection. Read and write sequence numbers remain independent, so a rekey in
one direction does not disturb the other. QUIC refuses TLS KeyUpdate, and under
QUIC the core keeps no application secret.

## Early data

Early data is not implemented. Tickets are always issued with
`max_early_data = 0`, so no client is invited to send 0-RTT, and a client that
offers `early_data` anyway is not granted it: the server never echoes the
extension in EncryptedExtensions. Delivering 0-RTT payload would need an early
encryption level carried through `tls.stream`, which this package does not have.

## Validation

Unit coverage seals and opens tickets across rotation boundaries, asserts the
overlap is exact on both sides, steps the wall clock without moving rotation,
checks a taken ticket's age and the obfuscated age a client sends, measures a
ticket's age from its receipt, counts a ticket dropped for an unreadable clock,
fails a handshake whose clock cannot be read with nothing changed in the ring,
store or replay window, repeats a full handshake and a resumption byte for byte
under a frozen clock, rejects tampered tickets and expired ones, admits a
replayed value exactly once, bounds the client store and its eviction order,
resumes a real handshake between `tls.client` and `tls.server` with matching
application secrets, refuses a second presentation of one ticket under a
single-use policy, and rekeys twice in each direction while the two sides stay in
step.

The external harness resumes against OpenSSL and GnuTLS in both directions and
performs key updates mid-session against both. See
[`../test/interop/README.md`](../test/interop/README.md).
