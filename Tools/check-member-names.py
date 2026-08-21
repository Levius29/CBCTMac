#!/usr/bin/env python3
"""Trova i nomi quasi-sinonimi chiamati sul tipo sbagliato.

# Perché serve, e perché `swiftc -parse` non basta

In questo ambiente il bersaglio dell'applicazione non si compila — vuole AppKit
e SwiftUI — quindi l'unico controllo disponibile sul suo codice è `-parse`, che
verifica la **grammatica** e nient'altro. Un nome di membro sbagliato è
grammatica corretta: passa, e l'errore si scopre sul Mac.

Il caso che ha motivato questo controllo: `ImplantModel` dichiara `displayName`,
mentre `Tool`, `WorkMode` e `DentalArch` dichiarano `localizedName`. Scrivere
`placement.model.localizedName` è un'analogia sbagliata, e il compilatore la
segnala una riga più in là con un messaggio su `Optional<String>.Stride` —
perché l'interpolazione irrisolta lascia aperto il tipo, e il primo candidato
assurdo è quello che finisce nel messaggio. Un giro di compilazione buttato per
un nome.

# Perché solo alcune famiglie di nomi, e non tutti i membri

Il primo tentativo controllava **ogni** membro, e annegava. Senza la libreria
standard sotto gli occhi, un tipo che il progetto si limita a estendere — `Data`,
`String`, `Vec3` — sembra avere per soli membri quelli dell'estensione, e ogni
`.count` diventa un allarme. Aggiungere elenchi di eccezioni per la libreria
standard e per i protocolli avrebbe prodotto un controllo che nessuno guarda.

La trappola vera è più stretta di così: sono i nomi **quasi-sinonimi**, quelli
che esistono su molti tipi con la stessa aria e non su tutti. Nessuno di questi
viene dalla libreria standard né da un protocollo, quindi la risoluzione
parziale qui basta e il controllo resta silenzioso.

# Che cosa risolve

- `x.membro` dove `x` è legato da `let x = TipoDelProgetto(` o `let x: Tipo`;
- `x.proprietà.membro`, un salto in più, per il tipo dichiarato della proprietà.

Solo tipi **dichiarati** nel progetto, non quelli che il progetto estende: dei
secondi non si vede l'elenco completo dei membri. Quel che non riesce a
risolvere lo tace.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

# I nomi che si scambiano l'uno per l'altro. Vanno a coppie o a terne di
# quasi-sinonimi, ed è l'analogia a farli sbagliare: si è appena scritto
# `tool.localizedName`, la riga dopo si scrive `model.localizedName`, e il
# modello quello lì non ce l'ha.
WATCHED = {
    "localizedName", "displayName", "shortName", "kindName",
    "systemImageName", "explanation", "hint", "summary", "formattedValue",
}

TYPE_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:final\s+)?(?:struct|enum|class|actor)\s+([A-Z]\w*)"
)
EXTENSION = re.compile(r"^\s*(?:public\s+)?extension\s+([A-Z]\w*)")
MEMBER_DECL = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:private\(set\)\s+)?(?:static\s+)?(?:final\s+)?"
    r"(?:var|let|func)\s+`?([a-z]\w*)`?"
)
CASE_DECL = re.compile(r"^\s*case\s+([a-z]\w*)")
# `var nome: Tipo` — il tipo dichiarato di una proprietà, senza optional né generici.
TYPED_PROPERTY = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:private\(set\)\s+)?(?:var|let)\s+`?([a-z]\w*)`?\s*:\s*([A-Z]\w*)\s*[?{=\n]"
)
# `let x = Tipo(` oppure `let x: Tipo`
LOCAL_INIT = re.compile(r"\b(?:let|var)\s+([a-z]\w*)\s*=\s*([A-Z]\w*)\(")
LOCAL_TYPED = re.compile(r"\b(?:let|var)\s+([a-z]\w*)\s*:\s*([A-Z]\w*)\b")
# Un nome che in qualche punto del file è anche parametro di chiusura, variabile di
# ciclo o parametro di funzione **non** si può legare leggendo: il legame vale in uno
# scopo e qui gli scopi non si vedono. È l'errore che il primo tentativo faceva —
# `quality` legato da un `let` in fondo al file e poi letto dentro un `ForEach { quality in }`,
# dove è tutt'altra cosa. Nel dubbio si tace.
SHADOWED = re.compile(
    r"(?:\{\s*|,\s*|\(\s*|\bfor\s+)([a-z]\w*)\s+in\b"
    r"|\bfunc\s+\w+\s*\([^)]*?\b([a-z]\w*)\s*:"
    r"|\bcase\s+(?:let\s+)?\.?\w*\(\s*(?:let\s+)?([a-z]\w*)\s*\)")
CHAIN = re.compile(r"\b([a-z]\w*)((?:\.[a-z]\w*)+)")


def strip_comments_and_strings(text: str) -> str:
    """Il testo dei commenti e delle stringhe non è codice.

    Le **interpolazioni** però sì, ed è proprio lì che stava il difetto: si
    tengono, sostituendo la stringa che le contiene con il loro contenuto.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text[i] == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "(":
                        # Interpolazione: si copia il contenuto fra parentesi.
                        depth = 1
                        i += 2
                        while i < n and depth > 0:
                            if text[i] == "(":
                                depth += 1
                            elif text[i] == ")":
                                depth -= 1
                                if depth == 0:
                                    break
                            else:
                                out.append(text[i])
                            i += 1
                        out.append(" ")
                        i += 1
                        continue
                    i += 2
                    continue
                i += 1
            i += 1
            out.append(" ")
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def collect_types() -> tuple[dict[str, set[str]], dict[str, dict[str, str]], set[str]]:
    """Membri dichiarati da ciascun tipo, e tipo dichiarato di ciascuna proprietà."""
    members: dict[str, set[str]] = {}
    properties: dict[str, dict[str, str]] = {}
    declared: set[str] = set()

    for path in sorted(SOURCES.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        stack: list[tuple[str | None, int]] = []
        depth = 0
        for line in lines:
            code = line.split("//")[0]
            own = TYPE_DECL.match(line)
            opening = own or EXTENSION.match(line)
            if opening and "{" in code:
                if own:
                    declared.add(own.group(1))
                stack.append((opening.group(1), depth))
                members.setdefault(opening.group(1), set())
                properties.setdefault(opening.group(1), {})
            elif stack:
                current = stack[-1][0]
                match = MEMBER_DECL.match(line) or CASE_DECL.match(line)
                if match:
                    members[current].add(match.group(1))
                typed = TYPED_PROPERTY.match(line + "\n")
                if typed:
                    properties[current][typed.group(1)] = typed.group(2)
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
    return members, properties, declared


def main() -> int:
    members, properties, declared = collect_types()

    findings = []
    for path in sorted(SOURCES.rglob("*.swift")):
        raw = path.read_text(encoding="utf-8")
        code = strip_comments_and_strings(raw)
        shadowed = {
            name for group in SHADOWED.findall(code) for name in group if name
        }
        # Legato più di una volta a tipi diversi: idem, non si sa quale valga qui.
        counts: dict[str, set[str]] = {}
        for name, type_name in LOCAL_INIT.findall(code) + LOCAL_TYPED.findall(code):
            counts.setdefault(name, set()).add(type_name)

        bindings: dict[str, str] = {}
        for name, types in counts.items():
            if name in shadowed or len(types) != 1:
                continue
            only = types.pop()
            if only in declared:
                bindings[name] = only

        for line_number, line in enumerate(code.splitlines(), start=1):
            for root, tail in CHAIN.findall(line):
                type_name = bindings.get(root)
                if type_name is None:
                    continue
                for step in tail.strip(".").split("."):
                    if type_name is None or type_name not in declared:
                        break
                    if step in members[type_name]:
                        type_name = properties[type_name].get(step)
                        continue
                    if step in WATCHED:
                        findings.append(
                            (path.relative_to(ROOT), line_number, type_name, step))
                    break

    if findings:
        print("Nomi quasi-sinonimi chiamati sul tipo sbagliato:\n")
        for path, number, type_name, member in sorted(set(findings)):
            others = sorted(t for t, names in members.items() if member in names)[:3]
            hint = f"  (lo dichiarano: {', '.join(others)})" if others else ""
            print(f"  {path}:{number}  {type_name}.{member}{hint}")
        return 1

    print("Nessun nome quasi-sinonimo sul tipo sbagliato.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
