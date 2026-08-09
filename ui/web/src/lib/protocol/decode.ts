/** Strict protocol-v1 server-message decoding.
 * @see ../../../../../docs/plan/PLAN-API.md
 */

import {
  AGENT_DETAIL_KEYS,
  AGENT_REASONS,
  HARD_CLIENT_MAX_OUTPUT_BYTES,
  LIMITS,
  PROTOCOL_VERSION,
  RUNTIME_ERRORS,
  SERVER_ERROR_SPECS,
} from './constants';
import type {
  ActiveTool,
  AgentTerminalError,
  ApiTerminalError,
  JsonObject,
  JsonValue,
  PublicResult,
  RunEvent,
  RunProjection,
  RuntimeTerminalError,
  ServerErrorCode,
  ServerMessage,
  SnapshotPayload,
  Terminal,
  TerminalError,
  ToolPublicMetadata,
} from './types';
import {
  hasNonBlankContent,
  hasExactKeys,
  isBoundedString,
  isIdentifier,
  isOneOf,
  isPlainObject,
  isRunId,
  isWellFormedUnicode,
  utf8ByteLength,
} from './validation';

export type DecodeErrorCode =
  'invalid_frame_type' | 'message_too_large' | 'invalid_json' | 'invalid_message';

export type DecodeError = {
  code: DecodeErrorCode;
  message: string;
};

export type DecodeResult = { ok: true; message: ServerMessage } | { ok: false; error: DecodeError };

const decodeMessages = {
  invalid_frame_type: 'Server frame must be a text message.',
  message_too_large: 'Server message exceeds the client byte limit.',
  invalid_json: 'Server message is not valid bounded JSON.',
  invalid_message: 'Server message does not match protocol v1.',
} as const satisfies Record<DecodeErrorCode, string>;

const envelopeKeys = ['version', 'type', 'request_id', 'payload'] as const;
const terminalKeys = ['run_id', 'seq', 'status', 'result', 'error'] as const;
const projectionKeys = [
  'status',
  'model',
  'turn',
  'text',
  'active_tool',
  'provider_attempts',
  'tool_calls',
  'output_bytes',
] as const;
const activeToolKeys = ['turn', 'operation_id', 'call_id', 'name', 'ordinal'] as const;
const terminalStatuses = ['completed', 'failed', 'interrupted'] as const;
const runStatuses = [
  'starting',
  'running',
  'cancel_requested',
  'owner_lost',
  ...terminalStatuses,
] as const;
const nonTerminalStatuses = ['starting', 'running', 'cancel_requested', 'owner_lost'] as const;
const invalid = Symbol('invalid');

class ParsedNumber {
  constructor(
    readonly raw: string,
    readonly value: number,
  ) {}
}

type ParsedJson =
  null | boolean | string | ParsedNumber | ParsedJson[] | { [key: string]: ParsedJson };

export function decodeServerMessage(
  data: unknown,
  maxOutputBytes = HARD_CLIENT_MAX_OUTPUT_BYTES,
): DecodeResult {
  if (typeof data !== 'string') return failure('invalid_frame_type');
  if (!isWellFormedUnicode(data)) return failure('invalid_json');
  if (utf8ByteLength(data) > LIMITS.serverMessageBytes) return failure('message_too_large');

  let parsed: ParsedJson;
  try {
    parsed = parseJsonDocument(data);
  } catch {
    return failure('invalid_json');
  }

  const effectiveMaxOutputBytes = Math.min(maxOutputBytes, HARD_CLIENT_MAX_OUTPUT_BYTES);
  if (!Number.isInteger(effectiveMaxOutputBytes) || effectiveMaxOutputBytes < 1) {
    return failure('invalid_message');
  }

  const message = decodeEnvelope(parsed, effectiveMaxOutputBytes);
  return message === invalid ? failure('invalid_message') : { ok: true, message };
}

export function decodeInitialServerMessage(data: unknown): DecodeResult {
  const result = decodeServerMessage(data);
  if (!result.ok) return result;
  return result.message.type === 'server.hello' ? result : failure('invalid_message');
}

function decodeEnvelope(value: ParsedJson, maxOutputBytes: number): ServerMessage | typeof invalid {
  if (!hasExactKeys(value, envelopeKeys)) return invalid;
  if (readInteger(value.version, 1, 1) !== PROTOCOL_VERSION || typeof value.type !== 'string') {
    return invalid;
  }

  switch (value.type) {
    case 'server.hello':
      return decodeHello(value.request_id, value.payload);
    case 'server.error':
      return decodeServerError(value.request_id, value.payload);
    case 'run.accepted':
      return decodeRunAccepted(value.request_id, value.payload);
    case 'run.cancel_requested':
      return decodeCancelRequested(value.request_id, value.payload);
    case 'run.snapshot':
      return decodeSnapshot(value.request_id, value.payload, maxOutputBytes);
    case 'run.event':
      return decodeRunEvent(value.request_id, value.payload);
    case 'run.terminal':
      return decodeRunTerminal(value.request_id, value.payload, maxOutputBytes);
    case 'pong':
      return decodePong(value.request_id, value.payload);
    default:
      return invalid;
  }
}

