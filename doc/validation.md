# Validation gates

This package is validated by three things that run here, on any machine with
the compiler, OpenSSL, and GnuTLS: the unit suites, the fuzz lane, and the
interoperability matrix. This document says what each one covers and, just
as importantly, what it does not.

## Unit suites

```sh
mach test . --lib tests
mach test . --lib tests --profile release
tools/test-selection
```

mach tests only the closure of the selected artifact, and the library does not
reach `tls.test.transport`, the completion transport tests that drive a real
event loop. The test-only `tests` artifact (`src/lib/tests.mach`) reaches
the library and that module, so `mach test . --lib tests` covers every module in
`src`, while `mach test .` covers only what the library reaches.
`tools/test-selection` fails when a test declared under `src` is collected on no
manifest target, and CI runs it. The suite runs in the debug and release
profiles, because optimisation has already changed observable behaviour in this
codebase once.

## Fuzz lane

`test/fuzz` answers every untrusted-input entry point: the record layer, alert
decoding, handshake framing, the extension walk and each context's validation,
every TLS 1.3 and TLS 1.2 handshake message parser, and X.509 certificate
parsing. Each boundary has a harness and a directory of retained inputs in
`test/fuzz/corpus`. The property is that no peer byte sequence crashes a parser,
reads past its input, loops, or is accepted or refused wrongly:

- every input is parsed or refused with a typed error, and a refusal never
  carries `OK`
- every view a parse publishes lies inside the input, and each input ends on the
  last byte before an unreadable page, so a read one byte past it faults
- a framer never publishes a body outside its header's bounds and never asks for
  bytes it already holds
- an accepted hello is structurally exact, an accepted key-exchange point matches
  its curve and the signed prefix is the start of the message, a list that
  validates walks to its end, and a certificate chain walks to the count it
  reported
- every walk a harness drives is bounded by its input's length, and the replay
  runs under a timeout

The replay is deterministic and runs in both profiles on the heavy tier (a pull
request into `main`, or a dispatch with `heavy: fuzz`). The lane is built on
every pull request so it cannot rot. `fuzz mutate` is the on-demand search: a
seeded structural mutator over a boundary's corpus that writes findings and,
with `--retain`, adds a minimized input for each outcome the corpus does not
hold yet. [`test/fuzz/README.md`](../test/fuzz/README.md) has the commands.

The corpus replaces the seeded mutation corpora the unit suite used to run on
every build. Those checked the same invariants over a few thousand fresh
mutations each time. The lane keeps the inputs that reached a distinct answer,
replays them exactly, and leaves the search to a deliberate run.

## Negative corpora

`tls.server` carries a hand-written malformed-ClientHello
corpus that asserts the exact error and alert for each named condition
(`doc/server.md` has the table), that every truncation prefix of a valid hello
reports a requirement without publishing state, and that a terminal engine
refuses further input. `tls.record`, `tls.handshake`, `tls.handshake.codec`,
`tls.handshake.extensions`, `tls.cert.x509`, and `tls.cert.verify` each carry
their own hostile cases.

## Allocation failure, short I/O, and cancellation

`tls.cert.credentials` supplies a secret allocator that always fails and asserts that
private-key loading refuses cleanly, publishes no partial key, and that a
credential generation is never published from the result. The same input then
succeeds with the working allocator, so the refusal is attributable to the
allocator rather than to the input.

`test/transport` covers short I/O and cancellation against a scripted
transport: partial writes that retain application ownership until a whole
record settles, write cancellation that forces an abortive close, zero-byte
write completions that would otherwise allow sequence reuse, encrypted records
delivered one byte at a time, close_notify fully written before a write-side
shutdown, callback reentry, concurrent entry, and a provider descriptor that
mutates under an operation.

It also closes a loopback socket through the bundled TCP adapter in each close
mode and checks what the peer reads: a clean end of stream for a graceful close,
and a reset for an abortive one.

The interop client harness additionally performs a pre-cancelled read and a
pre-timed-out read against a live peer and requires the exact terminal error.

## Interoperability matrix

```sh
mach dep pull test/interop
mach dep update test/interop tls
mach build test/interop
./test/interop/run.sh
```

`test/interop` takes the library as a path dependency, and `mach dep pull` does
not refresh an existing path copy. Run `mach dep update test/interop tls` after
changing the library, or the harness builds against the copy taken earlier.

The runner executes every leg in `test/interop/README.md`, prints a pass or
FAILED line per leg, prints the peer versions and the release evidence, and
exits non-zero listing any leg that failed. Each leg is an assertion: the Mach
harness exits non-zero on any failure, and the expected-failure legs
additionally require the exact alert value.

