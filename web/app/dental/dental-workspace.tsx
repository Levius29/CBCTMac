'use client';

/**
 * Panoramica ricostruita e sezioni trasversali: la schermata.
 *
 * # Che cosa mostra, e in che ordine
 *
 * In alto la **panoramica**, che serve a orientarsi: si vede l'arcata distesa e si sceglie dove
 * guardare. Sotto, a sinistra, la **fetta assiale con la curva disegnata sopra** — che non è un
 * ornamento: il rilevamento dell'arcata è un'euristica, e questa è l'unica immagine su cui si può
 * giudicare se ha trovato l'arcata o qualcos'altro. A destra la **sezione trasversale**, che è la
 * vista su cui si guarda davvero la cresta.
 *
 * Le tre viste sono legate: un clic sulla panoramica sposta la sezione, e la sezione si vede sulla
 * fetta assiale come la riga lungo cui taglia. Senza quel legame la striscia di sezioni sarebbe un
 * elenco da scorrere a caso, e nessuno saprebbe da che parte dell'arcata viene quella che guarda.
 *
 * # Perché la curva si corregge a mano
 *
 * Perché il rilevamento automatico o funziona o non funziona, e quando non funziona — arcata
 * asimmetrica, edentulo, campo parziale, un'otturazione che tira la soglia — senza correzione non
 * c'è rimedio e la funzione intera non serve a niente. Si trascinano i punti, se ne aggiunge uno
 * facendo clic sulla curva, se ne toglie uno con un clic tenendo Alt.
 *
 * La curva disegnata mentre si trascina è un'**anteprima** calcolata qui; quella vera la calcola
 * Python con la stessa formula, e si vede appena si preme Apply. Sono due implementazioni della
 * stessa spline, e stanno vicine di proposito: l'anteprima serve a non lavorare alla cieca.
 *
 * # Perché la scala è dichiarata a schermo
 *
 * Perché una panoramica ricostruita si usa per misurare, e un'immagine ridimensionata dal browser
 * non dice più quanto è lunga. Il righello da 10 mm è disegnato nelle stesse unità dell'immagine,
 * quindi resta vero a qualunque ingrandimento.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ChevronLeft,
  ChevronRight,
  LoaderCircle,
  PenLine,
  RefreshCw,
  RotateCcw,
} from 'lucide-react';
import Image from 'next/image';
import Link from 'next/link';
import { Button } from '@/components/ui/button';

type Patient = { id: string; name: string };
type Study = { id: string; patient_id: string; date: string; label: string };
type Series = { id: string; label: string };

type Axial = {
  columns: number;
  rows: number;
  stepMM: number;
  verticalMM: number;
  curvePixels: number[][];
  controlPixels: number[][];
  cutPixels: number[][];
  levelRangeMM: number[];
  worldFromPixel: { x: number[]; y: number[]; z: number };
};

type Build = {
  key: string;
  cached: boolean;
  curveSource: 'automatic' | 'manual' | 'saved';
  curve: {
    controlPointsMM: number[][];
    archVerticalMM: number;
    verticalCentreMM: number;
    automatic: boolean;
  };
  panorama: {
    widthPx: number;
    heightPx: number;
    mmPerPixel: number;
    arcLengthMM: number;
    slabThicknessMM: number;
    slabSamples: number;
    projection: string;
    normalOffsetMM: number;
  };
  sections: {
    count: number;
    intervalMM: number;
    widthPx: number;
    heightPx: number;
    mmPerPixel: number;
    widthMM: number;
    heightMM: number;
    arcLengthsMM: number[];
  };
  axial: Axial | null;
  volume: { dimensions: number[]; voxelMM: number[] };
  notes: string[];
  images: { panorama: string; axial: string | null; sections: string[] };
};

type Options = {
  slabThicknessMM: number;
  projection: 'maximum' | 'average';
  heightMM: number;
  normalOffsetMM: number;
  sectionIntervalMM: number;
  sectionWidthMM: number;
  sectionHeightMM: number;
  sectionThicknessMM: number;
  archVerticalMM: number | null;
  controlPointsMM: number[][] | null;
};

const initialOptions: Options = {
  slabThicknessMM: 20,
  projection: 'maximum',
  heightMM: 80,
  normalOffsetMM: 0,
  sectionIntervalMM: 2,
  sectionWidthMM: 32,
  sectionHeightMM: 45,
  sectionThicknessMM: 1,
  archVerticalMM: null,
  controlPointsMM: null,
};

async function api<T>(route: string, init?: RequestInit): Promise<T> {
  const response = await fetch(route, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok)
    throw new Error(body.error || `${route}: ${response.status}`);
  return body as T;
}

/**
 * Anteprima della spline mentre si trascina.
 *
 * Catmull-Rom con tensione 0,5, la stessa di `scripts/dental_panorama.py`: passa esattamente per i
 * punti posati. Qui è disegno, non geometria — la curva su cui si ricostruisce la calcola Python.
 */
