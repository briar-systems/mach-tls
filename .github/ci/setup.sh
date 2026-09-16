#!/usr/bin/env bash
set -euo pipefail

# gnutls-cli and gnutls-serv are half of the interop matrix. openssl and ss are on the image
case "$MACH_CI_LEG" in
  x86_64-linux)
    sudo apt-get update
    sudo apt-get install -y gnutls-bin
    ;;
esac
