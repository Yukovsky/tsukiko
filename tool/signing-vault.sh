#!/bin/sh
# Зашифрованное хранилище для ключей подписи и нотаризации (.p12, .p8,
# пароль от .p12, Key ID, Issuer ID). Одно на все приложения.
#
# Хранилище — зашифрованный образ диска (AES-256) с одним паролем: пока он
# не открыт, ни одна программа ничего внутри не прочитает. Открывается
# только на время работы скрипта и сразу закрывается.
#
#   ./tool/signing-vault.sh init [путь.p12 путь.p8]  создать хранилище
#                                                    и перенести в него файлы
#   ./tool/signing-vault.sh upload [владелец/репо]   загрузить секреты в GitHub
#                                                    (окружение release)
#   ./tool/signing-vault.sh open                     открыть, посмотреть, закрыть
#
# Где лежит: VAULT=путь переопределяет место
# (по умолчанию ~/Library/Application Support/Signing Vault).
set -e
cd "$(dirname "$0")/.."

VAULT_DIR=${VAULT:-"$HOME/Library/Application Support/Signing Vault"}
BUNDLE="$VAULT_DIR/vault.sparsebundle"
MNT=

ask() { printf '%s' "$1" >&2; read -r REPLY; printf '%s' "$REPLY"; }
ask_secret() { printf '%s' "$1" >&2; stty -echo 2>/dev/null || true; read -r REPLY; stty echo 2>/dev/null || true; echo >&2; printf '%s' "$REPLY"; }
clean_path() { printf '%s' "$1" | sed -e "s/^['\"]//" -e "s/['\"]$//" -e 's/\\ / /g'; }

detach() {
  stty echo 2>/dev/null || true
  if [ -n "$MNT" ] && [ -d "$MNT" ]; then
    hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
  fi
}
trap detach EXIT

attach() {
  [ -d "$BUNDLE" ] || { echo "Хранилища нет. Сначала: ./tool/signing-vault.sh init" >&2; exit 1; }
  MNT=$(mktemp -d)
  PASSWORD=$(ask_secret "Пароль хранилища: ")
  printf '%s' "$PASSWORD" | hdiutil attach "$BUNDLE" -stdinpass -nobrowse -mountpoint "$MNT" -quiet ||
    { echo "Не открылось: неверный пароль?" >&2; rmdir "$MNT" 2>/dev/null; MNT=; exit 1; }
}

case "${1:-}" in
init)
  [ ! -d "$BUNDLE" ] || { echo "Хранилище уже есть: $BUNDLE" >&2; exit 1; }
  P12=${2:-$(clean_path "$(ask "Путь к .p12: ")")}
  KEY=${3:-$(clean_path "$(ask "Путь к AuthKey_XXXX.p8: ")")}
  [ -f "$P12" ] && [ -f "$KEY" ] || { echo "Файл не найден." >&2; exit 1; }
  P12_PASSWORD=$(ask_secret "Пароль от .p12: ")
  KEY_ID=$(ask "Key ID: ")
  ISSUER=$(ask "Issuer ID: ")
  PASSWORD=$(ask_secret "Придумайте пароль хранилища: ")
  AGAIN=$(ask_secret "Повторите пароль: ")
  [ "$PASSWORD" = "$AGAIN" ] && [ -n "$PASSWORD" ] || { echo "Пароли не совпали." >&2; exit 1; }
  mkdir -p "$VAULT_DIR"
  printf '%s' "$PASSWORD" | hdiutil create "$BUNDLE" -size 20m -type SPARSEBUNDLE -fs APFS \
    -encryption AES-256 -stdinpass -volname "Signing Vault" -quiet
  MNT=$(mktemp -d)
  printf '%s' "$PASSWORD" | hdiutil attach "$BUNDLE" -stdinpass -nobrowse -mountpoint "$MNT" -quiet
  cp "$P12" "$MNT/developer-id.p12"
  cp "$KEY" "$MNT/$(basename "$KEY")"
  umask 077
  {
    printf 'P12_FILE=%s\n' "developer-id.p12"
    printf 'P12_PASSWORD=%s\n' "$P12_PASSWORD"
    printf 'KEY_FILE=%s\n' "$(basename "$KEY")"
    printf 'KEY_ID=%s\n' "$KEY_ID"
    printf 'ISSUER=%s\n' "$ISSUER"
  } > "$MNT/vault.env"
  detach; MNT=
  echo "Хранилище создано: $BUNDLE"
  echo "Проверьте, что открывается: ./tool/signing-vault.sh open"
  ANSWER=$(ask "Стереть исходные .p12 и .p8 безвозвратно? Делайте это только после проверки [y/N] ")
  if [ "$ANSWER" = "y" ]; then rm -P "$P12" "$KEY"; fi
  ;;
upload)
  attach
  # Читаем построчно, а не `source`: пароль может содержать любые символы.
  field() { sed -n "s/^$1=//p" "$MNT/vault.env" | head -1; }
  P12="$MNT/$(field P12_FILE)" P12_PASSWORD="$(field P12_PASSWORD)" KEY="$MNT/$(field KEY_FILE)" \
    KEY_ID="$(field KEY_ID)" ISSUER="$(field ISSUER)" KEEP_FILES=1 \
    ./tool/setup-signing-secrets.sh "${2:-Yukovsky/tsukiko}"
  ;;
open)
  attach
  echo "Открыто: $MNT"
  ls -1 "$MNT"
  ask "Enter — закрыть хранилище. " >/dev/null
  ;;
*)
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  ;;
esac
