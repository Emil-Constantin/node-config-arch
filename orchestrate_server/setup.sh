#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "This setup needs administrator privileges to install Python." >&2
        exit 1
    fi
}

install_python() {
    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get update
        run_as_root apt-get install -y python3 python3-venv python3-pip
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y python3 python3-pip
    elif command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y python3 python3-pip
    elif command -v brew >/dev/null 2>&1; then
        brew install python
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -Syu python python-pip btop --noconfirm
    else
        echo "Could not find a supported package manager (apt, dnf, yum, or brew)." >&2
        exit 1
    fi
}

install_btop() {
    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get update
        run_as_root apt-get install -y btop
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y btop
    elif command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y btop
    elif command -v brew >/dev/null 2>&1; then
        brew install btop
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -S --needed --noconfirm btop
    else
        echo "Could not find a supported package manager (apt, dnf, yum, pacman, or brew)." >&2
        exit 1
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    install_python
fi

if ! python3 -c "import venv" >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get install -y python3-venv
    else
        echo "Python's venv module is unavailable. Install the Python venv package and rerun." >&2
        exit 1
    fi
fi

if ! command -v btop >/dev/null 2>&1; then
    install_btop
fi

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip
"$APP_DIR/.venv/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

echo "Setup complete. Start the app with:"
echo "  cd \"$APP_DIR\" && \"$APP_DIR/.venv/bin/python\" app.py"
