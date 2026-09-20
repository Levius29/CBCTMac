#!/usr/bin/env python3
"""Panoramica ricostruita e sezioni trasversali d'arcata, da un volume CBCT.

# Perché questo file esiste

OpenMRI guarda volumi: tre sezioni ortogonali e un rendering. Per una CBCT dentale non basta, e
non è una questione di comodità. I denti stanno su una curva, e qualunque taglio piatto li
attraversa di sbieco: su un'assiale un molare compare come tre macchie separate, su una sagittale
si vede un dente e mezzo. Le due viste che servono davvero sono ricostruite lungo quella curva —
la **panoramica**, che è uno slab curvo lungo l'arcata, e le **sezioni trasversali**,
perpendicolari a essa, che sono quelle su cui si giudicano altezza e spessore della cresta.

# Da dove viene questa matematica

È il porto fedele di `Sources/DentalKit` e `Sources/SegmentKit/ArchDetection.swift` della riserva
Swift, dove è già verificata. Le scelte non ovvie sono state tenute, e vale la pena ripeterle
perché è da lì che si vede se una ricostruzione è fatta bene:

- **Catmull-Rom** e non Bézier: la curva passa **esattamente** per i punti posati, che è ciò che
  la rende correggibile a mano guardando l'anatomia.
- **Ricampionamento a passo d'arco costante**: campionare a passo di parametro comprimerebbe
  l'immagine nelle curve e la dilaterebbe nei tratti diritti, e una misura orizzontale presa sulla
  panoramica non significherebbe niente.
- **Scala isotropa**: millimetri per pixel uguali in orizzontale e in verticale. Con due scale
  diverse una misura verticale non è confrontabile con una orizzontale, ed è esattamente l'uso che
  si fa di una panoramica ricostruita.
- **Slab centrato sulla curva**, da −T/2 a +T/2: partendo dalla curva verso l'esterno si
  perderebbe metà dello spessore, cioè tutto il versante linguale.
- **Soglia di Otsu** e non un valore fisso: su CBCT i valori grigi non sono unità Hounsfield e
  una soglia costante funziona su un apparecchio e non sull'altro.
- **Tre criteri di rifiuto espliciti** nel rilevamento dell'arcata. Una proposta sbagliata è
  peggio di nessuna proposta: chi la riceve la corregge invece di rifarla, e finisce con una curva
  né sua né buona.

# Che cosa questa ricostruzione non è

Una panoramica ricostruita **non è una radiografia panoramica**: è una superficie campionata, e il
tessuto che ci si vede può stare in qualunque punto dello spessore dello slab. Una distanza presa
su di essa è una distanza fra due punti della superficie ricostruita. Per la distanza fra due
strutture vale la sezione trasversale, dove il piano è piatto e il punto è dove sembra.

Uso:
    python3 dental_panorama.py <volume.nii.gz> <cartella-uscita> [opzioni.json]

Scrive le immagini nella cartella e stampa su stdout il risultato in JSON.
"""

import json
import sys
from pathlib import Path

import nibabel as nib
import numpy as np
import SimpleITK as sitk
from scipy import ndimage

# MARK: - Costanti del rilevamento, con i valori della riserva Swift

#: Settori angolari attorno al baricentro dell'osso.
SECTOR_COUNT = 72
#: Frazione minima di settori che devono contenere osso perché la figura sia un'arcata.
MINIMUM_FILLED_SECTOR_FRACTION = 0.35
#: Frazione minima della fetta che deve essere osso. Relativa, non assoluta: un minimo fisso
#: dipenderebbe dal passo di campionamento, e la stessa anatomia passerebbe o no secondo il voxel.
MINIMUM_BONE_FRACTION = 0.003
#: Sotto questo numero di punti la statistica per settore non regge comunque.
MINIMUM_BONE_POINTS = 120
#: Settori vuoti di fila perché l'apertura della U sia un'apertura: otto su settantadue, quaranta
#: gradi. Con un solo settore bastava un buco di cinque gradi nel rumore perché la curva girasse
#: attorno alla testa invece di seguire l'arcata.
MINIMUM_OPENING_SECTORS = 8
#: Suddivisioni per segmento nella poligonale che misura la lunghezza d'arco.
SUBDIVISIONS_PER_SEGMENT = 200
#: Tetto ai campioni dello slab: oltre, il guadagno visivo è nullo e il costo no.
MAXIMUM_SLAB_SAMPLES = 96
#: Lunghezze d'arcata plausibili, in millimetri. Serve a scegliere fra più quote candidate.
PLAUSIBLE_ARCH_LENGTH_MM = (55.0, 220.0)


