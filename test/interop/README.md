# TLS client interoperability

This local harness connects to `127.0.0.1:9443`, authenticates
`api.example.com`, negotiates `h2`, exchanges application records in both
directions, verifies cancellation and deadline settlement, then performs
half-close and final close. It presents the checked-in client identity when requested.
The fixture private keys are test material only.

Build the harness:

```sh
mach dep pull test/interop
mach build test/interop
```

In one terminal, start a server. Run the harness in another terminal after each
server command:

```sh
test/interop/out/linux-x86_64/debug/bin/tls-client-interop
```

## OpenSSL

Basic Ed25519 authentication:

```sh
openssl s_server -accept 9443 \
  -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key \
  -tls1_3 -alpn h2 -rev -quiet
```

P-256 HelloRetryRequest:

```sh
openssl s_server -accept 9443 \
  -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key \
  -tls1_3 -alpn h2 -groups P-256 -rev -quiet
```

Force the other TLS 1.3 suites by running one command at a time:

```sh
openssl s_server -accept 9443 \
  -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key \
  -tls1_3 -alpn h2 \
  -ciphersuites TLS_AES_256_GCM_SHA384 -rev -quiet

openssl s_server -accept 9443 \
  -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key \
  -tls1_3 -alpn h2 \
  -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -rev -quiet
```

ECDSA P-256 and RSA-PSS server authentication:

```sh
openssl s_server -accept 9443 \
  -cert test/interop/fixtures/p256.pem \
  -key test/interop/fixtures/p256.key \
  -tls1_3 -alpn h2 -rev -quiet

openssl s_server -accept 9443 \
  -cert test/interop/fixtures/rsa.pem \
  -key test/interop/fixtures/rsa.key \
  -tls1_3 -alpn h2 -rev -quiet
```

Required and verified client authentication:

```sh
openssl s_server -accept 9443 \
  -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key \
  -tls1_3 -alpn h2 -Verify 1 -verify_return_error \
  -CAfile test/interop/fixtures/root.pem -rev -quiet
```

## GnuTLS

Required client authentication and TLS 1.3:

```sh
gnutls-serv --port 9443 \
  --x509certfile test/interop/fixtures/leaf.pem \
  --x509keyfile test/interop/fixtures/leaf.key \
  --x509cafile test/interop/fixtures/root.pem \
  --priority 'NORMAL:-VERS-ALL:+VERS-TLS1.3' \
  --alpn h2 --alpn-fatal --require-client-cert --verify-client-cert --echo
```

The qualification recorded for this revision passed with OpenSSL 3.6.3 and
GnuTLS 3.8.13. Every command above returned exit status zero from the Mach
harness. Each run exchanged the `mach-tls inter` application line and a server
response before half-close. Both servers also verified the required client
certificate to the checked-in root.

# TLS 1.3 server interoperability

`tls-server-interop` listens on `127.0.0.1:9443`, accepts one connection, runs
the TLS 1.3 server handshake, reads one application line, writes
`mach-tls server`, half-closes, and closes. It prints the negotiated suite,
group, retry count, and SNI host name, then `ok`. It exits non-zero on any
failure, so every command below is its own assertion.

Options:

- `--port N` listen elsewhere
- `--identity ed25519|p256|rsa` choose the credential served for `api.example.com`
- `--suite 1|2|3` restrict to AES-128-GCM, AES-256-GCM, or ChaCha20-Poly1305
- `--groups-p256` offer only P-256, forcing HelloRetryRequest for an X25519 client
- `--require-client-auth` request and verify a client certificate to `root.pem`
- `--optional-alpn` accept a client that offers no matching protocol
- `--no-default` register no default credential, so an unknown SNI is refused
- `--rotate` rotate the credential generation while the connection is established
- `--expect-failure N` require the handshake to fail with alert `N`

Build both harnesses:

```sh
mach dep pull test/interop
mach build test/interop
```

Start the server in one terminal and run the client command in another. The
server exits after one connection.

```sh
test/interop/out/linux-x86_64/debug/bin/tls-server-interop [options]
```

## OpenSSL clients

Ed25519 credential, X25519, AES-128-GCM, SNI and ALPN:

