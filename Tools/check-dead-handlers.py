#!/usr/bin/env python3
"""Trova richiami di eventi che non possono scattare.

# I due modi in cui è già successo

**Una vista che si esclude dal hit testing e poi implementa gli eventi.** `ScrollWheelCatcher`
restituiva `nil` da `hitTest` per lasciar passare i clic e sovrascriveva `scrollWheel`: AppKit
consegna rotella e pinch alla vista trovata **da hitTest** e poi ai suoi antenati, mai a un
fratello che si è chiamato fuori. Il codice c'era, era commentato con cura, e non è mai stato
eseguito. Da lì la rotella sulle sezioni trasversali e il pinch che non ingrandiva.

**Un richiamo dichiarato e mai assegnato.** Un `NSViewRepresentable` espone `var onCancel: () ->
Void`, chi lo usa lo riempie, e se manca la riga `view.onCancel = onCancel` il gesto non arriva
mai. Non è un errore di compilazione: è una proprietà che nessuno legge, e il chiamante non ha
modo di accorgersene.

Entrambi hanno lo stesso sintomo — una funzione che sembra esserci e non risponde — e nessuno dei
due lascia traccia nel compilatore.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

EVENT_OVERRIDES = {
    "scrollWheel", "magnify", "mouseDown", "mouseDragged", "mouseUp",
    "rightMouseDown", "otherMouseDown", "keyDown", "rotate",
}


def strip_noise(text):
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", "", text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def blocks(text, pattern):
    """I corpi delle dichiarazioni che corrispondono, per bilanciamento delle graffe."""
    found = []
    for match in re.finditer(pattern, text, re.M):
        depth = 0
        start = text.find("{", match.end() - 1)
        if start < 0:
            continue
        for index in range(start, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    found.append((match.group(1), text[start : index + 1],
                                  text[: match.start()].count("\n") + 1))
                    break
    return found


def main():
    problems = []
    files = 0

    for path in sorted(SOURCES.rglob("*.swift")):
        files += 1
        body = strip_noise(path.read_text(encoding="utf-8", errors="replace"))
        relative = path.relative_to(ROOT)

        # 1. Viste che si escludono dal hit testing e implementano eventi.
        for name, contents, line in blocks(
            body, r"^(?:private\s+|public\s+|final\s+)*class\s+([A-Za-z_]\w*)\s*:[^{]*NSView"
        ):
            if not re.search(r"func\s+hitTest\([^)]*\)\s*->\s*NSView\?\s*\{\s*nil\s*\}", contents):
                continue
            dead = sorted(
                {
                    event
                    for event in EVENT_OVERRIDES
                    if re.search(r"override\s+func\s+" + event + r"\b", contents)
                }
            )
            if dead:
                problems.append(
                    (relative, line,
                     f"«{name}» esce dal hit testing e sovrascrive "
                     f"{', '.join(dead)}: quegli eventi non le arriveranno mai")
                )

        # 2. Richiami dichiarati da un ponte e mai assegnati alla vista.
        for name, contents, line in blocks(
            body, r"^(?:public\s+|internal\s+)?struct\s+([A-Za-z_]\w*)\s*:[^{]*NSViewRepresentable"
        ):
            declared = set(re.findall(r"var\s+(on[A-Z]\w*)\s*:", contents))
            assigned = set(re.findall(r"\.(on[A-Z]\w*)\s*=", contents))
            # Un richiamo può anche essere consumato direttamente invece che assegnato.
            used = set(re.findall(r"\b(on[A-Z]\w*)\s*\(", contents))
            orphans = sorted(declared - assigned - used)
            for orphan in orphans:
                problems.append(
                    (relative, line,
                     f"«{name}.{orphan}» è dichiarato e mai collegato alla vista")
                )

    if not problems:
        print(f"Nessun richiamo morto. {files} file esaminati.")
        return 0

    for path, line, message in problems:
        print(f"  {path}:{line}: {message}")
    print()
    print(f"{len(problems)} da collegare o da togliere.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
