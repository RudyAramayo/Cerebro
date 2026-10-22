#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-depth-floor.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun clang -O2 -std=c11 -Wall -Wextra -Werror \
  "$repo_dir/Tests/ROBDepthFloorRectificationFixtureTests.c" -o "$fixture_dir/floor"
"$fixture_dir/floor"