The matrix covers, for both roles and both versions: cipher suites, groups
including HelloRetryRequest, credential types, SNI exact, wildcard, and default
selection, ALPN, client authentication, session resumption, ticket reuse under
both replay policies, credential rotation during a live connection, key updates
mid-session, downgrade protection, and the protocol-correct rejection of each
named failure. The client also runs a full-duplex exchange over the bundled
async TCP adapter, for both versions.

The footprint leg serves four TLS 1.3 connections with `--footprint`. Each
connection's stream and engine are separate `std.memory.secret` allocations,
and its buffers come from its own pool account. Once the handshake operation is
destroyed, the harness asserts that the stream finished its engine, then
returns the engine to its pool. The server reads `/proc/self/pagemap` and the
account's held bytes, and prints the resident pages of the stream and the
engine and the pages the held buffers cover: once idle after the handshake,
once after a request, and once after destroy. It also prints the cost of an
idle `next_event` on the established core. The leg fails when the last
connection's idle or destroyed pages exceed the bound in `run.sh`, which is the
measured one page plus two. Every connection in both roles must also return
every chunk before its account closes.

## Release evidence

`tls-evidence` prints the supported cipher suites, groups, signature schemes,
and bounds **from the same predicates the library uses to accept them**, and
fails if any declared value is not accepted or if a value outside the declared
set is. The table therefore cannot drift from the implementation. The runner
prints it at the end of every matrix run.

The target and profile matrix is the build itself:

```sh
mach build . --all-targets --profile debug --verify-ir
mach build . --all-targets --profile release --verify-ir
```

linux-x86_64, linux-arm64, linux-riscv64, windows-x86_64, darwin-x86_64, and
darwin-aarch64, at both profiles, with the IR verifier enabled.

## What interoperability legs structurally cannot cover

The matrix runs TLS over TCP against OpenSSL and GnuTLS. Neither is a QUIC
peer, so neither reads `quic_transport_parameters`, and to both of them the
extension is opaque passthrough. Nothing in the matrix depends on the event
that carries it existing at all.

That is not a hole to plug with more legs, it is a property of the peers. The
server's `PEER_PARAMETERS` event was never queued, its render arm in
`next_event` was unreachable, and the defect survived sixteen green server legs
and a full six-target release matrix before a QUIC consumer found it (#17).

The class is wider than that one event: **anything a consumer reaches through
the event stream rather than through the record stream is invisible to
TLS-over-TCP interop.** What closes it is driving both roles' engines against
each other in process with the consumer's configuration applied, asserting on
`next_event` delivery and ordering. `tls.client` and `tls.server` each carry
such a test for the transport-parameters event, and each fails if the queue
site is removed.

Two rules follow, for anyone extending this package:

- an event that only one role emits is a defect until proven otherwise, and the
  proof belongs in an in-process test of both roles, not in a new interop leg
- a `snapshot()` assertion is never sufficient evidence that an event is
  delivered. The snapshot for the transport parameters returned the right bytes
  the whole time the event did not exist

## Not covered here

These are real gaps, named so nobody has to discover them:

- **Coverage-guided fuzzing.** There is no libFuzzer, AFL, or equivalent
  coverage instrumentation available for Mach, and none was built. The fuzz
  lane's mutation is seeded, not coverage-guided, and it retains an input for a
  new answer rather than for new code: it will not discover a path that needs a
  specific 32-bit constant to reach, and two inputs that reach different code
  with the same answer count as one.
- **The engines under hostile input.** The fuzz lane drives the parsers. The
  handshake engines see malformed input through the negative corpora and the
  interop matrix's failure legs, not through the lane.
- **Multi-day sessions.** The longest session exercised is two key
  updates in each direction on one connection, plus ticket lifetimes checked
  against a controlled clock. No wall-clock long-running soak was performed.
- **Concurrency stress.** Rotation, leases, and the replay window are exercised
  interleaved with live connections but single-threaded, apart from the
  transport tests that spawn one contending thread. There is no multi-threaded
  rotation or resumption stress.
- **Browser interoperability.** There is no browser harness on this machine.
  Command-line OpenSSL and GnuTLS are the only external implementations used.
- **Differential output comparison.** Both roles are run against two independent
  implementations and against each other, and the TLS 1.2 PRF is checked against
  a published vector, but nothing compares our wire output byte for byte against
  another stack's for the same inputs.
- **QUIC-shaped peers in the interop matrix.** The in-process tests above cover
  the event surface a QUIC adapter binds to, but no external QUIC
  implementation is driven from this repository. mach-quic exercises it from
  the consumer side.
- **Native execution on non-x86_64 targets.** The other five targets are built
  and IR-verified but not run; this machine is linux-x86_64.
