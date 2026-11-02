#!/usr/bin/env python3
"""Нарисовать фон для окна .dmg — в двух разрешениях и одним TIFF.

Почему средний тон, а не светлый: Finder рисует подписи под значками
цветом темы — чёрным в светлой, белым в тёмной, — а картинка в образе
одна на обе. На светлом фоне белая подпись пропадает, на тёмном чёрная.
Взят тон, на котором читаются обе: контраст с чёрным 5,0, с белым 4,2.

Запуск: python3 tool/dmg-background.py (нужен rsvg-convert и Pillow)
Итог: design/dmg-background.tiff — его и кладёт в образ tool/dmg.sh
"""

import io
import subprocess
import sys
from pathlib import Path

from PIL import Image

from dmg_layout import (CARD_SIZE, CARD_TOP, CONTENT_HEIGHT, CORNER_INSET, ICON_Y, LEFT_X,
                        MASCOT_HEIGHT, RIGHT_X, WINDOW_SIZE)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "design" / "dmg-background.tiff"
# Лунный кот из приложения: test/design/cat/brand_art_test.dart.
MASCOT = ROOT / "design" / "dmg-mascot.png"

# Картинка нарочно больше окна образа.
#
# Finder не растягивает фон и не повторяет его: он кладёт картинку
# от левого верхнего угла, а всё, что не закрыто, оставляет белым. Окно
# же не наше: человек мог открыть образ в уже открытом окне Finder,
# включить строку пути, растянуть окно однажды и навсегда — и картинка
# ровно по размеру окна оборачивалась белыми полосами справа и снизу.
# Полос не будет, если картинка больше любого разумного окна; лишнее
# уходит под обрез, и уходит один градиент.
W, H = 1000, 700

# Фон и .DS_Store используют одну систему координат без поправки на заголовок.
WIN_W, WIN_H = WINDOW_SIZE

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="#9295bd"/>
      <stop offset="1" stop-color="#666b98"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.42" r="0.6">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.18"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="10"/>
    </filter>
  </defs>

  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" fill="url(#glow)"/>

  <!-- Два места под значки: пунктирные гнёзда читаются как интерфейс,
       а не как украшение, — сразу видно, что и куда кладут. -->
  <rect x="{LEFT_X - CARD_SIZE // 2}" y="{CARD_TOP}" width="{CARD_SIZE}" height="{CARD_SIZE}" rx="28"
        fill="#ffffff" fill-opacity="0.07"
        stroke="#ffffff" stroke-opacity="0.28" stroke-width="1.5"
        stroke-dasharray="7 6"/>
  <rect x="{RIGHT_X - CARD_SIZE // 2}" y="{CARD_TOP}" width="{CARD_SIZE}" height="{CARD_SIZE}" rx="28"
        fill="#ffffff" fill-opacity="0.10"
        stroke="#ffffff" stroke-opacity="0.34" stroke-width="1.5"/>

  <!-- Стрелка: единственное указание, и оно без слов — образ один
       на все языки. -->
  <g opacity="0.85" filter="url(#soft)">
    <path d="M{LEFT_X + 104} {ICON_Y} H{RIGHT_X - 104}" stroke="#ffffff" stroke-width="9"
          stroke-linecap="round" fill="none" opacity="0.35"/>
  </g>
  <path d="M{LEFT_X + 104} {ICON_Y} H{RIGHT_X - 104}" stroke="#ffffff" stroke-width="4"
        stroke-linecap="round" fill="none"/>
  <path d="M{RIGHT_X - 122} {ICON_Y - 10} L{RIGHT_X - 104} {ICON_Y} L{RIGHT_X - 122} {ICON_Y + 10}"
        stroke="#ffffff" stroke-width="4"
        stroke-linecap="round" stroke-linejoin="round" fill="none"/>

  <text x="{WIN_W // 2}" y="72" text-anchor="middle"
        font-family="SF Pro Display, Helvetica Neue, Helvetica, sans-serif"
        font-size="28" font-weight="600" fill="#ffffff" fill-opacity="0.9"
        letter-spacing="-0.4">tsukiko</text>

  <!-- У декоративных элементов одинаковые поля от углов окна. -->
  <text x="{WIN_W - CORNER_INSET}" y="{CONTENT_HEIGHT - CORNER_INSET - 3}" text-anchor="end"
        font-family="SF Pro Text, Helvetica Neue, Helvetica, sans-serif"
        font-size="12" font-weight="500" fill="#ffffff" fill-opacity="0.72"
        letter-spacing="0.25">Yukovsky</text>
</svg>
"""


def render(scale: int) -> Image.Image:
    """SVG в растр нужного разрешения."""
    png = subprocess.run(
        ["rsvg-convert", "-w", str(W * scale), "-h", str(H * scale)],
        input=SVG.encode(), capture_output=True, check=True).stdout
    canvas = Image.open(io.BytesIO(png)).convert("RGBA")

    # Кот в нижнем левом углу заметен с первого взгляда, но остаётся ниже
    # рабочих значков и не спорит с жестом перетаскивания.
    cat = Image.open(MASCOT).convert("RGBA")
    # Отступы считаются от самого рисунка, а не прозрачных полей файла.
    cat = cat.crop(cat.getchannel("A").getbbox())
    height = MASCOT_HEIGHT * scale
    width = round(cat.width * height / cat.height)
    cat = cat.resize((width, height), Image.LANCZOS)
    visible = cat.copy()
    visible.putalpha(cat.getchannel("A").point(lambda a: int(a * 0.78)))
    canvas.alpha_composite(visible, (
        CORNER_INSET * scale,
        (CONTENT_HEIGHT - CORNER_INSET - MASCOT_HEIGHT) * scale))
    return canvas.convert("RGB")


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    one, two = ROOT / "build" / "dmg-bg.png", ROOT / "build" / "dmg-bg@2x.png"
    one.parent.mkdir(parents=True, exist_ok=True)
    render(1).save(one)
    render(2).save(two)
    # Один файл на оба разрешения: Finder сам берёт нужное. Отдельного
    # «@2x» рядом он не ищет — только многостраничный TIFF.
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT)],
        check=True, capture_output=True)
    one.unlink()
    two.unlink()
    print(f"нарисовано: {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} КБ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
