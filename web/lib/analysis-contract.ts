/** Adapter boundary for a future local model. No model or diagnostic inference is shipped. */
export type AnalysisRequest = {
  patientId: string;
  studyId: string;
  seriesId: string;
  sourceSha256: string;
  modality: 'MR' | 'CT';
  bodyPart: string;
  dimensions: [number, number, number];
  affineRASmm: number[][];
};
export type AnalysisResult = {
  request: AnalysisRequest;
  model: { id: string; version: string };
  coordinateSystem: 'RAS-mm';
  findings: {
    id: string;
    label: string;
    pointRASmm: [number, number, number];
    confidence?: number;
  }[];
  segmentation?: { assetId: string; sourceSha256: string };
};
export interface LocalModelAdapter {
  id: string;
  version: string;
  supports(request: AnalysisRequest): boolean;
  analyze(
    request: AnalysisRequest,
    signal: AbortSignal,
  ): Promise<AnalysisResult>;
}
export function validateAnalysisSource(
  result: AnalysisResult,
  request: AnalysisRequest,
) {
  for (const key of [
    'patientId',
    'studyId',
    'seriesId',
    'sourceSha256',
  ] as const)
    if (result.request[key] !== request[key])
      throw new Error(`Analysis source mismatch: ${key}`);
  if (
    JSON.stringify(result.request.affineRASmm) !==
      JSON.stringify(request.affineRASmm) ||
    JSON.stringify(result.request.dimensions) !==
      JSON.stringify(request.dimensions)
  )
    throw new Error('Analysis geometry mismatch');
  if (result.coordinateSystem !== 'RAS-mm')
    throw new Error('Unsupported coordinate system');
  for (const f of result.findings)
    if (
      f.pointRASmm.length !== 3 ||
      !f.pointRASmm.every(Number.isFinite) ||
      (f.confidence !== undefined &&
        (!Number.isFinite(f.confidence) ||
          f.confidence < 0 ||
          f.confidence > 1))
    )
      throw new Error('Invalid finding coordinates or confidence');
  if (
    result.segmentation &&
    result.segmentation.sourceSha256 !== request.sourceSha256
  )
    throw new Error('Segmentation source mismatch');
}
