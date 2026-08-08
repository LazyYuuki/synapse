import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { PendingCorrelations } from '../../src/lib/client/pending';

describe('pending command correlations', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  const timers = {
    setTimeout: (callback: () => void, delayMs: number) => setTimeout(callback, delayMs),
    clearTimeout: (handle: unknown) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  };

  it('bounds capacity and rejects duplicate request IDs', () => {
    const pending = new PendingCorrelations(timers, 8_000, () => undefined);

    for (let index = 0; index < 32; index += 1) {
      expect(pending.add(`request-${index}`, 'subscribe', 'run.snapshot', 1)).toBe(true);
    }

    expect(pending.full).toBe(true);
    expect(pending.add('request-32', 'subscribe', 'run.snapshot', 1)).toBe(false);
    expect(pending.add('request-0', 'subscribe', 'run.snapshot', 1)).toBe(false);
  });

  it('marks a delayed command without dropping correlation and accepts a late response', () => {
    const delayed = vi.fn();
    const pending = new PendingCorrelations(timers, 8_000, delayed);
    pending.add('request-1', 'start', 'run.accepted', 4);

    vi.advanceTimersByTime(8_000);

    expect(delayed).toHaveBeenCalledWith({
      requestId: 'request-1',
      kind: 'start',
      expected: 'run.accepted',
      generation: 4,
      runId: null,
      delayed: true,
    });
    expect(pending.size).toBe(1);
    expect(pending.settle('request-1', 'run.accepted', 4)).toMatchObject({ ok: true });
    expect(pending.size).toBe(0);
  });

  it('does not remove mismatched or wrong-generation responses', () => {
    const pending = new PendingCorrelations(timers, 8_000, () => undefined);
    pending.add('request-1', 'cancel', 'run.cancel_requested', 2);

    expect(pending.settle('request-1', 'pong', 2)).toEqual({
      ok: false,
      reason: 'unexpected_response',
    });
    expect(pending.settle('request-1', 'run.cancel_requested', 3)).toEqual({
      ok: false,
      reason: 'wrong_generation',
    });
    expect(pending.size).toBe(1);
  });

  it('clears only one socket generation and cancels warning timers', () => {
    const delayed = vi.fn();
    const pending = new PendingCorrelations(timers, 8_000, delayed);
    pending.add('request-1', 'start', 'run.accepted', 1);
    pending.add('request-2', 'ping', 'pong', 2);

    expect(pending.clearGeneration(1)).toEqual([
      {
        requestId: 'request-1',
        kind: 'start',
        expected: 'run.accepted',
        generation: 1,
        runId: null,
        delayed: false,
      },
    ]);
    vi.advanceTimersByTime(8_000);
    expect(delayed).toHaveBeenCalledTimes(1);
    expect(delayed).toHaveBeenCalledWith(expect.objectContaining({ requestId: 'request-2' }));
  });
});
