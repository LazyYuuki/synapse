import { render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  createBrowserConnectionController,
  createConnectionController,
  validateApiUrl,
  type ConnectionCallbacks,
  type ConnectionDependencies,
} from '../../src/lib/client/connection.svelte';
import ConnectionStateHarness from '../fixtures/ConnectionStateHarness.svelte';
import { REQUEST_ID, RUN_ID, serverEnvelope } from '../fixtures/messages';
import { FakeSocket, FakeSocketFactory, MemorySessionStorage } from '../support/fake-socket';

const hello = serverEnvelope('server.hello', null, {
  protocol: 1,
  replay: 'memory',
  max_active_runs: 1,
  cwd: '/synthetic/server-launch',
  max_output_bytes: 524_288,
});

describe('WebSocket connection controller', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it.each([
    ['ws://127.0.0.1:4848/v1/socket', 'ws://127.0.0.1:4848/v1/socket'],
    ['WS://LOCALHOST:80/v1/socket', 'ws://localhost:80/v1/socket'],
  ])('accepts and canonicalizes local API URL %s', (candidate, expected) => {
    expect(validateApiUrl(candidate)).toEqual({ ok: true, url: expected });
  });

  it.each([
    'wss://localhost:4848/v1/socket',
    'ws://example.com:4848/v1/socket',
    'ws://[::1]:4848/v1/socket',
    'ws://user@localhost:4848/v1/socket',
    'ws://localhost/v1/socket',
    'ws://localhost:0/v1/socket',
    'ws://localhost:65536/v1/socket',
    'ws://localhost:4848/v1/socket?token=x',
    'ws://localhost:4848/v1/socket#fragment',
    'ws://localhost:4848/V1/SOCKET',
    ' ws://localhost:4848/v1/socket',
  ])('rejects unsupported API URL %s', (candidate) => {
    expect(validateApiUrl(candidate)).toMatchObject({
      ok: false,
      error: { code: 'invalid_url' },
    });
  });

  it('does not construct a socket until explicit connect and gates readiness on hello', () => {
    const { controller, factory, ready } = setup();
    expect(factory.sockets).toHaveLength(0);
    expect(controller.lifecycle).toBe('idle');

    expect(controller.connect()).toEqual({ ok: true });
    const socket = factory.sockets[0];
    expect(controller.lifecycle).toBe('connecting');
    socket.emitOpen();
    expect(controller.lifecycle).toBe('awaiting_hello');
    socket.emitMessage(hello);

    expect(controller.lifecycle).toBe('ready');
    expect(controller.hello?.payload).toEqual({
      protocol: 1,
      replay: 'memory',
      max_active_runs: 1,
      cwd: '/synthetic/server-launch',
      max_output_bytes: 524_288,
    });
    expect(ready).toHaveBeenCalledOnce();
  });

  it('rejects invalid URLs before socket construction', () => {
    const { controller, factory } = setup();
    expect(controller.connect('ws://remote.example:4848/v1/socket')).toMatchObject({
      ok: false,
      error: { code: 'invalid_url' },
    });
    expect(factory.sockets).toHaveLength(0);
  });

  it('restores only a validated URL and tolerates unavailable session storage', () => {
    const storage = new MemorySessionStorage();
    storage.values.set('synapse.api_url', 'ws://LOCALHOST:9000/v1/socket');
    const restored = setup({}, storage).controller;
    expect(restored.apiUrl).toBe('ws://localhost:9000/v1/socket');

    storage.throwOnRead = true;
    expect(setup({}, storage).controller.apiUrl).toBe('ws://127.0.0.1:4848/v1/socket');
    storage.throwOnRead = false;
    storage.throwOnWrite = true;
    expect(restored.connect()).toEqual({ ok: true });

    const invalid = new MemorySessionStorage();
    invalid.values.set('synapse.api_url', 'ws://remote.example:9000/v1/socket');
    expect(setup({}, invalid).controller.apiUrl).toBe('ws://127.0.0.1:4848/v1/socket');
    expect(invalid.values.has('synapse.api_url')).toBe(false);
  });

  it('fails closed when the first frame is not hello', () => {
    const { controller, factory } = setup();
    controller.connect();
    const socket = factory.sockets[0];
    socket.emitOpen();
    socket.emitMessage(serverEnvelope('pong', REQUEST_ID, {}));

    expect(controller.lifecycle).toBe('protocol_fault');
    expect(controller.notice?.code).toBe('protocol_fault');
    expect(socket.closes).toEqual([4_000]);
    vi.advanceTimersByTime(60_000);
    expect(factory.sockets).toHaveLength(1);
  });

  it('ignores all callbacks from a replaced socket generation', () => {
    const { controller, factory } = setup();
    controller.connect();
    const first = factory.sockets[0];
    first.emitOpen();
    const [queuedMessage] = first.captureListeners('message');

    controller.connect('ws://localhost:4849/v1/socket');
    const second = factory.sockets[1];
    expect(first.closes).toEqual([1_000]);
    expect(controller.lastClose).toEqual({ code: 1_000, kind: 'replaced' });
    queuedMessage({ data: hello });
    first.emitClose(1_006);
    expect(controller.lifecycle).toBe('connecting');

    second.emitOpen();
    second.emitMessage(hello);
    expect(controller.lifecycle).toBe('ready');
    expect(controller.generation).toBe(2);
  });

  it('completes reconnect state before generation-end callbacks may reconnect', () => {
    const state: { controller: ReturnType<typeof createConnectionController> | null } = {
      controller: null,
    };
    let reentered = false;
    const context = setup({
      onGenerationEnd: () => {
        if (reentered) return;
        reentered = true;
        state.controller?.connect('ws://localhost:4850/v1/socket');
      },
    });
    const controller = context.controller;
    state.controller = controller;
    controller.connect();
    const first = context.factory.sockets[0];
    first.emitOpen();
    first.emitMessage(hello);
    first.emitClose(1_006);

    expect(context.factory.sockets).toHaveLength(2);
    const second = context.factory.sockets[1];
    second.emitOpen();
    second.emitMessage(hello);
    vi.advanceTimersByTime(1_000);
    expect(context.factory.sockets).toHaveLength(2);
    expect(controller.lifecycle).toBe('ready');
  });

  it('routes asynchronous frames while correlating the exact direct response', () => {
    const messages = vi.fn();
    const { controller, socket } = readyController({ onMessage: messages });
    const sent = controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    expect(sent.ok).toBe(true);
    expect(controller.pendingCount).toBe(1);

    socket.emitMessage(
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 1,
        event: { type: 'run.started', model: 'model-a' },
      }),
    );
    expect(messages).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: 'run.event' }),
      expect.objectContaining({ correlation: null }),
    );

    const requestId = sent.ok ? sent.requestId : '';
    socket.emitMessage(
      serverEnvelope('run.accepted', requestId, { run_id: RUN_ID, status: 'starting' }),
    );
    expect(controller.pendingCount).toBe(0);
    expect(messages).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: 'run.accepted' }),
      expect.objectContaining({ correlation: expect.objectContaining({ kind: 'start' }) }),
    );
  });

  it('treats mismatched and unknown direct responses as protocol faults', () => {
    const { controller, socket } = readyController();
    const sent = controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    const requestId = sent.ok ? sent.requestId : '';

    socket.emitMessage(serverEnvelope('pong', requestId, {}));
    expect(controller.lifecycle).toBe('protocol_fault');

    const second = readyController();
    second.socket.emitMessage(serverEnvelope('pong', 'unknown-request', {}));
    expect(second.controller.lifecycle).toBe('protocol_fault');
  });

  it.each(['cancel', 'subscribe'] as const)(
    'requires %s responses to match the requested run ID',
    (command) => {
      const { controller, socket } = readyController();
      const sent =
        command === 'cancel' ? controller.cancelRun(RUN_ID) : controller.subscribe(RUN_ID, 0);
      const requestId = sent.ok ? sent.requestId : '';
      const otherRunId = `run_${'B'.repeat(21)}Q`;

      if (command === 'cancel') {
        socket.emitMessage(
          serverEnvelope('run.cancel_requested', requestId, {
            run_id: otherRunId,
            status: 'cancel_requested',
          }),
        );
      } else {
        socket.emitMessage(
          serverEnvelope('run.snapshot', requestId, {
            mode: 'replay',
            reset: false,
            run_id: otherRunId,
            first_available_seq: 1,
            last_seq: 0,
            projection: null,
            terminal: null,
          }),
        );
      }

      expect(controller.lifecycle).toBe('protocol_fault');
    },
  );

  it('retains delayed start correlation and accepts a late response', () => {
    const delayed = vi.fn();
    const { controller, socket } = readyController({ onCommandDelayed: delayed });
    const sent = controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    const requestId = sent.ok ? sent.requestId : '';

    vi.advanceTimersByTime(8_000);
    expect(delayed).toHaveBeenCalledWith(expect.objectContaining({ kind: 'start', delayed: true }));
    expect(controller.pendingCount).toBe(1);
    expect(controller.startAmbiguous).toBe(true);

    socket.emitMessage(
      serverEnvelope('run.accepted', requestId, { run_id: RUN_ID, status: 'starting' }),
    );
    expect(controller.pendingCount).toBe(0);
    expect(controller.startAmbiguous).toBe(false);
  });

  it('blocks duplicate cancellation until the direct response settles', () => {
    const { controller, socket } = readyController();
    const first = controller.cancelRun(RUN_ID);
    expect(first.ok).toBe(true);
    expect(controller.pendingCancel).toBe(true);
    expect(controller.canCancel).toBe(false);
    expect(controller.cancelRun(RUN_ID)).toMatchObject({
      ok: false,
      error: { code: 'cancel_pending' },
    });

    const requestId = first.ok ? first.requestId : '';
    socket.emitMessage(
      serverEnvelope('run.cancel_requested', requestId, {
        run_id: RUN_ID,
        status: 'cancel_requested',
      }),
    );
    expect(controller.pendingCancel).toBe(false);
    expect(controller.canCancel).toBe(true);
  });

  it('never resends an ambiguously admitted start after reconnect', () => {
    const first = readyController();
    const sent = first.controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    expect(sent.ok).toBe(true);
    first.socket.emitClose(1_006);

    expect(first.controller.lifecycle).toBe('reconnecting');
    expect(first.controller.startAmbiguous).toBe(true);
    vi.advanceTimersByTime(250);
    const replacement = first.factory.sockets[1];
    replacement.emitOpen();
    replacement.emitMessage(hello);

    expect(first.controller.lifecycle).toBe('ready');
    expect(replacement.sent.map((frame) => JSON.parse(frame).type)).not.toContain('run.start');
    expect(first.controller.startRun({ prompt: 'Again', cwd: '/tmp/project' })).toMatchObject({
      ok: false,
      error: { code: 'ambiguous_start' },
    });
  });

  it('retains start ambiguity when accepted-run application fails', () => {
    const { controller, socket } = readyController({
      onMessage(message) {
        if (message.type === 'run.accepted') throw new Error('sanitized projection failure');
      },
    });
    const sent = controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    const requestId = sent.ok ? sent.requestId : '';
    socket.emitMessage(
      serverEnvelope('run.accepted', requestId, { run_id: RUN_ID, status: 'starting' }),
    );

    expect(controller.lifecycle).toBe('unavailable');
    expect(controller.startAmbiguous).toBe(true);
  });

  it('reactively invalidates command controls when pending state changes', async () => {
    const { controller, socket } = readyController();
    render(ConnectionStateHarness, { controller });
    expect(screen.getByTestId('can-start')).toHaveTextContent('enabled');

    const sent = controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    await tick();
    expect(screen.getByTestId('can-start')).toHaveTextContent('disabled');
    expect(screen.getByTestId('pending-count')).toHaveTextContent('1');

    const requestId = sent.ok ? sent.requestId : '';
    socket.emitMessage(
      serverEnvelope('run.accepted', requestId, { run_id: RUN_ID, status: 'starting' }),
    );
    await tick();
    expect(screen.getByTestId('can-start')).toHaveTextContent('enabled');
    expect(screen.getByTestId('pending-count')).toHaveTextContent('0');
  });

  it('uses bounded reconnect delays and stops after ten failed attempts', () => {
    const { controller, factory, socket } = readyController();
    socket.emitClose(1_006);
    const delays = [250, 500, 1_000, 2_000, 5_000, 5_000, 5_000, 5_000, 5_000, 5_000];

    for (const delay of delays) {
      vi.advanceTimersByTime(delay);
      const reconnecting = factory.sockets.at(-1)!;
      reconnecting.emitClose(1_006);
    }

    expect(factory.sockets).toHaveLength(11);
    expect(controller.lifecycle).toBe('unavailable');
    expect(controller.notice?.code).toBe('reconnect_exhausted');
    expect(controller.reconnectAttempts).toBe(10);
  });

  it('resets the outage attempt count only after validated hello', () => {
    const { controller, factory, socket } = readyController();
    socket.emitClose(1_006);
    expect(controller.reconnectAttempts).toBe(1);
    vi.advanceTimersByTime(250);
    const replacement = factory.sockets[1];
    replacement.emitOpen();
    expect(controller.reconnectAttempts).toBe(1);
    replacement.emitMessage(hello);
    expect(controller.reconnectAttempts).toBe(0);
  });

  it('pauses automatic reconnect while hidden and resumes once visible', () => {
    const { controller, factory, socket } = readyController();
    controller.setVisible(false);
    socket.emitClose(1_006);
    expect(controller.reconnectAttempts).toBe(0);
    vi.advanceTimersByTime(120_000);
    expect(factory.sockets).toHaveLength(1);

    controller.setVisible(true);
    expect(controller.reconnectAttempts).toBe(1);
    vi.advanceTimersByTime(250);
    expect(factory.sockets).toHaveLength(2);
  });

  it('does not schedule a second reconnect when a hidden attempt socket already exists', () => {
    const { controller, factory, socket } = readyController();
    socket.emitClose(1_006);
    vi.advanceTimersByTime(250);
    expect(factory.sockets).toHaveLength(2);

    controller.setVisible(false);
    controller.setVisible(true);
    vi.advanceTimersByTime(5_000);
    expect(factory.sockets).toHaveLength(2);

    const replacement = factory.sockets[1];
    replacement.emitOpen();
    replacement.emitMessage(hello);
    expect(controller.lifecycle).toBe('ready');
  });

  it('closes and retries a socket that never reaches hello readiness', () => {
    const { controller, factory } = setup();
    controller.connect();
    const first = factory.sockets[0];
    first.emitOpen();
    vi.advanceTimersByTime(10_000);

    expect(first.closes).toEqual([4_001]);
    expect(controller.lifecycle).toBe('reconnecting');
    expect(controller.notice?.code).toBe('readiness_timeout');
    expect(first.listenerCount('message')).toBe(0);
    vi.advanceTimersByTime(250);
    expect(factory.sockets).toHaveLength(2);
  });

  it.each([
    [1_003, 'protocol_fault'],
    [1_002, 'protocol_fault'],
    [1_007, 'protocol_fault'],
    [1_008, 'protocol_fault'],
    [1_009, 'protocol_fault'],
    [1_011, 'unavailable'],
    [1_000, 'unavailable'],
  ] as const)('does not automatically reconnect after close %i', (code, lifecycle) => {
    const { controller, factory, socket } = readyController();
    socket.emitClose(code);
    expect(controller.lifecycle).toBe(lifecycle);
    vi.advanceTimersByTime(60_000);
    expect(factory.sockets).toHaveLength(1);
  });

  it('sends one correlated ping at a time and pauses while hidden', () => {
    const { controller, socket } = readyController();
    controller.setVisible(false);
    vi.advanceTimersByTime(60_000);
    expect(socket.sent).toEqual([]);

    controller.setVisible(true);
    vi.advanceTimersByTime(0);
    expect(socket.sent).toHaveLength(1);
    const firstPing = JSON.parse(socket.sent[0]);
    expect(firstPing).toMatchObject({ type: 'ping', payload: {} });

    vi.advanceTimersByTime(25_000);
    expect(socket.sent).toHaveLength(1);
    socket.emitMessage(serverEnvelope('pong', firstPing.request_id, {}));
    expect(controller.pendingCount).toBe(0);
    vi.advanceTimersByTime(25_000);
    expect(socket.sent).toHaveLength(2);
  });

  it('serializes rapid pongs, command responses, events, and stale reconnect callbacks', () => {
    const onMessage = vi.fn();
    const { controller, factory, socket } = readyController({ onMessage });
    const staleMessages = socket.captureListeners('message');
    for (let index = 0; index < 16; index += 1) {
      vi.advanceTimersByTime(index === 0 ? 25_000 : 25_000);
      const ping = JSON.parse(socket.sent.at(-1) ?? '{}');
      socket.emitMessage(serverEnvelope('pong', ping.request_id, {}));
      socket.emitMessage(
        serverEnvelope('run.event', null, {
          run_id: RUN_ID,
          seq: index + 1,
          event: { type: 'run.owner_lost' },
        }),
      );
    }
    expect(controller.pendingCount).toBe(0);
    expect(onMessage).toHaveBeenCalledTimes(32);

    for (let index = 0; index < 8; index += 1) {
      expect(controller.cancelRun(RUN_ID).ok).toBe(true);
      const cancel = JSON.parse(socket.sent.at(-1) ?? '{}');
      socket.emitMessage(
        serverEnvelope('run.cancel_requested', cancel.request_id, {
          run_id: RUN_ID,
          status: 'cancel_requested',
        }),
      );
      expect(controller.subscribe(RUN_ID, 0).ok).toBe(true);
      const subscribe = JSON.parse(socket.sent.at(-1) ?? '{}');
      socket.emitMessage(
        serverEnvelope('run.snapshot', subscribe.request_id, {
          mode: 'replay',
          reset: false,
          run_id: RUN_ID,
          first_available_seq: 1,
          last_seq: 0,
          projection: null,
          terminal: null,
        }),
      );
    }
    expect(controller.pendingCount).toBe(0);
    expect(onMessage).toHaveBeenCalledTimes(48);

    socket.emitClose(1_012);
    vi.advanceTimersByTime(250);
    const replacement = factory.sockets[1];
    replacement.emitOpen();
    replacement.emitMessage(hello);
    for (const listener of staleMessages) listener({ data: hello });

    expect(controller.lifecycle).toBe('ready');
    expect(factory.sockets).toHaveLength(2);
    expect(onMessage).toHaveBeenCalledTimes(48);
  });

  it('manual disconnect and destruction clear resources without sending cancellation', () => {
    const { controller, factory, socket } = readyController();
    controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' });
    controller.disconnect();

    expect(controller.lifecycle).toBe('manually_disconnected');
    expect(socket.closes).toEqual([1_000]);
    expect(socket.sent.map((frame) => JSON.parse(frame).type)).not.toContain('run.cancel');
    expect(socket.listenerCount('open')).toBe(0);
    expect(socket.listenerCount('message')).toBe(0);
    expect(socket.listenerCount('close')).toBe(0);
    vi.advanceTimersByTime(60_000);
    expect(factory.sockets).toHaveLength(1);

    controller.destroy();
    controller.destroy();
    expect(socket.sent.map((frame) => JSON.parse(frame).type)).not.toContain('run.cancel');
  });

  it('classifies send failure as ambiguous transport loss without exposing exceptions', () => {
    const { controller, socket } = readyController();
    socket.throwOnSend = true;

    expect(controller.startRun({ prompt: 'Inspect', cwd: '/tmp/project' })).toMatchObject({
      ok: false,
      error: { code: 'not_ready' },
    });
    expect(controller.lifecycle).toBe('reconnecting');
    expect(controller.startAmbiguous).toBe(true);
    expect(JSON.stringify(controller.notice)).not.toContain('sanitized fake');
  });

  it('reports a cancel removed by send failure so run state requires an authoritative snapshot', () => {
    const ended = vi.fn();
    const { controller, socket } = readyController({ onGenerationEnd: ended });
    socket.throwOnSend = true;

    expect(controller.cancelRun(RUN_ID)).toMatchObject({
      ok: false,
      error: { code: 'not_ready' },
    });
    expect(ended).toHaveBeenCalledWith(
      1,
      expect.arrayContaining([expect.objectContaining({ kind: 'cancel', runId: RUN_ID })]),
    );
  });

  it('guards browser storage access and owns pagehide cleanup', () => {
    const descriptor = Object.getOwnPropertyDescriptor(window, 'sessionStorage');
    Object.defineProperty(window, 'sessionStorage', {
      configurable: true,
      get() {
        throw new Error('sanitized property access failure');
      },
    });

    try {
      const controller = createBrowserConnectionController();
      expect(controller.apiUrl).toBe('ws://127.0.0.1:4848/v1/socket');
      window.dispatchEvent(new Event('pagehide'));
      expect(controller.lifecycle).toBe('manually_disconnected');
      expect(controller.connect()).toMatchObject({ ok: false, error: { code: 'not_ready' } });
      expect(JSON.stringify(controller.notice)).not.toContain('sanitized');
    } finally {
      if (descriptor) {
        Object.defineProperty(window, 'sessionStorage', descriptor);
      } else {
        delete (window as unknown as { sessionStorage?: Storage }).sessionStorage;
      }
    }
  });

  it('keeps the browser controller reusable across persisted page transitions', () => {
    const controller = createBrowserConnectionController();
    const pageHide = new Event('pagehide');
    Object.defineProperty(pageHide, 'persisted', { value: true });
    window.dispatchEvent(pageHide);

    expect(controller.lifecycle).toBe('manually_disconnected');
    expect(controller.connect()).toEqual({ ok: true });
    controller.destroy();
  });
});

function setup(callbacks: ConnectionCallbacks = {}, storage = new MemorySessionStorage()) {
  const factory = new FakeSocketFactory();
  let request = 0;
  const dependencies: ConnectionDependencies = {
    createSocket: factory.create,
    setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
    clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
    now: () => Date.now(),
    randomUUID: () => `request-${++request}`,
    storage,
  };
  const ready = vi.fn(callbacks.onReady);
  const controller = createConnectionController(dependencies, { ...callbacks, onReady: ready });
  return { controller, factory, ready, storage };
}

function readyController(callbacks: ConnectionCallbacks = {}) {
  const context = setup(callbacks);
  context.controller.connect();
  const socket = context.factory.sockets[0] as FakeSocket;
  socket.emitOpen();
  socket.emitMessage(hello);
  return { ...context, socket };
}
