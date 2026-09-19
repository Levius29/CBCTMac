'use client';
import { CalendarDays, ChevronRight, X } from 'lucide-react';
import type { Patient, StudyRecord } from './library-workspace';
import { displayDate } from '@/lib/dates';
export default function StudyOverview({
  patient,
  studies,
  selected,
  onSelect,
  onClose,
}: {
  patient: Patient;
  studies: StudyRecord[];
  selected: string;
  onSelect: (id: string) => void;
  onClose: () => void;
}) {
  return (
    <aside className="side-panel overview-panel" aria-label="Study history">
      <header>
        <CalendarDays size={20} />
        <span className="eyebrow">PATIENT HISTORY</span>
        <button
          className="icon-button"
          aria-label="Close history"
          onClick={onClose}
        >
          <X size={18} />
        </button>
      </header>
      <h2>All studies for this patient</h2>
      <p>
        Pick a date to open its images on the right. Every series can be
        explored, points can be marked, and snapshots can be saved.
      </p>
      <nav className="study-timeline" aria-label="All studies of the patient">
        {[...studies].reverse().map((s, i) => (
          <button
            key={s.id}
            aria-current={s.id === selected ? 'step' : undefined}
            onClick={() => onSelect(s.id)}
          >
            <span className="timeline-index">
              {String(i + 1).padStart(2, '0')}
            </span>
            <div>
              <strong>{displayDate(s.date)}</strong>
              <small>{s.label}</small>
            </div>
            <ChevronRight size={15} />
          </button>
        ))}
      </nav>
      {patient.notes && (
        <section>
          <span className="eyebrow">NOTES</span>
          <p>{patient.notes}</p>
        </section>
      )}
      <div className="analysis-status">
        <span className="eyebrow">AUTOMATED ANALYSIS</span>
        <strong>No model connected</strong>
        <p>
          This view shows the images and their metadata. It does not produce
          findings or flag changes between dates.
        </p>
      </div>
    </aside>
  );
}
