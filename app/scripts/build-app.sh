#!/bin/bash
# Compila Switchpanel.app y la instala en ~/Applications.
# Uso: scripts/build-app.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Switchpanel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Switchpanel" "$APP/Contents/MacOS/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Switchpanel</string>
    <key>CFBundleDisplayName</key><string>Switchpanel</string>
    <key>CFBundleIdentifier</key><string>com.emilianosuarez.switchpanel</string>
    <key>CFBundleExecutable</key><string>Switchpanel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Switchpanel uses Terminal to take you to each session's tab.</string>
</dict>
</plist>
PLIST

# Firma estable (certificado de desarrollo si existe) para que macOS recuerde el permiso de Automatización.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Firmado con: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" != "--no-install" ]]; then
    pkill -x Switchpanel 2>/dev/null || true
    # Esperar a que termine: si abrimos mientras se cierra, macOS reactiva la instancia que muere.
    for _ in {1..50}; do pgrep -x Switchpanel >/dev/null || break; sleep 0.1; done
    mkdir -p ~/Applications
    rm -rf ~/Applications/Switchpanel.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Switchpanel.app
    echo "Instalada en ~/Applications/Switchpanel.app"
fi
