#!/bin/bash
# Compila o PrintShot.app (Apple Silicon) usando apenas as Command Line Tools.
# Uso:  ./build.sh            → gera build/PrintShot.app
#       ./build.sh install    → também copia para /Applications e abre
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PrintShot"
APP="build/$APP_NAME.app"
ARCH="$(uname -m)"   # arm64 no M1/M2/M3/M4

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ swiftc não encontrado. Instale as ferramentas com:  xcode-select --install"
  exit 1
fi

echo "▸ Compilando ($ARCH)…"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
  -framework Carbon -framework ServiceManagement -framework UniformTypeIdentifiers \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Gerando ícone…"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Assinando…"
# Se existir um certificado próprio (veja o README), a permissão de Gravação de Tela
# sobrevive a recompilações. Sem ele, usa assinatura ad-hoc.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "PrintShot Dev"; then
  IDENTITY="PrintShot Dev"
fi
codesign --force --deep --sign "${IDENTITY:--}" --identifier app.printshot.PrintShot "$APP"

echo "✅ Pronto: $APP"

if [ "${1:-}" = "install" ]; then
  echo "▸ Instalando em /Applications…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✅ Instalado e aberto. Procure o ícone 📷 na barra de menus."
fi
