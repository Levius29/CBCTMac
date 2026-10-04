"""Prove del convertitore di riserva, quello che entra quando dcm2niix si rifiuta.

L'arbitro è dcm2niix stesso: su ogni serie che sa convertire, il convertitore di riserva deve dare
lo stesso volume con la stessa geometria. Se i due divergono, uno dei due sbaglia — ed è il nostro,
fino a prova contraria. Poi le serie che dcm2niix non vede mai qui, e che il nostro deve rifiutare
dicendo perché: sezioni con orientamenti diversi, fette doppie, passo irregolare.

E infine l'innesto: un'importazione intera in cui dcm2niix fallisce deve finire lo stesso.
"""

import hashlib
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile
from pathlib import Path

import nibabel as nib
import numpy as np
from pydicom.dataset import Dataset, FileDataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import (
    CTImageStorage,
    EnhancedCTImageStorage,
    ExplicitVRLittleEndian,
    JPEG2000Lossless,
    RLELossless,
    generate_uid,
)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("dicom_volume", ROOT / "scripts/dicom_volume.py")
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)

COLUMNS, ROWS, SLICES = 7, 5, 6


def volume():
    """Ogni voxel dice dove sta: 100·fetta + 10·riga + colonna."""
    k, j, i = np.meshgrid(np.arange(SLICES), np.arange(ROWS), np.arange(COLUMNS), indexing="ij")
    return (100 * k + 10 * j + i).astype(np.int16)


def rotation_x(degrees):
    angle = np.radians(degrees)
    return np.array([[1, 0, 0], [0, np.cos(angle), -np.sin(angle)], [0, np.sin(angle), np.cos(angle)]])


