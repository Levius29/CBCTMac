'use client';
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import {
  ArrowUpRight,
  Check,
  ChevronRight,
  FolderOpen,
  LoaderCircle,
  Upload,
  Users,
  X,
} from 'lucide-react';
import Viewer from './viewer';
import Welcome from './welcome';
import Intro from './intro';
import { displayDate } from '@/lib/dates';
import { rememberOpened } from '@/lib/recent';
export type Patient = {
  id: string;
  name: string;
  birth_date: string;
  sex: string;
  notes: string;
};
export type StudyRecord = {
  id: string;
  patient_id: string;
  date: string;
  label: string;
  body_part: string;
  created_at: string;
};
type Catalog = {
  patients: Patient[];
  studies: StudyRecord[];
  jobs: {
    id: string;
    status: string;
    stage: string;
    progress: number;
    filename: string;
    error: string;
  }[];
  cache: { files: number; bytes: number };
};
type ImportJob = {
  id: string;
  status: string;
  stage: string;
  progress: number;
  filename: string;
  error: string;
  preview: {
    patient?: Partial<Patient> & { dicomId?: string };
    seriesCount?: number;
    imageCount?: number;
    studies?: { date: string; bodyPart: string; modality: string }[];
    series?: { label: string; count: number }[];
    warnings?: string[];
  };
  result: {
    patientId?: string;
    studyIds?: string[];
    warnings?: string[];
    duplicate?: boolean;
  };
};
/** What the viewer shows and which transition brought the user there. */
type View = { patientId: string; studyId: string; entered: number };
const MAX_ARCHIVE_BYTES = 2 * 1024 ** 3;
const PATIENT_STORAGE_KEY = 'openmri-patient';
const RECENT_STORAGE_KEY = 'openmri-recent';
function readStorage(key: string) {
  try {
    return typeof window !== 'undefined' ? localStorage.getItem(key) : null;
  } catch {
    return null;
  }
}
function writeStorage(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* Local storage is optional. */
  }
}
/** The study to open when only a patient was chosen: the newest import. */
function newestStudy(studies: StudyRecord[], patientId: string) {
  return studies
    .filter((s) => s.patient_id === patientId)
    .sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
}
async function api<T = Record<string, unknown>>(
  url: string,
  options?: RequestInit,
): Promise<T> {
  const r = await fetch(url, options);
  const d = (await r.json()) as T & { error?: string };
  if (!r.ok) throw new Error(d.error || 'The request failed');
  return d;
}
export default function LibraryWorkspace() {
  const [catalog, setCatalog] = useState<Catalog | null>(null),
    [patientId, setPatientId] = useState(
      () => readStorage(PATIENT_STORAGE_KEY) || '',
    ),
    [opened, setOpened] = useState<string[]>(() => {
      try {
        const saved: unknown = JSON.parse(
          readStorage(RECENT_STORAGE_KEY) || '[]',
        );
        return Array.isArray(saved)
          ? saved.filter((x): x is string => typeof x === 'string')
          : [];
      } catch {
        return [];
      }
    }),
    [view, setView] = useState<View | null>(null),
    [introDone, setIntroDone] = useState(0),
    [library, setLibrary] = useState(false),
    [wizard, setWizard] = useState(false),
    [jobId, setJobId] = useState(''),
    [error, setError] = useState(''),
    [edit, setEdit] = useState<Patient | null>(null);
  const refresh = useCallback(async () => {
    try {
      const d = await api<Catalog>('/api/library');
      setCatalog(d);
      setError('');
      return d;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return null;
    }
  }, []);
  useEffect(() => {
    let active = true;
    void api<Catalog>('/api/library')
      .then((d) => {
        if (active) setCatalog(d);
      })
      .catch((e) => {
        if (active) setError(e instanceof Error ? e.message : String(e));
      });
    return () => {
      active = false;
    };
  }, []);
  const patient = catalog?.patients.find((p) => p.id === view?.patientId);
  const studies =
    catalog?.studies.filter((s) => s.patient_id === patient?.id) || [];
  /** Every way into the viewer goes through here, so the transition always plays. */
  function openStudy(nextPatientId: string, studyId: string) {
    setPatientId(nextPatientId);
    writeStorage(PATIENT_STORAGE_KEY, nextPatientId);
    const next = rememberOpened(opened, studyId);
    setOpened(next);
    writeStorage(RECENT_STORAGE_KEY, JSON.stringify(next));
    setLibrary(false);
    setView({ patientId: nextPatientId, studyId, entered: Date.now() });
  }
  function openPatient(id: string, source: Catalog | null = catalog) {
    const study = source ? newestStudy(source.studies, id) : undefined;
    if (study) openStudy(id, study.id);
    else {
      setPatientId(id);
      writeStorage(PATIENT_STORAGE_KEY, id);
      setLibrary(false);
      setView(null);
    }
  }
  function upload(id = '') {
    setJobId(id);
    setWizard(true);
  }
  const showingViewer = !!(view && patient && studies.length);
  const viewStudy = studies.find((s) => s.id === view?.studyId) || studies[0];
  return (
    <>
      {showingViewer ? (
        <>
          <Viewer
            key={patient!.id}
            patient={patient!}
            studies={studies}
            initialStudy={view!.studyId}
            patients={catalog!.patients}
            onPatient={(id) => openPatient(id)}
            onLibrary={() => setLibrary(true)}
            onImport={() => upload()}
            onEdit={() => setEdit({ ...patient! })}
            onHome={() => setView(null)}
          />
          {view!.entered !== introDone && (
            <Intro
              key={view!.entered}
              title={patient!.name}
              subtitle={`${displayDate(viewStudy.date)} · ${viewStudy.label}`}
              onDone={() => setIntroDone(view!.entered)}
            />
          )}
        </>
      ) : (
        <Welcome
          patients={catalog?.patients || []}
          studies={catalog?.studies || []}
          opened={opened}
          loading={!catalog && !error}
          onOpen={openStudy}
          onImport={() => upload()}
          onLibrary={() => setLibrary(true)}
        />
      )}
      {error && (
        <div className="global-error" role="alert">
          {error}
          <button onClick={() => void refresh()}>Retry</button>
        </div>
      )}
      {library && catalog && (
        <Modal label="Patient library" onClose={() => setLibrary(false)}>
          <header>
            <div>
              <span className="eyebrow">LIBRARY</span>
              <h2>Patients and studies</h2>
            </div>
            <button
              className="icon-button"
              aria-label="Close library"
              onClick={() => setLibrary(false)}
            >
              <X />
            </button>
          </header>
          <div className="library-stats">
            <span>{plural(catalog.patients.length, 'patient')}</span>
            <span>{plural(catalog.studies.length, 'study', 'studies')}</span>
            <span>
              {(catalog.cache.bytes / 1024 ** 3).toFixed(2)} GB · volume cache
            </span>
          </div>
          <div className="patient-grid">
            {catalog.patients.map((p) => (
              <button
                className={`patient-item ${p.id === patientId ? 'current' : ''}`}
                key={p.id}
                onClick={() => openPatient(p.id)}
              >
                <Users size={22} />
                <div>
                  <strong>{p.name}</strong>
                  <span>
                    {p.birth_date
                      ? displayDate(p.birth_date)
                      : 'No date of birth'}{' '}
                    ·{' '}
                    {plural(
                      catalog.studies.filter((s) => s.patient_id === p.id)
                        .length,
                      'study',
                      'studies',
                    )}
                  </span>
                </div>
                <ArrowUpRight size={18} />
              </button>
            ))}
          </div>
          {catalog.jobs.length > 0 && (
            <>
              <h3>Imports</h3>
              {catalog.jobs.map((j) => (
                <button
                  className="import-resume"
                  key={j.id}
                  onClick={() => upload(j.id)}
                >
                  <span>{j.filename}</span>
                  <small>
                    {j.stage}
                    {j.status === 'error' ? ' · failed' : ''}
                  </small>
                  <ChevronRight size={16} />
                </button>
              ))}
            </>
          )}
          <footer>
            <p>
              Source archives and prepared volumes are stored on this computer.
            </p>
            <button className="primary-action" onClick={() => upload()}>
              <Upload size={17} /> Import archive
            </button>
          </footer>
        </Modal>
      )}
      {wizard && (
        <ImportWizard
          id={jobId}
          patients={catalog?.patients || []}
          currentPatientId={patientId}
          onClose={() => {
            setWizard(false);
            void refresh();
          }}
          onComplete={(id) => {
            setWizard(false);
            void refresh().then((d) => openPatient(id, d));
          }}
        />
      )}
      {edit && (
        <Modal label="Patient details" onClose={() => setEdit(null)}>
          <form
            className="patient-editor"
            onSubmit={async (e) => {
              e.preventDefault();
              try {
                await api('/api/library', {
                  method: 'PATCH',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify(edit),
                });
                setEdit(null);
                void refresh();
              } catch (e) {
                setError(e instanceof Error ? e.message : String(e));
              }
            }}
          >
            <header>
              <div>
                <span className="eyebrow">PATIENT DETAILS</span>
                <h2>{edit.name}</h2>
              </div>
              <button
                type="button"
                className="icon-button"
                aria-label="Close patient details"
                onClick={() => setEdit(null)}
              >
                <X />
              </button>
            </header>
            <PatientFields
              value={edit}
              onChange={(p) => setEdit({ ...edit, ...p })}
            />
            <button className="primary-action" type="submit">
              Save changes
            </button>
          </form>
        </Modal>
      )}
    </>
  );
}
function plural(count: number, singular: string, pluralForm = `${singular}s`) {
  return `${count} ${count === 1 ? singular : pluralForm}`;
}
function PatientFields({
  value,
  onChange,
}: {
  value: Partial<Patient>;
  onChange: (value: Partial<Patient>) => void;
}) {
  return (
    <div className="patient-fields">
      <label>
        Patient name
        <input
          required
          maxLength={160}
          value={value.name || ''}
          onChange={(e) => onChange({ name: e.target.value })}
        />
      </label>
      <div className="field-row">
        <label>
          Date of birth
          <input
            type="date"
            value={value.birth_date || ''}
            onChange={(e) => onChange({ birth_date: e.target.value })}
          />
        </label>
        <label>
          Sex
          <select
            value={value.sex || ''}
            onChange={(e) => onChange({ sex: e.target.value })}
          >
            <option value="">Not specified</option>
            <option value="F">Female</option>
            <option value="M">Male</option>
            <option value="O">Other</option>
          </select>
        </label>
      </div>
      <label>
        Notes
        <textarea
          value={value.notes || ''}
          maxLength={4000}
          rows={3}
          placeholder="Anything worth remembering when viewing these scans"
          onChange={(e) => onChange({ notes: e.target.value })}
        />
      </label>
    </div>
  );
}
function ImportWizard({
  id,
  patients,
  currentPatientId,
  onClose,
  onComplete,
}: {
  id: string;
  patients: Patient[];
  currentPatientId: string;
  onClose: () => void;
  onComplete: (id: string) => void;
}) {
  const [jobId, setJobId] = useState(id),
    [job, setJob] = useState<ImportJob | null>(null),
    [uploading, setUploading] = useState(false),
    [percent, setPercent] = useState(0),
    [error, setError] = useState(''),
    [selection, setSelection] = useState('new'),
    [patient, setPatient] = useState<Partial<Patient>>({
      name: '',
      birth_date: '',
      sex: '',
      notes: '',
    }),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!jobId) return;
    let alive = true;
    const poll = async () => {
      try {
        const d = await api<ImportJob>('/api/library/imports/' + jobId);
        if (alive) {
          setJob(d);
          if (d.status === 'review')
            setPatient((p) => (p.name ? p : { ...p, ...d.preview.patient }));
        }
      } catch (e) {
        if (alive) setError(e instanceof Error ? e.message : String(e));
      }
    };
    void poll();
    const t = setInterval(() => void poll(), 1500);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [jobId]);
  async function upload(file: File) {
    if (uploading || jobId) return;
    setError('');
    if (!/\.zip$/i.test(file.name)) {
      setError('Please choose a ZIP archive');
      return;
    }
    if (file.size > MAX_ARCHIVE_BYTES) {
      setError('The archive must be 2 GB or smaller');
      return;
    }
    setUploading(true);
    try {
      const { id: newId } = await api<{ id: string }>('/api/library/imports', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ filename: file.name }),
      });
      setJobId(newId);
      await new Promise<void>((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('PUT', '/api/library/imports/' + newId);
        xhr.upload.onprogress = (e) => {
          if (e.lengthComputable)
            setPercent(Math.round((e.loaded / e.total) * 100));
        };
        xhr.onload = () =>
          xhr.status >= 200 && xhr.status < 300
            ? resolve()
            : reject(
                new Error(
                  JSON.parse(xhr.responseText || '{}').error || 'Upload failed',
                ),
              );
        xhr.onerror = () => reject(new Error('The connection was interrupted'));
        xhr.send(file);
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setUploading(false);
    }
  }
  const step =
    job?.status === 'complete'
      ? 4
      : job?.status === 'processing'
        ? 3
        : job?.status === 'review'
          ? 2
          : 1;
  async function confirm() {
    setBusy(true);
    setError('');
    try {
      await api('/api/library/imports/' + jobId, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          patient: selection === 'new' ? patient : { id: selection },
        }),
      });
      setJob((j) =>
        j
          ? {
              ...j,
              status: 'processing',
              progress: 0,
              stage: 'Preparing volumes',
            }
          : j,
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal label="Import MRI" onClose={onClose}>
      <header>
        <div>
          <span className="eyebrow">NEW STUDY</span>
          <h2>{step === 4 ? 'Ready to view.' : 'Import an archive.'}</h2>
        </div>
        <button
          className="icon-button"
          aria-label="Close the import wizard"
          onClick={onClose}
        >
          <X />
        </button>
      </header>
      <ol className="wizard-steps">
        {['Archive', 'Patient', 'Processing', 'Done'].map((s, i) => (
          <li
            key={s}
            className={step === i + 1 ? 'current' : step > i + 1 ? 'done' : ''}
          >
            <span>{step > i + 1 ? <Check size={13} /> : i + 1}</span>
            {s}
          </li>
        ))}
      </ol>
      {!jobId && (
        <label className="upload-zone">
          <Upload size={36} />
          <strong>Drop an MRI archive here</strong>
          <span>or choose a file on your computer</span>
          <input
            type="file"
            accept=".zip"
            aria-label="MRI ZIP archive"
            onChange={(e) => {
              if (e.target.files?.[0]) void upload(e.target.files[0]);
            }}
          />
          <small>
            ZIP up to 2 GB · DICOM and NIfTI · MRI or CT of any body part
          </small>
        </label>
      )}
      {(uploading ||
        (job &&
          ['created', 'uploading', 'inspecting', 'processing'].includes(
            job.status,
          ))) && (
        <div className="import-progress">
          <LoaderCircle size={32} className="spin" />
          <h3>{uploading ? 'Uploading the archive' : job?.stage}</h3>
          <p>{job?.filename}</p>
          <progress
            max={100}
            value={uploading ? percent : job?.progress || 0}
          />
          <span>{uploading ? percent : job?.progress || 0}%</span>
          <p>
            {uploading
              ? 'Keep this page open until the transfer finishes.'
              : 'Processing runs on this computer. You can close this window and come back through the library.'}
          </p>
        </div>
      )}
      {job?.status === 'review' && (
        <div className="import-review">
          <div className="review-summary">
            <FolderOpen />
            <div>
              <strong>
                {plural(job.preview.seriesCount ?? 0, 'series', 'series')} ·{' '}
                {plural(job.preview.imageCount ?? 0, 'DICOM file')}
              </strong>
              <p>
                {job.preview.studies
                  ?.map(
                    (s) =>
                      `${displayDate(s.date)} · ${s.modality} ${s.bodyPart}`,
                  )
                  .join(' / ') || 'NIfTI · study date unknown'}
              </p>
            </div>
          </div>
          <label className="patient-choice">
            Add the study to
            <select
              aria-label="Patient to add the study to"
              value={selection}
              onChange={(e) => setSelection(e.target.value)}
            >
              <option value="new">New patient</option>
              {patients.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                  {p.id === currentPatientId ? ' · current' : ''}
                </option>
              ))}
            </select>
          </label>
          {selection === 'new' ? (
            <PatientFields
              value={patient}
              onChange={(p) => setPatient({ ...patient, ...p })}
            />
          ) : (
            <p className="import-notice">
              The archive says: {job.preview.patient?.name || 'no name'}
              {job.preview.patient?.birth_date
                ? ` · ${displayDate(job.preview.patient.birth_date)}`
                : ''}
              . Make sure this matches the selected patient.
            </p>
          )}
          <details>
            <summary>Archive contents and limitations</summary>
            <p>
              4D time series, color functional maps, and single frames are not
              converted into static 3D volumes. The original archive is kept in
              full.
            </p>
            {job.preview.series?.map((s, i) => (
              <div key={i}>
                {s.label} · {s.count}
              </div>
            ))}
            {job.preview.warnings?.map((s) => (
              <p key={s}>{s}</p>
            ))}
          </details>
          <button
            className="primary-action"
            disabled={busy || (selection === 'new' && !patient.name?.trim())}
            onClick={() => void confirm()}
          >
            {busy ? (
              <LoaderCircle className="spin" size={17} />
            ) : (
              <ChevronRight size={17} />
            )}
            Prepare the study
          </button>
        </div>
      )}
      {job?.status === 'complete' && (
        <div className="import-complete">
          <Check size={42} />
          <h3>
            {job.result.duplicate
              ? 'This archive is already in the library'
              : 'Studies saved'}
          </h3>
          <p>
            The original archive and the 3D cache are stored locally. Opening
            the study again needs no processing.
          </p>
          {!!job.result.warnings?.length && (
            <details>
              <summary>
                Skipped series and warnings ({job.result.warnings.length})
              </summary>
              {job.result.warnings.map((w, i) => (
                <p key={i}>{w}</p>
              ))}
            </details>
          )}
          <button
            className="primary-action"
            onClick={() => onComplete(job.result.patientId!)}
          >
            Open the scans <ArrowUpRight size={17} />
          </button>
        </div>
      )}
      {(error || job?.error) && (
        <p className="import-error" role="alert">
          {error || job?.error}
        </p>
      )}
      {job && ['error', 'review', 'created'].includes(job.status) && (
        <button
          className="text-button"
          onClick={async () => {
            try {
              await api('/api/library/imports/' + jobId, { method: 'DELETE' });
              setJobId('');
              setJob(null);
              setError('');
            } catch (e) {
              setError(e instanceof Error ? e.message : String(e));
            }
          }}
        >
          Discard this import draft
        </button>
      )}
      <footer className="wizard-footer">
        <span>Processed on this computer</span>
        <span>No scans are sent to the cloud</span>
      </footer>
    </Modal>
  );
}

function Modal({
  label,
  onClose,
  children,
}: {
  label: string;
  onClose: () => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    ref.current?.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      className="library-modal"
      aria-label={label}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
    >
      {children}
    </dialog>
  );
}
