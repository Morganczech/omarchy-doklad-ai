#!/usr/bin/env bash
# Nainstaluje plugin do Omarchy a zapne ho v pravé části baru.
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/gruut.doklad-ai"

mkdir -p -- "$(dirname -- "$DST")"
rm -rf -- "$DST"
mkdir -p -- "$DST"

rsync -a \
  --exclude '.git' \
  --exclude '.claude' \
  --exclude '.cursor' \
  --exclude 'webhook-relay/node_modules' \
  --exclude 'webhook-relay/.wrangler' \
  --exclude 'webhook-relay/worker-configuration.d.ts' \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '.env' \
  --exclude 'env' \
  "$SRC/" "$DST/"

chmod +x "$DST/setup-env.sh" "$DST/webhook-relay/relay-setup.sh"
omarchy plugin validate "$DST"

echo "Nainstalováno do $DST"
if omarchy-shell shell rescanPlugins >/dev/null 2>&1; then
  omarchy plugin enable gruut.doklad-ai --section right
  echo "Plugin je v baru (vpravo). Další krok: $DST/setup-env.sh"
else
  echo "Shell teď neběží nebo neodpovídá. Plugin je nainstalovaný;"
  echo "po startu Omarchy spusť: omarchy plugin enable gruut.doklad-ai --section right"
  echo "Pak: $DST/setup-env.sh"
fi
