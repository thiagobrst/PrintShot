#!/bin/bash
# Dois cliques: compila e gera dist/PrintShot-<versão>.dmg
cd "$(dirname "$0")"
./make_dmg.sh
open dist 2>/dev/null || true
