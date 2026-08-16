#!/usr/bin/env python3
"""
Verifica indipendente di una serie DICOM di fantoccio.

Rilegge i file prodotti da `make_phantom.py` con un parser scritto da zero, ricostruisce il
volume e misura le strutture note. Serve a due cose distinte:

1. **Controllare il generatore.** Se scrittura e lettura sono la stessa implementazione, un
   malinteso sul formato si annulla da solo e resta invisibile. Qui il parser e' separato.

2. **Fornire i numeri di riferimento all'applicazione Swift.** Questo script implementa la
   stessa catena — ordinamento per proiezione sulla normale, matrice voxel→Patient, misure in
   millimetri — descritta nei Contratti 1 e 2 di docs/architecture.md. Se Swift e Python
   danno risultati diversi sullo stesso fantoccio, uno dei due sbaglia, e il confronto dice
   subito dove guardare.

Uso:
    python3 verify_phantom.py ./phantom
"""

import os
import struct
import sys

LONG_FORM_VR = {"OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT", "SV", "UV"}


# --------------------------------------------------------------------------------------
# Parser minimo, Explicit VR Little Endian
# --------------------------------------------------------------------------------------


def parse_dicom(path):
    """Restituisce (dizionario di elementi, byte dei pixel)."""
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 132 or data[128:132] != b"DICM":
        raise ValueError(f"{os.path.basename(path)}: manca il magic DICM")

    elements = {}
    pixel_data = None
    offset = 132

    while offset + 8 <= len(data):
        group, element = struct.unpack_from("<HH", data, offset)
        vr = data[offset + 4 : offset + 6].decode("ascii", errors="replace")
        offset += 6

        if vr in LONG_FORM_VR:
            if offset + 6 > len(data):
                break
            (length,) = struct.unpack_from("<I", data, offset + 2)
            offset += 6
        else:
            if offset + 2 > len(data):
                break
            (length,) = struct.unpack_from("<H", data, offset)
            offset += 2

        if length == 0xFFFFFFFF:
            raise ValueError(
                f"{os.path.basename(path)}: lunghezza indefinita non prevista nel fantoccio"
            )
        if offset + length > len(data):
            raise ValueError(f"{os.path.basename(path)}: file troncato a offset {offset}")

        value = data[offset : offset + length]
        offset += length

        if (group, element) == (0x7FE0, 0x0010):
            pixel_data = value
        else:
            elements[(group, element)] = (vr, value)

    return elements, pixel_data


def text(elements, tag, default=""):
    if tag not in elements:
        return default
    return elements[tag][1].decode("ascii", errors="replace").strip("\x00 ")


def numbers(elements, tag):
    """Valori numerici, sia testuali (DS/IS) sia binari (US/SS/UL/SL)."""
    if tag not in elements:
        return []
    vr, raw = elements[tag]
    if vr in ("DS", "IS"):
        s = raw.decode("ascii", errors="replace").strip("\x00 ")
        return [float(p) for p in s.split("\\") if p.strip()]
    if vr == "US":
        return [float(v) for v in struct.unpack(f"<{len(raw) // 2}H", raw)]
    if vr == "SS":
        return [float(v) for v in struct.unpack(f"<{len(raw) // 2}h", raw)]
    if vr == "UL":
        return [float(v) for v in struct.unpack(f"<{len(raw) // 4}I", raw)]
    if vr == "SL":
        return [float(v) for v in struct.unpack(f"<{len(raw) // 4}i", raw)]
    return []


def one(elements, tag, default=None):
    values = numbers(elements, tag)
    return values[0] if values else default


# --------------------------------------------------------------------------------------
# Ricostruzione del volume
# --------------------------------------------------------------------------------------


def cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def load_series(directory):
    paths = sorted(
        os.path.join(directory, name)
        for name in os.listdir(directory)
        if name.lower().endswith(".dcm")
    )
    if not paths:
        raise SystemExit(f"Nessun file .dcm in {directory}")

    slices = []
    for path in paths:
        elements, pixels = parse_dicom(path)
        position = numbers(elements, (0x0020, 0x0032))
        orientation = numbers(elements, (0x0020, 0x0037))
        if len(position) < 3 or len(orientation) < 6:
            raise SystemExit(f"{os.path.basename(path)}: geometria mancante")
        slices.append(
            {
                "path": path,
                "elements": elements,
                "pixels": pixels,
                "position": tuple(position[:3]),
                "orientation": tuple(orientation[:6]),
            }
        )

    first = slices[0]["elements"]
    columns = int(one(first, (0x0028, 0x0011), 0))
    rows = int(one(first, (0x0028, 0x0010), 0))
    pixel_spacing = numbers(first, (0x0028, 0x0030))
    bits_stored = int(one(first, (0x0028, 0x0101), 16))
    is_signed = int(one(first, (0x0028, 0x0103), 0)) == 1
    intercept = one(first, (0x0028, 0x1052), 0.0)
    slope = one(first, (0x0028, 0x1053), 1.0)

    if len(pixel_spacing) < 2:
        raise SystemExit("PixelSpacing mancante")
    # PixelSpacing e' [righe, colonne]: la prima e' la verticale.
    row_spacing, column_spacing = pixel_spacing[0], pixel_spacing[1]

    # Contratto 2: si ordina per proiezione sulla normale, mai per InstanceNumber.
    o = slices[0]["orientation"]
    normal = cross(o[0:3], o[3:6])
    for s in slices:
        s["d"] = dot(s["position"], normal)
    slices.sort(key=lambda s: s["d"])

    if len(slices) >= 2:
        span = slices[-1]["d"] - slices[0]["d"]
        slice_spacing = span / (len(slices) - 1)
    else:
        slice_spacing = float(one(first, (0x0018, 0x0050), 1.0))

    # Uniformita' della spaziatura.
    max_deviation = 0.0
    for n in range(len(slices) - 1):
        step = slices[n + 1]["d"] - slices[n]["d"]
        max_deviation = max(max_deviation, abs(step - slice_spacing))

    mask = (1 << bits_stored) - 1
    sign_bit = 1 << (bits_stored - 1)

    volume = []
    for s in slices:
        raw = s["pixels"]
        count = columns * rows
        values = struct.unpack(f"<{count}H", raw[: count * 2])
        if is_signed:
            values = [(v & mask) - (sign_bit << 1) if (v & sign_bit) else (v & mask) for v in values]
        else:
            values = [v & mask for v in values]
        volume.append(values)

    return {
        "volume": volume,
        "columns": columns,
        "rows": rows,
        "slices": len(slices),
        "spacing": (column_spacing, row_spacing, slice_spacing),
        "origin": slices[0]["position"],
        "orientation": o,
        "intercept": intercept,
        "slope": slope,
        "max_spacing_deviation": max_deviation,
        "bits_stored": bits_stored,
        "is_signed": is_signed,
    }


def density(v, series):
    return v * series["slope"] + series["intercept"]


# --------------------------------------------------------------------------------------
# Misure
# --------------------------------------------------------------------------------------


def mm_to_index(series, mm, axis):
    """Millimetri Patient → indice voxel frazionario lungo un asse."""
    return (mm - series["origin"][axis]) / series["spacing"][axis]


def index_to_mm(series, index, axis):
    return series["origin"][axis] + index * series["spacing"][axis]


def voxel(series, i, j, k):
    return series["volume"][k][j * series["columns"] + i]


