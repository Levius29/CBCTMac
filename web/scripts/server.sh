#!/usr/bin/env bash
# Start, stop and inspect the local OpenMRI server (127.0.0.1:4173).
#
#   scripts/server.sh start [--no-open]   build if needed, start in the background, open the browser
#   scripts/server.sh stop                stop the background server
#   scripts/server.sh restart [--no-open]
#   scripts/server.sh status              is it running, which pid, where is the log
#   scripts/server.sh logs                follow the server log
#
# npm shortcuts: npm run up / npm run down / npm run status.
# "Launch OpenMRI.command" is the double-click equivalent for macOS and runs
# the server in the foreground instead.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

URL='http://127.0.0.1:4173'
PORT=4173
PID_FILE='.openmri-server.pid'
LOG_FILE='.openmri-server.log'
STAMP='dist/.built-from'

healthy() { curl -fsS --max-time 2 "$URL/api/health" 2>/dev/null | grep -q '"openmri"'; }

# Pid of whatever listens on the port, or nothing. lsof on macOS and most Linux, ss as a fallback.
listening_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n 1
  fi
}

recorded_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

open_browser() {
  if command -v open >/dev/null 2>&1; then open "$URL"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 || true
  else echo "Open $URL in your browser."; fi
}

# Same rules as the macOS launcher: rebuild when the checked-out revision
# changed, create the Python environment on first run.
prepare() {
  if ! command -v node >/dev/null 2>&1; then
    echo 'Node.js was not found. Install Node.js 22.13 or newer from https://nodejs.org and try again.' >&2
    exit 1
  fi
  local revision; revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ ! -d node_modules || ! -d dist || "$(cat "$STAMP" 2>/dev/null)" != "$revision" ]]; then
    echo 'Installing JavaScript dependencies and building the application.'
    npm ci
    npm run build
    echo "$revision" > "$STAMP"
  fi
  if [[ ! -x .venv/bin/python ]]; then
    echo 'First run: preparing the Python processing environment.'
    npm run setup
  fi
}

wait_until_healthy() {  # $1 = pid to watch
  local i
  for i in $(seq 1 60); do
    healthy && return 0
    kill -0 "$1" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

start() {
  local open_after=1
  [[ "${1:-}" == '--no-open' ]] && open_after=0
  if healthy; then
    echo "OpenMRI is already running at $URL"
    if (( open_after )); then open_browser; fi
    return 0
  fi
  local other; other="$(listening_pid || true)"
  if [[ -n "$other" ]]; then
    echo "Port $PORT is used by another application (pid $other). Stop it and try again." >&2
    exit 1
  fi
  prepare
  : > "$LOG_FILE"
  nohup npm start >>"$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Starting OpenMRI (pid $pid), log in $LOG_FILE"
  if wait_until_healthy "$pid"; then
    echo "OpenMRI is running at $URL"
    if (( open_after )); then open_browser; fi
  else
    echo "The server did not become healthy. Last log lines:" >&2
    tail -n 20 "$LOG_FILE" >&2 || true
    stop >/dev/null 2>&1 || true
    exit 1
  fi
}

stop() {
  local pid listener i stopped=0
  pid="$(recorded_pid || true)"
  listener="$(listening_pid || true)"
  if [[ -z "$pid" && -z "$listener" ]]; then
    echo 'OpenMRI is not running.'
    rm -f "$PID_FILE"
    return 0
  fi
  # npm forwards the signal to the server, and the listener is killed directly
  # as well in case the process tree was reparented.
  for p in $pid $listener; do kill -TERM "$p" 2>/dev/null || true; done
  for i in $(seq 1 20); do
    if [[ -z "$(listening_pid || true)" ]] && { [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; }; then stopped=1; break; fi
    sleep 0.5
  done
  if (( ! stopped )); then
    for p in $pid $(listening_pid || true); do kill -KILL "$p" 2>/dev/null || true; done
  fi
  rm -f "$PID_FILE"
  echo 'OpenMRI stopped.'
}

status() {
  local pid listener
  pid="$(recorded_pid || true)"
  listener="$(listening_pid || true)"
  if healthy; then
    echo "OpenMRI is running at $URL (pid ${pid:-unknown}, server pid ${listener:-unknown})"
    echo "Log: $LOG_FILE"
  elif [[ -n "$listener" ]]; then
    echo "Port $PORT is in use by pid $listener, but it is not answering as OpenMRI."
    return 1
  else
    echo 'OpenMRI is not running.'
    return 1
  fi
}

case "${1:-}" in
  start)   start "${2:-}" ;;
  stop)    stop ;;
  restart) stop; start "${2:-}" ;;
  status)  status ;;
  logs)    [[ -f "$LOG_FILE" ]] && exec tail -n 50 -f "$LOG_FILE" || { echo "No log yet: $LOG_FILE"; exit 1; } ;;
  *)       sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
