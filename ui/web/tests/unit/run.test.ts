import { render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { describe, expect, it, vi } from 'vitest';

import {
  createRunController,
  type RunControllerDependencies,
  type RunTransport,
} from '../../src/lib/client/run.svelte';
import type { MessageContext } from '../../src/lib/client/connection.svelte';
import type { CommandKind, PendingCommand } from '../../src/lib/client/pending';
import type { ServerMessage, StateSnapshotPayload, Terminal } from '../../src/lib/protocol/types';
import RunStateHarness from '../fixtures/RunStateHarness.svelte';
import { MemorySessionStorage } from '../support/fake-socket';
import { RUN_ID } from '../fixtures/messages';

describe('current run controller', () => {
  it('installs only a correlated accepted run, persists only its ID, and reacts through runes', async () => {
    const { controller, storage } = setup();
    render(RunStateHarness, { controller });
    expect(screen.getByTestId('run-state')).toHaveTextContent('idle:none:-');

    controller.handleMessage(accepted(), context('start', 'start-1', null));
    await tick();

    expect(screen.getByTestId('run-state')).toHaveTextContent('live:starting:0');
    expect(storage.values).toEqual(new Map([['synapse.run_id', RUN_ID]]));
  });

  it('returns snapshots that cannot mutate authoritative run or activity state', () => {
    const { controller } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    const exposed = controller.current;
    if (!exposed) throw new Error('expected current run');
    exposed.lastAppliedSeq = 99;
    exposed.projection.model = 'forged';
    exposed.activity.length = 0;

    expect(controller.current).toMatchObject({
      lastAppliedSeq: 1,
      projection: { model: 'model-a' },
      activity: [{ seq: 1, type: 'run.started' }],
    });
  });

  it('reconnects an in-memory projection from its applied cursor', () => {
    const { controller, subscribe } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    controller.handleGenerationEnd(1, []);
    controller.handleReady(2);

    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, 1);
    expect(controller.syncState).toBe('awaiting_replay');
    expect(controller.current?.projection.model).toBe('model-a');
  });

  it('requests an authoritative snapshot when a new hello lowers retained output policy', () => {
    const { controller, subscribe } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    controller.handleMessage(
      event(2, { type: 'turn.started', turn: 1, operation_id: 'provider-1' }),
      asyncContext(),
    );
    controller.handleMessage(
      event(3, {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-1',
        item_id: 'item-1',
        content_index: 0,
        delta: 'hello',
      }),
      asyncContext(),
    );

    controller.handleGenerationEnd(1, []);
    controller.handleReady(2, 4);

    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, undefined);
    expect(controller.syncState).toBe('recovering');
  });

  it('fails protocol instead of recovering when live output exceeds hello policy', () => {
    const { controller, subscribe, failProtocol } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    controller.handleMessage(
      event(2, { type: 'turn.started', turn: 1, operation_id: 'provider-1' }),
      asyncContext(),
    );
    controller.handleMessage(
      event(3, {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-1',
        item_id: 'item-1',
        content_index: 0,
        delta: 'hello',
      }),
      asyncContext(1, 4),
    );

    expect(failProtocol).toHaveBeenCalledOnce();
    expect(subscribe).not.toHaveBeenCalled();
    expect(controller.syncState).toBe('protocol_fault');
  });

  it('restores a validated stored run through subscribe without a cursor', () => {
    const storage = new MemorySessionStorage();
    storage.values.set('synapse.run_id', RUN_ID);
    const { controller, subscribe } = setup(storage);

    expect(controller.restoredRunId).toBe(RUN_ID);
    expect(controller.current).toBeNull();
    controller.handleReady(3);
    expect(subscribe).toHaveBeenCalledWith(RUN_ID, undefined);

    controller.handleMessage(
      snapshotMessage('subscribe-1', snapshot(false)),
      context('subscribe', 'subscribe-1', RUN_ID, 3),
    );
    expect(controller.current?.lastAppliedSeq).toBe(4);
    expect(controller.current?.projection.text).toBe('snapshot text');
    expect(controller.syncState).toBe('live');
  });

  it('removes invalid stored run IDs and tolerates unavailable storage', () => {
    const invalid = new MemorySessionStorage();
    invalid.values.set('synapse.run_id', 'not-a-run');
    expect(setup(invalid).controller.restoredRunId).toBeNull();
    expect(invalid.values.has('synapse.run_id')).toBe(false);

    invalid.throwOnRead = true;
    expect(setup(invalid).controller.restoredRunId).toBeNull();

    const acceptedStorage = new MemorySessionStorage();
    acceptedStorage.throwOnWrite = true;
    expect(() => acceptedController(acceptedStorage)).not.toThrow();
  });

  it('commits replay only after acknowledgement and catches up contiguously', () => {
    const { controller } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    controller.handleGenerationEnd(1, []);
    controller.handleReady(2);
    const before = controller.current;

    controller.handleMessage(
      replayMessage('subscribe-1', 3),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(controller.current).toEqual(before);
    expect(controller.catchUpTarget).toBe(3);
    expect(controller.syncState).toBe('catching_up');

    controller.handleMessage(
      event(2, { type: 'turn.started', turn: 1, operation_id: 'provider-1' }),
      asyncContext(2),
    );
    controller.handleMessage(
      event(3, {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-1',
        item_id: 'item-1',
        content_index: 0,
        delta: 'hello',
      }),
      asyncContext(2),
    );
    expect(controller.syncState).toBe('live');
    expect(controller.current?.projection.text).toBe('hello');
  });

  it('replaces all local state and reports lost history on reset', () => {
    const { controller } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    controller.handleMessage(snapshotMessage(null, snapshot(true)), asyncContext());

    expect(controller.current).toMatchObject({
      lastAppliedSeq: 4,
      historyReset: true,
      activity: [],
      projection: { model: 'model-b', text: 'snapshot text', turn: 2 },
    });
    expect(controller.notice?.code).toBe('history_reset');
    expect(controller.syncState).toBe('live');
  });

  it('retains a witnessed cancellation acknowledgement through owner-loss snapshot recovery', () => {
    const { controller } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    controller.handleMessage(cancelled('cancel-1'), context('cancel', 'cancel-1'));
    controller.handleMessage(
      snapshotMessage(null, {
        ...snapshot(true),
        first_available_seq: 3,
        last_seq: 3,
        projection: {
          ...snapshot(true).projection,
          status: 'owner_lost',
          model: 'model-a',
        },
      }),
      asyncContext(),
    );
    expect(controller.current?.projection.status).toBe('owner_lost');
    expect(controller.current?.cancelAcknowledged).toBe(true);
  });

  it('rejects an asynchronous reset when the applied cursor is not stale', () => {
    const { controller } = acceptedController();
    controller.handleMessage(
      snapshotMessage(null, { ...snapshot(true), first_available_seq: 1 }),
      asyncContext(),
    );
    expect(controller.syncState).toBe('protocol_fault');
    expect(controller.current?.lastAppliedSeq).toBe(0);
  });

  it('keeps the last valid view and requests one no-cursor snapshot after a sequence fault', () => {
    const { controller, subscribe } = acceptedController();
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext());
    const before = controller.current;

    controller.handleMessage(event(3, { type: 'run.owner_lost' }), asyncContext());
    controller.handleMessage(event(4, { type: 'run.owner_lost' }), asyncContext());

    expect(controller.current).toEqual(before);
    expect(controller.notice?.code).toBe('sequence_fault');
    expect(controller.syncState).toBe('recovering');
    expect(subscribe).toHaveBeenCalledTimes(1);
    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, undefined);
  });

  it('turns a pre-ack frame into snapshot recovery without applying it', () => {
    const { controller, subscribe } = acceptedController();
    controller.handleGenerationEnd(1, []);
    controller.handleReady(2);
    controller.handleMessage(event(1, { type: 'run.started', model: 'model-a' }), asyncContext(2));
    expect(controller.current?.lastAppliedSeq).toBe(0);
    expect(subscribe).toHaveBeenCalledTimes(1);

    controller.handleMessage(
      replayMessage('subscribe-1', 1),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(subscribe).toHaveBeenCalledTimes(2);
    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, undefined);
  });

  it('keeps an in-flight correlation after an asynchronous reset and realigns replay', () => {
    const { controller, subscribe } = acceptedController();
    controller.handleGenerationEnd(1, []);
    controller.handleReady(2);

    controller.handleMessage(snapshotMessage(null, snapshot(true)), asyncContext(2));
    expect(controller.current?.lastAppliedSeq).toBe(4);
    expect(controller.syncState).toBe('recovering');

    controller.handleMessage(
      replayMessage('subscribe-1', 4),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, undefined);
    controller.handleMessage(
      snapshotMessage('subscribe-2', snapshot(false)),
      context('subscribe', 'subscribe-2', RUN_ID, 2),
    );
    expect(controller.syncState).toBe('live');
    expect(controller.current?.lastAppliedSeq).toBe(4);
  });

  it('fails closed on snapshot modes that contradict the requested cursor strategy', () => {
    const restoredStorage = new MemorySessionStorage();
    restoredStorage.values.set('synapse.run_id', RUN_ID);
    const restored = setup(restoredStorage);
    restored.controller.handleReady(1);
    restored.controller.handleMessage(
      snapshotMessage('subscribe-1', snapshot(true)),
      context('subscribe', 'subscribe-1'),
    );
    expect(restored.controller.syncState).toBe('protocol_fault');

    const retained = acceptedController();
    retained.controller.handleGenerationEnd(1, []);
    retained.controller.handleReady(2);
    retained.controller.handleMessage(
      snapshotMessage('subscribe-1', snapshot(false)),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(retained.controller.syncState).toBe('protocol_fault');
  });

  it('rejects reset and snapshot cursors that contradict retained state', () => {
    const stale = acceptedController();
    stale.controller.handleMessage(
      event(1, { type: 'run.started', model: 'model-a' }),
      asyncContext(),
    );
    stale.controller.handleGenerationEnd(1, []);
    stale.controller.handleReady(2);
    stale.controller.handleMessage(
      snapshotMessage('subscribe-1', {
        ...snapshot(true),
        first_available_seq: 2,
      }),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(stale.controller.syncState).toBe('protocol_fault');

    const regressed = acceptedController();
    regressed.controller.handleMessage(
      event(1, { type: 'run.started', model: 'model-a' }),
      asyncContext(),
    );
    regressed.controller.handleMessage(event(3, { type: 'run.owner_lost' }), asyncContext());
    regressed.controller.handleMessage(
      snapshotMessage('subscribe-1', {
        mode: 'snapshot',
        reset: false,
        run_id: RUN_ID,
        first_available_seq: 1,
        last_seq: 0,
        projection: {
          status: 'starting',
          model: null,
          turn: 0,
          text: '',
          active_tool: null,
          provider_attempts: 0,
          tool_calls: 0,
          output_bytes: 0,
        },
        terminal: null,
      }),
      context('subscribe', 'subscribe-1'),
    );
    expect(regressed.controller.syncState).toBe('protocol_fault');
    expect(regressed.controller.current?.lastAppliedSeq).toBe(1);
  });

  it('bounds replay catch-up and recovers through a no-cursor snapshot', () => {
    const { controller, subscribe, timerCallbacks } = acceptedController();
    controller.handleGenerationEnd(1, []);
    controller.handleReady(2);
    controller.handleMessage(
      replayMessage('subscribe-1', 2),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(controller.syncState).toBe('catching_up');

    timerCallbacks.at(-1)?.();
    expect(controller.syncState).toBe('recovering');
    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, undefined);
  });

  it('forces a no-cursor snapshot when a cancel outcome was lost with the generation', () => {
    const { controller, subscribe } = acceptedController();
    controller.handleGenerationEnd(1, [pending('cancel', 'cancel-1', RUN_ID, 1)]);
    controller.handleReady(2);
    expect(subscribe).toHaveBeenCalledWith(RUN_ID, undefined);
  });

  it('updates cancellation status without consuming sequence and preserves owner loss', () => {
    const { controller } = acceptedController();
    controller.handleMessage(cancelled('cancel-1'), context('cancel', 'cancel-1'));
    expect(controller.current?.projection.status).toBe('cancel_requested');
    expect(controller.current?.lastAppliedSeq).toBe(0);

    controller.handleMessage(event(1, { type: 'run.owner_lost' }), asyncContext());
    controller.handleMessage(cancelled('cancel-2'), context('cancel', 'cancel-2'));
    expect(controller.current?.projection.status).toBe('owner_lost');
  });

  it('installs a terminal-bearing snapshot and recovers rather than duplicating terminal', () => {
    const storage = new MemorySessionStorage();
    storage.values.set('synapse.run_id', RUN_ID);
    const { controller, subscribe } = setup(storage);
    controller.handleReady(1);
    const terminal = completedTerminal(5);
    controller.handleMessage(
      snapshotMessage('subscribe-1', {
        ...snapshot(false),
        last_seq: 5,
        projection: { ...snapshot(false).projection, status: 'completed', text: 'complete' },
        terminal,
      }),
      context('subscribe', 'subscribe-1'),
    );
    expect(controller.current?.terminal).toEqual(terminal);
    expect(controller.syncState).toBe('terminal');

    controller.handleMessage(
      { version: 1, type: 'run.terminal', request_id: null, payload: { ...terminal, seq: 6 } },
      asyncContext(),
    );
    expect(controller.current?.terminal).toEqual(terminal);
    expect(subscribe).toHaveBeenLastCalledWith(RUN_ID, undefined);
  });

  it('explains run_not_found before clearing stale state and restoration', () => {
    const storage = new MemorySessionStorage();
    storage.values.set('synapse.run_id', RUN_ID);
    const { controller } = setup(storage);
    controller.handleReady(1);
    controller.handleMessage(
      serverError('subscribe-1', 'run_not_found'),
      context('subscribe', 'subscribe-1'),
    );

    expect(controller.notice).toMatchObject({ code: 'run_not_found' });
    expect(controller.syncState).toBe('not_found');
    expect(controller.current).toBeNull();
    expect(controller.restoredRunId).toBeNull();
    expect(storage.values.has('synapse.run_id')).toBe(false);
  });

  it('clears stale state when cancellation reports run_not_found', () => {
    const { controller, storage } = acceptedController();
    controller.handleMessage(
      serverError('cancel-1', 'run_not_found'),
      context('cancel', 'cancel-1'),
    );
    expect(controller.notice?.code).toBe('run_not_found');
    expect(controller.current).toBeNull();
    expect(storage.values.has('synapse.run_id')).toBe(false);
  });

  it('retains state and closes transport when synchronization recovery fails', () => {
    const { controller, failProtocol } = acceptedController();
    controller.handleGenerationEnd(1, []);
    controller.handleReady(2);
    const before = controller.current;
    controller.handleMessage(
      serverError('subscribe-1', 'invalid_cursor'),
      context('subscribe', 'subscribe-1', RUN_ID, 2),
    );
    expect(controller.current).toEqual(before);
    expect(controller.notice?.code).toBe('subscription_failed');
    expect(controller.syncState).toBe('protocol_fault');
    expect(failProtocol).toHaveBeenCalledOnce();
  });

  it('clears a terminal run explicitly without sending cancellation', () => {
    const { controller, storage, subscribe } = acceptedController();
    controller.handleMessage(
      {
        version: 1,
        type: 'run.terminal',
        request_id: null,
        payload: {
          run_id: RUN_ID,
          seq: 1,
          status: 'interrupted',
          result: null,
          error: {
            source: 'runtime',
            reason: 'runtime_lost',
            message: 'Runtime coordinator was lost',
          },
        },
      },
      asyncContext(),
    );
    expect(controller.clear()).toBe(true);
    expect(controller.current).toBeNull();
    expect(controller.restoredRunId).toBeNull();
    expect(storage.values.size).toBe(0);
    expect(subscribe).not.toHaveBeenCalled();
  });

  it('refuses local clear while a run is active or synchronization is pending', () => {
    const active = acceptedController();
    expect(active.controller.clear()).toBe(false);
    expect(active.controller.current?.runId).toBe(RUN_ID);

    const storage = new MemorySessionStorage();
    storage.values.set('synapse.run_id', RUN_ID);
    const restoring = setup(storage);
    restoring.controller.handleReady(1);
    expect(restoring.controller.clear()).toBe(false);
    expect(restoring.controller.restoredRunId).toBe(RUN_ID);
  });

  it('refuses clear until an in-flight cancel receives its terminal acknowledgement', () => {
    const { controller } = acceptedController();
    controller.handleCommandSent(
      {
        version: 1,
        type: 'run.cancel',
        request_id: 'cancel-1',
        payload: { run_id: RUN_ID },
      },
      1,
    );
    controller.handleMessage(
      {
        version: 1,
        type: 'run.terminal',
        request_id: null,
        payload: {
          run_id: RUN_ID,
          seq: 1,
          status: 'interrupted',
          result: null,
          error: {
            source: 'runtime',
            reason: 'runtime_lost',
            message: 'Runtime coordinator was lost',
          },
        },
      },
      asyncContext(),
    );
    expect(controller.clear()).toBe(false);

    controller.handleMessage(
      {
        version: 1,
        type: 'run.cancel_requested',
        request_id: 'cancel-1',
        payload: { run_id: RUN_ID, status: 'already_terminal' },
      },
      context('cancel', 'cancel-1'),
    );
    expect(controller.clear()).toBe(true);
  });
});

