'use client';
import { useEffect, useRef, useState } from 'react';
import type { Niivue } from '@niivue/niivue';
import { FocusController } from './focus-controller';
import type { Vec3 } from '@/lib/focus-timeline';
export type CameraState = {
  azimuth: number;
  elevation: number;
  scale: number;
  pan: [number, number, number, number];
};
export type TimelineView = 'all' | 'axial' | 'coronal' | 'sagittal' | 'volume';
const snapshot = (n: Niivue): CameraState => ({
  azimuth: n.scene.renderAzimuth,
  elevation: n.scene.renderElevation,
  scale: n.scene.volScaleMultiplier,
  pan: [...n.scene.pan2Dxyzmm] as CameraState['pan'],
});
export default function TimelineVolume(props: {
  url: string;
  range: number[];
  label: string;
  point: Vec3 | null;
  radius: number;
  cut: boolean;
  crop: boolean;
  camera: CameraState;
  view: TimelineView;
  onPoint: (p: Vec3) => void;
  onCamera: (c: CameraState) => void;
  onReady?: (ready: boolean, thumbnail?: string) => void;
}) {
  const canvas = useRef<HTMLCanvasElement>(null),
    nv = useRef<Niivue | null>(null),
    focus = useRef<FocusController | null>(null);
  const current = useRef(props);
  useEffect(() => {
    current.current = props;
  }, [props]);
  const appliedEngine = useRef<Niivue | null>(null);
  const emittedPoint = useRef<Vec3 | null>(null);
  const applying = useRef(false),
    lastCamera = useRef('');
  const [status, setStatus] = useState('Opening the volume…'),
    [failed, setFailed] = useState(false),
    [loaded, setLoaded] = useState(0);
  useEffect(() => {
    let alive = true,
      finished = false,
      engine: Niivue | null = null,
      controller: FocusController | null = null,
      frame = 0;
    const dispose = () => {
      controller?.dispose();
      engine?.cleanup();
      engine?.gl?.getExtension('WEBGL_lose_context')?.loseContext();
    };
    async function load() {
      setStatus('Opening the volume…');
      setFailed(false);
      current.current.onReady?.(false);
      const { Niivue } = await import('@niivue/niivue');
      if (!alive || !canvas.current) return;
      engine = new Niivue({
        backColor: [0, 0, 0, 1],
        crosshairColor: [1, 0.72, 0.16, 1],
        crosshairWidth: 1,
        crosshairGap: 5,
        isSliceMM: true,
        isRadiologicalConvention: true,
        forceDevicePixelRatio: 1,
        fontMinPx: 11,
        show3Dcrosshair: false,
        clipPlaneColor: [0, 0, 0, 0],
        isOrientCube: true,
        dragAndDropEnabled: false,
        loadingText: '',
      });
      await engine.attachToCanvas(canvas.current);
      if (!alive) return;
      await engine.loadVolumes([
        {
          url: props.url,
          name: 'timeline.nii.gz',
          colormap: 'gray',
          cal_min: props.range[0],
          cal_max: props.range[1],
        },
      ]);
      if (!alive) return;
      nv.current = engine;
      emittedPoint.current = null;
      controller = new FocusController(engine, engine, (location) => {
        if (!applying.current && location.visible) {
          emittedPoint.current = location.mm as Vec3;
          current.current.onPoint(location.mm as Vec3);
        }
      });
      focus.current = controller;
      const tick = () => {
        if (!alive || !engine) return;
        const camera = snapshot(engine),
          key = JSON.stringify(camera);
        if (key !== lastCamera.current) {
          lastCamera.current = key;
          current.current.onCamera(camera);
        }
        frame = requestAnimationFrame(tick);
      };
      // Effects below initialize geometry before the camera observer begins.
      lastCamera.current = JSON.stringify(snapshot(engine));
      setLoaded((n) => n + 1);
      setStatus('');
      frame = requestAnimationFrame(tick);
      current.current.onReady?.(true);
    }
    void load()
      .catch((e) => {
        if (alive) {
          setFailed(true);
          setStatus(e instanceof Error ? e.message : String(e));
        }
      })
      .finally(() => {
        finished = true;
        if (!alive) dispose();
      });
    return () => {
      alive = false;
      cancelAnimationFrame(frame);
      focus.current = null;
      nv.current = null;
      current.current.onReady?.(false);
      if (finished) dispose();
    };
  }, [props.url, props.range]);
  useEffect(() => {
    const n = nv.current;
    if (!n) return;
    if (props.view === 'all')
      n.setCustomLayout([
        { sliceType: 4, position: [0, 0, 0.58, 1] },
        { sliceType: 0, position: [0.58, 0, 0.42, 1 / 3] },
        { sliceType: 1, position: [0.58, 1 / 3, 0.42, 1 / 3] },
        { sliceType: 2, position: [0.58, 2 / 3, 0.42, 1 / 3] },
      ]);
    else
      n.setCustomLayout([
        {
          sliceType: { axial: 0, coronal: 1, sagittal: 2, volume: 4 }[
            props.view
          ],
          position: [0, 0, 1, 1],
        },
      ]);
    n.drawScene();
  }, [props.view, loaded]);
  useEffect(() => {
    const n = nv.current,
      f = focus.current;
    if (!n || !f) return;
    applying.current = true;
    if (props.point) {
      const existing = emittedPoint.current;
      // Echoes of this controller's animation must not cancel its next frame.
      if (
        appliedEngine.current !== n ||
        !existing ||
        existing.some((v, i) => Math.abs(v - props.point![i]) > 0.0001)
      )
        f.reset(Array.from(n.mm2frac(props.point, 0, true)) as Vec3, true);
    } else f.reset([0.5, 0.5, 0.5], false);
    applying.current = false;
    appliedEngine.current = n;
    // A physical sphere marks the saved neighbourhood; the point marker stays visible through tissue.
    while (n.meshes.length) n.removeMesh(n.meshes[0]);
    if (props.point) {
      n.loadConnectome({
        name: 'Focus region',
        nodeScale: 1,
        nodeColormap: 'hot',
        nodeMinColor: 0,
        nodeMaxColor: 1,
        showLegend: false,
        nodes: {
          names: [''],
          prefilled: [],
          X: [props.point[0]],
          Y: [props.point[1]],
          Z: [props.point[2]],
          Color: [0.65],
          Size: [props.radius],
        },
        edges: [],
      });
      if (n.meshes[0]) n.meshes[0].opacity = 0.22;
    }
    n.drawScene();
  }, [props.point, props.radius, loaded]);
  useEffect(() => {
    const n = nv.current;
    if (!n) return;
    n.scene.renderAzimuth = props.camera.azimuth;
    n.scene.renderElevation = props.camera.elevation;
    n.scene.volScaleMultiplier = props.camera.scale;
    n.scene.pan2Dxyzmm = [...props.camera.pan];
    if (props.crop && props.point) {
      const lo = Array.from(n.frac2mm([0, 0, 0], 0, true)),
        hi = Array.from(n.frac2mm([1, 1, 1], 0, true));
      const zoom = Math.max(
        1,
        Math.min(
          8,
          Math.max(...hi.slice(0, 3).map((v, i) => Math.abs(v - lo[i]))) /
            (props.radius * 6),
        ),
      );
      n.scene.pan2Dxyzmm = [
        ...props.point.map((v, i) => (hi[i] + lo[i]) / 2 - v * zoom),
        zoom,
      ] as CameraState['pan'];
    }
    lastCamera.current = JSON.stringify(snapshot(n));
    n.drawScene();
  }, [props.camera, props.crop, props.point, props.radius, loaded]);
  useEffect(() => {
    const n = nv.current;
    if (n) {
      n.setClipPlane(props.cut ? [0, 270, 0] : [2, 0, 0]);
      n.drawScene();
    }
  }, [props.cut, loaded]);
  useEffect(() => {
    if (!loaded) return;
    const timer = setTimeout(() => {
      const n = nv.current;
      if (!n?.canvas) return;
      n.drawScene();
      // Small local preview, never a second persistent GPU volume.
      const preview = document.createElement('canvas');
      preview.width = 240;
      preview.height = 160;
      preview.getContext('2d')?.drawImage(n.canvas, 0, 0, 240, 160);
      current.current.onReady?.(true, preview.toDataURL('image/jpeg', 0.65));
    }, 300);
    return () => clearTimeout(timer);
  }, [loaded, props.point, props.view]);
  return (
    <div className="timeline-volume">
      <canvas ref={canvas} aria-label={props.label} />
      {status && (
        <div
          className="timeline-volume-status"
          role={failed ? 'alert' : 'status'}
        >
          {status}
        </div>
      )}
    </div>
  );
}
