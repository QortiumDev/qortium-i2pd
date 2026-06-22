# qortium-i2pd

Reproducible builds of the [i2pd](https://github.com/PurpleI2P/i2pd) I2P router
(C++ implementation, BSD-3-Clause) packaged as **portable, verified, signed
binaries** for every platform Qortium Home runs a managed Core on.

Qortium Home talks to i2pd over the SAM v3 bridge on `127.0.0.1:7656` and uses
I2P as a fallback transport. Upstream i2pd ships a clean portable binary only for
Windows x64 — there is **no** portable Linux binary and **no** macOS arm64
binary in its releases. This repo fills those gaps by building i2pd ourselves for
all targets, so Home can download a known-good binary at first run (the same
download → verify → install pipeline Home already uses for Qortium Core and the
Adoptium JRE).

## Targets

| Target | Build host | Notes |
| --- | --- | --- |
| `linux-x86_64` | Docker (Alpine/musl) | fully static — no glibc/distro dependency |
| `linux-aarch64` | Docker (Alpine/musl, cross or arm runner) | fully static |
| `windows-x86_64` | Docker (MinGW-w64 cross from Linux) | Authenticode-signed |
| `macos-x86_64` | remote mac | static-linked deps, Developer-ID signed + notarized |
| `macos-arm64` | remote mac | static-linked deps, Developer-ID signed + notarized |

Building (and notarizing) our own macOS binary is what lets a *downloaded* i2pd
run cleanly under Gatekeeper on Apple Silicon.

## Source pinning & verification

- **Pinned upstream version:** i2pd `2.60.0`.
- Source is cloned from `https://github.com/PurpleI2P/i2pd.git` at the exact tag.
- The tag's GPG signature is verified against maintainer **r4sas**, key
  `0x66F6C87B98EBCFE2` (key published at <https://repo.i2pd.xyz/r4sas.gpg>).
  Builds **abort** if the signature does not verify (override only for local
  spikes with `SKIP_GPG=1`, which prints a loud warning).

## Output contract (what Home consumes)

Each build writes to `out/<target>/`:

- `i2pd` (or `i2pd.exe`) — the binary.
- `i2pd.sha256` — `sha256sum` line for the binary.

A release aggregates all targets and publishes, alongside the binaries:

- `SHA256SUMS` — checksums for every asset.
- `manifest.json` — `{ version, builtFrom, targets: { "<os>-<arch>": { asset, sha256 } } }`
  so Home can resolve the right asset by `process.platform` / `process.arch`
  (mapping `darwin→macos`, `win32→windows`, `arm64→aarch64`) and verify it.

## Versioning

Release tags are `<upstream>-q<rev>` — e.g. `2.60.0-q1` is our first build of
i2pd 2.60.0. Bumping `<rev>` reflects packaging/signing changes with no upstream
version change.

## Building

```sh
# Linux (x86_64 host): fully-static binary via Alpine container
./build/build-linux.sh
```

Windows (MinGW cross) and macOS (remote mac) build scripts follow the same
pinning/verification/output contract; see `build/`.

## Licensing

i2pd is BSD-3-Clause. Redistributed binaries carry i2pd's copyright and license
notice (see `out/<target>/` and the aggregated release). This repository's own
build tooling is 0BSD, consistent with the rest of the Qortium stack.
