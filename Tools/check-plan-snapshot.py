#!/usr/bin/env python3
"""L'istantanea del piano, e i quattro posti che devono restare d'accordo.

`AppModel.PlanSnapshot` è ciò che «annulla» riporta indietro. Ogni campo che ci
sta dentro compare in quattro posti diversi, lontani fra loro nello stesso file:

    1. `planSnapshot`          — dove si legge lo stato per fotografarlo
    2. `apply(_ snapshot:)`    — dove si riscrive tornando indietro
    3. il valore iniziale di `undoHistory`
    4. il blocco che azzera tutto all'apertura di un altro esame

Dimenticarne uno non produce un errore di compilazione e non produce un errore a
schermo: produce un piano che torna indietro **a metà**, oppure i denti di un
paziente sulle immagini di un altro. È già successo con i denti protesici, ed è
il genere di difetto che si trova soltanto rifacendo a mano un giro completo.

C'è una quinta regola, e nasce da un difetto vero trovato dopo: chi carica un
piano in blocco — `ProjectDocument.apply(to:)` — riversa i campi nel modello
senza passare da `recordUndo`, com'è giusto, perché caricare non è modificare.
Ma se non riparte anche la cronologia, il piano appena caricato non ci sta
dentro: ci sta quello di prima. Una modifica e un ⌘Z, e il caso caricato
scompare — o peggio, viene sostituito da quello di un altro paziente.

Esenzione, sulla riga sopra la dichiarazione del campo:

    // fuori-dall-azzeramento: <motivo>
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
MODEL_FILE = APP / "AppModel.swift"

# Quanti campi bisogna assegnare perché la funzione conti come «caricamento in
# blocco». Due possono essere una coincidenza; tre no.
BULK_THRESHOLD = 3

RESET_CALLS = ("resetUndoBaseline", "undoHistory.reset")


def strip_comments(text: str) -> str:
    """Via i commenti, tenendo le righe al loro posto."""
    out = []
    index = 0
    length = len(text)
    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            if end == -1:
                break
            out.append("\n")
            index = end + 1
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end == -1 else end + 2
            out.append("\n" * text.count("\n", index, end))
            index = end
        elif text[index] == '"':
            index += 1
            while index < length and text[index] != '"':
                index += 2 if text[index] == "\\" else 1
            index += 1
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


def block_after(text: str, start: int) -> str:
    """Il corpo fra graffe che comincia al primo `{` dopo `start`."""
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


def assignment(field: str, prefix: str = "") -> str:
    """Il campo viene scritto: per intero, per indice, oppure svuotato.

    `archCurves[arch] = …` è un azzeramento quanto `archCurves = [:]`, e un
    controllo che riconoscesse solo la seconda forma chiederebbe di riscrivere il
    codice per fargli piacere. La coda `(?!=)` tiene fuori i confronti.
    """
    return rf"\b{prefix}{field}\s*(?:\[[^\]]*\])?\s*(?:=(?!=)|\.removeAll\b)"


def snapshot_fields(text: str) -> list[str]:
    start = text.find("struct PlanSnapshot")
    if start == -1:
        return []
    body = block_after(text, start)
    return re.findall(r"^\s*var\s+(\w+)\s*:", body, re.M)


def functions(text: str) -> dict[str, str]:
    """Nome → corpo, per ogni funzione del file."""
    result: dict[str, str] = {}
    for match in re.finditer(r"\bfunc\s+(\w+)\s*\(", text):
        result.setdefault(match.group(1), "")
        result[match.group(1)] += block_after(text, match.end())
    return result


def expanded(body: str, bodies: dict[str, str]) -> str:
    """Il corpo, più quello delle funzioni che chiama, un livello.

    Un campo azzerato dentro `resetArchCurves()` è azzerato: il blocco che apre
    un esame lo chiama, e pretendere l'assegnazione scritta lì dentro
    costringerebbe a copiare il codice per far contento un controllo.
    """
    text = body
    for name in set(re.findall(r"\b(\w+)\s*\(", body)):
        if name in bodies:
            text += "\n" + bodies[name]
    return text


def main() -> int:
    raw = MODEL_FILE.read_text(encoding="utf-8")
    text = strip_comments(raw)
    fields = snapshot_fields(text)

    problems: list[str] = []

    if not fields:
        print("PlanSnapshot non trovato in AppModel.swift: il controllo non sa che cosa guardare.")
        return 1

    # Esenzioni dall'azzeramento, dichiarate sopra il campo dentro la struct.
    exempt: set[str] = set()
    lines = raw.splitlines()
    for index, line in enumerate(lines):
        match = re.search(r"//\s*fuori-dall-azzeramento:", line)
        if not match:
            continue
        for following in lines[index + 1 : index + 4]:
            declared = re.match(r"\s*var\s+(\w+)\s*:", following)
            if declared:
                exempt.add(declared.group(1))
                break

    # 1. la lettura
    #
    # Si pretende `campo: campo`, non il solo nome dell'etichetta: `cephTracing: CephTracing()`
    # compila, sembra giusto, e fotografa una costante invece dello stato — l'istantanea
    # risulterebbe sempre vuota per quel campo, e annulla lo azzererebbe a ogni passo.
    start = text.find("var planSnapshot")
    reader = block_after(text, start) if start != -1 else ""
    for field in fields:
        if not re.search(rf"\b{field}\s*:\s*{field}\b", reader):
            problems.append(
                f"«{field}» non viene letto in planSnapshot: l'istantanea non lo fotograferebbe"
            )

    # 2. la scrittura all'indietro
    start = text.find("func apply(_ snapshot: PlanSnapshot?)")
    restorer = block_after(text, start) if start != -1 else ""
    for field in fields:
        if not re.search(rf"\b{field}\s*=\s*snapshot\.{field}\b", restorer):
            problems.append(f"«{field}» non viene ripristinato in apply(_:), quindi annulla non lo tocca")

    # 3. il valore iniziale della cronologia
    #
    # Qui basta l'etichetta: il valore **dev'essere** una costante vuota, non lo stato del
    # modello, perché è il fondo da cui la cronologia parte.
    match = re.search(r"UndoHistory<PlanSnapshot>\(initial:.*?\)\)", text, re.S)
    initial = match.group(0) if match else ""
    for field in fields:
        if not re.search(rf"\b{field}\s*:", initial):
            problems.append(f"«{field}» manca nell'istantanea iniziale della cronologia")

    bodies = functions(text)

    # 4. l'azzeramento all'apertura di un altro esame
    # Il blocco giusto è quello che fa **due** cose: azzera i campi e riparte con la
    # cronologia. `resetUndoBaseline()` contiene la stessa riga e non azzera niente: prenderlo
    # per il blocco di apertura farebbe fallire il controllo su ogni campo, che è come non
    # averlo.
    reset_body = ""
    for _, body in bodies.items():
        if "undoHistory.reset(to: planSnapshot)" not in body:
            continue
        candidate = expanded(body, bodies)
        if not any(re.search(assignment(f), candidate) for f in fields):
            continue
        if len(candidate) > len(reset_body):
            reset_body = candidate
    if not reset_body:
        problems.append("non trovo il blocco che azzera il piano aprendo un altro esame")
    else:
        for field in fields:
            if field in exempt:
                continue
            if not re.search(assignment(field), reset_body):
                problems.append(
                    f"«{field}» non viene azzerato aprendo un altro esame: "
                    "resterebbe addosso alle immagini di un altro paziente"
                )

    # 5. chi carica un piano in blocco deve far ripartire la cronologia
    for path in sorted(APP.glob("*.swift")):
        source = strip_comments(path.read_text(encoding="utf-8"))
        for match in re.finditer(r"\bfunc\s+(\w+)\s*\(", source):
            name = match.group(1)
            body = block_after(source, match.end())
            if not body:
                continue
            assigned = [f for f in fields if re.search(assignment(f, prefix=r"model\."), body)]
            if len(assigned) < BULK_THRESHOLD:
                continue
            if any(call in body for call in RESET_CALLS):
                continue
            problems.append(
                f"{path.name}: {name}() riversa {len(assigned)} campi del piano nel modello "
                "senza far ripartire la cronologia — un ⌘Z dopo una modifica riporterebbe il "
                "piano di prima"
            )

    if problems:
        print("Istantanea del piano incoerente:\n")
        for problem in problems:
            print(f"  {problem}")
        print()
        print(
            f"{len(problems)} da sistemare. Ogni campo di PlanSnapshot va letto, ripristinato, "
            "inizializzato e azzerato."
        )
        return 1

    print(
        f"L'istantanea del piano è coerente in tutti e quattro i posti. "
        f"{len(fields)} campi, {len(exempt)} esentati dall'azzeramento."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
