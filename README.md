# qortium-i2pd

Build and release tooling for the i2pd I2P router binaries consumed by
Qortium Home. This is not a QDN app: it produces platform-specific executables,
checksums, and a release manifest for Home's managed runtime.

The build scripts pin upstream [PurpleI2P/i2pd](https://github.com/PurpleI2P/i2pd)
at version `2.60.0`. Unless `SKIP_GPG=1` is set for a local experiment, each
script imports the r4sas public key from `https://repo.i2pd.xyz/r4sas.gpg` and
requires `git tag -v 2.60.0` to succeed before compiling.

## Targets and signing status

| Target | CI path | Binary and signing status |
| --- | --- | --- |
| `linux-x86_64` | `ubuntu-latest`, Alpine 3.20 Docker build | Fully static musl binary; no code-signing step |
| `linux-aarch64` | native `ubuntu-24.04-arm`, Alpine 3.20 Docker build | Fully static musl binary; no code-signing step |
| `windows-x86_64` | `windows-latest` with MSYS2/MINGW64 | Static MinGW build; not Authenticode-signed |
| `macos-arm64` | native `macos-14` runner | Static third-party dependencies, dynamic system `libSystem`; ad-hoc signed by default |
| `macos-x86_64` | cross-compiled on a `macos-14` Apple-Silicon runner | Same dependency model; ad-hoc signed by default |

The macOS script uses `codesign -s -` when no identity is provided. Setting
`MACOS_SIGN_IDENTITY` switches the build to Developer ID signing, but
notarization is not implemented. The repository has no Windows Authenticode
step. The available verification signals are the upstream tag check performed
during each build and the published SHA-256 values; these are not substitutes
for platform code signing.

## Build locally

Linux requires Docker:

```sh
./build/build-linux.sh
```

Windows must be run from an MSYS2 MINGW64 shell; the script installs its MinGW
packages with `pacman`:

```sh
./build/build-windows.sh
```

macOS requires Homebrew. The host architecture is the default; an Apple-Silicon
host can cross-build x86_64 with Rosetta and an x86_64 Homebrew installation:

```sh
./build/build-macos.sh
TARGET_ARCH=x86_64 ./build/build-macos.sh
```

`I2PD_VERSION` can override the pinned version for a test build. `SKIP_GPG=1`
skips source-tag verification and prints a warning; it is not appropriate for a
release build.

Each script writes under `out/<target>/`:

- Linux and macOS: `i2pd` and `i2pd.sha256`.
- Windows: `i2pd.exe` and `i2pd.exe.sha256`.

## CI and releases

`.github/workflows/build.yml` runs the five-target matrix for pull requests,
manual dispatches, and tags matching `*-q*`. A tag such as `2.60.0-q2` also runs
the release job after every platform build. That job packages Unix targets as
`.tar.gz`, Windows as `.zip`, restores the Unix executable bit, and publishes:

- one archive per target;
- `SHA256SUMS` covering the archives;
- `manifest.json`, mapping each target to its archive and SHA-256 value.

Release tags use `<upstream>-q<revision>`. Increment the Qortium revision when
the packaging changes without changing the upstream i2pd version.

## Smoke-test a release

On Linux or macOS, the smoke script selects the current OS and architecture,
downloads the matching release archive and `manifest.json`, verifies the
archive hash, launches the binary with an isolated data directory, and checks a
SAM v3 handshake on an alternate port:

```sh
./scripts/smoke-release.sh 2.60.0-q2
SAM_PORT=7666 ./scripts/smoke-release.sh 2.60.0-q2
```

The script cleans up its temporary process and data directory when it exits.

## Licensing

i2pd is BSD-3-Clause. This repository's build tooling is 0BSD.
