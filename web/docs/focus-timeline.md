# Focus over time

An experimental local workspace for following one spot across study dates. The
**Focus over time** button opens it from the current series and carries over
the selected point. The main viewer stays as it was after you close it.

## How to use it

1. Choose the reference date (A) and series. Click a point on a slice, give
   the region a name and a neighbourhood radius, and click **Track this
   region**.
2. Choose a comparison date (B). A matching series is proposed by family
   (T1, T2, FLAIR, DIR, SWI, ADC) and by explicitly known contrast phase. If
   nothing matches, the choice stays empty. Comparing different families or
   an unknown phase requires ticking the manual-choice box.
3. Wait for the local registration. Use **Side by side**, **Wipe**, or
   **A ↔ B**, pick a single plane or 3D plus three slices. Cameras and
   coordinates are linked. **Zoom to focus** enlarges the neighbourhood at the
   same physical scale in both panes.
4. Check anatomical landmarks. **Position checked** records that you looked.
   **Correct point B** stores a per-date manual offset; the reference point
   and the automatic transform are kept.
5. **Prepare all matching dates** queues the registrations one after another.
   **Play history** steps through the real studies in date order, starting
   with the first match. Nothing is morphed between studies. While a date is
   loading, failed, or has the point outside its scanned field, playback does
   not keep showing the previous volume under the new date.
6. The filmstrip lists every date with the real gap in days. Dates you have
   viewed get local thumbnails. Series that cannot be matched stay marked.

Saved regions survive restarts. Moving the cursor never overwrites a region:
go back to the saved point or save the new position explicitly. Changing the
centre or radius clears earlier checks; renaming keeps them. Changing the
reference series starts a new region.

## Geometry and provenance

- Registration currently targets 3D head MRI: DICOM body part `HEAD` or
  `BRAIN`, or NIfTI imports, which carry no body part. Volumes reconstructed
  from 2D slices are fine. Other body parts import and display normally;
  cross-date registration for them is not implemented yet.
- SimpleITK 2.5: Euler3D rigid transform, Mattes mutual information, shrink
  levels 4/2/1, fixed sampling seed 42, two CPU threads. This is an initial
  alignment, not a clinically validated registration.
- Every date is registered directly to the reference series. No scaling and no
  deformable registration are applied.
- SimpleITK estimates the transform **fixed LPS → moving LPS**. The matrix used
  by the interface is `diag(-1,-1,1,1) × T × diag(-1,-1,1,1)`, including the
  rotation centre and translation.
- Image B is interpolated once onto the grid of A. Whether a point is covered
  is decided with the transform and the geometry of the **original B**, not
  the zero-padded resampled volume.
- A region stores the patient, reference study and series, source SHA-256,
  RAS-mm centre, radius, and independent per-date corrections. A correction
  defines point B in registered coordinates; B's original coordinates are shown
  separately.
- The registration cache key includes the patient and series identifiers, both
  file hashes, and the algorithm version. Source files are never modified.
- After surgery, tissue correspondence may not exist. The sphere is a
  geometric neighbourhood, not a segmentation. Intensities, lesion volume, and
  growth are never interpreted automatically.

## Storage and execution

SQLite tables `focus_regions` and `registrations`; transforms and registered
NIfTI files under `.openmri/registrations/`. The worker is a separate process
that keeps running if the window is closed. A file lock limits execution to
one registration at a time; the queue can be cancelled, but a pair already
running finishes in the background. A failed job can be retried.

## Tests

`npm test` covers series matching, coordinates, out-of-field detection,
region persistence and patient isolation, provenance, and review reset.
`npm run test:import` includes a synthetic volume with a known rotation and
translation: the landmark error must stay below 1 mm and the reference grid
must be preserved. These are engineering tests, not accuracy studies on
patients.

Method reference: https://simpleitk.readthedocs.io/en/master/registrationOverview.html