function decodeHello(requestId: ParsedJson, payload: ParsedJson): ServerMessage | typeof invalid {
  if (
    requestId !== null ||
    !hasExactKeys(payload, ['protocol', 'replay', 'max_active_runs', 'cwd', 'max_output_bytes']) ||
    readInteger(payload.protocol, 1, 1) !== 1 ||
    payload.replay !== 'memory' ||
    readInteger(payload.max_active_runs, 1, 1) !== 1 ||
    !validWorkspacePath(payload.cwd) ||
    readInteger(payload.max_output_bytes, 1, HARD_CLIENT_MAX_OUTPUT_BYTES) === undefined
  ) {
    return invalid;
  }

  return {
    version: 1,
    type: 'server.hello',
    request_id: null,
    payload: {
      protocol: 1,
      replay: 'memory',
      max_active_runs: 1,
      cwd: payload.cwd,
      max_output_bytes: readInteger(payload.max_output_bytes, 1, HARD_CLIENT_MAX_OUTPUT_BYTES)!,
    },
  };
}

function validWorkspacePath(value: ParsedJson): value is string {
  return (
    typeof value === 'string' &&
    isBoundedString(value, LIMITS.workspacePathBytes) &&
    hasNonBlankContent(value) &&
    value.startsWith('/') &&
    !value.includes('\0')
  );
}

function decodeServerError(
  requestId: ParsedJson,
  payload: ParsedJson,
): ServerMessage | typeof invalid {
  if (
    !hasExactKeys(payload, ['code', 'message', 'retryable']) ||
    !isServerErrorCode(payload.code)
  ) {
    return invalid;
  }

  const spec = SERVER_ERROR_SPECS[payload.code];
  if (payload.message !== spec.message || payload.retryable !== spec.retryable) return invalid;
  if (!validErrorRequestId(requestId, spec.requestId)) return invalid;

  return {
    version: 1,
    type: 'server.error',
    request_id: requestId,
    payload: { code: payload.code, message: spec.message, retryable: spec.retryable },
  };
}

function decodeRunAccepted(
  requestId: ParsedJson,
  payload: ParsedJson,
): ServerMessage | typeof invalid {
  if (
    !isRequestId(requestId) ||
    !hasExactKeys(payload, ['run_id', 'status']) ||
    !isRunId(payload.run_id) ||
    payload.status !== 'starting'
  ) {
    return invalid;
  }

  return {
    version: 1,
    type: 'run.accepted',
    request_id: requestId,
    payload: { run_id: payload.run_id, status: 'starting' },
  };
}

function decodeCancelRequested(
  requestId: ParsedJson,
  payload: ParsedJson,
): ServerMessage | typeof invalid {
  if (
    !isRequestId(requestId) ||
    !hasExactKeys(payload, ['run_id', 'status']) ||
    !isRunId(payload.run_id) ||
    !isOneOf(payload.status, ['cancel_requested', 'already_terminal'] as const)
  ) {
    return invalid;
  }

  return {
    version: 1,
    type: 'run.cancel_requested',
    request_id: requestId,
    payload: { run_id: payload.run_id, status: payload.status },
  };
}

function decodePong(requestId: ParsedJson, payload: ParsedJson): ServerMessage | typeof invalid {
  if (!isRequestId(requestId) || !hasExactKeys(payload, [])) return invalid;
  return { version: 1, type: 'pong', request_id: requestId, payload: {} };
}

