/** @see ../../../../../docs/plan/PLAN-API.md */

import type { AgentTerminalError, ServerErrorCode } from './types';

export const PROTOCOL_VERSION = 1 as const;
export const DEFAULT_API_URL = 'ws://127.0.0.1:4848/v1/socket';
export const HARD_CLIENT_MAX_OUTPUT_BYTES = 524_288;

export const LIMITS = {
  clientMessageBytes: 2_097_152,
  serverMessageBytes: 3_276_800,
  promptBytes: 262_144,
  conversationMessages: 128,
  conversationBytes: 1_572_864,
  workspacePathBytes: 4_096,
  modelBytes: 256,
  requestIdBytes: 128,
  runIdBytes: 26,
  projectionTextBytes: HARD_CLIENT_MAX_OUTPUT_BYTES,
  eventDeltaBytes: 64_000,
  operationIdBytes: 256,
  callIdBytes: 512,
  itemIdBytes: 512,
  toolNameBytes: 64,
  toolArgumentBytes: 64_000,
  toolArgumentEntries: 16,
  toolArgumentDepth: 4,
  toolContentBytes: 64_000,
  agentMessageBytes: 512,
  agentDetailsBytes: 4_096,
  agentDetailsEntries: 32,
  agentDetailsDepth: 4,
  jsonDepth: 16,
  jsonObjectKeys: 32,
  jsonArrayElements: 128,
  jsonNodes: 4_096,
  activityEntries: 500,
  activityBytes: 1_048_576,
  traceEntries: 8_192,
  traceBytes: 8_388_608,
  sessionRuns: 64,
  protocolEntries: 500,
  protocolBytes: 1_048_576,
} as const;

export const SERVER_ERROR_SPECS = {
  invalid_json: {
    message: 'Message is not valid JSON',
    retryable: false,
    requestId: 'null',
  },
  invalid_envelope: {
    message: 'Command envelope is invalid',
    retryable: false,
    requestId: 'optional',
  },
  unsupported_version: {
    message: 'Protocol version is not supported',
    retryable: false,
    requestId: 'optional',
  },
  unknown_type: {
    message: 'Command type is not supported',
    retryable: false,
    requestId: 'required',
  },
  invalid_request_id: {
    message: 'Request ID is invalid',
    retryable: false,
    requestId: 'null',
  },
  invalid_payload: {
    message: 'Command payload is invalid',
    retryable: false,
    requestId: 'required',
  },
  token_limit_exceeded: {
    message: 'Estimated input exceeds the 272000 token context limit',
    retryable: false,
    requestId: 'required',
  },
  run_busy: {
    message: 'A run is already active',
    retryable: true,
    requestId: 'required',
  },
  run_not_found: {
    message: 'Run was not found',
    retryable: false,
    requestId: 'required',
  },
  invalid_cursor: {
    message: 'Run cursor is invalid',
    retryable: false,
    requestId: 'required',
  },
  subscription_limit: {
    message: 'Connection subscription limit reached',
    retryable: false,
    requestId: 'required',
  },
  runtime_unavailable: {
    message: 'Runtime is unavailable',
    retryable: true,
    requestId: 'required',
  },
  internal_error: {
    message: 'Internal API failure',
    retryable: false,
    requestId: 'optional',
  },
} as const satisfies Record<
  ServerErrorCode,
  { message: string; retryable: boolean; requestId: 'null' | 'optional' | 'required' }
>;

export const AGENT_REASONS = {
  internal: [
    'invalid_run_request',
    'invalid_agent_context',
    'event_sink_failed',
    'tool_executor_contract_failed',
    'conversation_projection_failed',
    'run_worker_crashed',
    'workspace_close_failed',
  ],
  provider: ['provider_failed', 'provider_interrupted_after_output', 'provider_retry_exhausted'],
  protocol: ['empty_provider_response', 'invalid_function_call_batch', 'tool_admission_failed'],
  tool: ['tool_ambiguous'],
  context: ['token_limit_exceeded'],
  budget: [
    'turn_budget_exhausted',
    'tool_call_budget_exhausted',
    'wall_time_budget_exhausted',
    'output_budget_exhausted',
  ],
  cancelled: ['run_cancelled'],
} as const satisfies Record<AgentTerminalError['kind'], readonly string[]>;

export const RUNTIME_ERRORS = {
  invalid_run_request: { message: 'Run Request is invalid', status: 'failed' },
  invalid_runtime_options: { message: 'Runtime options are invalid', status: 'failed' },
  runtime_unavailable: {
    message: 'Runtime infrastructure is unavailable',
    status: 'failed',
  },
  runtime_busy: { message: 'Runtime is busy', status: 'failed' },
  workspace_open_failed: { message: 'Workspace could not be opened', status: 'failed' },
  runtime_lost: { message: 'Runtime coordinator was lost', status: 'interrupted' },
} as const;

export const AGENT_DETAIL_KEYS = new Set([
  'attempts',
  'call_id',
  'http_status',
  'limit',
  'maximum',
  'observed',
  'operation_id',
  'outcome',
  'output_started',
  'provider_kind',
  'retryable',
  'status',
  'tool_name',
]);
