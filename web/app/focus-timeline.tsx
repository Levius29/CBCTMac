'use client';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Image from 'next/image';
import {
  Crosshair,
  X,
  Play,
  Pause,
  Save,
  Check,
  ArrowLeftRight,
  LoaderCircle,
  RefreshCw,
  Plus,
  Trash2,
} from 'lucide-react';
import TimelineVolume, {
  type CameraState,
  type TimelineView,
} from './timeline-volume';
import {
  compatible,
  covered,
  seriesCaption,
  transformPoint,
  type FocusRegion,
  type Registration,
  type TimelineStudy,
  type Vec3,
} from '@/lib/focus-timeline';
import { displayDate } from '@/lib/dates';
async function api<T>(
  url: string,
  body?: unknown,
  method = 'POST',
  signal?: AbortSignal,
): Promise<T> {
  const r = await fetch(
    url,
    body
      ? {
          method,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
          signal,
        }
      : { signal },
  );
  const d = (await r.json()) as T & { error?: string };
  if (!r.ok) throw new Error(d.error || 'The request failed');
  return d;
}
const urlFor = (url: string) =>
  url.startsWith('/api/') ? url : `/api/${url.replace(/^\//, '')}`;
const defaultCamera: CameraState = {
  azimuth: 120,
  elevation: 10,
  scale: 1.05,
  pan: [0, 0, 0, 1],
};
export default function FocusTimeline({
  patientId,
  patientName,
  initialStudy,
  initialSeries,
  initialPoint,
  onClose,
}: {
  patientId: string;
  patientName: string;
  initialStudy: string;
  initialSeries: string;
  initialPoint: Vec3 | null;
  onClose: () => void;
}) {
  const [studies, setStudies] = useState<TimelineStudy[]>([]),
    [regions, setRegions] = useState<FocusRegion[]>([]),
    [region, setRegion] = useState<FocusRegion | null>(null);
  const [fixedId, setFixedId] = useState(initialStudy),
    [fixedSeriesId, setFixedSeriesId] = useState(initialSeries);
  const [movingId, setMovingId] = useState(''),
    [movingSeriesId, setMovingSeriesId] = useState('');
  const [cursor, setCursor] = useState<Vec3 | null>(initialPoint),
    [name, setName] = useState('New region'),
    [radius, setRadius] = useState(10);
  const [camera, setCamera] = useState<CameraState>(defaultCamera),
    [view, setView] = useState<TimelineView>('all');
  const [cut, setCut] = useState(true);
  const [crop, setCrop] = useState(false);
  const [mode, setMode] = useState<'pair' | 'wipe' | 'blink'>('pair'),
    [wipe, setWipe] = useState(50),
    [blink, setBlink] = useState(false);
  const [registrationState, setRegistration] = useState<Registration | null>(
      null,
    ),
    [retry, setRetry] = useState(0),
    [allowMismatch, setAllowMismatch] = useState(false);
  const [error, setError] = useState(''),
    [message, setMessage] = useState(''),
    [saving, setSaving] = useState(false),
    [playing, setPlaying] = useState(false),
    [readyB, setReadyB] = useState(false);
  const [correcting, setCorrecting] = useState(false),
    [manualPoint, setManualPoint] = useState<Vec3 | null>(null);
  const [preparing, setPreparing] = useState(false),
    [prepareProgress, setPrepareProgress] = useState('');
  const [previews, setPreviews] = useState<Record<string, string>>({}),
    [states, setStates] = useState<Record<string, string>>({});
  const abort = useRef<AbortController | null>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const [registrationKey, setRegistrationKey] = useState('');
  const pairKey = `${fixedId}:${fixedSeriesId}:${movingId}:${movingSeriesId}`;
  const registration = registrationKey === pairKey ? registrationState : null;
  useEffect(() => {
    dialog.current?.showModal();
  }, []);
  const fixed = studies.find((s) => s.id === fixedId),
    fixedSeries = fixed?.series.find((s) => s.id === fixedSeriesId);
  const moving = studies.find((s) => s.id === movingId),
    movingSeries = moving?.series.find((s) => s.id === movingSeriesId);
  const mismatch = !!(
    fixedSeries &&
    movingSeries &&
    !compatible(fixedSeries, movingSeries)
  );
  const review = registration && region?.reviews[registration.id];
  const offset = useMemo(
    () =>
      review?.status === 'corrected' && region
        ? (review.point.map((v, i) => v - region.point[i]) as Vec3)
        : null,
    [review, region],
  );
  const pointB = useMemo(
    () =>
      correcting
        ? manualPoint
        : cursor
          ? offset
            ? (cursor.map((v, i) => v + offset[i]) as Vec3)
            : cursor
          : null,
    [correcting, manualPoint, cursor, offset],
  );
  const result =
    registration?.status === 'ready' && registrationKey === pairKey
      ? registration.result
      : undefined;
  const inBounds = !!(result && pointB && covered(result, pointB));
  const regionFits = !!(result && pointB && covered(result, pointB, radius));
  const cacheKey = `${movingId}:${movingSeriesId}`;
  const hasEdits =
    !!region &&
    (region.name !== name ||
      region.radius !== radius ||
      JSON.stringify(region.point) !== JSON.stringify(cursor));
  const canReview = !!region && !hasEdits && !!result && inBounds;
  useEffect(() => {
    const controller = new AbortController();
    api<{ studies: TimelineStudy[]; regions: FocusRegion[] }>(
      `/api/timeline?patientId=${encodeURIComponent(patientId)}`,
      undefined,
      'GET',
      controller.signal,
    )
      .then((d) => {
        setStudies(d.studies);
        setRegions(d.regions);
        const reference = d.studies
          .find((s) => s.id === initialStudy)
          ?.series.find((s) => s.id === initialSeries);
        const first =
          d.studies
            .slice()
            .reverse()
            .find(
              (s) =>
                s.id !== initialStudy &&
                s.series.some((x) => reference && compatible(reference, x)),
            ) || d.studies.find((s) => s.id !== initialStudy);
        if (first) setMovingId(first.id);
      })
      .catch((e) => {
        if (!controller.signal.aborted) setError(String(e));
      });
    return () => {
      controller.abort();
      abort.current?.abort();
    };
  }, [patientId, initialStudy, initialSeries]);
  useEffect(() => {
    let active = true;
    queueMicrotask(() => {
      if (!active) return;
      setAllowMismatch(false);
      setCorrecting(false);
      setManualPoint(null);
      setReadyB(false);
      setRegistration(null);
      setMovingSeriesId(
        moving && fixedSeries
          ? moving.series.find((s) => compatible(fixedSeries, s))?.id || ''
          : '',
      );
    });
    return () => {
      active = false;
    };
  }, [moving, fixedSeries]);
  useEffect(() => {
    const controller = new AbortController();
    queueMicrotask(() => {
      if (!controller.signal.aborted) {
        setRegistration(null);
        setReadyB(false);
        setError('');
        setCorrecting(false);
        setManualPoint(null);
        setMessage('');
      }
    });
    if (
      !fixedSeries ||
      !movingSeries ||
      fixedId === movingId ||
      (mismatch && !allowMismatch)
    )
      return () => controller.abort();
    async function run() {
      let r = await api<Registration>(
        '/api/timeline/registrations',
        {
          patientId,
          fixedStudy: fixedId,
          fixedSeries: fixedSeriesId,
          movingStudy: movingId,
          movingSeries: movingSeriesId,
          allowMismatch,
        },
        'POST',
        controller.signal,
      );
      while (!controller.signal.aborted) {
        setRegistration(r);
        setRegistrationKey(pairKey);
        setStates((s) => ({ ...s, [cacheKey]: r.status }));
        if (r.status === 'error') setPlaying(false);
        if (r.status === 'ready' || r.status === 'error') break;
        await new Promise<void>((resolve) => {
          const t = setTimeout(resolve, 1200);
          controller.signal.addEventListener(
            'abort',
            () => {
              clearTimeout(t);
              resolve();
            },
            { once: true },
          );
        });
        if (controller.signal.aborted) return;
        r = await api<Registration>(
          `/api/timeline/registrations/${r.id}`,
          undefined,
          'GET',
          controller.signal,
        );
      }
    }
    void run().catch((e) => {
      if (!controller.signal.aborted) setError(String(e));
    });
    return () => controller.abort();
  }, [
    patientId,
    fixedId,
    fixedSeriesId,
    movingId,
    movingSeriesId,
    allowMismatch,
    retry,
    studies,
    fixedSeries,
    movingSeries,
    mismatch,
    cacheKey,
    pairKey,
  ]);
  useEffect(() => {
    if (mode !== 'blink' || !readyB) return;
    const t = setInterval(() => setBlink((v) => !v), 900);
    return () => clearInterval(t);
  }, [mode, readyB]);
  useEffect(() => {
    if (!playing || !readyB || !result || !region || !inBounds) return;
    const t = setTimeout(() => {
      const candidates = studies.filter(
        (s) =>
          s.id !== fixedId &&
          s.series.some((x) => fixedSeries && compatible(fixedSeries, x)),
      );
      const next =
        candidates[candidates.findIndex((s) => s.id === movingId) + 1];
      if (next) setMovingId(next.id);
      else setPlaying(false);
    }, 2800);
    return () => clearTimeout(t);
  }, [
    playing,
    readyB,
    result,
    region,
    review,
    inBounds,
    movingId,
    fixedId,
    fixedSeries,
    studies,
  ]);
  const receiveCamera = useCallback(
    (c: CameraState) =>
      setCamera((old) => (JSON.stringify(old) === JSON.stringify(c) ? old : c)),
    [],
  );
  const receivePoint = useCallback((p: Vec3) => {
    setPlaying(false);
    setPreviews({});
    setCursor((old) =>
      old && old.every((v, i) => Math.abs(v - p[i]) < 0.001) ? old : p,
    );
  }, []);
  function chooseRegion(r: FocusRegion) {
    abort.current?.abort();
    setPlaying(false);
    setRegion(r);
    setFixedId(r.studyId);
    setFixedSeriesId(r.seriesId);
    setName(r.name);
    setRadius(r.radius);
    setCursor(r.point);
    setCamera(defaultCamera);
    setPreviews({});
    setStates({});
    if (movingId === r.studyId)
      setMovingId(studies.find((s) => s.id !== r.studyId)?.id || '');
  }
  function resetReference(studyId: string, seriesId: string) {
    setPlaying(false);
    setRegion(null);
    setFixedId(studyId);
    setFixedSeriesId(seriesId);
    setCursor(null);
    setName('New region');
    setCamera(defaultCamera);
    setPreviews({});
    setStates({});
    if (movingId === studyId)
      setMovingId(studies.find((s) => s.id !== studyId)?.id || '');
  }
  async function save() {
    if (!cursor) return;
    setSaving(true);
    setError('');
    try {
      const r = await api<FocusRegion>('/api/timeline', {
        id: region?.id || '',
        patientId,
        studyId: fixedId,
        seriesId: fixedSeriesId,
        name,
        point: cursor,
        radius,
      });
      setRegion(r);
      setRegions((all) => [...all.filter((x) => x.id !== r.id), r]);
      setMessage('Region saved on this computer');
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }
  async function reviewPoint(status: 'checked' | 'corrected') {
    if (!region || !registration) return;
    setSaving(true);
    setError('');
    try {
      const r = await api<FocusRegion>(
        '/api/timeline',
        {
          patientId,
          regionId: region.id,
          registrationId: registration.id,
          status,
          point: status === 'corrected' ? manualPoint : region.point,
        },
        'PATCH',
      );
      setRegion(r);
      setRegions((all) => all.map((x) => (x.id === r.id ? r : x)));
      setCorrecting(false);
      setManualPoint(null);
      setMessage(
        status === 'corrected'
          ? 'Correction saved for this date'
          : 'Region position marked as checked',
      );
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }
  async function prepareAll() {
    if (!fixedSeries) return;
    const controller = new AbortController();
    abort.current = controller;
    setPreparing(true);
    setError('');
    const dates = studies.filter(
      (s) =>
        s.id !== fixedId && s.series.some((x) => compatible(fixedSeries, x)),
    );
    try {
      for (let i = 0; i < dates.length; i++) {
        if (controller.signal.aborted) break;
        const s = dates[i],
          series = s.series.find((x) => compatible(fixedSeries, x))!;
        setPrepareProgress(
          `${i + 1} / ${dates.length} · ${displayDate(s.date)}`,
        );
        let r = await api<Registration>(
          '/api/timeline/registrations',
          {
            patientId,
            fixedStudy: fixedId,
            fixedSeries: fixedSeriesId,
            movingStudy: s.id,
            movingSeries: series.id,
          },
          'POST',
          controller.signal,
        );
        while (
          !controller.signal.aborted &&
          ['running', 'queued'].includes(r.status)
        ) {
          await new Promise<void>((resolve) => {
            const t = setTimeout(resolve, 1500);
            controller.signal.addEventListener(
              'abort',
              () => {
                clearTimeout(t);
                resolve();
              },
              { once: true },
            );
          });
          if (controller.signal.aborted) break;
          r = await api<Registration>(
            `/api/timeline/registrations/${r.id}`,
            undefined,
            'GET',
            controller.signal,
          );
        }
        if (!controller.signal.aborted)
          setStates((old) => ({ ...old, [`${s.id}:${series.id}`]: r.status }));
      }
    } catch (e) {
      if (!controller.signal.aborted) setError(String(e));
    } finally {
      setPreparing(false);
      setPrepareProgress('');
    }
  }
  return (
    <dialog
      ref={dialog}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      className="focus-timeline"
      aria-modal="true"
      aria-label="Focus over time"
    >
      <header className="timeline-header">
        <div>
          <span className="timeline-eyebrow">
            <Crosshair size={15} /> OPENMRI / OVER TIME
          </span>
          <h1>Focus over time</h1>
          <p>
            {patientName} · {studies.length}{' '}
            {studies.length === 1 ? 'study' : 'studies'} · local registration
          </p>
        </div>
        <button
          className="icon-button"
          aria-label="Close focus over time"
          onClick={onClose}
        >
          <X />
        </button>
      </header>
      <div className="timeline-body">
        <aside className="timeline-sidebar">
          <label>
            Saved regions
            <select
              aria-label="Saved regions"
              value={region?.id || ''}
              onChange={(e) => {
                const r = regions.find((x) => x.id === e.target.value);
                if (r) chooseRegion(r);
              }}
            >
              <option value="">New region</option>
              {regions.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </select>
          </label>
          <button
            onClick={() => {
              setRegion(null);
              setName('New region');
              setMessage('Pick a point on a slice and save a new region');
            }}
          >
            <Plus size={15} /> New region
          </button>
          <label>
            Name
            <input
              aria-label="Region name"
              value={name}
              maxLength={100}
              onChange={(e) => setName(e.target.value)}
            />
          </label>
          <label>
            Neighbourhood radius <b>{radius} mm</b>
            <input
              aria-label="Region radius"
              type="range"
              min="1"
              max="50"
              value={radius}
              onChange={(e) => setRadius(Number(e.target.value))}
            />
          </label>
          <small>
            The sphere marks the neighbourhood of the point. It does not outline
            any lesion.
          </small>
          <button
            className="primary-action"
            disabled={!cursor || saving || !name.trim()}
            onClick={save}
          >
            <Save size={15} />
            {region ? 'Save position' : 'Track this region'}
          </button>
          {region && (
            <>
              <button
                onClick={() => {
                  setCursor(region.point);
                  setRadius(region.radius);
                  setName(region.name);
                }}
              >
                <Crosshair size={15} /> Back to the saved focus
              </button>
              <button
                className="timeline-muted"
                onClick={async () => {
                  try {
                    await api(
                      '/api/timeline',
                      { patientId, id: region.id },
                      'DELETE',
                    );
                    setRegions((a) => a.filter((r) => r.id !== region.id));
                    setRegion(null);
                    setMessage('Region deleted');
                  } catch (e) {
                    setError(String(e));
                  }
                }}
              >
                <Trash2 size={14} /> Delete region
              </button>
            </>
          )}
          <div className="timeline-divider" />
          <label>
            A · Reference date
            <select
              aria-label="Reference date"
              disabled={preparing}
              value={fixedId}
              onChange={(e) => {
                const s = studies.find((s) => s.id === e.target.value)!;
                resetReference(
                  s.id,
                  s.series.find(
                    (x) => fixedSeries && compatible(fixedSeries, x),
                  )?.id ||
                    s.series[0]?.id ||
                    '',
                );
              }}
            >
              {studies.map((s) => (
                <option key={s.id} value={s.id}>
                  {displayDate(s.date)}
                </option>
              ))}
            </select>
          </label>
          <label>
            Reference series
            <select
              aria-label="Reference series"
              disabled={preparing}
              value={fixedSeriesId}
              onChange={(e) => resetReference(fixedId, e.target.value)}
            >
              {fixed?.series.map((s) => (
                <option key={s.id} value={s.id}>
                  {seriesCaption(s)}
                </option>
              ))}
            </select>
          </label>
          <small>
            Every date is registered directly to this series. Changing the
            reference series starts a new region.
          </small>
          <label>
            B · Comparison date
            <select
              aria-label="Comparison date"
              value={movingId}
              onChange={(e) => {
                setPlaying(false);
                setMovingId(e.target.value);
              }}
            >
              {studies
                .filter((s) => s.id !== fixedId)
                .map((s) => (
                  <option key={s.id} value={s.id}>
                    {displayDate(s.date)}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Comparison series
            <select
              aria-label="Series to compare"
              value={movingSeriesId}
              onChange={(e) => {
                setPlaying(false);
                setAllowMismatch(false);
                setMovingSeriesId(e.target.value);
              }}
            >
              <option value="">No matching series, choose manually</option>
              {moving?.series.map((s) => (
                <option key={s.id} value={s.id}>
                  {seriesCaption(s)}
                </option>
              ))}
            </select>
          </label>
          {mismatch && (
            <label className="timeline-warning">
              <input
                type="checkbox"
                checked={allowMismatch}
                onChange={(e) => setAllowMismatch(e.target.checked)}
              />{' '}
              Different series types or contrast phases. Compare anyway.
            </label>
          )}
          <button disabled={preparing || !fixedSeries} onClick={prepareAll}>
            <RefreshCw size={14} className={preparing ? 'spin' : ''} />
            {preparing ? prepareProgress : 'Prepare all matching dates'}
          </button>
          {preparing && (
            <button onClick={() => abort.current?.abort()}>
              Stop the queue after the current pair
            </button>
          )}
        </aside>
        <main className="timeline-main">
          <div className="timeline-toolbar">
            <div className="timeline-segment">
              {(
                [
                  ['pair', 'Side by side'],
                  ['wipe', 'Wipe'],
                  ['blink', 'A ↔ B'],
                ] as const
              ).map(([key, title]) => (
                <button
                  key={key}
                  aria-pressed={mode === key}
                  onClick={() => setMode(key)}
                >
                  {title}
                </button>
              ))}
            </div>
            <select
              aria-label="Comparison view"
              value={view}
              onChange={(e) => setView(e.target.value as TimelineView)}
            >
              <option value="all">3D + three slices</option>
              <option value="axial">Axial</option>
              <option value="coronal">Coronal</option>
              <option value="sagittal">Sagittal</option>
              <option value="volume">3D</option>
            </select>
            <button aria-pressed={cut} onClick={() => setCut((v) => !v)}>
              3D cut
            </button>
            <button
              aria-pressed={crop}
              disabled={!cursor}
              onClick={() => {
                setCrop((v) => !v);
                if (view === 'all' || view === 'volume') setView('axial');
              }}
            >
              Zoom to focus
            </button>
            <button
              onClick={() => {
                setCrop(false);
                setCamera(defaultCamera);
              }}
            >
              Reset camera
            </button>
          </div>
          {error && (
            <div role="alert" className="timeline-error">
              {error}
            </div>
          )}
          <div className="timeline-statusline">
            <span>
              {cursor
                ? `RAS: ${cursor.map((v) => v.toFixed(1)).join(' / ')} mm`
                : 'Pick a point on a slice'}
            </span>
            <span>
              {result
                ? review?.status === 'corrected'
                  ? 'Manually corrected point'
                  : review
                    ? 'Checked by you'
                    : 'Registered · check the region position'
                : registration?.stage || 'Choose two series'}
            </span>
          </div>
          <div className={`timeline-stage mode-${mode}`}>
            <article className="timeline-card fixed-card">
              <div className="timeline-card-label">
                <b>A</b> {displayDate(fixed?.date || '')}{' '}
                <span>Reference MRI</span>
              </div>
              {fixedSeries && (
                <TimelineVolume
                  key={`reference:${fixedId}:${fixedSeriesId}`}
                  url={urlFor(fixedSeries.url)}
                  range={fixedSeries.displayRange}
                  label="Reference MRI: 3D and slices"
                  point={cursor}
                  radius={radius}
                  camera={camera}
                  cut={cut}
                  crop={crop}
                  view={view}
                  onPoint={receivePoint}
                  onCamera={receiveCamera}
                />
              )}
            </article>
            <article
              className="timeline-card moving-card"
              style={
                mode === 'wipe'
                  ? { clipPath: `inset(0 0 0 ${wipe}%)` }
                  : mode === 'blink'
                    ? { visibility: blink ? 'visible' : 'hidden' }
                    : undefined
              }
            >
              <div className="timeline-card-label">
                <b>B</b> {displayDate(moving?.date || '')}{' '}
                <span>{movingSeries?.label || 'No matching series'}</span>
              </div>
              {result && movingSeries ? (
                <TimelineVolume
                  key={`moving:${registration?.id}`}
                  url={result.url}
                  range={movingSeries.displayRange}
                  label="Registered MRI: 3D and slices"
                  point={pointB}
                  radius={radius}
                  camera={camera}
                  cut={cut}
                  crop={crop}
                  view={view}
                  onPoint={(p) => {
                    if (correcting) setManualPoint(p);
                    else
                      receivePoint(
                        offset ? (p.map((v, i) => v - offset[i]) as Vec3) : p,
                      );
                  }}
                  onCamera={receiveCamera}
                  onReady={(ready, preview) => {
                    setReadyB(ready);
                    if (preview)
                      setPreviews((old) => ({ ...old, [cacheKey]: preview }));
                  }}
                />
              ) : (
                <div className="timeline-placeholder">
                  {registration?.status === 'error' ? (
                    <>
                      <p>{registration.error}</p>
                      <button onClick={() => setRetry((n) => n + 1)}>
                        Retry registration
                      </button>
                    </>
                  ) : registration ? (
                    <>
                      <LoaderCircle className="spin" />
                      <p>{registration.stage}</p>
                      <small>The result is kept in the local cache</small>
                    </>
                  ) : (
                    <>
                      <ArrowLeftRight size={28} />
                      <p>
                        {mismatch
                          ? 'Confirm the manual series choice'
                          : 'Choose a series for this date on the left'}
                      </p>
                    </>
                  )}
                </div>
              )}
            </article>
            {mode === 'wipe' && (
              <input
                className="timeline-wipe"
                type="range"
                min="0"
                max="100"
                value={wipe}
                aria-label="Wipe position"
                onChange={(e) => setWipe(Number(e.target.value))}
              />
            )}
            {mode === 'blink' && (
              <span className="timeline-blink-label">
                {blink ? 'B' : 'A'} ·{' '}
                {displayDate((blink ? moving : fixed)?.date || '')}
              </span>
            )}
          </div>
          {result && cursor && (
            <div
              className={`timeline-review ${inBounds ? '' : 'timeline-warning'}`}
            >
              {!inBounds ? (
                <span>
                  The point lies outside the scanned field of this date. The
                  coordinate is kept without an offset.
                </span>
              ) : (
                <>
                  <span>
                    {!regionFits
                      ? 'Part of the sphere lies outside the scanned field. '
                      : ''}
                    {correcting
                      ? 'Click the matching spot on image B. Reference point A stays unchanged.'
                      : review
                        ? 'Check the surrounding anatomy whenever you switch dates.'
                        : 'Compare landmarks on the slices or with the wipe. After surgery, tissue correspondence can be ambiguous.'}
                  </span>
                  {correcting ? (
                    <>
                      <button
                        disabled={saving || !manualPoint}
                        onClick={() => reviewPoint('corrected')}
                      >
                        <Save size={14} /> Save correction
                      </button>
                      <button
                        onClick={() => {
                          setCorrecting(false);
                          setManualPoint(null);
                        }}
                      >
                        Cancel
                      </button>
                    </>
                  ) : (
                    <>
                      <button
                        disabled={!canReview || saving}
                        onClick={() => reviewPoint('checked')}
                      >
                        <Check size={14} /> Position checked
                      </button>
                      <button
                        disabled={!canReview}
                        onClick={() => {
                          setPlaying(false);
                          setMode('pair');
                          setCorrecting(true);
                          setManualPoint(pointB);
                        }}
                      >
                        Correct point B
                      </button>
                    </>
                  )}
                </>
              )}
            </div>
          )}
          <div className="timeline-history-heading">
            <div>
              <b>Region history</b>
              <small>
                {playing && !inBounds
                  ? 'Playback waits for loading or for a point inside the scanned field'
                  : hasEdits
                    ? 'The focus has moved. Return to the saved point or save the new position.'
                    : message ||
                      'Real studies in date order; nothing is interpolated between them'}
              </small>
            </div>
            <button
              disabled={!region || hasEdits || correcting}
              onClick={() => {
                if (!playing) {
                  setCursor(region!.point);
                  setMode('pair');
                  const first = studies.find(
                    (s) =>
                      s.id !== fixedId &&
                      s.series.some(
                        (x) => fixedSeries && compatible(fixedSeries, x),
                      ),
                  );
                  if (first) setMovingId(first.id);
                }
                setPlaying((v) => !v);
              }}
            >
              {playing ? <Pause size={16} /> : <Play size={16} />}{' '}
              {playing ? 'Pause' : 'Play history'}
            </button>
          </div>
          <div className="timeline-filmstrip">
            {studies.map((s, i) => {
              const match = s.series.find(
                  (x) => fixedSeries && compatible(fixedSeries, x),
                ),
                key = `${s.id}:${match?.id}`,
                isFixed = s.id === fixedId;
              const days =
                i && s.date && studies[i - 1].date
                  ? Math.round(
                      (new Date(s.date).getTime() -
                        new Date(studies[i - 1].date).getTime()) /
                        86400000,
                    )
                  : null;
              return (
                <button
                  className={`timeline-date ${s.id === movingId ? 'active' : ''} ${isFixed ? 'reference' : ''}`}
                  key={s.id}
                  disabled={isFixed}
                  onClick={() => {
                    setPlaying(false);
                    setMovingId(s.id);
                  }}
                >
                  <div className="timeline-thumb">
                    {previews[key] ? (
                      <Image
                        unoptimized
                        width={240}
                        height={160}
                        src={previews[key]}
                        alt={`Region on the MRI from ${displayDate(s.date)}`}
                      />
                    ) : (
                      <Crosshair size={20} />
                    )}
                    <span>
                      {isFixed ? 'A' : String(i + 1).padStart(2, '0')}
                    </span>
                  </div>
                  <b>{displayDate(s.date)}</b>
                  <small>
                    {isFixed
                      ? 'Reference date'
                      : !match
                        ? 'No matching series'
                        : states[key] === 'ready'
                          ? 'Ready to view'
                          : states[key] === 'error'
                            ? 'Registration failed'
                            : 'Registers when opened'}
                  </small>
                  <em>
                    {!i
                      ? 'Start of history'
                      : days === null
                        ? 'Interval unknown'
                        : `+${days} ${days === 1 ? 'day' : 'days'}`}
                  </em>
                </button>
              );
            })}
          </div>
          {result && pointB && (
            <small className="timeline-provenance">
              Point B in the original MRI:{' '}
              {transformPoint(result.transformRAS, pointB)
                .map((v) => v.toFixed(1))
                .join(' / ')}{' '}
              mm RAS. Growth measurements and automatic diagnoses are not
              computed.
            </small>
          )}
        </main>
      </div>
    </dialog>
  );
}
