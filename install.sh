#!/bin/bash
# Installs Switchpanel: hooks in Claude Code's settings and the menu bar app in ~/Applications.
# Usage: ./install.sh [--no-app] [installer options]   (./install.sh --help for the options)
set -euo pipefail
cd "$(dirname "$0")"

[[ "$(uname)" == Darwin ]] || { echo "Switchpanel only runs on macOS." >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Install the Xcode Command Line Tools first: xcode-select --install" >&2; exit 1; }

BUILD_APP=1
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-app) BUILD_APP=0 ;;
        --dry-run|-h|--help) BUILD_APP=0; ARGS+=("$arg") ;;
        *) ARGS+=("$arg") ;;
    esac
done

/usr/bin/python3 scripts/installer.py install ${ARGS[@]+"${ARGS[@]}"}
if (( BUILD_APP )); then
    echo
    app/scripts/build-app.sh
fi
