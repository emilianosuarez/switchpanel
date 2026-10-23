#!/bin/bash
# Removes Switchpanel: its hooks from Claude Code's settings and the app from ~/Applications.
# Usage: ./uninstall.sh [--purge] [--yes] [--dry-run]   (--purge also deletes ~/.switchpanel)
set -euo pipefail
cd "$(dirname "$0")"

/usr/bin/python3 scripts/installer.py uninstall "$@"
[[ " $* " == *" --dry-run "* || " $* " == *" --help "* || " $* " == *" -h "* ]] && exit 0

pkill -x Switchpanel 2>/dev/null || true
rm -rf ~/Applications/Switchpanel.app
if [[ " $* " == *" --purge "* ]]; then
    defaults delete com.emilianosuarez.switchpanel 2>/dev/null || true
fi
echo "App removed. If you had \"Open at login\" on, you can also clear it in System Settings → General → Login Items."
