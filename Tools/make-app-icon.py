#!/usr/bin/env python3
"""Disegna l'icona dell'applicazione, senza dipendenze e senza file d'origine.

# Perché disegnata invece che disegnata da qualcuno

Perché un PNG nel repository è un file che nessuno sa più rifare quando serve a una misura
diversa, e perché un'icona è geometria: un'arcata vista dall'alto, che è esattamente ciò che il
programma mostra nella fetta assiale. Scritta così esce nitida a ogni dimensione — da 16 pixel a
1024 — e cambiarla è cambiare tre numeri.

Il PNG lo scrive `zlib`, che sta nella libreria standard: niente Pillow, niente numpy, niente da
installare prima di poter compilare un'icona.

Uso:
    python3 Tools/make-app-icon.py <cartella.iconset>

Scrive dentro la cartella i dieci PNG che `iconutil` si aspetta.
"""

import struct
import sys
import zlib
from pathlib import Path

#: Le dimensioni che macOS vuole in un `.iconset`, con il nome che pretende.
ICONSET = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

#: Colori: lo sfondo scuro dell'interfaccia, il verde dei suoi accenti, lo smalto quasi bianco.
BACKGROUND_TOP = (18, 28, 34)
BACKGROUND_BOTTOM = (8, 12, 15)
ARCH = (178, 237, 202)
TOOTH = (238, 250, 243)

#: Il quadrato non riempie la tela: macOS si aspetta un margine attorno all'icona.
MARGIN = 0.085
#: Raggio degli angoli, in frazione del lato. È la proporzione delle icone di sistema.
CORNER = 0.223


def rounded_rect_coverage(x, y, size):
    """Quanto un punto sta dentro il quadrato arrotondato: 0 fuori, 1 dentro."""
    inset = MARGIN * size
    radius = CORNER * size
    left, top = inset, inset
    right, bottom = size - inset, size - inset

    # Distanza con segno dal quadrato arrotondato, che è la distanza dal rettangolo interno meno
    # il raggio: sugli angoli diventa la distanza dal cerchio, che è ciò che li arrotonda.
    dx = max(left + radius - x, 0, x - (right - radius))
    dy = max(top + radius - y, 0, y - (bottom - radius))
    return 1.0 if (dx * dx + dy * dy) ** 0.5 <= radius else 0.0


def arch_coverage(x, y, size):
    """L'arcata: una fascia ellittica aperta verso il basso, con i denti sopra."""
    centre_x = size * 0.5
    centre_y = size * 0.54
    radius_x = size * 0.29
    radius_y = size * 0.32
    thickness = size * 0.080

    normalised = (((x - centre_x) / radius_x) ** 2 + ((y - centre_y) / radius_y) ** 2) ** 0.5
    distance = abs(normalised - 1.0) * min(radius_x, radius_y)
    # Aperta verso il basso: sotto il centro la fascia si interrompe, come un'arcata vera.
    if y > centre_y + size * 0.26:
        return 0.0
    return 1.0 if distance <= thickness * 0.5 else 0.0


def tooth_coverage(x, y, size):
    """I denti: tondi equidistanti lungo l'arcata, che è ciò che la rende riconoscibile."""
    import math

    centre_x = size * 0.5
    centre_y = size * 0.54
    radius_x = size * 0.29
    radius_y = size * 0.32
    tooth_radius = size * 0.026

    for index in range(9):
        angle = math.pi + (index + 0.5) / 9 * math.pi
        tx = centre_x + radius_x * math.cos(angle)
        ty = centre_y + radius_y * math.sin(angle)
        if (x - tx) ** 2 + (y - ty) ** 2 <= tooth_radius**2:
            return 1.0
    return 0.0


def blend(base, colour, alpha):
    return tuple(round(b + (c - b) * alpha) for b, c in zip(base, colour))


def render(size, supersample=3):
    """L'icona a una dimensione, con i bordi lisciati campionando più volte per pixel."""
    rows = []
    scale = size * supersample
    step = 1.0 / supersample
    for row in range(size):
        line = bytearray()
        for column in range(size):
            red = green = blue = alpha = 0.0
            for sub_y in range(supersample):
                for sub_x in range(supersample):
                    x = (column + (sub_x + 0.5) * step) * supersample
                    y = (row + (sub_y + 0.5) * step) * supersample
                    inside = rounded_rect_coverage(x, y, scale)
                    if inside <= 0:
                        continue
                    fraction = y / scale
                    colour = blend(BACKGROUND_TOP, BACKGROUND_BOTTOM, fraction)
                    if tooth_coverage(x, y, scale) > 0:
                        colour = TOOTH
                    elif arch_coverage(x, y, scale) > 0:
                        colour = ARCH
                    red += colour[0]
                    green += colour[1]
                    blue += colour[2]
                    alpha += 1.0
            samples = supersample * supersample
            if alpha <= 0:
                line += bytes((0, 0, 0, 0))
                continue
            line += bytes(
                (
                    round(red / alpha),
                    round(green / alpha),
                    round(blue / alpha),
                    round(255 * alpha / samples),
                )
            )
        rows.append(bytes(line))
    return rows


def write_png(path, rows, size):
    """Un PNG a otto bit con canale alfa, scritto a mano: nessuna libreria da installare."""

    def chunk(kind, payload):
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + row for row in rows)
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main(argv):
    if len(argv) != 2:
        print("Uso: make-app-icon.py <cartella.iconset>", file=sys.stderr)
        return 2
    folder = Path(argv[1])
    folder.mkdir(parents=True, exist_ok=True)

    # Le dimensioni si ripetono nel formato — 32 serve due volte, e così 256 e 512 — quindi ogni
    # misura si disegna una volta sola e si copia dove serve.
    drawn = {}
    for size, name in ICONSET:
        if size not in drawn:
            drawn[size] = render(size, supersample=3 if size <= 256 else 2)
        write_png(folder / name, drawn[size], size)
    print(f"{len(ICONSET)} immagini in {folder}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
