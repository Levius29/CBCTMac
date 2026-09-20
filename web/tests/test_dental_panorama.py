"""Prove della panoramica ricostruita e delle sezioni d'arcata.

Il fantoccio è un'arcata **nota per costruzione**: un tubo di osso lungo una semiellisse, con
denti più densi a intervalli regolari. Su dati veri non esiste un paziente di cui si conosca
l'arcata al decimo di millimetro; qui la verità è scritta sopra, quindi si può chiedere non
«l'immagine sembra buona?» ma «la curva trovata coincide con quella vera?».

Restano prove d'ingegneria: dicono che la geometria è quella giusta, non che su una CBCT vera la
ricostruzione sia clinicamente adeguata.
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

import nibabel as nib
import numpy as np

spec = importlib.util.spec_from_file_location(
    "dental_panorama", Path(__file__).resolve().parents[1] / "scripts/dental_panorama.py"
)
dental = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dental)

#: Semiassi dell'arcata del fantoccio, in millimetri.
ARCH_A, ARCH_B = 25.0, 32.0
#: Raggio del tubo d'osso attorno alla curva.
ARCH_RADIUS = 4.0
#: Estensione verticale dell'osso, attorno a z = 0.
ARCH_HALF_HEIGHT = 12.0


def true_arch_point(theta):
    """Un punto della curva vera, in millimetri RAS."""
    return np.array([ARCH_A * np.cos(theta), ARCH_B * np.sin(theta), 0.0])


def make_arch_volume(path, spacing=0.5, columns=160, rows=160, slices=96):
    """Un volume NIfTI con dentro un'arcata: tubo d'osso, denti più densi, fondo d'aria."""
    origin = np.array(
        [-(columns - 1) * spacing / 2, -(rows - 1) * spacing / 2, -(slices - 1) * spacing / 2]
    )
    affine = np.diag([spacing, spacing, spacing, 1.0])
    affine[:3, 3] = origin

    xs = origin[0] + np.arange(columns) * spacing
    ys = origin[1] + np.arange(rows) * spacing
    zs = origin[2] + np.arange(slices) * spacing
    grid_x, grid_y = np.meshgrid(xs, ys, indexing="ij")

    # Distanza dal filo dell'arcata, valutata su un campionamento fitto della curva vera.
    theta = np.linspace(0.0, np.pi, 400)
    curve = np.stack([ARCH_A * np.cos(theta), ARCH_B * np.sin(theta)], axis=1)
    flat = np.stack([grid_x.ravel(), grid_y.ravel()], axis=1)
    distance = np.min(np.linalg.norm(flat[:, None, :] - curve[None, :, :], axis=2), axis=1)
    distance = distance.reshape(columns, rows)

    data = np.full((columns, rows, slices), -1000.0, dtype=np.float32)
    inside_height = np.abs(zs) <= ARCH_HALF_HEIGHT
    bone = (distance <= ARCH_RADIUS)[:, :, None] & inside_height[None, None, :]
    data[bone] = 1200.0

    # Denti: sfere dense a intervalli regolari lungo l'arcata, che sporgono verso l'alto.
    for angle in np.linspace(0.15 * np.pi, 0.85 * np.pi, 8):
        centre = true_arch_point(angle) + np.array([0.0, 0.0, 6.0])
        dx = xs[:, None, None] - centre[0]
        dy = ys[None, :, None] - centre[1]
        dz = zs[None, None, :] - centre[2]
        data[(dx * dx + dy * dy + dz * dz) <= 3.0**2] = 2800.0

    image = nib.Nifti1Image(data, affine)
    image.header["cal_min"] = -1000.0
    image.header["cal_max"] = 2800.0
    nib.save(image, str(path))
    return path


