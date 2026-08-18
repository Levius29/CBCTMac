#!/usr/bin/env python3
"""Trova funzioni non isolate che chiamano funzioni `@MainActor` dello stesso file.

# Perché serve

`swiftc -parse` non conosce l'isolamento: `@MainActor` è sintatticamente un attributo come un
altro, e chiamarne una da un contesto non isolato passa il controllo qui e diventa un errore sul
Mac. È già successo — `AppIcon.install()` chiamava `image(size:)`, che è `@MainActor`, e il
difetto si è scoperto solo a compilazione.

# Che cosa considera isolato

Una funzione è isolata se lo è lei o se lo è il tipo che la contiene. Un tipo è isolato se porta
`@MainActor` oppure se conforma a uno dei protocolli che SwiftUI e AppKit dichiarano
main-actor: `View`, `App`, `Scene`, `ViewModifier`, `NSViewRepresentable` e simili. Quella lista
è il motivo per cui la stragrande maggioranza delle viste non ha bisogno di alcuna annotazione,
e ignorarla riempirebbe il rapporto di segnalazioni inutili.

Il confronto resta **dentro il file**: risolvere una chiamata fra file richiederebbe sapere quale
tipo la riceve, cioè un compilatore. Restare nel file rinuncia a qualche caso e in cambio non
produce falsi allarmi, che è il compromesso giusto per un controllo che gira a ogni consegna.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

MAIN_ACTOR_PROTOCOLS = {
    "View", "App", "Scene", "ViewModifier", "NSViewRepresentable",
    "NSViewControllerRepresentable", "NSApplicationDelegate", "Commands",
    "PreviewProvider", "Shape", "InsettableShape", "ToolbarContent",
}

TYPE_LINE = re.compile(
    r"^(?P<indent>\s*)(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+)*"
    r"(?P<kind>struct|enum|class|actor|extension)\s+(?P<name>[A-Za-z_]\w*)"
    r"(?P<rest>[^{]*)"
)
FUNC_LINE = re.compile(
    r"^(?P<indent>\s*)(?:public\s+|internal\s+|private\s+|fileprivate\s+|static\s+|"
    r"final\s+|class\s+|mutating\s+|nonisolated\s+|override\s+)*"
    r"func\s+(?P<name>[A-Za-z_]\w*)"
)


def strip_noise(text):
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", "", text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def analyse(path):
    lines = strip_noise(path.read_text(encoding="utf-8", errors="replace")).splitlines()

    isolated_funcs = set()
    plain_funcs = {}          # nome -> riga, per le funzioni non isolate
    pending_attributes = []
    type_stack = []           # (indent, isolato)

    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue

        if stripped.startswith("@"):
            pending_attributes.append(stripped)
            continue

        attributes = " ".join(pending_attributes)
        pending_attributes = []
        indent = len(line) - len(line.lstrip())

        while type_stack and indent <= type_stack[-1][0]:
            type_stack.pop()

        match = TYPE_LINE.match(line)
        if match and match.group("kind"):
            conformances = set(re.findall(r"[A-Za-z_]\w*", match.group("rest")))
            # `bool(...)` non è pedanteria: `type_stack and type_stack[-1][1]` restituisce la
            # **lista** quando è vuota, e appenderla la rende auto-referenziale — quindi truthy
            # dal tipo successivo in poi. Con quel difetto ogni funzione risultava isolata e il
            # controllo non poteva fallire, che è la peggiore condizione per un controllo.
            isolated = bool(
                "@MainActor" in attributes
                or (conformances & MAIN_ACTOR_PROTOCOLS)
                or (type_stack and type_stack[-1][1])
            )
            type_stack.append((indent, isolated))
            continue

        match = FUNC_LINE.match(line)
        if match:
            name = match.group("name")
            enclosing = type_stack[-1][1] if type_stack else False
            if "@MainActor" in attributes or enclosing:
                isolated_funcs.add(name)
            elif "nonisolated" not in stripped:
                plain_funcs.setdefault(name, number)

    if not isolated_funcs or not plain_funcs:
        return []

    # Chi chiama chi: si guarda il corpo di ogni funzione non isolata.
    problems = []
    for name, start in plain_funcs.items():
        indent = len(lines[start - 1]) - len(lines[start - 1].lstrip())
        called = set()
        for line in lines[start:]:
            if line.strip() and (len(line) - len(line.lstrip())) <= indent and line.strip() != "}":
                break
            called.update(re.findall(r"\b([a-z]\w*)\s*\(", line))
        hits = sorted(called & isolated_funcs - {name})
        if hits:
            problems.append((start, name, hits))
    return problems


def main():
    total = 0
    files = 0
    for path in sorted(SOURCES.rglob("*.swift")):
        files += 1
        for line, name, hits in analyse(path):
            rel = path.relative_to(ROOT)
            print(
                f"  {rel}:{line}: «{name}» non è isolata e chiama "
                f"{', '.join(f'{h}()' for h in hits)}, che lo è"
            )
            total += 1

    if total == 0:
        print(f"Nessuna chiamata fuori dall'attore. {files} file esaminati.")
        return 0
    print()
    print(f"{total} da sistemare. Sul Mac sarebbero altrettanti errori di compilazione.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
