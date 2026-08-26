#!/usr/bin/env python3
"""Ogni stato che si accende deve potersi spegnere.

# Il guasto

`isShowingCephalometry` lo accendeva una voce di menu e non lo spegneva nessuno.
Il pannello cefalometrico restava in cima all'ispettore per tutto il resto della
sessione e, finché ci stava, copriva gli altri contesti: chi l'aveva aperto per
curiosità non rivedeva più il pannello dell'impianto, e non c'era niente che
dicesse perché o come tornare indietro. L'unica uscita era chiudere il
programma.

È una forma dello stesso difetto delle finestre modali — «se apro una cosa, poi
non posso più aprirne altre» — e ha una firma riconoscibile nel codice: un
booleano del modello con un `= true` e nessun `= false`.

# Che cosa guarda

Le proprietà booleane *pubbliche* di `AppModel`: quelle che una vista può
scrivere. Per ciascuna che venga accesa da qualche parte, pretende che esista
anche un modo di spegnerla — un `= false`, un `.toggle()`, un'assegnazione da
una variabile (`isScanVisible = visible`, che passa per entrambi i valori) o un
legame `$model.qualcosa`, che è il caso di un interruttore in una vista.

Le `private` e le `private(set)` restano fuori: le governa il modello, che le
spegne per conto proprio quando l'operazione finisce, e nessuna vista può
lasciarle accese.

# La seconda regola: la schermata di attesa

`loadingMessage` copre l'intera finestra finché non è `nil`. Spegnerla a mano in
ciascun ramo funziona finché i rami sono due; il giorno che uno resta scoperto
l'applicazione non si blocca — si *vela*, e sembra occupata a fare qualcosa che
ha già finito. Ogni funzione che l'accende deve quindi spegnerla con un `defer`,
che vale per tutte le uscite comprese quelle che verranno.

# L'esenzione

Sulla riga sopra la dichiarazione:

    // senza-uscita: <motivo>

Vale per gli stati che *devono* restare accesi una volta accesi — non ce ne sono
molti, ed è bene che scriverlo costi una riga di spiegazione.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
MODEL_FILE = APP / "AppModel.swift"

# `var nome = false` oppure `var nome: Bool = <espressione>`, a quattro spazi di rientro e senza
# `private`: sono le proprietà memorizzate che una vista può scrivere.
BOOL_DECLARATION = re.compile(r"^    var (\w+)\s*(?::\s*Bool\s*)?=\s*(?:true|false)\s*(?:\{.*)?$")
EXEMPT = re.compile(r"//\s*senza-uscita:\s*(.+)")


FUNCTION = re.compile(r"^    (?:@\w+\s+)*(?:private\s+|fileprivate\s+)?func\s+(\w+)")
OVERLAY_ON = re.compile(r"^\s*loadingMessage\s*=\s*(?!nil\b)\S")
OVERLAY_OFF = "defer { loadingMessage = nil }"


def overlay_problems(lines: list[str]) -> list[str]:
    """La schermata di attesa deve cadere da sé, da qualunque uscita si esca."""
    problems: list[str] = []
    for index, line in enumerate(lines):
        if not OVERLAY_ON.match(line):
            continue
        start = next(
            (i for i in range(index, -1, -1) if FUNCTION.match(lines[i])), None)
        if start is None:
            continue
        end = next(
            (i for i in range(index, len(lines)) if lines[i] == "    }"), len(lines))
        body = lines[start:end]
        if not any(OVERLAY_OFF in body_line for body_line in body):
            name = FUNCTION.match(lines[start]).group(1)
            problems.append(
                f"AppModel.swift:{index + 1}: `{name}` accende la schermata di attesa e non "
                f"garantisce di spegnerla. Serve `{OVERLAY_OFF}` subito dopo: un ramo che "
                "esce senza toglierla lascia la finestra velata e non più premibile.")
    return problems


def main() -> int:
    model_lines = MODEL_FILE.read_text(encoding="utf-8").splitlines()

    flags: dict[str, int] = {}
    exempt: set[str] = set()
    for index, line in enumerate(model_lines):
        match = BOOL_DECLARATION.match(line)
        if not match:
            continue
        name = match.group(1)
        flags[name] = index + 1
        if index and EXEMPT.search(model_lines[index - 1]):
            exempt.add(name)

    sources = {path.name: path.read_text(encoding="utf-8") for path in sorted(APP.glob("*.swift"))}
    text = "\n".join(sources.values())

    problems: list[str] = []
    for name, line_number in sorted(flags.items(), key=lambda item: item[1]):
        if name in exempt:
            continue

        # La dichiarazione resta fuori da entrambi i conti: `var acceso = false` non è un modo
        # di spegnere niente, ed è l'errore che rendeva questo controllo cieco proprio sul caso
        # per cui è nato.
        turned_on: list[tuple[str, int]] = []
        turned_off = False
        for file_name, source in sources.items():
            for number, line in enumerate(source.splitlines(), 1):
                if BOOL_DECLARATION.match(line) or line.lstrip().startswith("//"):
                    continue
                if re.search(rf"\b{name}\s*=\s*true\b", line):
                    turned_on.append((file_name, number))
                    continue
                # Lo spegnimento, in tutte le forme in cui si scrive: il valore contrario, la
                # commutazione, un legame che una vista può muovere nei due sensi, o
                # un'assegnazione da una variabile — `isScanVisible = visible` passa per entrambi.
                if (
                    re.search(rf"\b{name}\s*=\s*false\b", line)
                    or re.search(rf"\b{name}\.toggle\(\)", line)
                    or re.search(rf"\$\w*\.?{name}\b", line)
                    or re.search(rf"\b{name}\s*=\s*(?!true\b)[a-z_]\w*\s*$", line)
                ):
                    turned_off = True

        if not turned_on or turned_off:
            continue

        where = ", ".join(f"{file_name}:{number}" for file_name, number in turned_on[:3])
        problems.append(
            f"AppModel.swift:{line_number}: `{name}` si accende ({where}) e non si spegne "
            "da nessuna parte. Uno stato che resta acceso copre ciò che sta dietro, e chi ci "
            "finisce dentro non ha un gesto per uscirne.")

    problems.extend(overlay_problems(model_lines))

    if problems:
        print("Stati senza via d'uscita:")
        for problem in problems:
            print(f"  {problem}")
        print("  Esenzione: `// senza-uscita: <motivo>` sulla riga sopra la dichiarazione.")
        return 1

    print(
        f"Ogni stato che si accende si spegne: {len(flags)} proprietà booleane esaminate, "
        f"{len(exempt)} esentate, e la schermata di attesa cade da sé.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
