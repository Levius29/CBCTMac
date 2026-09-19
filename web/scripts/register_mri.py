#!/usr/bin/env python3
"""Local rigid registration. Transform maps fixed LPS -> moving LPS.
Display output is sampled ONCE on the fixed grid; no deformable warping.
"""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import numpy as np
import nibabel as nib
import SimpleITK as sitk

sitk.ProcessObject.SetGlobalDefaultNumberOfThreads(2)

def sha(filename):
    h = hashlib.sha256()
    with open(filename, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def ras_matrix(transform):
    """ITK LPS fixed->moving to NIfTI RAS fixed->moving, including center."""
    origin = np.asarray(transform.TransformPoint((0., 0., 0.)))
    matrix = np.eye(4)
    matrix[:3, 3] = origin
    for i in range(3):
        p = np.eye(3)[i]
        matrix[:3, i] = np.asarray(transform.TransformPoint(tuple(p))) - origin
    flip = np.diag([-1., -1., 1., 1.])
    return flip @ matrix @ flip

def register(fixed, moving, progress=lambda stage: None):
    if fixed.GetDimension() != 3 or moving.GetDimension() != 3:
        raise ValueError('Registration needs 3D volumetric series')
    if min(*fixed.GetSize(), *moving.GetSize()) < 12:
        raise ValueError('Too few slices for volumetric registration')
    fixed = sitk.Cast(fixed, sitk.sitkFloat32)
    moving = sitk.Cast(moving, sitk.sitkFloat32)
    for img in [fixed, moving]:
        values = sitk.GetArrayViewFromImage(img)
        if not np.isfinite(values).all() or float(np.std(values)) < 1e-6:
            raise ValueError('A series contains invalid or constant values')
    initializer = sitk.CenteredTransformInitializer(fixed, moving, sitk.Euler3DTransform(), sitk.CenteredTransformInitializerFilter.GEOMETRY)
    method = sitk.ImageRegistrationMethod()
    method.SetMetricAsMattesMutualInformation(48)
    method.SetMetricSamplingStrategy(method.RANDOM)
    method.SetMetricSamplingPercentage(0.12, seed=42)
    method.SetInterpolator(sitk.sitkLinear)
    method.SetOptimizerAsRegularStepGradientDescent(learningRate=2.0, minStep=0.015, numberOfIterations=180, relaxationFactor=0.5, gradientMagnitudeTolerance=1e-6)
    method.SetOptimizerScalesFromPhysicalShift()
    method.SetShrinkFactorsPerLevel([4, 2, 1])
    method.SetSmoothingSigmasPerLevel([2, 1, 0])
    method.SmoothingSigmasAreSpecifiedInPhysicalUnitsOn()
    method.SetInitialTransform(initializer, inPlace=False)
    method.AddCommand(sitk.sitkMultiResolutionIterationEvent, lambda: progress(f'Registering: level {method.GetCurrentLevel()+1} of 3'))
    transform = method.Execute(fixed, moving)
    matrix = ras_matrix(transform)
    if not np.isfinite(matrix).all() or not np.isfinite(method.GetMetricValue()):
        raise ValueError('The registration did not converge to a stable result')
    # Coverage describes acquisition support, NOT registration accuracy.
    ones = sitk.Image(moving.GetSize(), sitk.sitkUInt8) + 1
    ones.CopyInformation(moving)
    mask = sitk.Resample(ones, fixed, transform, sitk.sitkNearestNeighbor, 0, sitk.sitkUInt8)
    overlap = float(np.mean(sitk.GetArrayViewFromImage(mask)))
    if overlap < 0.25:
        raise ValueError('The studies barely overlap. Check the selected series.')
    progress('Resampling the volume onto the reference MRI grid')
    resampled = sitk.Resample(moving, fixed, transform, sitk.sitkLinear, 0., sitk.sitkFloat32)
    return transform, resampled, overlap

def run(root, job_id):
    root = Path(root)
    conn = sqlite3.connect(root/'library.sqlite', timeout=60)
    conn.execute('PRAGMA busy_timeout=60000')
    def update(status, stage='', result=None, error=''):
        conn.execute('UPDATE registrations SET status=?,stage=?,result=?,error=?,updated_at=? WHERE id=?',
                     (status, stage, json.dumps(result or {}), error, datetime.datetime.now(datetime.timezone.utc).isoformat(), job_id))
        conn.commit()
    try:
        req = json.loads(conn.execute('SELECT request FROM registrations WHERE id=?', (job_id,)).fetchone()[0])
        # Bound memory/CPU usage across all registrations. Independent pairs use the same fixed reference.
        with open(root/'registration.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            update('running', 'Reading the source series')
            if sha(req['fixed']) != req['referenceHash'] or sha(req['moving']) != req['movingHash']:
                raise ValueError('A source file has changed. Start the registration again.')
            fixed = sitk.ReadImage(req['fixed'], sitk.sitkFloat32)
            moving = sitk.ReadImage(req['moving'], sitk.sitkFloat32)
            transform, aligned, overlap = register(fixed, moving, lambda s: update('running', s))
            folder = root/'registrations'/job_id
            folder.mkdir(parents=True, exist_ok=True)
            output = folder/'aligned.nii.gz'
            temporary = folder/'aligned.tmp.nii.gz'
            sitk.WriteImage(aligned, str(temporary), True)
            os.replace(temporary, output)
            sitk.WriteTransform(transform, str(folder/'fixed-to-moving.tfm'))
            src = nib.load(req['moving'])
            result = dict(url=f'/api/library/assets/reg-{job_id}', transformRAS=ras_matrix(transform).tolist(),
                          movingWorldToVoxel=np.linalg.inv(src.affine).tolist(), movingDimensions=list(src.shape),
                          overlap=overlap, algorithm=req['algorithm'], referenceHash=req['referenceHash'], movingHash=req['movingHash'])
            conn.execute('INSERT OR REPLACE INTO assets(id,path,sha256,size) VALUES(?,?,?,?)',
                         ('reg-'+job_id, str(output.relative_to(root)), sha(output), output.stat().st_size))
            conn.commit()
            update('ready', 'Registered · visual check required', result)
    except Exception as error:
        update('error', 'Registration failed', error=str(error)[:1200])
        raise
    finally:
        conn.close()

if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2])
