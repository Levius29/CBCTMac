#!/usr/bin/env python3
"""Trova il codice che esiste solo sulla carta.

Un tipo pubblico che nessun cammino collega all'applicazione è, dal punto di
vista di chi usa il programma, codice che non esiste. Il difetto si è ripetuto
abbastanza volte da meritare un controllo: il riquadro di ritaglio, quattro tipi
di annotazione mai creabili, quattro moduli interi.

Non basta chiedersi se un tipo sia citato fuori dal suo modulo: `DICOMParser`
non lo è, eppure l'applicazione lo raggiunge attraverso `DICOMScanner`. La
domanda giusta è se esista un *cammino* dall'applicazione al tipo. Il controllo
parte dai file dell'applicazione, raccoglie i nomi che citano, apre i file che
li dichiarano, e ripete finché non trova più niente di nuovo. Quel che resta
fuori dalla chiusura non è raggiungibile da nessun gesto dell'utente.

Si segnalano i soli tipi che *offrono un'operazione* — hanno almeno un membro
statico pubblico — perché un tipo di soli dati non collegato è un dettaglio,
mentre un'operazione non collegata è una funzione promessa e mai consegnata.

L'esenzione si scrive sulla riga sopra la dichiarazione:

    // non-ancora-collegato: <motivo>
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
TESTS = ROOT / "Tests"
APP_MODULE = "CBCTMacApp"

DECL = re.compile(
    r"^\s*(?:public\s+)?(?:final\s+)?(?:struct|enum|class|actor|protocol|extension)\s+([A-Z]\w*)"
)
PUBLIC_DECL = re.compile(
    r"^\s*public\s+(?:final\s+)?(?:struct|enum|class|actor|protocol)\s+([A-Z]\w*)"
)
STATIC_MEMBER = re.compile(r"^\s*public\s+static\s+(?:func|var|let)\s")
EXEMPT = re.compile(r"//\s*non-ancora-collegato:\s*(.+)")
WORD = re.compile(r"\b[A-Z]\w*\b")


def strip_comments_and_strings(text: str) -> str:
    """Un nome citato in un commento o in una stringa non è un uso."""
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
    files = sorted(SOURCES.rglob("*.swift"))
    if not files:
        print("Nessun sorgente.", file=sys.stderr)
        return 2

    text = {}
    body = {}
    declares = {}        # file -> nomi dichiarati (anche in extension)
    declared_by = {}     # nome -> insieme di file
    roots = {}           # (modulo, nome) -> (file, riga)
    exemptions = {}

    for path in files:
        raw = path.read_text(encoding="utf-8")
        text[path] = raw
        body[path] = strip_comments_and_strings(raw)
        module = path.relative_to(SOURCES).parts[0]

        names = set()
        lines = raw.splitlines()
        current = None
        for number, line in enumerate(lines, start=1):
            match = DECL.match(line)
            if match:
                names.add(match.group(1))
            public = PUBLIC_DECL.match(line)
            if public and (len(line) - len(line.lstrip())) == 0:
                current = public.group(1)
                note = None
                for back in range(number - 2, max(-1, number - 6), -1):
                    if back < 0:
                        break
                    found = EXEMPT.search(lines[back])
                    if found:
                        note = found.group(1).strip()
                        break
                    stripped = lines[back].strip()
                    if stripped and not stripped.startswith("//"):
                        break
                if note:
                    exemptions[(module, current)] = note
            elif current is not None and STATIC_MEMBER.match(line):
                roots.setdefault((module, current), (path, number))
        declares[path] = names
        for name in names:
            declared_by.setdefault(name, set()).add(path)

    # Chiusura transitiva a partire dall'applicazione.
    frontier = [p for p in files if p.relative_to(SOURCES).parts[0] == APP_MODULE]
    reached = set(frontier)
    while frontier:
        path = frontier.pop()
        for name in set(WORD.findall(body[path])):
            for target in declared_by.get(name, ()):
                if target not in reached:
                    reached.add(target)
                    frontier.append(target)

    reachable_names = set()
    for path in reached:
        reachable_names |= declares[path]

    problems = []
    for (module, name), (path, number) in sorted(roots.items()):
        if (module, name) in exemptions:
            continue
        if name in reachable_names:
            continue
        problems.append((path.relative_to(ROOT), number, module, name))

    if problems:
        for rel, number, module, name in problems:
            print(f"{rel}:{number}: nessun cammino porta {module}.{name} all'applicazione")
        print()
        print(
            f"{len(problems)} tipi con operazioni pubbliche che l'applicazione non raggiunge.\n"
            "Collegali, oppure scrivi sopra la dichiarazione:\n"
            "    // non-ancora-collegato: <motivo>"
        )
        return 1

    esenti = sum(1 for key in exemptions if key in roots)
    print(
        f"Ogni operazione pubblica è raggiungibile dall'applicazione. "
        f"{len(roots)} tipi radice, {esenti} esentati."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
