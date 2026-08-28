# Session resumption, tickets, and key updates

`tls.session` owns everything a connection needs to be resumed later: the
server's ticket key ring, the sealed session state, the bounded replay window,
and the client's bounded ticket store. Every record is caller-owned and
explicitly bounded.

## Ticket keys and rotation

A server seals sessions under one ticket key at a time. `session.KeyRing` holds
at most `MAX_TICKET_KEYS` keys, exactly one of which is current for sealing.
`keyring_init` mints the first key and fixes three policy values:

- `seal_lifetime_seconds`: how long a key stays current for sealing
- `overlap_seconds`: how long a retired key stays usable for opening
- `ticket_lifetime_seconds`: the lifetime written into each issued ticket

`keyring_rotate` mints a replacement and retires the current key exactly: the
retired key stops sealing immediately and stops opening `overlap_seconds` later,
whatever remained of its original window. That makes retirement bounded and
predictable rather than "at least the overlap". Keys past their opening window
are wiped and their slots reused; a ring that is full evicts the key that stops
opening first.

A ticket therefore survives rotation for exactly the configured overlap. Its own
lifetime is independent and is enforced from the issue time sealed inside it, so
a ticket cannot outlive its lifetime even if its key is still openable.

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

## Client ticket storage

`session.ClientStore` retains at most `DEFAULT_MAX_TICKETS` tickets. Saving into
a full store evicts the oldest. Taking a ticket selects the freshest unexpired
one for the requested server name and **removes** it, so the same ticket is
never offered twice by this store, and expired tickets are dropped as they are
passed over.

A client with a store offers one PSK: it initializes its key schedule from the
ticket, writes `psk_key_exchange_modes` and a `pre_shared_key` extension last
with a zeroed binder, then computes the real binder over the truncated encoding
and patches it in. If the server does not select the PSK, the resumption
schedule is destroyed and the handshake continues as a full one.

## Key updates

Either role may call `request_key_update`, and `stream.key_update` drives it as
one operation: the KeyUpdate flight is written, the sending traffic secret
advances, and the operation settles. A peer's KeyUpdate advances the receiving
secret, and an update carrying `update_requested` is answered with one of our
own. Read and write sequence numbers remain independent, so a rekey in one
direction does not disturb the other.

## Early data

Early data is not implemented. Tickets are always issued with
`max_early_data = 0`, so no client is invited to send 0-RTT, and a client that
offers `early_data` anyway is not granted it: the server never echoes the
extension in EncryptedExtensions. Delivering 0-RTT payload would need an early
encryption level carried through `tls.stream`, which this package does not have.

## Validation

Unit coverage seals and opens tickets across rotation boundaries, asserts the
overlap is exact on both sides, rejects tampered tickets and expired ones,
admits a replayed value exactly once, bounds the client store and its eviction
order, resumes a real handshake between `tls.client` and `tls.server` with
matching application secrets, refuses a second presentation of one ticket under
a single-use policy, and drives thirty-two key updates in each direction while
the two sides stay in step.

The external harness resumes against OpenSSL and GnuTLS in both directions and
performs key updates mid-session against both. See
[`../test/interop/README.md`](../test/interop/README.md).