def write_series(folder, *, tilt=0.0, slope=1.0, intercept=-1000.0, compress=None,
                 orientations=None, positions=None, name_order=None, data=None):
    """Una fetta per file, scritte e numerate nell'ordine sbagliato di proposito."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    rotate = rotation_x(tilt)
    row_direction = rotate @ np.array([1.0, 0, 0])
    column_direction = rotate @ np.array([0, 1.0, 0])
    normal = np.cross(row_direction, column_direction)
    origin = np.array([-12.0, 8.0, 40.0])
    study, series = generate_uid(), generate_uid()
    data = volume() if data is None else data
    slices, rows, columns = data.shape
    order = name_order or list(reversed(range(slices)))
    for written, k in enumerate(order):
        meta = FileMetaDataset()
        meta.MediaStorageSOPClassUID = CTImageStorage
        meta.MediaStorageSOPInstanceUID = generate_uid()
        meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds = FileDataset(None, {}, file_meta=meta, preamble=b"\0" * 128)
        ds.SOPClassUID = CTImageStorage
        ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
        ds.StudyInstanceUID, ds.SeriesInstanceUID = study, series
        ds.Modality = "CT"
        ds.PatientName = "RISERVA^PROVA"
        ds.InstanceNumber = written + 1
        ds.Rows, ds.Columns = rows, columns
        ds.PixelSpacing = [0.5, 0.25]
        ds.SliceThickness = 0.75
        iop = orientations[k] if orientations else [*row_direction, *column_direction]
        ds.ImageOrientationPatient = [float(v) for v in iop]
        position = positions[k] if positions else origin + normal * 0.75 * k
        ds.ImagePositionPatient = [float(v) for v in position]
        ds.SamplesPerPixel = 1
        ds.PhotometricInterpretation = "MONOCHROME2"
        ds.BitsAllocated, ds.BitsStored, ds.HighBit = 16, 16, 15
        ds.PixelRepresentation = 1
        ds.RescaleSlope, ds.RescaleIntercept = slope, intercept
        ds.PixelData = data[k].tobytes()
        if compress:
            ds.compress(compress, data[k], generate_instance_uid=False)
        ds.save_as(folder / f"ReformattedSlice{written + 1}.dcm", enforce_file_format=True)
    return sorted(folder.glob("*.dcm"))


def dcm2niix():
    binary = Path(sys.executable).with_name("dcm2niix")
    return str(binary) if binary.exists() else shutil.which("dcm2niix")


class ReserveConverterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def convert(self, files):
        return nib.load(str(converter.build_volume(files, self.root / "riserva.nii.gz")))

    def test_slices_go_in_by_position_not_by_name_or_number(self):
        image = self.convert(write_series(self.root / "serie"))
        data = np.asarray(image.dataobj)
        self.assertEqual(data.shape, (COLUMNS, ROWS, SLICES))
        expected = np.transpose(volume().astype(np.int32) - 1000, (2, 1, 0))
        np.testing.assert_array_equal(data, expected)
        self.assertEqual(data.dtype, np.int16)

    def test_a_slope_gives_floating_point_values(self):
        image = self.convert(write_series(self.root / "serie", slope=0.5, intercept=-1000.5))
        data = np.asarray(image.dataobj)
        self.assertEqual(data.dtype, np.float32)
        self.assertAlmostEqual(float(data[3, 2, 4]), (100 * 4 + 10 * 2 + 3) * 0.5 - 1000.5, places=3)

    def test_it_agrees_with_dcm2niix_where_dcm2niix_works(self):
        binary = dcm2niix()
        if not binary:
            self.skipTest("dcm2niix non c'è")
        for tilt in (0.0, 17.0):
            with self.subTest(tilt=tilt):
                files = write_series(self.root / f"serie-{tilt}", tilt=tilt)
                out = self.root / f"dcm2niix-{tilt}"
                out.mkdir()
                subprocess.run([binary, "-z", "y", "-b", "n", "-f", "volume", "-o", str(out),
                                str(files[0].parent)], capture_output=True, check=True)
                theirs = nib.as_closest_canonical(nib.load(str(next(out.glob("*.nii.gz")))))
                ours = nib.as_closest_canonical(self.convert(files))
                self.assertEqual(ours.shape, theirs.shape)
                np.testing.assert_allclose(np.asarray(ours.dataobj), theirs.get_fdata(), atol=1e-3)
                np.testing.assert_allclose(ours.affine, theirs.affine, atol=1e-3)

    def test_compressed_slices_are_read_too(self):
        image = self.convert(write_series(self.root / "serie", compress=RLELossless))
        self.assertEqual(int(np.asarray(image.dataobj)[6, 4, 5]), 100 * 5 + 10 * 4 + 6 - 1000)

    def test_jpeg_2000_slices_are_read_when_the_decoders_are_there(self):
        # Nell'app del Mac i decodificatori ci sono sempre: Tools/make-mac-app.sh li mette dentro.
        # Fette di dimensioni vere: sotto i 32 pixel il codificatore JPEG 2000 si rifiuta.
        k, j, i = np.meshgrid(np.arange(4), np.arange(48), np.arange(64), indexing="ij")
        larger = (100 * k + 10 * (j % 9) + i % 10).astype(np.int16)
        try:
            files = write_series(self.root / "serie", compress=JPEG2000Lossless, data=larger)
        except (RuntimeError, NotImplementedError, ValueError) as missing:
            self.skipTest(f"manca il codificatore JPEG 2000: {missing}")
        data = np.asarray(self.convert(files).dataobj)
        np.testing.assert_array_equal(data, np.transpose(larger.astype(np.int32) - 1000, (2, 1, 0)))

    def test_cross_sections_along_the_arch_are_refused_with_the_reason(self):
        orientations = [[1, 0, 0, 0, np.cos(a), np.sin(a)] for a in np.radians(np.arange(SLICES) * 15)]
        with self.assertRaisesRegex(ValueError, "different orientations"):
            self.convert(write_series(self.root / "serie", orientations=orientations))

    def test_two_slices_in_the_same_place_are_refused(self):
        positions = [np.array([0.0, 0.0, 0.75 * min(k, 3)]) for k in range(SLICES)]
        with self.assertRaisesRegex(ValueError, "same position"):
            self.convert(write_series(self.root / "serie", positions=positions))

    def test_uneven_spacing_is_refused(self):
        heights = [0.0, 0.75, 1.5, 2.25, 4.0, 4.75]
        positions = [np.array([0.0, 0.0, h]) for h in heights]
        with self.assertRaisesRegex(ValueError, "evenly spaced"):
            self.convert(write_series(self.root / "serie", positions=positions))

    def test_an_enhanced_multiframe_file_is_a_volume_too(self):
        meta = FileMetaDataset()
        meta.MediaStorageSOPClassUID = EnhancedCTImageStorage
        meta.MediaStorageSOPInstanceUID = generate_uid()
        meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds = FileDataset(None, {}, file_meta=meta, preamble=b"\0" * 128)
        ds.SOPClassUID, ds.SOPInstanceUID = EnhancedCTImageStorage, meta.MediaStorageSOPInstanceUID
        ds.Modality = "CT"
        ds.Rows, ds.Columns, ds.NumberOfFrames = ROWS, COLUMNS, SLICES
        ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME2"
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 16, 15, 1
        measures, orientation, transform = Dataset(), Dataset(), Dataset()
        measures.PixelSpacing = [0.5, 0.25]
        orientation.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
        transform.RescaleSlope, transform.RescaleIntercept = 1, -1000
        shared = Dataset()
        shared.PixelMeasuresSequence = Sequence([measures])
        shared.PlaneOrientationSequence = Sequence([orientation])
        shared.PixelValueTransformationSequence = Sequence([transform])
        ds.SharedFunctionalGroupsSequence = Sequence([shared])
        order = list(reversed(range(SLICES)))
        groups = []
        for k in order:
            plane, group = Dataset(), Dataset()
            plane.ImagePositionPatient = [0.0, 0.0, 0.75 * k]
            group.PlanePositionSequence = Sequence([plane])
            groups.append(group)
        ds.PerFrameFunctionalGroupsSequence = Sequence(groups)
        ds.PixelData = volume()[order].tobytes()
        path = self.root / "multiframe.dcm"
        ds.save_as(path, enforce_file_format=True)
        data = np.asarray(self.convert([path]).dataobj)
        np.testing.assert_array_equal(data, np.transpose(volume().astype(np.int32) - 1000, (2, 1, 0)))


class FallbackInTheImporterTests(unittest.TestCase):
    """L'importazione intera, con un dcm2niix che si rifiuta sempre."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        subprocess.run(["node", "--experimental-strip-types", "-e", "import('./lib/library.ts').then(m=>m.db())"],
                       cwd=ROOT, env={**os.environ, "OPENMRI_DATA_DIR": str(self.root)}, check=True, capture_output=True)
        self.db = sqlite3.connect(self.root / "library.sqlite")
        self.db.row_factory = sqlite3.Row
        refusing = self.root / "dcm2niix-che-rifiuta"
        refusing.write_text("#!/bin/sh\necho 'Error: Unable to decode this pixel data'\nexit 1\n")
        refusing.chmod(0o755)
        self.environment = os.environ.get("DCM2NIIX")
        os.environ["DCM2NIIX"] = str(refusing)

    def tearDown(self):
        if self.environment is None:
            os.environ.pop("DCM2NIIX", None)
        else:
            os.environ["DCM2NIIX"] = self.environment
        self.db.close()
        self.temp.cleanup()

    def test_the_import_finishes_with_the_second_converter(self):
        from import_mri import main

        files = write_series(self.root / "serie")
        job = str(uuid.uuid4())
        work = self.root / "jobs" / job
        work.mkdir(parents=True)
        with zipfile.ZipFile(work / "source.zip", "w") as bundle:
            for path in files:
                bundle.write(path, f"VOL/{path.name}")
        digest = hashlib.sha256((work / "source.zip").read_bytes()).hexdigest()
        self.db.execute(
            "INSERT INTO jobs(id,status,stage,filename,sha256,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
            (job, "inspecting", "test", "VOL.zip", digest, "now", "now"))
        self.db.commit()
        main(str(self.root), job, "inspect")
        self.db.execute("UPDATE jobs SET status='processing',result=? WHERE id=?",
                        (json.dumps({"patient": {"name": "Riserva"}}), job))
        self.db.commit()
        main(str(self.root), job, "convert")
        row = dict(self.db.execute("SELECT status,error FROM jobs WHERE id=?", (job,)).fetchone())
        self.assertEqual(row["status"], "complete", row["error"])
        manifest = json.loads(self.db.execute("SELECT manifest FROM studies").fetchone()[0])
        self.assertEqual(manifest["series"][0]["nativeDimensions"], [COLUMNS, ROWS, SLICES])


if __name__ == "__main__":
    unittest.main()
