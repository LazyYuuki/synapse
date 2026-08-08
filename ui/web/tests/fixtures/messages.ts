export const RUN_ID = 'run_AAAAAAAAAAAAAAAAAAAAAA';
export const REQUEST_ID = 'request-1';

const envelope = (type: string, requestId: string | null, payload: object) =>
  JSON.stringify({ version: 1, type, request_id: requestId, payload });

export const projection = {
  status: 'running',
  model: 'model-a',
  turn: 1,
  text: 'Hello',
  active_tool: null,
  provider_attempts: 1,
  tool_calls: 0,
  output_bytes: 5,
};

export const successfulTerminal = {
  run_id: RUN_ID,
  seq: 8,
  status: 'completed',
  result: {
    text: 'Complete',
    turns: 1,
    tool_calls: 1,
    provider_retries: 0,
    output_bytes: 8,
  },
  error: null,
};

export const agentTerminal = {
  run_id: RUN_ID,
  seq: 8,
  status: 'failed',
  result: null,
  error: {
    source: 'agent',
    kind: 'provider',
    reason: 'provider_failed',
    message: 'Provider request failed',
    turn: 1,
    operation_id: 'provider-op-1',
    details: { attempts: 1, retryable: false },
  },
};

export const runtimeTerminal = {
  run_id: RUN_ID,
  seq: 8,
  status: 'interrupted',
  result: null,
  error: {
    source: 'runtime',
    reason: 'runtime_lost',
    message: 'Runtime coordinator was lost',
  },
};

export const apiTerminal = {
  run_id: RUN_ID,
  seq: 8,
  status: 'interrupted',
  result: null,
  error: {
    source: 'api',
    reason: 'internal_contract_failed',
    message: 'Run settlement contract failed',
  },
};

export const serverMessageFixtures: [string, string][] = [
  [
    'server.hello',
    envelope('server.hello', null, {
      protocol: 1,
      replay: 'memory',
      max_active_runs: 1,
      cwd: '/synthetic/server-launch',
      max_output_bytes: 524_288,
    }),
  ],
  [
    'server.error',
    envelope('server.error', REQUEST_ID, {
      code: 'run_busy',
      message: 'A run is already active',
      retryable: true,
    }),
  ],
  ['run.accepted', envelope('run.accepted', REQUEST_ID, { run_id: RUN_ID, status: 'starting' })],
  [
    'run.cancel_requested',
    envelope('run.cancel_requested', REQUEST_ID, {
      run_id: RUN_ID,
      status: 'cancel_requested',
    }),
  ],
  [
    'run.snapshot replay',
    envelope('run.snapshot', REQUEST_ID, {
      mode: 'replay',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 0,
      projection: null,
      terminal: null,
    }),
  ],
  [
    'run.snapshot state',
    envelope('run.snapshot', REQUEST_ID, {
      mode: 'snapshot',
      reset: false,
      run_id: RUN_ID,
      first_available_seq: 1,
      last_seq: 5,
      projection,
      terminal: null,
    }),
  ],
  [
    'run.event',
    envelope('run.event', null, {
      run_id: RUN_ID,
      seq: 1,
      event: { type: 'run.started', model: 'model-a' },
    }),
  ],
  ['run.terminal', envelope('run.terminal', null, successfulTerminal)],
  ['pong', envelope('pong', REQUEST_ID, {})],
];

export const eventFixtures: [string, object][] = [
  ['run.started', { type: 'run.started', model: 'model-a' }],
  ['turn.started', { type: 'turn.started', turn: 1, operation_id: 'provider-op-1' }],
  [
    'text.delta',
    {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-op-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'Hello ',
    },
  ],
  [
    'tool.started',
    {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-op-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    },
  ],
  [
    'tool.completed',
    {
      type: 'tool.completed',
      turn: 1,
      operation_id: 'tool-op-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
      status: 'ok',
      metadata: { tool: 'read', outcome: 'completed' },
    },
  ],
  [
    'turn.completed',
    {
      type: 'turn.completed',
      turn: 1,
      outcome: 'continued',
      provider_attempts: 1,
      tool_calls: 1,
      output_bytes: 6,
    },
  ],
  ['run.owner_lost', { type: 'run.owner_lost' }],
];

export const terminalFixtures: [string, object][] = [
  ['successful terminal', successfulTerminal],
  ['Agent terminal', agentTerminal],
  ['Runtime terminal', runtimeTerminal],
  ['API terminal', apiTerminal],
];

export const errorFixtures: [string, string | null, object][] = [
  [
    'invalid_json',
    null,
    { code: 'invalid_json', message: 'Message is not valid JSON', retryable: false },
  ],
  [
    'invalid_envelope',
    null,
    { code: 'invalid_envelope', message: 'Command envelope is invalid', retryable: false },
  ],
  [
    'unsupported_version',
    REQUEST_ID,
    {
      code: 'unsupported_version',
      message: 'Protocol version is not supported',
      retryable: false,
    },
  ],
  [
    'unknown_type',
    REQUEST_ID,
    { code: 'unknown_type', message: 'Command type is not supported', retryable: false },
  ],
  [
    'invalid_request_id',
    null,
    { code: 'invalid_request_id', message: 'Request ID is invalid', retryable: false },
  ],
  [
    'invalid_payload',
    REQUEST_ID,
    { code: 'invalid_payload', message: 'Command payload is invalid', retryable: false },
  ],
  [
    'run_busy',
    REQUEST_ID,
    { code: 'run_busy', message: 'A run is already active', retryable: true },
  ],
  [
    'run_not_found',
    REQUEST_ID,
    { code: 'run_not_found', message: 'Run was not found', retryable: false },
  ],
  [
    'invalid_cursor',
    REQUEST_ID,
    { code: 'invalid_cursor', message: 'Run cursor is invalid', retryable: false },
  ],
  [
    'subscription_limit',
    REQUEST_ID,
    {
      code: 'subscription_limit',
      message: 'Connection subscription limit reached',
      retryable: false,
    },
  ],
  [
    'runtime_unavailable',
    REQUEST_ID,
    { code: 'runtime_unavailable', message: 'Runtime is unavailable', retryable: true },
  ],
  [
    'internal_error',
    null,
    { code: 'internal_error', message: 'Internal API failure', retryable: false },
  ],
];

export const serverEnvelope = envelope;
