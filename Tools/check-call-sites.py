#!/usr/bin/env python3
"""Verifica le costruzioni dei tipi del progetto contro le firme dichiarate.

# Il collo di bottiglia che questo controllo attacca

Il bersaglio dell'applicazione non si compila in questo ambiente: vuole l'SDK di
macOS. L'unico controllo disponibile sul suo codice è `swiftc -parse`, che
verifica la **grammatica**. Un'etichetta di argomento sbagliata è grammatica
corretta, quindi passa — e si scopre sul Mac, un giro dopo.

È già costato. `PanoramicViewportView(clip:)` passava un parametro che quella
vista non dichiara: l'ho trovato rileggendo, non con uno strumento. E
`VolumeCamera(azimuth:elevation:targetMM:halfHeightMM:)` metteva due argomenti
nell'ordine sbagliato — che in Swift, sull'inizializzatore per membri, è un
errore e non una comodità.

Nessuno dei due riguarda SwiftUI o AppKit: riguardano **simboli dichiarati dentro
il progetto**. Quelli si possono verificare senza SDK, ed è ciò che fa questo.

# Come giudica

Raccoglie, per ogni `struct` e `class` del progetto:

- gli inizializzatori scritti a mano, con le loro etichette in ordine;
- l'inizializzatore **per membri** che Swift sintetizza per una `struct` che non
  ne dichiara uno nel corpo principale: le proprietà immagazzinate, in ordine di
  dichiarazione, con l'indicazione di quali hanno un valore predefinito.

Poi trova le costruzioni `Tipo(...)` e confronta le etichette.

Segnala due cose, entrambe errori di compilazione veri:

- un'etichetta che **nessun** inizializzatore di quel tipo dichiara;
- etichette giuste in **ordine sbagliato**, quando un solo inizializzatore le
  contiene tutte.

# Che cosa tace, di proposito

Tutto ciò che non riesce a risolvere con certezza: tipi generici con vincoli,
costruzioni con argomenti variadici, un tipo dichiarato in più moduli con firme
diverse. Un controllo che indovina viene ignorato dopo la seconda falsa
segnalazione, e allora non serve più a niente.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCANNED = [ROOT / "Sources", ROOT / "Tests"]

TYPE_DECL = re.compile(
    r"^(?P<indent>[ \t]*)(?:public |internal |private |fileprivate |package )?"
    r"(?:final )?(?P<kind>struct|class)\s+(?P<name>\w+)"
)
INIT_DECL = re.compile(
    # `init`, `init?`, e la clausola generica che ci può stare in mezzo:
    # `init?<Cells: Sequence>(cells:)` è un inizializzatore come gli altri, e non
    # riconoscerlo faceva credere che il tipo non ne dichiarasse nessuno — quindi che valesse
    # quello per membri, quindi che ogni sua costruzione fosse sbagliata.
    r"^[ \t]*(?:public |internal |private |fileprivate |package )?"
    r"(?:required |convenience |override )*init(?P<optional>\?|!)?"
    r"(?:<[^>]*>)?\s*\("
)
STORED = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public |internal |private |fileprivate |package )?"
    r"(?:private\(set\)\s+|public\(set\)\s+)?"
    r"(?P<kind>var|let)\s+(?P<name>\w+)\s*:\s*(?P<rest>.+)$"
)


def strip_strings_and_comments(text: str) -> str:
    """Sostituisce stringhe e commenti con spazi, conservando le posizioni."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(" " * (end - i) if "\n" not in text[i:end] else
                       "".join(" " if c != "\n" else "\n" for c in text[i:end]))
            i = end
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append("".join(" " if c != "\n" else "\n" for c in text[i:end]))
            i = end
            continue
        if text[i] == '"':
            start = i
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i = min(i + 1, n)
            out.append(" " * (i - start))
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def labels_of_signature(signature: str) -> list[tuple[str, bool]]:
    """Etichette di un elenco di parametri, con l'indicazione del valore predefinito."""
    result = []
    depth = 0
    current = ""
    for char in signature:
        if char in "([{<":
            depth += 1
        elif char in ")]}>":
            depth -= 1
        if char == "," and depth == 0:
            result.append(current)
            current = ""
            continue
        current += char
    if current.strip():
        result.append(current)

    labels = []
    for piece in result:
        piece = piece.strip()
        if not piece:
            continue
        has_default = "=" in piece.split(":", 1)[-1]
        head = piece.split(":", 1)[0].strip()
        names = head.split()
        if not names:
            continue
        external = names[0]
        labels.append((external, has_default))
    return labels


def balanced(text: str, start: int) -> tuple[str, int] | None:
    """Il contenuto delle parentesi che comincia a `start`, e l'indice dopo la chiusura."""
    assert text[start] == "("
    depth = 0
    i = start
    n = len(text)
    while i < n:
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i + 1
        i += 1
    return None


