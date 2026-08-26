#!/usr/bin/env python3
"""L'ispettore mostra elenchi, non catene di `else`.

# Il guasto

L'ispettore sceglieva che cosa mostrare con due catene di `if`/`else if`: una
per il contesto — piano occlusale, cefalometria, dente, impianto — e una per i
comandi di visualizzazione. Una catena mostra **una** voce, e le altre non sono
coperte: sono assenti, senza niente che dica perché.

Ne uscivano due difetti che da fuori sembravano lo stesso guasto:

- accesa la cefalometria dal menu, il pannello dell'impianto non tornava più,
  perché stava dietro a un `else`;
- un clic sul riquadro 3D portava via finestra e livello alle tre viste 2D
  rimaste a schermo, che è proprio quando servono.

# La regola che questo controllo tiene ferma

*Quali* sezioni si vedono lo decide `InspectorSections`, in StudyKit, dove i
test percorrono per intero le combinazioni di scheda, disposizione e riquadro a
fuoco. Alla vista resta il disegno. Se la decisione tornasse dentro la vista i
test non la vedrebbero più, e il difetto potrebbe rinascere senza che nulla se
ne accorga — quindi:

1. l'ispettore chiama le due funzioni pure invece di decidere da sé;
2. ogni sezione e ogni contesto dichiarati hanno un ramo che li disegna;
3. il corpo dell'ispettore non contiene `else if`: è lì che la catena
   ricrescerebbe.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PANEL = ROOT / "Sources" / "CBCTMacApp" / "InspectorPanel.swift"
SECTIONS_FILE = ROOT / "Sources" / "StudyKit" / "InspectorSections.swift"

CASE = re.compile(r"^\s{4}case\s+(\w+)\s*$")


def cases(text: str, declaration: str) -> list[str]:
    """I casi dichiarati dall'enum che comincia con `declaration`."""
    start = text.index(declaration)
    end = text.index("}", text.index("public var id", start))
    return [m.group(1) for line in text[start:end].splitlines() if (m := CASE.match(line))]


def body_of(text: str, signature: str) -> list[str]:
    """Le righe di una proprietà o funzione, dalla firma alla graffa che la chiude."""
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(signature))
    for offset, line in enumerate(lines[start + 1:], start + 1):
        if line == "    }":
            return lines[start:offset + 1]
    return lines[start:]


def main() -> int:
    panel = PANEL.read_text(encoding="utf-8")
    declared = SECTIONS_FILE.read_text(encoding="utf-8")
    problems: list[str] = []

    for call in ("InspectorSections.sections(", "InspectorSections.contexts("):
        if call not in panel:
            problems.append(
                f"{PANEL.name}: non chiama `{call}`. Quali sezioni mostrare è una decisione che "
                "si prova in StudyKit; dentro la vista nessun test la vedrebbe.")

    for declaration, kind in (
        ("public enum InspectorSection:", "la sezione"),
        ("public enum InspectorContext:", "il contesto"),
    ):
        for name in cases(declared, declaration):
            if f"case .{name}:" not in panel:
                problems.append(
                    f"{PANEL.name}: {kind} `{name}` è dichiarato e nessun ramo lo disegna.")

    for line in body_of(panel, "    var body: some View {"):
        if "else if" in line and not line.lstrip().startswith("//"):
            problems.append(
                f"{PANEL.name}: `else if` nel corpo dell'ispettore. È la catena che nascondeva "
                "un pannello dietro l'altro: gli elenchi si mostrano tutti.")

    if problems:
        print("Strade dell'ispettore:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    sections = cases(declared, "public enum InspectorSection:")
    contexts = cases(declared, "public enum InspectorContext:")
    print(
        f"L'ispettore disegna quel che StudyKit decide: {len(sections)} sezioni, "
        f"{len(contexts)} contesti, nessuna catena.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
