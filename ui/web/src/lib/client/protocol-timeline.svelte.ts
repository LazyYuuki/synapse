import { LIMITS } from '../protocol/constants';
import type {
  ClientCommand,
  JsonObject,
  JsonValue,
  RunEvent,
  RunProjection,
  ServerMessage,
  Terminal,
} from '../protocol/types';
import { utf8ByteLength } from '../protocol/validation';
import { appendBounded } from './timeline';

export type ProtocolEntryRole =
  'handshake' | 'command' | 'command_response' | 'asynchronous' | 'terminal';

export type ProtocolEntryMarker =
  'handshake' | 'command' | 'response' | 'event' | 'terminal' | 'replay' | 'snapshot' | 'reset';

export type ProtocolTimelineEntry = {
  id: number;
  direction: 'inbound' | 'outbound';
  type: ClientCommand['type'] | ServerMessage['type'];
  requestId: string | null;
  runId: string | null;
  seq: number | null;
  detail: string | null;
  role: ProtocolEntryRole;
  marker: ProtocolEntryMarker;
  display: JsonObject;
};

export function createProtocolTimeline() {
  let entries = $state<ProtocolTimelineEntry[]>([]);
  let bytes = $state(0);
  let nextId = 1;

  function recordOutbound(command: ClientCommand): void {
    const runId =
      command.type === 'run.cancel' || command.type === 'run.subscribe'
        ? command.payload.run_id
        : null;
    const seq = command.type === 'run.subscribe' ? (command.payload.after_seq ?? null) : null;
    append({
      id: nextId++,
      direction: 'outbound',
      type: command.type,
      requestId: command.request_id,
      runId,
      seq,
      detail: null,
      role: 'command',
      marker: 'command',
      display: commandDisplay(command),
    });
  }

  function recordInbound(message: ServerMessage): void {
    const summary = inboundSummary(message);
    append({
      id: nextId++,
      direction: 'inbound',
      type: message.type,
      requestId: message.request_id,
      runId: summary.runId,
      seq: summary.seq,
      detail: summary.detail,
      role: summary.role,
      marker: summary.marker,
      display: messageDisplay(message),
    });
  }

  function clear(): void {
    entries = [];
    bytes = 0;
  }

  function append(entry: ProtocolTimelineEntry): void {
    const timeline = appendBounded(
      { entries, bytes },
      entry,
      LIMITS.protocolEntries,
      LIMITS.protocolBytes,
    );
    entries = timeline.entries;
    bytes = timeline.bytes;
  }

  return {
    get entries() {
      return entries.map(cloneEntry);
    },
    get bytes() {
      return bytes;
    },
    recordOutbound,
    recordInbound,
    clear,
  };
}

export type ProtocolTimeline = ReturnType<typeof createProtocolTimeline>;

export function serializeProtocolEntries(entries: ProtocolTimelineEntry[]): string {
  return JSON.stringify(
    entries.map((entry) => ({
      index: entry.id,
      direction: entry.direction,
      role: entry.role,
      marker: entry.marker,
      envelope: entry.display,
    })),
    null,
    2,
  );
}

function commandDisplay(command: ClientCommand): JsonObject {
  let payload: JsonObject;
  switch (command.type) {
    case 'run.start':
      payload = {
        prompt: omittedText(command.payload.prompt),
        cwd: { omitted: true, utf8_bytes: utf8ByteLength(command.payload.cwd) },
      };
      if (command.payload.model !== undefined) payload.model = command.payload.model;
      if (command.payload.budget !== undefined) payload.budget = { ...command.payload.budget };
      break;
    case 'run.cancel':
      payload = { run_id: command.payload.run_id };
      break;
    case 'run.subscribe':
      payload = { run_id: command.payload.run_id };
      if (command.payload.after_seq !== undefined) payload.after_seq = command.payload.after_seq;
      break;
    case 'ping':
      payload = {};
      break;
  }
  return envelope(command.type, command.request_id, payload);
}

function messageDisplay(message: ServerMessage): JsonObject {
  let payload: JsonObject;
  switch (message.type) {
    case 'server.hello':
      payload = {
        protocol: message.payload.protocol,
        replay: message.payload.replay,
        max_active_runs: message.payload.max_active_runs,
        cwd: { omitted: true, utf8_bytes: utf8ByteLength(message.payload.cwd) },
        max_output_bytes: message.payload.max_output_bytes,
      };
      break;
    case 'server.error':
      payload = { code: message.payload.code, retryable: message.payload.retryable };
      break;
    case 'run.accepted':
    case 'run.cancel_requested':
      payload = { ...message.payload };
      break;
    case 'run.snapshot':
      payload = {
        mode: message.payload.mode,
        reset: message.payload.reset,
        run_id: message.payload.run_id,
        first_available_seq: message.payload.first_available_seq,
        last_seq: message.payload.last_seq,
        projection:
          message.payload.projection === null
            ? null
            : projectionSummary(message.payload.projection),
        terminal:
          message.payload.terminal === null ? null : terminalSummary(message.payload.terminal),
      };
      break;
    case 'run.event':
      payload = {
        run_id: message.payload.run_id,
        seq: message.payload.seq,
        event: eventSummary(message.payload.event),
      };
      break;
    case 'run.terminal':
      payload = terminalSummary(message.payload);
      break;
    case 'pong':
      payload = {};
      break;
  }
  return envelope(message.type, message.request_id, payload);
}

