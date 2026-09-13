# Changelog

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
