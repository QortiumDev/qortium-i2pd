#!/usr/bin/env bash
#
# Build a static i2pd.exe for Windows x64 in an MSYS2 MINGW64 environment
# (the toolchain upstream uses for its win64 builds). Run from an MSYS2 MINGW64
# shell, or via msys2/setup-msys2 in CI.
#
# Authenticode signing is done at release time (needs a code-signing cert), not
# here; see the CI release job. Authenticity for Home's download comes from the
# GPG-verified source + the pinned SHA256.
#
# Usage (inside MINGW64 shell):
#   ./build/build-windows.sh
#
set -euo pipefail

I2PD_VERSION="${I2PD_VERSION:-2.60.0}"
I2PD_REPO="https://github.com/PurpleI2P/i2pd.git"
R4SAS_KEY_ID="66F6C87B98EBCFE2"
R4SAS_KEY_URL="https://repo.i2pd.xyz/r4sas.gpg"
SKIP_GPG="${SKIP_GPG:-0}"

ARCH="x64"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${REPO_ROOT}/out/windows-${ARCH}"
mkdir -p "$OUTDIR"

echo ">> Building i2pd ${I2PD_VERSION} for windows-${ARCH} (MSYS2 MINGW64)"

pacman -S --noconfirm --needed \
  git \
  mingw-w64-x86_64-gcc \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-make \
  mingw-w64-x86_64-boost \
  mingw-w64-x86_64-openssl \
  mingw-w64-x86_64-zlib \
  gnupg

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone "$I2PD_REPO" "$WORK/i2pd"
cd "$WORK/i2pd"
git checkout "tags/${I2PD_VERSION}"

if [ "$SKIP_GPG" = "1" ]; then
  echo "!! WARNING: SKIP_GPG=1 — NOT verifying the i2pd source signature."
else
  curl -fsSL "$R4SAS_KEY_URL" -o "$WORK/r4sas.gpg"
  gpg --import "$WORK/r4sas.gpg"
  gpg --fingerprint "$R4SAS_KEY_ID"
  git tag -v "${I2PD_VERSION}"
fi

cd build
cmake -G "MinGW Makefiles" -DWITH_STATIC=ON -DWITH_UPNP=OFF .
mingw32-make -j"$(nproc)"
strip i2pd.exe

cp i2pd.exe "$OUTDIR/i2pd.exe"
( cd "$OUTDIR" && sha256sum i2pd.exe > i2pd.exe.sha256 )

echo ">> Done:"; file "$OUTDIR/i2pd.exe"; cat "$OUTDIR/i2pd.exe.sha256"