class ArchMathTests(unittest.TestCase):
    """La matematica della curva, senza volume di mezzo."""

    def test_otsu_splits_two_modes(self):
        values = np.concatenate([np.full(1000, 10.0), np.full(300, 900.0)])
        threshold = dental.otsu_threshold(values)
        self.assertIsNotNone(threshold)
        self.assertGreater(threshold, 10.0)
        self.assertLess(threshold, 900.0)

    def test_otsu_refuses_a_flat_image(self):
        self.assertIsNone(dental.otsu_threshold(np.full(500, 7.0)))

    def test_largest_component_keeps_one_blob(self):
        mask = np.zeros((20, 20), dtype=bool)
        mask[2:12, 2:12] = True  # macchia grande
        mask[16:19, 16:19] = True  # macchia piccola, staccata
        kept = dental.largest_component(mask)
        self.assertEqual(int(kept.sum()), 100)
        self.assertFalse(kept[17, 17])

    def test_spline_passes_through_control_points(self):
        points = np.array([[0.0, 0, 0], [10.0, 5, 0], [20.0, 0, 0]])
        dense, lengths = dental.catmull_rom_polyline(points)
        for point in points:
            distance = np.min(np.linalg.norm(dense - point, axis=1))
            self.assertLess(distance, 1e-6, f"la curva non passa per {point}")
        self.assertGreater(lengths[-1], 20.0)

    def test_arc_length_sampling_is_evenly_spaced(self):
        points = np.array([[0.0, 0, 0], [10.0, 8, 0], [22.0, 0, 0], [30.0, -6, 0]])
        dense, lengths = dental.catmull_rom_polyline(points)
        arc = np.linspace(0, lengths[-1], 50)
        position, tangent, normal, _ = dental.arch_samples(
            dense, lengths, arc, np.array([0.0, 0.0, 1.0])
        )
        steps = np.linalg.norm(np.diff(position, axis=0), axis=1)
        # Passo costante entro il due per cento: è il requisito che rende misurabile la panoramica.
        self.assertLess(steps.std() / steps.mean(), 0.02)
        # Tangente e normale sono versori ortogonali fra loro.
        np.testing.assert_allclose(np.linalg.norm(tangent, axis=1), 1.0, atol=1e-9)
        np.testing.assert_allclose(np.linalg.norm(normal, axis=1), 1.0, atol=1e-9)
        np.testing.assert_allclose(np.sum(tangent * normal, axis=1), 0.0, atol=1e-9)

    def test_curve_starts_on_the_patient_right(self):
        left_first = np.array([[-20.0, 0, 0], [0.0, 20, 0], [20.0, 0, 0]])
        oriented = dental.orient_curve(left_first)
        self.assertGreater(oriented[0, 0], oriented[-1, 0])
        # Una curva già orientata non si tocca.
        np.testing.assert_allclose(dental.orient_curve(oriented), oriented)


