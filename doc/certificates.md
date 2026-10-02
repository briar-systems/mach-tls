# Certificates and credential generations

X.509 comes from [mach-pki](https://github.com/briar-systems/mach-pki): `pki.cert` holds the borrowed certificate, chain and trust store handles, `pki.x509` parses certificates, `pki.name` matches DNS and IP identities, `pki.load` loads DER and PEM certificates, chains and private keys, and `pki.verify` validates certification paths. Its README describes parsing, the supported keys and signatures, path validation, identity matching and loading. This page covers what tls adds on top.

## Peer validation

Every handshake path, the TLS 1.3 client and server and both TLS 1.2 roles, validates a peer chain the same way. It bounds the presented certificates by `verify.MAX_CHAIN_DEPTH` and the configured byte limits, then calls `verify.chain` with `verify.MAX_SIGNATURE_CHECKS` and the configured clock. A server certificate is validated for `verify.server_auth()` and a client certificate for `verify.client_auth()`, so a leaf with a key usage extension must permit digital signatures and the leaf and every intermediate carrying an extended key usage must list the purpose. Once the path validates, a client checks the leaf against its configured server name with `verify.identity`, which requires `subjectAltName` and never falls back to the common name.

A path failure reaches the peer as the alert of its `tls.error` code:

| `verify.Error` | `tls.error` | alert |
|---|---|---|
| `CERTIFICATE_EXPIRED` | `CERTIFICATE_EXPIRED` | `certificate_expired` |
| `UNKNOWN_CA` | `UNKNOWN_CA` | `unknown_ca` |
| `UNSUPPORTED_ALGORITHM` | `UNSUPPORTED_ALGORITHM` | `handshake_failure` |
| `BAD_CERTIFICATE`, `BAD_SIGNATURE`, `RESOURCE_LIMIT`, `INVALID_INPUT` | `BAD_CERTIFICATE` | `bad_certificate` |

A leaf that does not hold the server name fails with `HOSTNAME_MISMATCH`, which is also `bad_certificate`.

P-384 is verification-only. The package does not load a P-384 private key, select P-384 for local signing, or expose a P-384 key-share group.

## TLS-ALPN-01 challenges

`tls.cert.credentials.parse_tls_alpn_challenge` parses an RFC 8737 challenge certificate with `x509.parse_with`, naming the `acmeIdentifier` extension as one it handles. The extension must be critical and hold a 32-byte digest, and the certificate must carry exactly one subject alternative name, a non-wildcard DNS name. On failure the output is left untouched. `tls_alpn_challenge_name_matches` checks that name against the validation name. `initialize_tls_alpn_challenge` is the only path that accepts such a certificate as a credential: every other parse refuses its critical extension.

## Trust anchor bundles

`tls.cert.bundle` reads a PEM CA bundle, such as `/etc/ssl/certs/ca-certificates.crt`, into a `cert.TrustStore` for `config.ClientConfig.trust`. `parse` reads bytes into caller storage that `measure` sizes. `load` reads a file into memory from a `std.allocator.Allocator`, which `release` returns after the trust store's last use. Text outside a block is ignored, so the comment lines distributions write between certificates are accepted. A block opens with a line starting `-----BEGIN ` and closes with the next line starting `-----END `.

Every block becomes an anchor or a `Skip` naming its index, byte range, reason and the underlying error. The reasons are `MALFORMED_PEM` (framing or base64 the PEM codec refuses, or a block that never closes), `NOT_A_CERTIFICATE`, `MALFORMED_CERTIFICATE` (the X.509 parser refuses it), `UNSUPPORTED` (a key or form this build cannot represent), and `DUPLICATE`. Anchors are parsed with `parse_trust_anchor`. A bundle with no usable anchor returns `NO_ANCHORS` with its skips. A bundle over `MAX_BYTES` (1 MiB), `MAX_BLOCKS` (1,024 blocks), or `MAX_ANCHORS` (the client's `MAX_TRUST_ANCHORS`) is refused whole with `TOO_LARGE`, never truncated.

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
