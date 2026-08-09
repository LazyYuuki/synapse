const SECOND_MS = 1_000;
const MINUTE_MS = 60 * SECOND_MS;
const HOUR_MS = 60 * MINUTE_MS;

/** Formats a non-negative elapsed duration for the compact run metadata view. */
export function formatElapsedTime(elapsedMs: number): string {
  const boundedMs = Number.isFinite(elapsedMs) ? Math.max(0, elapsedMs) : 0;

  if (boundedMs < MINUTE_MS) return `${(boundedMs / SECOND_MS).toFixed(1)} s`;

  const totalSeconds = Math.floor(boundedMs / SECOND_MS);
  const seconds = totalSeconds % 60;
  const totalMinutes = Math.floor(totalSeconds / 60);
  if (boundedMs < HOUR_MS) return `${totalMinutes}m ${seconds.toString().padStart(2, '0')}s`;

  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `${hours}h ${minutes.toString().padStart(2, '0')}m ${seconds.toString().padStart(2, '0')}s`;
}
