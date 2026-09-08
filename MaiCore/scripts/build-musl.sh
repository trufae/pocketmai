#!/bin/sh
# Build a fully static pmai with the Swift Static Linux SDK. The result has no
# dependency on glibc, libstdc++, libcurl, or libxml2, so the same binary runs
# on musl distributions such as Alpine and on any glibc distribution, old or
# new. Native plugins loaded with --plugin are unavailable in this build
# because static musl executables cannot dlopen shared objects.
#
# Requires the Static Linux SDK that matches the host toolchain exactly, e.g.
#   swift sdk install https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#     --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
#
# Usage: MaiCore/scripts/build-musl.sh [x86_64|aarch64]
# Prints the path of the built executable on success.

set -eu

arch=${1:-$(uname -m)}
case "$arch" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *)
    echo "build-musl: unsupported architecture: $arch" >&2
    exit 1
    ;;
esac
triple="$arch-swift-linux-musl"

package=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
patch="$package/patches/swift-tui-musl.patch"
edited="$package/Packages/swift-tui"

# swift-tui only knows Glibc on Linux. SwiftPM edit mode keeps the patched copy
# in MaiCore/Packages, outside the pristine checkout, and
# `swift package unedit --force swift-tui` puts everything back. Edit mode also drops
# the swift-tui pin from Package.resolved, so the file is restored afterwards
# to leave the tree as it was found.
resolved="$package/Package.resolved"
saved=$(mktemp) || exit 1
trap 'rm -f "$saved"' EXIT
cp "$resolved" "$saved"
restore_resolved() {
  cp "$saved" "$resolved"
}

if [ ! -d "$edited" ]; then
  swift package --package-path "$package" edit swift-tui
fi
if git -C "$edited" apply --check --reverse "$patch" >/dev/null 2>&1; then
  echo "build-musl: swift-tui musl patch already applied" >&2
else
  git -C "$edited" apply "$patch"
fi

if ! swift build --package-path "$package" -c release --product pmai \
  --swift-sdk "$triple" -Xswiftc -Osize >&2; then
  restore_resolved
  exit 1
fi
restore_resolved

echo "$package/.build/$triple/release/pmai"
