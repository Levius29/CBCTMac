# Demo study: Jane

`jane-head-mri.zip` (45 MB) is one complete head MRI session of an
adult volunteer, 18 series, included so you can try OpenMRI without scans of
your own. `npm run demo` loads it as patient Jane and opens the app. By hand: click
**Import MRI**, choose the archive, name the patient **Jane**, and click
**Prepare the study**. NIfTI files carry no patient details, so the name is
typed at import and the study date stays unknown.

| File                            | Series                                   | Voxels      | Voxel size, mm |
| ------------------------------- | ---------------------------------------- | ----------- | -------------- |
| `01 +C Axial MPRAGE.nii.gz`     | 3D T1 MPRAGE after contrast              | 256×256×160 | 0.9×0.9×1      |
| `02 Axial MPRAGE.nii.gz`        | 3D T1 MPRAGE                             | 256×256×160 | 0.9×0.9×1      |
| `03 Axial T2.nii.gz`            | Axial T2                                 | 256×256×30  | 0.71×0.94×5.2  |
| `04 Axial T2 FLAIR.nii.gz`      | Axial T2 FLAIR                           | 256×256×30  | 0.7×0.94×5.2   |
| `05 Cor T2.nii.gz`              | Coronal T2                               | 256×35×256  | 0.71×5.2×0.94  |
| `06 Cor T2 FLAIR.nii.gz`        | Coronal T2 FLAIR                         | 256×35×256  | 0.73×5.2×0.92  |
| `07 Sag T2.nii.gz`              | Sagittal T2                              | 29×256×256  | 5.2×1.01×0.98  |
| `08 Axial T2 SPC IAM.nii.gz`    | 3D T2 SPACE, inner ear                   | 256×256×80  | 0.72×0.72×0.65 |
| `09 Sag DIR.nii.gz`             | 3D double inversion recovery             | 112×256×256 | 1.4×1.02×1.02  |
| `10 Axial SWI.nii.gz`           | Susceptibility-weighted                  | 256×256×52  | 0.85×0.94×3.17 |
| `11 Axial SWI mIP.nii.gz`       | SWI minimum-intensity projection         | 256×256×45  | 0.85×0.94×3.17 |
| `12 Axial SWI magnitude.nii.gz` | SWI magnitude                            | 256×256×52  | 0.85×0.94×3.17 |
| `13 Axial DWI ADC.nii.gz`       | Apparent diffusion coefficient map       | 256×256×30  | 0.94×0.94×5.2  |
| `14 Axial T1.nii.gz`            | Axial T1                                 | 256×256×30  | 0.94×0.94×5.2  |
| `15 Sag T1.nii.gz`              | Sagittal T1                              | 29×256×256  | 5.2×0.96×0.96  |
| `16 +C Axial T1 FS.nii.gz`      | Axial fat-saturated T1 after contrast    | 256×256×30  | 0.94×0.94×5.2  |
| `17 +C Cor T1 FS.nii.gz`        | Coronal fat-saturated T1 after contrast  | 256×37×256  | 0.86×5.2×0.86  |
| `18 +C Sag T1 FS.nii.gz`        | Sagittal fat-saturated T1 after contrast | 27×256×256  | 5.2×0.94×0.94  |

The scan shows a brain after surgery. It is a demonstration of the viewer, not
a reference dataset: do not use it for research, for training models, or for
any medical purpose.

## How it was prepared

- The series were converted from DICOM to NIfTI with OpenMRI's own import
  pipeline (dcm2niix). The headers hold geometry and nothing else: no name,
  identifier, date of birth, study date, DICOM UIDs, or scanner details, and
  no header extensions. The 4D diffusion trace series was left out.
- The face was deliberately left in, so the 3D view shows a whole head. A
  volume rendering shows a recognisable face, so this scan is not anonymous.
- Every volume was resampled to at most 256 voxels per axis with linear
  interpolation, preserving the voxel-centre geometry, and stored as 16-bit
  integers.

The person scanned chose to publish this scan, face included. It is released
under the repository's [MIT license](../LICENSE).

SHA-256 of the archive: `247b778cc557f6b474ed154cc56841cb8faaad05bf9d5456bee7f2c0cc213124`