function decodeSnapshot(
  requestId: ParsedJson,
  payload: ParsedJson,
  maxOutputBytes: number,
): ServerMessage | typeof invalid {
  if (
    !hasExactKeys(payload, [
      'mode',
      'reset',
      'run_id',
      'first_available_seq',
      'last_seq',
      'projection',
      'terminal',
    ]) ||
    !isOneOf(payload.mode, ['snapshot', 'replay'] as const) ||
    typeof payload.reset !== 'boolean' ||
    !isRunId(payload.run_id)
  ) {
    return invalid;
  }

  const firstAvailableSeq = readPositiveInteger(payload.first_available_seq);
  const lastSeq = readNonNegativeInteger(payload.last_seq);
  if (
    firstAvailableSeq === undefined ||
    lastSeq === undefined ||
    !(firstAvailableSeq <= lastSeq || firstAvailableSeq === lastSeq + 1)
  ) {
    return invalid;
  }

  let snapshot: SnapshotPayload;
  if (payload.mode === 'replay') {
    if (
      requestId === null ||
      !isRequestId(requestId) ||
      payload.reset !== false ||
      payload.projection !== null ||
      payload.terminal !== null
    ) {
      return invalid;
    }

    snapshot = {
      mode: 'replay',
      reset: false,
      run_id: payload.run_id,
      first_available_seq: firstAvailableSeq,
      last_seq: lastSeq,
      projection: null,
      terminal: null,
    };
  } else {
    if (requestId === null && !payload.reset) return invalid;
    if (requestId !== null && !isRequestId(requestId)) return invalid;

    const projection = decodeProjection(payload.projection, maxOutputBytes);
    const terminal =
      payload.terminal === null ? null : decodeTerminal(payload.terminal, maxOutputBytes);
    if (projection === invalid || terminal === invalid) return invalid;
    if (!snapshotSequenceMatchesProjection(projection, lastSeq)) return invalid;

    if (terminal === null) {
      if (!isOneOf(projection.status, nonTerminalStatuses)) return invalid;
    } else if (
      terminal.run_id !== payload.run_id ||
      terminal.seq !== lastSeq ||
      terminal.status !== projection.status
    ) {
      return invalid;
    }
    if (!snapshotProjectionMatchesTerminal(projection, terminal)) return invalid;

    snapshot = {
      mode: 'snapshot',
      reset: payload.reset,
      run_id: payload.run_id,
      first_available_seq: firstAvailableSeq,
      last_seq: lastSeq,
      projection,
      terminal,
    };
  }

  return {
    version: 1,
    type: 'run.snapshot',
    request_id: requestId,
    payload: snapshot,
  };
}

function decodeProjection(
  value: ParsedJson,
  maxOutputBytes: number,
): RunProjection | typeof invalid {
  if (!hasExactKeys(value, projectionKeys) || !isOneOf(value.status, runStatuses)) return invalid;

  const model = value.model;
  if (model !== null && !isIdentifier(model, LIMITS.modelBytes)) return invalid;

  const turn = readNonNegativeInteger(value.turn);
  const providerAttempts = readNonNegativeInteger(value.provider_attempts);
  const toolCalls = readNonNegativeInteger(value.tool_calls);
  const outputBytes = readInteger(value.output_bytes, 0, maxOutputBytes);
  const activeTool = value.active_tool === null ? null : decodeActiveTool(value.active_tool);

  if (
    turn === undefined ||
    providerAttempts === undefined ||
    toolCalls === undefined ||
    outputBytes === undefined ||
    !isBoundedString(value.text, maxOutputBytes) ||
    activeTool === invalid
  ) {
    return invalid;
  }
  if (
    activeTool !== null &&
    (activeTool.turn !== turn || !isOneOf(value.status, ['running', 'cancel_requested']))
  ) {
    return invalid;
  }
  if (
    (value.status === 'starting' && model !== null) ||
    ((value.status === 'running' || value.status === 'completed') && model === null) ||
    (model === null &&
      (turn !== 0 ||
        value.text !== '' ||
        activeTool !== null ||
        providerAttempts !== 0 ||
        toolCalls !== 0 ||
        outputBytes !== 0))
  ) {
    return invalid;
  }

  return {
    status: value.status,
    model,
    turn,
    text: value.text,
    active_tool: activeTool,
    provider_attempts: providerAttempts,
    tool_calls: toolCalls,
    output_bytes: outputBytes,
  };
}

function decodeActiveTool(value: ParsedJson): ActiveTool | typeof invalid {
  if (!hasExactKeys(value, activeToolKeys)) return invalid;

  const turn = readPositiveInteger(value.turn);
  const ordinal = readPositiveInteger(value.ordinal);
  if (
    turn === undefined ||
    ordinal === undefined ||
    !isIdentifier(value.operation_id, LIMITS.operationIdBytes) ||
    !isIdentifier(value.call_id, LIMITS.callIdBytes) ||
    !isIdentifier(value.name, LIMITS.toolNameBytes)
  ) {
    return invalid;
  }

  return {
    turn,
    operation_id: value.operation_id,
    call_id: value.call_id,
    name: value.name,
    ordinal,
  };
}

function decodeRunEvent(
  requestId: ParsedJson,
  payload: ParsedJson,
): ServerMessage | typeof invalid {
  if (
    requestId !== null ||
    !hasExactKeys(payload, ['run_id', 'seq', 'event']) ||
    !isRunId(payload.run_id)
  ) {
    return invalid;
  }

  const seq = readPositiveInteger(payload.seq);
  const event = decodeEvent(payload.event);
  if (seq === undefined || event === invalid) return invalid;

  return {
    version: 1,
    type: 'run.event',
    request_id: null,
    payload: { run_id: payload.run_id, seq, event },
  };
}

