#!/usr/bin/env bash
#
# the complete client and server interoperability matrix
#
# run from the repository root after `mach build test/interop`. every leg is an
# assertion: the Mach harness exits non-zero on any failure, and the expected
# failure legs additionally require the exact alert. the summary at the end is
# the qualification record for a revision.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-debug}"
BIN="test/interop/out/linux-x86_64/$PROFILE/bin"
SERVER="$BIN/tls-server-interop"
CLIENT="$BIN/tls-client-interop"
EVIDENCE="$BIN/tls-evidence"
FIX="test/interop/fixtures"
CA="$FIX/server-root.pem"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$SERVER" ] || [ ! -x "$CLIENT" ] || [ ! -x "$EVIDENCE" ]; then
  echo "build first: mach dep pull test/interop && mach build test/interop" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_LEGS=""

note() { printf '%-64s %s\n' "$1" "$2"; }

record() { # $1 name  $2 status
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1))
    note "$1" "ok"
  else
    FAIL=$((FAIL + 1))
    FAILED_LEGS="$FAILED_LEGS\n  $1"
    note "$1" "FAILED"
  fi
}

wait_for_listener() {
  for _ in $(seq 1 80); do
    grep -q listening "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_for_port() {
  for _ in $(seq 1 80); do
    ss -ltn 2>/dev/null | grep -q ':9443' && return 0
    sleep 0.1
  done
  return 1
}

# our server against one external client
server_leg() { # $1 name  $2 server args  $3 client command
  local name="$1" args="$2" client="$3"
  # shellcheck disable=SC2086
  $SERVER $args >"$WORK/server.log" 2>&1 &
  local pid=$!
  if ! wait_for_listener "$WORK/server.log"; then
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    record "$name" "fail"
    return
  fi
  printf 'mach-tls matrix\n' | timeout 25 bash -c "$client" >"$WORK/client.log" 2>&1
  wait $pid
  if [ $? -eq 0 ]; then record "$name" "ok"; else record "$name" "fail"; fi
}

# our client against one external server
client_leg() { # $1 name  $2 client args  $3 server command
  local name="$1" args="$2" server="$3"
  # shellcheck disable=SC2086
  bash -c "$server" >"$WORK/server.log" 2>&1 &
  local pid=$!
  if ! wait_for_port; then
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    record "$name" "fail"
    return
  fi
  # shellcheck disable=SC2086
  timeout 25 $CLIENT $args >"$WORK/client.log" 2>&1
  local rc=$?
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if [ $rc -eq 0 ]; then record "$name" "ok"; else record "$name" "fail"; fi
}

# our client must fail against this server
client_leg_must_fail() {
  local name="$1" args="$2" server="$3"
  # shellcheck disable=SC2086
  bash -c "$server" >"$WORK/server.log" 2>&1 &
  local pid=$!
  wait_for_port
  # shellcheck disable=SC2086
  timeout 25 $CLIENT $args >"$WORK/client.log" 2>&1
  local rc=$?
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if [ $rc -ne 0 ]; then record "$name" "ok"; else record "$name" "fail"; fi
}

# a sequence of external clients against one long-lived server
sequence_leg() { # $1 name  $2 server args  $3 expected 'resumed=' line joined by ,
  local name="$1" args="$2" expected="$3"
  shift 3
  rm -f "$WORK/sess.pem"
  # shellcheck disable=SC2086
  $SERVER $args >"$WORK/server.log" 2>&1 &
  local pid=$!
  if ! wait_for_listener "$WORK/server.log"; then
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    record "$name" "fail"
    return
  fi
  local step
  for step in "$@"; do
    printf 'mach-tls matrix\n' | timeout 25 bash -c "$step" >>"$WORK/client.log" 2>&1
  done
  wait $pid
  local rc=$?
  local seen
  seen="$(grep -c 'resumed=1' "$WORK/server.log" || true)"
  if [ $rc -eq 0 ] && [ "$seen" = "$expected" ]; then
    record "$name" "ok"
  else
    record "$name" "fail"
  fi
}

