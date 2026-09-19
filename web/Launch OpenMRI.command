#!/bin/zsh
# Double-click launcher for macOS. Installs dependencies on first run, builds
# the app, starts the local server on 127.0.0.1:4173 and opens the browser.
set -e
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
URL='http://127.0.0.1:4173'
pause_and_exit() { read -r '?Press Enter to close.'; exit 1; }
if ! command -v node >/dev/null 2>&1; then
  echo 'Node.js was not found. Install Node.js 22.13 or newer from https://nodejs.org and run this launcher again.'
  pause_and_exit
fi
if curl -fsS --max-time 2 "$URL/api/health" 2>/dev/null | grep -q '"openmri"'; then
  open "$URL"
  exit 0
fi
if /usr/sbin/lsof -iTCP:4173 -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo 'Port 4173 is used by another application. Close it and run this launcher again.'
  pause_and_exit
fi
# Rebuild whenever the checked-out revision changed, so a git pull never
# starts a stale build. The revision is remembered next to the build output.
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP='dist/.built-from'
if [[ ! -d node_modules || ! -d dist || "$(cat "$STAMP" 2>/dev/null)" != "$REVISION" ]]; then
  echo 'Installing JavaScript dependencies and building the application.'
  npm ci
  npm run build
  echo "$REVISION" > "$STAMP"
fi
if [[ ! -x .venv/bin/python ]]; then
  echo 'First run: preparing the Python processing environment.'
  npm run setup
fi
echo 'OpenMRI is starting locally. Keep this window open; press Control+C to stop.'
npm start &
SERVER_PID=$!
trap 'kill -TERM "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM
for _ in {1..60}; do
  if curl -fsS --max-time 2 "$URL/api/health" 2>/dev/null | grep -q '"openmri"'; then
    open "$URL"
    wait "$SERVER_PID"
    exit 0
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo 'The application failed to start. See the error above.'
    pause_and_exit
  fi
  sleep 1
done
echo "Startup is taking longer than a minute. Open $URL manually."
wait "$SERVER_PID"
