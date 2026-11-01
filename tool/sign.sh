#!/bin/sh
# Подписать собранное приложение постоянной подписью разработчика.
#
# Зачем: macOS привязывает выданное разрешение («Универсальный доступ»)
# к подписи приложения. Flutter собирает с ad-hoc
# подписью, а её отпечаток меняется с каждой сборкой — выданное разрешение
# после пересборки перестаёт действовать, и диктовка молча замолкает.
# Подпись сертификатом из связки ключей одна и та же от сборки к сборке,
# поэтому разрешение выдаётся один раз.
#
# Заодно кладёт внутрь движок whisper.cpp — его надо собрать заранее,
# один раз: ./tool/engine.sh
#
# Запускать после `flutter build macos --release`.
set -e
cd "$(dirname "$0")/.."

APP=build/macos/Build/Products/Release/tsukiko.app
# Строка «0 valid identities found» — итог, а не сертификат. Прежний awk
# принимал слово `valid` за его идентификатор, и codesign закономерно падал.
if [ -n "$TSUKIKO_SIGNING_KEYCHAIN" ]; then
  IDENTITIES=$(security find-identity -v -p codesigning "$TSUKIKO_SIGNING_KEYCHAIN")
else
  IDENTITIES=$(security find-identity -v -p codesigning)
fi
# «Developer ID Application» — сертификат для раздачи вне App Store, под
# нотаризацию годится только он; при его наличии берём его, а не
# «Apple Development».
LINE=$(printf '%s\n' "$IDENTITIES" | grep -E '^[[:space:]]*[0-9]+\)' |
  grep 'Developer ID Application' | head -1)
[ -n "$LINE" ] ||
  LINE=$(printf '%s\n' "$IDENTITIES" | grep -E '^[[:space:]]*[0-9]+\)' | head -1)
ID=$(printf '%s\n' "$LINE" | awk '{print $2}')
# Hardened runtime обязателен для нотаризации и не нужен для разработческой
# подписи, где только мешал бы отладке.
RUNTIME=
case "$LINE" in *'Developer ID Application'*) RUNTIME="--options=runtime" ;; esac
if [ -z "$ID" ]; then
  if [ -n "$TSUKIKO_ADHOC_SIGN" ] && [ -z "$CI" ]; then
    echo "Локальная тестовая сборка: ad-hoc подпись (-)."
    ID="-"
  else
    echo "Нет сертификата для постоянной подписи. Сборка с ad-hoc подписью потеряет разрешение «Универсальный доступ» после обновления." >&2
    exit 1
  fi
fi

# Движок едет внутри приложения: у всех один и тот же, не зависит от того,
# что стоит у человека в системе, и не пропадает, если он снесёт Homebrew.
# Собирается отдельно — tool/engine.sh.
ENGINE=macos/Engine
if [ ! -x "$ENGINE/tsukiko-recognizer" ] || [ ! -x "$ENGINE/tsukiko-dictation" ] ||
  [ ! -x "$ENGINE/nemo/bin/nemo-speech" ]; then
  echo "Нет движка в $ENGINE. Соберите: ./tool/engine.sh" >&2
  exit 1
fi
# Helpers — место для вложенных программ, и по правилам подписи там
# не должно лежать ничего, кроме них: лицензия едет в Resources.
mkdir -p "$APP/Contents/Helpers"
cp "$ENGINE/tsukiko-recognizer" "$ENGINE/tsukiko-dictation" "$APP/Contents/Helpers/"
cp "$ENGINE/whisper.cpp-LICENSE.txt" "$APP/Contents/Resources/"
if [ -d "icon/Tsukiko.icon" ]; then
  rm -rf "$APP/Contents/Resources/AppIcon.icon"
  cp -R "icon/Tsukiko.icon" "$APP/Contents/Resources/AppIcon.icon"
fi
rm -rf "$APP/Contents/Helpers/nemo"
# В Helpers macOS разрешает только вложенный код. Официальный архив NeMo
# кроме бинарника и dylib содержит CMake-файлы, индекс и лицензии; если
# скопировать его целиком, codesign принимает первый Markdown за неподписанный
# subcomponent и отказывается запечатывать всё приложение. Runtime оставляем
# рядом с исполняемым файлом (его rpath — ../lib), а данные и лицензии кладём
# в положенное им Contents/Resources.
mkdir -p "$APP/Contents/Helpers/nemo"
cp -R "$ENGINE/nemo/bin" "$ENGINE/nemo/lib" "$APP/Contents/Helpers/nemo/"
rm -rf "$APP/Contents/Helpers/nemo/lib/cmake"
rm -rf "$APP/Contents/Resources/nemo-speech"
mkdir -p "$APP/Contents/Resources/nemo-speech"
cp -R "$ENGINE/nemo/share/." "$APP/Contents/Resources/nemo-speech/"

# Расшифровщик из командной строки. Едет рядом с движком, потому что
# он такая же вложенная программа: скрипту и нейросетевому агенту нужен
# текст, а не окно, и запускать ради одного голосового сообщения весь
# интерфейс с котом — нелепо. Flutter в него не входит вовсе, поэтому
# `dart compile exe` собирает его за секунды и без движка Flutter. По
# умолчанию результат имеет архитектуру машины сборщика; приложение же
# universal, поэтому оба среза собираем явно и объединяем.
CLI_WORK=$(mktemp -d "${TMPDIR:-/tmp}/tsukiko-cli.XXXXXX")
trap 'rm -rf "$CLI_WORK"' EXIT
DART_VERSION=$(dart --version 2>&1 | sed -E 's/Dart SDK version: ([^ ]+).*/\1/')
DART_PLATFORM=$(dart --version 2>&1 | sed -E 's/.*on "([^"]+)".*/\1/')