function decodeEvent(value: ParsedJson): RunEvent | typeof invalid {
  if (!isPlainObject(value) || typeof value.type !== 'string') return invalid;

  switch (value.type) {
    case 'run.started':
      if (
        !hasExactKeys(value, ['type', 'model']) ||
        !isIdentifier(value.model, LIMITS.modelBytes)
      ) {
        return invalid;
      }
      return { type: 'run.started', model: value.model };

    case 'turn.started': {
      if (!hasExactKeys(value, ['type', 'turn', 'operation_id'])) return invalid;
      const turn = readPositiveInteger(value.turn);
      if (turn === undefined || !isIdentifier(value.operation_id, LIMITS.operationIdBytes)) {
        return invalid;
      }
      return { type: 'turn.started', turn, operation_id: value.operation_id };
    }

    case 'text.delta': {
      if (
        !hasExactKeys(value, ['type', 'turn', 'operation_id', 'item_id', 'content_index', 'delta'])
      ) {
        return invalid;
      }
      const turn = readPositiveInteger(value.turn);
      const contentIndex = readNonNegativeInteger(value.content_index);
      if (
        turn === undefined ||
        contentIndex === undefined ||
        !isIdentifier(value.operation_id, LIMITS.operationIdBytes) ||
        !isIdentifier(value.item_id, LIMITS.itemIdBytes) ||
        !isBoundedString(value.delta, LIMITS.eventDeltaBytes)
      ) {
        return invalid;
      }
      return {
        type: 'text.delta',
        turn,
        operation_id: value.operation_id,
        item_id: value.item_id,
        content_index: contentIndex,
        delta: value.delta,
      };
    }

    case 'tool.started':
      return decodeToolStarted(value);
    case 'tool.completed':
      return decodeToolCompleted(value);

    case 'turn.completed': {
      if (
        !hasExactKeys(value, [
          'type',
          'turn',
          'outcome',
          'provider_attempts',
          'tool_calls',
          'output_bytes',
        ]) ||
        !isOneOf(value.outcome, ['continued', 'completed', 'failed', 'interrupted'] as const)
      ) {
        return invalid;
      }
      const turn = readPositiveInteger(value.turn);
      const providerAttempts = readPositiveInteger(value.provider_attempts);
      const toolCalls = readNonNegativeInteger(value.tool_calls);
      const outputBytes = readNonNegativeInteger(value.output_bytes);
      if (
        turn === undefined ||
        providerAttempts === undefined ||
        toolCalls === undefined ||
        outputBytes === undefined
      ) {
        return invalid;
      }
      return {
        type: 'turn.completed',
        turn,
        outcome: value.outcome,
        provider_attempts: providerAttempts,
        tool_calls: toolCalls,
        output_bytes: outputBytes,
      };
    }

    case 'run.owner_lost':
      return hasExactKeys(value, ['type']) ? { type: 'run.owner_lost' } : invalid;
    default:
      return invalid;
  }
}

function decodeToolStarted(value: Record<string, unknown>): RunEvent | typeof invalid {
  if (!hasExactKeys(value, ['type', ...activeToolKeys, 'arguments'])) return invalid;
  const tool = decodeActiveToolFields(value);
  const arguments_ = decodeToolArguments(value.arguments);
  if (tool === invalid || arguments_ === invalid) return invalid;
  return { type: 'tool.started', ...tool, arguments: arguments_ };
}

function decodeToolCompleted(value: Record<string, unknown>): RunEvent | typeof invalid {
  if (!hasExactKeys(value, ['type', ...activeToolKeys, 'status', 'metadata', 'content'])) {
    return invalid;
  }
  const tool = decodeActiveToolFields(value);
  if (
    tool === invalid ||
    !isOneOf(value.status, ['ok', 'error', 'ambiguous'] as const) ||
    !isPlainObject(value.metadata) ||
    !isBoundedString(value.content, LIMITS.toolContentBytes)
  ) {
    return invalid;
  }

  const metadata = decodeToolMetadata(value.metadata, tool.name);
  if (metadata === invalid) return invalid;
  return {
    type: 'tool.completed',
    ...tool,
    status: value.status,
    metadata,
    content: value.content,
  };
}

function decodeToolArguments(value: unknown): JsonObject | typeof invalid {
  if (!isPlainObject(value) || encodedJsonBytes(value) > LIMITS.toolArgumentBytes) return invalid;
  const normalized = normalizeJsonValue(
    value,
    0,
    { entries: 0 },
    LIMITS.toolArgumentEntries,
    LIMITS.toolArgumentDepth,
  );
  return normalized === invalid || !isPlainObject(normalized)
    ? invalid
    : (normalized as JsonObject);
}

