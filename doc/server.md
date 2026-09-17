# TLS 1.3 server ownership

`tls.server` is the transport-independent TLS 1.3 server handshake engine.
It publishes the same event contract as `tls.client`, defined once in
`tls.engine`, so `tls.stream` drives either role over the same records and the
same completion-based transport.

## The engine contract

`tls.engine` owns the encryption levels, directions, event kinds, statuses, the
`Event` and `Snapshot` records, and the one map from protocol failure to alert.
Every role implements the same operations:

- `start` arms the engine and fixes the certificate verification time
- `ingest` accepts complete or fragmented handshake bytes at one level
- `poll` advances the engine without new peer input
- `next_event` publishes one borrowed event; `complete_event` releases it
- `traffic_keys` derives the record key and IV for the borrowed secret event
- `close` queues one terminal alert
- `snapshot` reports negotiated parameters and status
- `aliases_borrowed` and `aliases_configuration` answer ownership queries

An engine is caller-owned. `tls.stream` borrows one through `init_client`,
`init_server`, `connect`, or `serve`, and never destroys it. The engine must
outlive the stream, and `stream.destroy` leaves it untouched so the owner can
inspect the negotiated result and then destroy it.

Engines carry secret state, so the language forbids erasing them to an untyped
pointer. The stream therefore holds one typed pointer per role and dispatches
over a closed set. Adding a role adds one pointer and one branch per operation;
it does not change the contract or the record layer.

## Configuration and bounds

`server.init` snapshots the `config.ServerConfig`, its entropy descriptor, and
its bounded arrays. The credential store, ALPN names, version, suite, group, and
signature arrays remain immutable caller-owned borrows for the lifetime of the
engine. The configuration requires one TLS 1.3 version, one to three cipher
suites, one or two groups, one to five signature schemes, an initialized
credential store, an operating-system or application entropy source, and
explicit finite limits.

Client authentication policy is not part of the listener configuration. It
belongs to the published credential generation, together with the trust store it
is checked against, so one rotation changes both at once and a connection cannot
observe a policy that never existed.

`max_peer_handshake_bytes` bounds one incoming frame including its header.
`max_client_hello_bytes` bounds the retained ClientHello, `max_client_flight_bytes`
the client authentication flight, and `max_server_flight_bytes` the generated
EncryptedExtensions through Finished. `max_chain_bytes` applies to both the
presented client chain and the served certificate chain. `server.storage_requirements`
reports the exact ServerHello and flight output a configuration needs, so a
caller sizes `Storage.output` from policy rather than by guessing.

`server.Storage` holds all variable-size handshake state and is caller-owned.
The input, output, ClientHello retention, peer certificate array, and optional
peer-extension regions must be representable and mutually disjoint, and none of
them may overlap the engine record, the configuration, or the entropy callback
context.

## Handshake

`server.start` generates the server random and proves it is not the
HelloRetryRequest sentinel. `ingest` at `INITIAL` accepts the ClientHello.

1. The ClientHello is decoded, its extensions validated for structure,
   placement, uniqueness, and ordering, and TLS 1.3 confirmed in
   `supported_versions`.
2. The SNI host name and complete offered-ALPN list are extracted before a
   credential lease is acquired. `server.init_with_credential_selector` may
   inspect both through one borrowed `CredentialOffer` and its typed
   caller-owned transient `credentials.Store`. It leases through
   `credentials.acquire`; returning `UNSUPPORTED` falls through to the
   configured published store. The default `server.init` path selects that
   store generation by SNI. Exact names outrank the longest matching wildcard,
   which outranks the configured default. A name with no match and no default
   fails with `unrecognized_name`.
3. The lease fixes the certificate, the private key, the client-authentication
   requirement, and the client trust store for the whole connection.
4. Negotiation selects a suite, a group, a signature scheme compatible with the
   leased private key, and an application protocol, proving every selection was
   offered by the client.
5. A group that was offered but carries no key share produces one
   HelloRetryRequest. The retried ClientHello must repeat every extension
   unchanged except the key share, cookie, and pre-shared-key group, and must
   carry exactly one share for the requested group.
6. ServerHello publishes the selected suite, the echoed legacy session id, and
   the server key share. Handshake traffic secrets follow in both directions.
7. EncryptedExtensions, an optional CertificateRequest, Certificate,
   CertificateVerify, and Finished are produced as one flight under one exact
   transcript, and the server application traffic secret follows it.
