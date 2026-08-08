/** Browser transport ownership for the local protocol-v1 API.
 * @see ../../../../../docs/plan/PLAN-API.md
 */

import { DEFAULT_API_URL, HARD_CLIENT_MAX_OUTPUT_BYTES } from '../protocol/constants';
import { decodeInitialServerMessage, decodeServerMessage } from '../protocol/decode';
import {
  encodeCancelCommand,
  encodePingCommand,
  encodeStartCommand,
  encodeSubscribeCommand,
  type EncodeResult,
  type StartCommandInput,
} from '../protocol/encode';
import type { ClientCommand, ServerHelloMessage, ServerMessage } from '../protocol/types';
import {
  PendingCorrelations,
  type CommandKind,
  type DirectResponseType,
  type PendingCommand,
  type PendingTimers,
} from './pending';

const KEEPALIVE_MS = 25_000;
const READINESS_TIMEOUT_MS = 10_000;
const RESPONSE_WARNING_MS = 8_000;
const MAX_RECONNECT_ATTEMPTS = 10;
const RECONNECT_DELAYS = [250, 500, 1_000, 2_000, 5_000] as const;
const API_URL_STORAGE_KEY = 'synapse.api_url';
const SOCKET_CONNECTING = 0;
const SOCKET_OPEN = 1;
const LOCAL_PROTOCOL_CLOSE = 4_000;
const LOCAL_TIMEOUT_CLOSE = 4_001;
const LOCAL_INTERNAL_CLOSE = 4_002;

export type ConnectionLifecycle =
  | 'idle'
  | 'connecting'
  | 'awaiting_hello'
  | 'ready'
  | 'reconnecting'
  | 'protocol_fault'
  | 'unavailable'
  | 'manually_disconnected';

export type CloseKind =
  | 'manual'
  | 'replaced'
  | 'network'
  | 'going_away'
  | 'server_restart'
  | 'normal'
  | 'protocol'
  | 'policy'
  | 'message_too_large'
  | 'server_internal'
  | 'readiness_timeout'
  | 'client_internal';

export type SanitizedClose = {
  code: number;
  kind: CloseKind;
};

export type ConnectionNoticeCode =
  | 'invalid_url'
  | 'not_ready'
  | 'pending_capacity'
  | 'request_id_unavailable'
  | 'ambiguous_start'
  | 'cancel_pending'
  | 'ping_pending'
  | 'protocol_fault'
  | 'connection_lost'
  | 'reconnect_exhausted'
  | 'server_policy_close'
  | 'server_internal_close'
  | 'readiness_timeout'
  | 'client_internal';

export type ConnectionNotice = {
  code: ConnectionNoticeCode;
  message: string;
};

export type SendCommandResult =
  { ok: true; requestId: string } | { ok: false; error: { code: string; message: string } };

export type ConnectionActionResult =
  { ok: true } | { ok: false; error: { code: string; message: string } };

export type SocketEvent = {
  data?: unknown;
  code?: number;
};

export type SocketEventType = 'open' | 'message' | 'close' | 'error';
export type SocketListener = (event: SocketEvent) => void;

export type SocketLike = {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number): void;
  addEventListener(type: SocketEventType, listener: SocketListener): void;
  removeEventListener(type: SocketEventType, listener: SocketListener): void;
};

export type SessionStorageLike = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
};

export type ConnectionDependencies = PendingTimers & {
  createSocket(url: string): SocketLike;
  now(): number;
  randomUUID(): string;
  storage: SessionStorageLike;
};

export type MessageContext = {
  generation: number;
  correlation: PendingCommand | null;
  maxOutputBytes: number;
};

export type ConnectionCallbacks = {
  onReady?(hello: ServerHelloMessage, generation: number): void;
  onMessage?(message: ServerMessage, context: MessageContext): void;
  onCommandSent?(command: ClientCommand, generation: number): void;
  onCommandDelayed?(command: PendingCommand): void;
  onGenerationEnd?(generation: number, pending: PendingCommand[]): void;
};

type SocketRecord = {
  generation: number;
  socket: SocketLike;
  listeners: Record<SocketEventType, SocketListener>;
  readinessTimer: unknown;
  ended: boolean;
};