function decodeActiveToolFields(value: Record<string, unknown>): ActiveTool | typeof invalid {
  const turn = readPositiveInteger(value.turn);
  const ordinal = readPositiveInteger(value.ordinal);
  if (
    turn === undefined ||
    ordinal === undefined ||
    !isIdentifier(value.operation_id, LIMITS.operationIdBytes) ||
    !isIdentifier(value.call_id, LIMITS.callIdBytes) ||
    !isIdentifier(value.name, LIMITS.toolNameBytes)
  ) {
    return invalid;
  }
  return {
    turn,
    operation_id: value.operation_id,
    call_id: value.call_id,
    name: value.name,
    ordinal,
  };
}

function decodeToolMetadata(
  value: Record<string, unknown>,
  toolName: string,
): ToolPublicMetadata | typeof invalid {
  const keys = Object.keys(value);
  if (keys.length > 2 || keys.some((key) => key !== 'tool' && key !== 'outcome')) return invalid;

  const metadata: ToolPublicMetadata = {};
  if ('tool' in value) {
    if (value.tool !== toolName) return invalid;
    metadata.tool = toolName;
  }
  if ('outcome' in value) {
    if (!isOneOf(value.outcome, ['completed', 'not_applied', 'not_applicable', 'unknown'])) {
      return invalid;
    }
    metadata.outcome = value.outcome;
  }
  return metadata;
}

function decodeRunTerminal(
  requestId: ParsedJson,
  payload: ParsedJson,
  maxOutputBytes: number,
): ServerMessage | typeof invalid {
  if (requestId !== null) return invalid;
  const terminal = decodeTerminal(payload, maxOutputBytes);
  if (terminal === invalid) return invalid;
  return { version: 1, type: 'run.terminal', request_id: null, payload: terminal };
}

function decodeTerminal(value: ParsedJson, maxOutputBytes: number): Terminal | typeof invalid {
  if (!hasExactKeys(value, terminalKeys) || !isRunId(value.run_id)) return invalid;
  const seq = readPositiveInteger(value.seq);
  if (seq === undefined || !isOneOf(value.status, terminalStatuses)) return invalid;

  if (value.status === 'completed') {
    if (value.error !== null) return invalid;
    const result = decodeResult(value.result, maxOutputBytes);
    if (result === invalid) return invalid;
    return { run_id: value.run_id, seq, status: 'completed', result, error: null };
  }

  if (value.result !== null) return invalid;
  const failure = decodeTerminalError(value.error, value.status);
  if (failure === invalid) return invalid;

  if (failure.source === 'agent') {
    return { run_id: value.run_id, seq, status: value.status, result: null, error: failure };
  }
  if (failure.source === 'runtime') {
    if (failure.reason === 'runtime_lost') {
      return { run_id: value.run_id, seq, status: 'interrupted', result: null, error: failure };
    }
    return { run_id: value.run_id, seq, status: 'failed', result: null, error: failure };
  }
  return { run_id: value.run_id, seq, status: 'interrupted', result: null, error: failure };
}

function decodeResult(value: ParsedJson, maxOutputBytes: number): PublicResult | typeof invalid {
  if (!hasExactKeys(value, ['text', 'turns', 'tool_calls', 'provider_retries', 'output_bytes'])) {
    return invalid;
  }

  const turns = readInteger(value.turns, 1, 100);
  const toolCalls = readInteger(value.tool_calls, 0, 500);
  const providerRetries = readInteger(value.provider_retries, 0, 5);
  const outputBytes = readInteger(value.output_bytes, 0, maxOutputBytes);
  if (
    !isBoundedString(value.text, maxOutputBytes) ||
    !hasNonBlankContent(value.text) ||
    turns === undefined ||
    toolCalls === undefined ||
    providerRetries === undefined ||
    outputBytes === undefined ||
    outputBytes < utf8ByteLength(value.text)
  ) {
    return invalid;
  }

  return {
    text: value.text,
    turns,
    tool_calls: toolCalls,
    provider_retries: providerRetries,
    output_bytes: outputBytes,
  };
}

function decodeTerminalError(
  value: ParsedJson,
  status: 'failed' | 'interrupted',
): TerminalError | typeof invalid {
  if (!isPlainObject(value) || typeof value.source !== 'string') return invalid;

  switch (value.source) {
    case 'agent':
      return decodeAgentError(value);
    case 'runtime':
      return decodeRuntimeError(value, status);
    case 'api':
      return decodeApiError(value, status);
    default:
      return invalid;
  }
}

