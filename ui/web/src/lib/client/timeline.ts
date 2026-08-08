import { utf8ByteLength } from '../protocol/validation';

export type BoundedTimeline<T> = {
  entries: T[];
  bytes: number;
};

export function appendBounded<T>(
  timeline: BoundedTimeline<T>,
  entry: T,
  maximumEntries: number,
  maximumBytes: number,
): BoundedTimeline<T> {
  const entries = [...timeline.entries, entry];
  let bytes = utf8ByteLength(JSON.stringify(entries));
  while (entries.length > 0 && (entries.length > maximumEntries || bytes > maximumBytes)) {
    entries.shift();
    bytes = utf8ByteLength(JSON.stringify(entries));
  }

  if (entries.length === 0) return timeline;
  return { entries, bytes };
}