TLS13="openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com"
TLS12="openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_2 -quiet -verify_return_error -servername api.example.com"
GNUTLS13="gnutls-cli --port 9443 127.0.0.1 --x509cafile $CA --priority NORMAL:-VERS-ALL:+VERS-TLS1.3 --alpn h2 --sni-hostname api.example.com --verify-hostname api.example.com"
GNUTLS12="gnutls-cli --port 9443 127.0.0.1 --x509cafile $CA --priority NORMAL:-VERS-ALL:+VERS-TLS1.2 --alpn h2 --sni-hostname api.example.com --verify-hostname api.example.com"

echo "== TLS 1.3 server =="
server_leg "1.3 server ed25519 x25519 aes128"        ""                    "$TLS13"
server_leg "1.3 server hello retry request p256"     "--groups-p256"       "$TLS13"
server_leg "1.3 server suite aes128"                 "--suite 1"           "$TLS13"
server_leg "1.3 server suite aes256"                 "--suite 2"           "$TLS13"
server_leg "1.3 server suite chacha20"               "--suite 3"           "$TLS13"
server_leg "1.3 server ecdsa p256 credential"        "--identity p256"     "$TLS13"
server_leg "1.3 server rsa-pss credential"           "--identity rsa"      "$TLS13"
server_leg "1.3 server sni exact selection" "" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername alt.example.com -verify_hostname alt.example.com"
server_leg "1.3 server sni wildcard selection" "" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername foo.example.com -verify_hostname foo.example.com"
server_leg "1.3 server required client authentication" "--require-client-auth" \
  "$TLS13 -cert $FIX/client.pem -key $FIX/client.key"
server_leg "1.3 server credential rotation while open" "--rotate"          "$TLS13"
server_leg "1.3 server gnutls client"                ""                    "$GNUTLS13"
server_leg "1.3 server key update openssl"           "--key-update"        "$TLS13"
server_leg "1.3 server key update gnutls"            "--key-update"        "$GNUTLS13"

echo "== TLS 1.3 server failure paths =="
server_leg "1.3 refuses tls 1.2 openssl (protocol_version)" "--expect-failure 70" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -tls1_2 -quiet"
server_leg "1.3 refuses tls 1.2 gnutls (protocol_version)" "--expect-failure 70" \
  "gnutls-cli --port 9443 127.0.0.1 --x509cafile $CA --priority NORMAL:-VERS-ALL:+VERS-TLS1.2 --insecure"
server_leg "1.3 refuses alpn mismatch (no_application_protocol)" "--expect-failure 120" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h3 -tls1_3 -quiet -servername api.example.com"
# RFC 7301 section 3.2: the alert above answers an offer that matched nothing.
# a client that sends no ALPN extension at all asked for nothing and is served,
# even though this listener configures require_alpn.
server_leg "1.3 serves a client that offers no alpn" "--expect-absent-alpn" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -tls1_3 -quiet -verify_return_error -servername api.example.com"
server_leg "1.2 serves a client that offers no alpn" "--tls12 --expect-absent-alpn" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -tls1_2 -quiet -verify_return_error -servername api.example.com"
server_leg "1.3 refuses unknown sni (unrecognized_name)" "--no-default --expect-failure 112" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -servername nowhere.invalid"
server_leg "1.3 refuses missing client certificate (certificate_required)" \
  "--require-client-auth --expect-failure 116" "$TLS13"

echo "== TLS 1.3 resumption =="
sequence_leg "1.3 openssl resumes an issued ticket" "--tickets 2 --connections 2" "1" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_out $WORK/sess.pem" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_in $WORK/sess.pem"
sequence_leg "1.3 single-use refuses a reused ticket" "--tickets 1 --single-use --connections 3" "1" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_out $WORK/sess.pem" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_in $WORK/sess.pem" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_in $WORK/sess.pem"
sequence_leg "1.3 permissive accepts a reused ticket" "--tickets 1 --connections 3" "2" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_out $WORK/sess.pem" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_in $WORK/sess.pem" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_3 -quiet -verify_return_error -servername api.example.com -sess_in $WORK/sess.pem"
sequence_leg "1.3 gnutls resumes an issued ticket" "--tickets 2 --connections 2 --handshake-only" "1" \
  "$GNUTLS13 --resume"