function decodeAgentError(value: Record<string, unknown>): AgentTerminalError | typeof invalid {
  if (
    !hasExactKeys(value, [
      'source',
      'kind',
      'reason',
      'message',
      'turn',
      'operation_id',
      'details',
    ]) ||
    typeof value.kind !== 'string' ||
    typeof value.reason !== 'string' ||
    !Object.hasOwn(AGENT_REASONS, value.kind)
  ) {
    return invalid;
  }

  const kind = value.kind as keyof typeof AGENT_REASONS;
  const reasons: readonly string[] = AGENT_REASONS[kind];
  if (!reasons.includes(value.reason)) return invalid;

  const turn = readInteger(value.turn, 0, Number.MAX_SAFE_INTEGER);
  const details = decodeAgentDetails(value.details);
  if (
    turn === undefined ||
    !isBoundedString(value.message, LIMITS.agentMessageBytes) ||
    !hasNonBlankContent(value.message) ||
    (value.operation_id !== null && !isIdentifier(value.operation_id, LIMITS.operationIdBytes)) ||
    details === invalid
  ) {
    return invalid;
  }

  const base = {
    source: 'agent' as const,
    message: value.message,
    turn,
    operation_id: value.operation_id,
    details,
  };

  switch (kind) {
    case 'internal':
      return { ...base, kind, reason: value.reason as AgentReason<'internal'> };
    case 'provider':
      return { ...base, kind, reason: value.reason as AgentReason<'provider'> };
    case 'protocol':
      return { ...base, kind, reason: value.reason as AgentReason<'protocol'> };
    case 'tool':
      return { ...base, kind, reason: value.reason as AgentReason<'tool'> };
    case 'context':
      return { ...base, kind, reason: value.reason as AgentReason<'context'> };
    case 'budget':
      return { ...base, kind, reason: value.reason as AgentReason<'budget'> };
    case 'cancelled':
      return { ...base, kind, reason: value.reason as AgentReason<'cancelled'> };
  }
}

type AgentReason<TKind extends keyof typeof AGENT_REASONS> = (typeof AGENT_REASONS)[TKind][number];

function decodeRuntimeError(
  value: Record<string, unknown>,
  status: 'failed' | 'interrupted',
): RuntimeTerminalError | typeof invalid {
  if (
    !hasExactKeys(value, ['source', 'reason', 'message']) ||
    typeof value.reason !== 'string' ||
    !Object.hasOwn(RUNTIME_ERRORS, value.reason)
  ) {
    return invalid;
  }

  const reason = value.reason as keyof typeof RUNTIME_ERRORS;
  const spec = RUNTIME_ERRORS[reason];
  if (value.message !== spec.message || status !== spec.status) return invalid;

  switch (reason) {
    case 'invalid_run_request':
      return { source: 'runtime', reason, message: 'Run Request is invalid' };
    case 'invalid_runtime_options':
      return { source: 'runtime', reason, message: 'Runtime options are invalid' };
    case 'runtime_unavailable':
      return { source: 'runtime', reason, message: 'Runtime infrastructure is unavailable' };
    case 'runtime_busy':
      return { source: 'runtime', reason, message: 'Runtime is busy' };
    case 'workspace_open_failed':
      return { source: 'runtime', reason, message: 'Workspace could not be opened' };
    case 'runtime_lost':
      return { source: 'runtime', reason, message: 'Runtime coordinator was lost' };
  }
}

function decodeApiError(
  value: Record<string, unknown>,
  status: 'failed' | 'interrupted',
): ApiTerminalError | typeof invalid {
  if (
    status !== 'interrupted' ||
    !hasExactKeys(value, ['source', 'reason', 'message']) ||
    value.reason !== 'internal_contract_failed' ||
    value.message !== 'Run settlement contract failed'
  ) {
    return invalid;
  }
  return {
    source: 'api',
    reason: 'internal_contract_failed',
    message: 'Run settlement contract failed',
  };
}

function decodeAgentDetails(value: unknown): JsonObject | typeof invalid {
  if (!isPlainObject(value)) return invalid;
  if (encodedJsonBytes(value) > LIMITS.agentDetailsBytes) return invalid;
  const counters = { entries: 0 };
  const normalized = normalizeJsonValue(
    value,
    0,
    counters,
    LIMITS.agentDetailsEntries,
    LIMITS.agentDetailsDepth,
    (key) => AGENT_DETAIL_KEYS.has(key),
  );
  if (normalized === invalid || !isPlainObject(normalized)) {
    return invalid;
  }
  return normalized as JsonObject;
}

function encodedJsonBytes(value: unknown): number {
  if (value === null) return 4;
  if (value === true) return 4;
  if (value === false) return 5;
  if (typeof value === 'string') return utf8ByteLength(JSON.stringify(value));
  if (value instanceof ParsedNumber) {
    if (/[.eE]/.test(value.raw) && value.raw !== encodeElixirFloat(value.value)) {
      return Number.POSITIVE_INFINITY;
    }
    return value.raw.length;
  }

  if (Array.isArray(value)) {
    let bytes = 2 + Math.max(value.length - 1, 0);
    for (const item of value) bytes += encodedJsonBytes(item);
    return bytes;
  }

  if (isPlainObject(value)) {
    const entries = Object.entries(value);
    let bytes = 2 + Math.max(entries.length - 1, 0);
    for (const [key, item] of entries) {
      bytes += utf8ByteLength(JSON.stringify(key)) + 1 + encodedJsonBytes(item);
    }
    return bytes;
  }

  return Number.POSITIVE_INFINITY;
}