# AOT-компилятор Dart умеет выдавать только архитектуру своего SDK. На
# Apple Silicon второй срез собираем x64-SDK той же версии под Rosetta.
# Архив берём из официального Dart Archive и сверяем его официальной суммой.
if [ "$DART_PLATFORM" != "macos_arm64" ]; then
  echo "Для universal CLI запускайте сборку на Apple Silicon (сейчас $DART_PLATFORM)." >&2
  exit 1
fi
X64_ROOT="build/dart-sdk-macos-x64-$DART_VERSION"
X64_ARCHIVE="$X64_ROOT.zip"
X64_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/$DART_VERSION/sdk/dartsdk-macos-x64-release.zip"
if [ ! -x "$X64_ROOT/dart-sdk/bin/dart" ]; then
  mkdir -p "$X64_ROOT"
  X64_SHA=$(curl --http1.1 -fsSL "$X64_URL.sha256sum" | awk '{print $1}')
  if [ -f "$X64_ARCHIVE" ] &&
    ! echo "$X64_SHA  $X64_ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm "$X64_ARCHIVE"
  fi
  if [ ! -f "$X64_ARCHIVE" ]; then
    curl --http1.1 -fsSL -o "$X64_ARCHIVE" "$X64_URL"
  fi
  echo "$X64_SHA  $X64_ARCHIVE" | shasum -a 256 -c - >/dev/null
  ditto -x -k "$X64_ARCHIVE" "$X64_ROOT"
fi

dart compile exe --target-os macos --target-arch arm64 \
  bin/tsukiko_transcribe.dart -o "$CLI_WORK/tsukiko-transcribe-arm64"
arch -x86_64 "$X64_ROOT/dart-sdk/bin/dart" compile exe \
  --target-os macos --target-arch x64 \
  bin/tsukiko_transcribe.dart -o "$CLI_WORK/tsukiko-transcribe-x64"

# Dart AOT-бинарники хранят снапшот в хвосте Mach-O файла — lipo портит
# смещение и вызов падает с «Usage: dartvm». Делаем универсальный C-трамплин,
# который мгновенно передаёт управление родной архитектуре через execv.
cat << 'EOF' > "$CLI_WORK/trampoline.c"
#include <unistd.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        return 1;
    }
    char target[PATH_MAX + 16];
#if defined(__arm64__)
    snprintf(target, sizeof(target), "%s-arm64", path);
#else
    snprintf(target, sizeof(target), "%s-x64", path);
#endif
    execv(target, argv);
    perror("execv");
    return 1;
}
EOF
clang -arch arm64 -arch x86_64 -O3 -o "$APP/Contents/Helpers/tsukiko-transcribe" "$CLI_WORK/trampoline.c"
cp "$CLI_WORK/tsukiko-transcribe-arm64" "$APP/Contents/Helpers/tsukiko-transcribe-arm64"
cp "$CLI_WORK/tsukiko-transcribe-x64" "$APP/Contents/Helpers/tsukiko-transcribe-x64"
chmod +x "$APP/Contents/Helpers/tsukiko-transcribe" \
  "$APP/Contents/Helpers/tsukiko-transcribe-arm64" \
  "$APP/Contents/Helpers/tsukiko-transcribe-x64"

# Метка времени от службы Apple, а не `--timestamp=none`.
#
# Без неё подпись действительна ровно столько, сколько действителен
# сертификат, — а сертификат разработчика живёт год. То есть через год
# приложение перестало бы запускаться у всех, кому его отдали, и
# у самого автора тоже. С меткой подпись переживает истечение
# сертификата: она удостоверяет, что подписано было, пока он ещё
# действовал.
#
# Стоит это одного обращения к сети при сборке. Без сети подписать
# по-прежнему можно — TSUKIKO_NO_TIMESTAMP=1, — но раздавать такое
# нельзя.
STAMP=--timestamp
if [ -n "$TSUKIKO_NO_TIMESTAMP" ] || [ "$ID" = "-" ]; then
  STAMP=--timestamp=none
fi

# Вложенное подписывается первым: подпись бандла запечатывает то, что внутри.
find "$APP/Contents/Frameworks" -depth 1 -print0 |
  xargs -0 -I{} codesign --force --sign "$ID" "$STAMP" $RUNTIME {}
find "$APP/Contents/Helpers" -type f \( -perm -111 -o -name '*.dylib' \) -print0 |
  xargs -0 -I{} codesign --force --sign "$ID" "$STAMP" $RUNTIME {}
codesign --force --sign "$ID" "$STAMP" $RUNTIME \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP"
SIGN_DETAILS=$(codesign -dv "$APP" 2>&1)
if [ -n "$CI" ] && printf '%s\n' "$SIGN_DETAILS" | grep -q 'Signature=adhoc'; then
  echo "Официальная macOS-сборка не может иметь ad-hoc подпись." >&2
  exit 1
fi
if [ -n "$TSUKIKO_EXPECTED_TEAM" ] &&
  ! printf '%s\n' "$SIGN_DETAILS" | grep -q "TeamIdentifier=$TSUKIKO_EXPECTED_TEAM"; then
  echo "Приложение подписано сертификатом другой команды Apple." >&2
  exit 1
fi
codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|Signature' || true
