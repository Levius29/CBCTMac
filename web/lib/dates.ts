/** Dates are stored as YYYY-MM-DD; a fixed locale keeps server and client markup identical. */
export const displayDate = (s: string) =>
  s
    ? new Date(s + 'T12:00:00').toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
      })
    : 'Unknown date';
