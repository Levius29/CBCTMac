#!/usr/bin/env bash
# One-line installer for OpenMRI on macOS and Linux:
#
#   curl -fsSL https://raw.githubusercontent.com/lev1nson/OpenMRI/main/install.sh | bash
#
# Installs what is missing (through Homebrew on macOS), puts the app in
# ~/OpenMRI, starts the local server, loads the demo study and opens it in the
# browser. Run it again at any time to update. Nothing is uploaded anywhere:
# the app runs on 127.0.0.1 only.
#
# OPENMRI_DIR changes the install folder, OPENMRI_REPO the Git source.
set -euo pipefail

REPO="${OPENMRI_REPO:-https://github.com/lev1nson/OpenMRI.git}"
DIR="${OPENMRI_DIR:-$HOME/OpenMRI}"
NODE_MIN='22.13.0'
PYTHONS=(python3.12 python3.13 python3.14)

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# True when the first dotted version is at least the second.
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]; }

node_ok() { has node && version_ge "$(node -p 'process.versions.node' 2>/dev/null || echo 0)" "$NODE_MIN"; }
git_ok() { git --version >/dev/null 2>&1; }  # the macOS stub fails without the command line tools
python_ok() {
  local py
  for py in "${PYTHONS[@]}"; do
    has "$py" && "$py" -c 'import venv, ensurepip' >/dev/null 2>&1 && return 0
  done
  return 1
}

# The script arrives through a pipe, so questions are read from the terminal.
ask() {
  local answer=''
  [[ -r /dev/tty ]] || return 1
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r answer </dev/tty || return 1
  [[ "$answer" =~ ^[Yy] ]]
}

load_brew() {
  local brew
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$brew" ]] && eval "$("$brew" shellenv)" && return 0
  done
  return 1
}

# New terminal windows must find Homebrew too, or npm run up and npm run down
# fail later with "command not found". This is the step Homebrew itself asks for.
remember_brew() {
  local profile="$HOME/.zprofile" line
  [[ "${SHELL:-}" == */bash ]] && profile="$HOME/.bash_profile"
  line="eval \"\$($(command -v brew) shellenv)\""
  grep -qsF "$line" "$profile" && return 0
  printf '\n%s\n' "$line" >>"$profile"
  say "Added Homebrew to $profile so new terminal windows find it."
}

prepare_macos() {
  local brew_on_path=0
  has brew && brew_on_path=1
  if ! load_brew; then
    say 'OpenMRI needs Node.js, Python and Git. On macOS they are installed with Homebrew, which is not on this Mac yet.'
    ask 'Install Homebrew now? It asks for your password.' ||
      fail 'Install Homebrew from https://brew.sh and run this command again.'
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    load_brew || fail 'Homebrew was installed but could not be found. Open a new terminal and run this command again.'
  fi
  if ((brew_on_path == 0)); then remember_brew; fi
  local missing=()
  git_ok || missing+=(git)
  node_ok || missing+=(node)
  python_ok || missing+=(python@3.12)
  if ((${#missing[@]})); then
    say "Installing with Homebrew: ${missing[*]}"
    brew install "${missing[@]}"
  fi
}

prepare_linux() {
  local problems=()
  git_ok || problems+=('Git: sudo apt install git (or dnf install git)')
  node_ok || problems+=("Node.js $NODE_MIN or newer: https://nodejs.org/en/download (distribution packages are usually too old)")
  python_ok || problems+=('Python 3.12, 3.13 or 3.14 with venv: sudo apt install python3 python3-venv (or dnf install python3)')
  if ((${#problems[@]})); then
    printf '\nInstall these first, then run this command again:\n' >&2
    printf '  - %s\n' "${problems[@]}" >&2
    exit 1
  fi
}

main() {
  case "$(uname -s)" in
    Darwin) prepare_macos ;;
    Linux) prepare_linux ;;
    *) fail 'This installer supports macOS and Linux. On Windows, run it inside WSL.' ;;
  esac
  node_ok || fail "Node.js $NODE_MIN or newer is required; found $(node --version 2>/dev/null || echo none)."

  if [[ -d "$DIR/.git" ]]; then
    say "Updating $DIR"
    git -C "$DIR" pull --ff-only || say 'Could not update (local changes?). Starting the version that is there.'
  elif [[ -e "$DIR" ]]; then
    fail "$DIR exists and is not an OpenMRI checkout. Move it away or set OPENMRI_DIR to another folder."
  else
    say "Downloading OpenMRI into $DIR"
    git clone --depth 1 "$REPO" "$DIR"
  fi

  cd "$DIR"
  say 'Preparing OpenMRI. The first run downloads about 1 GB and takes a few minutes.'
  bash scripts/server.sh start --no-open
  node scripts/demo.mjs

  say 'OpenMRI is running at http://127.0.0.1:4173'
  cat <<EOF
Import your own scans with the Import MRI button. They stay on this computer.

  Stop:        cd "$DIR" && npm run down
  Start again: cd "$DIR" && npm run up
  Update:      run the same curl command again
EOF
}

main "$@"
