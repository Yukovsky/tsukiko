#!/bin/sh
# Собрать минимальный ffmpeg для Windows — тот, что перекладывает звук
# в WAV перед распознаванием.
#
# Зачем он вообще нужен: whisper читает сам только wav, mp3, flac и ogg
# с Vorbis. А в разговор приходит другое — голосовые из мессенджеров
# (Opus в ogg), записи с диктофона (AAC в m4a), дорожки из видео.
# На macOS их перекладывает системный afconvert, на Windows системного
# конвертера нет.
#
# Media Foundation не выручает: Opus в ogg она без отдельного расширения
# из магазина не читает, а расширение ставится не у всех. Проверено
# по документации Microsoft, а не по догадке.
#
# Строго LGPL: ни --enable-gpl, ни --enable-nonfree. Иначе класть его
# внутрь приложения стало бы нельзя.
#
# Запускать в MSYS2 (mingw64). В CI это делает .github/workflows/windows.yml,
# руками — так же, той же командой.
set -e
cd "$(dirname "$0")/.."

VERSION=7.1.5
BUILD_ID="$VERSION-audio3"
SHA=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f

OUT=windows/Engine
WORK=build/ffmpeg
STAMP="$OUT/.ffmpeg-version"

if [ "$1" != "--force" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$BUILD_ID" ] &&
  [ -f "$OUT/ffmpeg.exe" ]; then
  echo "ffmpeg $VERSION уже собран — $OUT"
  exit 0
fi

mkdir -p "$WORK" "$OUT"
SRC="$WORK/ffmpeg-$VERSION"
TAR="$WORK/ffmpeg-$VERSION.tar.xz"

if [ ! -d "$SRC" ]; then
  echo "качаем ffmpeg $VERSION…"
  curl -fsSL -o "$TAR" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  # Сверяем то, что скачали: подменённый архив собрался бы молча.
  echo "$SHA  $TAR" | sha256sum -c -
  tar xf "$TAR" -C "$WORK"
fi

cd "$SRC"
# --disable-everything и поимённый список: полный ffmpeg весит под сотню
# мегабайт и тянет кодеки, которые нам не нужны ни на что.
# --extra-cflags="-static" и --extra-ldflags="-static" обязательны:
# без них MinGW GCC динамически цепляет libwinpthread-1.dll, и на чистой
# Windows без MSYS2 ffmpeg падает с ошибкой -1073741515 (0xC0000135).
./configure \
  --disable-everything \
  --disable-network \
  --disable-autodetect \
  --disable-doc \
  --disable-debug \
  --disable-shared \
  --enable-static \
  --enable-small \
  --extra-cflags="-static" \
  --extra-ldflags="-static" \
  --pkg-config-flags="--static" \
  --enable-protocol=file \
  --enable-demuxer=wav,ogg,matroska,mov,mp3,flac,aac,aiff,asf,w64 \
  --enable-decoder=opus,vorbis,aac,mp3,mp2,ac3,eac3,flac,alac,wmav1,wmav2,wmapro,wmalossless,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_alaw,pcm_mulaw \
  --enable-parser=opus,vorbis,aac,mpegaudio,ac3,flac \
  --enable-muxer=wav \
  --enable-encoder=pcm_s16le \
  --enable-filter=abuffer,abuffersink,aresample,aformat,anull \
  --enable-bsf=null

make -j "$(nproc 2>/dev/null || echo 4)"

cd - >/dev/null
cp "$SRC/ffmpeg.exe" "$OUT/ffmpeg.exe"
# Если осталась зависимость от libwinpthread-1.dll (динамическая линковка), кладём её рядом
for dll in /mingw64/bin/libwinpthread-1.dll /usr/x86_64-w64-mingw32/sys-root/mingw/bin/libwinpthread-1.dll; do
  if [ -f "$dll" ]; then
    cp "$dll" "$OUT/libwinpthread-1.dll"
    echo "Скопирована $dll -> $OUT/libwinpthread-1.dll"
    break
  fi
done
# LGPL обязывает возить с собой текст лицензии.
cp "$SRC/COPYING.LGPLv2.1" "$OUT/ffmpeg-LICENSE.txt"
echo "$BUILD_ID" > "$STAMP"

ls -la "$OUT/ffmpeg.exe"
echo "ffmpeg $VERSION собран"
