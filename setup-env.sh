#!/usr/bin/env bash
# Stores the Doklad.ai credentials in a private file only you can read:
#   ~/.config/omarchy-doklad-ai/env   (directory 0700, file 0600)
#
# The key is typed without echo and handed to the backend through stdin, so it
# never shows up in the shell history or in the process list.
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
  store DOKLAD_API_KEY "$API_KEY"
  echo "API klíč uložen."
elif [[ ! -f "$PRIVATE_ENV" ]]; then
  echo "Chyba: API klíč je povinný." >&2
  exit 1
fi
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
echo "Uloženo do $PRIVATE_ENV (čitelné jen pro tebe, platí okamžitě)."

# Optional: export the same values to the whole desktop session through
# systemd's environment.d. The plugin does not need it, and it makes the key
# readable by every program you start, so the default answer is no.
echo
echo "Plugin si klíč čte přímo z tohoto souboru. Navíc ho lze vystavit jako proměnnou"
echo "prostředí celé relaci (~/.config/environment.d), pak ho ale uvidí každý program,"
echo "který spustíš."
read -r -p "Vystavit klíče i celé relaci? [a/N]: " WRITE_ENVD
if [[ "${WRITE_ENVD:-}" =~ ^[AaYy]$ ]]; then
  [[ ! -L "$ENVD_FILE" ]] || { echo "Chyba: $ENVD_FILE je symbolický odkaz." >&2; exit 1; }
  mkdir -p -- "$(dirname -- "$ENVD_FILE")"
  ENVD_TMP="$(mktemp "$(dirname -- "$ENVD_FILE")/.doklad-ai.XXXXXX")"
  grep '^DOKLAD_' "$PRIVATE_ENV" >"$ENVD_TMP"
  mv -f -- "$ENVD_TMP" "$ENVD_FILE"
  chmod 600 -- "$ENVD_FILE"
  echo "Zapsáno do $ENVD_FILE (0600). Projeví se po příštím přihlášení."
elif [[ -f "$ENVD_FILE" && ! -L "$ENVD_FILE" ]]; then
  # A copy left there earlier would silently override the values stored above.
  echo "V $ENVD_FILE zůstala dřívější kopie klíčů, která má přednost před novým nastavením."
  read -r -p "Smazat ji? [A/n]: " REMOVE_ENVD
  if [[ ! "${REMOVE_ENVD:-A}" =~ ^[Nn]$ ]]; then
    rm -f -- "$ENVD_FILE"
    echo "Smazáno. Projeví se po příštím přihlášení."
  fi
fi

echo
echo "Ověřuji spojení s Doklad.ai…"
if env -u DOKLAD_API_KEY /usr/bin/python3 -I -B "$BACKEND" verify-auth; then
  echo "Hotovo, klíč funguje."
else
  echo "Ověření selhalo. Zkontroluj klíč a připojení k internetu." >&2
  exit 1
fi
