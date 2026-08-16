#!/usr/bin/env python3
"""
Generatore di fantocci CBCT sintetici.

Produce una serie DICOM di un oggetto di dimensioni e densita' note. Serve a due cose:

1. **Validare l'intera catena delle coordinate.** Se uno spigolo che misura esattamente
   20,00 mm nel fantoccio non legge 20,00 mm nell'applicazione, qualcosa fra la matrice del
   volume, l'ordinamento delle slice e la proiezione dei pixel e' rotto. Su dati reali un
   errore del genere e' invisibile: non esiste un paziente di cui si conosca la mandibola al
   centesimo di millimetro. Qui invece la verita' e' nota per costruzione.

2. **Provare l'applicazione senza toccare dati di pazienti.** Nessun problema di privacy,
   nessun dato clinico nella repo.

Scritto in Python puro, senza pydicom ne' numpy, di proposito: nessuna dipendenza da
installare, e i byte DICOM prodotti sono un'implementazione indipendente da quella del
parser Swift, quindi i due si verificano a vicenda invece di condividere lo stesso
malinteso sul formato.

Uso:
    python3 make_phantom.py --output ./phantom
    python3 make_phantom.py --output ./phantom --bits-stored 12
    python3 make_phantom.py --output ./phantom --anisotropic
"""

import argparse
import math
import os
import struct
import sys

# --------------------------------------------------------------------------------------
# Costanti DICOM
# --------------------------------------------------------------------------------------

EXPLICIT_VR_LITTLE_ENDIAN = "1.2.840.10008.1.2.1"
CT_IMAGE_STORAGE = "1.2.840.10008.5.1.4.1.1.2"

# Radice UID di prova. 2.25.* e' lo spazio riservato agli UUID e non collide con nulla.
UID_ROOT = "2.25.99999"

# VR che nella forma esplicita usano l'intestazione lunga: 2 byte riservati + 4 di lunghezza.
LONG_FORM_VR = {"OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT", "SV", "UV"}


def encode_element(group, element, vr, value):
    """Codifica un elemento in Explicit VR Little Endian."""
    if isinstance(value, str):
        payload = value.encode("ascii")
    else:
        payload = value

    # Ogni elemento deve avere lunghezza pari. I VR testuali si riempiono con uno spazio,
    # gli UID e i binari con un byte nullo: e' quanto prescrive lo standard, e sbagliarlo
    # manda fuori sincrono ogni lettore.
    if len(payload) % 2 == 1:
        payload += b"\x00" if vr in ("UI", "OB", "OW", "UN") else b" "

    header = struct.pack("<HH", group, element) + vr.encode("ascii")
    if vr in LONG_FORM_VR:
        header += b"\x00\x00" + struct.pack("<I", len(payload))
    else:
        header += struct.pack("<H", len(payload))
    return header + payload


def decimal_string(*values):
    """VR di tipo DS: numeri come testo, separati da backslash, al massimo 16 caratteri."""
    parts = []
    for v in values:
        s = f"{v:.6f}".rstrip("0").rstrip(".")
        if s in ("", "-0"):
            s = "0"
        parts.append(s[:16])
    return "\\".join(parts)


def make_uid(*parts):
    return ".".join([UID_ROOT] + [str(p) for p in parts])


# --------------------------------------------------------------------------------------
# Geometria del fantoccio
# --------------------------------------------------------------------------------------