```sh
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem \
  -alpn h2 -tls1_3 -quiet -verify_return_error
```

HelloRetryRequest, with the server offering only P-256:

```sh
# server: --groups-p256
```

The other two cipher suites, one server run each:

```sh
# server: --suite 2
# server: --suite 3
```

ECDSA P-256 and RSA-PSS credentials:

```sh
# server: --identity p256
# server: --identity rsa
```

SNI selection. The exact name serves `server-alt.pem` and the unmatched name
falls to the wildcard `server-wild.pem`; `-verify_hostname` fails unless the
right certificate was chosen:

```sh
openssl s_client -connect 127.0.0.1:9443 -servername alt.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet \
  -verify_return_error -verify_hostname alt.example.com

openssl s_client -connect 127.0.0.1:9443 -servername foo.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet \
  -verify_return_error -verify_hostname foo.example.com
```

Required and verified client authentication:

```sh
# server: --require-client-auth
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet \
  -verify_return_error \
  -cert test/interop/fixtures/client.pem -key test/interop/fixtures/client.key
```

Credential rotation while the connection is established. The server rotates
after the handshake and before the application exchange. Because a completed
connection holds no lease, it asserts that the retired generation is already
reclaimable while the connection is open. It then completes the exchange and
asserts the generation is still reclaimable once the connection is destroyed:

```sh
# server: --rotate
```

## GnuTLS client

```sh
gnutls-cli --port 9443 127.0.0.1 \
  --x509cafile test/interop/fixtures/server-root.pem \
  --priority 'NORMAL:-VERS-ALL:+VERS-TLS1.3' \
  --alpn h2 --sni-hostname api.example.com --verify-hostname api.example.com
```

## Protocol-correct rejection

Each of these requires the server to fail with the named alert. The server exits
zero only when the alert matches.

```sh
# server: --expect-failure 70        protocol_version
openssl s_client -connect 127.0.0.1:9443 \
  -CAfile test/interop/fixtures/server-root.pem -tls1_2 -quiet

# server: --expect-failure 70        protocol_version
gnutls-cli --port 9443 127.0.0.1 \
  --x509cafile test/interop/fixtures/server-root.pem \
  --priority 'NORMAL:-VERS-ALL:+VERS-TLS1.2' --insecure

# server: --expect-failure 120       no_application_protocol
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h3 -tls1_3 -quiet

# server: --no-default --expect-failure 112   unrecognized_name
openssl s_client -connect 127.0.0.1:9443 -servername nowhere.invalid \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet

# server: --require-client-auth --expect-failure 116   certificate_required
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet
```

## Server fixtures

The `server-*` fixtures are test material only and are signed by
`server-root.pem`, whose private key is deliberately not checked in. Regenerate
the family with:

```sh
openssl genpkey -algorithm ED25519 -out server-root.key
openssl req -new -x509 -key server-root.key -out server-root.pem -days 3650 \
  -subj "/CN=MachTLSServerRoot" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

# for each <name>/<san>/<algorithm> below
openssl genpkey -algorithm ED25519 -out <name>.key
openssl req -new -key <name>.key -out <name>.csr -subj "/CN=<san>"
openssl x509 -req -in <name>.csr -CA server-root.pem -CAkey server-root.key \
  -CAcreateserial -out <name>.pem -days 3650 -copy_extensions copy \
  -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:<san>\n")
```

| fixture | subject alternative name | key |
| --- | --- | --- |
| `server-ed25519` | `api.example.com` | Ed25519 |
| `server-p256` | `api.example.com` | ECDSA P-256 |
| `p384` | `api.example.com` | ECDSA P-384, verification-only peer fixture |
| `p384-chain` | `api.example.com` | P-256 leaf signed by the P-384 test root |
| `server-rsa` | `api.example.com` | RSA 2048 |
| `server-alt` | `alt.example.com` | Ed25519 |
| `server-wild` | `*.example.com` | Ed25519 |
| `server-rotated` | `api.example.com` | Ed25519 |

The client trust store for `--require-client-auth` is the existing `root.pem`,
which signs `client.pem`.

## Qualification for this revision

