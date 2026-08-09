import { HARD_CLIENT_MAX_OUTPUT_BYTES, LIMITS } from '../protocol/constants';
import type {
  RunEvent,
  RunEventMessage,
  StartCommand,
  StateSnapshotPayload,
  Terminal,
} from '../protocol/types';
import { utf8ByteLength } from '../protocol/validation';
import {
  projectionView,
  type ReductionKnowledge,
  type RunActivityEntry,
  type RunReductionError,
  type RunReductionResult,
  type RunState,
} from './run-types';
import { appendBounded } from './timeline';

export function initialRunState(runId: string, start: StartCommand | null = null): RunState {
  return {
    runId,
    start,
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
    terminal: null,
    cancelAcknowledged: false,
    lastAppliedSeq: 0,
    activity: [],
    activityBytes: 0,
    events: [],
    eventBytes: 0,
    traceIncomplete: false,
    traceBaseText: '',
    historyReset: false,
    turnStartedAt: null,
    lastTurnDurationMs: null,
    knowledge: exactInitialKnowledge(),
  };
}

export function stateFromSnapshot(payload: StateSnapshotPayload): RunState {
  const projection = projectionView(payload.projection);
  if (payload.terminal?.status === 'completed') projection.text = payload.terminal.result.text;

  return {
    runId: payload.run_id,
    start: null,
    projection,
    terminal: payload.terminal,
    cancelAcknowledged: payload.projection.status === 'cancel_requested',
    lastAppliedSeq: payload.last_seq,
    activity: [],
    activityBytes: 0,
    events: [],
    eventBytes: 0,
    traceIncomplete: payload.last_seq > 0,
    traceBaseText: projection.text,
    historyReset: payload.reset,
    turnStartedAt: null,
    lastTurnDurationMs: null,
    knowledge: snapshotKnowledge(payload),
  };
}

export function applyRunEvent(
  state: RunState,
  payload: RunEventMessage['payload'],
  maxOutputBytes = HARD_CLIENT_MAX_OUTPUT_BYTES,
  receivedAt = performance.now(),
): RunReductionResult {
  const sequenceFailure = validateSequence(state, payload.run_id, payload.seq);
  if (sequenceFailure) return sequenceFailure;
  if (state.terminal) return failure('event_after_terminal');

  const reduced = reduceEvent(state, payload.event, maxOutputBytes);
  if (!reduced.ok) return reduced;

  const applied = { seq: payload.seq, event: payload.event };
  const appliedBytes = utf8ByteLength(JSON.stringify(applied));
  const trace = appendTrace(state, applied, appliedBytes);

  const entry = activityEntry(payload.seq, payload.event);
  const timeline = appendBounded(
    { entries: state.activity, bytes: state.activityBytes },
    entry,
    LIMITS.activityEntries,
    LIMITS.activityBytes,
  );

  const timing = turnTiming(state, payload.event, receivedAt);

  return {
    ok: true,
    state: {
      ...state,
      ...reduced.state,
      ...timing,
      lastAppliedSeq: payload.seq,
      activity: timeline.entries,
      activityBytes: timeline.bytes,
      events: trace.events,
      eventBytes: trace.bytes,
      traceIncomplete: state.traceIncomplete || trace.truncated,
      traceBaseText: trace.baseText,
    },
  };
}

function turnTiming(
  state: RunState,
  event: RunEvent,
  receivedAt: number,
): Pick<RunState, 'turnStartedAt' | 'lastTurnDurationMs'> {
  if (event.type === 'turn.started') {
    return { turnStartedAt: receivedAt, lastTurnDurationMs: null };
  }
  if (event.type === 'turn.completed' && state.turnStartedAt !== null) {
    return {
      turnStartedAt: null,
      lastTurnDurationMs: Math.max(0, receivedAt - state.turnStartedAt),
    };
  }
  return {
    turnStartedAt: state.turnStartedAt,
    lastTurnDurationMs: state.lastTurnDurationMs,
  };
}

function appendTrace(
  state: RunState,
  applied: RunState['events'][number],
  appliedBytes: number,
): { events: RunState['events']; bytes: number; truncated: boolean; baseText: string } {
  if (appliedBytes > LIMITS.traceBytes) {
    return { events: [], bytes: 0, truncated: true, baseText: state.projection.text };
  }

  const events = [...state.events, applied];
  let bytes = state.eventBytes + appliedBytes;
  let truncated = false;
  let baseText = state.traceBaseText;
  while (events.length > LIMITS.traceEntries || bytes > LIMITS.traceBytes) {
    const removed = events.shift();
    if (!removed) break;
    bytes -= utf8ByteLength(JSON.stringify(removed));
    if (removed.event.type === 'text.delta') baseText += removed.event.delta;
    truncated = true;
  }
  return { events, bytes, truncated, baseText };
}

