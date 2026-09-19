#!/usr/bin/env python3
"""Dice se una CBCT passerà l'importatore di OpenMRI, prima di provarci.

# Perché esiste

L'importatore di `web/` accetta soltanto le serie con `Modality` `MR` o `CT`, a un campione per
pixel, tridimensionali e sotto un tetto di voxel. Una CBCT dentale quasi sempre le rispetta —
ma quando non le rispetta lo si scopre alla fine di un'importazione lunga, con un messaggio che
dice «No volumetric MR/CT DICOM or NIfTI files found» e non dice **perché**.

Questo controllo legge le sole intestazioni e risponde in pochi secondi, sulla cartella o
direttamente sullo ZIP che si sta per importare. Non ha dipendenze: né pydicom, né numpy, né
l'ambiente Python di OpenMRI. Gira con il `python3` che c'è.

    python3 Tools/inspect-dicom.py /percorso/della/cartella
    python3 Tools/inspect-dicom.py esame.zip

Esce con stato 1 se almeno una serie verrebbe rifiutata, così si può mettere in uno script.
"""

import sys
import zipfile
from collections import defaultdict
from pathlib import Path

# I limiti veri dell'importatore, letti da web/scripts/import_mri.py.
ACCEPTED_MODALITIES = ("MR", "CT")
MAXIMUM_VOXELS = 512**3 * 2
MAXIMUM_ARCHIVE_BYTES = 2 * 1024**3
MAXIMUM_EXTRACTED_BYTES = 12 * 1024**3
MAXIMUM_FILES = 60_000

IMPLICIT_LITTLE = "1.2.840.10008.1.2"
EXPLICIT_BIG = "1.2.840.10008.1.2.2"

# Le sole etichette che servono a decidere. Tutto il resto del dataset si salta.
TAGS = {
    (0x0002, 0x0010): "transferSyntax",
    (0x0008, 0x0008): "imageType",
    (0x0008, 0x0060): "modality",
    (0x0010, 0x0010): "patientName",
    (0x0010, 0x0020): "patientID",
    (0x0018, 0x0050): "sliceThickness",
    (0x0020, 0x000D): "studyUID",
    (0x0020, 0x000E): "seriesUID",
    (0x0020, 0x0037): "orientation",
    (0x0028, 0x0002): "samplesPerPixel",
    (0x0028, 0x0008): "frames",
    (0x0028, 0x0010): "rows",
    (0x0028, 0x0011): "columns",
    (0x0028, 0x0030): "pixelSpacing",
    (0x0008, 0x103E): "seriesDescription",
}

# I VR a lunghezza estesa: due byte riservati e poi quattro di lunghezza.
LONG_VALUE_REPRESENTATIONS = {b"OB", b"OW", b"OF", b"SQ", b"UT", b"UN"}


def number(data, big):
    """Un intero senza segno, dai byte di un elemento US."""
    if not data:
        return None
    return int.from_bytes(data[:2], "big" if big else "little")


def text(data):
    """Il testo di un elemento, senza il riempimento che il formato impone."""
    if data is None:
        return ""
    return data.decode("latin-1").strip().strip("\x00").strip()


def read_elements(buffer, position, explicit, big, until_group=None):
    """Legge gli elementi in sequenza e restituisce quelli che interessano.

    Si ferma al primo elemento che non sta nel pezzo di file letto, oppure quando il gruppo
    cambia rispetto a `until_group`: i dati dei pixel non si toccano mai.
    """
    order = "big" if big else "little"
    found = {}
    while position + 8 <= len(buffer):
        group = int.from_bytes(buffer[position:position + 2], order)
        element = int.from_bytes(buffer[position + 2:position + 4], order)
        if until_group is not None and group != until_group:
            break
        if (group, element) == (0x7FE0, 0x0010):
            break
        position += 4

        if explicit:
            representation = buffer[position:position + 2]
            if representation in LONG_VALUE_REPRESENTATIONS:
                length = int.from_bytes(buffer[position + 4:position + 8], order)
                position += 8
            else:
                length = int.from_bytes(buffer[position + 2:position + 4], order)
                position += 4
        else:
            representation = b""
            length = int.from_bytes(buffer[position:position + 4], order)
            position += 4

        # Lunghezza indefinita: è una sequenza, e si salta fino al suo delimitatore invece di
        # provare a interpretarla. Le etichette che servono qui stanno tutte fuori dalle sequenze.
        if length == 0xFFFFFFFF:
            end = buffer.find(b"\xfe\xff\xdd\xe0", position)
            if end < 0:
                break
            position = end + 8
            continue

        if position + length > len(buffer):
            break
        name = TAGS.get((group, element))
        if name:
            found[name] = buffer[position:position + length]
        position += length
    return position, found


