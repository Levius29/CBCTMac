/** Ordering and bookkeeping for the "recent studies" list on the welcome screen. */
export const RECENT_LIMIT = 5;

/**
 * Studies the user opened most recently come first, in the order they were
 * opened; the remaining slots are filled with the newest imports. Ids that no
 * longer exist in the catalogue are ignored.
 */
export function recentStudies<T extends { id: string; created_at?: string }>(
  studies: T[],
  openedIds: string[],
  limit = RECENT_LIMIT,
): T[] {
  const byId = new Map(studies.map((s) => [s.id, s]));
  const opened: T[] = [];
  for (const id of openedIds) {
    const study = byId.get(id);
    if (study && !opened.includes(study)) opened.push(study);
  }
  const rest = studies
    .filter((s) => !opened.includes(s))
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));
  return [...opened, ...rest].slice(0, limit);
}

/** Moves a study to the front of the opened list and trims it. */
export function rememberOpened(
  openedIds: string[],
  id: string,
  limit = RECENT_LIMIT,
): string[] {
  return [id, ...openedIds.filter((x) => x !== id)].slice(0, limit);
}
