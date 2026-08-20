#!/usr/bin/env python3
"""Campi del piano salvato che non vengono mai riletti.

`ProjectDocument` è il `.cbctplan`, ed è anche ciò che l'archivio conserva.
Ogni suo campo attraversa due funzioni che stanno a duecento righe di distanza:

    init(from model:)   lo scrive prendendolo dal modello
    apply(to model:)    lo rimette nel modello riaprendo il caso

Scriverlo e non rileggerlo compila, non dà avvisi, e produce un file che
contiene l'informazione giusta e un programma che la butta via. Non se ne
accorge nessuno finché non serve: è successo con l'esito della registrazione
della scansione, che si salvava da mesi e non tornava mai — la scansione si
rimetteva al posto giusto, ma il caso riaperto risultava «non registrato», il
contorno si disegnava nel grigio della posizione ignota, e la costruzione della
dima si rifiutava di partire.

Il verso opposto — un campo dichiarato e mai scritto — è lo stesso difetto visto
dall'altra parte: si rilegge un valore che nessuno ha mai messo lì.

Esenzione, sulla riga sopra la dichiarazione:

    // solo-in-scrittura: <motivo>
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCUMENT = ROOT / "Sources" / "CBCTMacApp" / "ProjectDocument.swift"

EXEMPT = re.compile(r"//\s*solo-in-scrittura:\s*(.+)")


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


def main() -> int:
    if not DOCUMENT.exists():
        print(f"{DOCUMENT} non c'è: il controllo non sa che cosa guardare.")
        return 1

    source = DOCUMENT.read_text(encoding="utf-8")

    start = source.find("struct ProjectDocument")
    if start == -1:
        print("struct ProjectDocument non trovata.")
        return 1
    struct = block_after(source, start)

    # I campi, con la riga su cui sono dichiarati.
    fields: list[tuple[str, int]] = []
    for match in re.finditer(r"^\s{4}var\s+(\w+)\s*:", struct, re.M):
        line = source.count("\n", 0, start + match.start()) + 1
        fields.append((match.group(1), line))

    # Le esenzioni: il commento sta entro tre righe sopra la dichiarazione.
    lines = source.splitlines()
    exempt: dict[str, str] = {}
    for index, line in enumerate(lines):
        found = EXEMPT.search(line)
        if not found:
            continue
        for following in lines[index + 1 : index + 4]:
            declared = re.match(r"\s*var\s+(\w+)\s*:", following)
            if declared:
                exempt[declared.group(1)] = found.group(1).strip()
                break

    writer_at = source.find("init(from model: AppModel)")
    reader_at = source.find("func apply(to model: AppModel)")
    if writer_at == -1 or reader_at == -1:
        print("init(from:) o apply(to:) non trovati: il controllo non può dire nulla.")
        return 1
    writer = block_after(source, writer_at)
    reader = block_after(source, reader_at)

    problems: list[tuple[int, str]] = []
    for field, line in fields:
        if field in exempt:
            continue
        if not re.search(rf"self\.{field}\s*=", writer):
            problems.append((line, f"«{field}» non viene scritto in init(from:)"))
        if not re.search(rf"\b{field}\b", reader):
            problems.append(
                (
                    line,
                    f"«{field}» si salva ma non si rilegge: riaprendo il caso il valore "
                    "torna a quello predefinito",
                )
            )

    if problems:
        print("Campi del piano che non fanno andata e ritorno:\n")
        for line, message in sorted(problems):
            print(f"  Sources/CBCTMacApp/ProjectDocument.swift:{line}: {message}")
        print()
        print(
            f"{len(problems)} da sistemare. Se un campo si scrive apposta senza rileggerlo, "
            "dillo sopra la dichiarazione:\n    // solo-in-scrittura: <motivo>"
        )
        return 1

    print(
        f"Ogni campo del piano fa andata e ritorno. "
        f"{len(fields)} campi, {len(exempt)} esentati."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
