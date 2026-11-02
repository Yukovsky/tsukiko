#!/usr/bin/env python3
"""Нарисовать картинки для окна установщика Inno Setup.

Зачем вообще: без них мастер выглядит как всякий второй установщик
из девяностых — серая полоса слева и ни одного признака того, что
именно ставится. На macOS ту же работу делает окно образа
(`tool/dmg.sh`): открыл — и сразу видно, что за программа и что с ней
делать. Здесь то же самое средствами Inno Setup: большая картинка на
первой и последней странице и маленькая — в шапке остальных.

Размеров у каждой не два, а весь набор, который Inno Setup ждёт.
Раньше рисовались только 164×314 и 328×628, и на всяком другом
масштабе экрана Inno брал ближайшую и растягивал её своим простым
растяжением — отсюда и мыло, на которое жаловался хозяин. Набор ниже
взят из самого Inno Setup (его WizModernImage*.bmp): на любом
обычном масштабе (100, 125, 150, 175, 200, 300%) находится картинка
почти точно нужного размера, и растягивать почти нечего.

Картинка рисуется под каждый размер заново, а не масштабируется:
пропорции у размеров чуть разные (164×314 и 292×534 — это 0,52 и 0,55),
и одна растянутая на все давала бы то сплюснутого кота, то съехавшую
подпись.

Плюс лёгкий шум поверх готового кадра. Плавный градиент в 24-битном
BMP полосит — переход в 256 уровней на 1200 точек высоты даёт видимые
глазом ступени. Шум амплитудой около единицы уровня разбивает границу
ступени, и полосы пропадают; это то же самое, что делает dithering,
только дешевле в одну строку.

Заодно кладёт заставку крупно и без шума — `design/tsukiko-splash.png`,
для промо и роликов.

Рисуется тем же, чем фон образа на macOS: SVG → rsvg-convert → Pillow.
Нужны они ровно один раз — готовые BMP лежат в design/ и в репозитории.

Запуск: python3 tool/installer-images.py (нужен rsvg-convert и Pillow)
"""

import io
import struct
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
DESIGN = ROOT / "design"
ICON = DESIGN / "tsukiko-appicon.svg"
# Тот же кот, что на фоне образа macOS: test/design/cat/brand_art_test.dart.
MASCOT = DESIGN / "dmg-mascot.png"

# Размеры задаёт Inno Setup — ровно те, в которых он поставляет свои
# собственные картинки мастера. WizardImageFile и WizardSmallImageFile
# принимают список через запятую и берут из него ближайший к нынешнему
# масштабу экрана.
BANNERS = [(164, 314), (192, 386), (292, 534), (386, 690), (423, 797), (637, 1200)]
LOGOS = [(55, 58), (64, 68), (92, 97), (119, 123), (128, 132), (138, 140), (192, 192)]

# В этих пропорциях нарисована сама заставка; остальные размеры
# получаются подгонкой по короткой стороне с обрезкой по длинной.
BANNER_BASE = (164, 314)

# Заставка для промо: та же картинка, только крупно и без шума —
# шум мешал бы дальнейшему масштабированию.
SPLASH = (1274, 2400)

# Тот же сине-сиреневый, что у значка и у маскота.
BANNER_SVG = """<svg xmlns="http://www.w3.org/2000/svg"
     width="{w}" height="{h}" viewBox="0 0 164 314"
     preserveAspectRatio="xMidYMid slice">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.4" y2="1">
      <stop offset="0" stop-color="#8B8FCB"/>
      <stop offset="1" stop-color="#4A4D77"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.3" r="0.7">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.20"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect x="-40" y="-40" width="244" height="394" fill="url(#bg)"/>
  <rect x="-40" y="-40" width="244" height="394" fill="url(#glow)"/>
  <text x="82" y="42" text-anchor="middle"
        font-family="Segoe UI, Helvetica, sans-serif"
        font-size="22" font-weight="600" fill="#ffffff" letter-spacing="0.5">tsukiko</text>
  <text x="82" y="64" text-anchor="middle"
        font-family="Segoe UI, Helvetica, sans-serif"
        font-size="10" fill="#ffffff" fill-opacity="0.72">расшифровка и диктовка</text>
  <text x="154" y="303" text-anchor="end"
        font-family="Segoe UI, Helvetica, sans-serif"
        font-size="7" font-weight="600" fill="#ffffff"
        fill-opacity="0.82" letter-spacing="0.35">Yukovsky</text>
</svg>
"""


