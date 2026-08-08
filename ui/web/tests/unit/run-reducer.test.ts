import { describe, expect, it } from 'vitest';

import {
  applyCancellation,
  applyRunEvent,
  applyRunTerminal,
  initialRunState,
  stateFromSnapshot,
} from '../../src/lib/client/run-reducer';
import type { RunState } from '../../src/lib/client/run-types';
import { LIMITS } from '../../src/lib/protocol/constants';
import type { RunEvent, StateSnapshotPayload, Terminal } from '../../src/lib/protocol/types';
import { RUN_ID } from '../fixtures/messages';

const OTHER_RUN_ID = `run_${'B'.repeat(21)}Q`;

describe('pure run projection reducers', () => {
  it('initializes an accepted run at sequence zero without form input', () => {
    expect(initialRunState(RUN_ID)).toMatchObject({
      runId: RUN_ID,
      lastAppliedSeq: 0,
      terminal: null,
      projection: {
        status: 'starting',
        model: null,
        turn: 0,
        text: '',
        activeTool: null,
        providerAttempts: 0,
        toolCalls: 0,
        outputBytes: 0,
      },
    });
  });

  it('reduces every progress event variant through one contiguous stream', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    state = apply(state, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: '  hello\n',
    });
    state = apply(state, {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    });
    state = apply(state, {
      type: 'tool.completed',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
      status: 'ok',
      metadata: { tool: 'read', outcome: 'completed' },
    });
    state = apply(state, {
      type: 'turn.completed',
      turn: 1,
      outcome: 'continued',
      provider_attempts: 2,
      tool_calls: 1,
      output_bytes: 8,
    });
    state = apply(state, { type: 'run.owner_lost' });

    expect(state.lastAppliedSeq).toBe(7);
    expect(state.projection).toMatchObject({
      status: 'owner_lost',
      model: 'model-a',
      turn: 1,
      text: '  hello\n',
      activeTool: null,
      providerAttempts: 2,
      toolCalls: 1,
      outputBytes: 8,
    });
    expect(state.activity.map((entry) => entry.type)).toEqual([
      'run.started',
      'turn.started',
      'text.delta',
      'tool.started',
      'tool.completed',
      'turn.completed',
      'run.owner_lost',
    ]);
  });

  it('preserves cancellation through ordinary progress and gives owner loss precedence', () => {
    let state = applyCancellation(initialRunState(RUN_ID));
    expect(state.cancelAcknowledged).toBe(true);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    state = apply(state, {
      type: 'turn.completed',
      turn: 1,
      outcome: 'completed',
      provider_attempts: 1,
      tool_calls: 0,
      output_bytes: 0,
    });
    expect(state.projection.status).toBe('cancel_requested');

    state = apply(state, { type: 'run.owner_lost' });
    const acknowledgedOwnerLoss = applyCancellation(state);
    expect(acknowledgedOwnerLoss.projection.status).toBe('owner_lost');
    expect(acknowledgedOwnerLoss.cancelAcknowledged).toBe(true);
  });

  it('accepts owner-loss Tool cleanup after the visible active Tool was cleared', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    state = apply(state, {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    });
    state = apply(state, { type: 'run.owner_lost' });
    state = apply(state, {
      type: 'tool.completed',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
      status: 'ambiguous',
      metadata: { outcome: 'unknown' },
    });
    expect(state.projection.status).toBe('owner_lost');
    expect(state.lastAppliedSeq).toBe(5);
  });

  it('retains exact turn outcome and owner-loss Tool ordering knowledge', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    state = apply(state, {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    });
    state = apply(state, { type: 'run.owner_lost' });

    expect(
      applyRunEvent(state, {
        run_id: RUN_ID,
        seq: 5,
        event: {
          type: 'text.delta',
          turn: 1,
          operation_id: 'provider-1',
          item_id: 'item-1',
          content_index: 0,
          delta: 'too early',
        },
      }),
    ).toEqual({ ok: false, error: 'invalid_transition' });
    expect(
      applyRunEvent(state, {
        run_id: RUN_ID,
        seq: 5,
        event: {
          type: 'tool.started',
          turn: 1,
          operation_id: 'tool-2',
          call_id: 'call-2',
          name: 'write',
          ordinal: 2,
        },
      }),
    ).toEqual({ ok: false, error: 'invalid_transition' });
    expect(
      applyRunEvent(state, {
        run_id: RUN_ID,
        seq: 5,
        event: {
          type: 'turn.completed',
          turn: 1,
          outcome: 'completed',
          provider_attempts: 1,
          tool_calls: 1,
          output_bytes: 0,
        },
      }),
    ).toEqual({ ok: false, error: 'invalid_transition' });

    state = apply(state, {
      type: 'tool.completed',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
      status: 'ok',
      metadata: {},
    });
    state = apply(state, {
      type: 'turn.completed',
      turn: 1,
      outcome: 'completed',
      provider_attempts: 1,
      tool_calls: 1,
      output_bytes: 0,
    });
    expect(
      applyRunEvent(state, {
        run_id: RUN_ID,
        seq: 7,
        event: { type: 'turn.started', turn: 2, operation_id: 'provider-2' },
      }),
    ).toEqual({ ok: false, error: 'invalid_transition' });
  });

  it('uses successful terminal data as authoritative replacement', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    const terminal = completedTerminal(2, 'authoritative');
    const result = applyRunTerminal(state, terminal);
    expect(result).toMatchObject({
      ok: true,
      state: {
        lastAppliedSeq: 2,
        projection: {
          status: 'completed',
          text: 'authoritative',
          turn: 2,
          providerAttempts: 3,
          toolCalls: 4,
          outputBytes: 13,
          activeTool: null,
        },
      },
    });
  });

  it('lets terminal status override owner loss while preserving failed progress', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.owner_lost' });
    const terminal: Terminal = {
      run_id: RUN_ID,
      seq: 2,
      status: 'interrupted',
      result: null,
      error: { source: 'runtime', reason: 'runtime_lost', message: 'Runtime coordinator was lost' },
    };
    const result = applyRunTerminal(state, terminal);
    expect(result).toMatchObject({ ok: true, state: { projection: { status: 'interrupted' } } });
  });

  it.each([
    ['duplicate', 1],
    ['reversed', 0],
    ['skipped', 3],
    ['unsafe', Number.MAX_SAFE_INTEGER + 1],
  ])('rejects a %s sequence without partial mutation', (_label, seq) => {
    const state = apply(initialRunState(RUN_ID), { type: 'run.started', model: 'model-a' });
    const result = applyRunEvent(state, {
      run_id: RUN_ID,
      seq,
      event: { type: 'run.owner_lost' },
    });
    expect(result).toEqual({ ok: false, error: 'sequence_fault' });
    expect(state.projection.status).toBe('running');
    expect(state.lastAppliedSeq).toBe(1);
  });

  it('rejects cross-run frames and duplicate terminals', () => {
    const state = initialRunState(RUN_ID);
    expect(
      applyRunEvent(state, {
        run_id: OTHER_RUN_ID,
        seq: 1,
        event: { type: 'run.owner_lost' },
      }),
    ).toEqual({ ok: false, error: 'wrong_run' });

    const terminalResult = applyRunTerminal(state, completedTerminal(1));
    if (!terminalResult.ok) throw new Error('expected terminal application');
    expect(applyRunTerminal(terminalResult.state, completedTerminal(2))).toEqual({
      ok: false,
      error: 'event_after_terminal',
    });
  });

  it('rejects projection text overflow atomically', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    state = apply(state, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'x',
    });
    const result = applyRunEvent(state, {
      run_id: RUN_ID,
      seq: 4,
      event: {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-1',
        item_id: 'item-1',
        content_index: 0,
        delta: 'x'.repeat(LIMITS.projectionTextBytes),
      },
    });
    expect(result).toEqual({ ok: false, error: 'projection_limit' });
    expect(state.projection.text).toBe('x');
    expect(state.lastAppliedSeq).toBe(3);
  });

  it('enforces a lower hello ceiling for live aggregate text and terminal Results', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    state = apply(state, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'x'.repeat(64_000),
    });

    expect(
      applyRunEvent(
        state,
        {
          run_id: RUN_ID,
          seq: state.lastAppliedSeq + 1,
          event: {
            type: 'text.delta',
            turn: 1,
            operation_id: 'provider-1',
            item_id: 'item-2',
            content_index: 1,
            delta: 'x',
          },
        },
        64_000,
      ),
    ).toEqual({ ok: false, error: 'projection_limit' });

    expect(applyRunTerminal(state, completedTerminal(4, `${'x'.repeat(64_000)}x`), 64_000)).toEqual(
      {
        ok: false,
        error: 'projection_limit',
      },
    );
  });

  it('replaces every projection field and terminal from a snapshot', () => {
    const state = stateFromSnapshot(snapshot(true, completedTerminal(8, 'snapshot text')));
    expect(state).toMatchObject({
      runId: RUN_ID,
      lastAppliedSeq: 8,
      historyReset: true,
      activity: [],
      projection: {
        status: 'completed',
        model: 'model-b',
        turn: 2,
        text: 'snapshot text',
        providerAttempts: 3,
        toolCalls: 4,
        outputBytes: 13,
      },
      terminal: { status: 'completed', seq: 8 },
    });
  });

  it('resumes safely from snapshot projection when hidden turn knowledge is unavailable', () => {
    const state = stateFromSnapshot({ ...snapshot(false, null), last_seq: 4 });
    const result = applyRunEvent(state, {
      run_id: RUN_ID,
      seq: 5,
      event: {
        type: 'text.delta',
        turn: 2,
        operation_id: 'provider-after-snapshot',
        item_id: 'item-2',
        content_index: 0,
        delta: ' resumed',
      },
    });
    expect(result).toMatchObject({
      ok: true,
      state: { lastAppliedSeq: 5, projection: { text: 'snapshot text resumed' } },
    });
  });

  it('clears owner-loss snapshot uncertainty when a new turn proves cleanup is absent', () => {
    const state = stateFromSnapshot({
      ...snapshot(false, null),
      last_seq: 4,
      projection: { ...snapshot(false, null).projection, status: 'owner_lost', turn: 1 },
    });
    const turn = applyRunEvent(state, {
      run_id: RUN_ID,
      seq: 5,
      event: { type: 'turn.started', turn: 2, operation_id: 'provider-2' },
    });
    if (!turn.ok) throw new Error('expected turn application');
    expect(
      applyRunEvent(turn.state, {
        run_id: RUN_ID,
        seq: 6,
        event: {
          type: 'tool.completed',
          turn: 1,
          operation_id: 'stale-tool',
          call_id: 'stale-call',
          name: 'read',
          ordinal: 1,
          status: 'ok',
          metadata: {},
        },
      }),
    ).toEqual({ ok: false, error: 'invalid_transition' });
  });

  it('evicts oldest activity summaries without changing projection or cursor', () => {
    let state = initialRunState(RUN_ID);
    state = apply(state, { type: 'run.started', model: 'model-a' });
    state = apply(state, { type: 'turn.started', turn: 1, operation_id: 'provider-1' });
    for (let index = 0; index < 501; index += 1) {
      state = apply(state, {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-1',
        item_id: 'item-1',
        content_index: 0,
        delta: 'x',
      });
    }
    expect(state.activity).toHaveLength(500);
    expect(state.activity[0].seq).toBe(4);
    expect(state.projection.text).toHaveLength(501);
    expect(state.lastAppliedSeq).toBe(503);
  });
});

function apply(state: RunState, event: RunEvent): RunState {
  const result = applyRunEvent(state, {
    run_id: RUN_ID,
    seq: state.lastAppliedSeq + 1,
    event,
  });
  if (!result.ok) throw new Error(`unexpected reduction failure: ${result.error}`);
  return result.state;
}

function completedTerminal(seq: number, text = 'complete'): Terminal {
  return {
    run_id: RUN_ID,
    seq,
    status: 'completed',
    result: {
      text,
      turns: 2,
      tool_calls: 4,
      provider_retries: 1,
      output_bytes: 13,
    },
    error: null,
  };
}

function snapshot(reset: boolean, terminal: Terminal | null): StateSnapshotPayload {
  return {
    mode: 'snapshot',
    reset,
    run_id: RUN_ID,
    first_available_seq: 3,
    last_seq: terminal?.seq ?? 4,
    projection: {
      status: terminal?.status ?? 'running',
      model: 'model-b',
      turn: 2,
      text: terminal?.status === 'completed' ? '' : 'snapshot text',
      active_tool: null,
      provider_attempts: 3,
      tool_calls: 4,
      output_bytes: 13,
    },
    terminal,
  };
}