class ArchDetectionTests(unittest.TestCase):
    """Il rilevamento: deve trovare l'arcata che c'è e rifiutare quella che non c'è."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.path = make_arch_volume(Path(cls.temp.name) / "arch.nii.gz")
        cls.volume = dental.Volume(cls.path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_finds_the_arch_where_it_is(self):
        detection = dental.detect_arch(self.volume)
        self.assertIsNotNone(detection, "l'arcata del fantoccio non è stata riconosciuta")
        points = detection["points"]
        self.assertGreaterEqual(len(points), 3)

        # Ogni punto proposto deve cadere sul filo dell'arcata vera, entro il raggio del tubo.
        theta = np.linspace(0.0, np.pi, 2000)
        curve = np.stack([ARCH_A * np.cos(theta), ARCH_B * np.sin(theta)], axis=1)
        for point in points:
            distance = np.min(np.linalg.norm(curve - point[:2], axis=1))
            self.assertLess(distance, ARCH_RADIUS + 1.0, f"punto fuori dall'arcata: {point}")

    def test_refuses_a_solid_block(self):
        """Un blocco pieno non ha apertura: circonda il proprio baricentro, quindi non è un'arcata."""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "block.nii.gz"
            data = np.full((80, 80, 60), -1000.0, dtype=np.float32)
            data[20:60, 20:60, 10:50] = 1200.0
            nib.save(nib.Nifti1Image(data, np.diag([0.5, 0.5, 0.5, 1.0])), str(path))
            self.assertIsNone(dental.detect_arch(dental.Volume(path)))

    def test_refuses_an_empty_volume(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "air.nii.gz"
            data = np.full((60, 60, 60), -1000.0, dtype=np.float32)
            nib.save(nib.Nifti1Image(data, np.diag([0.5, 0.5, 0.5, 1.0])), str(path))
            self.assertIsNone(dental.detect_arch(dental.Volume(path)))


class ReconstructionTests(unittest.TestCase):
    """Panoramica e sezioni: la geometria, misurata sull'immagine prodotta."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        folder = Path(cls.temp.name)
        cls.path = make_arch_volume(folder / "arch.nii.gz")
        cls.output = folder / "out"
        cls.result = dental.build(
            cls.path,
            cls.output,
            {"sectionIntervalMM": 4.0, "mmPerPixel": 0.25, "sectionMmPerPixel": 0.25},
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_writes_the_images(self):
        self.assertTrue((self.output / "panorama.png").exists())
        self.assertTrue((self.output / "axial.png").exists())
        sections = sorted((self.output / "sections").glob("*.png"))
        self.assertEqual(len(sections), self.result["sections"]["count"])

    def test_panorama_covers_the_whole_arch_at_one_scale(self):
        panorama = self.result["panorama"]
        # Mezza ellisse di semiassi 25 e 32: fra i 90 e i 100 mm di perimetro.
        self.assertGreater(panorama["arcLengthMM"], 85.0)
        self.assertLess(panorama["arcLengthMM"], 105.0)
        # La scala è una sola: la larghezza copre la curva, l'altezza segue.
        self.assertAlmostEqual(
            panorama["mmPerPixel"] * panorama["widthPx"], panorama["arcLengthMM"], places=6
        )
        self.assertGreater(panorama["slabSamples"], 1)

    def test_panorama_shows_the_bone_band_at_the_right_height(self):
        image = dental.sitk.GetArrayFromImage(
            dental.sitk.ReadImage(str(self.output / "panorama.png"))
        )
        panorama = self.result["panorama"]
        rows = np.where(image.mean(axis=1) > image.mean() + 10)[0]
        self.assertGreater(rows.size, 0, "la panoramica non mostra nessun osso")

        # L'osso del fantoccio sta fra −12 e +12 mm: la banda chiara deve cadere lì, in quota
        # **Patient**, non a metà immagine. La riga 0 è la più craniale, e il centro dell'immagine
        # sta alla quota che il rilevamento ha scelto — non necessariamente z = 0.
        centre_row = (panorama["heightPx"] - 1) / 2
        centre_mm = self.result["curve"]["verticalCentreMM"]
        top_z = centre_mm + (centre_row - rows.min()) * panorama["mmPerPixel"]
        bottom_z = centre_mm + (centre_row - rows.max()) * panorama["mmPerPixel"]
        self.assertLess(abs(top_z - ARCH_HALF_HEIGHT), 4.0, f"bordo alto a {top_z:.1f} mm")
        self.assertLess(abs(bottom_z + ARCH_HALF_HEIGHT), 4.0, f"bordo basso a {bottom_z:.1f} mm")

    def test_sections_cut_across_the_arch(self):
        sections = self.result["sections"]
        middle = sorted((self.output / "sections").glob("*.png"))[sections["count"] // 2]
        image = dental.sitk.GetArrayFromImage(dental.sitk.ReadImage(str(middle)))

        # La sezione taglia perpendicolarmente il tubo d'osso: la parte chiara deve stare attorno
        # al centro in orizzontale, ed essere larga quanto il tubo, non quanto l'arcata.
        bright = image > image.mean() + 20
        self.assertTrue(bright.any(), "la sezione non contiene osso")
        columns = np.where(bright.any(axis=0))[0]
        centre = (sections["widthPx"] - 1) / 2
        width_mm = (columns.max() - columns.min()) * sections["mmPerPixel"]
        self.assertLess(abs(columns.mean() - centre) * sections["mmPerPixel"], 3.0)
        self.assertLess(width_mm, 4 * ARCH_RADIUS)

    def test_result_declares_what_it_is_and_is_not(self):
        self.assertTrue(self.result["curve"]["automatic"])
        self.assertEqual(len(self.result["notes"]), 2)
        self.assertIn("reconstructed surface", self.result["notes"][0])


if __name__ == "__main__":
    unittest.main()


class AxialOverlayTests(unittest.TestCase):
    """La fetta assiale e la curva disegnata sopra: è il posto in cui si giudica il rilevamento."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        folder = Path(cls.temp.name)
        cls.path = make_arch_volume(folder / "arch.nii.gz")
        cls.output = folder / "out"
        cls.result = dental.build(cls.path, cls.output, {"sectionIntervalMM": 8.0})

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_curve_pixels_land_inside_the_image(self):
        axial = self.result["axial"]
        self.assertEqual(axial["orientation"], "radiological")
        pixels = np.asarray(axial["curvePixels"])
        self.assertGreater(len(pixels), 50)
        self.assertTrue((pixels[:, 0] >= 0).all() and (pixels[:, 0] <= axial["columns"] - 1).all())
        self.assertTrue((pixels[:, 1] >= 0).all() and (pixels[:, 1] <= axial["rows"] - 1).all())
        self.assertEqual(len(axial["controlPixels"]), len(self.result["curve"]["controlPointsMM"]))

    def test_curve_pixels_follow_the_bone_in_the_image(self):
        """Il pixel sotto la curva deve essere osso: è la prova che la conversione non è specchiata."""
        image = dental.sitk.GetArrayFromImage(
            dental.sitk.ReadImage(str(self.output / "axial.png"))
        )
        pixels = np.asarray(self.result["axial"]["curvePixels"])
        values = [
            float(image[int(round(y)), int(round(x))])
            for x, y in pixels
            if 0 <= int(round(y)) < image.shape[0] and 0 <= int(round(x)) < image.shape[1]
        ]
        self.assertGreater(np.median(values), image.mean() + 20)

    def test_patient_right_is_on_the_left_of_the_image(self):
        """Il primo punto della curva sta a destra del paziente, quindi a sinistra dell'immagine."""
        control = np.asarray(self.result["axial"]["controlPixels"])
        self.assertLess(control[0, 0], control[-1, 0])


class DepthAndCutTests(unittest.TestCase):
    """Lo scostamento in profondità e le linee di taglio: i due legami fra le viste."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        folder = Path(cls.temp.name)
        cls.path = make_arch_volume(folder / "arch.nii.gz")
        # Slab sottile di proposito: è la condizione in cui lo scostamento significa qualcosa.
        # Con venti millimetri di spessore il piano si sposta e l'osso resta dentro lo slab
        # comunque — ed è esattamente perché si assottiglia lo slab quando si sfoglia in
        # profondità.
        thin = {"sectionIntervalMM": 8.0, "slabThicknessMM": 1.0}
        cls.result = dental.build(cls.path, folder / "centro", thin)
        cls.image = dental.sitk.GetArrayFromImage(
            dental.sitk.ReadImage(str(folder / "centro/panorama.png"))
        )
        # Otto millimetri verso il vestibolare: il tubo d'osso ha raggio quattro, quindi il piano
        # campionato esce dall'osso e la panoramica deve svuotarsi.
        cls.outside = dental.build(
            cls.path, folder / "fuori", {**thin, "normalOffsetMM": 8.0}
        )
        cls.outside_image = dental.sitk.GetArrayFromImage(
            dental.sitk.ReadImage(str(folder / "fuori/panorama.png"))
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_depth_offset_moves_the_sampled_plane(self):
        self.assertEqual(self.result["panorama"]["normalOffsetMM"], 0.0)
        self.assertEqual(self.outside["panorama"]["normalOffsetMM"], 8.0)
        bright_inside = float((self.image > 128).mean())
        bright_outside = float((self.outside_image > 128).mean())
        self.assertGreater(bright_inside, 0.1, "la panoramica centrata non mostra osso")
        self.assertLess(
            bright_outside,
            bright_inside / 4,
            "spostando il piano fuori dall'osso la panoramica non si è svuotata",
        )

    def test_cut_lines_cross_the_curve(self):
        axial = self.result["axial"]
        cuts = np.asarray(axial["cutPixels"])
        self.assertEqual(len(cuts), self.result["sections"]["count"])

        curve = np.asarray(axial["curvePixels"])
        step = axial["stepMM"]
        for cut in cuts:
            start = cut[:2]
            end = cut[2:]
            middle = (start + end) / 2
            # Il centro del taglio sta sulla curva: è lì che la sezione è generata.
            distance = np.min(np.linalg.norm(curve - middle, axis=1)) * step
            self.assertLess(distance, 2.0, "una linea di taglio non parte dalla curva")
            # E la sua lunghezza è la larghezza della sezione.
            length = np.linalg.norm(end - start) * step
            self.assertAlmostEqual(length, self.result["sections"]["widthMM"], delta=1.0)

    def test_world_from_pixel_is_the_inverse_of_the_drawing(self):
        """Trascinare un punto e ridisegnarlo deve riportarlo dov'era, al decimo di millimetro."""
        axial = self.result["axial"]
        affine = axial["worldFromPixel"]
        for pixel, point in zip(
            axial["controlPixels"], self.result["curve"]["controlPointsMM"]
        ):
            x = affine["x"][0] * pixel[0] + affine["x"][1] * pixel[1] + affine["x"][2]
            y = affine["y"][0] * pixel[0] + affine["y"][1] * pixel[1] + affine["y"][2]
            self.assertAlmostEqual(x, point[0], places=6)
            self.assertAlmostEqual(y, point[1], places=6)
        self.assertAlmostEqual(affine["z"], self.result["curve"]["archVerticalMM"], places=6)

    def test_level_range_covers_the_volume(self):
        low, high = self.result["axial"]["levelRangeMM"]
        self.assertLess(low, self.result["curve"]["archVerticalMM"])
        self.assertGreater(high, self.result["curve"]["archVerticalMM"])


class ManualCurveTests(unittest.TestCase):
    """La curva data a mano: è il rimedio quando il rilevamento sbaglia, e deve essere obbedita."""

    def test_given_points_are_used_as_they_are(self):
        with tempfile.TemporaryDirectory() as folder:
            path = make_arch_volume(Path(folder) / "arch.nii.gz")
            # Una curva più stretta di quella vera, posata a mano: il programma deve usare questa.
            theta = np.linspace(0.15 * np.pi, 0.85 * np.pi, 6)
            points = [
                [float(ARCH_A * 0.6 * np.cos(t)), float(ARCH_B * 0.6 * np.sin(t)), 2.0]
                for t in theta
            ]
            result = dental.build(
                path,
                Path(folder) / "out",
                {"controlPointsMM": points, "sectionIntervalMM": 8.0},
            )
            self.assertFalse(result["curve"]["automatic"])
            used = np.asarray(result["curve"]["controlPointsMM"])
            given = np.asarray(points)
            # Stessi punti, eventualmente nell'ordine rovesciato per partire dalla destra.
            if used[0, 0] < given[0, 0]:
                given = given[::-1]
            np.testing.assert_allclose(used, given, atol=1e-9)
            self.assertAlmostEqual(result["curve"]["archVerticalMM"], 2.0, places=6)