const notices = {
  invalid_url: 'API URL must be an explicit local protocol-v1 WebSocket URL.',
  not_ready: 'Connection is not ready for commands.',
  pending_capacity: 'Too many commands are waiting for responses.',
  request_id_unavailable: 'A fresh request ID could not be generated.',
  ambiguous_start: 'The previous start outcome is unknown and cannot be resent safely.',
  cancel_pending: 'Cancellation is already waiting for a server response.',
  ping_pending: 'A keepalive response is already pending.',
  protocol_fault: 'The server connection violated protocol v1.',
  connection_lost: 'The local API connection was lost.',
  reconnect_exhausted: 'Automatic reconnect attempts are exhausted.',
  server_policy_close: 'The server closed the connection for a protocol or policy violation.',
  server_internal_close: 'The server closed the connection after an internal failure.',
  readiness_timeout: 'The local API did not become ready in time.',
  client_internal: 'The browser client could not safely continue the connection.',
} as const satisfies Record<ConnectionNoticeCode, string>;

export function validateApiUrl(
  candidate: unknown,
): { ok: true; url: string } | { ok: false; error: ConnectionNotice } {
  if (typeof candidate !== 'string') return urlFailure();
  const match = candidate.match(/^([A-Za-z]+):\/\/([^:/]+):([1-9][0-9]{0,4})\/v1\/socket$/);
  if (!match) return urlFailure();

  const scheme = match[1].toLowerCase();
  const host = match[2].toLowerCase();
  const port = Number(match[3]);
  if (scheme !== 'ws' || !['localhost', '127.0.0.1'].includes(host)) return urlFailure();
  if (!Number.isInteger(port) || port > 65_535) return urlFailure();
  return { ok: true, url: `ws://${host}:${port}/v1/socket` };
}

