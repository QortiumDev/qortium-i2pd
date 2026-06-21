#!/usr/bin/env bash
#
# Smoke-test a published qortium-i2pd release on the current machine, the way
# Qortium Home will consume it: download the right asset for this os/arch, verify
# its SHA256 against manifest.json, extract, run it, and confirm the SAM bridge
# answers a v3 HELLO. Non-invasive — uses a private datadir and an alternate SAM
# port, and leaves no daemon running.
#
# Usage:
#   ./smoke-release.sh [VERSION]      # default VERSION: 2.60.0-q2
#   SAM_PORT=7666 ./smoke-release.sh
#
set -euo pipefail

REPO="QortiumDev/qortium-i2pd"
VERSION="${1:-2.60.0-q2}"
SAM_PORT="${SAM_PORT:-7666}"
BASE="https://github.com/${REPO}/releases/download/${VERSION}"

os="$(uname -s)"; m="$(uname -m)"
case "$os" in Linux) OS=linux;; Darwin) OS=macos;; *) echo "unsupported OS: $os" >&2; exit 1;; esac
case "$m" in
  x86_64|amd64) ARCH=x86_64;;
  arm64|aarch64) [ "$OS" = macos ] && ARCH=arm64 || ARCH=aarch64;;
  *) echo "unsupported arch: $m" >&2; exit 1;;
esac
TARGET="${OS}-${ARCH}"
echo ">> Smoke-testing ${REPO} ${VERSION} for ${TARGET} (SAM port ${SAM_PORT})"

# Work under $HOME, not /tmp, which may be mounted noexec.
WORK="$(mktemp -d "${HOME}/.i2pd-smoke.XXXXXX")"
trap 'kill "${PID:-}" 2>/dev/null; wait "${PID:-}" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

echo ">> Downloading manifest + asset"
curl -fsSL "${BASE}/manifest.json" -o manifest.json
asset="$(python3 -c "import json;print(json.load(open('manifest.json'))['targets']['${TARGET}']['asset'])")"
want="$(python3 -c "import json;print(json.load(open('manifest.json'))['targets']['${TARGET}']['sha256'])")"
curl -fsSL "${BASE}/${asset}" -o "$asset"

got="$(python3 -c "import hashlib;print(hashlib.sha256(open('${asset}','rb').read()).hexdigest())")"
if [ "$got" = "$want" ]; then echo ">> sha256 OK (${got})"; else echo "!! sha256 MISMATCH: want ${want}, got ${got}" >&2; exit 1; fi

case "$asset" in
  *.zip) unzip -q "$asset";;
  *) tar xzf "$asset";;
esac
BIN="${WORK}/i2pd"; [ -f "$BIN" ] || BIN="${WORK}/i2pd.exe"
chmod +x "$BIN"

echo ">> Binary:"; file "$BIN" 2>/dev/null || true
echo ">> Version:"; "$BIN" --version | head -2

DATADIR="${WORK}/data"; mkdir -p "$DATADIR"
echo ">> Launching i2pd with SAM on 127.0.0.1:${SAM_PORT}"
"$BIN" --datadir="$DATADIR" \
  --sam.enabled=true --sam.address=127.0.0.1 --sam.port="$SAM_PORT" \
  --http.enabled=false --httpproxy.enabled=false --socksproxy.enabled=false \
  --notransit --loglevel=error >"${WORK}/run.log" 2>&1 &
PID=$!
sleep 5
if ! kill -0 "$PID" 2>/dev/null; then echo "!! i2pd exited early:"; tail -n 15 "${WORK}/run.log"; exit 1; fi

reply="$(python3 -c "
import socket
s=socket.create_connection(('127.0.0.1',${SAM_PORT}),5)
s.sendall(b'HELLO VERSION MIN=3.0 MAX=3.1\n')
print(s.recv(128).decode(errors='replace').strip())
")"
echo ">> SAM reply: ${reply}"
case "$reply" in
  *RESULT=OK*) echo ">> PASS — ${TARGET} ${VERSION}: binary runs and SAM v3 answers";;
  *) echo "!! FAIL — unexpected SAM reply" >&2; exit 1;;
esac