function catmullRom(points: number[][], perSegment = 20): number[][] {
  if (points.length < 2) return points;
  const out: number[][] = [];
  for (let index = 0; index < points.length - 1; index += 1) {
    const p0 = points[Math.max(index - 1, 0)];
    const p1 = points[index];
    const p2 = points[Math.min(index + 1, points.length - 1)];
    const p3 = points[Math.min(index + 2, points.length - 1)];
    for (let step = 0; step < perSegment; step += 1) {
      const t = step / perSegment;
      const t2 = t * t;
      const t3 = t2 * t;
      out.push(
        [0, 1].map(
          (axis) =>
            0.5 *
            (2 * p1[axis] +
              (p2[axis] - p0[axis]) * t +
              (2 * p0[axis] - 5 * p1[axis] + 4 * p2[axis] - p3[axis]) * t2 +
              (3 * p1[axis] - p0[axis] - 3 * p2[axis] + p3[axis]) * t3),
        ),
      );
    }
  }
  out.push(points[points.length - 1]);
  return out;
}

/** Fra quali due punti di controllo cade un clic: è lì che il punto nuovo si inserisce. */
function insertionIndex(points: number[][], x: number, y: number) {
  let best = points.length;
  let bestDistance = Infinity;
  for (let index = 0; index < points.length - 1; index += 1) {
    const [ax, ay] = points[index];
    const [bx, by] = points[index + 1];
    const dx = bx - ax;
    const dy = by - ay;
    const length = dx * dx + dy * dy || 1;
    const t = Math.min(
      Math.max(((x - ax) * dx + (y - ay) * dy) / length, 0),
      1,
    );
    const distance = Math.hypot(x - (ax + dx * t), y - (ay + dy * t));
    if (distance < bestDistance) {
      bestDistance = distance;
      best = index + 1;
    }
  }
  return best;
}