function setup(storage = new MemorySessionStorage()) {
  let request = 0;
  const timerCallbacks: Array<() => void> = [];
  const subscribe = vi.fn((runId: string, afterSeq?: number) => {
    void runId;
    void afterSeq;
    return { ok: true as const, requestId: `subscribe-${++request}` };
  });
  const failProtocol = vi.fn();
  const transport: RunTransport = { subscribe, failProtocol };
  const dependencies: RunControllerDependencies = {
    storage,
    transport,
    setTimeout(callback) {
      timerCallbacks.push(callback);
      return callback;
    },
    clearTimeout() {},
  };
  return {
    controller: createRunController(dependencies),
    storage,
    subscribe,
    failProtocol,
    timerCallbacks,
  };
}

function acceptedController(storage = new MemorySessionStorage()) {
  const result = setup(storage);
  result.controller.handleReady(1);
  result.controller.handleMessage(accepted(), context('start', 'start-1', null));
  result.subscribe.mockClear();
  return result;
}

function context(
  kind: CommandKind,
  requestId: string,
  runId: string | null = RUN_ID,
  generation = 1,
): MessageContext {
  return {
    generation,
    correlation: pending(kind, requestId, runId, generation),
    maxOutputBytes: 524_288,
  };
}

function asyncContext(generation = 1, maxOutputBytes = 524_288): MessageContext {
  return { generation, correlation: null, maxOutputBytes };
}

