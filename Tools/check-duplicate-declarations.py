#!/usr/bin/env python3
"""Cerca membri di tipo dichiarati due volte con la stessa firma.

# Perché esiste

`swiftc -parse` verifica la sintassi e non i nomi: un `var hint` dichiarato due volte nello stesso
enum, o una funzione lasciata in due copie da una modifica automatica, passa il controllo qui e
fallisce sul Mac. Sono errori banali da correggere e costosi da scoprire, perché costano un giro
completo — pull, build, incolla, correggi, ripush.

# Perché è così ristretto

La prima versione seguiva le graffe per ricostruire gli ambiti e ha prodotto diciassette falsi
positivi su diciassette: variabili locali omonime in funzioni diverse, e overload legittimi la cui
firma si estende su più righe. Un controllo che grida sempre viene spento, quindi vale meno di
niente.

Questa versione guarda **solo i membri di tipo** — quelli rientrati di esattamente quattro spazi,
che è dove Swift li mette — confronta la firma intera, tipi degli argomenti compresi, e riparte da
capo a ogni tipo dichiarato a colonna zero. Le tre restrizioni servono tutte: senza la prima
vedrebbe i locali, che non possono collidere fra funzioni; senza la seconda confonderebbe gli
overload, che sono legittimi; senza la terza griderebbe su ogni file con due `View` dentro, perché
entrambe hanno un `var body`. Sono i tre modi in cui ho visto fallire i due tentativi precedenti.
"""

import re
import sys
from pathlib import Path

MEMBER = re.compile(
    r'^ {4}(?!\s)'
    r'(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(?:public|internal|private|fileprivate|open)(?:\(set\))?\s+)*'
    r'(?:nonisolated\s+)?(?:static\s+|class\s+)?(?:final\s+)?(?:mutating\s+)?'
    r'(?:override\s+)?'
    r'(var|let|func|subscript|init)\b\s*([A-Za-z_]\w*)?'
)


def signature(lines: list[str], start: int) -> tuple[str, int]:
    """Firma normalizzata del membro che comincia a `start`, e la riga in cui finisce.

    Per le funzioni la firma si estende fino alla parentesi chiusa, che può stare parecchie righe
    più in basso: fermarsi alla prima riga confonderebbe due overload con lo stesso nome.
    """
    match = MEMBER.match(lines[start])
    if not match:
        return '', start
    keyword, name = match.group(1), match.group(2) or ''
    # Gli operatori non hanno un nome che questo controllo sappia leggere, e ridurli tutti alla
    # stessa firma vuota li farebbe collidere fra loro. Si lasciano stare.
    if not name and keyword != 'init':
        return '', start

    text = lines[start]
    index = start
    if '(' in text:
        while text.count('(') > text.count(')') and index + 1 < len(lines):
            index += 1
            text += ' ' + lines[index].strip()

    if keyword in ('var', 'let'):
        return f'{keyword} {name}', index

    # Solo i tipi degli argomenti, non i nomi interni né i valori predefiniti: due firme che
    # differiscono per il nome di un parametro interno sono la stessa firma per il compilatore.
    # Etichette **e** tipi. Con i soli tipi, `apply(toPoint: Vec3)` e `apply(toVector: Vec3)`
    # risulterebbero la stessa firma, che è il falso positivo più fastidioso perché colpisce
    # proprio le funzioni scritte bene, quelle che distinguono i casi con l'etichetta.
    arguments = ''
    if '(' in text:
        inside = text[text.index('(') + 1:text.rindex(')')] if ')' in text else ''
        parts = re.findall(r'(?:^|,)\s*(\w+)(?:\s+\w+)?\s*:\s*([^,=]+?)\s*(?:=[^,]*)?(?=,|$)',
                           inside)
        arguments = ','.join(
            f'{label}:{re.sub(chr(92) + "s+", "", kind)}' for label, kind in parts)
    return f'{keyword} {name}({arguments})', index


TYPE_START = re.compile(
    r'^(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(?:public|internal|private|fileprivate|open)\s+)*'
    r'(?:final\s+)?(?:struct|enum|class|actor|protocol|extension|func)\b')


def check(path: Path) -> list[str]:
    lines = path.read_text().splitlines()
    seen: dict[str, int] = {}
    problems = []
    index = 0
    while index < len(lines):
        # Un tipo — o una funzione libera — a colonna zero apre un ambito nuovo. Per i tipi
        # perché due `View` nello stesso file hanno entrambe un `var body`, ed è corretto; per le
        # funzioni perché il loro corpo sta a quattro spazi, esattamente dove stanno i membri, e
        # senza questo le variabili locali passerebbero per membri.
        if TYPE_START.match(lines[index]):
            seen = {}
        found, index = signature(lines, index)
        if found:
            if found in seen:
                problems.append(
                    f'{path}:{index + 1}: «{found}» già dichiarato alla riga {seen[found]}')
            else:
                seen[found] = index + 1
        index += 1
    return problems


def main() -> int:
    problems = []
    count = 0
    for root in (Path('Sources'), Path('Tests')):
        for path in sorted(root.rglob('*.swift')):
            count += 1
            problems.extend(check(path))

    if problems:
        for problem in problems:
            print(problem)
        print(f'\n{len(problems)} dichiarazioni ripetute in {count} file.')
        return 1

    print(f'Nessuna dichiarazione ripetuta. {count} file esaminati.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
