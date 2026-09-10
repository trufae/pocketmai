#!/bin/bash
# Build once while the simulator boots, then reuse that build for the full suite.
set -euo pipefail

destination=${TEST_DESTINATION:-}
result_bundle=${TEST_RESULT_BUNDLE:-build/TestResults.xcresult}
boot_pid=
cleanup() {
  if [ -n "$boot_pid" ]; then
    kill "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -z "$destination" ]; then
  simulator_id=$(xcrun simctl list devices available --json | jq -r '
    [.devices | to_entries[] | select(.key | contains("SimRuntime.iOS-"))
      | . as $runtime | .value[]
      | select(.isAvailable == true and (.name | startswith("iPhone")))
      | {runtime: ($runtime.key | split("iOS-")[1] | split("-") | map(tonumber)),
         udid: .udid}]
    | sort_by(.runtime) | last | .udid // empty')
  if [ -z "$simulator_id" ]; then
    echo "No available iPhone simulator found" >&2
    exit 1
  fi
  # -b also boots a shutdown device. Do not hide boot errors or create clones.
  xcrun simctl bootstatus "$simulator_id" -b &
  boot_pid=$!
  destination="platform=iOS Simulator,id=$simulator_id"
fi

# Use identical settings and destination for both actions. A separate generic
# arm64 build followed by `test` invalidated build work in CI.
common=("$@" -destination "$destination" -parallel-testing-enabled NO)
echo "Building iOS tests"
time xcodebuild "${common[@]}" build-for-testing
if [ -n "$boot_pid" ]; then
  wait "$boot_pid"
  boot_pid=
fi

# Preserve previous results on repeated local runs; xcodebuild needs a new path.
if [ -e "$result_bundle" ]; then
  result_bundle="${result_bundle%.xcresult}-$(date +%s)-$$.xcresult"
fi
echo "Running the full iOS suite; results: $result_bundle"
time xcodebuild "${common[@]}" -resultBundlePath "$result_bundle" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 test-without-building
