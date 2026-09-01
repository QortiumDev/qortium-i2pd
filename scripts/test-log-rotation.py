#!/usr/bin/env python3
"""Black-box acceptance test for Qortium's bounded i2pd file logging."""

from __future__ import annotations

import argparse
import socket
import subprocess
import tempfile
import time
from pathlib import Path


MAX_FILE_SIZE = 4096
ARCHIVE_COUNT = 3


def available_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_sam(port: int, process: subprocess.Popen[bytes], timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"i2pd exited early with status {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"SAM did not listen on 127.0.0.1:{port} within {timeout}s")


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def start(binary: Path, root: Path, log: Path, level: str) -> tuple[subprocess.Popen[bytes], int, object]:
    datadir = root / f"data-{level}"
    datadir.mkdir()
    port = available_port()
    diagnostic = (root / f"i2pd-{level}.stdio.log").open("wb")
    command = [
        str(binary),
        f"--datadir={datadir}",
        "--log=file",
        f"--logfile={log}",
        f"--loglevel={level}",
        "--logclftime",
        f"--logfilesize={MAX_FILE_SIZE}",
        f"--logfilecount={ARCHIVE_COUNT}",
        "--sam.enabled=true",
        "--sam.address=127.0.0.1",
        f"--sam.port={port}",
        "--http.enabled=false",
        "--httpproxy.enabled=false",
        "--socksproxy.enabled=false",
        "--notransit",
    ]
    return subprocess.Popen(command, stdout=diagnostic, stderr=subprocess.STDOUT), port, diagnostic


def assert_bounded(log: Path, require_all_archives: bool) -> None:
    expected = [log] + [Path(f"{log}.{index}") for index in range(1, ARCHIVE_COUNT + 1)]
    if not log.exists():
        raise AssertionError(f"active logfile was not created: {log}")
    if require_all_archives:
        missing = [str(path) for path in expected[1:] if not path.exists()]
        if missing:
            raise AssertionError(f"rotation did not fill the archive set: {missing}")
    for path in expected:
        if path.exists() and path.stat().st_size > MAX_FILE_SIZE:
            raise AssertionError(f"{path} is {path.stat().st_size} bytes; limit is {MAX_FILE_SIZE}")
    if Path(f"{log}.{ARCHIVE_COUNT + 1}").exists():
        raise AssertionError("rotation retained more archives than configured")
    leftovers = list(log.parent.glob(f"{log.name}.rotation-*"))
    if leftovers:
        raise AssertionError(f"rotation left temporary files behind: {leftovers}")


def exercise_sam(port: int, attempts: int = 500) -> None:
    for _ in range(attempts):
        with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
            sock.sendall(b"HELLO VERSION MIN=3.0 MAX=3.1\n")
            reply = sock.recv(256)
            if b"RESULT=OK" not in reply:
                raise RuntimeError(f"unexpected SAM reply: {reply!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"binary does not exist: {binary}")

    with tempfile.TemporaryDirectory(prefix="qortium-i2pd-log-test-") as temporary:
        root = Path(temporary)
        log = root / "i2pd.log"

        # An upgrade can encounter Home's old unbounded logfile. Its first
        # rotation must retain only a bounded tail, not rename the whole file.
        log.write_bytes((b"legacy-unbounded-log\n" * 1000))
        process, port, diagnostic = start(binary, root, log, "none")
        try:
            wait_for_sam(port, process)
        finally:
            stop(process)
            diagnostic.close()
        assert_bounded(log, require_all_archives=False)
        if not Path(f"{log}.1").exists():
            raise AssertionError("oversized legacy logfile was not archived")

        for path in root.glob("i2pd.log*"):
            path.unlink()

        process, port, diagnostic = start(binary, root, log, "debug")
        try:
            wait_for_sam(port, process)
            exercise_sam(port)
            time.sleep(1)
        finally:
            stop(process)
            diagnostic.close()
        assert_bounded(log, require_all_archives=True)

    print(
        f"PASS: active log and {ARCHIVE_COUNT} archives stayed at or below "
        f"{MAX_FILE_SIZE} bytes, including an oversized legacy log"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