class Phantom:
    """
    Contenuto del fantoccio, definito analiticamente in millimetri.

    Origine al centro del volume. Tutte le quote sono esatte per costruzione, quindi
    diventano il riferimento contro cui confrontare le misure dell'applicazione.
    """

    # Densita' di riferimento, in unita' di densita' (non grezze).
    AIR = -1000.0
    WATER = 0.0
    SOFT_TISSUE = 60.0
    CANCELLOUS = 400.0
    CORTICAL = 1200.0
    ENAMEL = 2800.0

    # Cubo di riferimento: lo spigolo e' la misura principale da verificare.
    CUBE_EDGE_MM = 20.0

    # Sfere: (diametro in mm, densita', centro (x, y, z) in mm)
    SPHERES = [
        (10.0, CANCELLOUS, (-18.0, 0.0, 0.0)),
        (6.0, ENAMEL, (18.0, -10.0, 0.0)),
        (4.0, SOFT_TISSUE, (18.0, 10.0, 0.0)),
    ]

    # Due lastrine parallele con intercapedine d'aria di misura nota: verifica le distanze
    # lungo l'asse delle slice, che e' quello dove un errore di spaziatura si nasconde meglio.
    #
    # La quota z = −20 mm le tiene ben separate dal cubo, che arriva a −10: fra le due
    # strutture restano 3 mm d'aria, sufficienti perche' una misura automatica non le fonda
    # in un unico blocco denso. Il volume predefinito e' alto 60 mm proprio per contenerle.
    PLATE_GAP_MM = 10.0
    PLATE_THICKNESS_MM = 2.0
    PLATE_HALF_WIDTH_MM = 12.0
    PLATE_CENTER_Z_MM = -20.0

    @classmethod
    def required_half_depth_mm(cls):
        """Semi-altezza minima del volume perche' tutte le strutture ci stiano dentro."""
        return abs(cls.PLATE_CENTER_Z_MM) + cls.PLATE_GAP_MM / 2.0 + cls.PLATE_THICKNESS_MM

    def density_at(self, x, y, z):
        """Densita' nel punto (x, y, z), in millimetri dal centro del volume."""
        half = self.CUBE_EDGE_MM / 2.0
        if abs(x) <= half and abs(y) <= half and abs(z) <= half:
            return self.CORTICAL

        for diameter, density, (cx, cy, cz) in self.SPHERES:
            r = diameter / 2.0
            if (x - cx) ** 2 + (y - cy) ** 2 + (z - cz) ** 2 <= r * r:
                return density

        if abs(x) <= self.PLATE_HALF_WIDTH_MM and abs(y) <= self.PLATE_HALF_WIDTH_MM:
            half_gap = self.PLATE_GAP_MM / 2.0
            for sign in (-1.0, 1.0):
                near = self.PLATE_CENTER_Z_MM + sign * half_gap
                far = near + sign * self.PLATE_THICKNESS_MM
                lo, hi = min(near, far), max(near, far)
                if lo <= z <= hi:
                    return self.CORTICAL

        return self.AIR

    def bounding_shapes(self):
        """
        Scatole di contenimento delle strutture, in mm.

        Serve a non valutare `density_at` su tutti i voxel: il fantoccio e' quasi tutto aria,
        e in Python puro tredici milioni di chiamate costerebbero minuti. Cosi' si riempie lo
        sfondo in blocco e si visita solo cio' che sta dentro queste scatole.
        """
        half = self.CUBE_EDGE_MM / 2.0
        boxes = [(-half, half, -half, half, -half, half)]

        for diameter, _, (cx, cy, cz) in self.SPHERES:
            r = diameter / 2.0
            boxes.append((cx - r, cx + r, cy - r, cy + r, cz - r, cz + r))

        w = self.PLATE_HALF_WIDTH_MM
        half_gap = self.PLATE_GAP_MM / 2.0
        t = self.PLATE_THICKNESS_MM
        zlo = self.PLATE_CENTER_Z_MM - half_gap - t
        zhi = self.PLATE_CENTER_Z_MM + half_gap + t
        boxes.append((-w, w, -w, w, zlo, zhi))

        return boxes

    def expected_measurements(self):
        """Le misure che l'applicazione deve restituire. E' la specifica del test."""
        rows = [
            ("Spigolo del cubo", f"{self.CUBE_EDGE_MM:.2f} mm"),
            ("Diagonale di faccia", f"{self.CUBE_EDGE_MM * math.sqrt(2):.2f} mm"),
            ("Diagonale del cubo", f"{self.CUBE_EDGE_MM * math.sqrt(3):.2f} mm"),
            ("Densita' del cubo", f"{self.CORTICAL:.0f} GV"),
            ("Intercapedine fra lastrine", f"{self.PLATE_GAP_MM:.2f} mm"),
            ("Spessore lastrina", f"{self.PLATE_THICKNESS_MM:.2f} mm"),
        ]
        for diameter, density, _ in self.SPHERES:
            rows.append((f"Sfera Ø{diameter:.0f} mm", f"{diameter:.2f} mm, {density:.0f} GV"))
        return rows


# --------------------------------------------------------------------------------------
# Generazione del volume
# --------------------------------------------------------------------------------------