Every command in this file returned exit status zero from the Mach harness
against OpenSSL 3.6.3 and GnuTLS 3.8.13 on linux-x86_64: eight client legs and
seventeen server legs. The server legs cover SNI exact, wildcard, and default
selection, ALPN, all three TLS 1.3 cipher suites, X25519 and P-256 including
HelloRetryRequest, Ed25519, ECDSA P-256 and RSA-PSS credentials, required client
authentication, credential rotation during an established connection, and five
protocol-correct rejections.

Browser interoperability is not covered here. This machine has no browser
harness, so the browser criterion is exercised only through the OpenSSL and
GnuTLS clients above.

# Session resumption and key updates

## Resumption against our server

`--tickets N` issues `N` session tickets per connection and enables resumption.
`--connections N` accepts `N` connections in sequence so the second one can
resume. `--single-use` requires each ticket identity to be presented only once.
`--handshake-only` tears down every connection but the last without an
application exchange, which is what `gnutls-cli --resume` expects.

OpenSSL saving and reusing a session:

```sh
# server: --tickets 2 --connections 2
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet \
  -verify_return_error -sess_out /tmp/sess.pem     # prints resumed=0

openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_3 -quiet \
  -verify_return_error -sess_in /tmp/sess.pem      # prints resumed=1
```

Presenting one ticket twice. Under `--single-use` the third connection prints
`resumed=0`; under the default policy it prints `resumed=1`:

```sh
# server: --tickets 1 --single-use --connections 3
# then -sess_out once and -sess_in twice with the same file
```

GnuTLS resuming:

```sh
# server: --tickets 2 --connections 2 --handshake-only
gnutls-cli --port 9443 127.0.0.1 \
  --x509cafile test/interop/fixtures/server-root.pem \
  --priority 'NORMAL:-VERS-ALL:+VERS-TLS1.3' --alpn h2 \
  --sni-hostname api.example.com --verify-hostname api.example.com --resume
```

GnuTLS reports `*** This is a resumed session` and the server prints
`resumed=1` for the second connection.

## Resumption from our client

`tls-client-interop` accepts `--sessions` to retain tickets in a bounded store
and `--connections N` to dial that many times, reusing the store.

```sh
openssl s_server -accept 9443 -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key -tls1_3 -alpn h2 -rev -quiet

test/interop/out/linux-x86_64/debug/bin/tls-client-interop --sessions --connections 2
```

The second connection prints `resumed=1`.

## Key updates

Both harnesses accept `--key-update`, which performs a post-handshake key update
after the first application read and then continues the exchange on the new
keys. A peer that mishandles the update fails the leg.

```sh
# server: --key-update, driven by either the OpenSSL or the GnuTLS client above
# client: --key-update, driven by openssl s_server above
```

## Full duplex

The client harness accepts `--duplex`. It then connects through the bundled
`transport.make_tcp` adapter over `std.net.async` instead of the blocking test
transport, and after the regular exchange it writes 1 MiB in one operation
while reads run beside it. The peer echoes as it reads, so a client that could
not read until its write finished would stall once both socket buffers filled.
The leg requires every echoed byte to match, and requires at least one read to
settle while the write still had a lower write in flight. It then half-closes
and closes through the adapter's graceful close.

```sh
# client: --duplex, and --tls12 --duplex, driven by openssl s_server -rev above
# client: --duplex, driven by gnutls-serv --echo above
```

## Qualification for the session revision

Against OpenSSL 3.6.3 and GnuTLS 3.8.13 on linux-x86_64: nineteen
single-connection server legs, four resumption legs, and ten client legs all
returned exit status zero from the Mach harness. The resumption legs cover
OpenSSL saving and reusing a ticket issued by our server, a single-use policy
refusing the second presentation of one ticket while the permissive policy
accepts it, GnuTLS reporting a resumed session against our server, and our
client resuming against an OpenSSL server. Key updates were driven mid-session
in both directions against both peers.

# TLS 1.2

Both harnesses accept `--tls12`, which selects the TLS 1.2 engine. The server
also accepts `--dual-version`, which declares TLS 1.3 support on the listener so
it marks its ServerHello random and refuses `TLS_FALLBACK_SCSV`.

## Our TLS 1.2 server

