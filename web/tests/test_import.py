import hashlib, json, os, shutil, sqlite3, subprocess, sys, tempfile, unittest, uuid, zipfile
from pathlib import Path
import nibabel as nib
import numpy as np
import pydicom
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, MRImageStorage, generate_uid
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from import_mri import main, prepare_volume
ROOT=Path(__file__).resolve().parents[1]
class ImportTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
  subprocess.run(['node','--experimental-strip-types','-e',"import('./lib/library.ts').then(m=>m.db())"],cwd=ROOT,env={**os.environ,'OPENMRI_DATA_DIR':str(self.root)},check=True,capture_output=True)
  self.db=sqlite3.connect(self.root/'library.sqlite');self.db.row_factory=sqlite3.Row
 def tearDown(self):self.db.close();self.temp.cleanup()
 def new_job(self,entries):
  id=str(uuid.uuid4());work=self.root/'jobs'/id;work.mkdir(parents=True)
  with zipfile.ZipFile(work/'source.zip','w') as z:
   for name,data in entries:z.writestr(zipfile.ZipInfo(name,(2024,1,1,0,0,0)),data)
  h=hashlib.sha256((work/'source.zip').read_bytes()).hexdigest()
  self.db.execute('INSERT INTO jobs(id,status,stage,filename,sha256,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',(id,'inspecting','test','test.zip',h,'now','now'));self.db.commit();return id
 def row(self,id):return dict(self.db.execute('SELECT * FROM jobs WHERE id=?',(id,)).fetchone())
 def confirm(self,id,patient=None):
  self.db.execute("UPDATE jobs SET status='processing',result=? WHERE id=?",(json.dumps({'patient':patient or {'name':'Test patient'}}),id));self.db.commit();main(str(self.root),id,'convert')
 def nifti(self):
  p=self.root/'scan.nii.gz';aff=np.diag([1.2,1.3,2.1,1]);aff[:3,3]=[-20,10,-5]
  nib.save(nib.Nifti1Image(np.arange(12*14*16,dtype=np.float32).reshape(12,14,16),aff),p);return p.read_bytes()
 def test_nifti_review_commit_cache_and_duplicate(self):
  data=self.nifti();id=self.new_job([('nested/scan.nii.gz',data)])
  main(str(self.root),id,'inspect');self.assertEqual(self.row(id)['status'],'review');self.assertEqual(self.db.execute('SELECT count(*) FROM patients').fetchone()[0],0)
  self.confirm(id);r=json.loads(self.row(id)['result']);self.assertEqual(self.row(id)['status'],'complete')
  manifest=json.loads(self.db.execute('SELECT manifest FROM studies').fetchone()[0]);s=manifest['series'][0]
  self.assertEqual(s['dimensions'],[12,14,16]);self.assertEqual(s['contrast']['status'],'unspecified')
  asset=self.root/self.db.execute('SELECT path FROM assets').fetchone()[0];self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(),s['sha256'])
  self.assertTrue(np.allclose(nib.load(asset).affine,nib.load(self.root/'scan.nii.gz').affine))
  second=self.new_job([('nested/scan.nii.gz',data)]);main(str(self.root),second,'inspect');self.confirm(second,{'id':r['patientId']});self.assertTrue(json.loads(self.row(second)['result'])['duplicate']);self.assertEqual(self.db.execute('SELECT count(*) FROM studies').fetchone()[0],1)
 def test_demo_archive_imports_as_jane(self):
  archive=ROOT/'demo'/'jane-head-mri.zip';id=str(uuid.uuid4());work=self.root/'jobs'/id;work.mkdir(parents=True);shutil.copy(archive,work/'source.zip')
  self.db.execute('INSERT INTO jobs(id,status,stage,filename,sha256,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',(id,'inspecting','test',archive.name,hashlib.sha256(archive.read_bytes()).hexdigest(),'now','now'));self.db.commit()
  main(str(self.root),id,'inspect');p=json.loads(self.row(id)['preview']);self.assertEqual(p['patient'],{});self.assertEqual(p['seriesCount'],18)
  self.confirm(id,{'name':'Jane'});self.assertEqual(self.row(id)['status'],'complete',self.row(id)['error'])
  self.assertEqual(self.db.execute('SELECT name FROM patients').fetchone()[0],'Jane')
  m=json.loads(self.db.execute('SELECT manifest FROM studies').fetchone()[0]);labels=[s['label'] for s in m['series']];by={s['label']:s for s in m['series']}
  self.assertEqual(labels,["01 +C Axial MPRAGE", "02 Axial MPRAGE", "03 Axial T2", "04 Axial T2 FLAIR", "05 Cor T2", "06 Cor T2 FLAIR", "07 Sag T2", "08 Axial T2 SPC IAM", "09 Sag DIR", "10 Axial SWI", "11 Axial SWI mIP", "12 Axial SWI magnitude", "13 Axial DWI ADC", "14 Axial T1", "15 Sag T1", "16 +C Axial T1 FS", "17 +C Cor T1 FS", "18 +C Sag T1 FS"])
  self.assertEqual(m['defaultSeriesId'],by['01 +C Axial MPRAGE']['id']);self.assertEqual(m['warnings'],['NIfTI files carry no verified patient details or study date.'])
  self.assertEqual([by[l]['contrast']['status'] for l in ('01 +C Axial MPRAGE','02 Axial MPRAGE','16 +C Axial T1 FS','05 Cor T2')],['confirmed','unspecified','confirmed','unspecified'])
  self.assertEqual(by['02 Axial MPRAGE']['dimensions'],[256,256,160]);self.assertEqual(by['09 Sag DIR']['axisCodes'],['R','A','S'])
 def test_zip_traversal_rejected(self):
  id=self.new_job([('../escape.txt',b'bad')])
  with self.assertRaises(ValueError):main(str(self.root),id,'inspect')
  self.assertFalse((self.root/'jobs'/id/'escape.txt').exists());self.assertEqual(self.row(id)['status'],'error')
 def test_4d_is_not_silently_flattened(self):
  p=self.root/'dynamic.nii.gz';nib.save(nib.Nifti1Image(np.zeros((8,8,8,4)),np.eye(4)),p)
  with self.assertRaises(ValueError):prepare_volume(p,self.root/'out.nii.gz','id','dynamic')
 def dicom_entries(self,patient='MRI TEST'):
  study,series=generate_uid(),generate_uid();entries=[]
  for i in range(12):
   meta=FileMetaDataset();meta.TransferSyntaxUID=ExplicitVRLittleEndian;meta.MediaStorageSOPClassUID=MRImageStorage;meta.MediaStorageSOPInstanceUID=generate_uid()
   d=FileDataset('',{},file_meta=meta,preamble=b'\0'*128);d.SOPClassUID=MRImageStorage;d.SOPInstanceUID=meta.MediaStorageSOPInstanceUID;d.StudyInstanceUID=study;d.SeriesInstanceUID=series
   d.PatientName=patient;d.PatientID=patient;d.StudyDate='20240102';d.Modality='MR';d.SeriesDescription='T1 POST';d.MRAcquisitionType='3D';d.SeriesNumber=1;d.InstanceNumber=i+1
   d.Rows=16;d.Columns=16;d.PixelSpacing=[1,1];d.SliceThickness=2;d.ImagePositionPatient=[0,0,i*2];d.ImageOrientationPatient=[1,0,0,0,1,0];d.SamplesPerPixel=1;d.PhotometricInterpretation='MONOCHROME2';d.BitsAllocated=16;d.BitsStored=16;d.HighBit=15;d.PixelRepresentation=0;d.PixelData=(np.arange(256,dtype=np.uint16)+i).tobytes()
   p=self.root/f'{patient}-{i}.dcm';d.save_as(p,enforce_file_format=True);entries.append((p.name,p.read_bytes()))
  return entries
 def test_dicom_real_converter_and_patient_metadata(self):
  id=self.new_job(self.dicom_entries());main(str(self.root),id,'inspect');p=json.loads(self.row(id)['preview']);self.assertEqual(p['imageCount'],12);self.assertEqual(p['patient']['name'],'MRI TEST')
  self.confirm(id);self.assertEqual(self.row(id)['status'],'complete');s=json.loads(self.db.execute('SELECT manifest FROM studies').fetchone()[0]);self.assertEqual(s['studyDate'],'2024-01-02');self.assertEqual(s['series'][0]['contrast']['status'],'confirmed')
 def test_multiple_patients_require_separate_archives(self):
  id=self.new_job(self.dicom_entries('ALPHA')+self.dicom_entries('BETA'))
  with self.assertRaisesRegex(ValueError,'more than one patient'):main(str(self.root),id,'inspect')
  self.assertEqual(self.db.execute('SELECT count(*) FROM patients').fetchone()[0],0)
if __name__=='__main__':unittest.main()