# MARK: - Soglia


def otsu_threshold(values, bin_count=256):
    """Il valore che massimizza la varianza fra le due classi, o `None` se non c'è nulla da separare.

    Un percentile fisso sarebbe più corto e sbaglierebbe: su una fetta in cui l'osso è meno del
    venti per cento — cioè qualunque fetta vera — l'ottantesimo percentile cade nel fondo.
    """
    values = values[np.isfinite(values)]
    if values.size == 0:
        return None
    minimum = float(values.min())
    maximum = float(values.max())
    if not maximum > minimum:
        return None

    histogram, edges = np.histogram(values, bins=bin_count, range=(minimum, maximum))
    histogram = histogram.astype(np.float64)
    total = histogram.sum()
    if total <= 0:
        return None

    centres = np.arange(bin_count, dtype=np.float64)
    weight_below = np.cumsum(histogram)
    weight_above = total - weight_below
    sum_below = np.cumsum(histogram * centres)
    sum_all = sum_below[-1]

    valid = (weight_below > 0) & (weight_above > 0)
    if not valid.any():
        return None
    mean_below = np.zeros(bin_count)
    mean_above = np.zeros(bin_count)
    mean_below[valid] = sum_below[valid] / weight_below[valid]
    mean_above[valid] = (sum_all - sum_below[valid]) / weight_above[valid]
    variance = np.where(
        valid, weight_below * weight_above * (mean_below - mean_above) ** 2, -1.0
    )
    best = int(np.argmax(variance))
    if variance[best] <= 0:
        return None
    return float(minimum + (best + 1) / bin_count * (maximum - minimum))


def largest_component(mask):
    """La macchia connessa più grande, a quattro vicini.

    A otto vicini due strutture che si sfiorano in diagonale — la corticale linguale e la punta di
    un processo — diventerebbero una sola, ed è proprio la fusione che questo filtro evita.

    Serve perché su una fetta assiale l'osso oltre soglia non è solo l'arcata: c'è la colonna
    cervicale dietro, spesso i rami. Tutto questo tirava il baricentro all'indietro e riempiva i
    settori tutto intorno, quindi l'apertura dell'arcata spariva e la curva girava attorno alla
    testa.
    """
    structure = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], dtype=bool)
    labels, count = ndimage.label(mask, structure=structure)
    if count == 0:
        return np.zeros_like(mask, dtype=bool)
    sizes = ndimage.sum_labels(mask, labels, index=np.arange(1, count + 1))
    return labels == (int(np.argmax(sizes)) + 1)


# MARK: - Rilevamento dell'arcata


