'use client';

import { useEffect, useRef, useState } from 'react';
import { LoaderCircle, RotateCcw } from 'lucide-react';
import type { Niivue } from '@niivue/niivue';
import type { FocusController } from './focus-controller';

type CompareSeries = {
  id: string;
  url: string;
  label: string;
  displayRange: number[];
};
const sliceNames = ['Axial', 'Coronal', 'Sagittal'];
export default function ComparePane({
  series,
  focus,
  onCanvas,
}: {
  series: CompareSeries;
  focus: FocusController;
  onCanvas: (canvas: HTMLCanvasElement | null) => void;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [inside, setInside] = useState(true);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    let active = true;
    let nv: Niivue | null = null;
    let settled = false;
    let released = false;
    function release() {
      if (!nv || released) return;
      released = true;
      nv.cleanup();
      nv.gl?.getExtension('WEBGL_lose_context')?.loseContext();
    }
    async function load() {
      setLoading(true);
      setError('');
      const { Niivue } = await import('@niivue/niivue');
      if (!active || !canvas.current) return;
      nv = new Niivue({
        backColor: [0, 0, 0, 1],
        crosshairColor: [1, 0.77, 0.4, 0.85],
        crosshairWidth: 1,
        crosshairGap: 6,
        isSliceMM: true,
        isRadiologicalConvention: true,
        forceDevicePixelRatio: 1,
        fontMinPx: 12,
        fontSizeScaling: 0.3,
        isOrientCube: false,
        dragAndDropEnabled: false,
        drawingEnabled: false,
        loadingText: '',
      });
      await nv.attachToCanvas(canvas.current);
      if (!active) return;
      nv.setCustomLayout(
        [0, 1, 2].map((sliceType, i) => ({
          sliceType,
          position: [0, i / 3, 1, 1 / 3],
        })),
      );
      await nv.loadVolumes([
        {
          url: series.url.startsWith('/api/')
            ? series.url
            : `/api/${series.url}`,
          name: `${series.id}.nii.gz`,
          colormap: 'gray',
          cal_min: series.displayRange[0],
          cal_max: series.displayRange[1],
        },
      ]);
      if (!active) return;
      focus.setPeer(nv, setInside);
      onCanvas(canvas.current);
      setLoading(false);
    }
    load()
      .catch((e) => {
        if (active) {
          setError(e instanceof Error ? e.message : String(e));
          setLoading(false);
        }
      })
      .finally(() => {
        settled = true;
        if (!active) release();
      });
    return () => {
      active = false;
      focus.setPeer(null);
      onCanvas(null);
      nv?.cleanup();
      if (settled) release();
    };
  }, [series, focus, retry, onCanvas]);
  return (
    <div className="compare-pane">
      <canvas
        ref={canvas}
        aria-label={`Slices of the comparison series ${series.label}. Clicks and scrolling are linked to the main series.`}
      />
      {sliceNames.map((name, i) => (
        <div className={`slice-overlay slice-${i}`} key={name}>
          <span className="slice-label">
            <span>{String(i + 1).padStart(2, '0')}</span>
            {name}
          </span>
        </div>
      ))}
      {loading && (
        <div className="compare-status">
          <LoaderCircle size={24} className="spin" />
          <span>Opening the second series</span>
        </div>
      )}
      {error && (
        <div className="compare-status" role="alert">
          <span>The series could not be opened</span>
          <small>{error}</small>
          <button
            className="text-button"
            onClick={() => setRetry((v) => v + 1)}
          >
            <RotateCcw size={14} />
            Retry
          </button>
        </div>
      )}
      {!loading && !error && !inside && (
        <output className="outside-volume">Point is outside this series</output>
      )}
    </div>
  );
}
