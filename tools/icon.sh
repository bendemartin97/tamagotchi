#!/bin/bash
# Erzeugt AppIcon.icns aus einem 1024er-PNG. Ohne Argument wird das Pixel-Haustier als Platzhalter gerendert.
# Aufruf: tools/icon.sh [icon.png]
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
SRC="${1:-}"
if [ -z "$SRC" ]; then
  cp "$D/tools/pixel-icon.swift" "$TMP/main.swift"
  swiftc "$TMP/main.swift" "$D/Sprite.swift" -o "$TMP/pixel-icon"
  SRC="$TMP/icon.png"
  "$TMP/pixel-icon" "$SRC"
fi
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$D/AppIcon.icns"
cp "$SRC" "$D/icon.png"
rm -rf "$TMP"
echo "AppIcon.icns aktualisiert"
