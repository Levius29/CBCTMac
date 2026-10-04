"""Costruisce il volume di una serie DICOM quando dcm2niix si rifiuta.

# Perché esiste

dcm2niix è il convertitore di OpenMRI, ed è ottimo: legge quasi tutto. Quasi. Sulla prima CBCT
vera di chi usa il programma — una serie esportata come «Volume riformattato», un file per fetta —
si è fermato, e l'importazione con lui: «The converter could not build a volume». Un convertitore
solo è un punto in cui tutto si ferma. Questo è il secondo: entra in gioco solo quando il primo ha
già detto di no.

# Come lo fa

Come lo faceva 3DMED, con le stesse regole (docs/architecture.md):

- **le fette si ordinano per proiezione della posizione sulla normale**, mai per InstanceNumber,
  che su alcuni apparecchi è semplicemente sbagliato (contratto 2);
- le coordinate sono quelle del paziente in millimetri, LPS nel DICOM; il NIfTI le vuole RAS, e il
  passaggio è un cambio di segno su x e y (contratto 1);
- il rescale si applica una volta, quello della prima fetta, e una serie che ne dichiara di diversi
  si rifiuta invece di cucire insieme scale diverse;
- una serie che **non è un volume** — fette con orientamenti diversi, come le sezioni esportate
  lungo l'arcata — si rifiuta dicendolo, invece di impilarle in un volume che non esiste.

Decodifica ciò che decodifica pydicom: non compresso e RLE sempre, JPEG, JPEG-LS e JPEG 2000 se
nel Python ci sono i plugin pylibjpeg — e nell'app del Mac ci sono.
"""

import nibabel as nib
import numpy as np
import pydicom

#: Due fette con la normale che differisce più di così non stanno nello stesso volume.
ORIENTATION_TOLERANCE = 1e-3
#: Quanto il passo fra le fette può variare prima che impilarle deformi l'anatomia.
SPACING_TOLERANCE = 0.05


def _vector(values, count):
    values = [float(v) for v in values]
    if len(values) < count:
        raise ValueError("a geometry attribute is incomplete")
    return np.array(values[:count])


def _frames(paths):
    """Ogni fetta come (posizione, orientamento, spaziatura, pixel, slope, intercept)."""
    frames = []
    for path in paths:
        ds = pydicom.dcmread(str(path), force=True)
        if "PixelData" not in ds:
            continue
        count = int(getattr(ds, "NumberOfFrames", 1) or 1)
        pixels = ds.pixel_array
        if count == 1:
            pixels = pixels[np.newaxis]
        shared = (getattr(ds, "SharedFunctionalGroupsSequence", None) or [None])[0]
        groups = getattr(ds, "PerFrameFunctionalGroupsSequence", None) or [None] * count

        def find(group, macro, name):
            for holder in (group, shared):
                item = (getattr(holder, macro, None) or [None])[0] if holder is not None else None
                if item is not None and name in item:
                    return item[name].value
            return getattr(ds, name, None)

        for index in range(count):
            group = groups[index] if index < len(groups) else None
            orientation = find(group, "PlaneOrientationSequence", "ImageOrientationPatient")
            spacing = find(group, "PixelMeasuresSequence", "PixelSpacing")
            position = find(group, "PlanePositionSequence", "ImagePositionPatient")
            slope = find(group, "PixelValueTransformationSequence", "RescaleSlope")
            intercept = find(group, "PixelValueTransformationSequence", "RescaleIntercept")
            if orientation is None or spacing is None:
                raise ValueError("the files do not declare orientation and pixel spacing")
            orientation = _vector(orientation, 6)
            if position is None or (count > 1 and group is None):
                # Multiframe senza gruppi funzionali: una posizione, il resto si deduce.
                origin = getattr(ds, "ImagePositionPatient", None)
                step = getattr(ds, "SpacingBetweenSlices", None) or getattr(ds, "SliceThickness", None)
                if origin is None or not step:
                    raise ValueError("the files do not declare where each slice is")
                normal = np.cross(orientation[:3], orientation[3:])
                position = _vector(origin, 3) + normal * float(step) * index
            frames.append(
                (
                    _vector(position, 3),
                    orientation,
                    _vector(spacing, 2),
                    pixels[index],
                    float(slope) if slope is not None else 1.0,
                    float(intercept) if intercept is not None else 0.0,
                )
            )
    if len(frames) < 2:
        raise ValueError("a volume needs at least two slices")
    return frames