def measure_cube_edge(series, axis, threshold_density=1000.0, window_mm=14.0):
    """
    Spigolo del cubo lungo un asse, misurato sulla slice centrale.

    La finestra di ±14 mm attorno all'origine e' necessaria per isolare il cubo: le sfere di
    smalto stanno a 18 mm dall'asse e superano abbondantemente la soglia, quindi una misura
    sull'intero volume restituirebbe l'ingombro complessivo del fantoccio e non lo spigolo.
    Le lastrine invece non compaiono, perche' stanno a z = −22 mm.

    L'estensione si misura da bordo **esterno** a bordo esterno dei voxel occupati, cioe'
    `(hi − lo + 1) · passo`. Usare `(hi − lo)` sottrarrebbe un voxel intero: su un cubo da
    20 mm campionato a 0,5 mm si leggerebbe 19,50 — un errore sistematico piccolo, coerente e
    del tutto invisibile senza un riferimento noto. E' precisamente cio' che il fantoccio
    serve a scoprire.
    """
    threshold_raw = (threshold_density - series["intercept"]) / series["slope"]
    columns, rows, slices = series["columns"], series["rows"], series["slices"]

    k = int(round(mm_to_index(series, 0.0, 2)))
    if not (0 <= k < slices):
        return None

    i_lo = max(0, int(mm_to_index(series, -window_mm, 0)))
    i_hi = min(columns - 1, int(mm_to_index(series, window_mm, 0)))
    j_lo = max(0, int(mm_to_index(series, -window_mm, 1)))
    j_hi = min(rows - 1, int(mm_to_index(series, window_mm, 1)))

    lo, hi = None, None
    for j in range(j_lo, j_hi + 1):
        for i in range(i_lo, i_hi + 1):
            if voxel(series, i, j, k) < threshold_raw:
                continue
            index = i if axis == 0 else j
            if lo is None or index < lo:
                lo = index
            if hi is None or index > hi:
                hi = index

    if lo is None:
        return None
    return (hi - lo + 1) * series["spacing"][axis]


def measure_plate_gap(series, threshold_density=1000.0):
    """
    Intercapedine d'aria fra le due lastrine, lungo l'asse delle slice.

    E' la misura che conta di piu': l'asse `k` e' l'unico il cui passo non viene letto da un
    tag ma **calcolato** dalle posizioni delle slice. Un errore nell'ordinamento o nel calcolo
    della spaziatura si manifesta qui e in nessun altro posto.
    """
    threshold_raw = (threshold_density - series["intercept"]) / series["slope"]
    slices = series["slices"]

    i = int(round(mm_to_index(series, 0.0, 0)))
    j = int(round(mm_to_index(series, 0.0, 1)))
    if not (0 <= i < series["columns"] and 0 <= j < series["rows"]):
        return None

    # Colonna di voxel lungo z: si cercano i due blocchi densi e si misura il vuoto fra loro.
    dense = [k for k in range(slices) if voxel(series, i, j, k) >= threshold_raw]
    if not dense:
        return None

    # Le lastrine stanno nella meta' inferiore; il cubo occupa il centro. Si prendono solo i
    # voxel densi sotto z = −14 mm, dove c'e' soltanto la coppia di lastrine.
    limit = mm_to_index(series, -14.0, 2)
    plate_voxels = sorted(k for k in dense if k < limit)
    if len(plate_voxels) < 2:
        # Le lastrine stanno a z ≈ −20 mm: su un volume troppo basso semplicemente non ci
        # sono. Non e' un errore di misura, e va distinto da un fallimento vero.
        return "assenti"

    # Il vuoto piu' ampio fra indici consecutivi e' l'intercapedine.
    best_gap = 0
    for n in range(len(plate_voxels) - 1):
        gap = plate_voxels[n + 1] - plate_voxels[n] - 1
        best_gap = max(best_gap, gap)

    return best_gap * series["spacing"][2]