def read_header(data):
    """Le intestazioni di un file DICOM, o `None` se non è un file DICOM."""
    if len(data) < 140:
        return None

    values = {}
    if data[128:132] == b"DICM":
        position, meta = read_elements(data, 132, explicit=True, big=False, until_group=0x0002)
        syntax = text(meta.get("transferSyntax")) or IMPLICIT_LITTLE
    else:
        # Senza preambolo resta la sintassi implicita, che è come i vecchi apparecchi scrivono
        # i file dentro una DICOMDIR.
        position, syntax = 0, IMPLICIT_LITTLE

    explicit = syntax != IMPLICIT_LITTLE
    big = syntax == EXPLICIT_BIG
    _, dataset = read_elements(data, position, explicit=explicit, big=big)
    if "seriesUID" not in dataset and "modality" not in dataset:
        return None

    values["transferSyntax"] = syntax
    values["modality"] = text(dataset.get("modality"))
    values["seriesUID"] = text(dataset.get("seriesUID"))
    values["studyUID"] = text(dataset.get("studyUID"))
    values["patient"] = text(dataset.get("patientID")) or text(dataset.get("patientName"))
    values["description"] = text(dataset.get("seriesDescription"))
    values["imageType"] = text(dataset.get("imageType")).replace("\\", " · ")
    values["rows"] = number(dataset.get("rows"), big)
    values["columns"] = number(dataset.get("columns"), big)
    values["samplesPerPixel"] = number(dataset.get("samplesPerPixel"), big) or 1
    frames = text(dataset.get("frames"))
    values["frames"] = int(frames) if frames.isdigit() else 1
    values["spacing"] = text(dataset.get("pixelSpacing")).replace("\\", " × ")
    values["thickness"] = text(dataset.get("sliceThickness"))
    values["orientation"] = text(dataset.get("orientation"))
    return values