export function createConnectionController(
  dependencies: ConnectionDependencies,
  callbacks: ConnectionCallbacks = {},
) {
  let lifecycle = $state<ConnectionLifecycle>('idle');
  let apiUrl = $state(restoredApiUrl(dependencies.storage));
  let hello = $state<ServerHelloMessage | null>(null);
  let generation = $state(0);
  let reconnectAttempts = $state(0);
  let pendingCount = $state(0);
  let pendingStart = $state(false);
  let pendingPing = $state(false);
  let pendingCancel = $state(false);
  let lastServerActivity = $state<number | null>(null);
  let lastClose = $state<SanitizedClose | null>(null);
  let notice = $state<ConnectionNotice | null>(null);
  let startAmbiguous = $state(false);
  let visible = $state(true);

  let current: SocketRecord | null = null;
  let reconnectTimer: unknown = null;
  let reconnectToken = 0;
  let keepaliveTimer: unknown = null;
  let reconnectPaused = false;
  let destroyed = false;

  const pending = new PendingCorrelations(dependencies, RESPONSE_WARNING_MS, (command) => {
    if (command.kind === 'start') startAmbiguous = true;
    callbacks.onCommandDelayed?.(command);
  });

  function connect(candidate: string = apiUrl): ConnectionActionResult {
    if (destroyed) return sendFailure('not_ready');
    const validated = validateApiUrl(candidate);
    if (!validated.ok) {
      notice = validated.error;
      return { ok: false, error: validated.error };
    }

    apiUrl = validated.url;
    persistApiUrl(dependencies.storage, apiUrl);
    notice = null;
    reconnectAttempts = 0;
    clearReconnectTimer();
    const replaced = current;
    const removed = replaced ? finishRecord(replaced, true, 1_000, 'replaced') : [];
    if (replaced) lastClose = { code: 1_000, kind: 'replaced' };
    startSocket(false);
    if (replaced) notifyGenerationEnd(replaced.generation, removed);
    return { ok: true };
  }

  function reconnect(): ConnectionActionResult {
    if (destroyed) return sendFailure('not_ready');
    reconnectAttempts = 0;
    notice = null;
    clearReconnectTimer();
    const replaced = current;
    const removed = replaced ? finishRecord(replaced, true, 1_000, 'replaced') : [];
    if (replaced) lastClose = { code: 1_000, kind: 'replaced' };
    startSocket(false);
    if (replaced) notifyGenerationEnd(replaced.generation, removed);
    return { ok: true };
  }

  function disconnect(): void {
    clearReconnectTimer();
    clearKeepaliveTimer();
    const disconnected = current;
    const removed = disconnected ? finishRecord(disconnected, true, 1_000, 'manual') : [];
    hello = null;
    lifecycle = 'manually_disconnected';
    lastClose = { code: 1_000, kind: 'manual' };
    notice = null;
    if (disconnected) notifyGenerationEnd(disconnected.generation, removed);
  }

  function destroy(): void {
    if (destroyed) return;
    destroyed = true;
    disconnect();
    const removed = pending.clear();
    if (removed.some((command) => command.kind === 'start')) startAmbiguous = true;
    syncPendingCount();
  }

  function failProtocol(): void {
    if (current) {
      protocolFault(current);
      return;
    }
    lifecycle = 'protocol_fault';
    notice = fixedNotice('protocol_fault');
  }

  function setVisible(nextVisible: boolean): void {
    visible = nextVisible;
    if (!visible) {
      clearKeepaliveTimer();
      if (lifecycle === 'reconnecting') pauseReconnectTimer();
    } else if (reconnectPaused) {
      reconnectPaused = false;
      if (!current) scheduleReconnect();
    } else if (lifecycle === 'ready') {
      scheduleKeepalive(0);
    }
  }

  function startRun(input: Omit<StartCommandInput, 'requestId'>): SendCommandResult {
    const blocked = commandBlock('start');
    if (blocked) return sendFailure(blocked);
    const requestId = nextRequestId();
    if (!requestId) return sendFailure('request_id_unavailable');
    return sendEncoded(
      'start',
      'run.accepted',
      null,
      encodeStartCommand({
        requestId,
        prompt: input.prompt,
        cwd: input.cwd,
        model: input.model,
        budget: input.budget,
      }),
    );
  }

  function cancelRun(runId: string): SendCommandResult {
    const blocked = commandBlock('cancel');
    if (blocked) return sendFailure(blocked);
    const requestId = nextRequestId();
    if (!requestId) return sendFailure('request_id_unavailable');
    return sendEncoded(
      'cancel',
      'run.cancel_requested',
      runId,
      encodeCancelCommand(requestId, runId),
    );
  }

  function subscribe(runId: string, afterSeq?: number): SendCommandResult {
    const blocked = commandBlock('subscribe');
    if (blocked) return sendFailure(blocked);
    const requestId = nextRequestId();
    if (!requestId) return sendFailure('request_id_unavailable');
    return sendEncoded(
      'subscribe',
      'run.snapshot',
      runId,
      encodeSubscribeCommand(requestId, runId, afterSeq),
    );
  }

  function ping(): SendCommandResult {
    const blocked = commandBlock('ping');
    if (blocked) return sendFailure(blocked);
    const requestId = nextRequestId();
    if (!requestId) return sendFailure('request_id_unavailable');
    return sendEncoded('ping', 'pong', null, encodePingCommand(requestId));
  }

  function startSocket(isReconnect: boolean): void {
    if (current) return;
    clearKeepaliveTimer();
    hello = null;
    generation += 1;
    lifecycle = isReconnect ? 'reconnecting' : 'connecting';
    const socketGeneration = generation;

    let socket: SocketLike;
    try {
      socket = dependencies.createSocket(apiUrl);
    } catch {
      lastClose = { code: 1_006, kind: 'network' };
      scheduleReconnect();
      return;
    }

    const record: SocketRecord = {
      generation: socketGeneration,
      socket,
      listeners: {
        open: () => handleOpen(record),
        message: (event) => handleMessage(record, event.data),
        close: (event) => handleClose(record, event.code),
        error: () => undefined,
      },
      readinessTimer: null,
      ended: false,
    };
    current = record;
    for (const type of socketEventTypes) socket.addEventListener(type, record.listeners[type]);
    record.readinessTimer = dependencies.setTimeout(
      () => handleReadinessTimeout(record),
      READINESS_TIMEOUT_MS,
    );
  }

  function handleOpen(record: SocketRecord): void {
    if (!currentRecord(record)) return;
    lifecycle = 'awaiting_hello';
  }

  function handleMessage(record: SocketRecord, data: unknown): void {
    if (!currentRecord(record)) return;

    if (
      lifecycle === 'awaiting_hello' ||
      lifecycle === 'connecting' ||
      lifecycle === 'reconnecting'
    ) {
      const decoded = decodeInitialServerMessage(data);
      if (!decoded.ok || decoded.message.type !== 'server.hello') {
        protocolFault(record);
        return;
      }

      dependencies.clearTimeout(record.readinessTimer);
      lastServerActivity = dependencies.now();
      const helloMessage = decoded.message;
      hello = helloMessage;
      lifecycle = 'ready';
      reconnectAttempts = 0;
      reconnectPaused = false;
      notice = null;
      scheduleKeepalive(KEEPALIVE_MS);
      if (!invoke(() => callbacks.onReady?.(helloMessage, record.generation))) {
        clientInternalFault(record);
      }
      return;
    }

    if (lifecycle !== 'ready') return;
    const decoded = decodeServerMessage(
      data,
      hello?.payload.max_output_bytes ?? HARD_CLIENT_MAX_OUTPUT_BYTES,
    );
    if (!decoded.ok || decoded.message.type === 'server.hello') {
      protocolFault(record);
      return;
    }

    const message = decoded.message;
    lastServerActivity = dependencies.now();
    let correlation: PendingCommand | null = null;
    if (typeof message.request_id === 'string') {
      const responseType = directResponseType(message);
      if (!responseType) {
        protocolFault(record);
        return;
      }
      const expectedCommand = pending.get(message.request_id);
      const responseRunId = directResponseRunId(message);
      if (
        !expectedCommand ||
        (expectedCommand.runId !== null &&
          responseType !== 'server.error' &&
          responseRunId !== expectedCommand.runId)
      ) {
        protocolFault(record);
        return;
      }
      const settled = pending.settle(message.request_id, responseType, record.generation);
      if (!settled.ok) {
        protocolFault(record);
        return;
      }
      correlation = settled.command;
      syncPendingCount();
    }

    const applied = invoke(() =>
      callbacks.onMessage?.(message, {
        generation: record.generation,
        correlation,
        maxOutputBytes: hello?.payload.max_output_bytes ?? HARD_CLIENT_MAX_OUTPUT_BYTES,
      }),
    );
    if (correlation?.kind === 'start') {
      startAmbiguous = !applied && message.type === 'run.accepted';
    }
    if (!applied) {
      clientInternalFault(record);
    }
  }

  function handleClose(record: SocketRecord, rawCode: number | undefined): void {
    if (!currentRecord(record)) return;
    const code = sanitizeCloseCode(rawCode);
    const classification = classifyRemoteClose(code);
    const removed = finishRecord(record, false, code, classification.kind);
    hello = null;
    lastClose = { code, kind: classification.kind };

    if (classification.retry) {
      notice = fixedNotice('connection_lost');
      scheduleReconnect();
    } else if (classification.lifecycle === 'protocol_fault') {
      lifecycle = 'protocol_fault';
      notice = fixedNotice('server_policy_close');
    } else {
      lifecycle = 'unavailable';
      notice = fixedNotice(
        classification.kind === 'server_internal' ? 'server_internal_close' : 'connection_lost',
      );
    }
    notifyGenerationEnd(record.generation, removed);
  }

  function handleReadinessTimeout(record: SocketRecord): void {
    if (!currentRecord(record)) return;
    lastClose = { code: LOCAL_TIMEOUT_CLOSE, kind: 'readiness_timeout' };
    notice = fixedNotice('readiness_timeout');
    const removed = finishRecord(record, true, LOCAL_TIMEOUT_CLOSE, 'readiness_timeout');
    scheduleReconnect();
    notifyGenerationEnd(record.generation, removed);
  }

  function protocolFault(record: SocketRecord): void {
    if (!currentRecord(record)) return;
    lastClose = { code: LOCAL_PROTOCOL_CLOSE, kind: 'protocol' };
    notice = fixedNotice('protocol_fault');
    lifecycle = 'protocol_fault';
    const removed = finishRecord(record, true, LOCAL_PROTOCOL_CLOSE, 'protocol');
    notifyGenerationEnd(record.generation, removed);
  }

  function clientInternalFault(record: SocketRecord): void {
    if (!currentRecord(record)) return;
    lastClose = { code: LOCAL_INTERNAL_CLOSE, kind: 'client_internal' };
    notice = fixedNotice('client_internal');
    lifecycle = 'unavailable';
    const removed = finishRecord(record, true, LOCAL_INTERNAL_CLOSE, 'client_internal');
    notifyGenerationEnd(record.generation, removed);
  }

  function sendEncoded(
    kind: CommandKind,
    expected: DirectResponseType,
    runId: string | null,
    encoded: EncodeResult<ClientCommand>,
  ): SendCommandResult {
    if (!encoded.ok) return { ok: false, error: encoded.error };
    const record = current;
    if (!record || lifecycle !== 'ready' || record.socket.readyState !== SOCKET_OPEN) {
      return sendFailure('not_ready');
    }
    if (pending.full) return sendFailure('pending_capacity');

    const requestId = encoded.command.request_id;
    if (!pending.add(requestId, kind, expected, record.generation, runId)) {
      return sendFailure('pending_capacity');
    }
    syncPendingCount();

    try {
      record.socket.send(encoded.json);
    } catch {
      const removed = pending.remove(requestId);
      if (removed?.kind === 'start') startAmbiguous = true;
      syncPendingCount();
      lastClose = { code: 1_006, kind: 'network' };
      notice = fixedNotice('connection_lost');
      const generationEnded = finishRecord(record, true, 1_000, 'network');
      scheduleReconnect();
      notifyGenerationEnd(
        record.generation,
        removed ? [removed, ...generationEnded] : generationEnded,
      );
      return sendFailure('not_ready');
    }

    try {
      callbacks.onCommandSent?.(encoded.command, record.generation);
    } catch {
      // Diagnostic rendering cannot change command admission or correlation.
    }
    return { ok: true, requestId };
  }

  function finishRecord(
    record: SocketRecord,
    closeSocket: boolean,
    closeCode: number,
    kind: CloseKind,
  ): PendingCommand[] {
    if (record.ended) return [];
    record.ended = true;
    dependencies.clearTimeout(record.readinessTimer);
    clearKeepaliveTimer();
    for (const type of socketEventTypes) {
      record.socket.removeEventListener(type, record.listeners[type]);
    }

    const removed = pending.clearGeneration(record.generation);
    if (removed.some((command) => command.kind === 'start')) startAmbiguous = true;
    syncPendingCount();
    if (current === record) current = null;

    if (
      closeSocket &&
      (record.socket.readyState === SOCKET_CONNECTING || record.socket.readyState === SOCKET_OPEN)
    ) {
      try {
        record.socket.close(closeCode);
      } catch {
        // Local lifecycle state remains authoritative when the browser refuses close().
      }
    }

    if (kind === 'manual' || kind === 'replaced') hello = null;
    return removed;
  }

  function notifyGenerationEnd(socketGeneration: number, removed: PendingCommand[]): void {
    try {
      callbacks.onGenerationEnd?.(socketGeneration, removed);
    } catch {
      // Cleanup cannot be blocked by diagnostics.
    }
  }

  function scheduleReconnect(): void {
    clearReconnectTimer();
    if (destroyed) return;
    if (!visible) {
      reconnectPaused = true;
      lifecycle = 'reconnecting';
      return;
    }
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      lifecycle = 'unavailable';
      notice = fixedNotice('reconnect_exhausted');
      return;
    }

    reconnectAttempts += 1;
    lifecycle = 'reconnecting';
    const delay = RECONNECT_DELAYS[Math.min(reconnectAttempts - 1, RECONNECT_DELAYS.length - 1)];
    const token = reconnectToken;
    reconnectTimer = dependencies.setTimeout(() => {
      if (destroyed || token !== reconnectToken || lifecycle !== 'reconnecting') return;
      reconnectTimer = null;
      startSocket(true);
    }, delay);
  }

  function clearReconnectTimer(): void {
    reconnectToken += 1;
    if (reconnectTimer !== null) dependencies.clearTimeout(reconnectTimer);
    reconnectTimer = null;
    reconnectPaused = false;
  }

  function pauseReconnectTimer(): void {
    reconnectToken += 1;
    if (reconnectTimer !== null) {
      dependencies.clearTimeout(reconnectTimer);
      reconnectAttempts = Math.max(0, reconnectAttempts - 1);
    }
    reconnectTimer = null;
    reconnectPaused = true;
  }

  function scheduleKeepalive(delay: number): void {
    clearKeepaliveTimer();
    if (!visible || lifecycle !== 'ready') return;
    const socketGeneration = generation;
    keepaliveTimer = dependencies.setTimeout(() => {
      keepaliveTimer = null;
      if (!visible || lifecycle !== 'ready' || generation !== socketGeneration) return;
      if (!pending.hasKind('ping')) ping();
      scheduleKeepalive(KEEPALIVE_MS);
    }, delay);
  }

  function clearKeepaliveTimer(): void {
    if (keepaliveTimer !== null) dependencies.clearTimeout(keepaliveTimer);
    keepaliveTimer = null;
  }

  function nextRequestId(): string | null {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      let requestId: string;
      try {
        requestId = dependencies.randomUUID();
      } catch {
        return null;
      }
      if (!pending.has(requestId)) return requestId;
    }
    return null;
  }

  function commandBlock(kind: CommandKind): ConnectionNoticeCode | null {
    if (!current || lifecycle !== 'ready' || current.socket.readyState !== SOCKET_OPEN) {
      return 'not_ready';
    }
    if (pendingCount >= pending.capacity) return 'pending_capacity';
    if (kind === 'start' && (startAmbiguous || pendingStart)) {
      return 'ambiguous_start';
    }
    if (kind === 'cancel' && pendingCancel) return 'cancel_pending';
    if (kind === 'ping' && pendingPing) return 'ping_pending';
    return null;
  }

  function syncPendingCount(): void {
    pendingCount = pending.size;
    pendingStart = pending.hasKind('start');
    pendingPing = pending.hasKind('ping');
    pendingCancel = pending.hasKind('cancel');
  }

  function currentRecord(record: SocketRecord): boolean {
    return !record.ended && current === record && generation === record.generation;
  }

  return {
    get lifecycle() {
      return lifecycle;
    },
    get apiUrl() {
      return apiUrl;
    },
    get hello() {
      return hello;
    },
    get generation() {
      return generation;
    },
    get reconnectAttempts() {
      return reconnectAttempts;
    },
    get pendingCount() {
      return pendingCount;
    },
    get lastServerActivity() {
      return lastServerActivity;
    },
    get lastClose() {
      return lastClose;
    },
    get notice() {
      return notice;
    },
    get startAmbiguous() {
      return startAmbiguous;
    },
    get pendingStart() {
      return pendingStart;
    },
    get pendingCancel() {
      return pendingCancel;
    },
    get visible() {
      return visible;
    },
    get canConnect() {
      return ['idle', 'unavailable', 'protocol_fault', 'manually_disconnected'].includes(lifecycle);
    },
    get canReconnect() {
      return lifecycle !== 'connecting' && lifecycle !== 'awaiting_hello' && lifecycle !== 'ready';
    },
    get canSendCommands() {
      return lifecycle === 'ready' && pendingCount < pending.capacity;
    },
    get canStart() {
      return (
        lifecycle === 'ready' && pendingCount < pending.capacity && !pendingStart && !startAmbiguous
      );
    },
    get canCancel() {
      return lifecycle === 'ready' && pendingCount < pending.capacity && !pendingCancel;
    },
    connect,
    reconnect,
    disconnect,
    destroy,
    failProtocol,
    setVisible,
    startRun,
    cancelRun,
    subscribe,
    ping,
  };
}

