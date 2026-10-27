#!/usr/bin/env bash
# install.sh — put nanotax on your PATH (~/.local/bin by default). No sudo.
#
#   curl -fsSL https://raw.githubusercontent.com/steven-matison/NanoTax/main/install.sh | bash
#   PREFIX=/opt/bin bash install.sh
set -euo pipefail

REPO="${NANOTAX_REPO:-steven-matison/NanoTax}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)/nanotax"

mkdir -p "$PREFIX"
if [[ -f $SRC ]]; then
  install -m 0755 "$SRC" "$PREFIX/nanotax"
else
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/nanotax" -o "$PREFIX/nanotax"
  chmod 0755 "$PREFIX/nanotax"
fi

echo "nanotax installed → $PREFIX/nanotax"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "add it to your PATH:  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
