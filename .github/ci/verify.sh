#!/usr/bin/env bash
set -euo pipefail

# the client and server matrix against OpenSSL and GnuTLS. the harness is linux-x86_64 only
case "$MACH_CI_LEG" in
  x86_64-linux) test/interop/run.sh ;;
esac

# counterfactual for #64, never merged
exit 1
