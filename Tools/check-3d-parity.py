#!/usr/bin/env python3
"""Ogni oggetto del piano disegnato in 2D dev'esserlo anche nel 3D.

`check-overlay-parity.py` confronta i **tipi** di sovraimpressione fra un
riquadro e l'altro. Non basta, e si è visto: nel riquadro 3D il canale alveolare
non si disegnava affatto — impianti, barre e denti sì — e il controllo passava,
perché la sovraimpressione tridimensionale c'era, era il suo contenuto a essere
incompleto.

Il buco era della specie peggiore. Il canale si traccia, `SafetyAnalysis` ne
calcola le distanze, l'ispettore le mostra; e la vista che rende evidente la
sola domanda per cui lo si traccia — l'impianto passa sopra il canale o dentro?
— non disegnava l'oggetto di cui quei numeri parlano. Chi tracciava il nervo e
passava al 3D non vedeva niente, e non aveva modo di sapere se fosse un
tracciamento andato male o un disegno che manca.

# La regola

Ogni raccolta del piano percorsa dalle sovraimpressioni 2D dev'essere percorsa
anche da `Volume3DOverlay`, oppure esentata per iscritto:

    // non-in-3d: <raccolta> — <motivo>

Fra un'omissione voluta e una dimenticata non c'è differenza nel codice, e il
commento è l'unica cosa che la rende visibile.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
FLAT = [APP / "ImplantOverlay.swift", APP / "ProstheticToothOverlay.swift"]
SOLID = APP / "Volume3DOverlay.swift"

# `for canal in model.nerveCanals where …`
LOOP = re.compile(r"\bfor\s+\w+\s+in\s+model\.(\w+)\b")
EXEMPT = re.compile(r"//\s*non-in-3d:\s*(\w+)\s*(?:—|-|:)?\s*(.*)")


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))


def main() -> int:
    flat: set[str] = set()
    for path in FLAT:
        if path.exists():
            flat |= set(LOOP.findall(strip_comments(path.read_text(encoding="utf-8"))))

    solid_text = SOLID.read_text(encoding="utf-8")
    solid = set(LOOP.findall(strip_comments(solid_text)))
    exempt = {name for name, _ in EXEMPT.findall(solid_text)}

    missing = sorted(flat - solid - exempt)
    if missing:
        print("Oggetti del piano disegnati in 2D e non nel riquadro 3D:\n")
        for name in missing:
            print(f"  model.{name}")
        print(
            "\nAggiungi il disegno in Volume3DOverlay, oppure scrivici dentro:"
            "\n    // non-in-3d: <raccolta> — <motivo>"
        )
        return 1

    print(f"Il riquadro 3D disegna tutte le {len(flat)} raccolte del piano.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
