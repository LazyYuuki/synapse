/**
 * Protocol-v1 wire contracts. Runtime validation in decode.ts remains authoritative;
 * these types must never be reached through an unchecked assertion.
 *
 * @see ../../../../../docs/plan/PLAN-API.md
 */

export type RequestId = string;
export type RunId = string;

export type Budget = {
  max_turns: number;
  max_tool_calls: number;
  max_wall_time_ms: number;
  provider_inactivity_ms: number;
  tool_inactivity_ms: number;
  max_output_bytes: number;
  max_provider_retries: number;
};

export type ClientEnvelope<TType extends string, TPayload> = {
  version: 1;
  type: TType;
  request_id: RequestId;
  payload: TPayload;
};

export type ConversationMessage = {
  role: 'user' | 'assistant';
  content: string;
};

export type StartCommand = ClientEnvelope<
  'run.start',
  {
    prompt: string;
    cwd: string;
    model?: string;
    budget?: Partial<Budget>;
    conversation?: ConversationMessage[];
  }
>;

export type CancelCommand = ClientEnvelope<'run.cancel', { run_id: RunId }>;

export type SubscribeCommand = ClientEnvelope<
  'run.subscribe',
  { run_id: RunId; after_seq?: number }
>;

export type PingCommand = ClientEnvelope<'ping', Record<string, never>>;

export type ClientCommand = StartCommand | CancelCommand | SubscribeCommand | PingCommand;

export type ServerEnvelope<TType extends string, TRequestId, TPayload> = {
  version: 1;
  type: TType;
  request_id: TRequestId;
  payload: TPayload;
};

export type ServerErrorCode =
  | 'invalid_json'
  | 'invalid_envelope'
  | 'unsupported_version'
  | 'unknown_type'
  | 'invalid_request_id'
  | 'invalid_payload'
  | 'token_limit_exceeded'
  | 'run_busy'
  | 'run_not_found'
  | 'invalid_cursor'
  | 'subscription_limit'
  | 'runtime_unavailable'
  | 'internal_error';

export type ServerErrorPayload = {
  code: ServerErrorCode;
  message: string;
  retryable: boolean;
};

export type RunStatus =
  | 'starting'
  | 'running'
  | 'cancel_requested'
  | 'owner_lost'
  | 'completed'
  | 'failed'
  | 'interrupted';

export type ActiveTool = {
  turn: number;
  operation_id: string;
  call_id: string;
  name: string;
  ordinal: number;
};

export type RunProjection = {
  status: RunStatus;
  model: string | null;
  turn: number;
  text: string;
  active_tool: ActiveTool | null;
  provider_attempts: number;
  tool_calls: number;
  output_bytes: number;
};

export type ToolPublicMetadata = {
  tool?: string;
  outcome?: 'completed' | 'not_applied' | 'not_applicable' | 'unknown';
};

export type RunStartedEvent = {
  type: 'run.started';
  model: string;
};

export type TurnStartedEvent = {
  type: 'turn.started';
  turn: number;
  operation_id: string;
};

export type TextDeltaEvent = {
  type: 'text.delta';
  turn: number;
  operation_id: string;
  item_id: string;
  content_index: number;
  delta: string;
};

export type ToolStartedEvent = {
  type: 'tool.started';
  turn: number;
  operation_id: string;
  call_id: string;
  name: string;
  ordinal: number;
  arguments: JsonObject;
};

export type ToolCompletedEvent = Omit<ToolStartedEvent, 'type' | 'arguments'> & {
  type: 'tool.completed';
  status: 'ok' | 'error' | 'ambiguous';
  metadata: ToolPublicMetadata;
  content: string;
};

export type TurnCompletedEvent = {
  type: 'turn.completed';
  turn: number;
  outcome: 'continued' | 'completed' | 'failed' | 'interrupted';
  provider_attempts: number;
  tool_calls: number;
  output_bytes: number;
};

export type RunOwnerLostEvent = {
  type: 'run.owner_lost';
};

export type RunEvent =
  | RunStartedEvent
  | TurnStartedEvent
  | TextDeltaEvent
  | ToolStartedEvent
  | ToolCompletedEvent
  | TurnCompletedEvent
  | RunOwnerLostEvent;

export type PublicResult = {
  text: string;
  turns: number;
  tool_calls: number;
  provider_retries: number;
  output_bytes: number;
};

export type JsonValue = null | boolean | number | string | JsonValue[] | JsonObject;
export type JsonObject = { [key: string]: JsonValue };

type AgentErrorBase = {
  source: 'agent';
  message: string;
  turn: number;
  operation_id: string | null;
  details: JsonObject;
};

