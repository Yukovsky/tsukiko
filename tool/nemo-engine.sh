#!/bin/sh
# Подготовить официальный нативный NeMo-Speech.cpp для универсальной macOS-сборки.
# Python готовому приложению не нужен: он требуется только конвертеру чужих
# checkpoint-файлов, а приложение использует уже готовый GGUF.
set -e
cd "$(dirname "$0")/.."

VERSION=0.2.0
ARM_ASSET="nemo-speech-$VERSION-macos-aarch64-metal.tar.gz"
X64_ASSET="nemo-speech-$VERSION-macos-x86_64-cpu.tar.gz"
ARM_SHA=5cb02ba7c04f0b5585ce5cde9c830be5f0b7dfb4c83083c500109c381b4f2da9
X64_SHA=d52c318d8197511d4f7eee02bcf05511f7e91b300555a130b562e571695a0f39
BASE_URL="https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$VERSION"

OUT=macos/Engine/nemo
WORK=build/nemo-engine
STAMP=macos/Engine/.nemo-version

if [ "$1" != "--force" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ] &&
  [ -x "$OUT/bin/nemo-speech" ]; then
  echo "NeMo-Speech.cpp $VERSION уже подготовлен — $OUT"
  exit 0
fi

command -v lipo >/dev/null || {
  echo "Нужен lipo из Xcode Command Line Tools." >&2
  exit 1
}

mkdir -p "$WORK" macos/Engine
download() {
  asset=$1
  sha=$2
  archive="$WORK/$asset"
  if [ ! -f "$archive" ]; then
    echo "качаем NeMo-Speech.cpp $asset…"
    curl -fsSL -o "$archive" "$BASE_URL/$asset"
  fi
  echo "$sha  $archive" | shasum -a 256 -c - >/dev/null
}
download "$ARM_ASSET" "$ARM_SHA"
download "$X64_ASSET" "$X64_SHA"

ARM="$WORK/arm64"
X64="$WORK/x86_64"
rm -rf "$ARM" "$X64" "$OUT"
mkdir -p "$ARM" "$X64" "$OUT/bin" "$OUT/lib" "$OUT/share"
tar xzf "$WORK/$ARM_ASSET" -C "$ARM"
tar xzf "$WORK/$X64_ASSET" -C "$X64"
# В 0.1.0 корень архива назывался `nemo-speech/`, с 0.2.0 в нём версия
# и платформа (`nemo-speech-0.2.0-macos-aarch64-metal/`). Берём ту
# единственную папку, что лежит в корне, как бы она ни называлась.
ARM_ROOT=$(find "$ARM" -mindepth 1 -maxdepth 1 -type d | head -1)
X64_ROOT=$(find "$X64" -mindepth 1 -maxdepth 1 -type d | head -1)

lipo -create "$ARM_ROOT/bin/nemo-speech" "$X64_ROOT/bin/nemo-speech" \
  -output "$OUT/bin/nemo-speech"
chmod +x "$OUT/bin/nemo-speech"

# Сохраняем имена-ссылки из официального архива, а настоящие dylib
# объединяем в universal. Metal-библиотека остаётся arm64-only: Intel-срез
# бинарника её не загружает и работает на CPU.
cp -R "$ARM_ROOT/lib/." "$OUT/lib/"
find "$ARM_ROOT/lib" -maxdepth 1 -type f -name '*.dylib' | while IFS= read -r arm_lib; do
  name=$(basename "$arm_lib")
  x64_lib="$X64_ROOT/lib/$name"
  if [ -f "$x64_lib" ]; then
    lipo -create "$arm_lib" "$x64_lib" -output "$OUT/lib/$name"
  fi
done

mkdir -p "$OUT/share/nemo-speech" "$OUT/share/licenses"
cp "$ARM_ROOT/share/nemo-speech/model-index.json" "$OUT/share/nemo-speech/"
cp -R "$ARM_ROOT/share/licenses/nemo-speech" "$OUT/share/licenses/"
echo "$VERSION" > "$STAMP"

echo "NeMo-Speech.cpp $VERSION подготовлен (Metal arm64 + CPU x86_64):"
file "$OUT/bin/nemo-speech"
