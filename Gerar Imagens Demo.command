#!/bin/bash
# Gera as imagens de divulgação (docs/screenshots) usando o código real do app.
cd "$(dirname "$0")"
mkdir -p build
SRCS=$(ls Sources/*.swift | grep -v '/main.swift$')
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info.plist \
  $SRCS Demo/main.swift -o build/PrintShotDemo && \
./build/PrintShotDemo Demo/backdrop.png build/demo-out
