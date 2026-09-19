import importlib.util
from pathlib import Path
import unittest
import numpy as np
import SimpleITK as sitk
spec = importlib.util.spec_from_file_location('register_mri', Path(__file__).resolve().parents[1]/'scripts/register_mri.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class RegistrationTests(unittest.TestCase):
    def test_ras_lps_direction_and_center(self):
        t = sitk.Euler3DTransform()
        t.SetCenter((11., -20., 5.))
        t.SetRotation(.04, -.06, .1)
        t.SetTranslation((4., -9., 2.))
        p = np.array([30., -15., 12., 1.])
        expected = np.array(t.TransformPoint((-p[0],-p[1],p[2]))) * [-1,-1,1]
        np.testing.assert_allclose((m.ras_matrix(t) @ p)[:3],expected,atol=1e-9)

    def test_recovers_rigid_motion_and_preserves_fixed_grid(self):
        z,y,x = np.mgrid[:48,:56,:52]
        data = np.zeros(x.shape, dtype=np.float32)
        for cx,cy,cz,sd,amp in [(19,25,20,8,110),(30,31,25,4,70),(15,17,29,3,140),(32,19,16,5,80)]:
            data += amp*np.exp(-((x-cx)**2+(y-cy)**2+(z-cz)**2)/(2*sd**2))
        fixed = sitk.GetImageFromArray(data)
        fixed.SetSpacing((1.3,1.1,1.5))
        fixed.SetOrigin((-30.,-35.,-32.))
        expected = sitk.Euler3DTransform()
        expected.SetCenter(fixed.TransformContinuousIndexToPhysicalPoint((26.,28.,24.)))
        expected.SetRotation(.025,-.035,.05)
        expected.SetTranslation((3.,-2.,2.5))
        moving = sitk.Resample(fixed,fixed,expected.GetInverse(),sitk.sitkLinear,0.)
        t, aligned, overlap = m.register(fixed,moving)
        for index in [(26.,28.,24.),(18.,20.,18.),(32.,32.,30.)]:
            p = fixed.TransformContinuousIndexToPhysicalPoint(index)
            self.assertLess(np.linalg.norm(np.array(t.TransformPoint(p))-expected.TransformPoint(p)),1.0)
        self.assertEqual(aligned.GetOrigin(),fixed.GetOrigin())
        self.assertEqual(aligned.GetSize(),fixed.GetSize())
        self.assertEqual(aligned.GetDirection(),fixed.GetDirection())
        self.assertGreater(overlap,.7)
        before = np.mean((data-sitk.GetArrayFromImage(moving))**2)
        after = np.mean((data-sitk.GetArrayFromImage(aligned))**2)
        self.assertLess(after,before*.15)

    def test_constant_and_small_volumes_rejected(self):
        for size in [(16,16,16),(8,16,16)]:
            with self.assertRaises(ValueError): m.register(sitk.Image(size,sitk.sitkFloat32),sitk.Image(size,sitk.sitkFloat32))