function pending(
  kind: CommandKind,
  requestId: string,
  runId: string | null,
  generation: number,
): PendingCommand {
  const expected =
    kind === 'start'
      ? 'run.accepted'
      : kind === 'cancel'
        ? 'run.cancel_requested'
        : kind === 'subscribe'
          ? 'run.snapshot'
          : 'pong';
  return { requestId, kind, expected, generation, runId, delayed: false };
}

function accepted(): Extract<ServerMessage, { type: 'run.accepted' }> {
  return {
    version: 1,
    type: 'run.accepted',
    request_id: 'start-1',
    payload: { run_id: RUN_ID, status: 'starting' },
  };
}

function cancelled(requestId: string): Extract<ServerMessage, { type: 'run.cancel_requested' }> {
  return {
    version: 1,
    type: 'run.cancel_requested',
    request_id: requestId,
    payload: { run_id: RUN_ID, status: 'cancel_requested' },
  };
}

function event(
  seq: number,
  runEvent: Extract<ServerMessage, { type: 'run.event' }>['payload']['event'],
): Extract<ServerMessage, { type: 'run.event' }> {
  return {
    version: 1,
    type: 'run.event',
    request_id: null,
    payload: { run_id: RUN_ID, seq, event: runEvent },
  };
}

function replayMessage(
  requestId: string,
  lastSeq: number,
): Extract<ServerMessage, { type: 'run.snapshot' }> {
  return {
    version: 1,
    type: 'run.snapshot',
    request_id: requestId,
    payload: {
      mode: 'replay',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: lastSeq,
      projection: null,
      terminal: null,
    },
  };
}