```sh
# server: --tls12
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_2 -quiet \
  -verify_return_error
```

The credential type and the suite are selected with the same flags as the
TLS 1.3 legs, and the cipher is forced from the client:

```sh
# server: --tls12 --identity p256      -> 0xC02B
# server: --tls12 --identity rsa       -> 0xC02F
# add -cipher ECDHE-ECDSA-AES256-GCM-SHA384      -> 0xC02C
# add -cipher ECDHE-ECDSA-CHACHA20-POLY1305      -> 0xCCA9
# server: --tls12 --identity rsa, add -cipher ECDHE-RSA-AES256-GCM-SHA384   -> 0xC030
# server: --tls12 --identity rsa, add -cipher ECDHE-RSA-CHACHA20-POLY1305   -> 0xCCA8
# server: --tls12 --groups-p256        -> group 23
```

GnuTLS:

```sh
# server: --tls12
gnutls-cli --port 9443 127.0.0.1 \
  --x509cafile test/interop/fixtures/server-root.pem \
  --priority 'NORMAL:-VERS-ALL:+VERS-TLS1.2' --alpn h2 \
  --sni-hostname api.example.com --verify-hostname api.example.com
```

## Downgrade protection

```sh
# server: --tls12 --dual-version --expect-failure 86   inappropriate_fallback
openssl s_client -connect 127.0.0.1:9443 -servername api.example.com \
  -CAfile test/interop/fixtures/server-root.pem -alpn h2 -tls1_2 -quiet \
  -fallback_scsv

# server: --tls12 --dual-version    a plain 1.2 client is still served

# server: (no --tls12) --expect-failure 70   protocol_version
openssl s_client -connect 127.0.0.1:9443 \
  -CAfile test/interop/fixtures/server-root.pem -tls1_2 -quiet
```

The last one is the criterion that TLS 1.2 cannot weaken a listener configured
for TLS 1.3 only: the TLS 1.3 server refuses the connection outright.

## Our TLS 1.2 client

```sh
openssl s_server -accept 9443 -cert test/interop/fixtures/leaf.pem \
  -key test/interop/fixtures/leaf.key -tls1_2 -alpn h2 -rev -quiet

test/interop/out/linux-x86_64/debug/bin/tls-client-interop --tls12
```

The same client leg is run against the `p256` and `rsa` server credentials,
against `-cipher ECDHE-ECDSA-AES256-GCM-SHA384` and
`-cipher ECDHE-ECDSA-CHACHA20-POLY1305`, and against `gnutls-serv` restricted to
TLS 1.2. Pointed at a TLS 1.3 only `openssl s_server`, it fails, which is the
client half of the same criterion.

## Qualification for the TLS 1.2 revision

Against OpenSSL 3.6.3 and GnuTLS 3.8.13 on linux-x86_64: 13 TLS 1.2 server legs
and 7 TLS 1.2 client legs returned exit status zero, and the TLS 1.2 client
against a TLS 1.3 only server failed as required. The TLS 1.3 legs above were
re-run unchanged: 19 server legs, 11 client legs, and 4 resumption legs, all
zero. The client counts include the two P-384 verification legs.

# Running the whole matrix

```sh
mach dep pull test/interop
mach dep update test/interop tls
mach build test/interop
./test/interop/run.sh
```

`mach dep update test/interop tls` refreshes the harness's copy of the library.
`mach dep pull` alone keeps a copy taken earlier.

The footprint leg serves four TLS 1.3 connections with `--footprint` and bounds
the resident pages of the last connection, its stream, engine and held buffers,
idle and after destroy (see
[`../../doc/validation.md`](../../doc/validation.md)):

```sh
# server: --footprint --connections 4
```

The runner executes every leg above, prints a pass or FAILED line per leg,
prints the peer versions and the release evidence, and exits non-zero naming any
leg that failed. It is the qualification record for a revision, and it is the
only place the legs are written down once rather than pasted twice.

The qualification recorded for this revision is 58 legs passed, 0 failed,
against OpenSSL 3.6.3 and GnuTLS 3.8.13 on linux-x86_64.

What the matrix does not cover is written down in
[`../../doc/validation.md`](../../doc/validation.md).
