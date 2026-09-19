'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import type { Niivue } from '@niivue/niivue';
import type { FocusController } from './focus-controller';
import type { SlicePlanesController } from './slice-planes-controller';
import ComparePane from './compare-pane';
import StudyOverview from './study-overview';
import FocusTimeline from './focus-timeline';
import type { Vec3 } from '@/lib/focus-timeline';
import type { Patient, StudyRecord } from './library-workspace';
import { displayDate } from '@/lib/dates';

import {
  Orbit,
  ShieldCheck,
  Layers3,
  Scan,
  Box,
  Camera,
  RotateCcw,
  Play,
  Pause,
  MoveUpRight,
  Crosshair,
  Info,
  ChevronRight,
  Check,
  Maximize2,
  X,
  LoaderCircle,
  ArrowUpRight,
  Columns2,
  CalendarDays,
  FolderOpen,
  Upload,
  UserRound,
} from 'lucide-react';
import { Slider } from '@/components/ui/slider';
import { Switch } from '@/components/ui/switch';
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group';
import {
  Dialog,
  DialogTrigger,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';

type Series = {
  id: string;
  label: string;
  shortLabel: string;
  description: string;
  originalSeriesDescription: string;
  acquisitionType: string;
  contrast: { status: string; agent?: string };
  sourceImageCount: number;
  nativeDimensions: number[];
  nativeVoxelMm: number[];
  dimensions: number[];
  voxelMm: number[];
  url: string;
  displayRange: number[];
};
type Manifest = {
  defaultSeriesId: string;
  series: Series[];
};
type Point = {
  mm: number[];
  frac: number[];
  seriesId: string;
  studyId?: string;
};
type Mode = 'both' | 'volume' | 'slices' | 'compare';
const paletteNames: Record<string, string> = {
  silver: 'Silver',
  jade: 'Jade',
  amber: 'Amber',
};
const paletteMaps: Record<string, string> = {
  silver: 'gray',
  jade: 'neuroJade',
  amber: 'neuroAmber',
};
const axes: Record<string, number[]> = {
  sagittal: [270, 0],
  coronal: [0, 0],
  axial: [0, 90],
};
const sliceNames = ['Axial', 'Coronal', 'Sagittal'];
function rangeValue(value: number | readonly number[]) {
  return Array.isArray(value) ? value[0] : (value as number);
}
function assetUrl(url: string) {
  return url.startsWith('/api/') ? url : `/api/${url.replace(/^\//, '')}`;
}
function measure(values: number[] | undefined) {
  return values?.map((v) => Number(v.toFixed(2))).join(' × ') ?? '—';
}
const seriesName = (s: Series | undefined) => s?.shortLabel || s?.label || '';

export default function Viewer({
  patient,
  studies,
  patients,
  onPatient,
  onLibrary,
  onImport,
  onEdit,
  onHome,
  initialStudy,
}: {
  patient: Patient;
  studies: StudyRecord[];
  patients: Patient[];
  onPatient: (id: string) => void;
  onLibrary: () => void;
  onImport: () => void;
  onEdit: () => void;
  onHome: () => void;
  /** Study to open first; defaults to the first study of the patient. */
  initialStudy?: string;
}) {
  const [overviewOpen, setOverviewOpen] = useState(false);
  const [timelineOpen, setTimelineOpen] = useState(false);

  const [studyKey, setStudyKey] = useState(
    studies.some((s) => s.id === initialStudy) ? initialStudy! : studies[0].id,
  );
  const [compareId, setCompareId] = useState('');

  const [planes, setPlanes] = useState(true);
  const [planeOpacity, setPlaneOpacity] = useState(65);
  const [focusController, setFocusController] =
    useState<FocusController | null>(null);
  const planesRef = useRef<SlicePlanesController | null>(null);
  const worldPoint = useRef<number[] | null>(null);
  const comparisonCanvas = useRef<HTMLCanvasElement | null>(null);
  const [comparisonReady, setComparisonReady] = useState(false);
  const onCompareCanvas = useCallback((canvas: HTMLCanvasElement | null) => {
    comparisonCanvas.current = canvas;
    setComparisonReady(!!canvas);
  }, []);
  const studyDate = displayDate(
    studies.find((s) => s.id === studyKey)?.date || '',
  );
  const bookmarkKey = `openmri-focus-${patient.id}`;
  const [manifest, setManifest] = useState<Manifest | null>(null);
  const [selectedId, setSelectedId] = useState('');
  const [ready, setReady] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [mode, setMode] = useState<Mode>('both');
  const [compact, setCompact] = useState(false);
  const [palette, setPalette] = useState('silver');
  const [brightness, setBrightness] = useState(100);
  const [cut, setCut] = useState(true);
  const [depth, setDepth] = useState(20);
  const [axis, setAxis] = useState('sagittal');
  const [rotate, setRotate] = useState(false);
  const [immersive, setImmersive] = useState(false);
  const [point, setPoint] = useState<Point | null>(null);
  const [hasFocus, setHasFocus] = useState(false);
  const [bookmark, setBookmark] = useState<Point | null>(null);
  const [toast, setToast] = useState('');
  const [captureUrl, setCaptureUrl] = useState('');
  const [saving, setSaving] = useState(false);
  const renderCanvas = useRef<HTMLCanvasElement>(null);
  const sliceCanvas = useRef<HTMLCanvasElement>(null);
  const engines = useRef<{ render: Niivue; slices: Niivue } | null>(null);
  const selectedRef = useRef('');
  const focusRef = useRef<FocusController | null>(null);
  const pendingBookmark = useRef<Point | null>(null);
  const paletteRef = useRef('silver');
  useEffect(() => {
    paletteRef.current = palette;
  }, [palette]);
  const loadQueue = useRef(Promise.resolve());
  const loadedSeriesId = useRef('');
  const study = manifest?.series.find((s) => s.id === selectedId);
  const compareSeries =
    manifest?.series.find((s) => s.id === compareId && s.id !== selectedId) ||
    manifest?.series.find((s) => s.id !== selectedId);
  useEffect(() => {
    selectedRef.current = selectedId;
  }, [selectedId]);

  useEffect(() => {
    let active = true;
    fetch(`/api/library/studies/${encodeURIComponent(studyKey)}`)
      .then((r) => {
        if (!r.ok) throw new Error('Study not found in the local library.');
        return r.json() as Promise<Manifest>;
      })
      .then((data: Manifest) => {
        if (!active) return;
        setManifest(data);
        setSelectedId(
          data.series.some((s) => s.id === pendingBookmark.current?.seriesId)
            ? pendingBookmark.current!.seriesId
            : data.defaultSeriesId,
        );
        try {
          const saved = JSON.parse(localStorage.getItem(bookmarkKey) || 'null');
          if (
            saved &&
            Array.isArray(saved.frac) &&
            Array.isArray(saved.mm) &&
            saved.frac.length === 3 &&
            saved.mm.length >= 3 &&
            saved.frac.every(Number.isFinite) &&
            saved.mm.every(Number.isFinite) &&
            typeof saved.seriesId === 'string'
          )
            setBookmark(saved);
        } catch {
          /* Local storage is optional. */
        }
      })
      .catch((e) => {
        if (active) {
          setError(e.message);
          setLoading(false);
        }
      });
    return () => {
      active = false;
    };
  }, [studyKey, bookmarkKey]);

  useEffect(() => {
    let active = true;
    let allocated: { render: Niivue; slices: Niivue } | null = null;
    let focus: FocusController | null = null;
    let planeController: SlicePlanesController | null = null;
    async function setup() {
      const [{ Niivue }, { FocusController }, { SlicePlanesController }] =
        await Promise.all([
          import('@niivue/niivue'),
          import('./focus-controller'),
          import('./slice-planes-controller'),
        ]);
      if (!active || !renderCanvas.current || !sliceCanvas.current) return;
      const common = {
        backColor: [0, 0, 0, 1] as [number, number, number, number],
        crosshairColor: [1, 0.72, 0.16, 1] as [number, number, number, number],
        crosshairWidth: 1,
        crosshairGap: 6,
        dragAndDropEnabled: false,
        drawingEnabled: false,
        loadingText: '',
        isColorbar: false,
        isRadiologicalConvention: true,
        show3Dcrosshair: false,
        forceDevicePixelRatio: 1,
      };
      const render = new Niivue({
        ...common,
        isOrientCube: true,
        crosshairColor: [1, 0.77, 0.4, 0.85],
        crosshairWidth: 0.7,
        crosshairGap: 5,
      });
      const slices = new Niivue({
        ...common,
        isOrientCube: false,
        fontMinPx: 12,
        fontSizeScaling: 0.3,
      });
      allocated = { render, slices };
      await render.attachToCanvas(renderCanvas.current);
      if (!active) return;
      await slices.attachToCanvas(sliceCanvas.current);
      if (!active) return;
      planeController = new SlicePlanesController(render);
      planesRef.current = planeController;
      render.setSliceType(4);
      render.setRenderAzimuthElevation(120, 10);
      render.setScale(1.05);
      render.addColormap('neuroJade', {
        I: [0, 45, 100, 170, 225, 255],
        R: [0, 12, 52, 135, 208, 248],
        G: [0, 39, 116, 188, 233, 255],
        B: [0, 37, 111, 174, 216, 253],
        A: [0, 0, 45, 125, 210, 255],
      });
      render.addColormap('neuroAmber', {
        I: [0, 40, 100, 165, 225, 255],
        R: [0, 63, 169, 233, 255, 255],
        G: [0, 28, 88, 167, 224, 253],
        B: [0, 19, 51, 111, 186, 243],
        A: [0, 0, 45, 125, 210, 255],
      });
      render.setClipPlaneColor([0.7, 0.95, 0.82, -0.05]);
      slices.setCustomLayout(
        [0, 1, 2].map((sliceType, i) => ({
          sliceType,
          position: [0, i / 3, 1, 1 / 3],
        })),
      );
      focus = new FocusController(render, slices, (location) => {
        if (!active) return;
        worldPoint.current = location.visible ? location.mm : null;
        setPoint({
          mm: location.mm,
          frac: location.frac,
          seriesId: selectedRef.current,
        });
        setHasFocus(location.visible);
      });
      focusRef.current = focus;
      setFocusController(focus);
      engines.current = allocated;
      setReady(true);
    }
    setup().catch((e: unknown) => {
      if (active) {
        const message = e instanceof Error ? e.message : String(e);
        // A failed dynamic import means the page belongs to a build that is no
        // longer served, typically after the app was rebuilt or restarted.
        const staleBuild =
          /dynamically imported module|Importing a module script failed|Loading chunk/i.test(
            message,
          );
        setError(
          staleBuild
            ? 'The viewer module could not be loaded. The app was probably rebuilt or restarted while this page was open. Reload the page and try again.'
            : `3D rendering could not start: ${message}. Open the app in a browser with WebGL 2 enabled.`,
        );
        setLoading(false);
      }
    });
    return () => {
      active = false;
      focus?.dispose();
      planeController?.dispose();
      planesRef.current = null;
      focusRef.current = null;
      engines.current = null;
      allocated?.render.cleanup();
      allocated?.slices.cleanup();
    };
  }, []);

  useEffect(() => {
    if (!ready || !study) return;
    let active = true;
    const selected = study;
    loadQueue.current = loadQueue.current
      .catch(() => {})
      .then(async () => {
        const pair = engines.current;
        if (!active || !pair) return;
        const camera =
          loadedSeriesId.current === selected.id
            ? {
                azimuth: pair.render.scene.renderAzimuth,
                elevation: pair.render.scene.renderElevation,
                scale: pair.render.scene.volScaleMultiplier,
              }
            : null;
        setLoading(true);
        setError('');
        setRotate(false);
        focusRef.current?.pause();
        const opts = {
          url: assetUrl(selected.url),
          // NiiVue picks its parser from the name, so keep a real extension.
          name: `${selected.id}.nii.gz`,
          colormap: 'gray',
          cal_min: selected.displayRange[0],
          cal_max: selected.displayRange[1],
        };
        for (const nv of [pair.render, pair.slices]) {
          for (const volume of nv.volumes.slice()) nv.removeVolume(volume);
        }
        const loads = await Promise.allSettled([
          pair.render.loadVolumes([opts]),
          pair.slices.loadVolumes([opts]),
        ]);
        const failed = loads.find((result) => result.status === 'rejected');
        if (failed?.status === 'rejected') throw failed.reason;
        if (!active) return;
        pair.render.setColormap(
          pair.render.volumes[0].id,
          paletteMaps[paletteRef.current],
        );
        await pair.render.setVolumeRenderIllumination(0.45);
        await pair.render.setGradientOpacity(0.12, 0.06);
        if (!active) return;
        pair.render.setRenderAzimuthElevation(
          camera?.azimuth ?? 120,
          camera?.elevation ?? 10,
        );
        pair.render.setScale(camera?.scale ?? 1.05);
        loadedSeriesId.current = selected.id;
        const restore =
          pendingBookmark.current?.seriesId === selected.id
            ? pendingBookmark.current
            : null;
        const carry = worldPoint.current;
        const center = (restore?.frac ||
          (carry
            ? Array.from(pair.slices.mm2frac(carry, 0, true))
            : [0.5, 0.5, 0.55])) as [number, number, number];
        pendingBookmark.current = null;
        focusRef.current?.reset(center, !!restore || !!carry);
        setBrightness(100);
        setLoading(false);
        if (restore) {
          setMode('both');
          setToast('Slices moved back to your saved point');
        }
      })
      .catch((e) => {
        if (active) {
          setError(
            `The series could not be loaded: ${e instanceof Error ? e.message : String(e)}`,
          );
          setLoading(false);
        }
      });
    return () => {
      active = false;
    };
    // A palette change updates only its texture; it must never reload the scan.
  }, [ready, study]);

  useEffect(() => {
    const query = window.matchMedia('(max-width: 700px)');
    const update = () => setCompact(query.matches);
    update();
    query.addEventListener('change', update);
    return () => query.removeEventListener('change', update);
  }, []);

  useEffect(() => {
    if (!ready) return;
    const slices = engines.current?.slices;
    slices?.setSliceMM(mode === 'compare');
    slices?.setCustomLayout(
      [0, 1, 2].map((sliceType, i) => ({
        sliceType,
        position:
          (mode === 'slices' && !compact) || (mode === 'both' && compact)
            ? [i / 3, 0, 1 / 3, 1]
            : [0, i / 3, 1, 1 / 3],
      })),
    );
    const timer = window.setTimeout(
      () => window.dispatchEvent(new Event('resize')),
      80,
    );
    return () => clearTimeout(timer);
  }, [mode, ready, immersive, compact, overviewOpen]);

  useEffect(() => {
    const controller = planesRef.current;
    if (!controller) return;
    controller.enabled = planes;
    controller.opacity = planeOpacity / 100;
    engines.current?.render.drawScene();
  }, [planes, planeOpacity, ready, loading]);

  useEffect(() => {
    const nv = engines.current?.render;
    if (nv?.volumes[0] && !loading)
      nv.setColormap(nv.volumes[0].id, paletteMaps[palette]);
  }, [palette, loading]);

  useEffect(() => {
    const nv = engines.current?.render;
    if (!nv || !ready) return;
    nv.setClipPlane(cut ? [depth / 100, ...axes[axis]] : [2, 0, 0]);
  }, [cut, depth, axis, ready, loading]);

  useEffect(() => {
    if (loading || !study) return;
    const timer = window.setTimeout(() => {
      const nv = engines.current?.render;
      if (!nv?.volumes[0]) return;
      nv.volumes[0].cal_min = study.displayRange[0];
      nv.volumes[0].cal_max = (study.displayRange[1] * 100) / brightness;
      nv.updateGLVolume();
    }, 100);
    return () => clearTimeout(timer);
  }, [brightness, loading, study]);

  useEffect(() => {
    if (!rotate || loading) return;
    let frame = 0;
    let previous = 0;
    const tick = (now: number) => {
      const nv = engines.current?.render;
      if (nv && previous && now - previous >= 33) {
        nv.setRenderAzimuthElevation(
          nv.scene.renderAzimuth + Math.min(now - previous, 100) * 0.008,
          nv.scene.renderElevation,
        );
        previous = now;
      }
      if (!previous) previous = now;
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [rotate, loading]);

  useEffect(() => {
    if (!loading)
      focusRef.current?.setBookmark(
        bookmark?.seriesId === selectedId ? bookmark.frac : null,
      );
  }, [bookmark, selectedId, loading]);

  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(''), 3200);
    return () => clearTimeout(id);
  }, [toast]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setImmersive(false);
        setRotate(false);
      }
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);

  const reset = useCallback(() => {
    setCut(true);
    setDepth(20);
    setAxis('sagittal');
    setRotate(false);
    setBrightness(100);
    setPalette('silver');
    engines.current?.render.setRenderAzimuthElevation(120, 10);
    engines.current?.render.setScale(1.05);
  }, []);
  function openStudy(key: string, restore: Point | null = null) {
    if (!studies.some((s) => s.id === key)) return;
    setRotate(false);
    pendingBookmark.current = restore;
    worldPoint.current = null;
    focusRef.current?.pause();
    setBookmark(null);
    setCaptureUrl('');
    setManifest(null);
    setSelectedId('');
    setPoint(null);
    setHasFocus(false);
    setLoading(true);
    setError('');
    loadedSeriesId.current = '';
    setStudyKey(key);
  }
  function openPoint(saved: Point) {
    const key = saved.studyId || studyKey;
    setMode('both');
    if (studyKey !== key) openStudy(key, saved);
    else if (selectedId !== saved.seriesId) {
      pendingBookmark.current = saved;
      setSelectedId(saved.seriesId);
    } else if (loading) pendingBookmark.current = saved;
    else focusRef.current?.moveTo(saved.frac as [number, number, number]);
  }
  function savePoint() {
    if (!point) return;
    setBookmark({ ...point, studyId: studyKey });
    try {
      localStorage.setItem(
        bookmarkKey,
        JSON.stringify({ ...point, studyId: studyKey }),
      );
      setToast('Point saved in this browser');
    } catch {
      setToast('Point kept until the app is closed');
    }
  }
  function removeBookmark() {
    setBookmark(null);
    try {
      localStorage.removeItem(bookmarkKey);
    } catch {
      /* Local storage is optional. */
    }
  }
  async function exportPng() {
    const pair = engines.current;
    if (!pair || loading || saving) return;
    if (mode === 'compare' && !comparisonCanvas.current) {
      setToast('Wait for the second series to load');
      return;
    }
    setSaving(true);
    try {
      setRotate(false);
      pair.render.drawScene();
      pair.slices.drawScene();
      focusRef.current?.redrawPeer();
      const out = document.createElement('canvas');
      out.width = 1920;
      out.height = 1200;
      const ctx = out.getContext('2d');
      if (!ctx) return;
      ctx.fillStyle = '#080c0f';
      ctx.fillRect(0, 0, out.width, out.height);
      ctx.fillStyle = '#b2edca';
      ctx.font = '600 25px sans-serif';
      ctx.fillText('OPENMRI', 46, 54);
      ctx.fillStyle = '#e9f0f0';
      ctx.font = '22px sans-serif';
      ctx.fillText(`${seriesName(study)} · ${studyDate}`, 46, 92);
      const drawContained = (
        source: HTMLCanvasElement,
        x: number,
        y: number,
        w: number,
        h: number,
      ) => {
        const scale = Math.min(w / source.width, h / source.height);
        const dw = source.width * scale;
        const dh = source.height * scale;
        ctx.drawImage(source, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh);
      };
      if (mode !== 'slices' && mode !== 'compare' && renderCanvas.current)
        drawContained(
          renderCanvas.current,
          24,
          115,
          mode === 'volume' ? 1872 : 1370,
          995,
        );
      if (
        mode === 'compare' &&
        sliceCanvas.current &&
        comparisonCanvas.current
      ) {
        drawContained(sliceCanvas.current, 24, 140, 918, 955);
        drawContained(comparisonCanvas.current, 978, 140, 918, 955);
        ctx.fillStyle = '#d4e8e0';
        ctx.font = '18px sans-serif';
        ctx.fillText(seriesName(study), 46, 127);
        ctx.fillText(seriesName(compareSeries), 990, 127);
      }
      if (mode !== 'volume' && mode !== 'compare' && sliceCanvas.current)
        drawContained(
          sliceCanvas.current,
          mode === 'slices' ? 24 : 1410,
          115,
          mode === 'slices' ? 1872 : 480,
          995,
        );
      ctx.fillStyle = '#94a4a6';
      ctx.font = '18px sans-serif';
      ctx.fillText(
        'MRI visualization · colors encode signal intensity · not for diagnosis',
        46,
        1160,
      );
      const blob = await new Promise<Blob | null>((resolve) =>
        out.toBlob(resolve, 'image/png'),
      );
      if (!blob) throw new Error('PNG encoding failed');
      const response = await fetch('/api/captures', {
        method: 'POST',
        headers: { 'Content-Type': 'image/png' },
        body: blob,
      });
      if (!response.ok) throw new Error('Local saving failed');
      const result = (await response.json()) as { url: string };
      setCaptureUrl(result.url);
      setToast('PNG saved to the captures folder in your data directory');
    } catch {
      setToast('The PNG could not be saved. Please try again.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <main className={`neuro-app ${immersive ? 'immersive' : ''}`}>
      {timelineOpen && (
        <FocusTimeline
          patientId={patient.id}
          patientName={patient.name}
          initialStudy={studyKey}
          initialSeries={selectedId}
          initialPoint={hasFocus && point ? (point.mm as Vec3) : null}
          onClose={() => setTimelineOpen(false)}
        />
      )}
      <header className="topbar">
        <button
          className="brand"
          onClick={onHome}
          aria-label="Back to the welcome screen"
          title="Welcome screen"
        >
          <Orbit strokeWidth={1.25} />
          <span>
            OPENMRI<small>LOCAL MRI VIEWER</small>
          </span>
        </button>
        <div className="study-header">
          <span className="status-dot" />
          Study viewer
          <span className="header-divider" />
          <time>{studyDate}</time>
        </div>
        <div className="header-actions">
          <button
            className="header-toggle"
            disabled={studies.length < 2}
            title={
              studies.length < 2
                ? 'Import a second study date to compare over time'
                : undefined
            }
            onClick={() => {
              setRotate(false);
              setTimelineOpen(true);
            }}
          >
            <Crosshair size={17} /> Focus over time
          </button>
          <button className="export-button library-button" onClick={onLibrary}>
            <FolderOpen size={17} />
            <span>Library</span>
          </button>
          <button className="primary-action" onClick={onImport}>
            <Upload size={16} />
            <span>Import MRI</span>
          </button>
          <button
            className={`header-toggle ${overviewOpen ? 'active' : ''}`}
            aria-pressed={overviewOpen}
            onClick={() => {
              setOverviewOpen(!overviewOpen);
            }}
          >
            <CalendarDays size={17} /> History
          </button>
          <span className="local">
            <ShieldCheck size={15} /> Runs locally
          </span>
          <Dialog>
            <DialogTrigger
              className="icon-button"
              aria-label="About this study and the controls"
            >
              <Info size={19} />
            </DialogTrigger>
            <DialogContent className="about-dialog">
              <DialogHeader>
                <DialogTitle>About this view</DialogTitle>
                <DialogDescription>
                  Study from {studyDate} · local application
                </DialogDescription>
              </DialogHeader>
              <p>
                The volume is built from the images in your archive. For smooth
                rendering, large matrices are downsampled to at most 320 voxels
                per axis; every source slice and its spatial position are
                preserved.
              </p>
              <p>
                3D view: drag to rotate, use the wheel or trackpad to zoom.
                Slices: click to move the amber marker in 3D, scroll to move the
                slice. The marker stays visible through tissue and the cut
                plane; it is a coordinate pointer. Smooth motion interpolates
                between the acquired slices. R and L mark the patient&apos;s
                right and left sides.
              </p>
              <p>
                A series is tagged with contrast only when the DICOM metadata
                says so. Color palettes encode signal intensity. Manual points
                do not outline any anatomy or lesion.
              </p>
              <p className="info-note">
                This is a visualization tool, not a medical diagnostic device.
                Data, points, and processing stay on this computer.
              </p>
              <div className="provenance">
                Rendering:{' '}
                <a href="https://niivue.com" target="_blank" rel="noreferrer">
                  NiiVue <ArrowUpRight size={13} />
                </a>
              </div>
            </DialogContent>
          </Dialog>
        </div>
      </header>
      <div className={`workspace ${overviewOpen ? 'panel-open' : ''}`}>
        {overviewOpen && (
          <StudyOverview
            patient={patient}
            studies={studies}
            selected={studyKey}
            onSelect={(id) => {
              if (id !== studyKey) openStudy(id);
            }}
            onClose={() => setOverviewOpen(false)}
          />
        )}
        <aside className="controls" hidden={overviewOpen}>
          <div className="control-heading">
            <span className="eyebrow">PATIENT</span>
            <button
              className="icon-button"
              aria-label="Edit patient details"
              onClick={onEdit}
            >
              <UserRound size={16} />
            </button>
          </div>
          <select
            className="patient-select"
            aria-label="Patient"
            value={patient.id}
            onChange={(e) => onPatient(e.target.value)}
          >
            {patients.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
          <div className="patient-subtitle">
            {patient.birth_date
              ? displayDate(patient.birth_date)
              : 'No date of birth'}
          </div>
          <label className="study-picker">
            <span className="eyebrow">
              STUDY · {studies.length} {studies.length === 1 ? 'DATE' : 'DATES'}
            </span>
            <select
              aria-label="Study date"
              value={studyKey}
              onChange={(e) => openStudy(e.target.value)}
            >
              {studies.map((s) => (
                <option key={s.id} value={s.id}>
                  {displayDate(s.date)} · {s.label}
                </option>
              ))}
            </select>
          </label>
          <p className="study-meta">
            {studyDate} <span>·</span> {manifest?.series.length ?? '—'} series
          </p>
          <section className="series-list" aria-label="Series in this study">
            {manifest?.series.map((s, index) => (
              <button
                className={`series-card ${selectedId === s.id ? 'selected' : ''}`}
                key={s.id}
                onClick={() => setSelectedId(s.id)}
                disabled={loading}
                aria-pressed={selectedId === s.id}
                title={s.originalSeriesDescription}
              >
                <span className="series-index">
                  {String(index + 1).padStart(2, '0')}
                </span>
                <span className="series-text">
                  <strong>{seriesName(s)}</strong>
                  <small>
                    {s.acquisitionType} <span>·</span> {s.sourceImageCount}{' '}
                    slices
                  </small>
                </span>
                {s.contrast.status === 'confirmed' ? (
                  <span className="contrast-tag">+C</span>
                ) : (
                  <ChevronRight size={14} className="series-arrow" />
                )}
              </button>
            ))}
          </section>
          <section className="control-section">
            <div className="control-heading">
              <span className="eyebrow">LIGHT AND MATERIAL</span>
              <span className="tiny-badge">3D</span>
            </div>
            <ToggleGroup
              value={[palette]}
              onValueChange={(v) => {
                if (v[0]) setPalette(String(v[0]));
              }}
              className="palettes"
              aria-label="Volume palette"
              disabled={loading}
            >
              {Object.entries(paletteNames).map(([id, name]) => (
                <ToggleGroupItem
                  value={id}
                  className={`palette ${id} ${palette === id ? 'chosen' : ''}`}
                  key={id}
                  aria-label={name}
                >
                  <span className="palette-swatch">
                    {palette === id && <Check size={15} />}
                  </span>
                  <span>{name}</span>
                </ToggleGroupItem>
              ))}
            </ToggleGroup>
            <div className="slider-label">
              <span id="brightness-label">Volume brightness</span>
              <output>{brightness}%</output>
            </div>
            <Slider
              aria-labelledby="brightness-label"
              value={[brightness]}
              onValueChange={(v) => setBrightness(rangeValue(v))}
              min={50}
              max={180}
              step={5}
              disabled={loading}
            />
          </section>
          <section className="control-section planes-section">
            <div className="switch-row">
              <label htmlFor="planes-switch">
                <Layers3 size={16} /> Slice planes in 3D
              </label>
              <Switch
                id="planes-switch"
                aria-label="Slice planes in 3D"
                checked={planes}
                onCheckedChange={setPlanes}
                disabled={loading}
              />
            </div>
            {planes && (
              <>
                <p className="muted-text">
                  Three planes intersect at the selected point and stay visible
                  through the volume.
                </p>
                <div className="slider-label">
                  <span id="planes-opacity-label">Plane visibility</span>
                  <output>{planeOpacity}%</output>
                </div>
                <Slider
                  aria-labelledby="planes-opacity-label"
                  value={[planeOpacity]}
                  onValueChange={(v) => setPlaneOpacity(rangeValue(v))}
                  min={15}
                  max={100}
                  step={5}
                />
              </>
            )}
          </section>
          <section
            className={`control-section cut-section ${cut ? 'enabled' : ''}`}
          >
            <div className="switch-row">
              <label htmlFor="cut-switch">
                <Scan size={16} /> Cut plane
              </label>
              <Switch
                aria-label="Cut plane"
                id="cut-switch"
                checked={cut}
                onCheckedChange={setCut}
                disabled={loading}
              />
            </div>
            {cut ? (
              <div className="cut-controls">
                <ToggleGroup
                  value={[axis]}
                  onValueChange={(v) => {
                    if (v[0]) setAxis(String(v[0]));
                  }}
                  className="axis-buttons"
                  aria-label="Cut direction"
                >
                  <ToggleGroupItem value="sagittal">Side</ToggleGroupItem>
                  <ToggleGroupItem value="coronal">Front</ToggleGroupItem>
                  <ToggleGroupItem value="axial">Top</ToggleGroupItem>
                </ToggleGroup>
                <div className="slider-label">
                  <span id="depth-label">Plane position</span>
                  <output>
                    {depth > 0 ? '+' : ''}
                    {depth}%
                  </output>
                </div>
                <Slider
                  aria-labelledby="depth-label"
                  value={[depth]}
                  onValueChange={(v) => setDepth(rangeValue(v))}
                  min={-90}
                  max={90}
                  step={2}
                />
              </div>
            ) : (
              <p className="muted-text">
                Open the volume with a movable cut plane.
              </p>
            )}
          </section>
          <section className="focus-card">
            <div className="focus-title">
              <Crosshair size={17} />
              <span>Saved point {bookmark && <small>01</small>}</span>
              <span className="focus-type">manual</span>
            </div>
            <p>
              Clicking a slice shows the focus in 3D. Save it to come back
              later.
            </p>
            <div className="focus-actions">
              <button
                className="text-button"
                onClick={savePoint}
                disabled={loading || !point}
              >
                {bookmark ? 'Update point' : 'Save point'}
                <MoveUpRight size={14} />
              </button>
              {bookmark && (
                <button
                  className="icon-button"
                  aria-label="Remove saved point"
                  onClick={removeBookmark}
                >
                  <X size={14} />
                </button>
              )}
            </div>
            {bookmark && (
              <button
                className="bookmark-button"
                disabled={loading}
                onClick={() => openPoint(bookmark)}
              >
                <span className="status-dot" />
                {selectedId === bookmark.seriesId
                  ? 'Go to point'
                  : `Point · ${
                      seriesName(
                        manifest?.series.find(
                          (s) => s.id === bookmark.seriesId,
                        ),
                      ) || 'another series'
                    }`}
                <ChevronRight size={14} />
              </button>
            )}
          </section>
          <div className="sidebar-footer">
            <ShieldCheck size={13} />
            <span>Processing and storage stay local</span>
          </div>
        </aside>
        <section className="viewer-workspace" aria-label="MRI viewer">
          <div className="viewer-toolbar">
            <div className="active-series">
              <span className="eyebrow">CURRENT SERIES</span>
              <h2>
                {study ? seriesName(study) : 'Loading study'}{' '}
                {study?.contrast.status === 'confirmed' && (
                  <span className="contrast-label">CONTRAST</span>
                )}
              </h2>
            </div>
            <div className="toolbar-actions">
              <button
                className="export-button"
                aria-label="Save a PNG snapshot"
                onClick={exportPng}
                disabled={
                  loading || saving || (mode === 'compare' && !comparisonReady)
                }
              >
                <Camera size={16} />
                <span>{saving ? 'Saving…' : 'Snapshot'}</span>
              </button>
              <button
                className="icon-button"
                aria-label={immersive ? 'Exit full view' : 'Expand the viewer'}
                onClick={() => setImmersive(!immersive)}
              >
                {immersive ? <X size={18} /> : <Maximize2 size={18} />}
              </button>
            </div>
          </div>
          <div className="view-options">
            <Tabs value={mode} onValueChange={(v) => setMode(v as Mode)}>
              <TabsList className="view-tabs" aria-label="View mode">
                <TabsTrigger value="both">
                  <Layers3 size={15} />
                  Volume + slices
                </TabsTrigger>
                <TabsTrigger value="volume">
                  <Box size={15} />
                  3D
                </TabsTrigger>
                <TabsTrigger value="slices">
                  <Scan size={15} />
                  Slices
                </TabsTrigger>
                <TabsTrigger
                  value="compare"
                  disabled={(manifest?.series.length ?? 0) < 2}
                >
                  <Columns2 size={15} />
                  Compare
                </TabsTrigger>
              </TabsList>
            </Tabs>
            <span className="voxel-label">
              {measure(study?.voxelMm)} mm <span>· voxel</span>
            </span>
          </div>
          {mode === 'compare' && (
            <div className="compare-controls">
              <div>
                <span className="compare-letter">A</span>
                <strong>{study ? seriesName(study) : 'Main series'}</strong>
              </div>
              <label>
                <span className="compare-letter">B</span>
                <select
                  aria-label="Series to compare"
                  value={compareSeries?.id || ''}
                  onChange={(e) => setCompareId(e.target.value)}
                >
                  {manifest?.series
                    .filter((s) => s.id !== selectedId)
                    .map((s) => (
                      <option key={s.id} value={s.id}>
                        {seriesName(s)}
                      </option>
                    ))}
                </select>
              </label>
              <p>
                Both panes share the study&apos;s scanner coordinates. Motion
                between series is not corrected; each pane scales its own field
                of view.
              </p>
            </div>
          )}
          <div className={`scan-stage mode-${mode}`}>
            <div
              className="render-pane"
              style={{
                display:
                  mode === 'slices' || mode === 'compare' ? 'none' : undefined,
              }}
            >
              <canvas
                ref={renderCanvas}
                aria-label="3D volume rendering of the MRI. Drag to rotate, scroll to zoom."
              />
              <div className="render-label">
                <span className="status-dot" />
                <span>VOLUME RENDERING</span>
              </div>
              <div className="render-subtitle">
                {paletteNames[palette]}
                {cut ? ' / cut' : ' / full volume'}
              </div>
              <div className={`focus-indicator ${hasFocus ? 'active' : ''}`}>
                <Crosshair size={13} />
                {hasFocus
                  ? 'Point from the slices · visible through the volume'
                  : 'Click a slice to place the focus'}
              </div>
              <div className="corner corner-tl" />
              <div className="corner corner-tr" />
              <div className="corner corner-bl" />
              <div className="corner corner-br" />
              <div className="orbit-toolbar">
                <button
                  onClick={() => setRotate(!rotate)}
                  disabled={loading}
                  className={rotate ? 'active' : ''}
                >
                  {rotate ? <Pause size={14} /> : <Play size={14} />}
                  <span>{rotate ? 'Pause' : 'Orbit'}</span>
                </button>
                <span className="toolbar-separator" />
                <button
                  onClick={reset}
                  aria-label="Reset the view"
                  disabled={loading}
                >
                  <RotateCcw size={16} />
                </button>
              </div>
              <span className="view-help">
                Drag to rotate <span>·</span> Scroll to zoom
              </span>
            </div>
            <div
              className="slices-pane"
              style={{ display: mode === 'volume' ? 'none' : undefined }}
            >
              <canvas
                ref={sliceCanvas}
                aria-label="Three MRI slices. Click to pick a point, scroll to move the slice."
              />
              {sliceNames.map((name, i) => (
                <div className={`slice-overlay slice-${i}`} key={name}>
                  <span className="slice-label">
                    <span>{String(i + 1).padStart(2, '0')}</span>
                    {name}
                  </span>
                  <span className="slice-axis">{['AX', 'COR', 'SAG'][i]}</span>
                </div>
              ))}
            </div>
            {mode === 'compare' && compareSeries && focusController && (
              <ComparePane
                key={compareSeries.id}
                series={compareSeries}
                focus={focusController}
                onCanvas={onCompareCanvas}
              />
            )}
            {loading && !error && (
              <output className="scan-loading" aria-live="polite">
                <LoaderCircle size={29} className="spin" />
                <strong>
                  {ready ? 'Building the volume' : 'Starting the viewer'}
                </strong>
                <span>{study ? seriesName(study) : `MRI · ${studyDate}`}</span>
                <small>
                  Opening a series for the first time can take a few seconds
                </small>
              </output>
            )}
            {error && (
              <div className="scan-loading error-state" role="alert">
                <Info size={28} />
                <strong>The study could not be opened</strong>
                <p>{error}</p>
                <button
                  className="export-button"
                  onClick={() => window.location.reload()}
                >
                  Try again
                </button>
              </div>
            )}
          </div>
          <footer className="viewer-footer">
            <div>
              <span className={`status-dot ${loading ? 'pending' : ''}`} />
              <span>
                {loading ? 'Preparing' : error ? 'Load error' : 'Study open'}
              </span>
              <span className="footer-separator" />
              {study && <span>{study.dimensions.join(' × ')} px</span>}
            </div>
            <div className="coordinate-readout">
              <Crosshair size={13} />
              {point ? (
                point.mm.map((v, i) => (
                  <span key={i}>
                    <b>{['X', 'Y', 'Z'][i]}</b> {v.toFixed(1)}
                  </span>
                ))
              ) : (
                <span>Pick a point on a slice</span>
              )}
              <span>mm</span>
            </div>
          </footer>
          <div className="below-viewer">
            <span>
              {captureUrl ? (
                <a
                  className="capture-link"
                  href={captureUrl}
                  target="_blank"
                  rel="noreferrer"
                >
                  Open the saved PNG <ArrowUpRight size={12} />
                </a>
              ) : (
                'Slices keep the original grayscale.'
              )}
            </span>
            <span>
              Visualization only · not for diagnosis <Info size={12} />
            </span>
          </div>
        </section>
      </div>
      {toast && (
        <output className="toast" aria-live="polite">
          <Check size={17} />
          {toast}
        </output>
      )}
    </main>
  );
}
