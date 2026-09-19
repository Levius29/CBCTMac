"""Local, restart-independent ZIP -> DICOM review -> immutable NIfTI cache worker."""
import fcntl, hashlib, json, os, re, shutil, sqlite3, stat, subprocess, sys, time, uuid, zipfile
from pathlib import Path
import nibabel as nib
import numpy as np
import pydicom
from nibabel.processing import resample_from_to


def date(value):
    s=str(value or '')
    return f'{s[:4]}-{s[4:6]}-{s[6:8]}' if re.fullmatch(r'\d{8}',s) else ''

def dcm2niix_path():
    """Prefer the converter bundled in the project virtualenv, then DCM2NIIX, then PATH."""
    explicit=os.environ.get('DCM2NIIX')
    if explicit:return explicit
    local=Path(sys.executable).with_name('dcm2niix'+('.exe' if os.name=='nt' else ''))
    return str(local) if local.exists() else shutil.which('dcm2niix')

def digest(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def prepare_volume(source, output, series_id, label, meta=None):
    meta=meta or {}
    original=nib.load(str(source))
    if len(original.shape)!=3 or min(original.shape)<2:
        raise ValueError('Not a 3D volume (4D series and single frames are skipped)')
    if np.prod(original.shape)>512**3*2: raise ValueError('The volume is too large')
    native_shape=list(original.shape); native_spacing=list(map(float,original.header.get_zooms()[:3]))
    img=nib.as_closest_canonical(original)
    # Preserve voxel-center geometry and physical field of view on downsampling.
    target=np.minimum(np.array(img.shape),320)
    if np.any(target != img.shape):
        ratio=(np.array(img.shape)-1)/(target-1)
        affine=img.affine.copy(); affine[:3,:3]=affine[:3,:3] @ np.diag(ratio)
        img=resample_from_to(img,(tuple(target),affine),order=1)
    data=np.nan_to_num(img.get_fdata(dtype=np.float32),copy=False)
    sample=data.ravel()[::max(1,data.size//500000)]
    positive=sample[sample>0]
    lo,hi=np.percentile(positive if positive.size>100 else sample,[.5,99.5])
    if hi<=lo:hi=lo+1
    clean=nib.Nifti1Image(data,img.affine)
    clean.header['cal_min']=lo;clean.header['cal_max']=hi
    output=Path(output);output.parent.mkdir(parents=True,exist_ok=True)
    tmp=output.with_name(output.name.replace('.nii.gz','.partial.nii.gz'))
    nib.save(clean,str(tmp));os.replace(tmp,output)
    description=meta.get('description',label)
    post=bool(meta.get('agent')) or bool(re.search(r'(^|[ _])(?:\+C|POST|CE)(?:[ _]|$)',description,re.I))
    return {'id':series_id,'label':label,'shortLabel':label,'description':description,
      'originalSeriesDescription':description,'acquisitionType':meta.get('acquisitionType','3D'),
      'contrast':{'status':'confirmed' if post else 'unspecified','agent':meta.get('agent','')},
      'sourceImageCount':meta.get('count',native_shape[2]),'nativeDimensions':native_shape,
      'nativeVoxelMm':native_spacing,'dimensions':list(clean.shape),
      'voxelMm':list(map(float,clean.header.get_zooms()[:3])), 'axisCodes':list(nib.aff2axcodes(clean.affine)),
      'affineRASmm':clean.affine.tolist(),'displayRange':[float(lo),float(hi)],
      'url':f'/api/library/assets/{series_id}','volumeBytes':output.stat().st_size,'sha256':digest(output)}


def main(root,job_id,action):
    root=Path(root); work=root/'jobs'/job_id; work.mkdir(parents=True,exist_ok=True)
    db=sqlite3.connect(root/'library.sqlite',timeout=30);db.row_factory=sqlite3.Row;db.execute('PRAGMA foreign_keys=ON')
    def update(status,stage,progress=0,**extra):
        fields={'status':status,'stage':stage,'progress':progress,'updated_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),**extra}
        db.execute('UPDATE jobs SET '+','.join(f'{k}=?' for k in fields)+' WHERE id=?',[*fields.values(),job_id]);db.commit()
    lock=None
    try:
        job=dict(db.execute('SELECT * FROM jobs WHERE id=?',(job_id,)).fetchone())
        if action=='inspect':
            update('inspecting','Extracting and inspecting',5)
            extraction=work/'extracted';extraction.mkdir(exist_ok=True)
            with zipfile.ZipFile(work/'source.zip') as z:
                entries=z.infolist()
                if len(entries)>60000 or sum(i.file_size for i in entries)>12*1024**3:raise ValueError('The archive exceeds the limit of 60,000 files or 12 GB when extracted')
                if sum(i.file_size for i in entries)+1024**3>shutil.disk_usage(root).free:raise ValueError('Not enough free disk space for extraction and the cache')
                for i in entries:
                    name=i.filename.replace('\\','/')
                    parts=Path(name).parts
                    if name.startswith('/') or '..' in parts or stat.S_ISLNK(i.external_attr>>16):raise ValueError('The archive contains an unsafe path or a symbolic link')
                    if i.flag_bits&1:raise ValueError('The archive is password protected. Use a ZIP without a password')
                    if i.is_dir():continue
                    if i.file_size>2*1024**3:raise ValueError('A single file in the archive is too large')
                    dest=extraction.joinpath(*parts);dest.parent.mkdir(parents=True,exist_ok=True)
                    with z.open(i) as src,open(dest,'wb') as dst:shutil.copyfileobj(src,dst,1024*1024)
            groups={};niftis=[];identities={};skipped=0;seen=set()
            files=list(extraction.rglob('*'))
            for n,p in enumerate(files):
                if not p.is_file() or '__MACOSX' in p.parts:continue
                if n%150==0:update('inspecting','Reading DICOM headers',10+int(75*n/max(1,len(files))))
                if p.name.lower().endswith(('.nii','.nii.gz')):
                    niftis.append(str(p));continue
                try:
                    d=pydicom.dcmread(p,stop_before_pixels=True,force=True)
                    if not getattr(d,'SeriesInstanceUID',None) or not getattr(d,'Rows',None):continue
                    if str(getattr(d,'Modality','')) not in ('MR','CT') or int(getattr(d,'SamplesPerPixel',1))!=1:
                        skipped+=1;continue
                    sop=str(getattr(d,'SOPInstanceUID',p))
                    if sop in seen:continue
                    seen.add(sop)
                    identity=(str(getattr(d,'PatientID','')),str(getattr(d,'PatientName','')),str(getattr(d,'PatientBirthDate','')))
                    if any(identity):identities[identity]={'name':identity[1].replace('^',' ').strip(),'dicomId':identity[0],'birth_date':date(identity[2]),'sex':str(getattr(d,'PatientSex',''))}
                    key=str(d.SeriesInstanceUID)
                    if key not in groups:
                        groups[key]={'uid':key,'studyUid':str(getattr(d,'StudyInstanceUID',key)),'date':date(getattr(d,'StudyDate','')),
                        'description':str(getattr(d,'SeriesDescription','Series')),'bodyPart':str(getattr(d,'BodyPartExamined','')),
                        'modality':str(d.Modality),'acquisitionType':str(getattr(d,'MRAcquisitionType','3D')),
                        'agent':str(getattr(d,'ContrastBolusAgent','')),'files':[]}
                    groups[key]['files'].append(str(p))
                except (OSError,ValueError,TypeError,AttributeError):continue
            if len(identities)>1:raise ValueError('The archive contains more than one patient. Split it into one archive per patient before importing')
            if not groups and not niftis:raise ValueError('No volumetric MR/CT DICOM or NIfTI files found. PDFs, images, and nested ZIPs are not volumes')
            index={'groups':list(groups.values()),'niftis':sorted(niftis)}
            (work/'index.json').write_text(json.dumps(index))
            preview={'patient':next(iter(identities.values()),{}),'seriesCount':len(groups)+len(niftis),'imageCount':len(seen),
                'studies':list({(g['studyUid'],g['date']):{'date':g['date'],'bodyPart':g['bodyPart'],'modality':g['modality']} for g in groups.values()}.values()),
                'series':[{'label':g['description'],'count':len(g['files'])} for g in groups.values()],
                'warnings':([f'Skipped color or unsupported DICOM files: {skipped}'] if skipped else [])+(['NIfTI files carry no verified patient details or study date.'] if niftis else [])}
            update('review','Confirm the patient',100,preview=json.dumps(preview,ensure_ascii=False));return
        if action!='convert':raise ValueError('Unknown action')
        update('processing','Waiting for a free worker')
        lock=open(root/'processor.lock','a')
        fcntl.flock(lock,fcntl.LOCK_EX)
        index=json.loads((work/'index.json').read_text());selection=json.loads(job['result'])['patient']
        patient_id=selection.get('id') or str(uuid.uuid4())
        existing=db.execute('SELECT id,patient_id FROM studies WHERE source_hash=?',(job['sha256'],)).fetchall()
        if existing:
            if any(s['patient_id']!=patient_id for s in existing):raise ValueError('This archive was already imported for another patient. Open that patient in the library')
            update('complete','The archive is already in the library',100,result=json.dumps({'patientId':patient_id,'studyIds':[s['id'] for s in existing],'duplicate':True}));shutil.rmtree(work/'extracted',ignore_errors=True);return
        binary=dcm2niix_path()
        if index['groups'] and not binary:raise ValueError('dcm2niix is not installed. Run: npm run setup')
        studies={};assets=[];warnings=json.loads(job['preview']).get('warnings',[])
        groups=index['groups']+[{'uid':digest(p),'studyUid':'nifti-'+job['sha256'],'date':'','description':re.sub(r'\.nii(\.gz)?$','',Path(p).name,flags=re.I),'bodyPart':'','modality':'MR','nifti':p} for p in index['niftis']]
        for i,g in enumerate(groups):
            update('processing',f'Preparing series {i+1} / {len(groups)}',int(95*i/len(groups)))
            try:
                if 'nifti' in g: outputs=[Path(g['nifti'])]
                else:
                    groupdir=work/'groups'/str(i);groupdir.mkdir(parents=True,exist_ok=True)
                    for j,p in enumerate(g['files']):
                        dest=groupdir/f'{j}.dcm'
                        if not dest.exists():os.link(p,dest)
                    out=work/'converted'/str(i);out.mkdir(parents=True,exist_ok=True)
                    result=subprocess.run([binary,'-z','y','-b','n','-f','volume','-o',str(out),str(groupdir)],capture_output=True,timeout=180)
                    outputs=sorted(out.glob('*.nii.gz'))
                    if result.returncode or not outputs:raise ValueError('The converter could not build a volume')
                for k,p in enumerate(outputs):
                    asset_id=str(uuid.uuid5(uuid.NAMESPACE_URL,'pipeline-v2:'+job['sha256']+g['uid']+str(k)))
                    dest=root/'volumes'/f'{asset_id}.nii.gz'
                    label=g['description']+(f' · {k+1}' if len(outputs)>1 else '')
                    s=prepare_volume(p,dest,asset_id,label,{**g,'count':len(g.get('files',[])) or None})
                    if not s['sourceImageCount']:s['sourceImageCount']=s['nativeDimensions'][2]
                    st=studies.setdefault(g['studyUid'],{'date':g['date'],'bodyPart':g['bodyPart'],'modality':g['modality'],'series':[]})
                    st['series'].append(s);assets.append((asset_id,str(dest.relative_to(root)),s['sha256'],s['volumeBytes']))
            except (ValueError,OSError,subprocess.TimeoutExpired,nib.filebasedimages.ImageFileError) as e:warnings.append(f"{g['description']}: {e}")
        if not studies:raise ValueError('No 3D volume could be prepared. '+('; '.join(warnings[-3:])))
        ids=[];now=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        with db:
            if not selection.get('id'):db.execute('INSERT INTO patients VALUES(?,?,?,?,?,?)',(patient_id,selection['name'],selection.get('birth_date',''),selection.get('sex',''),selection.get('notes',''),now))
            for uid,st in studies.items():
                prior=db.execute('SELECT id,manifest FROM studies WHERE patient_id=? AND study_uid=?',(patient_id,uid)).fetchone()
                sid=prior['id'] if prior else str(uuid.uuid4());ids.append(sid)
                series=st['series']
                if prior:
                    old=json.loads(prior['manifest']);seen_ids={s['id'] for s in old['series']};series=old['series']+[s for s in series if s['id'] not in seen_ids]
                manifest={'studyId':sid,'studyDate':st['date'],'bodyPart':st['bodyPart'],'modality':st['modality'],'defaultSeriesId':series[0]['id'],'series':series,'warnings':warnings,'registration':{'withinStudy':'scanner coordinates; motion not corrected','betweenStudies':'not performed'}}
                db.execute('INSERT INTO studies VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET manifest=excluded.manifest',(sid,patient_id,uid,st['date'],st['modality']+' · '+(st['bodyPart'] or 'Study'),st['bodyPart'],json.dumps(manifest),job['sha256'],now))
            db.executemany('INSERT OR IGNORE INTO assets VALUES(?,?,?,?)',assets)
        sources=root/'sources';sources.mkdir(exist_ok=True)
        dest=sources/(job['sha256']+'.zip')
        if not dest.exists():shutil.move(work/'source.zip',dest)
        else:(work/'source.zip').unlink(missing_ok=True)
        for name in ('extracted','groups','converted'):shutil.rmtree(work/name,ignore_errors=True)
        update('complete','Done',100,result=json.dumps({'patientId':patient_id,'studyIds':ids,'warnings':warnings}))
    except Exception as e:
        update('error','Import stopped',error=str(e)[:1800])
        raise
    finally:
        if lock is not None:lock.close()
        db.close()

if __name__=='__main__':main(*sys.argv[1:4])
