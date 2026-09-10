#!/usr/bin/env bash
# Install a requested Swift toolchain without a JavaScript action runtime.
set -euo pipefail

version=${1:?usage: setup-swift.sh <version>}
swiftly_version=1.1.0
arch=$(uname -m)
workdir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/swiftly.XXXXXX")
package="$workdir/swiftly.tar.gz"
signature="$package.sig"
keys="$workdir/all-keys.asc"
export GNUPGHOME="$workdir/gnupg"
mkdir -m 700 "$GNUPGHOME"

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

curl --fail --location --retry 3 --output "$package" \
  "https://download.swift.org/swiftly/linux/swiftly-${swiftly_version}-${arch}.tar.gz"
curl --fail --location --retry 3 --output "$signature" \
  "https://download.swift.org/swiftly/linux/swiftly-${swiftly_version}-${arch}.tar.gz.sig"
curl --fail --location --retry 3 --output "$keys" https://swift.org/keys/all-keys.asc
if gunzip --test "$keys" 2>/dev/null; then
  zcat "$keys" | gpg --batch --import
else
  gpg --batch --import "$keys"
fi
gpg --batch --verify "$signature" "$package"
tar -xzf "$package" -C "$workdir"

export SWIFTLY_HOME_DIR="${RUNNER_TEMP:-/tmp}/swiftly-home"
export SWIFTLY_BIN_DIR="${RUNNER_TEMP:-/tmp}/swiftly-bin"
export PATH="$SWIFTLY_BIN_DIR:$PATH"

"$workdir/swiftly" init --skip-install --quiet-shell-followup --assume-yes --no-modify-profile
# init moves the bootstrap executable into SWIFTLY_BIN_DIR.
"$SWIFTLY_BIN_DIR/swiftly" install --use "$version" --assume-yes \
  --post-install-file "$workdir/post-install.sh"
if [ -f "$workdir/post-install.sh" ]; then
  bash "$workdir/post-install.sh"
fi

toolchain_dir=$("$SWIFTLY_BIN_DIR/swiftly" use --print-location)
toolchain_bin="$toolchain_dir/usr/bin"
test -x "$toolchain_bin/swift"
export PATH="$toolchain_bin:$PATH"
swift --version

echo "SWIFTLY_HOME_DIR=$SWIFTLY_HOME_DIR" >> "$GITHUB_ENV"
echo "SWIFTLY_BIN_DIR=$SWIFTLY_BIN_DIR" >> "$GITHUB_ENV"
echo "$SWIFTLY_BIN_DIR" >> "$GITHUB_PATH"
echo "$toolchain_bin" >> "$GITHUB_PATH"
