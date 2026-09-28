# Memory

mach-tls owns no memory of its own. Every variable-size buffer a connection
needs comes from the caller's `std.memory.buffers` sources, when it is needed,
and goes back when it is not. An established connection with nothing in flight
holds no buffer at all.

## Leases

`tls.buffer.Lease` names a plain `buffers.Source`, the connection's
`buffers.Account` and a lane. `tls.buffer.SecretLease` names a
`buffers.SecretSource`, the same account and a lane.

- The caller opens exactly one account per connection, passes it in the
  leases, and closes it after the connection is destroyed. tls never opens or
  closes an account.
- tls charges the account on the lease's lane. A caller that wants to budget
  tls memory apart from its own gives tls a lane of its own.
- The engine and the Stream of one connection take the same account. The
  Stream refuses a `SecretLease` whose account differs from its `Lease`.
- The source, the account and every lease must outlive the connection, and
  must not lie inside the engine, the Stream or the transport's state.
- Key material and opened plaintext live only in chunks from the
  `SecretSource`, which wipes them on release.
- The `SecretSource` implements `fn_bind`, since a cipher's expanded key
  lives in a typed view of one of its chunks.

| taker | lease | memory |
| --- | --- | --- |
| `client.init`, `server.init`, `server.init_with_credential_selector` | `Lease` | handshake input, output, retained ClientHello, QUIC peer parameters |
| `tls12.connection.init_client`, `init_server` | `Lease` | handshake input, output, retained ClientHello |
| `tls13.established` (seeded by the engine) | the engine's `Lease` | one NewSessionTicket being assembled |
| `stream.init_*`, `connect*`, `serve*` | `Lease` and `SecretLease` | wire input and output, opened plaintext, sealing scratch, one context per keyed traffic direction |
| `session.keyring_init` | `SecretLease` | one context per live ticket key |

## Class shape

A request is served from the smallest class that fits, or from the pool's
oversize path. The recommended classes are 512 B, 4 KiB and 17,408 B (one
record), each plain and secret, and one secret class of
`record.CONTEXT_SIZE` bytes aligned to `record.CONTEXT_ALIGN`. With them:

- a Stream reads with a 512 B buffer and grows it to what a record header
  announces, never past `HEADER + max_receive_record_plaintext + 256`
- a record being written or opened takes one chunk sized for it and returns it
  when the record is done
- handshake buffers follow the handshake's actual messages, bounded by the
  limits in [`client.md`](client.md) and [`server.md`](server.md).
  `server.storage_requirements` reports the ServerHello and flight output a
  configuration needs
- a larger message, such as a long certificate chain, takes the oversize path
- an AES-GCM key's expanded context takes one chunk of the context class

## Cipher contexts

An AES-GCM traffic key is expanded once, into an `aes_gcm.Context`, and every
record runs against it. The context lives in a secret chunk, sized and aligned
from the context's own type, which `record.CONTEXT_SIZE` and
`record.CONTEXT_ALIGN` report. A backend with a larger context needs no change
here or in the caller's class shape.

- A Stream takes a direction's context at that direction's first AES-GCM key,
  keeps it through every later key (the handshake's application keys and each
  key update expand into the same chunk), and returns it wiped on
  `stream.destroy`. A Stream holds at most two, and none before its first key.
  ChaCha20-Poly1305 takes none.
- A context acquisition that must wait parks the operation as below. Only a
  direction's first key can wait, since later keys reuse its chunk.
- A `session.KeyRing` takes one context per ticket key as it mints the key, and
  returns it when the key expires or the ring is destroyed. A mint the source
  refuses fails without registering for a wake-up, and the caller rotates again
  later. The ring takes and returns chunks under its own lock, so its source is
  one the caller never enters concurrently from elsewhere.

## Waiting for memory

A refusal is either fatal or a wait.

- `budget` (the lane's own limit) and `misuse` fail the connection with
  `RESOURCE_LIMIT`.
- `exhausted` and `memory` register the account with the source for a wake-up.
  The call returns `engine.WAITING` with nothing consumed and nothing changed,
  and the caller repeats the same call, with the same bytes, once the source
  reports the account ready.

`WAITING` can come from `start`, `ingest` and `poll` on every engine, and from
`feed`, `ingest` and `poll` on the TLS 1.3 established record. `finish` refuses
with `INVALID_STATE` while a client still holds post-handshake bytes it could
not yet hand over.

### Stream

A Stream operation that must wait parks. It submits a scoped `USER_WAKE`
(`transport.TRANSPORT_WAIT`) and stays open:

- `stream.resume(stream)` completes the wake, and the retry arrives as an
  ordinary completion for `stream.accept`. It returns `false` when nothing is
  parked, so a stale wake is harmless.
- Cancellation and deadlines apply to a parked operation as to any other. It
  settles as `CANCELLED` or `TIMEOUT` through `stream.accept`.
- Waiting is bounded only by the operation's scope and deadline.
- An application write that parks before its next record is sealed ends at a
  record boundary. Cancelling it leaves the stream `OPEN`.
- A handshake message the engine cannot take yet stays in the wire buffer and
  is offered again, before anything else, when the operation resumes.
- `resume` wakes each lane parked for memory. When both are parked, the lane
  holding the turn retries first, and the other is woken again once it has
  acquired, so a single `resume` is enough (see
  [`client.md`](client.md#concurrent-read-and-write)).

`std.memory.buffers.ready` reports accounts, not callers. A wake for the
connection's account may be for tls or for the caller's own chunks on that
account. The caller resumes the Stream, or retries its pending engine call,
and retries its own work, whichever is waiting.

## Footprint

Measured by the footprint leg of the interoperability matrix (see
[`validation.md`](validation.md)). The harness serves each connection from its
own `std.memory.secret` region and its own account, and reads
`/proc/self/pagemap` and the account's held bytes.

| state of one established TLS 1.3 connection | resident pages | buffer bytes held |
| --- | ---: | ---: |
| idle, after the handshake | 2 | 2,112 |
| after one request | 2 | 2,112 |
| after `stream.destroy` | 1 | 0 |

On x86_64-linux the fixed part, `$size_of(stream.Stream)`, is 1,992 bytes with
both established records and both lanes included. Each live AES-GCM key adds
one borrowed context of 1,056 bytes (`record.CONTEXT_SIZE`), so an idle
established connection holds its Stream and two contexts. The fixed part is
still above the ≤ 1 KiB that the per-connection memory RFC (#87) targets. A
`session.KeyRing` is 560 bytes, plus one context per live ticket key.
