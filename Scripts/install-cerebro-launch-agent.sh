#!/bin/zsh
set -euo pipefail

readonly agent_label="com.orbitusrobotics.Cerebro.keepalive"
readonly app_path="/Applications/Cerebro.app"
readonly executable_path="${app_path}/Contents/MacOS/Cerebro"
readonly agent_directory="${HOME}/Library/LaunchAgents"
readonly agent_path="${agent_directory}/${agent_label}.plist"
readonly domain="gui/$(id -u)"

if [[ ! -x "${executable_path}" ]]; then
  print -u2 "Install a signed Cerebro.app in /Applications before enabling its keep-alive agent."
  exit 1
fi

mkdir -p "${agent_directory}"
temporary_plist="$(mktemp "${TMPDIR:-/tmp}/cerebro-launch-agent.XXXXXX")"
trap 'rm -f "${temporary_plist}"' EXIT

plutil -create xml1 "${temporary_plist}"
plutil -insert Label -string "${agent_label}" "${temporary_plist}"
plutil -insert ProgramArguments -json "[\"${executable_path}\"]" "${temporary_plist}"
plutil -insert RunAtLoad -bool YES "${temporary_plist}"
plutil -insert KeepAlive -bool YES "${temporary_plist}"
plutil -insert ProcessType -string Interactive "${temporary_plist}"
plutil -insert ThrottleInterval -integer 10 "${temporary_plist}"
plutil -insert LimitLoadToSessionType -string Aqua "${temporary_plist}"
plutil -insert StandardOutPath -string "${HOME}/Library/Logs/Cerebro.launchd.log" "${temporary_plist}"
plutil -insert StandardErrorPath -string "${HOME}/Library/Logs/Cerebro.launchd.log" "${temporary_plist}"
chmod 600 "${temporary_plist}"
mv "${temporary_plist}" "${agent_path}"
trap - EXIT

launchctl bootout "${domain}/${agent_label}" 2>/dev/null || true
launchctl bootstrap "${domain}" "${agent_path}"
launchctl enable "${domain}/${agent_label}"
launchctl kickstart -k "${domain}/${agent_label}"
print "Cerebro keep-alive agent installed and running."
