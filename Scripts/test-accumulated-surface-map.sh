#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-surfaces.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun clang -O2 -std=c11 -Wall -Wextra -Werror \
  "$repo_dir/Tests/ROBAccumulatedSurfaceMapFixtureTests.c" -o "$fixture_dir/surfaces"
"$fixture_dir/surfaces"
xcrun clang -O1 -g -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$repo_dir/Tests/ROBAccumulatedSurfaceMapFixtureTests.c" -o "$fixture_dir/surfaces-sanitized"
"$fixture_dir/surfaces-sanitized"
