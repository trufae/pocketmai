#!/usr/bin/env bash
# Avoid Swift's URLSession/OpenSSL teardown crash when installing remote SDKs.
set -euo pipefail

url=${1:?usage: install-swift-sdk.sh <url> <sha256>}
checksum=${2:?usage: install-swift-sdk.sh <url> <sha256>}
workdir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/swift-sdk.XXXXXX")
trap 'rm -rf "$workdir"' EXIT
archive="$workdir/${url##*/}"

curl --fail --location --retry 3 --output "$archive" "$url"
# Swift only checks --checksum for remote URLs, so verify before local install.
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --strict
swift sdk install "$archive"
