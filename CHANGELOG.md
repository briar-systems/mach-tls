# Changelog

## [Unreleased]

tls builds on mach-std 7.0.2 and mach-crypto 0.20.0, selected by version range (#126). Its own public surface is unchanged.

### Changed

- Dependencies: `[dep.std] version = "^7.0"` realized at v7.0.2 and `[dep.crypto] version = "^0.20"` at v0.20.0, both committed as gitlinks, and test/interop's tag pins moved with them. std 7.0.0 makes `io.runtime.make(runtime, a, initial)` take the allocator the runtime draws from and keep a copy of it. The library never builds a runtime, so the 28 sites are all test code: `src/test/transport.mach` and the interop client and server each hold one module-level page allocator and hand it to every runtime they make. `data.toml.Value` grew and the page, testing and arena allocators honour `align`, neither of which tls observes. crypto 0.20.0 moves its std range to `^7.0` and changes no API tls calls (#126).
- The TLS 1.2 handshake holds one role's configuration snapshot, a tag of `ClientConfig` or `ServerConfig` selected at `init_client` or `init_server`, instead of a copy of both. The role's pointer aliases the tag payload, so every read goes through the same path as before. `$size_of(tls12.connection.Handshake)` drops from 4,384 to 4,176 bytes on x86_64-linux, and behaviour is unchanged (#107).

## [0.9.0] - 2026-09-19

tls builds on mach-std 6.0.0 and mach-crypto 0.18.0, selected by version range, on mach 5.9 (#121). Its own public surface is unchanged.

### Changed

- Dependencies: `[dep.std] version = "^6.0"` realized at v6.0.0 and `[dep.crypto] version = "^0.18"` at v0.18.0, both committed as gitlinks, and `mach = "^5.9"`. std 6.0.0 removed the width-named constant-time comparisons and made `buffers.open_account` take a `buffers.Budgets` value; the two tls sites moved (`ct.is_zero[u8]` in the record layer, the test pool's account open). Nothing else std's migration guide names (sort, heap, map, set, the clock, `Source` members) is used here. crypto 0.14 through 0.18 changed no API tls calls: SHA-2 runs on std's hardware-dispatched states, secret word products use the processor multiply where mach admits it, and x25519 and Ed25519 compute on `u128`, so an x25519 + ECDSA P-256 handshake costs about a third of the instructions it did on crypto 0.13 (#121).
- On aarch64-linux and aarch64-darwin, a program linking tls turns PSTATE.DIT on before `main` and refuses to start, with status 255, on a processor or kernel without the mode. This is crypto 0.17's DIT-required start through std 5.8; x86_64 and riscv64 are unaffected (#121).
- `test/interop` pins std and crypto by tag itself, because a path dependency carries no pin for a dependency it selects by version and that tree is not committed (#121).
- CI passes `dit: required` to the shared pipeline, so the aarch64 legs test under `qemu-aarch64 -cpu max` on a runner without FEAT_DIT and natively where it exists (#121).
- The tag-triggered workflow is `.github/workflows/cd.yml`, the family's name for it, and it serializes runs per tag so a duplicate tag push waits and then finds the release already published (#117, #119).

## [0.8.1] - 2026-09-17

The bundled TCP adapter now closes correctly, and the interoperability matrix runs full-duplex traffic over it against OpenSSL and GnuTLS (#113).

### Fixed

- A stream closed through `transport.make_tcp` with `lifecycle.GRACEFUL` never settled its close and never released the socket. std's graceful stream close only shuts the write side down, and its completion was refused as the wrong kind. A graceful close now releases the socket, so the kernel sends what is queued and then a FIN (#113).
- `lifecycle.ABORTIVE` and the adapter's abort were plain closes. They now set a zero linger first, so the peer sees a reset (#113).

### Added

- Full-duplex client legs in the interoperability matrix: over the bundled async TCP adapter, a 1 MiB write runs while reads run beside it, against OpenSSL (TLS 1.3 and 1.2) and GnuTLS (TLS 1.3). Each leg requires the echo to match and at least one read to settle while a lower write is in flight (#113).

## [0.8.0] - 2026-09-17

Engines read wall and monotonic time from a caller clock source when they need it, and every in-process interval runs on the monotonic clock (#102). A stream carries one read and one write at once (#103).

### Breaking

- Time comes from a clock source (#102):
  - `config.ClientConfig.clock` and `config.ServerConfig.clock` are required. They name a caller-owned `clock.Source`, shared across connections. `clock.system()` reads the process clocks, and `clock.frozen` answers with a moment the caller controls. `read_fn` must not call into tls, must not block, and must be safe under the entrant gate.
  - `client.start`, `server.start` and `tls12.connection.start` take no time.
  - `stream.handshake`, `connect`, `connect_tls12`, `serve` and `serve_tls12` drop their time argument.
  - `verify.Options.now` is a `time.Time`.
  - Session: `keyring_init`, `keyring_rotate`, `seal` and `open` take `clock.Moment`. `keyring_openable` and `client_store_take` take `time.Instant`. `replay_admit` takes `time.Time`. `State.issued_at` is a `time.Time`, `Ticket.received_at` is a `time.Instant`, and `Ticket` gains `age_milliseconds`.
  - A clock read that fails during a handshake fails it with `internal_error`. When a ticket arrives, a failed read drops that ticket and counts it in the new `engine.Snapshot.ticket_clock_failures`.
- A stream carries one read and one write at once (#103):
  - The lower transport must accept a read and a write submitted concurrently. The bundled TCP adapter does.
  - `stream.destroy_operation(stream, token)` takes the token of the operation to release.
  - `stream.Snapshot.operation` is replaced by `read` and `write`, and the snapshot gains `failure`.
  - `Stream.operation`, `pending_action`, `transport` and `lower_transport` are replaced by `reading`, `writing` and `lower`.
  - The handshake, `alert` and `close` are refused while a read is outstanding. `half_close` and `key_update` need only the write lane.
  - A lane that fails the stream leaves the other lane's lower action in flight. That action is accounted when it completes, then resolves with the stream's failure. A `FAILED` stream must be closed, and `close` on it is allowed while a read is outstanding. See `doc/client.md`.
  - `transport.begin_action` takes a `*transport.Provider` from `transport.pin`. `Operation.provider` is a `*Provider`, and `Operation.provider_owner` is removed.

### Fixed

- A resuming client sent `obfuscated_ticket_age = 0`. It now sends the ticket's age in milliseconds, measured on the monotonic clock from receipt, plus `age_add`, modulo 2^32 (RFC 8446 4.2.11) (#102).
- Ticket-key rotation and overlap followed the wall clock, so a wall-clock step could rotate keys early or stretch the overlap. They now run on the monotonic clock (#102).

### Changed

- `stream.Stream` is 1,864 bytes, up from 1,704. An idle connection is still one resident page (#103).
- `transport.Operation` is 208 bytes, down from 280 (#103).

## [0.7.1] - 2026-09-17

A cancelled, timed-out or failed completion now keeps the transfer it reports. From mach-std 5.3.0 on, every backend reports that transfer (#104).

### Fixed

- A cancelled, timed-out or failed read lost the end of stream its completion reported. The next read then made one more lower read before it resolved as `CLOSED`. No bytes were lost: a cancelled read's bytes already reached the record layer in 0.7.0 and earlier (#104).
- A write cancelled or timed out after its whole record had gone out made the stream `FAILED` and reported 0 application bytes, although the peer had the record. It now settles the record: the bytes count and the stream stays `OPEN`. A write cancelled with a record partly sent still fails the stream (#104).
  - Before mach-std 5.3.0 the runtime itself reported 0 bytes for such a write, so tls and std gave the same wrong answer. The bytes arrive only from 5.3.0 on. tls did not silently lose data in earlier releases.
- A completion's transfer is bounded by the submitted length however the request ended. A larger one resolves as `INTERNAL_ERROR` and is not counted (#104).

### Embedders: audit retry-on-timeout paths

Before this release, a write that was cancelled or timed out reported `application_bytes == 0` even when its record had reached the peer. A caller that trusted that count and retried the payload, on the same stream or a new connection, could deliver it twice at the application layer. Review any code that retries writes after a cancellation or timeout. From 0.7.1 on, `application_bytes` counts every record the peer was sent in full.

### Changed

- Requires mach-std v5.3.0 and mach-crypto v0.13.2, and the mach 5.3 compiler (`mach = "^5.3"`) (#104).
- `transport.advance` also accepts a terminal operation, so the owner can count the transfer of the completion that ended it. This widens what the call accepts, and nothing that worked before changes (#104).

## [0.7.0] - 2026-09-17

An idle established TLS 1.3 connection now takes 1 resident page and holds no buffer, down from 6 pages. Every variable-size buffer comes from the caller's `std.memory.buffers` pool when it is needed and goes back when it is not (#98).

### Breaking

- Requires mach-std v5.0.1 and mach-crypto v0.13.1 (#98).
- Handshake engines, established records and the Stream take their memory from the caller's buffer pool. `client.Storage`, `server.Storage`, `tls12.connection.Storage` and `stream.Storage` are removed, and so is the Stream's inline secret region and `stream.SECRET_STORAGE_BYTES` (#98):
  - `client.init`, `server.init`, `server.init_with_credential_selector`, `tls12.connection.init_client` and `init_server` take a `buffer.Lease`.
  - `stream.init_client`, `init_server`, `init_tls12_client`, `init_tls12_server`, `connect`, `connect_tls12`, `serve` and `serve_tls12` take a `buffer.Lease` and a `buffer.SecretLease` on the same account.
  - `client.finish`, `server.finish` and `tls12.connection.finish` take no storage.
  - The caller opens one account per connection and closes it after the connection is destroyed. tls never opens an account. See `doc/memory.md`.
- A call short of memory returns the new `engine.WAITING`, with nothing consumed and nothing changed. The caller repeats it once the pool reports the account ready. A budget or misuse refusal fails the connection with `RESOURCE_LIMIT` (#98).
- A Stream operation short of memory parks instead of failing. Call `stream.resume` when the pool reports the account ready. A parked operation still settles as `CANCELLED` or `TIMEOUT` through `stream.accept` (#98).
- Behaviour change: an application write that is cancelled or times out between records, for example while parked for memory, now leaves the stream `OPEN`. Before 0.7.0 any cancelled or timed-out write failed the stream. A write cancelled with a sealed record partly unsent still fails it (#98).

### Added

- `tls.buffer`: `Lease`, `SecretLease`, and the reservation outcomes (`HELD`, `WAIT`, `FAIL`) over `std.memory.buffers` sources (#98).
- `engine.WAITING`, `stream.resume`, `stream.READ_START` and `transport.TRANSPORT_WAIT` (#98).
- `doc/memory.md`: the lease contract, the recommended class shape, waiting for memory, and the footprint (#98).

### Changed

- The Stream reads with a 512-byte buffer and grows it only to what a record header announces. Before encryption starts, a record header asking for more than the plaintext limit is refused at once (#98).
- Handshake input grows only to the largest message actually received (#98).
- The footprint leg serves each connection from its own pool account, requires every chunk back before the account closes, and bounds a connection at 3 pages idle and after destroy (#98).
- Tests and the interoperability harness use `Instant` deadlines and clocks (#98).

## [0.6.0] - 2026-09-17

### Breaking

- The engines are renamed: `server.Server` is `server.Handshake`, `client.Client` is `client.Handshake`, and `tls12.connection.Connection` is `tls12.connection.Handshake` (#92).
- A call that finds another call in progress on the same engine, established record or Stream is refused instead of made to wait. It returns `false`, or `FAILED` with `ILLEGAL_PARAMETER`. Each object has one owner at a time, and handing it to another thread is legal only once the current call has returned. See `doc/established.md` (#92).
- The default limits are much smaller. Ten thousand concurrent handshakes need a few hundred MiB of storage instead of about 11 GiB (#92):

  | limit | 0.5.2 | 0.6.0 |
  | --- | ---: | ---: |
  | `max_peer_handshake_bytes` | 1 MiB | 16 KiB |
  | `max_client_hello_bytes` | 64 KiB | 16 KiB |
  | `max_chain_bytes` | 512 KiB | 64 KiB |
  | `max_certificate_bytes` (new) | none | 16 KiB |

  To accept larger peers, set the field on `config.Limits` before `init`. Every limit can be raised to the protocol maximum:
  - `max_peer_handshake_bytes` now bounds every incoming message except Certificate. Raise it for large extensions or large CertificateRequest authority lists.
  - `max_chain_bytes` bounds a Certificate message through `config.certificate_message_bytes(limits)`. Raise it for long chains. A client's `Storage.input`, and a server's when it may require client authentication, must hold `certificate_message_bytes`.
  - `max_certificate_bytes` bounds each chain entry, and a larger entry fails with `BAD_CERTIFICATE`. Raise it for certificates with very large SAN lists or keys.
  - `max_client_hello_bytes` bounds the retained ClientHello. Raise it for clients that send large PSK or post-quantum key shares.
- A server that requires client authentication from input too small for `certificate_message_bytes` fails the handshake with `RESOURCE_LIMIT` (#92).
- The exporter master secret is no longer kept after the handshake. Set `retain_exporter` on the client or server configuration to keep `export_keying_material` working on an established connection (#92).
- `stream.Storage` has a third region, `ticket_input`. A TLS 1.3 client with a session store must size it for `max_ticket_bytes` plus a handshake header, or tickets are skipped (#92).

### Added

- Established records: `tls13.established.Established` (464 bytes) and `tls12.established.Established` (88 bytes). When the last handshake event is accepted, the engine moves the application state into its embedded record and wipes or releases everything else. `server.finish`, `client.finish` and `tls12.connection.finish` move that record out and return the engine to its destroyed state, ready for `init` or a pool (#92).
- `tls.stream` finishes its engine into its own established record when the completed handshake operation is destroyed. From then on it no longer borrows the engine (#92).
- `config.certificate_message_bytes`, `config.Limits.max_certificate_bytes` and `retain_exporter` (#92).
- Secret-level key schedule operations in `tls13.key_schedule` (#92).

### Changed

- An idle `next_event` costs one compare-and-swap, about 21 ns, down from 435 ns (#92).
- An idle established TLS 1.3 connection in the footprint leg holds 6 resident pages, down from 9, and 15 after destroy, down from 18. The leg now bounds them at 8 and 17 (#92).
- NewSessionTicket is accepted before or after `finish`. A client's ticket input is sized for a whole ticket message (#92).
- The license is attributed to Briar Systems LLC (#93).

## [0.5.2] - 2026-09-17

### Changed

- An idle `next_event` checks for a pending event before it walks the borrowed configuration, storage and callback descriptors. With nothing queued it no longer costs O(ALPN entries + trust anchors + chain) (#88).
- Every engine and Stream call enters through one shared guard (`tls.transition`). The guard wakes a sleeping thread only when one is waiting, so an uncontended call no longer makes a futex syscall. An idle `next_event` goes from about 1.2 µs to 0.4 µs in a debug build (#88).
- A protected handshake record is revealed over its own consumed ciphertext. The Stream no longer zero-fills a 16,639-byte buffer for every handshake-type record, post-handshake ones included (#88).
- Once the last handshake event is accepted, the engines wipe what an established connection never reads again (#88):
  - the transcript
  - the server's resumed PSK state
  - the client's offered ticket
  - the TLS 1.2 PRF secrets
- Once the last handshake event is accepted, the server and the TLS 1.2 engine also release their credential lease. A rotated generation becomes reclaimable as soon as the handshakes that used it finish, instead of when their connections close (#88).

### Added

- `--footprint` in the interoperability server, and a footprint leg in the matrix (#88):
  - Each connection is served from its own `std.memory.secret` region.
  - The leg reports resident pages per region and the cost of an idle `next_event`.
  - It bounds one connection at 11 pages idle and 20 after destroy. The measured baseline is 9 and 18.

## [0.5.1] - 2026-09-17

### Changed

- Dependencies: mach-crypto v0.12.0 (#83). X25519 key derivation takes 3.6x fewer instructions and Ed25519 signing 4.0x fewer, so every handshake does less key-share and certificate-signature work.

## [0.5.0] - 2026-09-16

### Changed

- Dependencies: mach-std v4.0.1 and mach-crypto v0.11.0 (#77). Consumers now resolve std 4.0.1 or later, which requires mach 5.2.0 or later.
- A transport refusal is built with `io.error.make`: an invalid submission reports kind `INVALID` with code 0 rather than a borrowed `EINVAL`. `transport.map_error` still classifies by kind, so the tls error a caller sees is unchanged.

## [0.4.1] - 2026-09-16

### Changed

- Dependencies: mach-std v3.2.0 and mach-crypto v0.10.1 (#73). Consumers now resolve std 3.2.0 or later, which carries the Windows owner-only permission security fix.

## [0.4.0] - 2026-09-16

### Changed

- Dependencies: mach-std v3.1.0 and mach-crypto v0.10.0 (#69). Consumers now resolve std 3.1.0 or later. The transport runs on the std 3 io runtime, whose tables grow on demand, so a submission past the runtime's initial size grows it instead of being refused, and a `RESOURCE_LIMIT` from the transport now means the allocator refused.
- CI is the shared family pipeline (#64): a pull request into `dev` runs linux x86_64, and a pull request into `main` also runs native aarch64 linux, x86_64 windows and both darwin hosts. The interoperability matrix runs on linux x86_64 in both tiers.
- The source tree and the interoperability harness are formatted with mach 5.1.0 (#64, #67).

## [0.3.1] - 2026-09-15

### Changed

- Dependencies: mach-crypto v0.9.1. A TLS 1.3 handshake and every record now run on the reworked AES-GCM, P-256 and curve25519 arithmetic, which removes the handshake and per-record costs reported in #56.
- The transport tests are part of the root test set (#61).

## [0.3.0] - 2026-09-13

### Changed

- Migrated to mach 5.0 and std 2.0.0 (#57): every fallible or absent outcome is a `res`, `opt` or `err` tag, `:^` is the typed `:>T` strip, the manifest is on the 5.0 schema and the dependency pins are the committed gitlinks under `dep/`.
- Dependencies: mach-crypto v0.9.0.
- The interoperability harness opens its fixture root in place and reads the std 2.0 clock as a result.


### Fixed

- A client that sends no ALPN extension is served instead of refused with
  `no_application_protocol`. RFC 7301 section 3.2 reserves that alert for a
  client that advertised protocols and matched none; `require_alpn` answered
  both cases, because the absence of the extension and an offer that matched
  nothing both left the selection empty. A client that advertises nothing now
  negotiates nothing and the handshake continues, on TLS 1.3 and TLS 1.2
  alike. An offer that matched nothing still gets the alert.

### Added

- `engine.Snapshot.peer_offered_alpn`, which says whether the peer sent an
  ALPN extension at all. An empty `selected_alpn` no longer has two meanings:
  with this false the peer asked for nothing, with it true the peer's offer
  was not covered. A server that cannot serve without ALPN uses this to refuse
  on its own terms rather than having the library guess for it.
- `--expect-absent-alpn` in the interoperability server harness, which holds a
  listener that configures `require_alpn` to serving a client that offers
  none, and asserts the snapshot reports it as having offered nothing. Two
  legs drive it with `openssl s_client` and no `-alpn`, one per version.

## [0.2.4] - 2026-09-05

### Removed

- `tools/partial_literal_sweep.py`. It enumerated record literals naming fewer
  fields than their record declares, which is a workaround for
  briar-systems/mach#3108; that defect is being fixed in the compiler. The rule
  itself still holds, and the `no_*` constructors are what keep it.

### Added

- GitHub Actions CI: every pull request builds the library, runs the suite in both profiles and the transport project, runs the OpenSSL and GnuTLS interoperability matrix, and verifies IR across all six targets.

### Changed

- Dependencies: mach-crypto v0.8.2.

## [0.2.3] - 2026-09-02

### Fixed

- `server.destroy` and `client.destroy` clear every per-handshake field, so an
  engine initialised again on the same record starts from the declared zero
  state. Previously the traffic-secret generations survived, and a second
  handshake on a reused record emitted its HANDSHAKE secret at generation 2,
  which mach-quic's handshake adapter rejects.

## [0.2.2] - 2026-09-01

### Changed

- `mach-crypto` advances to `v0.8.1`, adopting the wiped deallocation retry
  contract so every secret owner release observes zeroed storage.

## [0.2.1] - 2026-09-01

### Changed

- `mach-std` advances to `v0.34.0` and `mach-crypto` advances to `v0.8.0`,
  keeping downstream consumers on one compatible typed-allocation stack.

## [0.2.0] - 2026-08-31

### Added

- An ALPN-aware TLS 1.3 server credential selector with stable transient
  credential stores and an exact, transactional RFC 8737 challenge contract.
- Verification-only ECDSA P-384 with SHA-384 for certificate paths and TLS 1.2
  and TLS 1.3 peer signatures.

### Changed

- `mach-crypto` advances to `v0.7.0` for strict P-384 public-key parsing and
  signature verification.
- TLS 1.3 signature policy supports five peer-verification schemes while P-384
  remains unavailable for local signing and key exchange.

### Fixed

- Ticket-key rotation refuses a full live ring instead of shortening a live
  ticket's configured overlap.
- Maximum-size CertificateRequest signature policies use a derived bound and
  reject undersized output before writing.