export function applyRunTerminal(
  state: RunState,
  terminal: Terminal,
  maxOutputBytes = HARD_CLIENT_MAX_OUTPUT_BYTES,
): RunReductionResult {
  const sequenceFailure = validateSequence(state, terminal.run_id, terminal.seq);
  if (sequenceFailure) return sequenceFailure;
  if (state.terminal) return failure('event_after_terminal');

  let projection = { ...state.projection, activeTool: null, status: terminal.status };
  if (terminal.status === 'completed') {
    const providerAttempts = checkedAdd(terminal.result.turns, terminal.result.provider_retries);
    if (
      providerAttempts === null ||
      utf8ByteLength(terminal.result.text) > maxOutputBytes ||
      terminal.result.output_bytes > maxOutputBytes
    ) {
      return failure('projection_limit');
    }
    projection = {
      ...projection,
      turn: terminal.result.turns,
      text: terminal.result.text,
      providerAttempts,
      toolCalls: terminal.result.tool_calls,
      outputBytes: terminal.result.output_bytes,
    };
  }

  return {
    ok: true,
    state: {
      ...state,
      projection,
      terminal,
      lastAppliedSeq: terminal.seq,
      knowledge: {
        ...state.knowledge,
        openTurn: false,
        providerOperationId: null,
        providerOperationKnown: true,
        lastToolOrdinal: null,
        ownerLostTool: null,
      },
    },
  };
}

export function applyCancellation(state: RunState, markStatus = true): RunState {
  if (state.terminal) return state;
  const projection =
    markStatus && state.projection.status !== 'owner_lost'
      ? { ...state.projection, status: 'cancel_requested' as const }
      : state.projection;
  return { ...state, projection, cancelAcknowledged: true };
}

function reduceEvent(
  state: RunState,
  event: RunEvent,
  maxOutputBytes: number,
):
  | { ok: true; state: Pick<RunState, 'projection' | 'knowledge'> }
  | { ok: false; error: 'invalid_transition' | 'projection_limit' } {
  const projection = state.projection;
  const knowledge = state.knowledge;

  switch (event.type) {
    case 'run.started': {
      if (knowledge.runStarted || projection.model !== null) return failure('invalid_transition');
      const status =
        projection.status === 'owner_lost' || projection.status === 'cancel_requested'
          ? projection.status
          : 'running';
      return success(
        { ...projection, model: event.model, status },
        { ...knowledge, runStarted: true, ownerLostTool: null },
      );
    }
    case 'turn.started': {
      if (
        !knowledge.runStarted ||
        knowledge.openTurn === true ||
        projection.activeTool !== null ||
        (knowledge.lastTurnOutcomeKnown &&
          knowledge.lastTurnOutcome !== null &&
          knowledge.lastTurnOutcome !== 'continued') ||
        event.turn !== projection.turn + 1
      ) {
        return failure('invalid_transition');
      }
      return success(
        { ...projection, turn: event.turn },
        {
          ...knowledge,
          openTurn: true,
          providerOperationId: event.operation_id,
          providerOperationKnown: true,
          lastToolOrdinal: 0,
          ownerLostTool: null,
        },
      );
    }
    case 'text.delta': {
      if (
        !knowledge.runStarted ||
        knowledge.openTurn === false ||
        projection.activeTool !== null ||
        (knowledge.ownerLostTool !== null && knowledge.ownerLostTool !== 'unknown') ||
        event.turn !== projection.turn ||
        (knowledge.providerOperationKnown && event.operation_id !== knowledge.providerOperationId)
      ) {
        return failure('invalid_transition');
      }
      const text = projection.text + event.delta;
      if (utf8ByteLength(text) > maxOutputBytes) return failure('projection_limit');
      return success(
        { ...projection, text },
        {
          ...knowledge,
          openTurn: true,
          providerOperationId: event.operation_id,
          providerOperationKnown: true,
          ownerLostTool: null,
        },
      );
    }
    case 'tool.started': {
      if (
        !knowledge.runStarted ||
        knowledge.openTurn === false ||
        projection.activeTool !== null ||
        (knowledge.ownerLostTool !== null && knowledge.ownerLostTool !== 'unknown') ||
        event.turn !== projection.turn ||
        (knowledge.lastToolOrdinal !== null && event.ordinal !== knowledge.lastToolOrdinal + 1)
      ) {
        return failure('invalid_transition');
      }
      return success(
        {
          ...projection,
          activeTool: {
            turn: event.turn,
            operation_id: event.operation_id,
            call_id: event.call_id,
            name: event.name,
            ordinal: event.ordinal,
          },
        },
        { ...knowledge, openTurn: true, lastToolOrdinal: event.ordinal, ownerLostTool: null },
      );
    }
    case 'tool.completed': {
      const activeTool = projection.activeTool;
      const matches =
        activeTool !== null &&
        activeTool.turn === event.turn &&
        activeTool.operation_id === event.operation_id &&
        activeTool.call_id === event.call_id &&
        activeTool.name === event.name &&
        activeTool.ordinal === event.ordinal;
      const ownerLossCleanup = projection.status === 'owner_lost' && activeTool === null;
      const ownerLostTool = knowledge.ownerLostTool;
      const matchesOwnerLost =
        ownerLossCleanup &&
        (ownerLostTool === 'unknown' ||
          (ownerLostTool !== null &&
            ownerLostTool.turn === event.turn &&
            ownerLostTool.operation_id === event.operation_id &&
            ownerLostTool.call_id === event.call_id &&
            ownerLostTool.name === event.name &&
            ownerLostTool.ordinal === event.ordinal));
      if (!matches && !matchesOwnerLost) return failure('invalid_transition');
      return success(
        { ...projection, activeTool: null },
        matchesOwnerLost ? { ...knowledge, ownerLostTool: null } : knowledge,
      );
    }
    case 'turn.completed': {
      if (
        !knowledge.runStarted ||
        knowledge.openTurn === false ||
        projection.activeTool !== null ||
        (knowledge.ownerLostTool !== null && knowledge.ownerLostTool !== 'unknown') ||
        event.turn !== projection.turn
      ) {
        return failure('invalid_transition');
      }
      const providerAttempts = checkedAdd(projection.providerAttempts, event.provider_attempts);
      const toolCalls = checkedAdd(projection.toolCalls, event.tool_calls);
      const outputBytes = checkedAdd(projection.outputBytes, event.output_bytes);
      if (
        providerAttempts === null ||
        toolCalls === null ||
        outputBytes === null ||
        outputBytes > maxOutputBytes
      ) {
        return failure('projection_limit');
      }
      return success(
        { ...projection, providerAttempts, toolCalls, outputBytes },
        {
          ...knowledge,
          openTurn: false,
          providerOperationId: null,
          providerOperationKnown: true,
          lastTurnOutcome: event.outcome,
          lastTurnOutcomeKnown: true,
          ownerLostTool: null,
        },
      );
    }
    case 'run.owner_lost':
      if (projection.status === 'owner_lost') return failure('invalid_transition');
      return success(
        { ...projection, status: 'owner_lost', activeTool: null },
        { ...knowledge, ownerLostTool: projection.activeTool },
      );
  }
}