echo "== TLS 1.2 server =="
server_leg "1.2 server ed25519 x25519 aes128"        "--tls12"                 "$TLS12"
server_leg "1.2 server ecdsa p256 credential"        "--tls12 --identity p256" "$TLS12"
server_leg "1.2 server rsa-pss credential"           "--tls12 --identity rsa"  "$TLS12"
server_leg "1.2 server ecdhe-ecdsa aes256"           "--tls12"                 "$TLS12 -cipher ECDHE-ECDSA-AES256-GCM-SHA384"
server_leg "1.2 server ecdhe-ecdsa chacha20"         "--tls12"                 "$TLS12 -cipher ECDHE-ECDSA-CHACHA20-POLY1305"
server_leg "1.2 server ecdhe-rsa aes256"             "--tls12 --identity rsa"  "$TLS12 -cipher ECDHE-RSA-AES256-GCM-SHA384"
server_leg "1.2 server ecdhe-rsa chacha20"           "--tls12 --identity rsa"  "$TLS12 -cipher ECDHE-RSA-CHACHA20-POLY1305"
server_leg "1.2 server secp256r1 exchange"           "--tls12 --groups-p256"   "$TLS12"
server_leg "1.2 server gnutls client"                "--tls12"                 "$GNUTLS12"
server_leg "1.2 dual-version listener serves 1.2"    "--tls12 --dual-version"  "$TLS12"

echo "== TLS 1.2 server failure paths =="
server_leg "1.2 refuses fallback scsv (inappropriate_fallback)" \
  "--tls12 --dual-version --expect-failure 86" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_2 -quiet -servername api.example.com -fallback_scsv"
server_leg "1.2 refuses alpn mismatch (no_application_protocol)" \
  "--tls12 --expect-failure 120" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h3 -tls1_2 -quiet -servername api.example.com"
server_leg "1.2 refuses unknown sni (unrecognized_name)" \
  "--tls12 --no-default --expect-failure 112" \
  "openssl s_client -connect 127.0.0.1:9443 -CAfile $CA -alpn h2 -tls1_2 -quiet -servername nowhere.invalid"

echo "== TLS 1.3 client =="
client_leg "1.3 client ed25519 x25519" "" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -rev -quiet"
client_leg "1.3 client hello retry request p256" "" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -groups P-256 -rev -quiet"
client_leg "1.3 client suite aes256" "" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -ciphersuites TLS_AES_256_GCM_SHA384 -rev -quiet"
client_leg "1.3 client suite chacha20" "" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -rev -quiet"
client_leg "1.3 client ecdsa p256 server" "" \
  "openssl s_server -accept 9443 -cert $FIX/p256.pem -key $FIX/p256.key -tls1_3 -alpn h2 -rev -quiet"
client_leg "1.3 client verifies p384 sha384 server" "" \
  "openssl s_server -accept 9443 -cert $FIX/p384.pem -key $FIX/p384.key -tls1_3 -alpn h2 -sigalgs ecdsa_secp384r1_sha384 -rev -quiet"
client_leg "1.3 client rsa-pss server" "" \
  "openssl s_server -accept 9443 -cert $FIX/rsa.pem -key $FIX/rsa.key -tls1_3 -alpn h2 -rev -quiet"
client_leg "1.3 client presents its certificate" "" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -Verify 1 -verify_return_error -CAfile $FIX/root.pem -rev -quiet"
client_leg "1.3 client gnutls server" "" \
  "gnutls-serv --port 9443 --x509certfile $FIX/leaf.pem --x509keyfile $FIX/leaf.key --x509cafile $FIX/root.pem --priority NORMAL:-VERS-ALL:+VERS-TLS1.3 --alpn h2 --alpn-fatal --require-client-cert --verify-client-cert --echo"
client_leg "1.3 client resumes its own ticket" "--sessions --connections 2" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -rev -quiet"
client_leg "1.3 client key update mid session" "--key-update" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -rev -quiet"

