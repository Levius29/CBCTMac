"""Prove della riduzione per blocchi delle CBCT oltre il tetto del motore.

Il difetto che sorvegliano: una CBCT ad alta risoluzione veniva rifiutata con «The volume is too
large». Ridurla non deve però spostarla né cambiarne i valori: ogni voxel nuovo deve stare al
centro del suo blocco e valere la media dei suoi, con la scala del convertitore applicata.
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

import nibabel as nib
import numpy as np

spec = importlib.util.spec_from_file_location(
    "large_volume", Path(__file__).resolve().parents[1] / "scripts/large_volume.py"
)
large = importlib.util.module_from_spec(spec)
spec.loader.exec_module(large)


def saved(data, affine, slope=1.0, inter=0.0):
    """Il volume passato per un file .nii.gz, come lo scrive dcm2niix: interi e scala a parte."""
    image = nib.Nifti1Image(data, affine)
    image.header.set_slope_inter(slope, inter)
    folder = tempfile.mkdtemp()
    path = Path(folder) / "volume.nii.gz"
    nib.save(image, str(path))
    return nib.load(str(path))


class LargeVolumeTests(unittest.TestCase):
    def test_a_volume_under_the_limit_is_left_alone(self):
        image = saved(np.zeros((4, 4, 4), dtype=np.int16), np.eye(4))
        self.assertIs(large.reduce_large_volume(image, limit=64), image)

    def test_the_factor_is_the_smallest_that_fits(self):
        self.assertEqual(large.reduction_factor((960, 960, 720)), 2)
        # 2000×2000×1000: con 2 resterebbero 500 milioni di voxel, con 3 sono 148.
        self.assertEqual(large.reduction_factor((2000, 2000, 1000)), 3)
        self.assertEqual(large.reduction_factor((10, 10, 10), limit=1000), 1)
        self.assertEqual(large.reduction_factor((10, 10, 10), limit=999), 2)

    def test_values_are_the_block_means_with_the_scale_applied(self):
        data = np.arange(6 * 4 * 4, dtype=np.int16).reshape((6, 4, 4))
        image = saved(data, np.eye(4), slope=2.0, inter=-1000.0)
        reduced = large.reduce_large_volume(image, limit=47)
        self.assertEqual(reduced.shape, (3, 2, 2))
        expected = data.reshape(3, 2, 2, 2, 2, 2).mean(axis=(1, 3, 5)) * 2.0 - 1000.0
        np.testing.assert_allclose(np.asarray(reduced.dataobj), expected, rtol=1e-6)

    def test_each_new_voxel_sits_at_the_centre_of_its_block(self):
        spacing = np.diag([0.125, 0.125, 0.125, 1.0])
        spacing[:3, 3] = [-10.0, -20.0, 30.0]
        image = saved(np.ones((8, 8, 8), dtype=np.int16), spacing)
        reduced = large.reduce_large_volume(image, limit=64)
        self.assertEqual(reduced.shape, (4, 4, 4))
        np.testing.assert_allclose(reduced.header.get_zooms()[:3], (0.25, 0.25, 0.25))
        # Il primo blocco copre i voxel 0 e 1: il suo centro sta a mezzo voxel originale.
        first = reduced.affine @ np.array([0, 0, 0, 1.0])
        np.testing.assert_allclose(first[:3], [-10.0 + 0.0625, -20.0 + 0.0625, 30.0 + 0.0625])

    def test_the_field_of_view_is_kept_up_to_one_block(self):
        image = saved(np.ones((9, 9, 9), dtype=np.int16), np.eye(4))
        reduced = large.reduce_large_volume(image, limit=100)
        self.assertEqual(reduced.shape, (4, 4, 4))
        extent = np.array(reduced.shape) * np.array(reduced.header.get_zooms()[:3])
        self.assertTrue(np.all(9 - extent < 2))


if __name__ == "__main__":
    unittest.main()
