#!/usr/bin/env bash
#
# Build a portable i2pd binary for macOS (runs on a macOS host / CI runner).
#
# "Static" on macOS means static Boost/OpenSSL/zlib with the always-present
# system libSystem linked dynamically (macOS has no static libc) — so the binary
# carries no Homebrew runtime dependency.
#
# Target arch is TARGET_ARCH (default: the host's `uname -m`). To avoid GitHub's
# scarce Intel runners we cross-compile the x86_64 binary on an Apple-Silicon
# (arm64) runner: that needs x86_64 dependency libraries, so we install an
# x86_64 Homebrew under Rosetta and point CMake at it.
#
# Signing: ad-hoc by default (`codesign -s -`), which satisfies Apple Silicon's
# requirement that every executable be signed and is sufficient because Home
# DOWNLOADS this binary (Node fetch does not set the quarantine attribute, so
# Gatekeeper does not block it). Authenticity comes from the GPG-verified source
# + the SHA256 Home pins, not from Apple. Set MACOS_SIGN_IDENTITY to switch to
# Developer-ID signing (and wire notarization in the marked stub) once available.
#
# Usage:
#   ./build/build-macos.sh                 # build for the host arch
#   TARGET_ARCH=x86_64 ./build/build-macos.sh   # cross-compile on arm64
#
set -euo pipefail

I2PD_VERSION="${I2PD_VERSION:-2.60.0}"
I2PD_REPO="https://github.com/PurpleI2P/i2pd.git"
R4SAS_KEY_ID="66F6C87B98EBCFE2"
R4SAS_KEY_URL="https://repo.i2pd.xyz/r4sas.gpg"
SKIP_GPG="${SKIP_GPG:-0}"

HOST_ARCH="$(uname -m)"                      # arm64 | x86_64
TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${REPO_ROOT}/out/macos-${TARGET_ARCH}"
mkdir -p "$OUTDIR"

echo ">> Building i2pd ${I2PD_VERSION} for macos-${TARGET_ARCH} (host ${HOST_ARCH})"

# Build tools (cmake, gnupg) run on the host, so install them with the native
# Homebrew. Dependency LIBRARIES must match the target arch, so they come from
# $DEPBREW — the native brew for a same-arch build, or an x86_64 Homebrew under
# Rosetta when cross-compiling.
brew install cmake gnupg

ARCH_FLAG=""
if [ "$TARGET_ARCH" = "$HOST_ARCH" ]; then
  DEPBREW="brew"
else
  echo ">> Cross-compiling: installing Rosetta + x86_64 Homebrew for ${TARGET_ARCH} deps"
  sudo softwareupdate --install-rosetta --agree-to-license
  if [ ! -x /usr/local/bin/brew ]; then
    arch -x86_64 /bin/bash -c \
      "NONINTERACTIVE=1 $(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  DEPBREW="arch -x86_64 /usr/local/bin/brew"
  ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=${TARGET_ARCH}"
fi

# zlib is keg-only on Homebrew but ships a static libz.a; macOS's SDK provides
# only libz.dylib, so without it the WITH_STATIC find_package(ZLIB) finds no
# static lib and the ZLIB::ZLIB target is never created (CMake generate fails).
$DEPBREW install boost openssl@3 zlib

OPENSSL_PREFIX="$($DEPBREW --prefix openssl@3)"
ZLIB_PREFIX="$($DEPBREW --prefix zlib)"
BOOST_PREFIX="$($DEPBREW --prefix boost)"

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
# Point CMake at the target-arch deps: explicit ZLIB_LIBRARY/INCLUDE_DIR (the
# <Pkg>_ROOT hints are ignored — i2pd's ancient cmake_minimum_required leaves
# CMP0074 OLD), OPENSSL_ROOT_DIR, and CMAKE_PREFIX_PATH so the (CONFIG-mode)
# find_package(Boost) resolves the right prefix.
cmake $ARCH_FLAG -DWITH_STATIC=ON -DWITH_UPNP=OFF \
  -DCMAKE_PREFIX_PATH="${BOOST_PREFIX}" \
  -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" \
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

echo ">> Done:"; file "$OUTDIR/i2pd"
# A cross-built binary may not run on the build host, so don't fail on it.
"$OUTDIR/i2pd" --version 2>/dev/null | head -2 || echo "(skipped run check for cross build)"
cat "$OUTDIR/i2pd.sha256"