function encodeElixirFloat(value: number): string {
  if (Object.is(value, -0)) return '-0.0';

  const [rawMantissa, rawExponent] = value.toExponential().split('e');
  const scientificExponent = Number(rawExponent);
  const sign = rawMantissa.startsWith('-') ? '-' : '';
  const unsignedMantissa = sign === '' ? rawMantissa : rawMantissa.slice(1);
  const digits = unsignedMantissa.replace('.', '');
  const digitCount = digits.length;
  const exponent = scientificExponent - digitCount + 1;

  const lowerBound = digitCount === 1 ? -4 : -(digitCount + 2);
  const upperBound = digitCount === 1 ? 2 : scientificExponent >= 10 ? 2 : 1;
  let useFixed = exponent >= lowerBound && exponent <= upperBound;

  if (useFixed && exponent >= 0) {
    const integer = BigInt(digits) * 10n ** BigInt(exponent);
    if (integer >= 2n ** 53n) useFixed = false;
  }

  if (!useFixed) {
    const mantissa =
      digitCount === 1 ? `${sign}${digits}.0` : `${sign}${digits[0]}.${digits.slice(1)}`;
    return `${mantissa}e${scientificExponent}`;
  }

  let decimal: string;
  if (exponent >= 0) {
    decimal = `${sign}${digits}${'0'.repeat(exponent)}.0`;
  } else if (digitCount + exponent > 0) {
    const decimalPosition = digitCount + exponent;
    decimal = `${sign}${digits.slice(0, decimalPosition)}.${digits.slice(decimalPosition)}`;
  } else {
    decimal = `${sign}0.${'0'.repeat(-(digitCount + exponent))}${digits}`;
  }
  return decimal;
}