function activityEntry(seq: number, event: RunEvent): RunActivityEntry {
  switch (event.type) {
    case 'run.started':
      return { seq, type: event.type, model: event.model };
    case 'turn.started':
      return { seq, type: event.type, turn: event.turn };
    case 'text.delta':
      return { seq, type: event.type, turn: event.turn, bytes: utf8ByteLength(event.delta) };
    case 'tool.started':
      return {
        seq,
        type: event.type,
        turn: event.turn,
        name: event.name,
        ordinal: event.ordinal,
      };
    case 'tool.completed':
      return {
        seq,
        type: event.type,
        turn: event.turn,
        name: event.name,
        ordinal: event.ordinal,
        status: event.status,
        metadata: { ...event.metadata },
      };
    case 'turn.completed':
      return { seq, type: event.type, turn: event.turn, outcome: event.outcome };
    case 'run.owner_lost':
      return { seq, type: event.type };
  }
}

function validateSequence(
  state: RunState,
  runId: string,
  seq: number,
): { ok: false; error: 'wrong_run' | 'sequence_fault' } | null {
  if (runId !== state.runId) return failure('wrong_run');
  if (!Number.isSafeInteger(seq) || seq !== state.lastAppliedSeq + 1) {
    return failure('sequence_fault');
  }
  return null;
}

function success(
  projection: RunState['projection'],
  knowledge: ReductionKnowledge,
): { ok: true; state: Pick<RunState, 'projection' | 'knowledge'> } {
  return { ok: true, state: { projection, knowledge } };
}

function failure<T extends RunReductionError>(error: T): { ok: false; error: T } {
  return { ok: false, error };
}

function checkedAdd(left: number, right: number): number | null {
  const value = left + right;
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function exactInitialKnowledge(): ReductionKnowledge {
  return {
    runStarted: false,
    openTurn: false,
    providerOperationId: null,
    providerOperationKnown: true,
    lastToolOrdinal: null,
    lastTurnOutcome: null,
    lastTurnOutcomeKnown: true,
    ownerLostTool: null,
  };
}

function snapshotKnowledge(payload: StateSnapshotPayload): ReductionKnowledge {
  const terminal = payload.terminal !== null;
  const activeTool = payload.projection.active_tool;
  return {
    runStarted: payload.projection.model !== null,
    openTurn:
      terminal || payload.projection.status === 'starting'
        ? false
        : activeTool !== null
          ? true
          : null,
    providerOperationId: null,
    providerOperationKnown: false,
    lastToolOrdinal: activeTool?.ordinal ?? null,
    lastTurnOutcome: null,
    lastTurnOutcomeKnown: false,
    ownerLostTool: payload.projection.status === 'owner_lost' ? 'unknown' : null,
  };
}
