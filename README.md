# Doklad.ai — Omarchy bar plugin

Přehledy fakturací, DPH a cashflow přímo v liště Omarchy. Plugin mluví **česky** a **slovensky** (slovenština při jazyku shellu `sk`, jinak čeština).

![Přehled pluginu Doklad.ai v Omarchy](docs/screenshot.png)

## Instalace

Z GitHubu (Omarchy):

```bash
omarchy plugin add https://github.com/Morganczech/omarchy-doklad-ai --enable
# nebo po klonu:
./install.sh
```

Ručně z tohoto adresáře:

```bash
./install.sh
# případně: mkdir -p ~/.config/omarchy/plugins && rsync -a ./ ~/.config/omarchy/plugins/gruut.doklad-ai/
```

Widget `Doklad.ai` patří do baru. Plugin **neinstalujte** do `/usr/share/omarchy/` — to je jen pro systémové komponenty.

Primárně pro uživatele [Doklad.ai](https://doklad.ai) v ČR (české DPH, ARES, Pohoda/Money S3). UI je česky a slovensky.

## API klíč

```bash
./setup-env.sh
```

Výchozí volba je systémová klíčenka Secret Service. Potřebuješ `secret-tool` z balíčku `libsecret` a funkční odemčenou klíčenku (např. GNOME Keyring). Pro instalaci bez klíčenky zvol soubor `~/.config/omarchy-doklad-ai/env` s oprávněním `0600`. Token relay a podpisový klíč webhooku jsou uložené v tomto souboru.

Pro přesun stávajícího API klíče spusť `./setup-env.sh`, u klíče stiskni Enter a zvol klíčenku. Skript nejdřív ověří načtení klíče z klíčenky a pak smaže jeho původní hodnotu v privátním souboru. Pokud jsi dříve nastavil kopii v `environment.d`, skript nabídne její smazání. Po smazání se odhlas a znovu přihlas.

## Co umí

- Přehled: měsíc / kvartál / rok / 12 měsíců, YoY, DPH, obrat za kalendářní rok vůči limitu
- Faktury: filtry, detail, platba, e-mail, stav, PDF, smazání konceptu
- Nový doklad: faktura (výchozí **koncept**) a náklad; před zápisem potvrzení s přesnými částkami
- Zákazníci: ARES (CZ) / RPO (SK) podle IČO
- Exporty: CSV, ISDOC, Pohoda, Money S3, ZIP s PDF
- Volitelný webhook relay (Cloudflare Worker) s čítačem změn

Každá zapisující akce vyžaduje `ConfirmDialog`. Živé API sandbox nemá.

## Webhook relay (volitelné)

```bash
cd webhook-relay
./relay-setup.sh deploy          # nasadí Worker, uloží RELAY_URL + TOKEN
# v panelu → Exporty → „Zaregistrovat webhook“
./relay-setup.sh secret          # nahraje whsec_… do Cloudflare
./relay-setup.sh status
```

Build běží v `~/.cache/…` (npm symlinky by jinak shodily `omarchy plugin validate`).

Worker přijímá celé tělo webhooku, aby ověřil jeho podpis. V aktivní databázi drží jen čítač doručených změn a z něj se plugin dozví, že má načíst nové údaje přímo z Doklad.ai. Opakované doručení může čítač zvýšit znovu.

Při přechodu ze starší verze aktualizuj plugin a znovu nasaď Worker. Při prvním přístupu k úložišti se odstraní dříve ukládaná tabulka událostí. Historie obnovy SQLite v Cloudflare může starší záznamy uchovávat až 30 dní.

## Klávesy a IPC

| Klávesa | Akce |
|---------|------|
| `1`–`5` | Karty |
| `j`/`k` | Kurzor |
| Enter | Aktivovat |
| `/` | Hledat |
| `n` | Nový doklad |
| `r` | Obnovit |
| `p` | Skrýt částky |
| `o` | Otevřít Doklad.ai |

```bash
omarchy-shell gruut.doklad-ai toggle
omarchy-shell gruut.doklad-ai refresh
omarchy-shell gruut.doklad-ai togglePrivacy
omarchy-shell gruut.doklad-ai status
```

## Testy

```bash
/usr/bin/python3 -I -B -m unittest discover -s tests
node --test tests/model.test.mjs
(cd webhook-relay && npm test)   # po npm install v cache / lokálně
omarchy plugin validate .
```

## Bezpečnost

- Lokální cache a stav synchronizace jsou v privátním adresáři pod `~/.local/state/omarchy-doklad-ai/` nebo `$XDG_STATE_HOME`. Cache je svázaná s použitým klíčem a při odpovědi `401` se zneplatní.
- V **Exporty → Vymazat lokální data** lze cache a stav synchronizace smazat. Při další synchronizaci se vytvoří znovu. Stažené PDF a účetní exporty zůstávají ve složce `~/Downloads/Doklad.ai`.
- Cache a exporty mají oprávnění `0600` a obsahují nešifrované účetní údaje. Chraň je také v zálohách.
- Režim soukromí maskuje částky v přehledu a oznámení mají jen obecný popis. Potvrzovací dialogy dál zobrazují přesné částky. Pro podrobná oznámení plugin používá D-Bus přes `python-dbus`. Bez něj se posílají jen obecné názvy.