def suggest_arch_points(slice_values, origin_x, origin_y, step, vertical_mm, point_count=9):
    """Punti di controllo proposti per la curva, o `None` se qui non c'è un'arcata riconoscibile.

    Il metodo è dichiarato perché è euristico: si soglia l'osso, si tiene la componente connessa
    maggiore, la si guarda in coordinate polari dal proprio baricentro e per ogni settore angolare
    si prende il raggio **mediano** — non il massimo, che inseguirebbe il voxel più esterno, che su
    una CBCT è spesso rumore o una vertebra entrata nell'inquadratura.
    """
    finite = slice_values[np.isfinite(slice_values)]
    if finite.size < 400:
        return None
    threshold = otsu_threshold(finite)
    if threshold is None:
        return None

    bone = largest_component(np.nan_to_num(slice_values, nan=-np.inf) >= threshold)
    rows, columns = slice_values.shape
    required = max(MINIMUM_BONE_POINTS, int(rows * columns * MINIMUM_BONE_FRACTION))
    if int(bone.sum()) < required:
        return None

    row_index, column_index = np.nonzero(bone)
    bone_x = origin_x + column_index * step
    bone_y = origin_y + row_index * step
    centre_x = float(bone_x.mean())
    centre_y = float(bone_y.mean())

    dx = bone_x - centre_x
    dy = bone_y - centre_y
    radius = np.hypot(dx, dy)
    keep = radius > 1e-6
    if not keep.any():
        return None
    angle = np.arctan2(dy[keep], dx[keep]) % (2 * np.pi)
    sector = np.minimum((angle / (2 * np.pi) * SECTOR_COUNT).astype(int), SECTOR_COUNT - 1)

    medians = np.full(SECTOR_COUNT, np.nan)
    for index in range(SECTOR_COUNT):
        values = radius[keep][sector == index]
        if values.size:
            medians[index] = float(np.median(values))
    filled = np.isfinite(medians)
    if filled.sum() / SECTOR_COUNT < MINIMUM_FILLED_SECTOR_FRACTION:
        return None

    # Il settore vuoto più lungo è l'apertura della U: la curva parte da un capo dell'apertura e
    # finisce all'altro, invece di chiudersi in un anello.
    best_start, best_length = 0, 0
    current_start, current_length = 0, 0
    for offset in range(SECTOR_COUNT * 2):
        index = offset % SECTOR_COUNT
        if not filled[index]:
            if current_length == 0:
                current_start = index
            current_length += 1
            if current_length > best_length:
                best_length, best_start = current_length, current_start
        else:
            current_length = 0
    if best_length < MINIMUM_OPENING_SECTORS:
        return None

    first_sector = (best_start + best_length) % SECTOR_COUNT
    span = SECTOR_COUNT - best_length
    if span < 3:
        return None

    def smoothed(index):
        """Mediana sui tre settori vicini: un settore con pochi punti dà un raggio ballerino, e
        una curva a zigzag si corregge peggio di una curva liscia leggermente fuori posto."""
        neighbours = [
            medians[(index + offset) % SECTOR_COUNT]
            for offset in (-1, 0, 1)
            if np.isfinite(medians[(index + offset) % SECTOR_COUNT])
        ]
        return float(np.median(neighbours)) if neighbours else None

    points = []
    for index in range(point_count):
        position = index / (point_count - 1) * (span - 1)
        index_sector = (first_sector + int(round(position))) % SECTOR_COUNT
        value = smoothed(index_sector)
        if value is None:
            continue
        theta = (index_sector + 0.5) / SECTOR_COUNT * 2 * np.pi
        points.append(
            [centre_x + value * np.cos(theta), centre_y + value * np.sin(theta), vertical_mm]
        )
    if len(points) < 3:
        return None
    return np.asarray(points, dtype=np.float64)


# MARK: - Curva


def catmull_rom_polyline(control_points, subdivisions=SUBDIVISIONS_PER_SEGMENT):
    """Poligonale densa della spline e lunghezze cumulate.

    Catmull-Rom con tensione 0,5 e punti agli estremi duplicati per definire le tangenti iniziale e
    finale. La lunghezza non ha forma chiusa: si approssima, e duecento suddivisioni per segmento
    tengono l'errore sotto il decimo di millimetro, cioè meno di mezzo voxel.
    """
    points = np.asarray(control_points, dtype=np.float64)
    if points.shape[0] < 2:
        return points, np.zeros(points.shape[0])

    segments = points.shape[0] - 1
    total = segments * subdivisions
    steps = np.arange(total + 1, dtype=np.float64) / total * segments
    index = np.minimum(steps.astype(int), segments - 1)
    local = (steps - index)[:, None]

    def at(offset):
        return points[np.clip(index + offset, 0, points.shape[0] - 1)]

    p0, p1, p2, p3 = at(-1), at(0), at(1), at(2)
    t2 = local * local
    t3 = t2 * local
    dense = 0.5 * (
        2 * p1 + (p2 - p0) * local + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3
    )

    lengths = np.zeros(dense.shape[0])
    lengths[1:] = np.cumsum(np.linalg.norm(np.diff(dense, axis=0), axis=1))
    return dense, lengths


def arch_samples(dense, lengths, arc_lengths, up_axis):
    """Posizione, tangente e normale vestibolo-linguale alle lunghezze d'arco indicate.

    La tangente è per differenze centrali sulla poligonale, più stabile della derivata analitica
    vicino ai punti di controllo, dove la curvatura salta.
    """
    total = float(lengths[-1])
    targets = np.clip(np.asarray(arc_lengths, dtype=np.float64), 0.0, total)
    index = np.clip(np.searchsorted(lengths, targets, side="right") - 1, 0, dense.shape[0] - 2)

    span = lengths[index + 1] - lengths[index]
    local = np.where(span > 1e-12, (targets - lengths[index]) / np.maximum(span, 1e-12), 0.0)
    position = dense[index] + (dense[index + 1] - dense[index]) * local[:, None]

    before = dense[np.maximum(index - 1, 0)]
    after = dense[np.minimum(index + 2, dense.shape[0] - 1)]
    tangent = after - before
    tangent /= np.maximum(np.linalg.norm(tangent, axis=1, keepdims=True), 1e-12)

    normal = np.cross(tangent, up_axis)
    normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-12)
    return position, tangent, normal, targets