function normalizeJsonValue(
  value: unknown,
  depth: number,
  counters: { entries: number },
  maximumEntries: number,
  maximumDepth: number,
  validKey: (key: string) => boolean = () => true,
): JsonValue | typeof invalid {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;

  if (value instanceof ParsedNumber) {
    if (/^-?(?:0|[1-9]\d*)$/.test(value.raw)) {
      const integer = readInteger(value, -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
      return integer === undefined ? invalid : integer;
    }
    return Number.isFinite(value.value) ? value.value : invalid;
  }

  if (Array.isArray(value)) {
    if (depth > maximumDepth) return invalid;
    counters.entries += value.length;
    if (counters.entries > maximumEntries) return invalid;
    const result: JsonValue[] = [];
    for (const item of value) {
      const nestedDepth = Array.isArray(item) || isPlainObject(item) ? depth + 1 : depth;
      const normalized = normalizeJsonValue(
        item,
        nestedDepth,
        counters,
        maximumEntries,
        maximumDepth,
        validKey,
      );
      if (normalized === invalid) return invalid;
      result.push(normalized);
    }
    return result;
  }

  if (isPlainObject(value)) {
    if (depth > maximumDepth) return invalid;
    const keys = Object.keys(value);
    counters.entries += keys.length;
    if (counters.entries > maximumEntries || keys.some((key) => !validKey(key))) {
      return invalid;
    }

    const result: JsonObject = {};
    for (const key of keys) {
      const item = value[key];
      const nestedDepth = Array.isArray(item) || isPlainObject(item) ? depth + 1 : depth;
      const normalized = normalizeJsonValue(
        item,
        nestedDepth,
        counters,
        maximumEntries,
        maximumDepth,
        validKey,
      );
      if (normalized === invalid) return invalid;
      Object.defineProperty(result, key, {
        value: normalized,
        enumerable: true,
        configurable: true,
        writable: true,
      });
    }
    return result;
  }

  return invalid;
}

function snapshotProjectionMatchesTerminal(
  projection: RunProjection,
  terminal: Terminal | null,
): boolean {
  if (terminal === null) return true;
  if (projection.active_tool !== null) return false;
  if (terminal.status !== 'completed') return true;

  return (
    projection.turn === terminal.result.turns &&
    projection.text === '' &&
    projection.provider_attempts === terminal.result.turns + terminal.result.provider_retries &&
    projection.tool_calls === terminal.result.tool_calls &&
    projection.output_bytes === terminal.result.output_bytes
  );
}

function snapshotSequenceMatchesProjection(projection: RunProjection, lastSeq: number): boolean {
  if (projection.status === 'starting') return lastSeq === 0;
  if (projection.status === 'running') return lastSeq > 0;
  if (projection.status === 'cancel_requested') {
    return projection.model === null ? lastSeq === 0 : lastSeq > 0;
  }
  if (projection.status === 'owner_lost') {
    return projection.model === null ? lastSeq === 1 : lastSeq > 1;
  }
  return projection.model === null || lastSeq > 0;
}

function isRequestId(value: unknown): value is string {
  return isIdentifier(value, LIMITS.requestIdBytes);
}

function validErrorRequestId(
  value: unknown,
  policy: 'null' | 'optional' | 'required',
): value is string | null {
  if (policy === 'null') return value === null;
  if (policy === 'required') return isRequestId(value);
  return value === null || isRequestId(value);
}

function isServerErrorCode(value: unknown): value is ServerErrorCode {
  return typeof value === 'string' && Object.hasOwn(SERVER_ERROR_SPECS, value);
}

function readPositiveInteger(value: unknown): number | undefined {
  return readInteger(value, 1, Number.MAX_SAFE_INTEGER);
}

function readNonNegativeInteger(value: unknown): number | undefined {
  return readInteger(value, 0, Number.MAX_SAFE_INTEGER);
}

function readInteger(value: unknown, minimum: number, maximum: number): number | undefined {
  if (!(value instanceof ParsedNumber) || !/^-?(?:0|[1-9]\d*)$/.test(value.raw)) return undefined;

  let integer: bigint;
  try {
    integer = BigInt(value.raw);
  } catch {
    return undefined;
  }

  if (integer < BigInt(minimum) || integer > BigInt(maximum)) return undefined;
  return Number(integer);
}

function failure(code: DecodeErrorCode): DecodeResult {
  return { ok: false, error: { code, message: decodeMessages[code] } };
}

function parseJsonDocument(source: string): ParsedJson {
  let index = 0;
  let nodes = 0;

  const skipWhitespace = () => {
    while (index < source.length && /[\t\n\r ]/.test(source[index])) index += 1;
  };

  const parseString = (): string => {
    const start = index;
    index += 1;
    let escaped = false;

    while (index < source.length) {
      const character = source[index];
      if (!escaped && character === '"') {
        index += 1;
        const value: unknown = JSON.parse(source.slice(start, index));
        if (typeof value !== 'string' || !isWellFormedUnicode(value)) throw new Error();
        return value;
      }
      if (!escaped && character === '\\') {
        escaped = true;
      } else {
        escaped = false;
      }
      index += 1;
    }

    throw new Error();
  };

  const parseNumber = (): ParsedNumber => {
    const match = source.slice(index).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (!match) throw new Error();
    index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) throw new Error();
    return new ParsedNumber(match[0], value);
  };

  const parseValue = (depth: number): ParsedJson => {
    if (depth > LIMITS.jsonDepth || nodes >= LIMITS.jsonNodes) throw new Error();
    nodes += 1;
    skipWhitespace();

    const character = source[index];
    if (character === '"') return parseString();
    if (character === '-' || (character >= '0' && character <= '9')) return parseNumber();

    if (source.startsWith('true', index)) {
      index += 4;
      return true;
    }
    if (source.startsWith('false', index)) {
      index += 5;
      return false;
    }
    if (source.startsWith('null', index)) {
      index += 4;
      return null;
    }

    if (character === '[') {
      index += 1;
      skipWhitespace();
      const values: ParsedJson[] = [];
      if (source[index] === ']') {
        index += 1;
        return values;
      }

      while (values.length < LIMITS.jsonArrayElements) {
        values.push(parseValue(depth + 1));
        skipWhitespace();
        if (source[index] === ']') {
          index += 1;
          return values;
        }
        if (source[index] !== ',') throw new Error();
        index += 1;
      }
      throw new Error();
    }

    if (character === '{') {
      index += 1;
      skipWhitespace();
      const object: { [key: string]: ParsedJson } = Object.create(null);
      const keys = new Set<string>();
      if (source[index] === '}') {
        index += 1;
        return object;
      }

      while (keys.size < LIMITS.jsonObjectKeys) {
        skipWhitespace();
        if (source[index] !== '"') throw new Error();
        const key = parseString();
        if (keys.has(key) || utf8ByteLength(key) > LIMITS.serverMessageBytes) throw new Error();
        keys.add(key);
        skipWhitespace();
        if (source[index] !== ':') throw new Error();
        index += 1;
        object[key] = parseValue(depth + 1);
        skipWhitespace();
        if (source[index] === '}') {
          index += 1;
          return object;
        }
        if (source[index] !== ',') throw new Error();
        index += 1;
      }
      throw new Error();
    }

    throw new Error();
  };

  skipWhitespace();
  const value = parseValue(1);
  skipWhitespace();
  if (index !== source.length) throw new Error();
  return value;
}
