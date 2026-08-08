import { describe, expect, it } from 'vitest';

import { LIMITS } from '../../src/lib/protocol/constants';
import { decodeInitialServerMessage, decodeServerMessage } from '../../src/lib/protocol/decode';
import {
  agentTerminal,
  apiTerminal,
  errorFixtures,
  eventFixtures,
  projection,
  REQUEST_ID,
  RUN_ID,
  runtimeTerminal,
  serverEnvelope,
  serverMessageFixtures,
  successfulTerminal,
  terminalFixtures,
} from '../fixtures/messages';

describe('protocol server-message decoding', () => {
  it.each(serverMessageFixtures)('decodes %s', (_name, message) => {
    const result = decodeServerMessage(message);
    expect(result).toEqual({ ok: true, message: JSON.parse(message) });
  });

  it('requires a validated hello as the initial server message', () => {
    const hello = serverMessageFixtures.find(([name]) => name === 'server.hello')?.[1];
    const pong = serverEnvelope('pong', REQUEST_ID, {});

    expect(hello).toBeDefined();
    expect(decodeInitialServerMessage(hello).ok).toBe(true);
    expect(decodeInitialServerMessage(pong)).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it('requires one exact bounded absolute hello Workspace path', () => {
    const hello = (cwd: unknown, extra: Record<string, unknown> = {}) =>
      serverEnvelope('server.hello', null, {
        protocol: 1,
        replay: 'memory',
        max_active_runs: 1,
        cwd,
        max_output_bytes: 524_288,
        ...extra,
      });
    const maximum = `/${'c'.repeat(LIMITS.workspacePathBytes - 1)}`;

    expect(decodeInitialServerMessage(hello(maximum))).toMatchObject({ ok: true });

    for (const cwd of ['', '   ', 'relative', '/bad\0path', '/bad\ud800', `${maximum}c`, 42]) {
      expect(decodeInitialServerMessage(hello(cwd))).toMatchObject({ ok: false });
    }

    expect(decodeInitialServerMessage(hello('/valid', { extra: true }))).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it.each([1, 524_288])('accepts advertised output policy %s', (maxOutputBytes) => {
    const hello = serverEnvelope('server.hello', null, {
      protocol: 1,
      replay: 'memory',
      max_active_runs: 1,
      cwd: '/valid',
      max_output_bytes: maxOutputBytes,
    });
    expect(decodeInitialServerMessage(hello)).toMatchObject({ ok: true });
  });

  it.each([0, 524_289, 1.5])('rejects advertised output policy %s', (maxOutputBytes) => {
    const hello = serverEnvelope('server.hello', null, {
      protocol: 1,
      replay: 'memory',
      max_active_runs: 1,
      cwd: '/valid',
      max_output_bytes: maxOutputBytes,
    });
    expect(decodeInitialServerMessage(hello)).toMatchObject({ ok: false });
  });

  it('enforces the current hello output ceiling on terminal and snapshot content', () => {
    const atLimit = 'x'.repeat(64_000);
    const overLimit = `${atLimit}x`;
    const terminalWith = (text: string) =>
      serverEnvelope('run.terminal', null, {
        ...successfulTerminal,
        result: { ...successfulTerminal.result, text, output_bytes: text.length },
      });
    const snapshotWith = (text: string) =>
      serverEnvelope('run.snapshot', REQUEST_ID, {
        mode: 'snapshot',
        reset: false,
        run_id: RUN_ID,
        first_available_seq: 1,
        last_seq: 8,
        projection: {
          ...projection,
          status: 'completed',
          text: '',
          tool_calls: 1,
          output_bytes: text.length,
        },
        terminal: {
          ...successfulTerminal,
          result: { ...successfulTerminal.result, text, output_bytes: text.length },
        },
      });

    expect(decodeServerMessage(terminalWith(atLimit), 64_000).ok).toBe(true);
    expect(decodeServerMessage(terminalWith(overLimit), 64_000).ok).toBe(false);
    expect(decodeServerMessage(snapshotWith(atLimit), 64_000).ok).toBe(true);
    expect(decodeServerMessage(snapshotWith(overLimit), 64_000).ok).toBe(false);
  });

  it.each(eventFixtures)('decodes the %s event variant', (_name, event) => {
    const message = serverEnvelope('run.event', null, { run_id: RUN_ID, seq: 1, event });
    expect(decodeServerMessage(message)).toEqual({ ok: true, message: JSON.parse(message) });
  });

  it.each(terminalFixtures)('decodes the %s', (_name, terminal) => {
    const message = serverEnvelope('run.terminal', null, terminal);
    expect(decodeServerMessage(message)).toEqual({ ok: true, message: JSON.parse(message) });
  });

  it.each(errorFixtures)('decodes fixed %s server errors', (_name, requestId, payload) => {
    const message = serverEnvelope('server.error', requestId, payload);
    expect(decodeServerMessage(message)).toEqual({ ok: true, message: JSON.parse(message) });
  });

  it('decodes an authoritative reset and a completed snapshot', () => {
    const reset = serverEnvelope('run.snapshot', null, {
      mode: 'snapshot',
      reset: true,
      run_id: RUN_ID,
      first_available_seq: 5,
      last_seq: 8,
      projection: {
        status: 'completed',
        model: 'model-a',
        turn: 1,
        text: '',
        active_tool: null,
        provider_attempts: 1,
        tool_calls: 1,
        output_bytes: 8,
      },
      terminal: successfulTerminal,
    });

    expect(decodeServerMessage(reset)).toEqual({ ok: true, message: JSON.parse(reset) });
  });

  it.each([new Uint8Array([1]), new ArrayBuffer(1), new Blob(['{}']), {}])(
    'rejects non-text browser frame data',
    (frame) => {
      expect(decodeServerMessage(frame)).toEqual({
        ok: false,
        error: { code: 'invalid_frame_type', message: 'Server frame must be a text message.' },
      });
    },
  );

  it('rejects oversized input before JSON parsing', () => {
    expect(decodeServerMessage('x'.repeat(LIMITS.serverMessageBytes + 1))).toMatchObject({
      ok: false,
      error: { code: 'message_too_large' },
    });
  });

  it('accepts an exact maximum-size text frame and rejects one additional byte', () => {
    const hello = serverMessageFixtures.find(([name]) => name === 'server.hello')?.[1];
    expect(hello).toBeDefined();
    const atLimit = `${hello}${' '.repeat(LIMITS.serverMessageBytes - (hello?.length ?? 0))}`;
    expect(new TextEncoder().encode(atLimit).byteLength).toBe(LIMITS.serverMessageBytes);
    expect(decodeServerMessage(atLimit)).toMatchObject({ ok: true });
    expect(decodeServerMessage(`${atLimit} `)).toMatchObject({
      ok: false,
      error: { code: 'message_too_large' },
    });
  });

  it('enforces exact operation, call, item, and Tool identifier byte limits', () => {
    const textFrame = (operationBytes: number, itemBytes: number) =>
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 1,
        event: {
          type: 'text.delta',
          turn: 1,
          operation_id: 'o'.repeat(operationBytes),
          item_id: 'i'.repeat(itemBytes),
          content_index: 0,
          delta: '',
        },
      });
    const toolFrame = (callBytes: number, nameBytes: number) =>
      serverEnvelope('run.event', null, {
        run_id: RUN_ID,
        seq: 1,
        event: {
          type: 'tool.started',
          turn: 1,
          operation_id: 'o',
          call_id: 'c'.repeat(callBytes),
          name: 't'.repeat(nameBytes),
          ordinal: 1,
        },
      });

    expect(
      decodeServerMessage(textFrame(LIMITS.operationIdBytes, LIMITS.itemIdBytes)),
    ).toMatchObject({
      ok: true,
    });
    expect(decodeServerMessage(toolFrame(LIMITS.callIdBytes, LIMITS.toolNameBytes))).toMatchObject({
      ok: true,
    });
    for (const frame of [
      textFrame(LIMITS.operationIdBytes + 1, LIMITS.itemIdBytes),
      textFrame(LIMITS.operationIdBytes, LIMITS.itemIdBytes + 1),
      toolFrame(LIMITS.callIdBytes + 1, LIMITS.toolNameBytes),
      toolFrame(LIMITS.callIdBytes, LIMITS.toolNameBytes + 1),
    ]) {
      expect(decodeServerMessage(frame)).toMatchObject({
        ok: false,
        error: { code: 'invalid_message' },
      });
    }
  });

  it.each([
    '{',
    '\ud800',
    '{"version":1,"version":1,"type":"pong","request_id":"request-1","payload":{}}',
    '{"version":1,"type":"pong","request_id":"request-1","payload":{"value":"\\ud800"}}',
  ])('rejects malformed, duplicate-key, and malformed-Unicode JSON', (message) => {
    expect(decodeServerMessage(message)).toMatchObject({
      ok: false,
      error: { code: 'invalid_json' },
    });
  });

  it.each([
    { type: 'pong', request_id: REQUEST_ID, payload: {} },
    { version: 1, type: 'pong', request_id: REQUEST_ID, payload: {}, extra: true },
    { version: 2, type: 'pong', request_id: REQUEST_ID, payload: {} },
    { version: 1, type: 'unknown', request_id: REQUEST_ID, payload: {} },
    { version: 1, type: 'pong', request_id: null, payload: {} },
    { version: 1, type: 'pong', request_id: REQUEST_ID, payload: { extra: true } },
  ])('rejects missing, extra, unsupported, and uncorrelated envelopes', (message) => {
    expect(decodeServerMessage(JSON.stringify(message))).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it.each([
    '{"version":1.0,"type":"pong","request_id":"request-1","payload":{}}',
    `{"version":1,"type":"run.event","request_id":null,"payload":{"run_id":"${RUN_ID}","seq":1.0,"event":{"type":"run.owner_lost"}}}`,
    `{"version":1,"type":"run.event","request_id":null,"payload":{"run_id":"${RUN_ID}","seq":1e0,"event":{"type":"run.owner_lost"}}}`,
    `{"version":1,"type":"run.event","request_id":null,"payload":{"run_id":"${RUN_ID}","seq":9007199254740992,"event":{"type":"run.owner_lost"}}}`,
  ])('rejects non-integer lexical forms and unsafe integers', (message) => {
    expect(decodeServerMessage(message)).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it('accepts Number.MAX_SAFE_INTEGER without rounding', () => {
    const message = serverEnvelope('run.event', null, {
      run_id: RUN_ID,
      seq: Number.MAX_SAFE_INTEGER,
      event: { type: 'run.owner_lost' },
    });
    expect(decodeServerMessage(message)).toEqual({ ok: true, message: JSON.parse(message) });
  });

  it('matches Elixir whitespace semantics for server identifiers', () => {
    const accepted = serverEnvelope('run.event', null, {
      run_id: RUN_ID,
      seq: 1,
      event: { type: 'run.started', model: '\ufeff' },
    });
    const rejected = serverEnvelope('run.event', null, {
      run_id: RUN_ID,
      seq: 1,
      event: { type: 'run.started', model: '\u0085' },
    });

    expect(decodeServerMessage(accepted).ok).toBe(true);
    expect(decodeServerMessage(rejected)).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it.each([
    {
      mode: 'replay',
      reset: true,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 0,
      projection: null,
      terminal: null,
    },
    {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 3,
      projection: null,
      terminal: null,
    },
    {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 5,
      last_seq: 3,
      projection,
      terminal: null,
    },
  ])('rejects malformed snapshot modes and cursor windows', (payload) => {
    expect(decodeServerMessage(serverEnvelope('run.snapshot', REQUEST_ID, payload))).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it('rejects asynchronous non-reset snapshots and terminal/projection mismatches', () => {
    const asynchronous = serverEnvelope('run.snapshot', null, {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 0,
      projection: { ...projection, status: 'running' },
      terminal: null,
    });
    const mismatch = serverEnvelope('run.snapshot', REQUEST_ID, {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 9,
      projection: { ...projection, status: 'completed' },
      terminal: successfulTerminal,
    });

    expect(decodeServerMessage(asynchronous).ok).toBe(false);
    expect(decodeServerMessage(mismatch).ok).toBe(false);
  });

  it.each([
    { text: 'wrong' },
    { turn: 2 },
    { provider_attempts: 2 },
    { tool_calls: 2 },
    { output_bytes: 9 },
    {
      active_tool: {
        turn: 1,
        operation_id: 'tool-op-1',
        call_id: 'call-1',
        name: 'read',
        ordinal: 1,
      },
    },
  ])('rejects successful snapshot projection contradictions', (override) => {
    const message = serverEnvelope('run.snapshot', REQUEST_ID, {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 8,
      projection: {
        status: 'completed',
        model: 'model-a',
        turn: 1,
        text: '',
        active_tool: null,
        provider_attempts: 1,
        tool_calls: 1,
        output_bytes: 8,
        ...override,
      },
      terminal: successfulTerminal,
    });

    expect(decodeServerMessage(message)).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it('rejects backend-impossible active Tool projections', () => {
    const snapshotWith = (status: string, turn: number) =>
      serverEnvelope('run.snapshot', REQUEST_ID, {
        mode: 'snapshot',
        reset: false,
        run_id: RUN_ID,
        first_available_seq: 1,
        last_seq: 2,
        projection: {
          ...projection,
          status,
          active_tool: {
            turn,
            operation_id: 'tool-op-1',
            call_id: 'call-1',
            name: 'read',
            ordinal: 1,
          },
        },
        terminal: null,
      });

    expect(decodeServerMessage(snapshotWith('running', 2)).ok).toBe(false);
    expect(decodeServerMessage(snapshotWith('owner_lost', 1)).ok).toBe(false);
  });

  it.each([
    { ...projection, status: 'starting', model: 'model-a' },
    { ...projection, status: 'running', model: null },
    { ...projection, status: 'owner_lost', model: null, text: 'impossible' },
    { ...projection, status: 'cancel_requested', model: null, turn: 1, text: '' },
  ])('rejects backend-impossible pre-start projection state', (impossibleProjection) => {
    const message = serverEnvelope('run.snapshot', REQUEST_ID, {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 2,
      projection: impossibleProjection,
      terminal: null,
    });
    expect(decodeServerMessage(message).ok).toBe(false);
  });

  it.each([
    {
      lastSeq: 2,
      impossibleProjection: {
        status: 'starting',
        model: null,
        turn: 0,
        text: '',
        active_tool: null,
        provider_attempts: 0,
        tool_calls: 0,
        output_bytes: 0,
      },
    },
    { lastSeq: 0, impossibleProjection: projection },
    {
      lastSeq: 2,
      impossibleProjection: {
        status: 'cancel_requested',
        model: null,
        turn: 0,
        text: '',
        active_tool: null,
        provider_attempts: 0,
        tool_calls: 0,
        output_bytes: 0,
      },
    },
    { lastSeq: 1, impossibleProjection: { ...projection, status: 'owner_lost' } },
  ])(
    'rejects projection lifecycle that contradicts sequence $lastSeq',
    ({ lastSeq, impossibleProjection }) => {
      const message = serverEnvelope('run.snapshot', REQUEST_ID, {
        mode: 'snapshot',
        reset: false,
        run_id: RUN_ID,
        first_available_seq: 1,
        last_seq: lastSeq,
        projection: impossibleProjection,
        terminal: null,
      });
      expect(decodeServerMessage(message).ok).toBe(false);
    },
  );

  it('rejects extra event fields and mismatched public Tool metadata', () => {
    const extra = serverEnvelope('run.event', null, {
      run_id: RUN_ID,
      seq: 1,
      event: { type: 'run.owner_lost', reason: 'secret' },
    });
    const metadata = serverEnvelope('run.event', null, {
      run_id: RUN_ID,
      seq: 1,
      event: {
        type: 'tool.completed',
        turn: 1,
        operation_id: 'tool-op-1',
        call_id: 'call-1',
        name: 'read',
        ordinal: 1,
        status: 'ok',
        metadata: { tool: 'write' },
      },
    });

    expect(decodeServerMessage(extra).ok).toBe(false);
    expect(decodeServerMessage(metadata).ok).toBe(false);
  });

  it.each([
    { ...successfulTerminal, status: 'failed' },
    { ...successfulTerminal, error: apiTerminal.error },
    { ...runtimeTerminal, status: 'failed' },
    {
      ...apiTerminal,
      error: { ...apiTerminal.error, message: 'forged internal prose' },
    },
    {
      ...agentTerminal,
      error: { ...agentTerminal.error, kind: 'tool', reason: 'provider_failed' },
    },
    {
      ...agentTerminal,
      error: { ...agentTerminal.error, details: { forbidden: 'value' } },
    },
  ])('rejects malformed source-specific terminal variants', (terminal) => {
    expect(decodeServerMessage(serverEnvelope('run.terminal', null, terminal))).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it('accepts Agent details at collection depth four and rejects depth five', () => {
    const atLimit = {
      attempts: { observed: { maximum: { limit: { status: 'bounded' } } } },
    };
    const overLimit = {
      attempts: { observed: { maximum: { limit: { status: { outcome: 'too-deep' } } } } },
    };

    const terminalWith = (details: object) =>
      serverEnvelope('run.terminal', null, {
        ...agentTerminal,
        error: { ...agentTerminal.error, details },
      });

    expect(decodeServerMessage(terminalWith(atLimit)).ok).toBe(true);
    expect(decodeServerMessage(terminalWith(overLimit))).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it.each([
    '1.0',
    '1.0e-6',
    '1.2e20',
    '1.0e14',
    '1000000000000001.0',
    '1.0000000000000002e-4',
    '100.0',
    '0.0001',
    '4.218805887352958e17',
    '-1.3273133750155706e17',
    '1.0145514511648458e18',
    '-1.8578746697548867e18',
    '2.706692757932366e16',
  ])('accounts Agent-detail numeric lexemes at the byte boundary: %s', (numberToken) => {
    const fixedDetails = `{"status":${numberToken},"outcome":""}`;
    const atLimitDetails = `{"status":${numberToken},"outcome":"${'x'.repeat(
      LIMITS.agentDetailsBytes - new TextEncoder().encode(fixedDetails).byteLength,
    )}"}`;
    const overLimitDetails = atLimitDetails.replace(/"}$/, 'x"}');
    const terminalFrame = (details: string) =>
      serverEnvelope('run.terminal', null, {
        ...agentTerminal,
        error: { ...agentTerminal.error, details: null },
      }).replace('"details":null', `"details":${details}`);

    expect(new TextEncoder().encode(atLimitDetails).byteLength).toBe(LIMITS.agentDetailsBytes);
    expect(decodeServerMessage(terminalFrame(atLimitDetails)).ok).toBe(true);
    expect(decodeServerMessage(terminalFrame(overLimitDetails))).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it.each([
    '1e-6',
    '100000000000000.0',
    '1.000000000000001e15',
    '0.00010000000000000002',
    '421880588735295800.0',
    '-132731337501557060.0',
    '1014551451164845800.0',
    '-1857874669754886700.0',
    '27066927579323660.0',
  ])('rejects noncanonical Elixir float lexemes: %s', (numberToken) => {
    const fixedDetails = `{"status":${numberToken},"outcome":""}`;
    const details = `{"status":${numberToken},"outcome":"${'x'.repeat(
      LIMITS.agentDetailsBytes - new TextEncoder().encode(fixedDetails).byteLength,
    )}"}`;
    const frame = serverEnvelope('run.terminal', null, {
      ...agentTerminal,
      error: { ...agentTerminal.error, details: null },
    }).replace('"details":null', `"details":${details}`);

    expect(new TextEncoder().encode(details).byteLength).toBe(LIMITS.agentDetailsBytes);
    expect(decodeServerMessage(frame)).toMatchObject({
      ok: false,
      error: { code: 'invalid_message' },
    });
  });

  it('enforces JSON parser depth, object, array, and aggregate node limits', () => {
    const nestedArrays = (depth: number) => '['.repeat(depth) + ']'.repeat(depth);
    const objectWithKeys = (count: number) =>
      JSON.stringify(
        Object.fromEntries(Array.from({ length: count }, (_, index) => [`k${index}`, 0])),
      );
    const arrayWithItems = (count: number) =>
      JSON.stringify(Array.from({ length: count }, () => 0));
    const nodeDocument = (lastArrayLength: number) =>
      JSON.stringify(
        Object.fromEntries(
          Array.from({ length: 32 }, (_, index) => [
            `k${index}`,
            Array.from({ length: index === 31 ? lastArrayLength : 128 }, () => 0),
          ]),
        ),
      );

    for (const atLimit of [
      nestedArrays(16),
      objectWithKeys(32),
      arrayWithItems(128),
      nodeDocument(95),
    ]) {
      expect(decodeServerMessage(atLimit)).toMatchObject({
        ok: false,
        error: { code: 'invalid_message' },
      });
    }

    for (const overLimit of [
      nestedArrays(17),
      objectWithKeys(33),
      arrayWithItems(129),
      nodeDocument(96),
    ]) {
      expect(decodeServerMessage(overLimit)).toMatchObject({
        ok: false,
        error: { code: 'invalid_json' },
      });
    }
  });

  it('returns fixed decode failures without raw frame disclosure', () => {
    const sentinel = 'PRIVATE_RAW_FRAME_SENTINEL';
    const result = decodeServerMessage(`{"${sentinel}":`);

    expect(result).toEqual({
      ok: false,
      error: { code: 'invalid_json', message: 'Server message is not valid bounded JSON.' },
    });
    expect(JSON.stringify(result)).not.toContain(sentinel);
  });

  it('never throws for a fixed-seed JSON-compatible fuzz corpus', () => {
    let seed = 0x5eed1234;
    const random = () => {
      seed = (Math.imul(seed, 1_664_525) + 1_013_904_223) >>> 0;
      return seed / 0x1_0000_0000;
    };
    const value = (depth = 0): unknown => {
      const kind = depth >= 4 ? Math.floor(random() * 4) : Math.floor(random() * 7);
      if (kind === 0) return null;
      if (kind === 1) return random() > 0.5;
      if (kind === 2) return Math.floor(random() * 2_000_000) - 1_000_000;
      if (kind === 3) return `fuzz-${Math.floor(random() * 1_000_000)}`;
      if (kind === 4)
        return Array.from({ length: Math.floor(random() * 6) }, () => value(depth + 1));
      return Object.fromEntries(
        Array.from({ length: Math.floor(random() * 6) }, (_item, index) => [
          `k${index}`,
          value(depth + 1),
        ]),
      );
    };

    for (let index = 0; index < 2_000; index += 1) {
      const frame = JSON.stringify(value());
      expect(() => decodeServerMessage(frame)).not.toThrow();
    }
  });
});
