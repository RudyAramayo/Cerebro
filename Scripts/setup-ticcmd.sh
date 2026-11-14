#!/bin/bash
# Build the unmodified Pololu CLI for this Mac. Never sends a hardware command.
set -euo pipefail
revision=a1887ca54a0190d298da779b3bccca9ce3a23450
cache_dir="$HOME/Library/Caches/Cerebro/ticcmd-native"
source_dir="${1:-$cache_dir/source}"
install_dir="$HOME/Library/Application Support/Cerebro/Tic"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
command -v cmake >/dev/null
pkg-config --exists libusbp-1 || { echo 'Install Pololu libusbp-1 before building ticcmd.' >&2; exit 1; }
if [[ ! -d "$source_dir" ]]; then
    if [[ $# != 0 ]]; then echo 'The supplied Pololu source directory does not exist.' >&2; exit 1; fi
    git clone https://github.com/pololu/pololu-tic-software.git "$source_dir"
    git -C "$source_dir" checkout --detach "$revision"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || {
    echo "Use the pinned Pololu revision $revision." >&2; exit 1;
}
git -C "$source_dir" diff --quiet HEAD -- || { echo 'Pololu sources must be unmodified.' >&2; exit 1; }
cmake -S "$source_dir" -B "$cache_dir/build" -DENABLE_GUI=OFF -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_PREFIX_PATH='/usr/local;/opt/homebrew' -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$cache_dir/build" --target cli --parallel 4
# Validate the command interface without opening a controller.
"$cache_dir/build/ticcmd" --help >/dev/null
mkdir -p "$install_dir"
install -m 755 "$cache_dir/build/ticcmd" "$install_dir/ticcmd.new"
mv "$install_dir/ticcmd.new" "$install_dir/ticcmd"
cp "$source_dir/LICENSE.txt" "$install_dir/LICENSE-Pololu.txt"
cp "$source_dir/LICENSE_libyaml.txt" "$install_dir/LICENSE-libyaml.txt"
printf '%s\n' "$revision" > "$install_dir/source-revision.txt"
echo "Installed native ticcmd at $install_dir/ticcmd. Relaunch Cerebro to use it."
