#!/usr/bin/env python3
"""Lo stato di sola visualizzazione non deve finire nel piano né in archivio.

# La distinzione, e perché va sorvegliata

Ci sono due specie di stato. Quello del **piano** — impianti, denti, nervi,
misure — descrive decisioni cliniche: si annulla, si salva, si riapre uguale.
Quello di **vista** — inquadratura, finestra di densità, riquadro di lettura —
descrive come si sta guardando adesso: non c'è niente da annullare, perché
niente è cambiato.

Confonderli in una direzione è fastidioso; nell'altra è un difetto vero. Il
riquadro di lettura esiste proprio perché il ritaglio distruttivo alterava
l'esame: se finisse nell'istantanea del piano o nel documento salvato, riaprire
un caso mostrerebbe mezzo cranio invisibile senza dire perché — cioè
esattamente il difetto che quella funzione è stata scritta per non avere.

# La regola

I nomi elencati qui sotto non devono comparire in `PlanSnapshot`, nel documento
di progetto, né nel codice che archivia. Il controllo è per nome ed è
volutamente grossolano: non gli serve capire il codice, gli serve accorgersi che
qualcuno ha aggiunto una riga.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"

# Stato che vive quanto la sessione e non oltre.
VIEW_ONLY = ["clipBox"]

# Dove non deve comparire.
FORBIDDEN = ["ProjectDocument.swift"]


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))


def main() -> int:
    findings = []

    for name in FORBIDDEN:
        path = APP / name
        if not path.exists():
            continue
        body = strip_comments(path.read_text(encoding="utf-8"))
        for state in VIEW_ONLY:
            if re.search(rf"\b{state}\b", body):
                findings.append(f"{name}: contiene «{state}», che è stato di sola vista")

    # E dentro la dichiarazione di `PlanSnapshot`, che è ciò che l'annulla ripristina.
    model = APP / "AppModel.swift"
    if model.exists():
        body = strip_comments(model.read_text(encoding="utf-8"))
        match = re.search(r"struct PlanSnapshot[^{]*\{(.*?)\n    \}", body, re.S)
        if match:
            for state in VIEW_ONLY:
                if re.search(rf"\b{state}\b", match.group(1)):
                    findings.append(
                        f"AppModel.PlanSnapshot: contiene «{state}», che non è del piano")

    if findings:
        print("Stato di sola vista finito dove si salva:\n")
        for finding in findings:
            print(f"  {finding}")
        print(
            "\nÈ la differenza fra guardare una parte e modificare l'esame. Se davvero deve"
            "\npersistere, toglilo dall'elenco in questo controllo e scrivi perché."
        )
        return 1

    print(f"Lo stato di sola vista ({', '.join(VIEW_ONLY)}) non finisce in nessun salvataggio.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
