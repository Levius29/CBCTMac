#!/usr/bin/env python3
"""Cerca tipi pubblici con lo stesso nome in moduli diversi.

# Perché esiste

Due tipi pubblici omonimi in due moduli non danno errore finché nessuno importa entrambi. Poi
qualcuno lo fa, e il file smette di compilare con un messaggio — «ambiguous for type lookup» —
che non nomina il modulo colpevole. Su questo progetto è successo due volte: `WindowLevel` contro
quello di SwiftUI, che ha prodotto novantuno errori a cascata da una riga sola, e
`VolumeProvenance` fra ArtifactKit e StudyKit.

Nessuno dei due si vedeva finché non si aggiungeva l'import. Questo controllo li vede prima,
quando la collisione **nasce** invece che quando esplode.

# Perché anche i nomi di SwiftUI e AppKit

Perché la collisione peggiore non è fra due nostri moduli — quella la si risolve rinominando ciò
che si preferisce — ma con un tipo del sistema. Lì la cascata è la stessa e la causa è ancora meno
evidente, perché il nome «esterno» non compare in nessun nostro file.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

DECL = re.compile(
    r'^public\s+(?:final\s+)?(?:struct|enum|class|actor|protocol)\s+([A-Za-z_]\w*)')

# Nomi del sistema con cui una collisione è già costata cara, o costerebbe.
FRAMEWORK_NAMES = {
    'WindowLevel', 'View', 'Image', 'Path', 'Shape', 'Text', 'Color', 'Font', 'Group',
    'Label', 'Button', 'Picker', 'Slider', 'Toggle', 'Menu', 'List', 'Table', 'Section',
    'State', 'Binding', 'Environment', 'Transaction', 'Animation', 'Gradient', 'Angle',
    'Alignment', 'Edge', 'Axis', 'Spacer', 'Divider', 'Canvas', 'Point', 'Size', 'Rect',
}


def main() -> int:
    owners: dict[str, list[str]] = defaultdict(list)
    for path in sorted(Path('Sources').rglob('*.swift')):
        module = path.parts[1]
        for line in path.read_text().splitlines():
            match = DECL.match(line)
            if match:
                owners[match.group(1)].append(f'{module} ({path.name})')

    problems = []
    for name, places in sorted(owners.items()):
        modules = {place.split(' ')[0] for place in places}
        if len(modules) > 1:
            problems.append(f'«{name}» dichiarato in più moduli: ' + ', '.join(sorted(places)))
        if name in FRAMEWORK_NAMES:
            problems.append(
                f'«{name}» collide con un tipo di SwiftUI o AppKit: ' + ', '.join(places))

    if problems:
        for problem in problems:
            print(problem)
        print(f'\n{len(problems)} collisioni fra {len(owners)} tipi pubblici.')
        return 1

    print(f'Nessuna collisione. {len(owners)} tipi pubblici in {len(set(p.parts[1] for p in Path("Sources").rglob("*.swift")))} moduli.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