function inboundSummary(message: ServerMessage): {
  runId: string | null;
  seq: number | null;
  detail: string | null;
  role: ProtocolEntryRole;
  marker: ProtocolEntryMarker;
} {
  switch (message.type) {
    case 'server.hello':
      return {
        runId: null,
        seq: null,
        detail: `protocol:${message.payload.protocol}`,
        role: 'handshake',
        marker: 'handshake',
      };
    case 'server.error':
      return {
        runId: null,
        seq: null,
        detail: message.payload.code,
        role: message.request_id === null ? 'asynchronous' : 'command_response',
        marker: message.request_id === null ? 'event' : 'response',
      };
    case 'run.accepted':
    case 'run.cancel_requested':
      return {
        runId: message.payload.run_id,
        seq: null,
        detail: null,
        role: 'command_response',
        marker: 'response',
      };
    case 'run.snapshot':
      return {
        runId: message.payload.run_id,
        seq: message.payload.last_seq,
        detail: message.payload.reset ? 'snapshot:reset' : message.payload.mode,
        role: message.request_id === null ? 'asynchronous' : 'command_response',
        marker: message.payload.reset
          ? 'reset'
          : message.payload.mode === 'replay'
            ? 'replay'
            : 'snapshot',
      };
    case 'run.event':
      return {
        runId: message.payload.run_id,
        seq: message.payload.seq,
        detail: message.payload.event.type,
        role: 'asynchronous',
        marker: 'event',
      };
    case 'run.terminal':
      return {
        runId: message.payload.run_id,
        seq: message.payload.seq,
        detail: message.payload.status,
        role: 'terminal',
        marker: 'terminal',
      };
    case 'pong':
      return {
        runId: null,
        seq: null,
        detail: null,
        role: 'command_response',
        marker: 'response',
      };
  }
}

function projectionSummary(projection: RunProjection): JsonObject {
  return {
    status: projection.status,
    model: projection.model,
    turn: projection.turn,
    text: omittedText(projection.text),
    active_tool: projection.active_tool ? { ...projection.active_tool } : null,
    provider_attempts: projection.provider_attempts,
    tool_calls: projection.tool_calls,
    output_bytes: projection.output_bytes,
  };
}

function eventSummary(event: RunEvent): JsonObject {
  if (event.type === 'text.delta') {
    return {
      type: event.type,
      turn: event.turn,
      operation_id: event.operation_id,
      item_id: event.item_id,
      content_index: event.content_index,
      delta: omittedText(event.delta),
    };
  }
  if (event.type === 'tool.completed') {
    return { ...event, metadata: { ...event.metadata } };
  }
  return { ...event };
}

function terminalSummary(terminal: Terminal): JsonObject {
  if (terminal.status === 'completed') {
    return {
      run_id: terminal.run_id,
      seq: terminal.seq,
      status: terminal.status,
      result: {
        text: omittedText(terminal.result.text),
        turns: terminal.result.turns,
        tool_calls: terminal.result.tool_calls,
        provider_retries: terminal.result.provider_retries,
        output_bytes: terminal.result.output_bytes,
      },
      error: null,
    };
  }

  const error = terminal.error;
  const summary: JsonObject = {
    source: error.source,
    reason: error.reason,
  };
  if (error.source === 'agent') {
    summary.kind = error.kind;
    summary.turn = error.turn;
    summary.operation_id = error.operation_id;
    summary.details = { omitted: true, keys: Object.keys(error.details).sort() };
  }
  return {
    run_id: terminal.run_id,
    seq: terminal.seq,
    status: terminal.status,
    result: null,
    error: summary,
  };
}

function envelope(type: string, requestId: string | null, payload: JsonObject): JsonObject {
  return { version: 1, type, request_id: requestId, payload };
}

function omittedText(text: string): JsonObject {
  return { omitted: true, utf8_bytes: utf8ByteLength(text) };
}

function cloneEntry(entry: ProtocolTimelineEntry): ProtocolTimelineEntry {
  return {
    ...entry,
    display: cloneJsonObject(entry.display),
  };
}

function cloneJsonObject(value: JsonObject): JsonObject {
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cloneJson(item)]));
}

function cloneJson(value: JsonValue): JsonValue {
  if (Array.isArray(value)) return value.map(cloneJson);
  if (typeof value === 'object' && value !== null) return cloneJsonObject(value);
  return value;
}
