# Certificates and credential generations

`tls.cert.x509` parses certificates without allocation. Every slice in a parsed certificate borrows the input DER and remains valid only while that input remains stable. Parsing rejects malformed DER, duplicate extensions, unknown critical extensions, invalid time forms, invalid names, mismatched inner and outer signature identifiers, noncanonical defaults, malformed key encodings, and invalid extension placement.

## Supported certificate keys and signatures

Subject public keys support Ed25519, P-256, and RSA with 2048 through 4096-bit moduli. Certificate signatures support Ed25519, ECDSA P-256 with SHA-256, RSA-PSS with SHA-256 or SHA-384, and RSA PKCS #1 v1.5 with SHA-256 or SHA-384 when provided by the pinned `mach-crypto` release. RSA-PSS parameters must select the same supported hash for the message and MGF1 and must use a salt whose length equals the hash length.

A trust anchor's self-signature is not part of certification path validation. `parse_trust_anchor` therefore accepts an otherwise valid anchor whose outer self-signature algorithm is not supported. Every non-anchor certificate still requires a supported signature algorithm.

## Path validation

`tls.cert.verify.chain` accepts a leaf-first presented set. Intermediates after the leaf may be unordered. The builder backtracks across issuer candidates and trust anchors up to `MAX_CHAIN_DEPTH`, rejects duplicate presented certificates, checks authority and subject key identifiers when both exist, and authenticates each selected link before publishing success.

Validation checks the leaf purpose and every intermediate's extended key usage. TLS 1.3 leaf certificates with a key usage extension must permit digital signatures. Intermediates must carry a critical CA basic constraint and, when key usage is present, `keyCertSign`. Path length excludes the leaf and self-issued rollover certificates as required by RFC 5280.

DNS, IP, and directory name constraints are processed for every applicable subordinate certificate. Excluded subtrees always win. A constrained name form that this package cannot process causes rejection when that form appears in a subordinate certificate. Self-issued intermediates are exempt from name constraints, while the final leaf is never exempt.

The trust anchor certificate's validity, extensions, and self-signature are not processed as path members. Its subject and public key identify the configured trust anchor.

## Identity matching

Server identity verification requires `subjectAltName`. Common-name fallback is not supported.

DNS reference names and presented names use strict ASCII preferred-name syntax. One trailing root dot is normalized. A wildcard is valid only as the complete leftmost label and matches exactly one reference label. Partial-label wildcards and broad two-label wildcard names are rejected.

IPv4 text rejects leading zeroes. IPv6 accepts full, compressed, and embedded IPv4 forms. Zone identifiers and bracketed literals are not certificate identities. Parsed address bytes must exactly match a four-byte or sixteen-byte `iPAddress` entry.

Distinguished names compare exact encodings first. PrintableString and ASCII UTF8String values also receive case folding, leading and trailing space removal, and internal space compression. Valid non-ASCII UTF8String values match exact encodings and otherwise fail closed.

## Loading

`tls.cert.load.certificate_der` validates one borrowed DER certificate.

`tls.cert.load.certificate_pem` decodes one `CERTIFICATE` block into caller-owned public storage. `tls.cert.load.chain_pem` accepts one or more adjacent `CERTIFICATE` blocks separated only by ASCII whitespace. It measures and validates the complete bundle before publishing the output chain. Input and output storage must not overlap.

`tls.cert.load.private_der` loads PKCS #8, SEC 1, or RSA PKCS #1 DER into an owned `crypto.encoding.keys.PrivateKey`. `tls.cert.load.private_pem` accepts `PRIVATE KEY`, `EC PRIVATE KEY`, and `RSA PRIVATE KEY` labels. The caller owns the returned key and must destroy it through `crypto.encoding.keys.destroy_private`.

## Generation ownership

A `Generation` and every identity, certificate byte array, trust anchor array, and private key reachable from it must have stable storage from `initialize` until `clear` succeeds. The caller must not copy a generation or mutate any reachable data after initialization.

Initialization validates every certificate, every trust anchor, every SNI pattern, and every leaf-to-private-key binding. A generation begins in the ready state. `initialize_store` or `rotate` publishes it exactly once.

`acquire` returns a lease and selects identities in this order:

1. exact SNI match
2. the longest valid leftmost-wildcard match
3. the explicitly configured default identity

IP literals and malformed host names are never valid SNI inputs. An empty SNI may select only the explicit default.

`rotate` publishes the replacement and retires the previous generation while holding the store lock. Existing leases continue to reference the retired generation. New leases can reference only the replacement. `reclaimable` becomes true only after retirement and release of every lease.

`acquire_client_trust` leases the same immutable generation and returns its client-auth trust store and required-or-optional policy together. This prevents a handshake from observing trust anchors from one generation and authentication policy from another.

`retire_store` prevents new acquisitions and returns the final retired generation. Call `clear` only after `reclaimable` succeeds, then destroy the private keys and release the public storage owned by the application.
