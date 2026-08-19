#!/usr/bin/env python3
"""Azioni del modello che nessuna vista richiama.

`check-unreachable-api.py` guarda i moduli di libreria e chiede se un cammino li
colleghi all'applicazione. Questo guarda il piano sopra: dentro l'applicazione,
un metodo di `AppModel` che nessuna vista chiama è la stessa cosa — una funzione
scritta, provata e irraggiungibile.

È il difetto che si è ripetuto più di ogni altro su questo progetto, e ha una
forma riconoscibile: il motore c'è, l'azione del modello c'è, nessuno ha scritto
la riga che le unisce. Il riquadro di ritaglio, quattro tipi di annotazione,
l'immobilità di impianti e nervi, quattro moduli interi.

Si segnalano i soli metodi — non le proprietà — perché una proprietà non letta è
spesso uno stato interno legittimo, mentre un metodo è un verbo: qualcuno deve
poterlo pronunciare.

L'esenzione si scrive sulla riga sopra la dichiarazione:

    // non-ancora-collegato: <motivo>
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
MODEL_FILE = APP / "AppModel.swift"

FUNC = re.compile(r"^\s{4}(?:@\w+\s+)*(?:private\s+|fileprivate\s+)?func\s+(\w+)\s*\(")
PRIVATE = re.compile(r"^\s*(?:private|fileprivate)\s")
EXEMPT = re.compile(r"//\s*non-ancora-collegato:\s*(.+)")

# Richiamati dal sistema o dal ciclo di vita, non da una vista.
LIFECYCLE = {"init", "deinit"}


def strip_comments_and_strings(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = n if end < 0 else end + 3
            continue
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main() -> int:
    if not MODEL_FILE.exists():
        print(f"{MODEL_FILE} assente.", file=sys.stderr)
        return 2

    lines = MODEL_FILE.read_text(encoding="utf-8").splitlines()

    declared = {}
    exemptions = {}
    inside_model = False
    for number, line in enumerate(lines, start=1):
        if line.startswith("final class AppModel") or line.startswith("class AppModel"):
            inside_model = True
        match = FUNC.match(line)
        if not match or PRIVATE.match(line):
            continue
        name = match.group(1)
        if name in LIFECYCLE:
            continue
        declared.setdefault(name, number)

        note = None
        for back in range(number - 2, max(-1, number - 8), -1):
            if back < 0:
                break
            found = EXEMPT.search(lines[back])
            if found:
                note = found.group(1).strip()
                break
            stripped = lines[back].strip()
            if stripped and not stripped.startswith("//") and not stripped.startswith("@"):
                break
        if note:
            exemptions[name] = note

    if not inside_model:
        print("AppModel non trovato: il controllo non sa dove guardare.", file=sys.stderr)
        return 2

    # I nomi pronunciati **fuori** da AppModel: quelli sono le radici.
    #
    # Non basta chiedersi se un metodo sia citato là fuori. `beginImplantDrag` non lo è più da
    # quando i riquadri passano da `beginObjectDrag`, eppure è vivissimo — lo chiama quello. La
    # domanda giusta è la stessa di `check-unreachable-api`: esiste un **cammino** da un gesto
    # dell'utente fino a qui? Si parte dai nomi che le viste pronunciano e si chiude sulle
    # chiamate interne al modello, finché non si trova più niente di nuovo.
    def names_in(text: str) -> set[str]:
        body = strip_comments_and_strings(text)
        found = set(re.findall(r"\b(\w+)\s*\(", body))
        # Anche una funzione passata come valore, senza parentesi: `onDrag: model.dragObject`.
        found.update(re.findall(r"\.(\w+)\b", body))
        return found

    roots = set()
    for path in sorted(ROOT.rglob("*.swift")):
        if path == MODEL_FILE or "/.build/" in str(path):
            continue
        roots |= names_in(path.read_text(encoding="utf-8"))

    # Il corpo di ciascun metodo del modello, per sapere che cosa chiama, e quali righe occupa.
    bodies: dict[str, list[str]] = {}
    body_lines: set[int] = set()
    current = None
    depth = 0
    for index, line in enumerate(lines):
        match = FUNC.match(line)
        if match and current is None:
            current = match.group(1)
            depth = line.count("{") - line.count("}")
            bodies.setdefault(current, []).append(line)
            body_lines.add(index)
            if depth <= 0 and "{" in line:
                current = None
            continue
        if current is not None:
            bodies[current].append(line)
            body_lines.add(index)
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                current = None

    # Anche ciò che sta **fuori** dai corpi dei metodi è un punto d'ingresso: gli osservatori
    # `didSet`, le proprietà calcolate, l'inizializzatore. `rebuildDerivedContours` è chiamato
    # dal `didSet` del mirino, e un controllo che guardasse i soli metodi lo direbbe morto —
    # segnalando come difetto proprio il codice che scatta a ogni movimento del puntatore.
    outside = [line for index, line in enumerate(lines) if index not in body_lines]
    roots |= names_in("\n".join(outside))

    # La chiusura attraversa **anche le funzioni private**, che si segnalano mai ma trasportano
    # eccome: `rebuildDerivedContours` è chiamato dalla privata `syncPlanesToCrosshair`, a sua
    # volta chiamata dal `didSet` del mirino. Fermandosi alle sole non private la catena si
    # spezzerebbe nel mezzo, e il codice che scatta a ogni movimento del puntatore risulterebbe
    # morto.
    reachable = {name for name in bodies if name in roots}
    frontier = list(reachable)
    while frontier:
        name = frontier.pop()
        for called in names_in("\n".join(bodies.get(name, []))):
            if called in bodies and called not in reachable:
                reachable.add(called)
                frontier.append(called)

    problems = []
    for name, number in sorted(declared.items(), key=lambda item: item[1]):
        if name in exemptions or name in reachable:
            continue
        problems.append((number, name))

    if problems:
        for number, name in problems:
            print(
                f"Sources/CBCTMacApp/AppModel.swift:{number}: "
                f"AppModel.{name}() non è richiamato da nessuna vista"
            )
        print()
        print(
            f"{len(problems)} azioni del modello che nessuno può eseguire.\n"
            "Collegale a un comando, oppure scrivi sopra la dichiarazione:\n"
            "    // non-ancora-collegato: <motivo>"
        )
        return 1

    print(
        f"Ogni azione del modello è raggiungibile. "
        f"{len(declared)} metodi, {len(exemptions)} esentati."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
