#!/usr/bin/env python3
"""Sovraimpressioni che la griglia disegna e le sezioni trasversali no.

# Il difetto, tre volte nello stesso posto

La sezione trasversale riceve i clic degli strumenti come i riquadri ortogonali:
`model.applyToolClick` è collegato, e ciò che si posa lì viene creato davvero.
Ma le sovraimpressioni sono un elenco a parte, e ogni volta che se ne aggiunge
una ai riquadri bisogna ricordarsi anche di questo — che sta in un altro file,
seicento righe più in là.

Dimenticarla non dà errore: dà un oggetto che si crea e non si vede. È già
successo con gli impianti — che per giunta si potevano **afferrare e spostare**
senza vederli — con i denti protesici, e con i reperi cefalometrici. Tre volte,
sempre uguale, sempre scoperto usando il programma.

# La regola

Ogni sovraimpressione costruita in `ViewportGrid.swift` dev'essere costruita
anche in `PanoramicWorkspace.swift`, oppure esentata per iscritto:

    // sovraimpressione-non-richiesta: NomeOverlay — <motivo>

Non è burocrazia: fra un'omissione voluta e una dimenticata non c'è differenza
nel codice, e questo commento è l'unica cosa che la rende visibile.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
REFERENCE = APP / "ViewportGrid.swift"
TARGET = APP / "PanoramicWorkspace.swift"

CONSTRUCTION = re.compile(r"\b(\w*Overlay)\s*\(")
EXEMPT = re.compile(r"//\s*sovraimpressione-non-richiesta:\s*(\w+)\s*(?:—|-|:)?\s*(.*)")


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))


def overlays(path: Path) -> set[str]:
    body = strip_comments(path.read_text(encoding="utf-8"))
    # `struct XOverlay: View {` è una dichiarazione, non un uso: si tolgono.
    declared = set(re.findall(r"\bstruct\s+(\w*Overlay)\b", body))
    return {name for name in CONSTRUCTION.findall(body) if name not in declared}


def main() -> int:
    for path in (REFERENCE, TARGET):
        if not path.exists():
            print(f"{path} non c'è: il controllo non sa che cosa confrontare.")
            return 1

    reference = overlays(REFERENCE)
    target = overlays(TARGET)

    exemptions: dict[str, str] = {}
    for line in TARGET.read_text(encoding="utf-8").splitlines():
        found = EXEMPT.search(line)
        if found:
            exemptions[found.group(1)] = found.group(2).strip()

    missing = sorted(reference - target - set(exemptions))

    if missing:
        print("Sovraimpressioni assenti dalle sezioni trasversali:\n")
        for name in missing:
            print(
                f"  {name} si disegna nei riquadri ortogonali e non qui: "
                "ciò che vi si posa non si vedrebbe"
            )
        print()
        print(
            f"{len(missing)} da sistemare. Se l'omissione è voluta, scrivila:\n"
            "    // sovraimpressione-non-richiesta: NomeOverlay — <motivo>"
        )
        return 1

    unused = sorted(set(exemptions) - (reference - target))
    if unused:
        print("Esenzioni che non servono più:\n")
        for name in unused:
            print(f"  {name} è esentata ma nei riquadri non c'è, o qui c'è già")
        print()
        print(f"{len(unused)} da togliere: un'esenzione stantia nasconde la prossima vera.")
        return 1

    print(
        f"Le sezioni trasversali disegnano tutto quello che disegnano i riquadri. "
        f"{len(reference)} sovraimpressioni, {len(exemptions)} esentate."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
