#!/usr/bin/env python3
"""Trova le operazioni pubbliche che nessuno chiama.

`check-unreachable-api.py` ragiona per **tipi**: chiede se esista un cammino
dall'applicazione a un tipo. Un tipo raggiungibile può però contenere
operazioni che nessuno invoca, e quelle il controllo per tipi non le vede
perché il tipo passa. Il caso tipico non è codice morto scritto per sbaglio: è
una capacità finita, provata, e mai collegata a un gesto — un'esportazione che
non compare in nessun menu, un'analisi che nessuna vista mostra. Dal punto di
vista di chi usa il programma non esiste, esattamente come se non fosse scritta.

La regola è più fine e più semplice di quella per tipi: un membro
`public static func` il cui nome non compare in **nessun altro file** di
`Sources/` è un'operazione che nessuno può invocare.

Due esiti distinti, perché sono due cose diverse:

- **chiamata solo nel proprio file** — esiste e funziona; non avrebbe bisogno
  di essere pubblica. È una nota, non un difetto, e non fa fallire il
  controllo.
- **chiamata da nessuno** — è l'operazione promessa e mai consegnata. Questa
  fa fallire.

I test non contano come uso: un'operazione che solo le prove chiamano è
provata e non consegnata.

Solo le funzioni, non le costanti. Un `public static let` citato soltanto nel
proprio file è una questione di visibilità, e una prova che verifica una soglia
chiamandola per nome invece che con un numero magico fa la cosa giusta.

L'esenzione si scrive sulla riga sopra la dichiarazione:

    // non-ancora-collegato: <motivo>
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

MEMBER = re.compile(r"^\s*public\s+static\s+func\s+(?:`)?([a-z]\w*)(?:`)?\b")
EXEMPT = re.compile(r"//\s*non-ancora-collegato:\s*(.+)")


def strip_comments_and_strings(text: str) -> str:
    """Un nome citato in un commento o in una stringa non è una chiamata."""
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
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = n if end < 0 else end + 3
            continue
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "(":
                        # Il contenuto di un'interpolazione **è** codice, e chiama funzioni: una
                        # API usata soltanto lì risultava chiamata da nessuno. È il difetto che
                        # ha segnalato `frontFace` come scollegata mentre il suggerimento del cubo
                        # la usa a ogni ridisegno.
                        depth = 1
                        i += 2
                        while i < n and depth > 0:
                            if text[i] == "(":
                                depth += 1
                            elif text[i] == ")":
                                depth -= 1
                                if depth == 0:
                                    break
                            out.append(text[i])
                            i += 1
                        out.append(" ")
                        i += 1
                        continue
                    i += 2
                    continue
                i += 1
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main() -> int:
    files = sorted(SOURCES.rglob("*.swift"))
    bodies = {path: strip_comments_and_strings(path.read_text(encoding="utf-8"))
              for path in files}

    # I nomi citati da ciascun file, una volta sola per file.
    mentions: dict[Path, set[str]] = {
        path: set(re.findall(r"\b[A-Za-z_]\w*\b", body)) for path, body in bodies.items()
    }

    findings = []
    private_use = []
    for path in files:
        lines = path.read_text(encoding="utf-8").splitlines()
        own = mentions[path]
        for number, line in enumerate(lines, start=1):
            match = MEMBER.match(line)
            if not match:
                continue
            name = match.group(1)
            # L'esenzione si cerca in tutto il blocco di commento sopra la dichiarazione, non
            # nella sola riga precedente: sopra una funzione documentata quella riga è l'ultima
            # del commento `///`, e pretendere l'esenzione proprio lì costringerebbe a
            # infilarla in mezzo alla documentazione.
            exempt = False
            index = number - 2
            while index >= 0:
                stripped = lines[index].strip()
                if not stripped.startswith("//"):
                    break
                if EXEMPT.search(stripped):
                    exempt = True
                    break
                index -= 1
            if exempt:
                continue
            elsewhere = any(name in mentions[other] for other in files if other != path)
            if elsewhere:
                continue
            # Due casi molto diversi, e distinguerli è ciò che rende il controllo
            # leggibile. Chiamata dentro il proprio file: esiste, funziona, e non
            # avrebbe bisogno di essere pubblica — è una nota, non un difetto.
            # Chiamata da nessuno: è l'operazione promessa e mai consegnata.
            body_uses = len(re.findall(rf"\b{re.escape(name)}\b", bodies[path]))
            if body_uses > 1:
                private_use.append((path.relative_to(ROOT), number, name))
            else:
                findings.append((path.relative_to(ROOT), number, name))

    if private_use:
        print("Nota — pubbliche ma chiamate solo nel proprio file (basterebbe interne):\n")
        for path, number, name in private_use:
            print(f"  {path}:{number}  {name}")
        print()

    if findings:
        print("Operazioni pubbliche che non chiama nessuno:\n")
        for path, number, name in findings:
            print(f"  {path}:{number}  {name}")
        print(
            "\nO le si collega a un gesto dell'utente, o le si toglie, o si scrive"
            "\nsulla riga sopra:  // non-ancora-collegato: <motivo>"
        )
        return 1

    print(f"Nessuna operazione pubblica scollegata ({len(files)} file).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
