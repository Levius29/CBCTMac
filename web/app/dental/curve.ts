/**
 * La curva d'arcata disegnata sulla fetta assiale: la geometria che serve alla pagina.
 *
 * File nostro. Qui stanno soltanto il disegno e la conversione dei clic: la curva su cui si
 * ricostruisce la calcola `scripts/dental_panorama.py`, ed è sempre quella che conta.
 */

/** La trasformazione da pixel dell'immagine assiale a millimetri, come la scrive Python. */
export type WorldFromPixel = { x: number[]; y: number[]; z: number };

/**
 * Anteprima della spline mentre si trascina.
 *
 * Catmull-Rom con tensione 0,5, la stessa di `scripts/dental_panorama.py`: passa esattamente per i
 * punti posati. Qui è disegno, non geometria — la curva su cui si ricostruisce la calcola Python.
 */
export function catmullRom(points: number[][], perSegment = 20): number[][] {
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

/**
 * Dove va il punto nuovo di un clic: fra i due punti di controllo del tratto più vicino.
 *
 * Oltre i capi della curva il punto la **allunga**, in testa o in coda. Prima finiva comunque nel
 * primo o nell'ultimo tratto, e un clic oltre l'ultimo punto piegava la curva all'indietro — che è
 * proprio il clic di chi posa un'arcata un punto alla volta.
 */
export function insertionIndex(points: number[][], x: number, y: number) {
  if (points.length < 2) return points.length;
  let best = points.length;
  let bestDistance = Infinity;
  for (let index = 0; index < points.length - 1; index += 1) {
    const [ax, ay] = points[index];
    const [bx, by] = points[index + 1];
    const dx = bx - ax;
    const dy = by - ay;
    const along = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy || 1);
    const t = Math.min(Math.max(along, 0), 1);
    const distance = Math.hypot(x - (ax + dx * t), y - (ay + dy * t));
    if (distance < bestDistance) {
      bestDistance = distance;
      if (index === 0 && along < 0) best = 0;
      else if (index === points.length - 2 && along > 1) best = points.length;
      else best = index + 1;
    }
  }
  return best;
}

/**
 * I punti posati sull'immagine, in millimetri alla quota della fetta.
 *
 * Nel riferimento RAS del volume preparato, che è quello in cui lavora `dental_panorama.py`.
 */
export function worldFromPixels(points: number[][], affine: WorldFromPixel) {
  const { x, y, z } = affine;
  return points.map(([column, row]) => [
    x[0] * column + x[1] * row + x[2],
    y[0] * column + y[1] * row + y[2],
    z,
  ]);
}
