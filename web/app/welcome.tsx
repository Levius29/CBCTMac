'use client';
import {
  ArrowUpRight,
  FolderOpen,
  LoaderCircle,
  Orbit,
  Plus,
  Scan,
  ShieldCheck,
} from 'lucide-react';
import Link from 'next/link';
import { displayDate } from '@/lib/dates';
import { recentStudies } from '@/lib/recent';
import type { Patient, StudyRecord } from './library-workspace';

export default function Welcome({
  patients,
  studies,
  opened,
  loading,
  onOpen,
  onImport,
  onLibrary,
}: {
  patients: Patient[];
  studies: StudyRecord[];
  opened: string[];
  loading: boolean;
  onOpen: (patientId: string, studyId: string) => void;
  onImport: () => void;
  onLibrary: () => void;
}) {
  const recent = recentStudies(studies, opened);
  const names = new Map(patients.map((p) => [p.id, p.name]));
  const returning = !loading && studies.length > 0;
  return (
    <main className="welcome">
      <div className="welcome-backdrop" aria-hidden="true" />
      <header className="welcome-brand">
        <Orbit strokeWidth={1.25} />
        <span>OPENMRI</span>
        <small>LOCAL MRI VIEWER</small>
      </header>
      <section className="welcome-content">
        <span className="eyebrow">
          {returning ? 'WELCOME BACK' : 'GET STARTED'}
        </span>
        <h1>
          {returning ? (
            <>
              Your MRI,
              <br />
              <span>in 3D.</span>
            </>
          ) : (
            <>
              Your scans,
              <br />
              <span>on your computer.</span>
            </>
          )}
        </h1>
        <p>
          {returning
            ? 'Open a recent study, or import a new archive. Everything stays on this computer.'
            : 'Import the ZIP archive from the imaging centre and explore it in 3D and on three linked slices. Nothing leaves this computer.'}
        </p>
        <div className="welcome-actions">
          <button className="primary-action" onClick={onImport}>
            <Plus size={18} />{' '}
            {returning ? 'Import a new MRI' : 'Import your first MRI'}
          </button>
          {patients.length > 0 && (
            <button className="export-button" onClick={onLibrary}>
              <FolderOpen size={17} /> Open library
            </button>
          )}
          {/* CBCTMac: la ricostruzione dentale apre i .dcm direttamente, senza archivio. Senza
              questo ingresso ci si arrivava solo da uno studio già aperto — cioè mai, alla prima
              volta. Vedi docs/openmri-dental.md § Modifiche locali. */}
          <Link className="export-button" href="/dental" prefetch={false}>
            <Scan size={17} /> Dental · open .dcm files
          </Link>
        </div>
        {loading && (
          <LoaderCircle className="spin" aria-label="Loading the library" />
        )}
        {recent.length > 0 && (
          <section className="welcome-recent" aria-label="Recent studies">
            <h2>Recent studies</h2>
            <ol>
              {recent.map((s, i) => (
                <li key={s.id}>
                  <button onClick={() => onOpen(s.patient_id, s.id)}>
                    <span className="recent-index">
                      {String(i + 1).padStart(2, '0')}
                    </span>
                    <span className="recent-text">
                      <strong>
                        {names.get(s.patient_id) || 'Unknown patient'}
                      </strong>
                      <small>
                        {displayDate(s.date)} · {s.label}
                      </small>
                    </span>
                    <ArrowUpRight size={16} />
                  </button>
                </li>
              ))}
            </ol>
          </section>
        )}
      </section>
      <footer className="welcome-footer">
        <ShieldCheck size={13} />
        <span>Runs locally · Visualization only, not for diagnosis</span>
      </footer>
    </main>
  );
}