8. The client flight is verified: an optional certificate path for client
   authentication, its CertificateVerify, and Finished. The client application
   traffic secret, the authentication disposition, and completion follow.
9. Post-handshake KeyUpdate is processed and answered.

Events are published from one bounded ordered queue, so interleaved flights and
secret transitions have one explicit order rather than an inferred one. The
queue is cleared and replaced by a single alert on failure.

## Certificate selection and rotation

A connection acquires exactly one credential lease and holds it for as long as
its handshake can still read the generation. When the last handshake event is
accepted the engine releases the lease, together with the transcript and the
resumed PSK, because nothing an established connection does reads them again.
`credentials.rotate` retires the published generation and installs a
replacement. The retired generation keeps every live lease valid and does not
report itself reclaimable until the last lease is released. A handshake in
progress therefore keeps the certificate, chain, private key, client trust
store, and client-authentication requirement it started with, and a rotation
cannot alter any of them mid-handshake. An established connection pins no
generation. The caller may reclaim the retired arrays and keys only after
`credentials.reclaimable` returns true.

`credentials.initialize_tls_alpn_challenge` creates the one-identity,
one-certificate transient generation RFC 8737 requires. It accepts the
critical `acmeIdentifier` extension only through `x509.parse_tls_alpn_challenge`
and only after proving the key matches and the SAN contains exactly one
non-wildcard `dNSName` equal case-insensitively to the validation name. Ordinary
`x509.parse`, normal generation initialization, and all client verification
continue to reject unknown critical extensions. A selector must choose this
generation only when `server.offered_alpn_exactly` confirms the current
ClientHello offers `acme-tls/1` and no other ALPN protocol. The generic selector
still receives the complete list and may use `offered_alpn_contains` for other
selection policies. Its owner initializes one stable caller-owned Store
with `credentials.initialize_vacant_store`, publishes each challenge with
`publish_store`, leases it with `acquire`, then calls `withdraw_store` before
reclaiming it after the final transient lease is released. Publication,
selection, and withdrawal synchronize through that Store without replacing
its lock while a selector may be entering it.

## Failure

Invalid ClientHello variants fail closed with one protocol-correct alert and
bounded work. A terminal engine accepts no further peer input.

| Condition | Error | Alert |
| --- | --- | --- |
| unknown handshake type, wrong state, wrong level | `UNEXPECTED_MESSAGE` | `unexpected_message` |
| `supported_versions` absent or without TLS 1.3 | `PROTOCOL_VERSION` | `protocol_version` |
| no key share and no usable pre-shared key | `MISSING_EXTENSION` | `missing_extension` |
| malformed, duplicated, or misplaced extensions | `ILLEGAL_PARAMETER` | `illegal_parameter` |
| key share for a group that was not offered | `ILLEGAL_PARAMETER` | `illegal_parameter` |
| legacy version or compression method wrong | `ILLEGAL_PARAMETER` | `illegal_parameter` |
| no suite, group, or signature in common | `HANDSHAKE_FAILURE` | `handshake_failure` |
| no application protocol in common | `NO_APPLICATION_PROTOCOL` | `no_application_protocol` |
| SNI with no credential and no default | `UNRECOGNIZED_NAME` | `unrecognized_name` |
| client authentication required, none presented | `CERTIFICATE_REQUIRED` | `certificate_required` |
| client chain fails path validation | `BAD_CERTIFICATE` / `UNKNOWN_CA` | matching certificate alert |
| declared body above the configured bound | `RESOURCE_LIMIT` | `internal_error` |

A ClientHello may fragment at every byte. Each incomplete prefix reports the
exact next requirement, publishes no event, and changes no handshake state.

## Validation

Unit coverage drives the server against `tls.client` in process through a
complete authenticated handshake and compares both application traffic secrets
byte for byte. A malformed-hello corpus asserts the exact error and alert for
every row of the table above, that every truncation prefix reports a requirement
without publishing state, and that a terminal engine refuses further input.

The external harness performs real TCP handshakes against OpenSSL and GnuTLS
clients covering SNI selection, wildcard selection, ALPN, all three cipher
suites, X25519 and P-256 including HelloRetryRequest, Ed25519, ECDSA P-256,
verification-only ECDSA P-384 peer authentication, and RSA-PSS credentials,
required client authentication, credential rotation during an established
connection, and the negotiation failures above. See
[`../test/interop/README.md`](../test/interop/README.md).