export type AgentTerminalError = AgentErrorBase &
  (
    | {
        kind: 'internal';
        reason:
          | 'invalid_run_request'
          | 'invalid_agent_context'
          | 'event_sink_failed'
          | 'tool_executor_contract_failed'
          | 'conversation_projection_failed'
          | 'run_worker_crashed'
          | 'workspace_close_failed';
      }
    | {
        kind: 'provider';
        reason:
          'provider_failed' | 'provider_interrupted_after_output' | 'provider_retry_exhausted';
      }
    | {
        kind: 'protocol';
        reason: 'empty_provider_response' | 'invalid_function_call_batch' | 'tool_admission_failed';
      }
    | { kind: 'tool'; reason: 'tool_ambiguous' }
    | {
        kind: 'budget';
        reason:
          | 'turn_budget_exhausted'
          | 'tool_call_budget_exhausted'
          | 'wall_time_budget_exhausted'
          | 'output_budget_exhausted';
      }
    | { kind: 'cancelled'; reason: 'run_cancelled' }
  );

export type RuntimeTerminalError =
  | { source: 'runtime'; reason: 'invalid_run_request'; message: 'Run Request is invalid' }
  | {
      source: 'runtime';
      reason: 'invalid_runtime_options';
      message: 'Runtime options are invalid';
    }
  | {
      source: 'runtime';
      reason: 'runtime_unavailable';
      message: 'Runtime infrastructure is unavailable';
    }
  | { source: 'runtime'; reason: 'runtime_busy'; message: 'Runtime is busy' }
  | {
      source: 'runtime';
      reason: 'workspace_open_failed';
      message: 'Workspace could not be opened';
    }
  | { source: 'runtime'; reason: 'runtime_lost'; message: 'Runtime coordinator was lost' };

export type ApiTerminalError = {
  source: 'api';
  reason: 'internal_contract_failed';
  message: 'Run settlement contract failed';
};

export type TerminalError = AgentTerminalError | RuntimeTerminalError | ApiTerminalError;

export type SuccessfulTerminal = {
  run_id: RunId;
  seq: number;
  status: 'completed';
  result: PublicResult;
  error: null;
};

export type AgentErrorTerminal = {
  run_id: RunId;
  seq: number;
  status: 'failed' | 'interrupted';
  result: null;
  error: AgentTerminalError;
};

export type RuntimeErrorTerminal =
  | {
      run_id: RunId;
      seq: number;
      status: 'failed';
      result: null;
      error: Exclude<RuntimeTerminalError, { reason: 'runtime_lost' }>;
    }
  | {
      run_id: RunId;
      seq: number;
      status: 'interrupted';
      result: null;
      error: Extract<RuntimeTerminalError, { reason: 'runtime_lost' }>;
    };

export type ApiErrorTerminal = {
  run_id: RunId;
  seq: number;
  status: 'interrupted';
  result: null;
  error: ApiTerminalError;
};

export type Terminal =
  SuccessfulTerminal | AgentErrorTerminal | RuntimeErrorTerminal | ApiErrorTerminal;

export type ReplaySnapshotPayload = {
  mode: 'replay';
  reset: false;
  run_id: RunId;
  first_available_seq: number;
  last_seq: number;
  projection: null;
  terminal: null;
};

export type StateSnapshotPayload = {
  mode: 'snapshot';
  reset: boolean;
  run_id: RunId;
  first_available_seq: number;
  last_seq: number;
  projection: RunProjection;
  terminal: Terminal | null;
};

export type SnapshotPayload = ReplaySnapshotPayload | StateSnapshotPayload;

export type ServerHelloMessage = ServerEnvelope<
  'server.hello',
  null,
  { protocol: 1; replay: 'memory'; max_active_runs: 1; cwd: string; max_output_bytes: number }
>;

export type ServerErrorMessage = ServerEnvelope<
  'server.error',
  RequestId | null,
  ServerErrorPayload
>;

export type RunAcceptedMessage = ServerEnvelope<
  'run.accepted',
  RequestId,
  { run_id: RunId; status: 'starting' }
>;

export type RunCancelRequestedMessage = ServerEnvelope<
  'run.cancel_requested',
  RequestId,
  { run_id: RunId; status: 'cancel_requested' | 'already_terminal' }
>;

export type RunSnapshotMessage = ServerEnvelope<'run.snapshot', RequestId | null, SnapshotPayload>;

export type RunEventMessage = ServerEnvelope<
  'run.event',
  null,
  { run_id: RunId; seq: number; event: RunEvent }
>;

export type RunTerminalMessage = ServerEnvelope<'run.terminal', null, Terminal>;
export type PongMessage = ServerEnvelope<'pong', RequestId, Record<string, never>>;

export type ServerMessage =
  | ServerHelloMessage
  | ServerErrorMessage
  | RunAcceptedMessage
  | RunCancelRequestedMessage
  | RunSnapshotMessage
  | RunEventMessage
  | RunTerminalMessage
  | PongMessage;
