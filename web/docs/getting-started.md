# Getting started

OpenMRI shows MR and CT studies in 3D and on three slices. Archives, patient
details, the processing queue, and prepared volumes stay on your computer. No
diagnostic model is connected.

## Installation

You need Node.js 22.13 or newer and Python 3.12, 3.13, or 3.14. On macOS with
Homebrew:

```sh
brew install node python@3.12
```

Then, in the project folder:

```sh
npm ci
npm run setup
npm run build
npm start
```

`npm run setup` creates `.venv/` with pydicom, nibabel, SimpleITK, and the
`dcm2niix` converter. If you prefer a system-wide `dcm2niix`, install it with
your package manager; the setup script finds it on `PATH` as well.

Open http://127.0.0.1:4173/. `npm run up` starts the server in the background
and opens the browser, `npm run down` stops it, `npm run status` reports its
state; `scripts/server.sh logs` follows the log. On macOS, `Launch
OpenMRI.command` does all of the above on first run and then just opens the app.

Installing dependencies needs an internet connection. Viewing and processing
work offline. The server binds to `127.0.0.1` only and has no authentication,
so treat it as a desktop app.

## Importing a study

1. Click **Import MRI** and choose a ZIP up to 2 GB.
2. The archive is extracted and inspected. DICOM headers supply the patient
   name, date of birth, study date, body part, and series descriptions. NIfTI
   files carry none of that, so you enter the name and the study date stays
   unknown.
3. Review the proposed patient. Create a new one or pick an existing patient
   explicitly.
4. Click **Prepare the study**. Conversion runs in a background process. You
   can close the wizard; the job stays listed under **Library → Imports**.
   Do not close the page while the upload itself is still in progress.
5. Open the study. The next open uses the cache.

The original ZIP is kept in full. Supported inputs are scalar 3D volumes and
regular 2D MR/CT slice stacks. `dcm2niix` handles most vendors but cannot
guarantee every archive; series it cannot convert are listed in the result.
4D time series, single images, color functional captures, PDFs, and nested
ZIPs are never turned into volumes. Extraction limits: 12 GB and 60,000 files.

One archive must contain a single patient; an archive with several patients is
rejected before anything is written. Importing the same archive again for the
same patient reuses the existing studies. The same archive is never silently
attached to a different patient.

To try the app without scans of your own, run `npm run demo`. It imports
`demo/jane-head-mri.zip` as patient Jane and opens the app; click Jane under
Recent studies. You can also
import that file by hand and name the patient Jane.
[demo/README.md](../demo/README.md) lists its series and explains how the data
was prepared.

Study dates come from the DICOM `StudyDate` tag. The `+C` contrast tag is set
only when `ContrastBolusAgent` is filled or the series description explicitly
says `POST`, `+C`, or `CE`. OpenMRI does not guess contrast from the image.

## Welcome screen

The app opens on a welcome screen. It lists the five studies you opened most
recently, filled up with the newest imports, next to **Import a new MRI** and
**Open library**. Choosing a study, a patient in the library, or finishing an
import plays a short entering transition while the viewer loads the volume
behind it. **Skip** ends it early; the sound toggle is remembered. With the
system's reduced-motion setting the clip is not played at all. The brand mark
in the viewer header returns to the welcome screen.

## Viewer controls

- **Patient** and **Study** are the drop-downs on the left. The person icon
  opens the patient details.
- **Series** cards switch between the volumes of the study. The `+C` badge
  marks confirmed contrast series.
- **3D view**: drag to rotate, wheel or trackpad to zoom, **Orbit** for a slow
  turn, the circular arrow to reset. **Light and material** changes the palette
  and brightness. **Cut plane** opens the volume from the side, front, or top.
  **Slice planes in 3D** draws the three slice positions inside the volume.
- **Slices**: click to pick a point. The amber focus marker appears in 3D and
  stays visible through tissue. Scrolling moves the slice; the motion is
  smoothed unless your system asks for reduced motion.
- **Compare** shows a second series of the same study next to the first with
  linked clicks and scrolling in physical millimetres. Motion between the two
  acquisitions is not corrected.
- **Saved point** stores one point per patient in the browser. **Go to point**
  returns to it and switches series if needed.
- **History** lists every study date of the patient; pick one to open it.
- **Focus over time** opens the cross-date comparison workspace, see
  [focus-timeline.md](focus-timeline.md). It needs at least two study dates.
- **Snapshot** saves a 1920×1200 PNG with the volume, the slices, and the
  marker into `captures/` inside your data directory.
- **Expand** enlarges the viewer; Escape returns to the normal layout.

## Data and cache

`.openmri/library.sqlite` is the SQLite catalog (WAL mode). `sources/` holds
the original ZIPs by SHA-256, `volumes/` the prepared NIfTI files (geometry is
preserved; the matrix is downsampled to at most 320 voxels per axis), `jobs/`
the import drafts and worker logs, `registrations/` the transforms and
resampled volumes of the timeline feature, `captures/` the snapshots you saved
from the viewer.

Studies that an older version seeded from the bundled demo dataset can no
longer be opened, because their volumes were served by a route that is gone
and no source archive exists to rebuild them. They are removed once, the first
time the new version opens the library.

The whole folder can be moved once imports are finished and the app is
stopped. Point `OPENMRI_DATA_DIR` at the new location. Cached paths are
relative, so the folder is self-contained. Back up the folder as a whole.

An installation created before the rename to OpenMRI keeps using its existing
`.neurospace/` folder automatically.

Discarding an import draft removes its temporary ZIP and extraction, never
studies that were already imported. Heavy conversions run one at a time. If
the computer restarts during an import, the job shows an error and the
archive has to be uploaded again; finished studies are unaffected.

## Future analysis model

`lib/analysis-contract.ts` defines the adapter interface for a local model: the
request names the patient, study, series, SHA-256, dimensions, body part, and
RAS affine; a result must reference the same source and model version, report
points in RAS millimetres, and attach segmentations as separate assets tied to
the source hash. Validation rejects results for another series, geometry, or
coordinate system. No model is shipped and nothing in the interface pretends
otherwise.
