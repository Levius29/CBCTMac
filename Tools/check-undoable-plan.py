#!/usr/bin/env python3
"""Modifiche al piano che «annulla» non riporta indietro.

# Il difetto

Il piano — misure, impianti, denti, barre, nervi, curve, reperi — si cambia da
una trentina di punti diversi di `AppModel`. Chi ne scrive uno nuovo deve
ricordarsi di chiudere con `recordUndo`, e chi se ne dimentica non rompe
niente: il programma funziona, l'operazione riesce, e soltanto ⌘Z non la
riporta indietro. Nessun errore, nessun avviso, e ci si accorge quando serve
davvero — cioè dopo aver cancellato qualcosa che si voleva tenere.

Trovati così due casi che c'erano da mesi: **eliminare un impianto** e
**appiattire la curva d'arcata**. Il primo è il peggiore che ci fosse: un
impianto posizionato con cura spariva e non c'era modo di riaverlo.

# La regola

Ogni funzione che scrive in un campo di `PlanSnapshot` deve registrare un
passo di annulla, direttamente o attraverso una funzione che lo fa.

Le eccezioni vere esistono e si scrivono, sulla riga sopra la dichiarazione:

    // senza-annulla: <motivo>

Ce ne sono tre legittime, e tutte per lo stesso genere di ragione: `apply` **è**
l'annulla, il blocco che apre un esame azzera la cronologia invece di
aggiungerci un passo, e chi comincia un canale nervoso lo fa un istante prima
che il primo nodo registri per entrambi.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "Sources" / "CBCTMacApp" / "AppModel.swift"

RECORDERS = ("recordUndo", "recordContinuousUndo", "resetUndoBaseline")
EXEMPT = re.compile(r"//\s*senza-annulla:\s*(.+)")


def strip_comments(text: str) -> str:
    out = []
    index = 0
    length = len(text)
    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end == -1 else end
            out.append("\n" * text.count("\n", index, end))
            index = end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end == -1 else end + 2
            out.append("\n" * text.count("\n", index, end))
            index = end
        elif text[index] == '"':
            end = index + 1
            while end < length and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            out.append(" " * (end + 1 - index))
            index = end + 1
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


def block_after(text: str, start: int) -> str:
    open_at = text.find("{", start)
    if open_at == -1:
        return ""
    depth = 0
    for index in range(open_at, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at + 1 : index]
    return ""


def computedAccessors(text: str, fields: list[str]) -> list[str]:
    """Proprietà calcolate il cui `set` scrive in un campo del piano.

    Una `var archCurve` con dentro `archCurves[activeArch] = nuova` è un modo di
    scrivere nel piano quanto l'assegnazione diretta, e chi legge il codice non
    lo distingue. Sorvegliarne solo i campi lascerebbe scoperta proprio la
    strada più facile da imboccare senza accorgersene.
    """
    found: list[str] = []
    for match in re.finditer(r"\bvar\s+(\w+)\s*:\s*[^={\n]+\{", text):
        name = match.group(1)
        if name in fields:
            continue
        body = block_after(text, match.end() - 1)
        if "set" not in body:
            continue
        if any(re.search(rf"\b{field}\s*(?:\[[^\]]*\])?\s*=(?!=)", body) for field in fields):
            found.append(name)
    return found


def snapshot_fields(text: str) -> list[str]:
    start = text.find("struct PlanSnapshot")
    if start == -1:
        return []
    return re.findall(r"^\s*var\s+(\w+)\s*:", block_after(text, start), re.M)


def main() -> int:
    raw = MODEL.read_text(encoding="utf-8")
    text = strip_comments(raw)

    fields = snapshot_fields(text)
    if not fields:
        print("PlanSnapshot non trovato: il controllo non sa che cosa sorvegliare.")
        return 1

    # Anche gli **accessori calcolati** che scrivono nel piano.
    #
    # `archCurve` — al singolare — legge e scrive `archCurves[activeArch]`. Sorvegliando i soli
    # nomi dei campi, `archCurve = curva` passava inosservato: ed è esattamente lì che si
    # nascondeva uno dei due difetti che questo controllo è nato per trovare. Un campo raggiunto
    # attraverso un accessore è un campo raggiunto.
    fields += computedAccessors(text, fields)

    # Scrive nel piano: assegnazione, oppure una delle mutazioni di un array.
    mutation = re.compile(
        r"\b(" + "|".join(fields) + r")\s*(?:\[[^\]]*\])?\s*"
        r"(?:=(?!=)|\.(?:append|insert|remove|removeAll|removeFirst|removeLast|sort|swapAt)\b)"
    )

    bodies: dict[str, str] = {}
    lines: dict[str, int] = {}
    for match in re.finditer(r"\bfunc\s+(\w+)\s*\(", text):
        name = match.group(1)
        bodies[name] = bodies.get(name, "") + block_after(text, match.end())
        lines.setdefault(name, text.count("\n", 0, match.start()) + 1)

    def records(name: str, seen: set[str] | None = None) -> bool:
        seen = seen or set()
        if name in seen:
            return False
        seen.add(name)
        body = bodies.get(name, "")
        if any(recorder in body for recorder in RECORDERS):
            return True
        for called in set(re.findall(r"\b(\w+)\s*\(", body)):
            if called in bodies and called != name and records(called, seen):
                return True
        return False

    # Le eccezioni dichiarate: il commento sta entro tre righe sopra la firma.
    source_lines = raw.splitlines()
    exempt: dict[str, str] = {}
    for index, line in enumerate(source_lines):
        found = EXEMPT.search(line)
        if not found:
            continue
        for following in source_lines[index + 1 : index + 5]:
            declared = re.search(r"\bfunc\s+(\w+)\s*\(", following)
            if declared:
                exempt[declared.group(1)] = found.group(1).strip()
                break

    problems = []
    for name, body in bodies.items():
        if name in exempt or not mutation.search(body) or records(name):
            continue
        problems.append((lines[name], name))

    if problems:
        print("Modifiche al piano che ⌘Z non riporta indietro:\n")
        for line, name in sorted(problems):
            print(
                f"  Sources/CBCTMacApp/AppModel.swift:{line}: {name}() cambia il piano "
                "senza registrare un passo di annulla"
            )
        print()
        print(
            f"{len(problems)} da sistemare. Chiudi con `recordUndo(\"…\")`, oppure — se "
            "l'eccezione è vera — scrivila sopra la firma:\n    // senza-annulla: <motivo>"
        )
        return 1

    print(
        f"Ogni modifica al piano si annulla. {len(fields)} campi sorvegliati, "
        f"{len(exempt)} funzioni esentate."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