function snapshotMessage(
  requestId: string | null,
  payload: StateSnapshotPayload,
): Extract<ServerMessage, { type: 'run.snapshot' }> {
  return { version: 1, type: 'run.snapshot', request_id: requestId, payload };
}

function serverError(
  requestId: string,
  code: 'run_not_found' | 'invalid_cursor',
): Extract<ServerMessage, { type: 'server.error' }> {
  return {
    version: 1,
    type: 'server.error',
    request_id: requestId,
    payload: {
      code,
      message: code === 'run_not_found' ? 'Run was not found' : 'Run cursor is invalid',
      retryable: false,
    },
  };
}

function snapshot(reset: boolean): StateSnapshotPayload {
  return {
    mode: 'snapshot',
    reset,
    run_id: RUN_ID,
    first_available_seq: 3,
    last_seq: 4,
    projection: {
      status: 'running',
      model: 'model-b',
      turn: 2,
      text: 'snapshot text',
      active_tool: null,
      provider_attempts: 3,
      tool_calls: 4,
      output_bytes: 13,
    },
    terminal: null,
  };
}

function completedTerminal(seq: number): Terminal {
  return {
    run_id: RUN_ID,
    seq,
    status: 'completed',
    result: { text: 'complete', turns: 2, tool_calls: 4, provider_retries: 1, output_bytes: 13 },
    error: null,
  };
}
