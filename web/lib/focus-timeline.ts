/** Longitudinal coordinates are always physical RAS millimetres in the fixed series. */
export type Vec3 = [number, number, number];
export type TimelineSeries = {
  id: string;
  label: string;
  shortLabel?: string;
  originalSeriesDescription?: string;
  url: string;
  displayRange: number[];
  modality?: string;
  contrast?: { status?: string };
};
export type TimelineStudy = {
  id: string;
  date: string;
  label: string;
  body_part: string;
  series: TimelineSeries[];
};
export type FocusRegion = {
  id: string;
  patientId: string;
  studyId: string;
  seriesId: string;
  sourceHash: string;
  name: string;
  point: Vec3;
  radius: number;
  reviews: Record<
    string,
    {
      registrationId: string;
      status: 'checked' | 'corrected';
      point: Vec3;
      at: string;
    }
  >;
};
export type Registration = {
  id: string;
  status: 'queued' | 'running' | 'ready' | 'error';
  stage: string;
  error?: string;
  result?: {
    url: string;
    transformRAS: number[][];
    movingWorldToVoxel: number[][];
    movingDimensions: number[];
    overlap: number;
    algorithm: string;
    referenceHash: string;
    movingHash: string;
  };
};
export function family(s: TimelineSeries): string {
  const text =
    `${s.shortLabel || ''} ${s.label} ${s.originalSeriesDescription || ''}`.toUpperCase();
  if (/FLAIR/.test(text)) return 'FLAIR';
  if (/\bADC\b/.test(text)) return 'ADC';
  if (/\bSWI\b/.test(text)) return 'SWI';
  if (/\bDIR\b/.test(text)) return 'DIR';
  if (/\bT2\b/.test(text)) return 'T2';
  if (/\bT1\b|BRAVO|MPRAGE|FSPGR/.test(text)) return 'T1';
  return 'OTHER';
}
export function phase(s: TimelineSeries) {
  if (s.contrast?.status === 'confirmed') return 'post';
  // Unknown acquisition metadata must never silently become a pre-contrast scan.
  return s.contrast?.status === 'pre' || s.contrast?.status === 'absent'
    ? 'pre'
    : 'unknown';
}
export function compatible(a: TimelineSeries, b: TimelineSeries) {
  return (
    family(a) !== 'OTHER' &&
    family(a) === family(b) &&
    phase(a) === phase(b) &&
    (a.modality || 'MR') === (b.modality || 'MR')
  );
}
export function seriesCaption(s: TimelineSeries) {
  return `${s.label} · ${phase(s) === 'post' ? 'post-contrast' : phase(s) === 'pre' ? 'pre-contrast' : 'contrast phase unknown'}`;
}
export function validPoint(p: unknown): p is Vec3 {
  return (
    Array.isArray(p) &&
    p.length === 3 &&
    p.every(
      (v) =>
        typeof v === 'number' && Number.isFinite(v) && Math.abs(v) < 100000,
    )
  );
}
export function transformPoint(matrix: number[][], p: Vec3): Vec3 {
  return matrix
    .slice(0, 3)
    .map(
      (row) => row[0] * p[0] + row[1] * p[1] + row[2] * p[2] + row[3],
    ) as Vec3;
}
export function covered(
  result: NonNullable<Registration['result']>,
  p: Vec3,
  radius = 0,
) {
  const voxel = transformPoint(
    result.movingWorldToVoxel,
    transformPoint(result.transformRAS, p),
  );
  // The transformed sphere's extent in each voxel axis, including oblique directions.
  return voxel.every((v, i) => {
    const r = radius * Math.hypot(...result.movingWorldToVoxel[i].slice(0, 3));
    return v - r >= -0.5 && v + r <= result.movingDimensions[i] - 0.5;
  });
}