def build_slice(phantom, k, columns, rows, spacing_mm, origin_mm, intercept, slope, max_stored):
    """
    Costruisce una slice come bytearray di UInt16 little endian.

    Si parte da uno sfondo d'aria uniforme e si sovrascrivono solo i voxel dentro le scatole
    di contenimento delle strutture.
    """
    air_stored = int(round((Phantom.AIR - intercept) / slope))
    air_stored = max(0, min(max_stored, air_stored))
    buffer = bytearray(struct.pack("<H", air_stored) * (columns * rows))

    z = origin_mm[2] + k * spacing_mm[2]

    for (xlo, xhi, ylo, yhi, zlo, zhi) in phantom.bounding_shapes():
        if not (zlo <= z <= zhi):
            continue

        i0 = max(0, int(math.floor((xlo - origin_mm[0]) / spacing_mm[0])))
        i1 = min(columns - 1, int(math.ceil((xhi - origin_mm[0]) / spacing_mm[0])))
        j0 = max(0, int(math.floor((ylo - origin_mm[1]) / spacing_mm[1])))
        j1 = min(rows - 1, int(math.ceil((yhi - origin_mm[1]) / spacing_mm[1])))
        if i0 > i1 or j0 > j1:
            continue

        for j in range(j0, j1 + 1):
            y = origin_mm[1] + j * spacing_mm[1]
            row_base = j * columns
            for i in range(i0, i1 + 1):
                x = origin_mm[0] + i * spacing_mm[0]
                density = phantom.density_at(x, y, z)
                if density == Phantom.AIR:
                    continue
                stored = int(round((density - intercept) / slope))
                stored = max(0, min(max_stored, stored))
                offset = (row_base + i) * 2
                buffer[offset] = stored & 0xFF
                buffer[offset + 1] = (stored >> 8) & 0xFF

    return buffer


def write_series(
    output_dir,
    columns=256,
    rows=256,
    slices=240,
    spacing_mm=(0.25, 0.25, 0.25),
    bits_stored=16,
    verbose=True,
):
    """Scrive la serie DICOM completa."""
    os.makedirs(output_dir, exist_ok=True)
    phantom = Phantom()

    # Meglio avvisare subito che lasciare all'utente un fantoccio in cui mancano proprio le
    # strutture su cui si basa la verifica delle distanze.
    half_depth = (slices - 1) * spacing_mm[2] / 2.0
    if half_depth < phantom.required_half_depth_mm():
        needed = int(math.ceil(2 * phantom.required_half_depth_mm() / spacing_mm[2])) + 1
        print(
            f"  Attenzione: con {slices} slice a {spacing_mm[2]} mm il volume e' alto "
            f"{half_depth * 2:.1f} mm e le lastrine di riferimento restano fuori. "
            f"Servono almeno {needed} slice per includerle.",
            file=sys.stderr,
        )

    slope = 1.0
    intercept = -1000.0
    max_stored = (1 << bits_stored) - 1

    # Origine in modo che il centro del volume cada in (0,0,0) mm: il fantoccio e' definito
    # attorno all'origine, quindi cosi' resta centrato.
    origin_mm = (
        -(columns - 1) * spacing_mm[0] / 2.0,
        -(rows - 1) * spacing_mm[1] / 2.0,
        -(slices - 1) * spacing_mm[2] / 2.0,
    )

    study_uid = make_uid(1, 1)
    series_uid = make_uid(1, 1, 1)
    frame_of_reference_uid = make_uid(1, 1, 2)

    for k in range(slices):
        pixel_data = build_slice(
            phantom, k, columns, rows, spacing_mm, origin_mm, intercept, slope, max_stored
        )

        sop_uid = make_uid(1, 1, 1, k + 1)
        z = origin_mm[2] + k * spacing_mm[2]

        dataset = b"".join(
            [
                encode_element(0x0008, 0x0016, "UI", CT_IMAGE_STORAGE),
                encode_element(0x0008, 0x0018, "UI", sop_uid),
                encode_element(0x0008, 0x0020, "DA", "20260101"),
                encode_element(0x0008, 0x0030, "TM", "120000"),
                encode_element(0x0008, 0x0060, "CS", "CT"),
                encode_element(0x0008, 0x0070, "LO", "CBCTMac"),
                encode_element(0x0008, 0x1030, "LO", "Fantoccio sintetico"),
                encode_element(0x0008, 0x103E, "LO", "Cubo 20mm e sfere di riferimento"),
                encode_element(0x0008, 0x1090, "LO", "PhantomGenerator"),
                encode_element(0x0010, 0x0010, "PN", "FANTOCCIO^SINTETICO"),
                encode_element(0x0010, 0x0020, "LO", "PHANTOM001"),
                encode_element(0x0010, 0x0030, "DA", ""),
                encode_element(0x0018, 0x0050, "DS", decimal_string(spacing_mm[2])),
                encode_element(0x0018, 0x0088, "DS", decimal_string(spacing_mm[2])),
                encode_element(0x0020, 0x000D, "UI", study_uid),
                encode_element(0x0020, 0x000E, "UI", series_uid),
                encode_element(0x0020, 0x0011, "IS", "1"),
                encode_element(0x0020, 0x0013, "IS", str(k + 1)),
                # ImagePositionPatient: e' il tag da cui dipende tutto l'ordinamento.
                encode_element(
                    0x0020, 0x0032, "DS", decimal_string(origin_mm[0], origin_mm[1], z)
                ),
                # ImageOrientationPatient: assiale standard.
                encode_element(0x0020, 0x0037, "DS", decimal_string(1, 0, 0, 0, 1, 0)),
                encode_element(0x0020, 0x0052, "UI", frame_of_reference_uid),
                encode_element(0x0028, 0x0002, "US", struct.pack("<H", 1)),
                encode_element(0x0028, 0x0004, "CS", "MONOCHROME2"),
                encode_element(0x0028, 0x0010, "US", struct.pack("<H", rows)),
                encode_element(0x0028, 0x0011, "US", struct.pack("<H", columns)),
                # PixelSpacing e' [righe, colonne], cioe' [verticale, orizzontale].
                encode_element(
                    0x0028, 0x0030, "DS", decimal_string(spacing_mm[1], spacing_mm[0])
                ),
                encode_element(0x0028, 0x0100, "US", struct.pack("<H", 16)),
                encode_element(0x0028, 0x0101, "US", struct.pack("<H", bits_stored)),
                encode_element(0x0028, 0x0102, "US", struct.pack("<H", bits_stored - 1)),
                encode_element(0x0028, 0x0103, "US", struct.pack("<H", 0)),
                encode_element(0x0028, 0x1050, "DS", "600"),
                encode_element(0x0028, 0x1051, "DS", "2400"),
                encode_element(0x0028, 0x1052, "DS", decimal_string(intercept)),
                encode_element(0x0028, 0x1053, "DS", decimal_string(slope)),
                encode_element(0x7FE0, 0x0010, "OW", bytes(pixel_data)),
            ]
        )

        meta_body = b"".join(
            [
                encode_element(0x0002, 0x0001, "OB", b"\x00\x01"),
                encode_element(0x0002, 0x0002, "UI", CT_IMAGE_STORAGE),
                encode_element(0x0002, 0x0003, "UI", sop_uid),
                encode_element(0x0002, 0x0010, "UI", EXPLICIT_VR_LITTLE_ENDIAN),
                encode_element(0x0002, 0x0012, "UI", make_uid(2)),
                encode_element(0x0002, 0x0013, "SH", "CBCTMAC_PHANTOM"),
            ]
        )
        group_length = encode_element(0x0002, 0x0000, "UL", struct.pack("<I", len(meta_body)))

        with open(os.path.join(output_dir, f"slice_{k:04d}.dcm"), "wb") as f:
            f.write(b"\x00" * 128)
            f.write(b"DICM")
            f.write(group_length)
            f.write(meta_body)
            f.write(dataset)

        if verbose and (k + 1) % 20 == 0:
            print(f"  {k + 1}/{slices} slice", file=sys.stderr)

    return phantom, origin_mm