def collect(target):
    """Le intestazioni di ogni file, da una cartella o direttamente da uno ZIP."""
    headers = []
    total_bytes = 0
    file_count = 0

    if target.is_file() and target.suffix.lower() == ".zip":
        with zipfile.ZipFile(target) as archive:
            for entry in archive.infolist():
                if entry.is_dir() or "__MACOSX" in entry.filename:
                    continue
                file_count += 1
                total_bytes += entry.file_size
                if entry.filename.lower().endswith((".nii", ".nii.gz")):
                    headers.append({"nifti": entry.filename})
                    continue
                with archive.open(entry) as handle:
                    header = read_header(handle.read(262_144))
                if header:
                    headers.append(header)
        return headers, file_count, total_bytes, target.stat().st_size

    for path in sorted(target.rglob("*")):
        if not path.is_file() or "__MACOSX" in path.parts:
            continue
        file_count += 1
        total_bytes += path.stat().st_size
        if path.name.lower().endswith((".nii", ".nii.gz")):
            headers.append({"nifti": path.name})
            continue
        header = read_header(path.open("rb").read(262_144))
        if header:
            headers.append(header)
    return headers, file_count, total_bytes, None


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0])
        print("\nUso: python3 Tools/inspect-dicom.py <cartella | esame.zip>")
        return 2

    target = Path(argv[1]).expanduser()
    if not target.exists():
        print(f"Non trovo «{target}».", file=sys.stderr)
        return 2

    headers, file_count, total_bytes, archive_bytes = collect(target)
    dicom = [h for h in headers if "nifti" not in h]
    nifti = [h for h in headers if "nifti" in h]

    print(f"{target}")
    print(f"{file_count} file, {total_bytes / 1024**2:.1f} MB una volta estratti")
    if nifti:
        print(f"{len(nifti)} file NIfTI: passano senza conversione.")
    if not dicom:
        print("\nNessun file DICOM leggibile qui dentro." if not nifti else "")
        return 0 if nifti else 1

    series = defaultdict(list)
    for header in dicom:
        series[header["seriesUID"]].append(header)

    patients = {h["patient"] for h in dicom if h["patient"]}
    problems = []
    print()

    for uid, files in sorted(series.items(), key=lambda item: -len(item[1])):
        first = files[0]
        slices = max(len(files), first["frames"])
        columns = first["columns"] or 0
        rows = first["rows"] or 0
        voxels = columns * rows * slices
        label = first["description"] or "(serie senza descrizione)"

        notes = []
        if first["modality"] not in ACCEPTED_MODALITIES:
            notes.append(
                f"RIFIUTATA: Modality «{first['modality'] or 'assente'}», "
                f"l'importatore accetta solo {' e '.join(ACCEPTED_MODALITIES)}"
            )
        if first["samplesPerPixel"] != 1:
            notes.append(
                f"RIFIUTATA: {first['samplesPerPixel']} campioni per pixel, ne serve 1 "
                "(è un'immagine a colori, non un volume)"
            )
        if slices < 2:
            notes.append("RIFIUTATA: una sola immagine, non è un volume")
        if voxels > MAXIMUM_VOXELS:
            notes.append(
                f"RIFIUTATA: {voxels / 1e6:.0f} milioni di voxel, il tetto è "
                f"{MAXIMUM_VOXELS / 1e6:.0f} milioni"
            )
        if not first["orientation"]:
            notes.append("ATTENZIONE: manca ImageOrientationPatient, la conversione può fallire")

        mark = "×" if any(n.startswith("RIFIUTATA") for n in notes) else "✓"
        size = f"{columns}×{rows}×{slices}" if columns and rows else "dimensioni ignote"
        spacing = f", {first['spacing']} mm" if first["spacing"] else ""
        thickness = f", spessore {first['thickness']} mm" if first["thickness"] else ""
        print(f"{mark} {label}")
        print(f"    {first['modality'] or '?'} · {size}{spacing}{thickness}")
        if first["imageType"]:
            print(f"    tipo: {first['imageType']}")
        for note in notes:
            print(f"    {note}")
            if note.startswith("RIFIUTATA"):
                problems.append(f"{label}: {note}")

    print()
    if len(patients) > 1:
        problems.append(
            f"L'archivio contiene {len(patients)} pazienti: l'importatore ne vuole uno per volta"
        )
        print(f"× {len(patients)} pazienti diversi qui dentro: vanno separati in archivi distinti.")
    if file_count > MAXIMUM_FILES:
        problems.append(f"{file_count} file: il tetto è {MAXIMUM_FILES}")
    if total_bytes > MAXIMUM_EXTRACTED_BYTES:
        problems.append("Estratto supera i 12 GB")
    if archive_bytes and archive_bytes > MAXIMUM_ARCHIVE_BYTES:
        problems.append(f"Lo ZIP pesa {archive_bytes / 1024**3:.1f} GB, il tetto è 2 GB")

    if problems:
        print("Non importabile così com'è:")
        for problem in problems:
            print(f"  · {problem}")
        return 1

    usable = sum(1 for files in series.values() if len(files) >= 2)
    print(f"Importabile: {usable} serie volumetriche su {len(series)}.")
    if archive_bytes is None:
        print("Comprimi la cartella in uno ZIP e aprila con «Import MRI».")
    else:
        print("Aprilo con «Import MRI».")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