export type ConnectionController = ReturnType<typeof createConnectionController>;

export function createBrowserConnectionController(callbacks: ConnectionCallbacks = {}) {
  const controller = createConnectionController(
    {
      createSocket(url) {
        const socket = new WebSocket(url);
        return {
          get readyState() {
            return socket.readyState;
          },
          send(data) {
            socket.send(data);
          },
          close(code) {
            socket.close(code);
          },
          addEventListener(type, listener) {
            socket.addEventListener(type, listener as EventListener);
          },
          removeEventListener(type, listener) {
            socket.removeEventListener(type, listener as EventListener);
          },
        };
      },
      setTimeout(callback, delayMs) {
        return window.setTimeout(callback, delayMs);
      },
      clearTimeout(handle) {
        window.clearTimeout(handle as number);
      },
      now: () => Date.now(),
      randomUUID: () => crypto.randomUUID(),
      storage: safeBrowserStorage(),
    },
    callbacks,
  );

  let resumeAfterPageShow = false;
  const handleVisibility = () => controller.setVisible(!document.hidden);
  const handlePageHide = (event: PageTransitionEvent) => {
    if (event.persisted) {
      resumeAfterPageShow = ['connecting', 'awaiting_hello', 'ready', 'reconnecting'].includes(
        controller.lifecycle,
      );
      controller.disconnect();
    } else {
      controller.destroy();
    }
  };
  const handlePageShow = (event: PageTransitionEvent) => {
    if (!event.persisted || !resumeAfterPageShow) return;
    resumeAfterPageShow = false;
    controller.reconnect();
  };
  document.addEventListener('visibilitychange', handleVisibility);
  window.addEventListener('pagehide', handlePageHide);
  window.addEventListener('pageshow', handlePageShow);
  handleVisibility();

  const destroy = controller.destroy;
  let lifecycleAttached = true;
  controller.destroy = () => {
    if (lifecycleAttached) {
      lifecycleAttached = false;
      document.removeEventListener('visibilitychange', handleVisibility);
      window.removeEventListener('pagehide', handlePageHide);
      window.removeEventListener('pageshow', handlePageShow);
    }
    destroy();
  };
  return controller;
}

