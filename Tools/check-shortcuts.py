#!/usr/bin/env python3
"""Confronta la legenda dei comandi con i tasti realmente collegati.

# Perché

Un'interfaccia che dichiara un tasto e non lo collega è peggio di una che tace: chi lo prova e
non ottiene nulla conclude che il programma è rotto, e non ha tutti i torti. È già successo due
volte in versi opposti — «Esc per annullare» scritto nei suggerimenti degli strumenti senza che
Esc fosse collegato a nulla, e tre comandi del menu (⇧⌘D, ⇧⌘M, ⇧⌘O) collegati e assenti dalla
legenda.

Il controllo guarda le due direzioni, perché entrambe fanno danno: la prima promette ciò che non
c'è, la seconda nasconde ciò che c'è.

# Che cosa confronta

Solo le voci **letterali**. Le scorciatoie degli strumenti e dei modi di lavoro sono generate da
`Tool.allCases` e `WorkMode.allCases` sia nel menu sia nella legenda: sono già impossibili da
disallineare, e includerle aggiungerebbe rumore senza coprire nulla.

`.cancelAction` e `.defaultAction` delle finestre di dialogo non compaiono in legenda di
proposito: sono Invio ed Esc dentro un dialogo, cioè una convenzione di sistema che nessuno ha
bisogno di leggere.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
LEGEND = APP / "ShortcutsSheet.swift"

SYMBOL_TO_MODIFIER = {"⌘": "command", "⇧": "shift", "⌥": "option", "⌃": "control"}
# Voci di legenda che non sono `.keyboardShortcut` ma gesti o tasti gestiti altrove.
NON_MENU_KEYS = {
    "esc": "keyCode == 53",
    # Le frecce e le pagine sono gestite in `InteractiveMetalView.keyDown`, non da SwiftUI: il
    # marcatore è il codice del tasto nello `switch`. Togliendo quel ramo il controllo scatta,
    # che è il punto — una legenda che promette le frecce e un `keyDown` che non le gestisce è
    # esattamente il caso per cui questo controllo esiste.
    "↑ ↓ ← →": "case 126, 124",
    "⇞ ⇟": "case 116",
}


def normalise(symbols):
    """«⇧⌘R» → ('r', {'command', 'shift'})."""
    modifiers = set()
    key = ""
    for character in symbols:
        if character in SYMBOL_TO_MODIFIER:
            modifiers.add(SYMBOL_TO_MODIFIER[character])
        else:
            key += character
    return key.strip().lower(), frozenset(modifiers)


def legend_entries():
    text = LEGEND.read_text(encoding="utf-8")
    found = set()
    for symbols, _ in re.findall(r'\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)', text):
        # Una voce può documentarne due — «⌘Z / ⇧⌘Z» — e vanno confrontate separatamente,
        # altrimenti la riga passa il controllo con una sola delle due collegate.
        for part in symbols.split("/"):
            key, modifiers = normalise(part)
            # Gesti del mouse e descrizioni: non sono combinazioni di tasti.
            if len(key) > 3 and key not in NON_MENU_KEYS:
                continue
            if not key:
                continue
            found.add((key, modifiers))
    return found


def wired_shortcuts():
    found = set()
    for path in APP.glob("*.swift"):
        if path == LEGEND:
            continue
        text = path.read_text(encoding="utf-8")
        for key, modifiers in re.findall(
            r'\.keyboardShortcut\(\s*"([^"]+)"\s*,\s*modifiers:\s*([^)]*)\)', text
        ):
            names = frozenset(re.findall(r"\.(\w+)", modifiers))
            found.add((key.lower(), names))
        if ".keyboardShortcut(.delete" in text:
            found.add(("⌫", frozenset()))
        for special, marker in NON_MENU_KEYS.items():
            if marker in text:
                found.add((special, frozenset()))
    return found


def describe(entry):
    key, modifiers = entry
    order = ["control", "option", "shift", "command"]
    symbols = "".join(
        symbol for symbol, name in SYMBOL_TO_MODIFIER.items() if name in modifiers
    )
    symbols = "".join(
        s for name in order for s, n in SYMBOL_TO_MODIFIER.items() if n == name and n in modifiers
    )
    return f"{symbols}{key.upper()}"


def main():
    legend = legend_entries()
    wired = wired_shortcuts()

    promised = sorted(legend - wired, key=describe)
    hidden = sorted(wired - legend, key=describe)

    if not promised and not hidden:
        print(f"Legenda e tasti coincidono. {len(legend)} combinazioni letterali.")
        return 0

    for entry in promised:
        print(f"  {describe(entry)}: in legenda ma non collegato a nulla.")
    for entry in hidden:
        print(f"  {describe(entry)}: collegato ma assente dalla legenda.")
    print()
    print(f"{len(promised) + len(hidden)} da allineare.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
