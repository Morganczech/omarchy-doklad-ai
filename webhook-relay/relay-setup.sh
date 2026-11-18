#!/usr/bin/env bash
# Deploys the Zero-Data webhook relay to your Cloudflare account and wires it to
# the Doklad.ai bar plugin. Secrets travel through stdin or a private temporary
# file only, never through command-line arguments.
#
#   ./relay-setup.sh deploy    build, deploy, generate + store the relay token
#   ./relay-setup.sh secret    upload the whsec_… secret after the webhook exists
#   ./relay-setup.sh status    check that the relay answers with your token
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$SCRIPT_DIR/../doklad.py"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
ENV_FILE="$CONFIG_ROOT/omarchy-doklad-ai/env"
# npm creates symlinks, which Omarchy does not allow inside a plugin folder, so
# the Worker is built in a private cache directory instead.
BUILD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-doklad-ai/webhook-relay"
SAFE_VALUE='^[A-Za-z0-9_.~+/=-]{16,512}$'

die() {
  echo "Chyba: $*" >&2
  exit 1
}

# Prints the value of one credential: process environment first, then the private env file.
read_secret() {
  local name="$1" line value
  value="${!name:-}"
  if [[ -z "$value" && -f "$ENV_FILE" && ! -L "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#export }"
      if [[ "$line" == "$name="* ]]; then
        value="${line#*=}"
      fi
    done <"$ENV_FILE"
    value="${value%$'\r'}"
    value="${value#[\"\']}"
    value="${value%[\"\']}"
  fi
  printf '%s' "$value"
}

store_secret() {
  local name="$1" value="$2"
  printf '%s\n' "$value" | /usr/bin/python3 -I -B "$BACKEND" set-secret "$name" >/dev/null \
    || die "hodnotu $name se nepodařilo uložit do $ENV_FILE"
}

prepare_build() {
  command -v npm >/dev/null 2>&1 || die "chybí Node.js a npm (například: mise use -g node)."
  [[ -f "$BACKEND" ]] || die "nenalezen doklad.py vedle složky webhook-relay."
  mkdir -p -- "$BUILD_DIR"
  chmod 700 -- "$BUILD_DIR"
  rm -rf -- "$BUILD_DIR/src" "$BUILD_DIR/test"
  cp -R -- "$SCRIPT_DIR/src" "$SCRIPT_DIR/test" "$BUILD_DIR/"
  cp -- "$SCRIPT_DIR/package.json" "$SCRIPT_DIR/package-lock.json" "$SCRIPT_DIR/tsconfig.json" \
    "$SCRIPT_DIR/wrangler.jsonc" "$BUILD_DIR/"
  cd -- "$BUILD_DIR"
  if [[ ! -d node_modules || package-lock.json -nt node_modules ]]; then
    echo "Instaluji nástroje pro nasazení (wrangler)…"
    npm ci --no-audit --no-fund >/dev/null
    touch node_modules
  fi
}

require_login() {
  if ! npx wrangler whoami >/dev/null 2>&1; then
    die "nejsi přihlášen ke Cloudflare. Spusť: (cd \"$BUILD_DIR\" && npx wrangler login) a pak tento příkaz znovu."
  fi
}

random_hex() {
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

cmd_deploy() {
  prepare_build
  require_login

  local relay_token webhook_secret placeholder=0
  relay_token="$(read_secret DOKLAD_RELAY_TOKEN)"
  if [[ ! "$relay_token" =~ $SAFE_VALUE || ${#relay_token} -lt 32 ]]; then
    relay_token="$(random_hex)"
    store_secret DOKLAD_RELAY_TOKEN "$relay_token"
    echo "Vygenerován nový DOKLAD_RELAY_TOKEN a uložen do $ENV_FILE (0600)."
  fi
  webhook_secret="$(read_secret DOKLAD_WEBHOOK_SECRET)"
  if [[ ! "$webhook_secret" =~ $SAFE_VALUE ]]; then
    # Until the real whsec_… secret is uploaded nobody can produce a valid signature.
    webhook_secret="placeholder_$(random_hex)"
    placeholder=1
  fi

  echo "Kontroluji a nasazuji Worker…"
  npm test >/dev/null || die "testy relay neprošly, nasazení zrušeno."

  local secrets_file output
  secrets_file="$(mktemp "$BUILD_DIR/.secrets.XXXXXX.json")"
  output="$(mktemp "$BUILD_DIR/.deploy.XXXXXX.log")"
  trap 'rm -f -- "${secrets_file:-}" "${output:-}"' EXIT
  printf '{"WEBHOOK_SECRET":"%s","RELAY_TOKEN":"%s"}\n' "$webhook_secret" "$relay_token" >"$secrets_file"

  if ! npx wrangler deploy --secrets-file "$secrets_file" 2>&1 | tee "$output"; then
    die "nasazení selhalo (viz výpis výše)."
  fi
  rm -f -- "$secrets_file"

  local relay_url
  relay_url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' "$output" | head -n 1 || true)"
  if [[ -z "$relay_url" ]]; then
    read -r -p "Zadej adresu nasazeného Workeru (https://…): " relay_url
  fi
  [[ "$relay_url" == https://* ]] || die "adresa relay musí začínat na https://"
  store_secret DOKLAD_RELAY_URL "$relay_url"

  echo
  echo "Relay běží na $relay_url a plugin o něm ví."
  if [[ "$placeholder" -eq 1 ]]; then
    echo
    echo "Zbývají dva kroky:"
    echo "  1) V panelu Doklad.ai otevři záložku „Exporty a webhooky“ a zvol „Zaregistrovat webhook“."
    echo "     (Případně webhook vytvoř ručně v Doklad.ai na adresu $relay_url/webhook"
    echo "      a jeho whsec_… secret ulož přes ./setup-env.sh.)"
    echo "  2) Pak spusť: $SCRIPT_DIR/relay-setup.sh secret"
  else
    echo "Webhook secret byl nahrán také, hotovo."
  fi
}

cmd_secret() {
  local webhook_secret
  webhook_secret="$(read_secret DOKLAD_WEBHOOK_SECRET)"
  [[ "$webhook_secret" =~ $SAFE_VALUE ]] \
    || die "v $ENV_FILE není DOKLAD_WEBHOOK_SECRET. Nejprve zaregistruj webhook v panelu pluginu."
  prepare_build
  require_login
  printf '%s' "$webhook_secret" | npx wrangler secret put WEBHOOK_SECRET
  echo "Webhook secret je nahraný. Relay teď přijímá podepsané události z Doklad.ai."
}

cmd_status() {
  local relay_url relay_token code
  relay_url="$(read_secret DOKLAD_RELAY_URL)"
  relay_token="$(read_secret DOKLAD_RELAY_TOKEN)"
  [[ "$relay_url" == https://* && -n "$relay_token" ]] || die "relay ještě není nastavený (spusť: relay-setup.sh deploy)."
  code="$(printf 'Authorization: Bearer %s\n' "$relay_token" \
    | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H @- "${relay_url%/}/events?after=0" || true)"
  case "$code" in
    200) echo "Relay odpovídá a token souhlasí." ;;
    401) die "relay odmítl token (401). Spusť znovu: relay-setup.sh deploy" ;;
    503) die "relay nemá nastavené secrets (503). Spusť znovu: relay-setup.sh deploy" ;;
    *) die "relay neodpovídá podle očekávání (HTTP ${code:-bez odpovědi})." ;;
  esac
}

case "${1:-}" in
  deploy) cmd_deploy ;;
  secret) cmd_secret ;;
  status) cmd_status ;;
  *)
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
