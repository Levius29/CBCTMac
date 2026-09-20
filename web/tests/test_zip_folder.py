"""Prove della compressione di una cartella di DICOM.

È il pezzo che permette di importare una cartella senza comprimerla a mano, e sbagliarlo non dà
un errore: dà un archivio che l'importatore rifiuta più avanti, con un messaggio che parla d'altro.
"""

import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "zip_folder", Path(__file__).resolve().parents[1] / "scripts/zip_folder.py"
)
zipper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zipper)


class ZipFolderTests(unittest.TestCase):
    def test_packs_every_file_and_declares_what_it_did(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "CBCT"
            (root / "serie").mkdir(parents=True)
            for index in range(5):
                (root / "serie" / f"{index}.dcm").write_bytes(b"x" * 100)

            archive = Path(folder) / "out.zip"
            summary = zipper.build(root, archive)
            self.assertEqual(summary["files"], 5)
            self.assertEqual(len(summary["sha256"]), 64)
            self.assertTrue(archive.exists())
            with zipfile.ZipFile(archive) as bundle:
                names = bundle.namelist()
            self.assertEqual(len(names), 5)
            # I nomi conservano la cartella: l'importatore la usa per raggruppare.
            self.assertTrue(all(name.startswith("CBCT/") for name in names), names)

    def test_leaves_out_what_macos_scatters_around(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "CBCT"
            (root / "__MACOSX").mkdir(parents=True)
            (root / "__MACOSX" / "._0.dcm").write_bytes(b"spazzatura")
            (root / ".DS_Store").write_bytes(b"spazzatura")
            (root / "0.dcm").write_bytes(b"x" * 10)

            summary = zipper.build(root, Path(folder) / "out.zip")
            self.assertEqual(summary["files"], 1)

    def test_an_empty_folder_is_an_error_with_a_reason(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "vuota"
            root.mkdir()
            with self.assertRaises(ValueError) as caught:
                zipper.build(root, Path(folder) / "out.zip")
            self.assertIn("no files", str(caught.exception))

    def test_a_missing_folder_says_so(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                zipper.build(Path(folder) / "non-esiste", Path(folder) / "out.zip")

    def test_the_command_line_prints_json(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "CBCT"
            root.mkdir()
            (root / "0.dcm").write_bytes(b"x")
            archive = Path(folder) / "out.zip"
            self.assertEqual(zipper.main(["zip_folder.py", str(root), str(archive)]), 0)
            self.assertTrue(archive.exists())


if __name__ == "__main__":
    unittest.main()


class HiddenAncestorTests(unittest.TestCase):
    """Il difetto che ha fermato il primo caricamento dal browser, in una prova.

    I file arrivano in `.openmri/jobs/<id>/incoming`, e il filtro sui nascosti guardava il
    percorso assoluto: ogni file risultava dentro una cartella che comincia per punto, quindi
    l'archivio usciva vuoto e l'importazione si fermava dicendo che la cartella era vuota.
    """

    def test_a_hidden_parent_does_not_hide_the_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / ".openmri" / "jobs" / "abc" / "incoming"
            root.mkdir(parents=True)
            for index in range(3):
                (root / f"{index:06d}-slice.dcm").write_bytes(b"x" * 50)

            summary = zipper.build(root, Path(folder) / "out.zip")
            self.assertEqual(summary["files"], 3)

    def test_hidden_files_inside_the_chosen_folder_still_go(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "CBCT"
            root.mkdir()
            (root / ".DS_Store").write_bytes(b"spazzatura")
            (root / "buono.dcm").write_bytes(b"x")
            summary = zipper.build(root, Path(folder) / "out.zip")
            self.assertEqual(summary["files"], 1)
