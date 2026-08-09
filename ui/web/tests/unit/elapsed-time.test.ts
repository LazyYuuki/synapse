import { describe, expect, it } from 'vitest';

import { formatElapsedTime } from '../../src/lib/client/elapsed-time';

describe('elapsed turn time formatting', () => {
  it.each([
    [0, '0.0 s'],
    [2_450, '2.5 s'],
    [59_999, '60.0 s'],
    [60_000, '1m 00s'],
    [125_900, '2m 05s'],
    [3_661_000, '1h 01m 01s'],
  ])('formats %i milliseconds as %s', (elapsedMs, expected) => {
    expect(formatElapsedTime(elapsedMs)).toBe(expected);
  });

  it.each([[-1], [Number.NaN], [Number.POSITIVE_INFINITY]])(
    'bounds invalid duration %s to zero',
    (elapsedMs) => {
      expect(formatElapsedTime(elapsedMs)).toBe('0.0 s');
    },
  );
});