def collect_types(files: list[Path]) -> dict[str, dict]:
    """Per ogni tipo: inizializzatori dichiarati e proprietà immagazzinate.

    Si scorre per **posizione nel testo** e non per riga: una firma di
    inizializzatore su più righe — la norma in questo progetto — non sta dentro una
    riga sola, e cercarla per contenuto trova la prima riga uguale invece di questa.
    Era il difetto della prima stesura, e produceva un elenco di falsi allarmi lungo
    quanto il progetto.
    """
    types: dict[str, dict] = {}
    counts: dict[str, int] = {}
    for path in files:
        clean = strip_strings_and_comments(path.read_text(encoding="utf-8"))
        stack: list[tuple[str, int]] = []
        depth = 0
        offset = 0
        for line in clean.splitlines(keepends=True):
            opening = TYPE_DECL.match(line)
            if opening and "{" in line:
                name = opening.group("name")
                counts[name] = counts.get(name, 0) + 1
                types.setdefault(
                    name, {"inits": [], "stored": [], "declaresInit": False,
                           "kind": opening.group("kind")})
                stack.append((name, depth))
            elif stack:
                entry = types[stack[-1][0]]
                if initMatch := INIT_DECL.match(line):
                    entry["declaresInit"] = True
                    # La parentesi dell'`init`, non la prima della riga: `init?(` e i
                    # modificatori davanti spostano tutto, e un offset sbagliato di un carattere
                    # fa leggere la firma da un altro punto.
                    body = balanced(clean, offset + initMatch.end() - 1)
                    if body is not None:
                        entry["inits"].append(labels_of_signature(body[0]))
                else:
                    stored = STORED.match(line)
                    if stored and depth == stack[-1][1] + 1:
                        rest = stored.group("rest")
                        # Le calcolate non entrano nell'init per membri. Niente `continue` qui:
                        # salterebbe l'avanzamento dell'offset in fondo al ciclo, e da lì in poi
                        # ogni firma verrebbe letta dal punto sbagliato del file.
                        if not rest.rstrip().endswith("{"):
                            entry["stored"].append(
                                (stored.group("name"), "=" in rest, stored.group("kind")))
            depth += line.count("{") - line.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
            offset += len(line)

    # Un nome dichiarato più volte — due `struct Outcome` locali dentro due funzioni diverse,
    # un `Snapshot` del modello e uno di comodo dentro una prova — non identifica un tipo solo,
    # e unirne le firme produce un miscuglio che non appartiene a nessuno dei due. Nel dubbio
    # si tace: questo controllo esiste per essere creduto, e una segnalazione falsa costa più
    # di dieci vere.
    for name in list(types):
        if counts[name] > 1:
            del types[name]
    return types


def memberwise(entry: dict) -> list[tuple[str, bool]] | None:
    """L'inizializzatore per membri, se Swift lo sintetizza."""
    if entry["kind"] != "struct" or entry["declaresInit"]:
        return None
    result = []
    for name, has_default, kind in entry["stored"]:
        # Un `let` già inizializzato non compare nell'init per membri.
        if kind == "let" and has_default:
            continue
        result.append((name, has_default))
    return result or None


def call_labels(arguments: str) -> list[str] | None:
    """Le etichette di una chiamata, o `None` se non si riesce a leggerla con certezza."""
    labels = []
    depth = 0
    piece = ""
    pieces = []
    for char in arguments:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            pieces.append(piece)
            piece = ""
            continue
        piece += char
    if piece.strip():
        pieces.append(piece)

    for item in pieces:
        item = item.strip()
        if not item:
            continue
        match = re.match(r"^([A-Za-z_]\w*)\s*:", item)
        labels.append(match.group(1) if match else "_")
    return labels


def main() -> int:
    files = sorted(p for base in SCANNED for p in base.rglob("*.swift"))
    types = collect_types(files)

    findings = []
    for path in files:
        clean = strip_strings_and_comments(path.read_text(encoding="utf-8"))
        for match in re.finditer(r"\b([A-Z]\w*)\s*\(", clean):
            name = match.group(1)
            entry = types.get(name)
            if entry is None:
                continue
            signatures = list(entry["inits"])
            member = memberwise(entry)
            if member is not None:
                signatures.append(member)
            if not signatures:
                continue
            # `.Tipo(` è un caso di enum, non una costruzione.
            if match.start() > 0 and clean[match.start() - 1] == ".":
                continue

            body = balanced(clean, match.end() - 1)
            if body is None:
                continue
            labels = call_labels(body[0])
            if labels is None or "_" in labels:
                # Argomenti senza etichetta: la corrispondenza posizionale è oltre quel che
                # questo controllo sa fare con certezza, e nel dubbio tace.
                continue
            if not labels:
                continue

            declared = {label for signature in signatures for label, _ in signature}
            unknown = [label for label in labels if label not in declared]
            line = clean[: match.start()].count("\n") + 1
            if unknown:
                findings.append(
                    (path.relative_to(ROOT), line, name,
                     f"etichette che nessun inizializzatore dichiara: {', '.join(unknown)}"))
                continue

            # Ordine: si confronta solo con gli inizializzatori che contengono tutte le
            # etichette usate, e solo se ce n'è esattamente uno — altrimenti non si sa quale
            # l'autore intendesse.
            candidates = [
                signature for signature in signatures
                if set(labels) <= {label for label, _ in signature}
            ]
            if len(candidates) != 1:
                continue
            order = [label for label, _ in candidates[0]]
            expected = [label for label in order if label in labels]
            if expected != labels:
                findings.append(
                    (path.relative_to(ROOT), line, name,
                     f"argomenti fuori ordine: {', '.join(labels)} invece di "
                     f"{', '.join(expected)}"))

    if findings:
        print("Costruzioni che non corrispondono alle firme dichiarate:\n")
        for path, line, name, reason in sorted(set(findings)):
            print(f"  {path}:{line}  {name} — {reason}")
        print(
            "\nSono errori di compilazione veri: `swiftc -parse` non li vede perché la"
            "\ngrammatica è corretta, e si scoprono sul Mac un giro dopo."
        )
        return 1

    print(f"Le costruzioni dei {len(types)} tipi del progetto corrispondono alle firme.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
