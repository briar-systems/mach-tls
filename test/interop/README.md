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
