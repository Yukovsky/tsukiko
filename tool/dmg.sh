#!/bin/sh
# Собрать .dmg, который открывается окном «перетащите tsukiko в Программы».
#
# Зачем так, а не просто файл: приложение, запущенное из папки загрузок,
# macOS переносит в случайное место (app translocation) — и выданный ему
# «Универсальный доступ» перестаёт действовать при каждом запуске.
# Перетаскивание в «Программы» — не украшение, а условие работы диктовки.
#
# Запускать после `flutter build macos --release` и `./tool/sign.sh`.
set -e
cd "$(dirname "$0")/.."

APP=${APP:-build/macos/Build/Products/Release/tsukiko.app}
OUT=${OUT:-build/tsukiko.dmg}
VOLUME="tsukiko"

[ -d "$APP" ] || {
  echo "Нет собранного приложения. Сначала: flutter build macos --release && ./tool/sign.sh" >&2
  exit 1
}

# Подпись обязана быть на месте: dmg её не чинит, а только упаковывает.
codesign -v --deep --strict "$APP" || {
  echo "Приложение не подписано. Сначала ./tool/sign.sh" >&2
  exit 1
}

BACKGROUND=design/dmg-background.tiff
[ -f "$BACKGROUND" ] || {
  echo "Нет фона окна. Нарисовать: python3 tool/dmg-background.py" >&2
  exit 1
}

# Записываем .DS_Store прямо в образ: раскладка не зависит от Finder,
# разрешения на автоматизацию или уже открытого тома с тем же именем.
# Изолированное окружение сохраняет системный Python без изменений.
PYTHON=build/dmg-tools-venv/bin/python3
if [ ! -x "$PYTHON" ]; then
  python3 -m venv build/dmg-tools-venv
fi
"$PYTHON" -m pip install --disable-pip-version-check -q -r tool/requirements-dmg.txt
mkdir -p "$(dirname "$OUT")"
TSUKIKO_DMG_APP="$APP" "$PYTHON" -m dmgbuild --no-hidpi \
  -s tool/dmg-settings.py "$VOLUME" "$OUT"

# Образ подписывается тем же сертификатом, что и приложение: для нотаризации
# нужен «Developer ID Application» и метка времени Apple. Для разработческой
# подписи оставляем прежнее поведение — без метки и без требования успеха.
if [ -n "$TSUKIKO_SIGNING_KEYCHAIN" ]; then
  DMG_IDENTITIES=$(security find-identity -v -p codesigning "$TSUKIKO_SIGNING_KEYCHAIN")
else
  DMG_IDENTITIES=$(security find-identity -v -p codesigning)
fi
DMG_LINE=$(printf '%s\n' "$DMG_IDENTITIES" | grep -E '^[[:space:]]*[0-9]+\)' |
  grep 'Developer ID Application' | head -1)
if [ -n "$DMG_LINE" ]; then
  DMG_ID=$(printf '%s\n' "$DMG_LINE" | awk '{print $2}')
  codesign --force --sign "$DMG_ID" --timestamp "$OUT"
else
  DMG_ID=$(printf '%s\n' "$DMG_IDENTITIES" | grep -E '^[[:space:]]*[0-9]+\)' |
    awk 'NR==1 {print $2}')
  if [ -n "$DMG_ID" ]; then
    codesign --force --sign "$DMG_ID" --timestamp=none "$OUT" 2>/dev/null || true
  fi
fi

echo "готово: $OUT ($(du -h "$OUT" | cut -f1))"
