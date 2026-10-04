#!/usr/bin/env python3
"""Scrive le fixture DICOM delle prove di DICOMCore, con pydicom.

# Perché le scrive pydicom e non il nostro scrittore

Perché una prova di lettura scritta da chi legge prova soltanto che lettore e scrittore sono
d'accordo fra loro — anche quando sbagliano tutti e due allo stesso modo. Le forme che queste
fixture coprono sono proprio quelle dove è facile sbagliare in due: le sequenze dei gruppi
funzionali di un multiframe, le lunghezze indefinite, la tabella degli offset di un multiframe
compresso, il DICOMDIR di un CD. pydicom è l'implementazione di riferimento più usata, ed è
scritta da altri.

Le fixture sono versionate in `Tests/DICOMCoreTests/Fixtures`, così le prove girano senza pydicom.
Questo script serve solo a rigenerarle:

    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pydicom numpy
    /tmp/venv/bin/python Tools/make-dicom-fixtures.py

# Che cosa contengono

Un volume di 6 colonne × 5 righe × 4 fette, minuscolo di proposito. Ogni voxel vale
`100·k + 10·j + i` in valore grezzo — fetta, riga, colonna — così un voxel fuori posto si
riconosce dal numero. Le tre spaziature sono diverse fra loro (0,4 mm fra colonne, 0,5 fra
righe, 0,75 fra fette) perché uno scambio fra assi cambi il risultato invece di passare
inosservato, e l'origine non è zero per la stessa ragione.

- `enhanced-explicit/` — Enhanced CT multiframe, Explicit VR, sequenze a lunghezza definita,
  fotogrammi scritti **dall'alto in basso**: l'ordine giusto lo dà la posizione, non il file.
- `enhanced-implicit/` — lo stesso in Implicit VR, sequenze e item a lunghezza indefinita.
- `enhanced-rle/` — lo stesso compresso RLE: un frammento per fotogramma.
- `legacy-multiframe/` — multiframe senza gruppi funzionali, `Modality` OT: una sola posizione,
  le altre si deducono dalla spaziatura.
- `cd/` — com'è fatto il CD del centro: `DICOMDIR` vero, file senza estensione in Implicit VR
  dentro sottocartelle, e accanto il visualizzatore per Windows, che non è DICOM.
"""

import shutil
import sys
from pathlib import Path

import numpy as np
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.fileset import FileSet
from pydicom.sequence import Sequence
from pydicom.uid import (
    CTImageStorage,
    EnhancedCTImageStorage,
    ExplicitVRLittleEndian,
    ImplicitVRLittleEndian,
    MultiFrameGrayscaleWordSecondaryCaptureImageStorage,
    RLELossless,
)

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "DICOMCoreTests" / "Fixtures"

COLUMNS, ROWS, SLICES = 6, 5, 4
COLUMN_SPACING, ROW_SPACING, SLICE_STEP = 0.4, 0.5, 0.75
ORIGIN = (-10.0, -20.0, 30.0)
INTERCEPT = -1000

# UID fissi: rigenerare le fixture deve dare gli stessi byte, o ogni rigenerazione sporca il diff.
ROOT_UID = "1.2.826.0.1.3680043.10.1499"


def uid(*parts):
    return ".".join([ROOT_UID, *(str(p) for p in parts)])


def volume():
    """Il volume, indicizzato [fetta, riga, colonna], fetta 0 in basso."""
    k, j, i = np.meshgrid(np.arange(SLICES), np.arange(ROWS), np.arange(COLUMNS), indexing="ij")
    return (100 * k + 10 * j + i).astype(np.int16)


def position(k):
    return [ORIGIN[0], ORIGIN[1], ORIGIN[2] + k * SLICE_STEP]


def base(sop_class, sop_instance, transfer_syntax, series):
    meta = FileMetaDataset()
    meta.MediaStorageSOPClassUID = sop_class
    meta.MediaStorageSOPInstanceUID = sop_instance
    meta.TransferSyntaxUID = transfer_syntax
    meta.ImplementationClassUID = uid(0)

    ds = Dataset()
    ds.file_meta = meta
    ds.SOPClassUID = sop_class
    ds.SOPInstanceUID = sop_instance
    ds.PatientName = "FIXTURE^DICOMCORE"
    ds.PatientID = "FIXTURE-001"
    ds.StudyDate = "20260314"
    ds.StudyTime = "093000"
    ds.StudyID = "1"
    ds.StudyInstanceUID = uid(1)
    ds.SeriesInstanceUID = uid(series)
    ds.FrameOfReferenceUID = uid(2)
    ds.SeriesNumber = series
    ds.Modality = "CT"
    ds.Manufacturer = "Fixture"
    ds.SamplesPerPixel = 1
    ds.PhotometricInterpretation = "MONOCHROME2"
    ds.Rows = ROWS
    ds.Columns = COLUMNS
    ds.BitsAllocated = 16
    ds.BitsStored = 16
    ds.HighBit = 15
    ds.PixelRepresentation = 1
    return ds