const socketEventTypes: SocketEventType[] = ['open', 'message', 'close', 'error'];

function directResponseType(message: ServerMessage): DirectResponseType | 'server.error' | null {
  switch (message.type) {
    case 'run.accepted':
    case 'run.cancel_requested':
    case 'run.snapshot':
    case 'pong':
      return message.type;
    case 'server.error':
      return message.request_id === null ? null : 'server.error';
    default:
      return null;
  }
}

function directResponseRunId(message: ServerMessage): string | null {
  switch (message.type) {
    case 'run.cancel_requested':
    case 'run.snapshot':
      return message.payload.run_id;
    default:
      return null;
  }
}

function classifyRemoteClose(code: number): {
  kind: CloseKind;
  retry: boolean;
  lifecycle: 'protocol_fault' | 'unavailable';
} {
  if ([1_001, 1_012, 1_013, 1_005, 1_006].includes(code)) {
    return {
      kind: code === 1_001 ? 'going_away' : code === 1_012 ? 'server_restart' : 'network',
      retry: true,
      lifecycle: 'unavailable',
    };
  }
  if (code === 1_008) return { kind: 'policy', retry: false, lifecycle: 'protocol_fault' };
  if (code === 1_009) {
    return { kind: 'message_too_large', retry: false, lifecycle: 'protocol_fault' };
  }
  if (code === 1_002 || code === 1_003 || code === 1_007) {
    return { kind: 'protocol', retry: false, lifecycle: 'protocol_fault' };
  }
  if (code === 1_011) {
    return { kind: 'server_internal', retry: false, lifecycle: 'unavailable' };
  }
  return {
    kind: code === 1_000 ? 'normal' : 'network',
    retry: false,
    lifecycle: 'unavailable',
  };
}

