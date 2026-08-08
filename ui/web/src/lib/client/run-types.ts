import type {
  ActiveTool,
  RunProjection,
  RunStatus,
  Terminal,
  ToolPublicMetadata,
} from '../protocol/types';

export type RunProjectionView = {
  status: RunStatus;
  model: string | null;
  turn: number;
  text: string;
  activeTool: ActiveTool | null;
  providerAttempts: number;
  toolCalls: number;
  outputBytes: number;
};

export type RunActivityEntry =
  | { seq: number; type: 'run.started'; model: string }
  | { seq: number; type: 'turn.started'; turn: number }
  | { seq: number; type: 'text.delta'; turn: number; bytes: number }
  | { seq: number; type: 'tool.started'; turn: number; name: string; ordinal: number }
  | {
      seq: number;
      type: 'tool.completed';
      turn: number;
      name: string;
      ordinal: number;
      status: 'ok' | 'error' | 'ambiguous';
      metadata: ToolPublicMetadata;
    }
  | {
      seq: number;
      type: 'turn.completed';
      turn: number;
      outcome: 'continued' | 'completed' | 'failed' | 'interrupted';
    }
  | { seq: number; type: 'run.owner_lost' };

export type ReductionKnowledge = {
  runStarted: boolean;
  openTurn: boolean | null;
  providerOperationId: string | null;
  providerOperationKnown: boolean;
  lastToolOrdinal: number | null;
  lastTurnOutcome: 'continued' | 'completed' | 'failed' | 'interrupted' | null;
  lastTurnOutcomeKnown: boolean;
  ownerLostTool: ActiveTool | null | 'unknown';
};

export type RunState = {
  runId: string;
  projection: RunProjectionView;
  terminal: Terminal | null;
  cancelAcknowledged: boolean;
  lastAppliedSeq: number;
  activity: RunActivityEntry[];
  activityBytes: number;
  historyReset: boolean;
  knowledge: ReductionKnowledge;
};

export type RunReductionError =
  | 'wrong_run'
  | 'sequence_fault'
  | 'event_after_terminal'
  | 'invalid_transition'
  | 'projection_limit';

export type RunReductionResult =
  { ok: true; state: RunState } | { ok: false; error: RunReductionError };

export function projectionView(projection: RunProjection): RunProjectionView {
  return {
    status: projection.status,
    model: projection.model,
    turn: projection.turn,
    text: projection.text,
    activeTool: projection.active_tool ? { ...projection.active_tool } : null,
    providerAttempts: projection.provider_attempts,
    toolCalls: projection.tool_calls,
    outputBytes: projection.output_bytes,
  };
}
