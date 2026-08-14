#!/bin/zsh
set -u

readonly executable="/Applications/Cerebro.app/Contents/MacOS/Cerebro"
readonly log_file="${HOME}/Library/Logs/Cerebro.supervisor.log"
readonly retry_delay=2
readonly maximum_consecutive_crashes=10

log_message() {
  print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "${log_file}"
}

if [[ ! -x "${executable}" ]]; then
  log_message "Circuit open: ${executable} is unavailable."
  exit 0
fi

attempt=0
while true; do
  started_at=${SECONDS}
  "${executable}" -ApplePersistenceIgnoreState YES
  status=$?
  runtime=$((SECONDS - started_at))

  if (( status == 0 )); then
    log_message "Cerebro exited intentionally; no restart requested."
    exit 0
  fi

  # A healthy run earns a fresh recovery budget.
  if (( runtime >= 300 )); then
    attempt=0
  fi

  attempt=$((attempt + 1))
  if (( attempt >= maximum_consecutive_crashes )); then
    log_message "Circuit open after ${attempt} consecutive crashes (last status ${status}); automatic restarts stopped."
    exit 0
  fi

  log_message "Cerebro crashed with status ${status} after ${runtime}s; crash ${attempt}/${maximum_consecutive_crashes}, relaunching in ${retry_delay}s."
  sleep "${retry_delay}"
done
