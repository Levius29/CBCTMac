#!/usr/bin/env python3
"""Controlla che gli `switch` sugli enum dell'applicazione siano esaustivi.

Perché esiste. Il target `CBCTMacApp` importa SwiftUI, AppKit e Metal, quindi non compila su
Linux né in CI: si compila solo su un Mac. `AppContractTests` copre le chiamate dell'app **verso
i moduli condivisi**, ma non vede gli enum che l'app dichiara per sé — `Tool`, `ViewportSlot`,
`ViewportLayout`, `MPRResolution`.

Da lì un errore che è già costato un giro: aggiungere un caso a `Tool` e dimenticare uno degli
`switch` che lo consumano. Il compilatore Swift lo direbbe subito, ma il compilatore Swift qui non
c'è, quindi lo scopre chi compila sul Mac.

Questo controllo è **sintattico e volutamente prudente**. Non capisce Swift: conta le graffe e
legge le etichette `case`. Segnala uno `switch` soltanto quando tutte queste condizioni valgono:

  * non ha un `default:` né un caso `@unknown`;
  * le sue etichette appartengono tutte a un solo enum noto;
  * ne nomina almeno due, così un `switch` su valori omonimi di un altro tipo non lo attiva.

Con queste condizioni un falso positivo è improbabile, e un falso negativo — uno switch che passa
inosservato — è preferibile a un allarme che si impara a ignorare.

Uso:
    python3 Tools/check-exhaustive-switches.py [cartella]

Esce con stato 1 se trova qualcosa, così può stare in una verifica automatica.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ENUM_RE = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+)?enum\s+(\w+)\s*:[^{]*\{")
CASE_DECL_RE = re.compile(r"^\s*case\s+([A-Za-z_]\w*)")
SWITCH_RE = re.compile(r"^(\s*)switch\s+(.+?)\s*\{\s*$")
CASE_LABEL_RE = re.compile(r"^\s*case\s+(.+?):")
DOT_CASE_RE = re.compile(r"\.([A-Za-z_]\w*)")


def strip_comments(lines: list[str]) -> list[str]:
    """Toglie i commenti di riga. Basta: quelli a blocco non contengono `switch` utili."""
    out = []
    for line in lines:
        # Non tocca le stringhe: una `//` dentro una stringa è rara e al più produce
        # un'omissione, mai un falso allarme.
        index = line.find("//")
        out.append(line[:index] if index >= 0 else line)
    return out


def collect_enums(files: list[Path]) -> dict[str, set[str]]:
    """Enum dichiarati nell'app, con i loro casi."""
    enums: dict[str, set[str]] = {}
    for path in files:
        lines = strip_comments(path.read_text(encoding="utf-8").splitlines())
        index = 0
        while index < len(lines):
            match = ENUM_RE.match(lines[index])
            if not match:
                index += 1
                continue

            name = match.group(1)
            cases: set[str] = set()
            depth = lines[index].count("{") - lines[index].count("}")
            index += 1
            while index < len(lines) and depth > 0:
                line = lines[index]
                if depth == 1:
                    decl = CASE_DECL_RE.match(line)
                    if decl:
                        payload = line.split("case", 1)[1]
                        if "(" in payload:
                            # Caso con valori associati: la virgola separa i **parametri**, non i
                            # casi. Spezzare qui trasformava
                            # `case unsupportedFormatVersion(found: Int, supported: Int)`
                            # in due casi, di cui uno inventato, e il controllo segnalava come
                            # mancante un caso che non è mai esistito.
                            cases.add(decl.group(1))
                        else:
                            # `case a, b, c` su una riga sola: qui la virgola separa davvero.
                            for piece in payload.split(","):
                                token = re.match(r"\s*([A-Za-z_]\w*)", piece)
                                if token:
                                    cases.add(token.group(1))
                depth += line.count("{") - line.count("}")
                index += 1

            if cases:
                enums[name] = cases
    return enums


def find_switch_bodies(lines: list[str]):
    """Restituisce (riga, espressione, etichette, ha_default) per ogni `switch`."""
    results = []
    for start, line in enumerate(lines):
        match = SWITCH_RE.match(line)
        if not match:
            continue

        depth = 1
        labels: list[str] = []
        has_default = False
        index = start + 1
        while index < len(lines) and depth > 0:
            body = lines[index]
            # Le etichette che contano sono quelle al primo livello dello `switch`.
            if depth == 1:
                if re.match(r"^\s*default\s*:", body) or "@unknown" in body:
                    has_default = True
                label = CASE_LABEL_RE.match(body)
                if label:
                    labels.extend(DOT_CASE_RE.findall(label.group(1)))
            depth += body.count("{") - body.count("}")
            index += 1

        results.append((start + 1, match.group(2), labels, has_default))
    return results


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "Sources/CBCTMacApp")
    if not root.is_dir():
        print(f"Cartella non trovata: {root}", file=sys.stderr)
        return 2

    files = sorted(root.rglob("*.swift"))
    if not files:
        print(f"Nessun file Swift in {root}", file=sys.stderr)
        return 2

    # Gli `switch` si controllano solo nell'applicazione, che è ciò che qui non compila. Gli enum
    # invece si leggono da **tutti** i moduli: senza conoscere `AnatomicalPlane` di DICOMCore, uno
    # switch sui suoi tre casi verrebbe scambiato per un `ViewportSlot` a cui manca il riquadro 3D.
    sources = root.parent if root.name != "Sources" else root
    enum_files = sorted(sources.rglob("*.swift")) if sources.is_dir() else files
    enums = collect_enums(enum_files)
    if not enums:
        print("Nessun enum trovato: il controllo non ha nulla da verificare.", file=sys.stderr)
        return 2

    problems = []
    for path in files:
        lines = strip_comments(path.read_text(encoding="utf-8").splitlines())
        for line_number, expression, labels, has_default in find_switch_bodies(lines):
            if has_default or len(labels) < 2:
                continue

            used = set(labels)
            if not used:
                continue

            # Se un enum è coperto **esattamente**, lo switch è esaustivo e si passa oltre. Senza
            # questa regola un `switch` su `AnatomicalPlane` — assiale, coronale, sagittale —
            # verrebbe scambiato per un `ViewportSlot` incompleto, perché quei tre casi sono un
            # sottoinsieme dei suoi quattro. È il motivo per cui il controllo legge tutti i moduli
            # e non solo l'applicazione: senza conoscere `AnatomicalPlane` non potrebbe accorgersene.
            if any(cases == used for cases in enums.values()):
                continue

            candidates = [
                name for name, cases in enums.items() if used < cases
            ]
            if len(candidates) != 1:
                continue

            name = candidates[0]
            missing = sorted(enums[name] - used)
            if missing:
                problems.append(
                    f"{path}:{line_number}: switch su «{expression}», che sembra un "
                    f"{name}, non copre: {', '.join('.' + case for case in missing)}"
                )

    if problems:
        print("Switch non esaustivi:\n")
        for problem in problems:
            print(f"  {problem}")
        print(
            f"\n{len(problems)} da sistemare. Sul Mac sarebbero altrettanti errori di "
            "compilazione."
        )
        return 1

    total = sum(len(cases) for cases in enums.values())
    print(
        f"Nessuno switch incompleto. {len(enums)} enum, {total} casi, "
        f"{len(files)} file esaminati."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
