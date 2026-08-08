import type {
  RunEvent,
  RunAcceptedMessage,
  RunEventMessage,
  RunProjection,
  RunSnapshotMessage,
  RunTerminalMessage,
  Terminal,
} from '../../src/lib/protocol/types.js';

export const RUN_ID = 'run_AAAAAAAAAAAAAAAAAAAAAA';

export function accepted(requestId: string): RunAcceptedMessage {
  return {
    version: 1,
    type: 'run.accepted',
    request_id: requestId,
    payload: { run_id: RUN_ID, status: 'starting' },
  };
}

export function runEvent(seq: number, event: RunEvent): RunEventMessage {
  return {
    version: 1,
    type: 'run.event',
    request_id: null,
    payload: { run_id: RUN_ID, seq, event },
  };
}

export function terminal(payload: Terminal): RunTerminalMessage {
  return { version: 1, type: 'run.terminal', request_id: null, payload };
}

export function replaySnapshot(requestId: string, lastSeq: number): RunSnapshotMessage {
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

export function stateSnapshot(
  requestId: string,
  projection: RunProjection,
  lastSeq: number,
  options: { reset: boolean; firstAvailableSeq: number; terminal?: Terminal | null },
): RunSnapshotMessage {
  return {
    version: 1,
    type: 'run.snapshot',
    request_id: requestId,
    payload: {
      mode: 'snapshot',
      reset: options.reset,
      run_id: RUN_ID,
      first_available_seq: options.firstAvailableSeq,
      last_seq: lastSeq,
      projection,
      terminal: options.terminal ?? null,
    },
  };
}
