#!/usr/bin/env python3
"""Trova i tipi usati senza importare il modulo che li dichiara.

# Perché serve

In questo ambiente il bersaglio dell'applicazione non compila: SwiftUI, AppKit e Metal non ci
sono. L'unica verifica possibile sui suoi file è `swiftc -parse`, che controlla la sintassi e
non i tipi — e un import mancante è sintatticamente perfetto. Il risultato è che l'errore si
scopre sul Mac, cioè dopo un giro completo di pull, compilazione e segnalazione.

Swift non riesporta: importare `DentalKit` non rende visibili i tipi di `MeasureKit` da cui
DentalKit dipende. La regola che questo script applica è quindi quella vera del compilatore, non
un'approssimazione prudente.

# Come evita i falsi positivi

- Toglie commenti e stringhe prima di guardare i nomi: un tipo citato in un commento non è un uso.
- Confronta parole intere, così `Annotation` non scatta dentro `AnnotationOverlay`.
- Ignora i tipi dichiarati nel modulo del file: lì l'import non serve.
- Ignora i nomi dichiarati **anche** nel proprio modulo, perché in caso di omonimia vince il
  locale e l'import non è necessario.

I nomi che collidono con SwiftUI e AppKit — `Text`, `Path`, `Shape` — non sono un problema qui
perché `check-cross-module-collisions.py` già impedisce che un modulo ne dichiari uno.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

DECLARATION = re.compile(
    r"^public\s+(?:final\s+)?(?:struct|enum|class|actor|protocol|typealias)\s+([A-Za-z_]\w*)",
    re.MULTILINE,
)
IMPORT = re.compile(r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_]\w*)", re.MULTILINE)
WORD = re.compile(r"\b([A-Z]\w*)\b")


def strip_noise(text):
    """Via i commenti e le stringhe: restano solo i nomi realmente usati."""
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", "", text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def main():
    modules = sorted(p for p in SOURCES.iterdir() if p.is_dir())

    # Tipi pubblici per modulo, e nomi dichiarati per modulo (pubblici o no).
    public_types = {}
    declared_anywhere = {}
    for module in modules:
        names = set()
        local = set()
        for path in module.rglob("*.swift"):
            body = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
            names.update(DECLARATION.findall(body))
            local.update(
                re.findall(
                    r"\b(?:struct|enum|class|actor|protocol|typealias)\s+([A-Za-z_]\w*)", body
                )
            )
        public_types[module.name] = names
        declared_anywhere[module.name] = local

    owner = {}
    for module_name, names in public_types.items():
        for name in names:
            owner.setdefault(name, set()).add(module_name)

    problems = []
    files_seen = 0

    for module in modules:
        own = module.name
        for path in sorted(module.rglob("*.swift")):
            files_seen += 1
            raw = path.read_text(encoding="utf-8", errors="replace")
            imported = set(IMPORT.findall(raw))
            body = strip_noise(raw)

            missing = {}
            for name in set(WORD.findall(body)):
                holders = owner.get(name)
                if not holders:
                    continue
                # Dichiarato nel proprio modulo: nessun import da fare.
                if name in declared_anywhere[own]:
                    continue
                needed = holders - imported - {own}
                if needed and not (holders & imported):
                    missing.setdefault(", ".join(sorted(needed)), set()).add(name)

            for module_name, names in sorted(missing.items()):
                problems.append(
                    (path.relative_to(ROOT), module_name, sorted(names))
                )

    if not problems:
        print(f"Nessun import mancante. {files_seen} file esaminati.")
        return 0

    for path, module_name, names in problems:
        print(f"  {path}: usa {', '.join(names)} senza «import {module_name}»")
    print()
    print(f"{len(problems)} da sistemare. Sul Mac sarebbero altrettanti errori di compilazione.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
