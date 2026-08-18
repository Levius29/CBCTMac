#!/usr/bin/env python3
"""Trova chiamate a inizializzatori membro a membro con gli argomenti in ordine sbagliato.

# Perché

Swift genera per ogni `struct` senza `init` esplicito un inizializzatore i cui parametri seguono
**l'ordine di dichiarazione delle proprietà**, e pretende che le chiamate lo rispettino. È una
regola che il compilatore applica e che leggendo il codice non si vede: una chiusura in più
aggiunta in fondo a una chiamata lunga trenta righe sembra a posto e non compila.

È già costato due giri sul Mac in una volta sola — `onDrag` dopo `onClick` e `onCancel` prima di
`onDragEnded`, su viste che dichiarano venti richiami — e `swiftc -parse` non lo vede perché la
sintassi è perfetta: è la corrispondenza fra chiamata e dichiarazione a non tornare.

# Che cosa guarda

Solo le `struct` del progetto **senza** inizializzatore esplicito, perché sono le sole a usare
quello membro a membro. Una `struct` che ne dichiara uno proprio accetta l'ordine che vuole, e
segnalarla darebbe rumore su ogni chiamata.

Gli argomenti della chiamata devono comparire come **sottosuccessione** delle proprietà: se ne
possono saltare — quelle con valore predefinito — ma non scambiare.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

STRUCT = re.compile(
    r"^(?:public\s+|internal\s+|private\s+|fileprivate\s+)?struct\s+([A-Za-z_]\w*)"
    r"[^{]*\{(.*?)\n\}", re.M | re.S
)
PROPERTY = re.compile(
    r"^    (?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:var|let)\s+([A-Za-z_]\w*)\s*:", re.M
)
EXPLICIT_INIT = re.compile(r"^    (?:public\s+|internal\s+|private\s+)?init\s*\(", re.M)


def strip_noise(text):
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", "", text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def call_arguments(text, start):
    """Le etichette di primo livello di una chiamata che comincia alla parentesi `start`."""
    depth = 0
    labels = []
    current = ""
    for index in range(start, len(text)):
        character = text[index]
        if character in "([{":
            depth += 1
            if depth == 1:
                current = ""
                continue
        elif character in ")]}":
            depth -= 1
            if depth == 0:
                match = re.match(r"\s*([A-Za-z_]\w*)\s*:", current)
                if match:
                    labels.append(match.group(1))
                return labels
            continue
        if depth == 1 and character == ",":
            match = re.match(r"\s*([A-Za-z_]\w*)\s*:", current)
            if match:
                labels.append(match.group(1))
            current = ""
        else:
            current += character
    return labels


def main():
    files = {p: strip_noise(p.read_text(encoding="utf-8", errors="replace"))
             for p in SOURCES.rglob("*.swift")}

    order = {}
    for body in files.values():
        for name, contents in STRUCT.findall(body):
            if EXPLICIT_INIT.search(contents):
                continue
            properties = PROPERTY.findall(contents)
            if properties:
                order[name] = properties

    problems = []
    for path, body in sorted(files.items()):
        for name, properties in order.items():
            for match in re.finditer(r"\b" + name + r"\s*\(", body):
                labels = call_arguments(body, match.end() - 1)
                if len(labels) < 2:
                    continue
                positions = [properties.index(l) for l in labels if l in properties]
                if len(positions) < 2 or positions == sorted(positions):
                    continue
                # La prima coppia fuori ordine: dire *quale* risparmia di rileggere la chiamata.
                culprit = next(
                    (labels[i] for i in range(1, len(positions))
                     if positions[i] < positions[i - 1]),
                    labels[-1])
                line = body[: match.start()].count("\n") + 1
                problems.append((path.relative_to(ROOT), line, name, culprit))

    if not problems:
        print(f"Ordine degli argomenti coerente. {len(order)} tipi membro a membro.")
        return 0

    for path, line, name, culprit in problems:
        print(f"  {path}:{line}: «{name}(…)» ha «{culprit}» fuori dall'ordine di dichiarazione.")
    print()
    print(f"{len(problems)} da riordinare. Sul Mac sarebbero altrettanti errori di compilazione.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