# MARK: - Campionamento del volume


class Volume:
    """Il volume caricato, con il solo mestiere di rispondere «che valore c'è in questo punto».

    I punti sono in millimetri nel riferimento **RAS** del file NIfTI, che è quello in cui OpenMRI
    tiene i volumi preparati: `+x` destra, `+y` avanti, `+z` verso la testa. I contratti del
    progetto parlano LPS — la conversione fra i due è `diag(−1, −1, 1)` — e qui si resta in RAS per
    non doverla fare due volte.
    """

    def __init__(self, path):
        image = nib.as_closest_canonical(nib.load(str(path)))
        self.data = np.asanyarray(image.dataobj, dtype=np.float32)
        self.affine = np.asarray(image.affine, dtype=np.float64)
        self.inverse = np.linalg.inv(self.affine)
        self.spacing = np.asarray(image.header.get_zooms()[:3], dtype=np.float64)
        header = image.header
        self.display_range = (float(header["cal_min"]), float(header["cal_max"]))
        sample = self.data.ravel()[:: max(1, self.data.size // 200_000)]
        self.background = float(np.percentile(sample, 1))

    @property
    def shape(self):
        return self.data.shape

    def world_bounds(self):
        """Gli estremi del volume in millimetri RAS, dai suoi otto vertici."""
        n = np.array(self.shape, dtype=np.float64) - 1
        corners = np.array(
            [[i * n[0], j * n[1], k * n[2]] for i in (0, 1) for j in (0, 1) for k in (0, 1)]
        )
        world = corners @ self.affine[:3, :3].T + self.affine[:3, 3]
        return world.min(axis=0), world.max(axis=0)

    def sample(self, points):
        """Valori interpolati linearmente nei punti indicati, `(n, 3)` in millimetri RAS.

        Fuori dal volume restituisce il fondo, non zero: su una CBCT l'aria è un valore negativo, e
        scrivere zero disegnerebbe una cornice chiara attorno all'anatomia.
        """
        points = np.asarray(points, dtype=np.float64)
        voxels = points @ self.inverse[:3, :3].T + self.inverse[:3, 3]
        return ndimage.map_coordinates(
            self.data,
            voxels.T,
            order=1,
            mode="constant",
            cval=self.background,
        )

    def axial_slice(self, vertical_mm, step=None):
        """Una fetta assiale campionata su griglia regolare, con la sua origine e il suo passo.

        Su griglia e non sui voxel: il volume può essere orientato comunque, e attraversare gli
        indici darebbe una fetta obliqua.
        """
        lower, upper = self.world_bounds()
        step = float(step or max(min(self.spacing[0], self.spacing[1]), 0.1))
        columns = int((upper[0] - lower[0]) / step) + 1
        rows = int((upper[1] - lower[1]) / step) + 1
        if columns < 2 or rows < 2 or columns * rows > 40_000_000:
            return None, None
        xs = lower[0] + np.arange(columns) * step
        ys = lower[1] + np.arange(rows) * step
        grid_x, grid_y = np.meshgrid(xs, ys)
        points = np.stack(
            [grid_x.ravel(), grid_y.ravel(), np.full(grid_x.size, float(vertical_mm))], axis=1
        )
        values = self.sample(points).reshape(rows, columns)
        return values, {
            "originMM": [float(lower[0]), float(lower[1])],
            "stepMM": step,
            "columns": columns,
            "rows": rows,
            "verticalMM": float(vertical_mm),
        }


# MARK: - Scelta della quota


def detect_arch(volume, vertical_mm=None, point_count=9, candidates=17):
    """La curva d'arcata: quella chiesta, o la migliore fra le quote candidate.

    Nell'applicazione Swift la quota la sceglie chi guarda, spostando il mirino. Qui non c'è
    ancora nessuno a sceglierla, quindi si prova una scala di quote e si tiene quella che dà
    l'arcata più solida — con la lunghezza dentro l'intervallo plausibile, perché un anello attorno
    al cranio e una U di dieci centimetri superano entrambi i criteri di forma, e solo uno dei due
    è un'arcata.
    """
    lower, upper = volume.world_bounds()
    if vertical_mm is not None:
        levels = [float(vertical_mm)]
    else:
        height = upper[2] - lower[2]
        levels = list(np.linspace(lower[2] + 0.15 * height, upper[2] - 0.15 * height, candidates))

    best = None
    for level in levels:
        values, grid = volume.axial_slice(level)
        if values is None:
            continue
        points = suggest_arch_points(
            values, grid["originMM"][0], grid["originMM"][1], grid["stepMM"], level, point_count
        )
        if points is None:
            continue
        dense, lengths = catmull_rom_polyline(points)
        length = float(lengths[-1])
        plausible = PLAUSIBLE_ARCH_LENGTH_MM[0] <= length <= PLAUSIBLE_ARCH_LENGTH_MM[1]
        score = length * (1.0 if plausible else 0.05)
        if best is None or score > best["score"]:
            best = {"score": score, "points": points, "verticalMM": float(level), "grid": grid}
    return best


def orient_curve(points):
    """Mette la curva in modo che parta dalla **destra del paziente**.

    Convenzione radiologica: la destra del paziente sta a sinistra dell'immagine. Con la curva
    orientata a caso, due panoramiche dello stesso paziente potrebbero uscire specchiate l'una
    rispetto all'altra, e non c'è modo di accorgersene guardandole.
    """
    points = np.asarray(points, dtype=np.float64)
    return points[::-1].copy() if points[0, 0] < points[-1, 0] else points


def outward_normals(position, normal):
    """Normali rivolte verso il **vestibolare**, cioè fuori dall'arcata.

    Il verso della normale segue quello di percorrenza della curva; senza questa correzione le
    sezioni trasversali uscirebbero specchiate, con il vestibolare a sinistra invece che a destra.
    """
    centre = position.mean(axis=0)
    outward = position - centre
    if float(np.sum(normal * outward)) < 0:
        return -normal
    return normal


# MARK: - Ricostruzioni


def build_panorama(volume, curve, options):
    """Lo slab curvo lungo l'arcata.

    La scala è **isotropa e la detta la larghezza**: le colonne coprono tutta la curva, quindi
    millimetri per pixel valgono `lunghezza / larghezza`, e l'altezza segue da lì. Con due scale
    diverse l'immagine sembra soltanto schiacciata, ma una misura verticale smette di essere
    confrontabile con una orizzontale.
    """
    dense, lengths = catmull_rom_polyline(curve["controlPointsMM"])
    total = float(lengths[-1])
    mm_per_pixel = float(options.get("mmPerPixel", 0.2))
    width = int(max(2, min(round(total / mm_per_pixel), 2400)))
    mm_per_pixel = total / width
    height_mm = float(options.get("heightMM", 80.0))
    height = int(max(2, min(round(height_mm / mm_per_pixel), 1600)))

    up = np.array([0.0, 0.0, 1.0])
    arc = np.linspace(0.0, total, width)
    position, _, normal, _ = arch_samples(dense, lengths, arc, up)
    normal = outward_normals(position, normal)

    vertical_centre = float(curve["verticalCentreMM"])
    thickness = float(options.get("slabThicknessMM", 20.0))
    step = float(max(min(volume.spacing), 0.05))
    slab_count = 1 if thickness <= 0 else int(min(max(1, round(thickness / step) + 1), MAXIMUM_SLAB_SAMPLES))
    offsets = (
        np.zeros(1)
        if slab_count <= 1
        else (np.arange(slab_count) - (slab_count - 1) / 2) * (thickness / (slab_count - 1))
    )

    # La colonna parte dall'alto: la prima riga è la più craniale, come nelle viste coronale e
    # sagittale, e scende di un pixel per volta.
    rows = (np.arange(height) - (height - 1) / 2) * mm_per_pixel

    # Scostamento vestibolo-linguale: sposta il **piano campionato**, non la curva.
    #
    # Serve perché una curva d'arcata è un'approssimazione: passa per i punti che si sono posati, e
    # i denti stanno un po' più fuori o un po' più dentro. Con uno slab spesso si vede tutto
    # sovrapposto e nulla con nitidezza; con uno slab sottile si vede una fetta sola, e per trovare
    # l'apice di una radice bisogna poter attraversare l'arcata in profondità. Positivo verso il
    # vestibolare, negativo verso il linguale.
    #
    # Le sezioni trasversali **non** lo ricevono, ed è voluto: sono larghe trenta millimetri e
    # contengono già tutto lo spessore, mentre spostarne il centro renderebbe due sezioni prese con
    # scostamenti diversi non confrontabili fra loro.
    depth = float(options.get("normalOffsetMM", 0.0))
    column_top = position + normal * depth
    column_top[:, 2] = vertical_centre

    maximum = options.get("projection", "maximum") == "maximum"
    image = np.empty((height, width), dtype=np.float32)

    # A blocchi di colonne: tutta l'immagine in una volta sarebbe larghezza × altezza × spessore
    # punti, cioè centinaia di megabyte di sole coordinate.
    block = max(1, int(2_000_000 / max(1, height * slab_count)))
    for start in range(0, width, block):
        stop = min(start + block, width)
        base = column_top[start:stop][:, None, :] - up[None, None, :] * rows[None, :, None]
        points = base[:, :, None, :] + normal[start:stop][:, None, None, :] * offsets[None, None, :, None]
        values = volume.sample(points.reshape(-1, 3)).reshape(stop - start, height, slab_count)
        column = values.max(axis=2) if maximum else values.mean(axis=2)
        image[:, start:stop] = column.T

    return image, {
        "widthPx": width,
        "heightPx": height,
        "mmPerPixel": mm_per_pixel,
        "arcLengthMM": total,
        "verticalCentreMM": vertical_centre,
        "slabThicknessMM": thickness,
        "slabSamples": slab_count,
        "projection": "maximum" if maximum else "average",
        "normalOffsetMM": depth,
    }


def build_sections(volume, curve, options):
    """Le sezioni perpendicolari alla curva: la vista su cui si giudica la cresta.

    Ogni sezione è un piano con l'asse orizzontale lungo la normale vestibolo-linguale e il
    verticale verso i piedi; la normale del piano risulta quindi la tangente alla curva, che è la
    definizione di sezione trasversale.
    """
    dense, lengths = catmull_rom_polyline(curve["controlPointsMM"])
    total = float(lengths[-1])
    interval = float(max(options.get("sectionIntervalMM", 2.0), 0.2))
    width_mm = float(options.get("sectionWidthMM", 32.0))
    height_mm = float(options.get("sectionHeightMM", 45.0))
    thickness = float(max(options.get("sectionThicknessMM", 1.0), 0.0))
    mm_per_pixel = float(options.get("sectionMmPerPixel", 0.15))

    width = int(max(2, round(width_mm / mm_per_pixel)))
    height = int(max(2, round(height_mm / mm_per_pixel)))
    count = int(max(2, round(total / interval) + 1))
    arc = np.linspace(0.0, total, count)

    up = np.array([0.0, 0.0, 1.0])
    position, tangent, normal, _ = arch_samples(dense, lengths, arc, up)
    normal = outward_normals(position, normal)

    vertical_centre = float(curve["verticalCentreMM"])
    step = float(max(min(volume.spacing), 0.05))
    slab_count = 1 if thickness <= 0 else int(min(max(1, round(thickness / step) + 1), 16))
    offsets = (
        np.zeros(1)
        if slab_count <= 1
        else (np.arange(slab_count) - (slab_count - 1) / 2) * (thickness / (slab_count - 1))
    )

    columns = (np.arange(width) - (width - 1) / 2) * mm_per_pixel
    rows = (np.arange(height) - (height - 1) / 2) * mm_per_pixel

    images = np.empty((count, height, width), dtype=np.float32)
    for index in range(count):
        centre = np.array([position[index, 0], position[index, 1], vertical_centre])
        plane = (
            centre[None, None, :]
            + normal[index][None, None, :] * columns[None, :, None]
            - up[None, None, :] * rows[:, None, None]
        )
        stack = plane[None, :, :, :] + tangent[index][None, None, None, :] * offsets[:, None, None, None]
        values = volume.sample(stack.reshape(-1, 3)).reshape(slab_count, height, width)
        images[index] = values.mean(axis=0)

    # Dove ciascuna sezione taglia, in millimetri: i due capi del segmento sulla fetta assiale.
    # Senza, chi guarda la sezione non sa da che parte dell'arcata provenga, e la striscia di
    # sezioni resta un elenco invece che un percorso.
    half = np.array([width * mm_per_pixel / 2, width * mm_per_pixel / 2])
    cut_ends = [
        [
            [
                float(position[index, 0] - normal[index, 0] * half[0]),
                float(position[index, 1] - normal[index, 1] * half[1]),
            ],
            [
                float(position[index, 0] + normal[index, 0] * half[0]),
                float(position[index, 1] + normal[index, 1] * half[1]),
            ],
        ]
        for index in range(count)
    ]

    geometry = {
        "count": count,
        "intervalMM": float(total / (count - 1)),
        "widthPx": width,
        "heightPx": height,
        "mmPerPixel": mm_per_pixel,
        "widthMM": width * mm_per_pixel,
        "heightMM": height * mm_per_pixel,
        "thicknessMM": thickness,
        "arcLengthsMM": [float(value) for value in arc],
        "cutEndsMM": cut_ends,
    }
    return images, geometry


# MARK: - Uscita


def window(values, low=1.0, high=99.7):
    """Finestra di visualizzazione dai percentili, non dagli estremi.

    Un solo voxel di metallo — e in bocca ce n'è quasi sempre — porterebbe il massimo a un valore
    che schiaccia tutto il resto in un grigio uniforme.
    """
    finite = values[np.isfinite(values)]
    if finite.size == 0:
        return 0.0, 1.0
    sample = finite.ravel()[:: max(1, finite.size // 500_000)]
    lo, hi = np.percentile(sample, [low, high])
    if not hi > lo:
        hi = lo + 1.0
    return float(lo), float(hi)


def to_bytes(values, lo, hi):
    """Da valori grigi a otto bit, con la finestra indicata."""
    scaled = (np.asarray(values, dtype=np.float32) - lo) / max(hi - lo, 1e-6)
    return np.clip(scaled * 255.0, 0, 255).astype(np.uint8)


def write_png(array, path):
    """PNG con SimpleITK, che è già nell'ambiente: nessuna dipendenza nuova per scrivere immagini."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    sitk.WriteImage(sitk.GetImageFromArray(np.ascontiguousarray(array)), str(path))


def build(volume_path, output_dir, options=None):
    """Tutto il lavoro: rileva l'arcata, ricostruisce panoramica e sezioni, scrive le immagini."""
    options = dict(options or {})
    output = Path(output_dir)
    volume = Volume(volume_path)

    control_points = options.get("controlPointsMM")
    if control_points:
        points = orient_curve(np.asarray(control_points, dtype=np.float64))
        vertical = float(options.get("archVerticalMM", float(points[:, 2].mean())))
        detection = {"points": points, "verticalMM": vertical, "grid": None}
    else:
        detection = detect_arch(volume, options.get("archVerticalMM"), int(options.get("archPointCount", 9)))
        if detection is None:
            raise ValueError(
                "No dental arch was recognised in this volume. "
                "Set the axial level by hand, or give the curve points."
            )
        detection["points"] = orient_curve(detection["points"])

    curve = {
        "controlPointsMM": detection["points"],
        "verticalCentreMM": float(options.get("verticalCentreMM", detection["verticalMM"])),
    }

    panorama, panorama_geometry = build_panorama(volume, curve, options)
    lo, hi = window(panorama)
    write_png(to_bytes(panorama, lo, hi), output / "panorama.png")

    sections, section_geometry = build_sections(volume, curve, options)
    # Una finestra sola per tutte le sezioni: con una finestra per immagine, due sezioni vicine
    # sembrerebbero avere densità ossee diverse solo perché il contrasto è stato riscalato.
    section_lo, section_hi = window(sections)
    for index in range(sections.shape[0]):
        write_png(to_bytes(sections[index], section_lo, section_hi), output / f"sections/{index:04d}.png")

    axial_geometry = detection.get("grid")
    if axial_geometry is None:
        _, axial_geometry = volume.axial_slice(detection["verticalMM"])
    if axial_geometry is not None:
        values, _ = volume.axial_slice(detection["verticalMM"])
        axial_lo, axial_hi = window(values)
        # Convenzione radiologica: la destra del paziente a sinistra dell'immagine, l'anteriore in
        # alto. In RAS `+x` è destra e `+y` è avanti, quindi entrambi gli assi vanno rovesciati.
        write_png(to_bytes(values[::-1, ::-1], axial_lo, axial_hi), output / "axial.png")

        # La curva in coordinate immagine, calcolata qui e non nell'interfaccia: la conversione
        # fra millimetri e pixel è geometria, e tenerla in due posti è il modo di farne divergere
        # uno dei due senza accorgersene.
        def to_pixels(points):
            columns = axial_geometry["columns"]
            rows = axial_geometry["rows"]
            step = axial_geometry["stepMM"]
            origin = axial_geometry["originMM"]
            return [
                [
                    float(columns - 1 - (point[0] - origin[0]) / step),
                    float(rows - 1 - (point[1] - origin[1]) / step),
                ]
                for point in points
            ]

        dense, _ = catmull_rom_polyline(detection["points"])
        axial_geometry["curvePixels"] = to_pixels(dense[:: max(1, len(dense) // 240)])
        axial_geometry["controlPixels"] = to_pixels(detection["points"])
        axial_geometry["orientation"] = "radiological"

        # Dove taglia ciascuna sezione, sulla stessa immagine. Chi guarda una sezione vede così da
        # che parte dell'arcata viene, e le tre viste dicono la stessa cosa invece di tre cose
        # vicine.
        axial_geometry["cutPixels"] = [
            [point for end in to_pixels(ends) for point in end]
            for ends in section_geometry["cutEndsMM"]
        ]

        # La trasformazione **inversa**, in forma di affine esplicita: serve a chi trascina un punto
        # di controllo sull'immagine e deve dire in millimetri dove l'ha portato. Scriverla qui e
        # non nell'interfaccia è la stessa ragione di `to_pixels`: una conversione tenuta in due
        # posti è una conversione che prima o poi diverge, e lo fa in silenzio.
        #
        #   X = x[0]·colonna + x[1]·riga + x[2]      Y = y[0]·colonna + y[1]·riga + y[2]
        step = axial_geometry["stepMM"]
        origin = axial_geometry["originMM"]
        axial_geometry["worldFromPixel"] = {
            "x": [-step, 0.0, origin[0] + (axial_geometry["columns"] - 1) * step],
            "y": [0.0, -step, origin[1] + (axial_geometry["rows"] - 1) * step],
            "z": detection["verticalMM"],
        }
        lower, upper = volume.world_bounds()
        axial_geometry["levelRangeMM"] = [float(lower[2]), float(upper[2])]

    return {
        "curve": {
            "controlPointsMM": [[float(v) for v in point] for point in detection["points"]],
            "archVerticalMM": detection["verticalMM"],
            "verticalCentreMM": curve["verticalCentreMM"],
            "automatic": not bool(control_points),
        },
        "panorama": {"file": "panorama.png", **panorama_geometry, "window": [lo, hi]},
        "sections": {
            "directory": "sections",
            **section_geometry,
            "window": [section_lo, section_hi],
        },
        "axial": ({"file": "axial.png", **axial_geometry} if axial_geometry is not None else None),
        "volume": {
            "dimensions": [int(v) for v in volume.shape],
            "voxelMM": [float(v) for v in volume.spacing],
        },
        # In inglese perché finiscono a schermo: l'interfaccia parla la lingua dell'originale,
        # la prosa del progetto resta italiana.
        "notes": [
            "The panoramic view is a reconstructed surface, not a radiograph. A distance measured "
            "on it is a distance between two points of that surface; for the distance between two "
            "structures, use a cross-section, where the plane is flat.",
            "The arch is found by a heuristic. Check the curve on the axial slice before trusting "
            "the cross-sections.",
        ],
    }


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("Uso: dental_panorama.py <volume.nii.gz> <cartella> [opzioni.json]", file=sys.stderr)
        return 2
    options = {}
    if len(argv) > 3 and argv[3]:
        # Prima come JSON, poi come percorso a un file: un JSON lungo passato come argomento
        # farebbe fallire il controllo sull'esistenza del file con un errore che non lo dice.
        try:
            options = json.loads(argv[3])
        except json.JSONDecodeError:
            options = json.loads(Path(argv[3]).read_text())
    result = build(argv[1], argv[2], options)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
