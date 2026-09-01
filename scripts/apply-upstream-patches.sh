#!/bin/sh
# Apply Qortium's reviewed downstream changes to a clean, verified i2pd tree.
set -eu

SOURCE_DIR="${1:?usage: apply-upstream-patches.sh <i2pd-source-dir>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for patch in "${REPO_ROOT}"/patches/*.patch; do
  echo ">> Applying Qortium downstream patch: $(basename "$patch")"
  git -C "$SOURCE_DIR" apply --check "$patch"
  git -C "$SOURCE_DIR" apply "$patch"
done
