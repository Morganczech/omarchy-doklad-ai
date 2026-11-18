#!/usr/bin/env bash
# Reads credentials without echo and passes them through stdin.
set -euo pipefail
umask 077

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
PRIVATE_DIR="$CONFIG_ROOT/omarchy-doklad-ai"
PRIVATE_ENV="$PRIVATE_DIR/env"
ENVD_FILE="$CONFIG_ROOT/environment.d/doklad-ai.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$SCRIPT_DIR/doklad.py"

[[ -f "$BACKEND" ]] || { echo "Chyba: nenalezen $BACKEND" >&2; exit 1; }

store() {
  printf '%s\n' "$2" | /usr/bin/python3 -I -B "$BACKEND" set-secret "$1" >/dev/null || {
    echo "Chyba: hodnotu $1 se nepodařilo uložit (obsahuje nepovolené znaky?)." >&2
    exit 1
  }
}

echo "=== Doklad.ai pro Omarchy: bezpečné uložení přístupových údajů ==="
echo
echo "API klíč vytvoříš v Doklad.ai: Nastavení → Integrace → API klíče a webhooky → Nový klíč."
echo "Klíč začíná na dk_ a má plný přístup k datům firmy. Při psaní se nezobrazuje."
echo

if [[ -L "$PRIVATE_ENV" || -L "$PRIVATE_DIR" ]]; then
  echo "Chyba: $PRIVATE_ENV je symbolický odkaz, odmítám do něj zapisovat." >&2
  exit 1
fi
mkdir -p -- "$PRIVATE_DIR"
chmod 700 -- "$PRIVATE_DIR"
if [[ -f "$PRIVATE_ENV" ]]; then
  chmod 600 -- "$PRIVATE_ENV"
  echo "Nalezeno existující nastavení. Prázdná odpověď (Enter) ponechá uloženou hodnotu."
  echo
fi

read -r -s -p "DOKLAD_API_KEY (dk_…): " API_KEY
echo
if [[ -n "$API_KEY" ]]; then
  if [[ "$API_KEY" != dk_* ]]; then
    read -r -p "Klíč nezačíná na dk_. Přesto uložit? [a/N]: " CONFIRM
    [[ "${CONFIRM:-}" =~ ^[AaYy]$ ]] || exit 1
  fi
fi
read -r -p "Uložení API klíče: systémová klíčenka, nebo soubor 0600? [K/s]: " STORAGE
case "${STORAGE:-K}" in
  K|k) STORAGE=keyring ;;
  S|s) STORAGE=file ;;
  *) echo "Neplatná volba." >&2; exit 1 ;;
esac
if ! printf '%s\n' "$API_KEY" | /usr/bin/python3 -I -B "$BACKEND" configure-api-key "$STORAGE" >/dev/null; then
  echo "Ověř dostupnost odemčené klíčenky Secret Service a programu secret-tool, případně zvol soubor 0600." >&2
  exit 1
fi
echo "API klíč uložen."
unset API_KEY

echo
echo "Volitelné: okamžitá oznámení přes Cloudflare relay."
echo "Nejjednodušší je nechat vše prázdné a spustit webhook-relay/relay-setup.sh deploy,"
echo "který adresu i token vyplní sám."
read -r -p "DOKLAD_RELAY_URL (https://…, Enter = beze změny): " RELAY_URL
if [[ -n "$RELAY_URL" ]]; then
  [[ "$RELAY_URL" == https://* ]] || { echo "Chyba: adresa musí začínat na https://" >&2; exit 1; }
  store DOKLAD_RELAY_URL "$RELAY_URL"
  read -r -s -p "DOKLAD_RELAY_TOKEN (Enter = beze změny): " RELAY_TOKEN
  echo
  [[ -z "$RELAY_TOKEN" ]] || store DOKLAD_RELAY_TOKEN "$RELAY_TOKEN"
  unset RELAY_TOKEN
fi
read -r -s -p "DOKLAD_WEBHOOK_SECRET (whsec_…, Enter = beze změny): " WEBHOOK_SECRET
echo
[[ -z "$WEBHOOK_SECRET" ]] || store DOKLAD_WEBHOOK_SECRET "$WEBHOOK_SECRET"
unset WEBHOOK_SECRET

echo
echo "Nastavení uloženo."

if [[ -f "$ENVD_FILE" && ! -L "$ENVD_FILE" ]]; then
  echo "V $ENVD_FILE zůstala dřívější kopie klíčů pro celou relaci."
  read -r -p "Smazat ji? [A/n]: " REMOVE_ENVD
  if [[ ! "${REMOVE_ENVD:-A}" =~ ^[Nn]$ ]]; then
    rm -f -- "$ENVD_FILE"
    echo "Kopie smazána. Odhlas se a přihlas, aby se staré hodnoty uvolnily z relace."
  fi
fi
