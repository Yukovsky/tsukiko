#!/bin/sh
# Положить секреты подписи и нотаризации в окружение release на GitHub.
#
# Запускать самому, в своём терминале: скрипт спрашивает пароли и пути,
# проверяет сертификат во временной связке ключей и загружает всё прямо
# в GitHub. Содержимое .p12 и .p8 никуда не печатается.
#
# Что нужно заранее:
#   1. «Developer ID Application» экспортирован из «Связки ключей» в .p12
#      (с паролем — любым, его скрипт заберёт у вас и положит в секрет).
#   2. В App Store Connect → Пользователи и доступ → Интеграции создан ключ
#      API (роль Developer), скачан AuthKey_XXXX.p8; под списком ключей
#      записан Issuer ID.
#   3. gh залогинен: gh auth status.
#
# Использование: ./tool/setup-signing-secrets.sh [владелец/репозиторий]
set -e

REPO=${1:-Yukovsky/tsukiko}
ENVIRONMENT=release

ask() { printf '%s' "$1" >&2; read -r REPLY; printf '%s' "$REPLY"; }
ask_secret() { printf '%s' "$1" >&2; stty -echo; read -r REPLY; stty echo; echo >&2; printf '%s' "$REPLY"; }
# Значение идёт через stdin, а не аргументом: так оно не видно в списке процессов.
put() { printf '%s' "$2" | gh secret set "$1" --env "$ENVIRONMENT" --repo "$REPO" >/dev/null && echo "  ✓ $1"; }

gh auth status >/dev/null 2>&1 || { echo "Сначала войдите: gh auth login" >&2; exit 1; }

P12=$(ask "Путь к .p12 (можно перетащить файл в окно): ")
P12=$(printf '%s' "$P12" | sed -e "s/^['\"]//" -e "s/['\"]$//" -e 's/\\ / /g')
[ -f "$P12" ] || { echo "Нет такого файла." >&2; exit 1; }
P12_PASSWORD=$(ask_secret "Пароль от .p12: ")

# Проверка: импорт во временную связку. Заодно оттуда берётся Team ID.
WORK=$(mktemp -d)
KEYCHAIN="$WORK/check.keychain-db"
cleanup() { security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; rm -rf "$WORK"; stty echo 2>/dev/null || true; }
trap cleanup EXIT
KPASS=$(openssl rand -hex 16)
security create-keychain -p "$KPASS" "$KEYCHAIN"
security unlock-keychain -p "$KPASS" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
LINE=$(security find-identity -v -p codesigning "$KEYCHAIN" | grep 'Developer ID Application' | head -1)
[ -n "$LINE" ] || { echo "В файле нет «Developer ID Application». Нужен именно он." >&2; exit 1; }
TEAM=$(printf '%s' "$LINE" | sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/')
echo "Сертификат найден, Team ID: $TEAM"

KEY=$(ask "Путь к AuthKey_XXXX.p8 (Enter — без нотаризации): ")
KEY=$(printf '%s' "$KEY" | sed -e "s/^['\"]//" -e "s/['\"]$//" -e 's/\\ / /g')
if [ -n "$KEY" ]; then
  [ -f "$KEY" ] || { echo "Нет такого файла." >&2; exit 1; }
  KEY_ID=$(ask "Key ID (10 символов): ")
  ISSUER=$(ask "Issuer ID (UUID): ")
fi

echo "Загружаю секреты в $REPO, окружение $ENVIRONMENT:"
put MACOS_SIGNING_P12_BASE64 "$(base64 -i "$P12" | tr -d '\n')"
put MACOS_SIGNING_P12_PASSWORD "$P12_PASSWORD"
put MACOS_TEAM_ID "$TEAM"
if [ -n "$KEY" ]; then
  put MACOS_NOTARY_KEY_BASE64 "$(base64 -i "$KEY" | tr -d '\n')"
  put MACOS_NOTARY_KEY_ID "$KEY_ID"
  put MACOS_NOTARY_ISSUER_ID "$ISSUER"
fi

ANSWER=$(ask "Удалить старые секреты уровня репозитория (иначе они доступны без окружения)? [y/N] ")
if [ "$ANSWER" = "y" ]; then
  for name in MACOS_SIGNING_P12_BASE64 MACOS_SIGNING_P12_PASSWORD MACOS_TEAM_ID; do
    gh secret delete "$name" --repo "$REPO" >/dev/null 2>&1 && echo "  удалён $name"
  done
fi

ANSWER=$(ask "Стереть локальные .p12 и .p8 безвозвратно? [y/N] ")
if [ "$ANSWER" = "y" ]; then
  rm -P "$P12"
  [ -n "$KEY" ] && rm -P "$KEY"
fi
echo "Готово. Сертификат в Связке ключей остаётся — он нужен для подписи локально."