function sanitizeCloseCode(code: number | undefined): number {
  return Number.isInteger(code) && code !== undefined && code >= 0 && code <= 4_999 ? code : 1_006;
}

function invoke(callback: () => void): boolean {
  try {
    callback();
    return true;
  } catch {
    return false;
  }
}

function safeBrowserStorage(): SessionStorageLike {
  return {
    getItem(key) {
      try {
        return window.sessionStorage.getItem(key);
      } catch {
        return null;
      }
    },
    setItem(key, value) {
      try {
        window.sessionStorage.setItem(key, value);
      } catch {
        // Storage is optional for current in-memory interaction.
      }
    },
    removeItem(key) {
      try {
        window.sessionStorage.removeItem(key);
      } catch {
        // Storage is optional for current in-memory interaction.
      }
    },
  };
}

function restoredApiUrl(storage: SessionStorageLike): string {
  try {
    const stored = storage.getItem(API_URL_STORAGE_KEY);
    const validated = validateApiUrl(stored);
    if (validated.ok) return validated.url;
    if (stored !== null) storage.removeItem(API_URL_STORAGE_KEY);
    return DEFAULT_API_URL;
  } catch {
    return DEFAULT_API_URL;
  }
}

function persistApiUrl(storage: SessionStorageLike, url: string): void {
  try {
    storage.setItem(API_URL_STORAGE_KEY, url);
  } catch {
    // Storage availability is not required for current in-memory interaction.
  }
}

function fixedNotice(code: ConnectionNoticeCode): ConnectionNotice {
  return { code, message: notices[code] };
}

function sendFailure(code: ConnectionNoticeCode): {
  ok: false;
  error: { code: string; message: string };
} {
  return { ok: false, error: fixedNotice(code) };
}

function urlFailure(): { ok: false; error: ConnectionNotice } {
  return { ok: false, error: fixedNotice('invalid_url') };
}