def render(svg: str, width: int, height: int) -> Image.Image:
    png = subprocess.run(
        ["rsvg-convert", "-w", str(width), "-h", str(height)],
        input=svg.encode(), capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def dither(image: Image.Image) -> Image.Image:
    """Разбить ступени градиента шумом амплитудой около одного уровня.

    Шум делается один раз на весь кадр: `effect_noise` даёт полосу
    вокруг 128, а `add` со сдвигом −128 возвращает её к нулю. Кота
    и подпись он тоже задевает, но на такой амплитуде этого не видно
    ни на одном экране.
    """
    noise = Image.merge("RGB", [Image.effect_noise(image.size, 1.6)] * 3)
    return ImageChops.add(image, noise, 1.0, -128)


def banner(width: int, height: int) -> Image.Image:
    canvas = render(BANNER_SVG.format(w=width, h=height), width, height)
    # Голова кота стоит подбородком на нижнем краю полосы. Прозрачные
    # поля кадра сначала срезаем, иначе он встал бы боком.
    cat = Image.open(MASCOT).convert("RGBA")
    # Голова занимает две трети ширины: шире она закрыла бы подпись внизу.
    cat = cat.crop(cat.getbbox())
    cat_width = width * 2 // 3
    cat_height = int(cat.height * cat_width / cat.width)
    cat = cat.resize((cat_width, cat_height), Image.LANCZOS)
    canvas.alpha_composite(
        cat, ((width - cat_width) // 2, height - cat_height - height // 12))
    return canvas.convert("RGB")


def logo(width: int, height: int) -> Image.Image:
    # Значок приложения на прозрачном. Раньше под него клали белое:
    # шапка мастера белая, а 24-битный BMP прозрачности не хранит.
    # Теперь мастер умеет и тёмный вид (WizardStyle=modern dynamic),
    # и белый квадрат в тёмной шапке выглядел бы дырой. Прозрачность
    # хранит 32-битный BMP — его и пишем, см. save_bmp32.
    icon = render(ICON.read_text(encoding="utf-8"), height, height)
    canvas = Image.new("RGBA", (width, height), (255, 255, 255, 0))
    canvas.alpha_composite(icon, ((canvas.width - icon.width) // 2, 0))
    return canvas


def save_bmp32(image: Image.Image, path: Path) -> None:
    """Записать 32-битный BMP с альфой — своими руками.

    Pillow такого не умеет: `save(format="BMP")` молча выбрасывает
    альфа-канал и кладёт 24 бита. А Inno Setup прозрачность берёт
    ровно из 32-битного BMP (WizardImageAlphaFormat=defined) — иначе
    значок в шапке остаётся с белой подложкой.

    Формат простой: заголовок файла, заголовок картинки без сжатия
    и строки BGRA снизу вверх. Ряды по четыре байта на точку, так что
    выравнивать нечего.
    """
    rgba = image.convert("RGBA")
    rows = []
    pixels = rgba.load()
    for y in range(rgba.height - 1, -1, -1):
        row = bytearray()
        for x in range(rgba.width):
            r, g, b, a = pixels[x, y]
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    body = b"".join(rows)
    info = struct.pack(
        "<IiiHHIIiiII", 40, rgba.width, rgba.height, 1, 32, 0, len(body),
        2835, 2835, 0, 0)
    head = struct.pack("<2sIHHI", b"BM", 14 + len(info) + len(body), 0, 0,
                       14 + len(info))
    path.write_bytes(head + info + body)


def main() -> int:
    made = []
    for name, draw, sizes in (
        ("installer-banner", banner, BANNERS),
        ("installer-logo", logo, LOGOS),
    ):
        for width, height in sizes:
            out = DESIGN / f"{name}-{width}x{height}.bmp"
            image = draw(width, height)
            if image.mode == "RGBA":
                # Значок в шапке — с прозрачностью, а шум ему ни к чему:
                # градиента в нём нет, полосить нечему.
                save_bmp32(image, out)
            else:
                # Полоса — 24 бита без сжатия, зато с шумом против полос.
                dither(image).save(out, format="BMP")
            made.append(out)

    splash = DESIGN / "tsukiko-splash.png"
    banner(*SPLASH).save(splash, format="PNG")
    made.append(splash)

    for out in made:
        print(f"нарисовано: {out.relative_to(ROOT)} ({out.stat().st_size // 1024} КБ)")
    print()
    print("Списки для tool/installer.iss:")
    print("WizardImageFile=" + ",".join(
        f"..\\design\\installer-banner-{w}x{h}.bmp" for w, h in BANNERS))
    print("WizardSmallImageFile=" + ",".join(
        f"..\\design\\installer-logo-{w}x{h}.bmp" for w, h in LOGOS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
