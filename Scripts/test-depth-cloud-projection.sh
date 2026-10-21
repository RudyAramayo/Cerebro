#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-depth-cloud.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror "$repo_dir/Tests/ROBDepthCloudProjectionFixtureTests.c" -o "$fixture_dir/projection"
"$fixture_dir/projection"
