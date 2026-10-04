#!/usr/bin/env python3
"""Comprime una cartella di DICOM nell'archivio che l'importatore si aspetta.

# Perché esiste

L'importatore di OpenMRI accetta un archivio ZIP, ed è una scelta sensata per un'applicazione che
riceve file da un browser: il browser non sa dare una cartella, sa dare un file. Su una CBCT
dentale però la cartella è ciò che si ha in mano — la chiavetta del centro radiologico, o la
cartella esportata dall'apparecchio — e comprimerla a mano prima di ogni importazione è una
seccatura che si ripete a ogni paziente.

Il programma gira sul computer di chi lo usa, quindi il server può leggere quella cartella da sé.
Questo script fa il pezzo che manca: prende la cartella, ne fa l'archivio dove il lavoro se lo
aspetta, e dichiara che cosa ci ha messo dentro.

# Che cosa lascia fuori, e perché

I file nascosti e le cartelle `__MACOSX` che macOS semina ovunque: non sono DICOM e il contatore
dei file — l'importatore ne accetta sessantamila — li conterebbe lo stesso. `DICOMDIR` invece
entra: è un indice, l'importatore lo ignora da sé, e toglierlo significherebbe decidere al posto
suo.

# File oppure cartelle

Nell'app del Mac il pannello di scelta accetta l'una e l'altra cosa, perché chi ha in mano una
CBCT non sa — e non deve sapere — se il programma vuole la cartella o i file: apre la cartella,
vede i `.dcm`, e li seleziona. Prima quei file comparivano in grigio, non selezionabili, ed era
l'unica cosa che chi usava il programma vedeva: «non mi fa aprire nessun file». Ora vale tutto:
una cartella, più cartelle, i file scelti uno per uno, o un misto.

Uso:
    python3 zip_folder.py <cartella o file> [<cartella o file> ...] <archivio.zip>

Stampa su stdout un JSON con quanti file, quanti byte e lo sha256 dell'archivio.
"""

import hashlib
import json
import os
import sys
import zipfile
from pathlib import Path

#: Gli stessi limiti dell'importatore: oltre, il lavoro fallirebbe più avanti e più tardi.
MAXIMUM_FILES = 60_000
MAXIMUM_BYTES = 2 * 1024**3
MAXIMUM_EXTRACTED_BYTES = 12 * 1024**3


def interesting(path, folder):
    """Vero se il file vale la pena di entrare nell'archivio.

    Il nascosto si giudica **dentro** la cartella scelta, non sul percorso intero: la cartella di
    lavoro del programma si chiama `.openmri`, e guardando il percorso assoluto ogni file che ci
    stava dentro risultava nascosto. Il sintomo era «That folder has no files in it» su una
    cartella piena.
    """
    relative = path.relative_to(folder)
    if any(part.startswith(".") or part == "__MACOSX" for part in relative.parts):
        return False
    return path.is_file() and not path.is_symlink()


def collect(sources):
    """I file da archiviare, ciascuno con il nome che avrà dentro l'archivio.

    I nomi partono dalla cartella che contiene ciò che si è scelto, così una cartella conserva il
    suo nome — l'importatore lo usa per raggruppare — e i file scelti a mano entrano con il loro.
    """
    paths = [Path(source).expanduser().resolve() for source in sources]
    for path in paths:
        if not path.exists():
            raise ValueError(f"«{path}» does not exist")
    root = Path(os.path.commonpath([str(path.parent) for path in paths]))
    chosen = {}
    for path in paths:
        if path.is_dir():
            for candidate in sorted(path.rglob("*")):
                if interesting(candidate, path):
                    chosen[candidate] = candidate.relative_to(root)
        elif path.is_file() and not path.is_symlink() and not path.name.startswith("."):
            chosen[path] = path.relative_to(root)
    return root, sorted(chosen.items())


def build(sources, archive):
    if isinstance(sources, (str, Path)):
        sources = [sources]
    if not sources:
        raise ValueError("Choose a folder or the DICOM files")
    archive = Path(archive).expanduser()
    root, files = collect(sources)
    if not files:
        single = Path(sources[0]).expanduser().resolve()
        if len(sources) == 1 and single.is_dir():
            raise ValueError("That folder has no files in it")
        raise ValueError("There are no files in what you chose")
    if len(files) > MAXIMUM_FILES:
        raise ValueError(f"That is {len(files)} files; the limit is {MAXIMUM_FILES}")
    total = sum(path.stat().st_size for path, _ in files)
    if total > MAXIMUM_EXTRACTED_BYTES:
        raise ValueError("What you chose is larger than 12 GB")

    archive.parent.mkdir(parents=True, exist_ok=True)
    partial = archive.with_suffix(".partial")
    # Senza compressione: i DICOM sono già compatti e l'archivio serve solo da contenitore, quindi
    # comprimerli costerebbe minuti per guadagnare poco. Su una CBCT da un gigabyte si sente.
    with zipfile.ZipFile(partial, "w", zipfile.ZIP_STORED, allowZip64=True) as bundle:
        for path, name in files:
            bundle.write(path, str(name))

    size = partial.stat().st_size
    if size > MAXIMUM_BYTES:
        partial.unlink(missing_ok=True)
        raise ValueError("The archive would be larger than 2 GB")

    digest = hashlib.sha256()
    with open(partial, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    partial.replace(archive)
    # «folder» resta ciò che si è scelto quando è uno solo, come prima che si potessero scegliere
    # anche i file; per una scelta multipla è la cartella che li contiene tutti.
    described = Path(sources[0]).expanduser().resolve() if len(sources) == 1 else root
    return {"files": len(files), "bytes": size, "sha256": digest.hexdigest(), "folder": str(described)}


def main(argv):
    if len(argv) < 3:
        print("Uso: zip_folder.py <cartella o file> [...] <archivio.zip>", file=sys.stderr)
        return 2
    print(json.dumps(build(argv[1:-1], argv[-1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
