#!/usr/bin/env bash
set -euo pipefail

# every test under src is collected by `mach test . --lib tests` on some target.
# listing is target-independent work, so the primary leg carries it
if [[ "${MACH_CI_PRIMARY:-}" == true ]]; then
  tools/test-selection "$MACH_COMPILER"
fi

# the client and server matrix against OpenSSL and GnuTLS. the harness is linux-x86_64 only
case "$MACH_CI_LEG" in
  x86_64-linux) test/interop/run.sh ;;
esac
