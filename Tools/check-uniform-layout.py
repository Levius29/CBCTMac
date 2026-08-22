#!/usr/bin/env python3
"""I blocchi di uniform devono avere la stessa sequenza di campi in Swift e in Metal.

# Il guasto, e perché non si vede

Uno `struct` di uniform esiste due volte: in Swift, per riempirlo, e in `.metal`,
per leggerlo. Sono due dichiarazioni scollegate — nessun compilatore le confronta
— e la CPU scrive byte che la GPU rilegge per posizione. Aggiungere un campo da
una parte sola, o metterlo in un ordine diverso, non dà né un errore né un
avviso: dà un'immagine sbagliata per una ragione che nel codice che disegna non
compare.

È il difetto più costoso da inseguire di tutta la grafica, perché il sintomo —
colori strani, illuminazione impazzita, niente a schermo — non somiglia alla
causa.

# La regola

Per ogni `struct <Nome>Uniforms` che esiste in entrambi i mondi, la **sequenza
dei tipi** dev'essere la stessa. I nomi si confrontano a titolo informativo: chi
li cambia da una parte sola merita comunque di saperlo.

Non si controlla il riempimento: quello lo verifica la prova sulla dimensione in
byte, che sta accanto al tipo e sa quanto deve venire.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

SWIFT_KIND = {"SIMD4<Float>": "float4", "SIMD3<Float>": "float3",
              "SIMD2<Float>": "float2", "Float": "float", "Int32": "int",
              "UInt32": "uint"}
METAL_KIND = {"float4": "float4", "float3": "float3", "float2": "float2",
              "float": "float", "int": "int", "uint": "uint"}


def metal_structs() -> dict[str, list[tuple[str, str]]]:
    found: dict[str, list[tuple[str, str]]] = {}
    for path in SOURCES.rglob("*.metal"):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"struct\s+(\w*Uniforms)\s*\{(.*?)\};", text, re.S):
            fields = []
            for kind, name in re.findall(
                r"^\s*(float4|float3|float2|float|int|uint)\s+(\w+)\s*;", match.group(2), re.M
            ):
                fields.append((METAL_KIND[kind], name))
            found[match.group(1)] = fields
    return found


def swift_structs() -> dict[str, list[tuple[str, str]]]:
    found: dict[str, list[tuple[str, str]]] = {}
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(
            r"struct\s+(\w*Uniforms)\s*\{(.*?)\n\}", text, re.S
        ):
            fields = []
            for name, kind in re.findall(
                r"^\s*var\s+(\w+)\s*:\s*(SIMD4<Float>|SIMD3<Float>|SIMD2<Float>"
                r"|Float|Int32|UInt32)\s*$",
                match.group(2), re.M
            ):
                fields.append((SWIFT_KIND[kind], name))
            if fields:
                found[match.group(1)] = fields
    return found


def main() -> int:
    metal = metal_structs()
    swift = swift_structs()
    shared = sorted(set(metal) & set(swift))
    if not shared:
        print("Nessun blocco di uniform da confrontare.")
        return 0

    problems = []
    for name in shared:
        m = metal[name]
        s = swift[name]
        if [kind for kind, _ in m] != [kind for kind, _ in s]:
            problems.append((name, m, s))

    if problems:
        print("Blocchi di uniform che non corrispondono fra Swift e Metal:\n")
        for name, m, s in problems:
            print(f"  {name}: {len(s)} campi in Swift, {len(m)} in Metal")
            for index in range(max(len(m), len(s))):
                left = f"{s[index][0]} {s[index][1]}" if index < len(s) else "—"
                right = f"{m[index][0]} {m[index][1]}" if index < len(m) else "—"
                mark = " " if left.split()[0] == right.split()[0] else "✗"
                print(f"    {mark} {left:<28} {right}")
        print(
            "\nLa CPU scrive per posizione e la GPU rilegge per posizione: una sequenza"
            "\ndiversa non dà errori, dà campi letti dal posto sbagliato."
        )
        return 1

    total = sum(len(swift[name]) for name in shared)
    print(f"{len(shared)} blocchi di uniform corrispondono ({total} campi).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
