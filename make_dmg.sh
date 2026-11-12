#!/bin/bash
# Gera o instalador dist/PrintShot-<versão>.dmg com a janela "arraste para Aplicativos".
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP="build/PrintShot.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOL="PrintShot"
STAGE="build/dmg"
RW="build/PrintShot-rw.dmg"
OUT="dist/PrintShot-$VERSION.dmg"

echo "▸ Montando o instalador…"
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
rm -rf "$STAGE" "$RW"; mkdir -p "$STAGE/.background" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicativos"
tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
cp "build/PrintShot.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')
sleep 1

# ícone do volume (se SetFile existir)
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "/Volumes/$VOL" || true; fi

echo "▸ Ajustando a janela (o macOS pode pedir permissão para o Terminal controlar o Finder — clique em OK)…"
osascript <<APPLESCRIPT || echo "⚠️  Não deu para ajustar a janela; o instalador funciona, mas sem o layout."
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "PrintShot.app" of container window to {165, 200}
    set position of item "Aplicativos" of container window to {495, 200}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" >/dev/null || hdiutil detach "$DEVICE" -force >/dev/null
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$RW" "$STAGE"
echo "✅ Instalador pronto: $OUT"
