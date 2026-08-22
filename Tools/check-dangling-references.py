#!/usr/bin/env python3
"""Trova i riferimenti a oggetti del piano che possono restare appesi.

# Il guasto, tre volte

Un identificatore conservato nel modello punta a un oggetto di una raccolta:
l'impianto scelto, il canale in tracciamento, il punto d'arcata selezionato.
L'oggetto può sparire per vie che non si ricordano tutte — `deleteObject`,
`deleteObjects(of:)`, il caricamento di un piano, l'apertura di un altro esame,
e soprattutto **l'annulla**, che ripristina un'istantanea senza toccare gli
identificatori perché nell'istantanea non ci sono.

Appeso, l'identificatore non dà un errore: dà il **silenzio**. La proprietà che
lo risolve restituisce `nil`, e i comandi che ne dipendono smettono di fare
qualcosa senza dirlo. Su `tracingNerveID` questo uccideva lo strumento nervo per
il resto della sessione: dopo un ⌘Z ogni clic usciva da una guardia e non
posava niente. Sulle selezioni è più quieto — l'ispettore si svuota, «elimina
l'impianto scelto» non elimina — ma è lo stesso guasto, e arriva sempre subito
dopo uno sbaglio, che è quando serve che le cose funzionino.

# La regola

Un identificatore del genere non si ripulisce a ogni cancellazione: si
**verifica in lettura**. Verificato in lettura vale per tutte le vie, comprese
quelle che verranno, e non c'è niente da ricordarsi di aggiornare.

In pratica: la proprietà è calcolata, con un getter che controlla che l'oggetto
esista ancora, e uno spazio privato `…Storage` dietro. Se è invece una
proprietà **immagazzinata**, nessuno la verifica.

L'esenzione — un identificatore che non punta a una raccolta del modello, per
esempio la chiave di un esame in archivio — si scrive sopra la dichiarazione:

    // senza-verifica: <motivo>
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"

# `var qualcosaID: UUID?` oppure `var qualcosaIndex: Int?`, non privata.
REFERENCE = re.compile(
    r"^\s*(?:private\(set\)\s+)?var\s+(\w+(?:ID|Index))\s*:\s*(?:UUID|Int)\?\s*(\{?)\s*$"
)
EXEMPT = re.compile(r"//\s*senza-verifica:\s*(.+)")


def main() -> int:
    findings = []
    for path in sorted(APP.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, start=1):
            match = REFERENCE.match(line)
            if not match:
                continue
            # Con la graffa è calcolata: il getter è il posto in cui si verifica.
            if match.group(2) == "{":
                continue
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
            if not exempt:
                findings.append((path.relative_to(ROOT), number, match.group(1)))

    if findings:
        print("Riferimenti immagazzinati che nessuno verifica:\n")
        for path, number, name in findings:
            print(f"  {path}:{number}  {name}")
        print(
            "\nRendila calcolata, con un getter che controlla che l'oggetto esista ancora"
            "\ne uno spazio privato dietro. Oppure, se non punta a una raccolta del modello,"
            "\nscrivi sopra la dichiarazione:  // senza-verifica: <motivo>"
        )
        return 1

    print("Nessun riferimento appeso possibile.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
