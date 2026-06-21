#!/usr/bin/env bash
#
# Build a portable i2pd binary for macOS (runs on a macOS host / CI runner).
#
# "Static" on macOS means static Boost/OpenSSL/zlib with the always-present
# system libSystem linked dynamically (macOS has no static libc) — so the binary
# carries no Homebrew runtime dependency. Architecture follows the host:
# `uname -m` -> arm64 (Apple Silicon) or x86_64 (Intel).
#
# Signing: we ad-hoc sign by default (`codesign -s -`). That satisfies Apple
# Silicon's requirement that every executable be signed, and is sufficient
# because Home DOWNLOADS this binary (Node fetch does not set the quarantine
# attribute, so Gatekeeper does not block it). Authenticity comes from the
# GPG-verified source + the SHA256 Home pins, not from Apple. When an Apple
# Developer ID is available, set MACOS_SIGN_IDENTITY to switch to Developer-ID
# signing (and wire notarization in the marked stub below).
#
# Usage:
#   ./build/build-macos.sh
#   I2PD_VERSION=2.60.0 ./build/build-macos.sh
#   MACOS_SIGN_IDENTITY="Developer ID Application: ..." ./build/build-macos.sh
#
set -euo pipefail

I2PD_VERSION="${I2PD_VERSION:-2.60.0}"
I2PD_REPO="https://github.com/PurpleI2P/i2pd.git"
R4SAS_KEY_ID="66F6C87B98EBCFE2"
R4SAS_KEY_URL="https://repo.i2pd.xyz/r4sas.gpg"
SKIP_GPG="${SKIP_GPG:-0}"

ARCH="$(uname -m)"                          # arm64 | x86_64
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${REPO_ROOT}/out/macos-${ARCH}"
mkdir -p "$OUTDIR"

echo ">> Building i2pd ${I2PD_VERSION} for macos-${ARCH}"

# zlib is keg-only on Homebrew but ships a static libz.a; macOS's SDK provides
# only libz.dylib, so without this the WITH_STATIC find_package(ZLIB) finds no
# static lib and the ZLIB::ZLIB target is never created (CMake generate fails).
brew install boost openssl@3 zlib cmake gnupg

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

# macOS cannot fully-statically link (no crt0.o / static libc). i2pd's
# WITH_STATIC unconditionally sets the exe LINK_FLAGS to "-static" for all
# non-MSVC targets (build/CMakeLists.txt), which fails on Apple with
# `ld: library not found for -lcrt0.o`. Neutralize just that flag in our source
# copy: WITH_STATIC still links Boost/OpenSSL/zlib statically; libSystem links
# dynamically, which is the standard portable-macOS approach. (BSD sed.)
sed -i '' 's/LINK_FLAGS "-static"/LINK_FLAGS ""/' build/CMakeLists.txt

cd build
# Point FindZLIB straight at Homebrew's static libz.a + headers. We set the
# explicit ZLIB_LIBRARY/ZLIB_INCLUDE_DIR cache vars (not ZLIB_ROOT) because
# i2pd's CMakeLists declares an ancient cmake_minimum_required, which leaves
# policy CMP0074 OLD so <Pkg>_ROOT hints are ignored. Without this, CMake finds
# the macOS SDK's zlib.h (1.2.12) but no static lib and ZLIB::ZLIB is not made.
ZLIB_PREFIX="$(brew --prefix zlib)"
cmake -DWITH_STATIC=ON -DWITH_UPNP=OFF \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DZLIB_LIBRARY="${ZLIB_PREFIX}/lib/libz.a" \
  -DZLIB_INCLUDE_DIR="${ZLIB_PREFIX}/include" .
make -j"$(sysctl -n hw.ncpu)"
strip i2pd

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo ">> Developer-ID signing with: ${MACOS_SIGN_IDENTITY}"
  codesign --force --options runtime --timestamp -s "$MACOS_SIGN_IDENTITY" i2pd
  # TODO(dev-id): notarize the binary once Apple credentials exist, e.g.
  #   ditto -c -k i2pd i2pd.zip
  #   xcrun notarytool submit i2pd.zip --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
  # A loose binary cannot be stapled; notarization alone clears Gatekeeper.
else
  echo ">> Ad-hoc signing (no Apple Developer ID set)."
  codesign --force -s - i2pd
fi
codesign -dv i2pd 2>&1 | sed -n '1,3p' || true

cp i2pd "$OUTDIR/i2pd"
( cd "$OUTDIR" && shasum -a 256 i2pd > i2pd.sha256 )

echo ">> Done:"; file "$OUTDIR/i2pd"; "$OUTDIR/i2pd" --version | head -2; cat "$OUTDIR/i2pd.sha256"