def build_volume(paths, output):
    """Scrive il volume NIfTI della serie in `output` e ne restituisce il percorso."""
    frames = _frames(paths)

    orientation = frames[0][1]
    for _, other, *_ in frames[1:]:
        if np.max(np.abs(other - orientation)) > ORIENTATION_TOLERANCE:
            raise ValueError(
                "the slices have different orientations — for example cross-sections along the "
                "arch — so they do not form a volume; export the axial volume instead"
            )
    rows, columns = frames[0][3].shape
    if any(frame[3].shape != (rows, columns) for frame in frames):
        raise ValueError("the slices do not all have the same size")
    row_direction = orientation[:3] / np.linalg.norm(orientation[:3])
    column_direction = orientation[3:] / np.linalg.norm(orientation[3:])
    normal = np.cross(row_direction, column_direction)

    # Contratto 2: l'ordine è quello della posizione proiettata sulla normale.
    frames.sort(key=lambda frame: float(frame[0] @ normal))
    heights = np.array([float(frame[0] @ normal) for frame in frames])
    steps = np.diff(heights)
    if np.any(steps <= 1e-6):
        raise ValueError("two slices sit at the same position: the files mix more than one series")
    step = float(np.median(steps))
    if np.max(np.abs(steps - step)) > SPACING_TOLERANCE * step:
        raise ValueError("the slices are not evenly spaced, and stacking them would distort the anatomy")

    slope, intercept = frames[0][4], frames[0][5]
    if any(abs(f[4] - slope) > 1e-9 or abs(f[5] - intercept) > 1e-9 for f in frames):
        raise ValueError("the slices declare different rescale values")

    # Il tipo più stretto che contiene i valori: interi a 16 bit per una CBCT con il solo
    # spostamento d'intercetta, virgola mobile se c'è una pendenza. Il volume si riempie una fetta
    # alla volta, così la memoria resta quella del risultato — su 732 fette da 800×800 impilarle e
    # poi convertirle costava tre gigabyte.
    integral = slope == 1.0 and float(intercept).is_integer()
    if integral:
        offset = int(intercept)
        low = min(int(frame[3].min()) for frame in frames) + offset
        high = max(int(frame[3].max()) for frame in frames) + offset
        fits = np.iinfo(np.int16).min <= low and high <= np.iinfo(np.int16).max
        dtype = np.int16 if fits else np.int32
    else:
        dtype = np.float32
    # NIfTI vuole l'indice di colonna per primo: (colonne, righe, fette).
    data = np.empty((columns, rows, len(frames)), dtype=dtype)
    for k, frame in enumerate(frames):
        values = frame[3].T
        if integral:
            data[:, :, k] = values.astype(np.int32) + offset
        else:
            data[:, :, k] = values.astype(np.float64) * slope + intercept

    row_spacing, column_spacing = frames[0][2]
    lps = np.eye(4)
    lps[:3, 0] = row_direction * column_spacing
    lps[:3, 1] = column_direction * row_spacing
    lps[:3, 2] = normal * step
    lps[:3, 3] = frames[0][0]
    affine = np.diag([-1.0, -1.0, 1.0, 1.0]) @ lps

    image = nib.Nifti1Image(data, affine)
    image.set_qform(affine, code=1)
    image.set_sform(affine, code=1)
    nib.save(image, str(output))
    return output