def enhanced(series, transfer_syntax, undefined_lengths=False):
    """Enhanced CT, fotogrammi dall'alto in basso: il fotogramma 0 è la fetta più alta."""
    sop = uid(series, 1)
    ds = base(EnhancedCTImageStorage, sop, transfer_syntax, series)
    ds.InstanceNumber = 1
    ds.ImageType = ["ORIGINAL", "PRIMARY", "AXIAL", "NONE"]
    ds.NumberOfFrames = SLICES

    measures = Dataset()
    measures.PixelSpacing = [ROW_SPACING, COLUMN_SPACING]
    measures.SliceThickness = SLICE_STEP
    orientation = Dataset()
    orientation.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
    transform = Dataset()
    transform.RescaleIntercept = INTERCEPT
    transform.RescaleSlope = 1
    transform.RescaleType = "HU"
    shared = Dataset()
    shared.PixelMeasuresSequence = Sequence([measures])
    shared.PlaneOrientationSequence = Sequence([orientation])
    shared.PixelValueTransformationSequence = Sequence([transform])
    ds.SharedFunctionalGroupsSequence = Sequence([shared])

    order = list(reversed(range(SLICES)))
    groups = []
    for frame, k in enumerate(order):
        plane = Dataset()
        plane.ImagePositionPatient = position(k)
        content = Dataset()
        content.InStackPositionNumber = frame + 1
        content.StackID = "1"
        group = Dataset()
        group.PlanePositionSequence = Sequence([plane])
        group.FrameContentSequence = Sequence([content])
        groups.append(group)
    ds.PerFrameFunctionalGroupsSequence = Sequence(groups)

    ds.PixelData = volume()[order].tobytes()
    if undefined_lengths:
        mark_undefined(ds)
    return ds


def mark_undefined(ds):
    """Sequenze e item a lunghezza indefinita, come li scrivono molti apparecchi."""
    for element in ds:
        if element.VR == "SQ":
            element.is_undefined_length = True
            for item in element.value:
                item.is_undefined_length_sequence_item = True
                mark_undefined(item)


def legacy_multiframe(series):
    """Multiframe senza gruppi funzionali: una posizione, il resto si deduce."""
    sop = uid(series, 1)
    sop_class = MultiFrameGrayscaleWordSecondaryCaptureImageStorage
    ds = base(sop_class, sop, ExplicitVRLittleEndian, series)
    ds.Modality = "OT"
    ds.InstanceNumber = 1
    ds.NumberOfFrames = SLICES
    ds.FrameIncrementPointer = 0x00180088
    ds.ImagePositionPatient = position(0)
    ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
    ds.PixelSpacing = [ROW_SPACING, COLUMN_SPACING]
    ds.SpacingBetweenSlices = SLICE_STEP
    ds.RescaleIntercept = INTERCEPT
    ds.RescaleSlope = 1
    ds.PixelData = volume().tobytes()
    return ds


def classic_slices(series, transfer_syntax):
    """La forma classica, un file per fetta: è quella del CD."""
    slices = []
    data = volume()
    for k in range(SLICES):
        sop = uid(series, k + 1)
        ds = base(CTImageStorage, sop, transfer_syntax, series)
        ds.InstanceNumber = SLICES - k  # sbagliato di proposito: l'ordine lo dà la posizione
        ds.ImagePositionPatient = position(k)
        ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
        ds.PixelSpacing = [ROW_SPACING, COLUMN_SPACING]
        ds.SliceThickness = SLICE_STEP
        ds.RescaleIntercept = INTERCEPT
        ds.RescaleSlope = 1
        ds.PixelData = data[k].tobytes()
        slices.append(ds)
    return slices


def save(ds, folder, name="CBCT.dcm"):
    folder.mkdir(parents=True, exist_ok=True)
    ds.save_as(folder / name, enforce_file_format=True)


def main():
    if FIXTURES.exists():
        shutil.rmtree(FIXTURES)

    save(enhanced(10, ExplicitVRLittleEndian), FIXTURES / "enhanced-explicit")
    save(
        enhanced(11, ImplicitVRLittleEndian, undefined_lengths=True),
        FIXTURES / "enhanced-implicit",
    )

    rle = enhanced(12, ExplicitVRLittleEndian)
    order = list(reversed(range(SLICES)))
    rle.compress(RLELossless, volume()[order], generate_instance_uid=False)
    save(rle, FIXTURES / "enhanced-rle")

    save(legacy_multiframe(13), FIXTURES / "legacy-multiframe")

    cd = FIXTURES / "cd"
    fileset = FileSet()
    fileset.ID = "CBCT"
    for ds in classic_slices(14, ImplicitVRLittleEndian):
        fileset.add(ds)
    fileset.write(cd)
    viewer = cd / "Viewer"
    viewer.mkdir()
    (viewer / "Viewer.exe").write_bytes(b"MZ" + bytes(510))
    (viewer / "dicom.dll").write_bytes(b"MZ" + bytes(254))
    (cd / "autorun.inf").write_text("[autorun]\nopen=Viewer\\Viewer.exe\n")

    for path in sorted(FIXTURES.rglob("*")):
        if path.is_file():
            print(f"{path.relative_to(ROOT)}  {path.stat().st_size} byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