export default function DentalWorkspace() {
  const [patients, setPatients] = useState<Patient[]>([]);
  const [studies, setStudies] = useState<Study[]>([]);
  const [studyId, setStudyId] = useState('');
  const [series, setSeries] = useState<Series[]>([]);
  const [seriesId, setSeriesId] = useState('');
  const [options, setOptions] = useState<Options>(initialOptions);
  const [build, setBuild] = useState<Build | null>(null);
  const [section, setSection] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<number[][] | null>(null);
  const [dragging, setDragging] = useState<number | null>(null);
  const panorama = useRef<HTMLButtonElement>(null);
  const axialSvg = useRef<SVGSVGElement>(null);

  useEffect(() => {
    api<{ patients: Patient[]; studies: Study[] }>('/api/library')
      .then((library) => {
        setPatients(library.patients);
        setStudies(library.studies);
        if (library.studies.length) setStudyId(library.studies[0].id);
      })
      .catch((e: Error) => setError(e.message));
  }, []);

  useEffect(() => {
    if (!studyId) return;
    api<{ series: Series[]; defaultSeriesId?: string }>(
      `/api/library/studies/${studyId}`,
    )
      .then((manifest) => {
        setSeries(manifest.series ?? []);
        setSeriesId(manifest.defaultSeriesId || manifest.series?.[0]?.id || '');
      })
      .catch((e: Error) => setError(e.message));
  }, [studyId]);

  const reconstruct = useCallback(
    async (override?: Partial<Options>, curveAction?: 'save' | 'forget') => {
      if (!seriesId) return;
      const wanted = { ...options, ...override };
      setBusy(true);
      setError('');
      try {
        const result = await api<Build>('/api/dental/panorama', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ seriesId, options: wanted, curveAction }),
        });
        setOptions(wanted);
        setBuild(result);
        setDraft(null);
        setEditing(false);
        setSection(Math.floor(result.sections.count / 2));
      } catch (e) {
        setBuild(null);
        setError((e as Error).message);
      } finally {
        setBusy(false);
      }
    },
    [seriesId, options],
  );

  // Le frecce scorrono le sezioni: è il gesto con cui si percorre un'arcata, e cercarlo con il
  // mouse su una striscia di sessanta miniature è il modo più lento di farlo.
  useEffect(() => {
    if (!build) return;
    function onKey(event: KeyboardEvent) {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      event.preventDefault();
      setSection((current) =>
        Math.min(
          Math.max(current + (event.key === 'ArrowRight' ? 1 : -1), 0),
          (build as Build).sections.count - 1,
        ),
      );
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [build]);

  function pickFromPanorama(event: React.MouseEvent<HTMLButtonElement>) {
    if (!build) return;
    const box = panorama.current?.getBoundingClientRect();
    if (!box || box.width <= 0) return;
    const fraction = Math.min(
      Math.max((event.clientX - box.left) / box.width, 0),
      1,
    );
    const arc = fraction * build.panorama.arcLengthMM;
    let best = 0;
    build.sections.arcLengthsMM.forEach((value, index) => {
      if (
        Math.abs(value - arc) <
        Math.abs(build.sections.arcLengthsMM[best] - arc)
      )
        best = index;
    });
    setSection(best);
  }

  // MARK: Correzione della curva

  const axial = build?.axial ?? null;
  const points = draft ?? axial?.controlPixels ?? [];

  /** Dal pixel dello schermo al pixel dell'immagine: il riquadro è scalato, la geometria no. */
  function imagePoint(event: React.PointerEvent) {
    const box = axialSvg.current?.getBoundingClientRect();
    if (!box || !box.width || !box.height || !axial) return null;
    return [
      ((event.clientX - box.left) / box.width) * axial.columns,
      ((event.clientY - box.top) / box.height) * axial.rows,
    ];
  }

  function onSurfaceDown(event: React.PointerEvent<SVGSVGElement>) {
    if (!editing || dragging !== null) return;
    const point = imagePoint(event);
    if (!point) return;
    const next = points.map((p) => [...p]);
    next.splice(insertionIndex(next, point[0], point[1]), 0, point);
    setDraft(next);
  }

  function onHandleDown(
    event: React.PointerEvent<SVGCircleElement>,
    index: number,
  ) {
    if (!editing) return;
    event.stopPropagation();
    // Alt toglie il punto. Sotto i tre punti la curva non è più una curva, quindi non si scende.
    if (event.altKey) {
      if (points.length <= 3) return;
      setDraft(points.filter((_, at) => at !== index));
      return;
    }
    (event.target as Element).setPointerCapture?.(event.pointerId);
    setDragging(index);
  }

  function onSurfaceMove(event: React.PointerEvent<SVGSVGElement>) {
    if (dragging === null) return;
    const point = imagePoint(event);
    if (!point) return;
    setDraft(points.map((p, index) => (index === dragging ? point : p)));
  }

  function applyCurve() {
    if (!axial || !draft) return;
    const { x, y, z } = axial.worldFromPixel;
    // `reconstruct` gestisce da sé l'errore e lo stato: qui l'attesa non serve a nessuno.
    // La curva si salva con la serie: correggerla una volta deve bastare.
    void reconstruct(
      {
        controlPointsMM: draft.map((point) => [
          x[0] * point[0] + x[1] * point[1] + x[2],
          y[0] * point[0] + y[1] * point[1] + y[2],
          z,
        ]),
        archVerticalMM: z,
      },
      'save',
    );
  }

  const patientOf = (study: Study) =>
    patients.find((p) => p.id === study.patient_id)?.name ?? 'Patient';
  const arc = build?.sections.arcLengthsMM[section] ?? 0;
  const markerPercent = build
    ? (arc / Math.max(build.panorama.arcLengthMM, 1e-6)) * 100
    : 0;
  const cut = axial?.cutPixels?.[section];
  const preview = editing ? catmullRom(points) : (axial?.curvePixels ?? []);

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-[1700px] flex-col gap-4 p-4">
      <header className="flex flex-wrap items-center gap-3">
        <div className="mr-auto">
          <h1 className="text-lg font-medium">Dental reconstruction</h1>
          <p className="text-muted-foreground text-xs">
            Panoramic view along the arch, and cross-sections perpendicular to
            it.
          </p>
        </div>
        <Link
          prefetch={false}
          className="text-muted-foreground text-xs underline"
          href="/"
        >
          Library
        </Link>
        <select
          className="border-border bg-card h-8 rounded-lg border px-2 text-sm"
          value={studyId}
          onChange={(event) => {
            // La ricostruzione mostrata appartiene alla serie di prima: sparisce qui, nel gesto, e
            // non in un effetto — altrimenti resterebbe a schermo per un fotogramma sotto il nome
            // dello studio nuovo.
            setBuild(null);
            setStudyId(event.target.value);
          }}
        >
          {studies.map((study) => (
            <option key={study.id} value={study.id}>
              {patientOf(study)} · {study.date || 'no date'} · {study.label}
            </option>
          ))}
        </select>
        <select
          className="border-border bg-card h-8 max-w-[22rem] rounded-lg border px-2 text-sm"
          value={seriesId}
          onChange={(event) => setSeriesId(event.target.value)}
        >
          {series.map((item) => (
            <option key={item.id} value={item.id}>
              {item.label}
            </option>
          ))}
        </select>
        <Button onClick={() => reconstruct()} disabled={!seriesId || busy}>
          {busy ? <LoaderCircle className="animate-spin" /> : <RefreshCw />}
          {build ? 'Rebuild' : 'Reconstruct'}
        </Button>
      </header>

      {error ? (
        <p className="border-destructive/40 bg-destructive/10 text-destructive rounded-lg border p-3 text-sm">
          {error}
        </p>
      ) : null}

      {busy && !build ? (
        <p className="text-muted-foreground text-sm">
          Reconstructing. The first run on a large volume takes a minute; the
          result is kept, so the same settings come back instantly.
        </p>
      ) : null}

      {build ? (
        <>
          <section className="border-border bg-card rounded-xl border p-3">
            <div className="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-xs">
              <span className="font-medium">Panoramic</span>
              <span className="text-muted-foreground">
                arch {build.panorama.arcLengthMM.toFixed(0)} mm · slab{' '}
                {build.panorama.slabThicknessMM.toFixed(0)} mm ·{' '}
                {build.panorama.projection} ·{' '}
                {build.panorama.mmPerPixel.toFixed(3)} mm/px
                {build.panorama.normalOffsetMM
                  ? ` · depth ${build.panorama.normalOffsetMM > 0 ? '+' : ''}${build.panorama.normalOffsetMM.toFixed(1)} mm`
                  : ''}
              </span>
              <span className="text-muted-foreground ml-auto">
                Click to move the cross-section · ← → to step
              </span>
            </div>
            <div className="flex justify-center">
              <button
                type="button"
                ref={panorama}
                className="relative max-w-full cursor-crosshair overflow-hidden rounded-lg bg-black"
                onClick={pickFromPanorama}
              >
                <Image
                  unoptimized
                  priority
                  width={build.panorama.widthPx}
                  height={build.panorama.heightPx}
                  src={build.images.panorama}
                  alt="Panoramic reconstruction"
                  className="block max-h-[min(42vh,520px)] w-auto max-w-full select-none"
                  draggable={false}
                />
                <div
                  className="bg-primary/80 pointer-events-none absolute top-0 bottom-0 w-px"
                  style={{ left: `${markerPercent}%` }}
                />
              </button>
            </div>
          </section>

          <section className="grid gap-4 lg:grid-cols-[minmax(260px,1fr)_minmax(320px,1.2fr)]">
            <div className="border-border bg-card rounded-xl border p-3">
              <div className="mb-2 flex flex-wrap items-center gap-2 text-xs">
                <span className="font-medium">Arch curve</span>
                <span className="text-muted-foreground">
                  {build.curveSource === 'automatic'
                    ? 'found automatically'
                    : build.curveSource === 'saved'
                      ? 'saved for this series'
                      : 'set by hand'}{' '}
                  · axial level {build.curve.archVerticalMM.toFixed(1)} mm ·{' '}
                  {points.length} points
                </span>
                <span className="ml-auto flex items-center gap-1">
                  {editing ? (
                    <>
                      <Button
                        size="xs"
                        onClick={applyCurve}
                        disabled={!draft || busy}
                      >
                        Apply curve
                      </Button>
                      <Button
                        size="xs"
                        variant="ghost"
                        onClick={() => {
                          setDraft(null);
                          setEditing(false);
                        }}
                      >
                        Cancel
                      </Button>
                    </>
                  ) : (
                    <Button
                      size="xs"
                      variant="outline"
                      onClick={() => setEditing(true)}
                      disabled={!axial || busy}
                    >
                      <PenLine /> Edit
                    </Button>
                  )}
                  {build.curveSource !== 'automatic' && !editing ? (
                    <Button
                      size="xs"
                      variant="ghost"
                      disabled={busy}
                      onClick={() =>
                        // «Automatic» non è solo «ricostruisci senza curva»: è anche «dimentica
                        // quella salvata», altrimenti tornerebbe da sola al prossimo giro.
                        void reconstruct(
                          { controlPointsMM: null, archVerticalMM: null },
                          'forget',
                        )
                      }
                    >
                      <RotateCcw /> Automatic
                    </Button>
                  ) : null}
                </span>
              </div>

              {build.images.axial && axial ? (
                <div className="relative overflow-hidden rounded-lg bg-black">
                  <Image
                    unoptimized
                    width={axial.columns}
                    height={axial.rows}
                    src={build.images.axial}
                    alt="Axial slice with the detected arch"
                    className="block w-full"
                  />
                  <svg
                    ref={axialSvg}
                    className={`absolute inset-0 h-full w-full ${editing ? 'cursor-crosshair' : 'pointer-events-none'}`}
                    viewBox={`0 0 ${axial.columns} ${axial.rows}`}
                    preserveAspectRatio="none"
                    onPointerDown={onSurfaceDown}
                    onPointerMove={onSurfaceMove}
                    onPointerUp={() => setDragging(null)}
                    onPointerCancel={() => setDragging(null)}
                  >
                    {cut ? (
                      <line
                        x1={cut[0]}
                        y1={cut[1]}
                        x2={cut[2]}
                        y2={cut[3]}
                        stroke="#ffb829"
                        strokeWidth={Math.max(axial.columns / 300, 0.8)}
                        strokeOpacity={0.95}
                      />
                    ) : null}
                    <polyline
                      points={preview
                        .map((point) => `${point[0]},${point[1]}`)
                        .join(' ')}
                      fill="none"
                      stroke="var(--primary)"
                      strokeWidth={Math.max(axial.columns / 260, 1)}
                      strokeOpacity={0.9}
                    />
                    {points.map((point, index) => (
                      <circle
                        key={index}
                        cx={point[0]}
                        cy={point[1]}
                        r={Math.max(axial.columns / (editing ? 90 : 180), 1.5)}
                        fill="var(--primary)"
                        className={editing ? 'cursor-grab' : ''}
                        onPointerDown={(event) => onHandleDown(event, index)}
                      />
                    ))}
                  </svg>
                </div>
              ) : null}

              <p className="text-muted-foreground mt-2 text-xs">
                {editing ? (
                  <>
                    Drag a point to move it, click the curve to add one,
                    Alt-click a point to remove it. <b>Apply curve</b> rebuilds
                    everything from the curve you drew.
                  </>
                ) : (
                  <>
                    Radiological orientation: the patient&rsquo;s right is on
                    the left, anterior is up. The amber line is where the
                    cross-section cuts. Check that the curve follows the arch
                    before trusting the cross-sections.
                  </>
                )}
              </p>
            </div>

            <div className="border-border bg-card rounded-xl border p-3">
              <div className="mb-2 flex flex-wrap items-center gap-2 text-xs">
                <span className="font-medium">Cross-section</span>
                <span className="text-muted-foreground">
                  {section + 1} of {build.sections.count} · {arc.toFixed(1)} mm
                  along the arch · {build.sections.widthMM.toFixed(0)} ×{' '}
                  {build.sections.heightMM.toFixed(0)} mm
                </span>
                <span className="ml-auto flex items-center gap-1">
                  <Button
                    size="xs"
                    variant="outline"
                    onClick={() =>
                      setSection((value) => Math.max(value - 1, 0))
                    }
                    disabled={section === 0}
                  >
                    <ChevronLeft />
                  </Button>
                  <Button
                    size="xs"
                    variant="outline"
                    onClick={() =>
                      setSection((value) =>
                        Math.min(value + 1, build.sections.count - 1),
                      )
                    }
                    disabled={section >= build.sections.count - 1}
                  >
                    <ChevronRight />
                  </Button>
                </span>
              </div>
              <div className="flex justify-center">
                <div className="relative overflow-hidden rounded-lg bg-black">
                  <Image
                    unoptimized
                    width={build.sections.widthPx}
                    height={build.sections.heightPx}
                    src={build.images.sections[section]}
                    alt={`Cross-section at ${arc.toFixed(1)} mm`}
                    className="block h-[420px] w-auto"
                  />
                  {/* Righello da 10 mm: l'immagine è ridimensionata dal browser, il rapporto no. */}
                  <div
                    className="absolute bottom-3 left-3 border-b-2 border-white/80 text-[10px] text-white/80"
                    style={{
                      width: `${(10 / build.sections.mmPerPixel / build.sections.heightPx) * 420}px`,
                    }}
                  >
                    10 mm
                  </div>
                </div>
              </div>
              <input
                className="mt-3 w-full"
                type="range"
                min={0}
                max={build.sections.count - 1}
                value={section}
                onChange={(event) => setSection(Number(event.target.value))}
              />
            </div>
          </section>

          <section className="border-border bg-card grid gap-3 rounded-xl border p-3 text-xs sm:grid-cols-2 lg:grid-cols-4">
            <Slider
              label="Slab thickness"
              unit="mm"
              value={options.slabThicknessMM}
              min={0}
              max={40}
              step={1}
              onChange={(value) =>
                setOptions((o) => ({ ...o, slabThicknessMM: value }))
              }
            />
            <Slider
              label="Depth, buccal +"
              unit="mm"
              value={options.normalOffsetMM}
              min={-15}
              max={15}
              step={0.5}
              onChange={(value) =>
                setOptions((o) => ({ ...o, normalOffsetMM: value }))
              }
            />
            <Slider
              label="Panoramic height"
              unit="mm"
              value={options.heightMM}
              min={40}
              max={160}
              step={5}
              onChange={(value) =>
                setOptions((o) => ({ ...o, heightMM: value }))
              }
            />
            <Slider
              label="Section spacing"
              unit="mm"
              value={options.sectionIntervalMM}
              min={0.5}
              max={10}
              step={0.5}
              onChange={(value) =>
                setOptions((o) => ({ ...o, sectionIntervalMM: value }))
              }
            />
            <Slider
              label="Section thickness"
              unit="mm"
              value={options.sectionThicknessMM}
              min={0}
              max={10}
              step={0.5}
              onChange={(value) =>
                setOptions((o) => ({ ...o, sectionThicknessMM: value }))
              }
            />
            <Slider
              label="Section width"
              unit="mm"
              value={options.sectionWidthMM}
              min={10}
              max={80}
              step={2}
              onChange={(value) =>
                setOptions((o) => ({ ...o, sectionWidthMM: value }))
              }
            />
            <Slider
              label="Section height"
              unit="mm"
              value={options.sectionHeightMM}
              min={10}
              max={90}
              step={5}
              onChange={(value) =>
                setOptions((o) => ({ ...o, sectionHeightMM: value }))
              }
            />
            <label className="flex flex-col gap-1">
              <span className="text-muted-foreground">
                Panoramic projection
              </span>
              <select
                className="border-border bg-background h-8 rounded-lg border px-2"
                value={options.projection}
                onChange={(event) =>
                  setOptions((o) => ({
                    ...o,
                    projection:
                      event.target.value === 'average' ? 'average' : 'maximum',
                  }))
                }
              >
                <option value="maximum">
                  Maximum — bone and enamel stand out
                </option>
                <option value="average">
                  Average — closer to a plain film
                </option>
              </select>
            </label>
            {axial ? (
              <Slider
                label="Axial level for the arch"
                unit="mm"
                value={Math.round(
                  options.archVerticalMM ?? build.curve.archVerticalMM,
                )}
                min={Math.round(axial.levelRangeMM[0])}
                max={Math.round(axial.levelRangeMM[1])}
                step={1}
                onChange={(value) =>
                  // Cambiare la quota rimette in gioco il rilevamento: la curva a mano era posata
                  // su un'altra fetta, e tenerla qui significherebbe una curva che galleggia.
                  setOptions((o) => ({
                    ...o,
                    archVerticalMM: value,
                    controlPointsMM: null,
                  }))
                }
              />
            ) : null}
            <div className="flex items-end gap-2">
              <Button
                onClick={() => reconstruct()}
                disabled={busy}
                variant="outline"
              >
                {busy ? (
                  <LoaderCircle className="animate-spin" />
                ) : (
                  <RefreshCw />
                )}
                Apply
              </Button>
            </div>
            <p className="text-muted-foreground sm:col-span-2 lg:col-span-4">
              Depth browses through the arch along the buccal–lingual direction.
              With a thick slab it changes little, because the slab already
              contains the bone: thin the slab to a few millimetres first, then
              browse.
            </p>
          </section>

          <footer className="text-muted-foreground space-y-1 text-xs">
            {build.notes.map((note) => (
              <p key={note}>{note}</p>
            ))}
            <p>
              Volume {build.volume.dimensions.join(' × ')} at{' '}
              {build.volume.voxelMM.map((v) => v.toFixed(2)).join(' × ')} mm.
              Visualization only, not for diagnosis.
            </p>
          </footer>
        </>
      ) : null}
    </main>
  );
}

function Slider({
  label,
  unit,
  value,
  min,
  max,
  step,
  onChange,
}: {
  label: string;
  unit: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
}) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-muted-foreground">
        {label}{' '}
        {/* Una quota che arriva dal calcolo ha quindici decimali, e nessuno di quelli oltre il
            primo significa qualcosa: il passo del cursore dice quanti scriverne. */}
        <span className="text-foreground">
          {value.toFixed(step < 1 ? 1 : 0)}
        </span>{' '}
        {unit}
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
      />
    </label>
  );
}
