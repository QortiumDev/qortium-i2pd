#!/usr/bin/env bash
#
# Build a fully-static, portable i2pd binary for Linux inside an Alpine (musl)
# container, so the result has no glibc / distro dependency and runs anywhere.
#
# Pins the upstream version, verifies the tag's GPG signature against r4sas, and
# writes the binary + sha256 to out/linux-<arch>/. Mirrors the output contract in
# README.md so Qortium Home can download + verify it like Core / the JRE.
#
# Usage:
#   ./build/build-linux.sh                 # build pinned version for host arch
#   I2PD_VERSION=2.60.0 ./build/build-linux.sh
#   SKIP_GPG=1 ./build/build-linux.sh      # local spike only — skips verification
#
set -euo pipefail

I2PD_VERSION="${I2PD_VERSION:-2.60.0}"
I2PD_REPO="https://github.com/PurpleI2P/i2pd.git"
R4SAS_KEY_ID="66F6C87B98EBCFE2"            # long key id; full fp confirmed on import
R4SAS_KEY_URL="https://repo.i2pd.xyz/r4sas.gpg"
ALPINE_IMAGE="alpine:3.20"
SKIP_GPG="${SKIP_GPG:-0}"

ARCH="$(uname -m)"                          # x86_64 on this host
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${REPO_ROOT}/out/linux-${ARCH}"
mkdir -p "$OUTDIR"

echo ">> Building i2pd ${I2PD_VERSION} (static, musl) for linux-${ARCH}"
echo ">> Output: ${OUTDIR}"

# The whole build runs in the container. Single-quoted heredoc: expansions happen
# inside the container, not on the host. Pinned values are passed via -e.
docker run -i --rm \
  -e I2PD_VERSION="$I2PD_VERSION" \
  -e I2PD_REPO="$I2PD_REPO" \
  -e R4SAS_KEY_ID="$R4SAS_KEY_ID" \
  -e R4SAS_KEY_URL="$R4SAS_KEY_URL" \
  -e SKIP_GPG="$SKIP_GPG" \
  -v "$OUTDIR":/out \
  "$ALPINE_IMAGE" sh -eux <<'BUILD'
  apk add --no-cache \
    build-base make cmake git gnupg ca-certificates wget \
    boost-dev boost-static \
    openssl-dev openssl-libs-static \
    zlib-dev zlib-static

  cd /tmp
  git clone "$I2PD_REPO" i2pd
  cd i2pd
  git checkout "tags/${I2PD_VERSION}"

  # Verify the tag signature unless explicitly skipped.
  if [ "$SKIP_GPG" = "1" ]; then
    echo "!! WARNING: SKIP_GPG=1 — NOT verifying the i2pd source signature."
  else
    wget -qO /tmp/r4sas.gpg "$R4SAS_KEY_URL"
    gpg --import /tmp/r4sas.gpg
    gpg --fingerprint "$R4SAS_KEY_ID"
    # Aborts (set -e) if the tag is unsigned or the signature does not verify.
    git tag -v "${I2PD_VERSION}"
  fi

  # Fully static build via CMake. The Makefile's USE_STATIC path hardcodes
  # Debian-multiarch lib locations that don't exist on Alpine/musl; CMake
  # (WITH_STATIC) discovers the static Boost/OpenSSL/zlib properly. Drop UPnP —
  # not needed for the SAM fallback path.
  cd build
  cmake -DWITH_STATIC=ON -DWITH_UPNP=OFF .
  make -j"$(nproc)"
  strip i2pd

  cp i2pd /out/i2pd
  cd /out
  sha256sum i2pd > i2pd.sha256
BUILD

echo ">> Build complete. Verifying portability:"
file "${OUTDIR}/i2pd" || true
echo ">> ldd (expect 'not a dynamic executable' for a fully-static binary):"
ldd "${OUTDIR}/i2pd" 2>&1 || true
echo ">> sha256:"
cat "${OUTDIR}/i2pd.sha256"
