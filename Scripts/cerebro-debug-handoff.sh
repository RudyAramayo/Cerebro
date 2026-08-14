#!/bin/zsh
set -euo pipefail

readonly mode="${1:-}"
readonly project_directory="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
readonly agent_label="com.orbitusrobotics.Cerebro.keepalive"
readonly domain="gui/$(id -u)"
readonly production_executable="/Applications/Cerebro.app/Contents/MacOS/Cerebro"
readonly watchdog_directory="${TMPDIR:-/tmp}/com.orbitusrobotics.Cerebro.debug-watchdog"

case "${mode}" in
  begin)
    launchctl bootout "${domain}/${agent_label}" 2>/dev/null || true
    while IFS= read -r process_id; do
      [[ -n "${process_id}" ]] && kill -TERM "${process_id}" 2>/dev/null || true
    done < <(pgrep -f "^${production_executable}$" || true)
    for _ in {1..40}; do
      if ! pgrep -f "^${production_executable}$" >/dev/null; then
        if mkdir "${watchdog_directory}" 2>/dev/null; then
          nohup "$0" watchdog >"${watchdog_directory}/watchdog.log" 2>&1 &
        fi
        exit 0
      fi
      sleep 0.05
    done
    print -u2 "The production Cerebro process did not stop before debugging."
    exit 1
    ;;
  end)
    if [[ -x "${production_executable}" ]]; then
      "${project_directory}/Scripts/install-cerebro-launch-agent.sh"
    fi
    ;;
  watchdog)
    trap 'rm -f "${watchdog_directory}/watchdog.log"; rmdir "${watchdog_directory}" 2>/dev/null || true' EXIT
    # Give Xcode enough time to build and launch the Debug executable.
    sleep 30
    while pgrep -f '/Library/Developer/Xcode/DerivedData/.*/Cerebro.app/Contents/MacOS/Cerebro$' >/dev/null; do
      sleep 5
    done
    if ! launchctl print "${domain}/${agent_label}" >/dev/null 2>&1 &&
       [[ -x "${production_executable}" ]]; then
      "${project_directory}/Scripts/install-cerebro-launch-agent.sh"
    fi
    ;;
  *)
    print -u2 "Usage: $0 begin|end|watchdog"
    exit 64
    ;;
esac