def main():
    parser = argparse.ArgumentParser(description="Genera un fantoccio CBCT sintetico.")
    parser.add_argument("--output", "-o", default="./phantom", help="cartella di destinazione")
    parser.add_argument("--columns", type=int, default=256)
    parser.add_argument("--rows", type=int, default=256)
    parser.add_argument("--slices", type=int, default=240)
    parser.add_argument("--spacing", type=float, default=0.25, help="passo isotropico in mm")
    parser.add_argument(
        "--bits-stored",
        type=int,
        default=16,
        choices=[12, 16],
        help="16 esercita il percorso senza segno a 16 bit, che richiede la traslazione; "
        "12 e' il caso CBCT piu' comune",
    )
    parser.add_argument(
        "--anisotropic",
        action="store_true",
        help="voxel non isotropici: scopre gli scambi fra spaziatura di righe e colonne, "
        "che su voxel isotropici non danno alcun sintomo",
    )
    args = parser.parse_args()

    if args.anisotropic:
        spacing = (args.spacing, args.spacing * 1.5, args.spacing * 2.0)
    else:
        spacing = (args.spacing, args.spacing, args.spacing)

    print(
        f"Genero {args.slices} slice da {args.columns}x{args.rows}, "
        f"passo {spacing[0]}x{spacing[1]}x{spacing[2]} mm, BitsStored {args.bits_stored}",
        file=sys.stderr,
    )

    phantom, origin = write_series(
        args.output,
        columns=args.columns,
        rows=args.rows,
        slices=args.slices,
        spacing_mm=spacing,
        bits_stored=args.bits_stored,
    )

    print(f"\nScritto in {args.output}", file=sys.stderr)
    print("\nMisure attese:", file=sys.stderr)
    for label, value in phantom.expected_measurements():
        print(f"  {label:.<34} {value}", file=sys.stderr)
    print(
        "\nSe una di queste non corrisponde nell'applicazione, l'errore sta nella catena "
        "delle coordinate, non nei dati.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