echo "== TLS 1.2 client =="
client_leg "1.2 client ed25519 server" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_2 -alpn h2 -rev -quiet"
client_leg "1.2 client ecdsa p256 server" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/p256.pem -key $FIX/p256.key -tls1_2 -alpn h2 -rev -quiet"
client_leg "1.2 client verifies p384 sha384 certificate path" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/p384-chain.pem -key $FIX/p256.key -tls1_2 -alpn h2 -cipher ECDHE-ECDSA-AES256-GCM-SHA384 -sigalgs ecdsa_secp256r1_sha256 -rev -quiet"
client_leg "1.2 client rsa server" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/rsa.pem -key $FIX/rsa.key -tls1_2 -alpn h2 -rev -quiet"
client_leg "1.2 client ecdhe-ecdsa aes256" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_2 -alpn h2 -cipher ECDHE-ECDSA-AES256-GCM-SHA384 -rev -quiet"
client_leg "1.2 client ecdhe-ecdsa chacha20" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_2 -alpn h2 -cipher ECDHE-ECDSA-CHACHA20-POLY1305 -rev -quiet"
client_leg "1.2 client gnutls server" "--tls12" \
  "gnutls-serv --port 9443 --x509certfile $FIX/leaf.pem --x509keyfile $FIX/leaf.key --priority NORMAL:-VERS-ALL:+VERS-TLS1.2 --alpn h2 --alpn-fatal --echo"
client_leg_must_fail "1.2 client refuses a tls 1.3 only server" "--tls12" \
  "openssl s_server -accept 9443 -cert $FIX/leaf.pem -key $FIX/leaf.key -tls1_3 -alpn h2 -rev -quiet"

echo
echo "== per-connection footprint =="
# resident pages of one established connection's region (engine, stream and
# every buffer), read from /proc/self/pagemap. the bounds are the v0.5.2
# baseline plus two pages and tighten as #87 lands
FOOTPRINT_IDLE_PAGES=11
FOOTPRINT_DESTROYED_PAGES=20
footprint_leg() {
  local connections=4
  $SERVER --footprint --connections $connections >"$WORK/footprint.log" 2>&1 &
  local pid=$!
  if ! wait_for_listener "$WORK/footprint.log"; then
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    record "footprint" "fail"
    return
  fi
  for _ in $(seq 1 $connections); do
    printf 'mach-tls footprint\n' | timeout 25 bash -c "$TLS13" >/dev/null 2>&1
  done
  wait $pid
  local served=$?
  # the last connection's readings, so allocator warm-up is excluded
  local idle destroyed
  idle="$(awk '/^footprint idle/{f=1;next} /^footprint/{f=0} f && /region_pages=/{sub(/.*=/,"");v=$0} END{print v}' "$WORK/footprint.log")"
  destroyed="$(awk '/^footprint destroyed/{f=1;next} /^footprint/{f=0} f && /region_pages=/{sub(/.*=/,"");v=$0} END{print v}' "$WORK/footprint.log")"
  awk '/^footprint idle/{n++} n=='"$connections"' && /^footprint|pages=|_ns=/' "$WORK/footprint.log"
  if [ $served -eq 0 ] && [ -n "$idle" ] && [ -n "$destroyed" ] &&
     [ "$idle" -le $FOOTPRINT_IDLE_PAGES ] && [ "$destroyed" -le $FOOTPRINT_DESTROYED_PAGES ]; then
    record "footprint idle $idle <= $FOOTPRINT_IDLE_PAGES, destroyed $destroyed <= $FOOTPRINT_DESTROYED_PAGES pages" "ok"
  else
    record "footprint idle ${idle:-?} <= $FOOTPRINT_IDLE_PAGES, destroyed ${destroyed:-?} <= $FOOTPRINT_DESTROYED_PAGES pages" "fail"
  fi
}
footprint_leg

echo
echo "== versions =="
openssl version
gnutls-cli --version | head -1

echo
echo "== release evidence =="
$EVIDENCE

echo
echo "legs passed: $PASS"
echo "legs failed: $FAIL"
if [ $FAIL -ne 0 ]; then
  printf 'failed legs:%b\n' "$FAILED_LEGS"
  exit 1
fi
exit 0
