#!/usr/bin/env python3
"""Una sola strada per le finestre modali.

# Il guasto

L'applicazione aveva nove finestre modali e nove booleani indipendenti, ciascuno
con il proprio `.sheet(isPresented:)` impilato sulla stessa vista. SwiftUI ne
presenta **una** per volta: la seconda richiesta veniva lasciata cadere e il suo
interruttore restava acceso. Da lì in poi quel comando era morto — rimettere a
`true` un valore già `true` non presenta niente — e la voce di menu rispondeva
per sempre con il silenzio.

Non è un caso di laboratorio: `offerToArchive()` accende la domanda «lo
archivio?» nell'istante in cui il pannello dell'archivio si sta chiudendo. È il
difetto che si descrive con «se apro una cosa, poi non posso più aprirne altre»,
e non lascia traccia: nessun errore, nessun avviso, solo un comando che smette
di funzionare.

# Che cosa pretende questo controllo

1. Nessun `.sheet(isPresented:)` nell'applicazione: la presentazione passa da
   `activeSheet`, che è un valore solo e non nove interruttori.
2. Un solo `.sheet(item:)`, su `activeSheet`, con `onDismiss` che promuove la
   richiesta rimasta in coda — senza, una modale chiesta a schermo occupato
   sparirebbe come prima.
3. Ogni `SheetRoute` dichiarata ha una facciata booleana nel modello, almeno un
   comando che la apre, e un ramo che la disegna. Una modale dichiarata e mai
   presentata è l'altra metà dello stesso difetto.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "CBCTMacApp"
MODEL_FILE = APP / "AppModel.swift"
CONTENT_VIEW = APP / "ContentView.swift"
ROUTER_FILE = ROOT / "Sources" / "StudyKit" / "ModalRouter.swift"

CASE = re.compile(r"^\s{4}case\s+(\w+)\s*$")
FACADE = re.compile(r"sheets\.setPresented\(\.(\w+),")
OPENS = re.compile(r"\.?\b(\w+)\s*=\s*true\b")


def routes() -> list[str]:
    """I casi di `SheetRoute`, nell'ordine in cui sono dichiarati."""
    text = ROUTER_FILE.read_text(encoding="utf-8")
    start = text.index("public enum SheetRoute")
    end = text.index("public struct ModalRouter")
    return [m.group(1) for line in text[start:end].splitlines() if (m := CASE.match(line))]


def main() -> int:
    problems: list[str] = []

    known = routes()
    if not known:
        print("Nessuna SheetRoute dichiarata: il controllo non ha nulla da verificare.")
        return 1

    # 1. Nessun `.sheet(isPresented:)` in giro.
    for path in sorted(APP.glob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if ".sheet(isPresented:" in line and not line.lstrip().startswith("//"):
                problems.append(
                    f"{path.name}:{number}: `.sheet(isPresented:)`. Le modali passano da "
                    "`activeSheet`: due presentazioni impilate se ne perdono una, e "
                    "l'interruttore resta acceso a vuoto.")

    # 2. Un solo presentatore, e la coda che si svuota.
    presenters = [
        (path.name, number, line)
        for path in sorted(APP.glob("*.swift"))
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
        if ".sheet(item:" in line and not line.lstrip().startswith("//")
    ]
    if len(presenters) != 1:
        where = ", ".join(f"{name}:{number}" for name, number, _ in presenters) or "nessuno"
        problems.append(
            f"Presentatori di modali trovati: {where}. Ne serve esattamente uno.")
    else:
        name, number, line = presenters[0]
        if "activeSheet" not in line:
            problems.append(
                f"{name}:{number}: il `.sheet(item:)` non è guidato da `activeSheet`.")
        if "onDismiss" not in line or "presentQueuedSheet" not in line:
            problems.append(
                f"{name}:{number}: manca `onDismiss: {{ model.presentQueuedSheet() }}`. "
                "Senza, una modale chiesta mentre un'altra era aperta resta in coda per sempre.")

    # 3. Ogni rotta ha una facciata, un comando che la apre e un ramo che la disegna.
    model_text = MODEL_FILE.read_text(encoding="utf-8")
    facades: dict[str, list[str]] = {}
    for block in re.finditer(
        r"\n    var (\w+): Bool \{(.{0,400}?)\n    \}", model_text, re.DOTALL
    ):
        name, body = block.group(1), block.group(2)
        for route in FACADE.findall(body):
            facades.setdefault(route, []).append(name)

    app_text = "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(APP.glob("*.swift")))
    opened = set(OPENS.findall(app_text))
    drawn = CONTENT_VIEW.read_text(encoding="utf-8")

    for route in known:
        names = facades.get(route, [])
        if not names:
            problems.append(
                f"SheetRoute.{route}: nessuna facciata booleana nel modello. "
                "Nessun comando può chiederla.")
            continue
        if not any(name in opened for name in names):
            problems.append(
                f"SheetRoute.{route}: nessun comando la apre "
                f"(cercato `{names[0]} = true`).")
        if f"case .{route}:" not in drawn:
            problems.append(
                f"SheetRoute.{route}: nessun ramo la disegna in {CONTENT_VIEW.name}.")

    if problems:
        print("Strade delle finestre modali:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        f"Una sola strada per le modali: {len(known)} rotte, "
        f"ciascuna con il suo comando e il suo ramo.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
