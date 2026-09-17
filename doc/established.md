# Established connections and ownership

A connection has two phases, each with its own record:

- the handshake engine, which does all the handshake work
- a small established record, which keeps only what an established connection
  still reads

Moving from one to the other is explicit, and it is the only way to get an
established record. This split keeps the idle per-connection footprint small
enough to hold a very large number of connections (#87).

## Records

| role | handshake engine | established record |
| --- | --- | --- |
| TLS 1.3 server | `server.Handshake`, 5,800 bytes | `tls13.established.Established`, 464 bytes |
| TLS 1.3 client | `client.Handshake`, 5,984 bytes | `tls13.established.Established`, 464 bytes |
| TLS 1.2, both roles | `tls12.connection.Handshake`, 4,032 bytes | `tls12.established.Established`, 88 bytes |

Sizes are for x86_64. The established records are bounded by
`established.MAX_BYTES` (512) and `tls12.established.MAX_BYTES` (256), and tests
enforce both bounds.

The TLS 1.3 established record holds:

- the suite
- both application traffic secrets, only when TLS KeyUpdate is possible, which
  excludes QUIC
- the resumption master secret, only for a client with a session store
- the exporter master secret, only with `config.retain_exporter`
- key-update, alert and close state
- the record limits
- a four-slot event queue
- the negotiated facts
- borrowed views of the configured server name and the selected ALPN name

It holds no transcript, credential lease, peer certificate, handshake storage or
configuration copy. No call on it re-validates borrowed arrays, so an idle call
is O(1).

The TLS 1.2 established record holds close and alert state, the record limits
and the negotiated facts. Its record keys already live in the stream's ciphers.

## Handover and finish

When the last handshake event is accepted, the engine seeds its embedded core:

- the application secrets are copied into the core
- the key schedule, transcript, PSK state, TLS 1.2 PRF secrets and credential
  lease are wiped or released
- any post-handshake bytes the peer sent behind its Finished go to the core

From then on the engine serves `ingest`, `poll`, `next_event`,
`complete_event`, `traffic_keys`, `close`, `request_key_update` and the record
limits from the core.

`finish(handshake, *Established, storage)` (TLS 1.2 takes no storage) moves the
core out:

- It refuses with `INVALID_STATE`, changing nothing, until the handoff has
  happened, the handshake queue is drained and no event is borrowed.
- On success the core carries any queued post-handshake events and any
  half-assembled ticket, and the handshake engine returns to its destroyed
  state, ready for `init` again or for a pool.

Take the snapshot before `finish`. The handshake reports the peer's server name
and QUIC transport parameters, and the established record does not keep them.
A client's snapshot still reports its configured server name.

The established record borrows from the caller's configuration, so the
configuration must outlive the connection, as it already had to outlive the
handshake.

### tls.stream

The stream embeds both established records. When the completed handshake
operation is destroyed, it finishes the engine into the matching record and
stops borrowing the engine, whose snapshot then reports `destroyed`. If an event
is still borrowed at that moment, the finish is retried when the next operation
starts. `stream.negotiated` reports the handshake's view until then, and the
established record's view afterwards.

A TLS 1.3 client with a session store passes `stream.Storage.ticket_input`,
sized for `max_ticket_bytes` plus a handshake header. Without it, tickets are
skipped.

### QUIC

A QUIC adapter drives the engine directly. At handshake confirmation (RFC 9001
section 4.1.2), and on a server once its NewSessionTicket CRYPTO events are
accepted, it takes the snapshot and calls `finish`, retrying on
`INVALID_STATE`.

- A client's NewSessionTicket is retained whether it arrives before or after
  `finish`.
- The established record keeps no application secret under QUIC, because QUIC
  never updates TLS keys, and `request_key_update` is refused.

## Ownership contract

Every engine, established record and stream has exactly one owner at a time.

- A call enters through `tls.transition`, one uncontended compare-and-swap, and
  leaves when it returns.
- A call that finds another call in progress is refused: `false`, or `FAILED`
  with `ILLEGAL_PARAMETER`. That covers a call from another thread and a
  callback re-entering from its own thread. Nothing waits and nothing reads a
  thread id.
- Handing an object to another thread is legal once the current call has
  returned. The handoff itself must be serialized by the owner, for example by
  one owner per connection per worker, or by a lock the owner already holds.
  A refused call means the owner broke that rule, not that it should retry.

## Memory

Measured by the footprint leg of the interoperability matrix (see
[`validation.md`](validation.md)). The harness serves each connection from its
own `std.memory.secret` allocations, returns a finished handshake and its
buffers to their pool, and reads `/proc/self/pagemap`.

| state of one established TLS 1.3 connection | resident pages |
| --- | ---: |
| idle, after the handshake | 6 |
| after one request | 6 |
| after `stream.destroy` | 15 |

What remains in an idle connection is the stream's fixed state (1,240 bytes,
including both established records), its inline record region, and the two wire
buffers. The on-demand buffer work in #87 removes the last two.

A handshake in progress costs one pooled engine plus its storage, sized by the
limits:

- `max_peer_handshake_bytes` and `max_client_hello_bytes` default to 16 KiB
- `max_chain_bytes` defaults to 64 KiB, and a client's input must hold
  `config.certificate_message_bytes`
- `max_certificate_bytes` defaults to 16 KiB per entry

Every limit can be raised to the protocol maximum.
