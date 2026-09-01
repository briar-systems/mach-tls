# Changelog

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
