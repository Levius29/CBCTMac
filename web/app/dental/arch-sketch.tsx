'use client';

/**
 * La curva d'arcata posata a mano, quando il rilevamento non l'ha trovata.
 *
 * File nostro. Prima, un'arcata non riconosciuta era un errore e la pagina restava vuota con una
 * frase — «impostate la quota a mano, o date i punti» — senza un posto dove farlo: è successo alla
 * prima CBCT vera aperta con il programma. Il rilevamento è un'euristica, e un'euristica che
 * fallisce non deve fermare la funzione intera: qui si mostra la fetta assiale, si sceglie la quota
 * dei denti e la curva la posa chi guarda, un clic per punto.
 *
 * Cambiare quota rifà anche il rilevamento: su un'altra fetta l'arcata potrebbe trovarsi da sola.
 */

import { useRef, useState } from 'react';
import { Eraser, LoaderCircle, Mountain, Spline } from 'lucide-react';
import Image from 'next/image';
import { Button } from '@/components/ui/button';
import {
  type WorldFromPixel,
  catmullRom,
  insertionIndex,
  worldFromPixels,
} from './curve';

export type Sketch = {
  key: string;
  needsCurve: true;
  axial: {
    columns: number;
    rows: number;
    verticalMM: number;
    levelRangeMM: number[];
    worldFromPixel: WorldFromPixel;
  };
  images: { axial: string | null };
};

/** Sotto i tre punti non c'è una curva: è anche il minimo che il server accetta. */
const MINIMUM_POINTS = 3;

export default function ArchSketch({
  sketch,
  busy,
  onLevel,
  onCurve,
}: {
  sketch: Sketch;
  busy: boolean;
  /** Mostra un'altra quota, e lì riprova il rilevamento. */
  onLevel: (levelMM: number) => void;
  /** La curva posata, in millimetri alla quota della fetta. */
  onCurve: (pointsMM: number[][], levelMM: number) => void;
}) {
  const { axial } = sketch;
  const [points, setPoints] = useState<number[][]>([]);
  const [dragging, setDragging] = useState<number | null>(null);
  const [level, setLevel] = useState(Math.round(axial.verticalMM));
  const surface = useRef<SVGSVGElement>(null);

  /** Dal pixel dello schermo al pixel dell'immagine: il riquadro è scalato, la geometria no. */
  function imagePoint(event: React.PointerEvent) {
    const box = surface.current?.getBoundingClientRect();
    if (!box || !box.width || !box.height) return null;
    return [
      ((event.clientX - box.left) / box.width) * axial.columns,
      ((event.clientY - box.top) / box.height) * axial.rows,
    ];
  }

  function onSurfaceDown(event: React.PointerEvent<SVGSVGElement>) {
    if (busy || dragging !== null) return;
    const point = imagePoint(event);
    if (!point) return;
    const next = points.map((p) => [...p]);
    next.splice(insertionIndex(next, point[0], point[1]), 0, point);
    setPoints(next);
  }

  function onHandleDown(
    event: React.PointerEvent<SVGCircleElement>,
    index: number,
  ) {
    event.stopPropagation();
    if (event.altKey) {
      setPoints(points.filter((_, at) => at !== index));
      return;
    }
    (event.target as Element).setPointerCapture?.(event.pointerId);
    setDragging(index);
  }

  function onSurfaceMove(event: React.PointerEvent<SVGSVGElement>) {
    if (dragging === null) return;
    const point = imagePoint(event);
    if (!point) return;
    setPoints(points.map((p, index) => (index === dragging ? point : p)));
  }

  const [low, high] = axial.levelRangeMM.map(Math.round);
  const shown = Math.round(axial.verticalMM);
  const handle = Math.max(axial.columns / 90, 1.5);

  return (
    <section className="border-border bg-card flex flex-col gap-3 rounded-xl border p-3">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h2 className="text-sm font-medium">Draw the arch</h2>
        <p className="text-muted-foreground text-xs">
          The arch was not found automatically. Choose the axial level of the
          teeth, then click along the middle of the arch from one end to the
          other.
        </p>
      </div>

      <div className="flex flex-wrap items-end gap-3 text-xs">
        <label className="flex min-w-[14rem] flex-1 flex-col gap-1">
          <span className="text-muted-foreground">
            Axial level <span className="text-foreground">{level}</span> mm
          </span>
          <input
            type="range"
            aria-label="Axial level"
            min={low}
            max={high}
            step={1}
            value={level}
            onChange={(event) => setLevel(Number(event.target.value))}
          />
        </label>
        <Button
          variant="outline"
          disabled={busy || level === shown}
          onClick={() => onLevel(level)}
        >
          {busy ? <LoaderCircle className="animate-spin" /> : <Mountain />}
          Show level
        </Button>
        <Button
          variant="ghost"
          disabled={busy || !points.length}
          onClick={() => setPoints([])}
        >
          <Eraser /> Clear
        </Button>
        <Button
          disabled={busy || points.length < MINIMUM_POINTS}
          onClick={() =>
            onCurve(
              worldFromPixels(points, axial.worldFromPixel),
              axial.worldFromPixel.z,
            )
          }
        >
          <Spline /> Use this curve
        </Button>
      </div>

      {sketch.images.axial ? (
        <div
          className="relative mx-auto overflow-hidden rounded-lg bg-black"
          // Grande quanto basta perché l'immagine intera stia nello schermo con i comandi sopra:
          // chi posa i punti deve vedere tutta l'arcata senza scorrere la pagina a metà gesto.
          style={{
            width: `min(100%, 860px, calc(62vh * ${axial.columns / axial.rows}))`,
          }}
        >
          <Image
            unoptimized
            width={axial.columns}
            height={axial.rows}
            src={sketch.images.axial}
            alt={`Axial slice at ${shown} mm`}
            className="block w-full select-none"
            draggable={false}
          />
          <svg
            ref={surface}
            aria-label="Axial slice: click to place the points of the arch"
            className="absolute inset-0 h-full w-full cursor-crosshair touch-none"
            viewBox={`0 0 ${axial.columns} ${axial.rows}`}
            preserveAspectRatio="none"
            onPointerDown={onSurfaceDown}
            onPointerMove={onSurfaceMove}
            onPointerUp={() => setDragging(null)}
            onPointerCancel={() => setDragging(null)}
          >
            <polyline
              points={catmullRom(points)
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
                r={handle}
                fill="var(--primary)"
                className="cursor-grab"
                onPointerDown={(event) => onHandleDown(event, index)}
              />
            ))}
          </svg>
        </div>
      ) : null}

      <p className="text-muted-foreground text-xs">
        {points.length} {points.length === 1 ? 'point' : 'points'}
        {points.length < MINIMUM_POINTS
          ? ` — at least ${MINIMUM_POINTS} are needed`
          : ''}
        . Radiological orientation: the patient&rsquo;s right is on the left,
        anterior is up. Drag a point to move it, Alt-click to remove it. Showing
        another level also tries again to find the arch there.
      </p>
    </section>
  );
}
