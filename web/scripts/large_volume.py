"""Riduce una CBCT troppo grande per il motore, senza riempire la memoria.

# Il difetto che toglie

OpenMRI rifiutava i volumi oltre 2·512³ voxel con «The volume is too large». È un tetto pensato
per la risonanza, e serve a non esaurire la memoria: il volume viene letto per intero e
ricampionato in virgola mobile, otto byte per voxel. Una CBCT dentale ad alta risoluzione — un
ottavo di millimetro su un campo di dodici centimetri, cioè 960×960×720 — lo supera di due volte e
mezza, e non si apriva affatto.

# Che cosa fa

Riduce per blocchi interi — 2×2×2, 3×3×3 — facendone la media, un piano di blocchi alla volta, a
partire dai valori grezzi a 16 bit: la memoria che serve è quella del volume grezzo più quella del
volume ridotto, invece di otto byte per voxel. Il risultato prende poi la strada di sempre, che lo
porta comunque a 320 voxel per asse per il visore: a quella risoluzione la riduzione per blocchi
non toglie niente che il visore avrebbe mostrato.

La geometria resta esatta (contratto 1 di docs/architecture.md): ogni voxel nuovo sta al centro del
suo blocco, e il passo è quello originale moltiplicato per il fattore. Ai bordi si perde meno di un
blocco — meno di mezzo millimetro su una CBCT.
"""

import math

import nibabel as nib
import numpy as np

#: Lo stesso tetto di OpenMRI: sotto, il volume prende la strada di sempre.
LIMIT = 512**3 * 2


def reduction_factor(shape, limit=LIMIT):
    """Il fattore intero più piccolo che porta il volume sotto il tetto; 1 se ci sta già."""
    shape = np.array(shape[:3], dtype=np.int64)
    if int(np.prod(shape)) <= limit:
        return 1
    factor = max(2, math.ceil((int(np.prod(shape)) / limit) ** (1 / 3)))
    while int(np.prod(shape // factor)) > limit:
        factor += 1
    return factor


def reduce_large_volume(image, limit=LIMIT):
    """Il volume stesso se sta sotto il tetto; altrimenti la sua media per blocchi interi."""
    factor = reduction_factor(image.shape, limit)
    if factor == 1:
        return image

    proxy = image.dataobj
    # I valori grezzi, come li ha scritti il convertitore: interi a 16 bit, non otto byte per
    # voxel. La scala si applica dopo, sul volume già ridotto.
    raw = np.asanyarray(proxy.get_unscaled() if hasattr(proxy, "get_unscaled") else proxy)
    nx, ny, nz = (np.array(raw.shape[:3]) // factor) * factor
    reduced = np.empty((nx // factor, ny // factor, nz // factor), dtype=np.float32)
    for k in range(0, nz, factor):
        slab = raw[:nx, :ny, k : k + factor].astype(np.float32)
        blocks = slab.reshape(nx // factor, factor, ny // factor, factor, factor)
        reduced[:, :, k // factor] = blocks.mean(axis=(1, 3, 4))

    slope = getattr(proxy, "slope", 1.0)
    inter = getattr(proxy, "inter", 0.0)
    if slope is not None and np.isfinite(slope) and slope not in (0, 1):
        reduced *= np.float32(slope)
    if inter is not None and np.isfinite(inter) and inter != 0:
        reduced += np.float32(inter)

    affine = np.array(image.affine, dtype=np.float64)
    center = np.full(3, (factor - 1) / 2)
    moved = affine.copy()
    moved[:3, 3] = affine[:3, :3] @ center + affine[:3, 3]
    moved[:3, :3] = affine[:3, :3] * factor
    return nib.Nifti1Image(reduced, moved)
