#!/usr/bin/env python3
"""Trova riquadri che non collegano un gesto che gli altri collegano.

# Il difetto

Un ponte verso Metal dichiara una quindicina di richiami. Chi lo usa ne passa quelli che gli
servono, e quelli che dimentica non esistono — senza errore, senza avviso, senza differenza
visibile finché qualcuno non prova il gesto.

È già successo quattro volte insieme: sulle sezioni trasversali il tasto destro non regolava il
contrasto e il puntatore non leggeva la densità, sulla panorex il tasto destro non faceva nulla,
e nelle anteprime del ritaglio non si potevano scorrere le fette mentre si sceglieva il riquadro.
In tutti e quattro i casi il richiamo esisteva sul ponte e l'azione esisteva nel modello: mancava
la riga che li univa.

Il sintomo per chi usa il programma non è «manca una funzione», è **«il programma è incoerente»**:
lo stesso gesto fa una cosa qui e nulla lì, e non c'è modo di indovinare dove.

# La regola

Ogni costruzione di un ponte deve passare **tutti** i richiami che quel ponte dichiara. Le
omissioni volute si dichiarano con un commento sulla riga precedente:

    // gesto-non-richiesto: onRotate — l'anteprima del ritaglio non ruota, il riquadro è assiale

Non è burocrazia: la differenza fra un'omissione voluta e una dimenticata non si vede nel codice,
e questa è l'unica cosa che la rende visibile.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
OPT_OUT = re.compile(r"//\s*gesto-non-richiesto:\s*(on[A-Z]\w*)")


def strip_strings(text):
    """Via le stringhe, e i commenti **sostituiti da spazi**.

    Sostituiti e non cancellati: le posizioni dei caratteri devono restare quelle del file,
    altrimenti i numeri di riga segnalati puntano altrove. Togliere i commenti serve perché ne
    contengono di virgole, e la ricerca delle etichette ne inciampa: un'etichetta che non cade
    all'inizio del proprio segmento passa inosservata, e il controllo accusa una chiamata
    corretta. Un controllo che dà falsi allarmi viene ignorato, che è il modo più efficace di
    non averne uno.
    """
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def bridges(files):
    """Ponti verso Metal e i richiami che dichiarano."""
    found = {}
    for text in files.values():
        for match in re.finditer(
            r"struct\s+([A-Za-z_]\w*)\s*:[^{]*NSViewRepresentable[^{]*\{", text
        ):
            depth = 0
            start = match.end() - 1
            for index in range(start, len(text)):
                if text[index] == "{":
                    depth += 1
                elif text[index] == "}":
                    depth -= 1
                    if depth == 0:
                        body = text[start : index + 1]
                        handlers = set(re.findall(r"^    var (on[A-Z]\w*)\s*:", body, re.M))
                        if handlers:
                            found[match.group(1)] = handlers
                        break
    return found


def call_labels(text, open_paren):
    depth = 0
    labels = set()
    current = ""
    for index in range(open_paren, len(text)):
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
                    labels.add(match.group(1))
                return labels, index
            continue
        if depth == 1 and character == ",":
            match = re.match(r"\s*([A-Za-z_]\w*)\s*:", current)
            if match:
                labels.add(match.group(1))
            current = ""
        else:
            current += character
    return labels, len(text)


def main():
    raw = {p: p.read_text(encoding="utf-8", errors="replace") for p in sorted(APP.glob("*.swift"))}
    files = {p: strip_strings(t) for p, t in raw.items()}
    declared = bridges(files)
    if not declared:
        print("Nessun ponte verso Metal trovato.")
        return 0

    problems = []
    sites = 0
    for path, text in files.items():
        for name, handlers in declared.items():
            for match in re.finditer(r"\b" + name + r"\s*\(", text):
                # La dichiarazione stessa non è una chiamata.
                before = text[max(0, match.start() - 40) : match.start()]
                if "struct " in before:
                    continue
                sites += 1
                passed, end = call_labels(text, match.end() - 1)
                if not passed:
                    continue
                # Le esenzioni si leggono dal testo grezzo, dove i commenti ci sono ancora.
                excused = set(OPT_OUT.findall(raw[path][match.start() : end]))
                missing = sorted(handlers - passed - excused)
                if missing:
                    line = text[: match.start()].count("\n") + 1
                    problems.append((path.relative_to(ROOT), line, name, missing))

    if not problems:
        print(f"Ogni riquadro collega i gesti che dichiara. {sites} costruzioni esaminate.")
        return 0

    for path, line, name, missing in problems:
        print(f"  {path}:{line}: «{name}» non collega {', '.join(missing)}")
    print()
    print(
        f"{len(problems)} da collegare, oppure da dichiarare con "
        "«// gesto-non-richiesto: <nome> — <ragione>»."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
