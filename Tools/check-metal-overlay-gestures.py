#!/usr/bin/env python3
"""Trova sovraimpressioni con gesti SwiftUI impilate su una vista Metal.

# Il difetto, quattro volte

Le maniglie del mirino, la modifica della curva d'arcata, la linea di taglio delle sezioni e il
riquadro di ritaglio: quattro funzioni scritte, disegnate e mai funzionanti, tutte per la stessa
ragione. Sotto la sovraimpressione c'è una `MTKView`, cioè una `NSView` vera; una sovraimpressione
SwiftUI è uno *strato* della stessa vista ospite e non un'altra `NSView`; e il gesto non parte.
Peggio, se lo strato è opaco al hit testing assorbe la rotella e spegne in silenzio uno
scorrimento che funzionava.

La regola adottata dopo la quarta volta: **dentro un riquadro c'è un solo percorso di eventi**,
quello di `InteractiveMetalView`. Le sovraimpressioni disegnano e basta.

# Che cosa segnala e che cosa no

Segnala i **gesti** — `.gesture`, `DragGesture`, `onTapGesture`, `onLongPressGesture` — in una
vista costruita dentro uno `ZStack` o un `.overlay` che contiene anche un riquadro Metal. Non
segnala i pulsanti: un `Button` è un elemento a sé, sta in un angolo, non copre l'immagine e non
compete per la rotella. Fu proprio un pulsante la soluzione data alla profondità della panorex.

Una vista che porta già `.allowsHitTesting(false)` è dichiaratamente solo disegno e passa.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"

METAL_VIEWS = {"MPRViewportView", "PanoramicViewportView", "Volume3DViewportView"}
GESTURES = re.compile(
    r"\.gesture\(|\.simultaneousGesture\(|\.highPriorityGesture\(|DragGesture\(|"
    r"\.onTapGesture|\.onLongPressGesture|MagnificationGesture\(|RotationGesture\("
)
BLOCK_START = re.compile(r"\b(ZStack|overlay)\s*(?:\([^)]*\))?\s*\{")
CONSTRUCTION = re.compile(r"\b([A-Z]\w*)\s*\(")


def strip_noise(text):
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", "", text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def blocks(text):
    """I corpi di ogni ZStack e .overlay, per contare chi ci sta dentro."""
    found = []
    for match in BLOCK_START.finditer(text):
        depth = 0
        start = match.end() - 1
        for index in range(start, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    found.append(text[start : index + 1])
                    break
    return found


def main():
    # Le viste del progetto che sono solo disegno, e quelle che portano gesti.
    draw_only = set()
    gesture_bearing = {}
    for path in sorted(APP.glob("*.swift")):
        body = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        for name in re.findall(r"^struct\s+([A-Za-z_]\w*)\s*:\s*View", body, re.M):
            if ".allowsHitTesting(false)" in body:
                draw_only.add(name)
            elif GESTURES.search(body):
                gesture_bearing[name] = path.relative_to(ROOT)

    problems = []
    for path in sorted(APP.glob("*.swift")):
        body = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        for block in blocks(body):
            built = set(CONSTRUCTION.findall(block))
            if not (built & METAL_VIEWS):
                continue
            for name in sorted(built & set(gesture_bearing)):
                problems.append((path.relative_to(ROOT), name, gesture_bearing[name]))

    problems = sorted(set(problems))
    if not problems:
        print(f"Nessun gesto dentro un riquadro Metal. {len(list(APP.glob('*.swift')))} file esaminati.")
        return 0

    for where, name, declared in problems:
        print(
            f"  {where}: «{name}» è impilata su un riquadro Metal e porta gesti "
            f"({declared}). Il gesto non partirà."
        )
    print()
    print(f"{len(problems)} da spostare sul percorso eventi di InteractiveMetalView.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