def sample_density(series, center_mm, radius_mm):
    """Densita' media in una sfera centrata su un punto in mm."""
    columns, rows, slices = series["columns"], series["rows"], series["slices"]
    total, count = 0.0, 0

    i0 = max(0, int(mm_to_index(series, center_mm[0] - radius_mm, 0)))
    i1 = min(columns - 1, int(mm_to_index(series, center_mm[0] + radius_mm, 0)) + 1)
    j0 = max(0, int(mm_to_index(series, center_mm[1] - radius_mm, 1)))
    j1 = min(rows - 1, int(mm_to_index(series, center_mm[1] + radius_mm, 1)) + 1)
    k0 = max(0, int(mm_to_index(series, center_mm[2] - radius_mm, 2)))
    k1 = min(slices - 1, int(mm_to_index(series, center_mm[2] + radius_mm, 2)) + 1)

    for k in range(k0, k1 + 1):
        z = index_to_mm(series, k, 2)
        for j in range(j0, j1 + 1):
            y = index_to_mm(series, j, 1)
            for i in range(i0, i1 + 1):
                x = index_to_mm(series, i, 0)
                dx, dy, dz = x - center_mm[0], y - center_mm[1], z - center_mm[2]
                if dx * dx + dy * dy + dz * dz > radius_mm * radius_mm:
                    continue
                total += density(voxel(series, i, j, k), series)
                count += 1

    return total / count if count else None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(1)

    directory = sys.argv[1]
    print(f"Lettura di {directory} …")
    series = load_series(directory)

    sx, sy, sz = series["spacing"]
    print("\n── Geometria ──────────────────────────────────────────")
    print(f"  Dimensioni ......... {series['columns']}×{series['rows']}×{series['slices']} voxel")
    print(f"  Spaziatura ......... {sx:.4f} × {sy:.4f} × {sz:.4f} mm")
    print(f"  Origine ............ {series['origin']}")
    print(f"  Orientamento ....... {series['orientation']}")
    print(f"  Rescale ............ slope {series['slope']}, intercept {series['intercept']}")
    print(f"  BitsStored ......... {series['bits_stored']}, con segno: {series['is_signed']}")
    print(f"  Deviazione passo ... {series['max_spacing_deviation']:.6f} mm")

    print("\n── Misure ─────────────────────────────────────────────")
    failures = []

    def check(label, measured, expected, tolerance):
        if measured == "assenti":
            print(
                f"  – {label:.<34} struttura fuori dal volume, controllo saltato"
            )
            return
        if measured is None:
            print(f"  ✗ {label:.<34} non misurabile")
            failures.append(label)
            return
        delta = abs(measured - expected)
        ok = delta <= tolerance
        mark = "✓" if ok else "✗"
        print(
            f"  {mark} {label:.<34} {measured:8.3f}   atteso {expected:7.2f}"
            f"   Δ {delta:.3f}"
        )
        if not ok:
            failures.append(label)

    # La tolleranza e' un voxel: il campionamento non puo' risolvere meglio del proprio passo,
    # e pretendere di piu' significherebbe scrivere un test che fallisce per costruzione.
    check("Spigolo del cubo, X", measure_cube_edge(series, 0), 20.0, sx)
    check("Spigolo del cubo, Y", measure_cube_edge(series, 1), 20.0, sy)
    check("Intercapedine lastrine, Z", measure_plate_gap(series), 10.0, sz)

    check("Densità del cubo", sample_density(series, (0.0, 0.0, 0.0), 5.0), 1200.0, 1.0)
    check(
        "Densità sfera Ø10 (spongiosa)",
        sample_density(series, (-18.0, 0.0, 0.0), 3.0),
        400.0,
        1.0,
    )
    check(
        "Densità sfera Ø6 (smalto)",
        sample_density(series, (18.0, -10.0, 0.0), 2.0),
        2800.0,
        1.0,
    )
    check(
        "Densità sfera Ø4 (tessuto molle)",
        sample_density(series, (18.0, 10.0, 0.0), 1.2),
        60.0,
        1.0,
    )

    if series["max_spacing_deviation"] > 0.01:
        print(
            f"\n  ⚠ Spaziatura non uniforme: deviazione "
            f"{series['max_spacing_deviation']:.4f} mm"
        )
        failures.append("uniformità della spaziatura")

    if failures:
        print(f"\n✗ {len(failures)} controlli falliti: {', '.join(failures)}")
        raise SystemExit(1)

    print("\n✓ Tutti i controlli superati. La serie è coerente e utilizzabile.")
    print("  Questi sono i numeri che l'applicazione Swift deve riprodurre sullo stesso")
    print("  fantoccio. Uno scarto significa un errore nella catena delle coordinate.")


if __name__ == "__main__":
    main()
