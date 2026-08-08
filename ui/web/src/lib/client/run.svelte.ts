import { SvelteMap } from 'svelte/reactivity';

import type { MessageContext, SendCommandResult } from './connection.svelte';
import type { PendingCommand, PendingTimers } from './pending';
import {
  applyCancellation,
  applyRunEvent,
  applyRunTerminal,
  initialRunState,
  stateFromSnapshot,
} from './run-reducer';
import type { RunState } from './run-types';
import type { ClientCommand, RunSnapshotMessage, ServerMessage } from '../protocol/types';
import { HARD_CLIENT_MAX_OUTPUT_BYTES } from '../protocol/constants';
import { isRunId, utf8ByteLength } from '../protocol/validation';

const RUN_ID_STORAGE_KEY = 'synapse.run_id';
const CATCH_UP_TIMEOUT_MS = 10_000;

export type RunSyncState =
  | 'idle'
  | 'live'
  | 'detached'
  | 'awaiting_replay'
  | 'awaiting_snapshot'
  | 'catching_up'
  | 'recovering'
  | 'terminal'
  | 'not_found'
  | 'protocol_fault';

export type RunNoticeCode =
  'sequence_fault' | 'history_reset' | 'run_not_found' | 'subscription_failed' | 'protocol_fault';

export type RunNotice = { code: RunNoticeCode; message: string };

export type RunStorage = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
};

export type RunTransport = {
  subscribe(runId: string, afterSeq?: number): SendCommandResult;
  failProtocol(): void;
};

export type RunControllerDependencies = PendingTimers & {
  storage: RunStorage;
  transport: RunTransport;
};

type Subscription = {
  generation: number;
  requestId: string;
  runId: string;
  strategy: 'replay' | 'snapshot';
  afterSeq: number | null;
  supersededByReset: boolean;
};

const notices = {
  sequence_fault: 'Run updates lost strict sequence; recovering from an authoritative snapshot.',
  history_reset: 'Earlier run activity is no longer retained; current server state was restored.',
  run_not_found: 'The server no longer retains this process-lifetime run.',
  subscription_failed: 'Run synchronization failed; the last validated view was retained.',
  protocol_fault: 'Run synchronization violated protocol v1; the last validated view was retained.',
} as const satisfies Record<RunNoticeCode, string>;

export function createRunController(dependencies: RunControllerDependencies) {
  const initialRestoredRunId = restoreRunId(dependencies.storage);
  let current = $state<RunState | null>(null);
  let restoredRunId = $state<string | null>(initialRestoredRunId);
  let syncState = $state<RunSyncState>(initialRestoredRunId ? 'detached' : 'idle');
  let notice = $state<RunNotice | null>(null);
  let activeGeneration = $state<number | null>(null);
  let catchUpTarget = $state<number | null>(null);

  let subscription: Subscription | null = null;
  let requireSnapshot = false;
  let catchUpTimer: unknown = null;
  const pendingCancels = new SvelteMap<string, number>();

  function handleReady(generation: number, maxOutputBytes = HARD_CLIENT_MAX_OUTPUT_BYTES): void {
    activeGeneration = generation;
    subscription = null;
    clearCatchUp();
    const runId = current?.runId ?? restoredRunId;
    if (!runId) {
      syncState = 'idle';
      return;
    }

    if (
      current &&
      (utf8ByteLength(current.projection.text) > maxOutputBytes ||
        current.projection.outputBytes > maxOutputBytes)
    ) {
      requireSnapshot = true;
    }

    if (current && !requireSnapshot) {
      sendSubscription(generation, runId, 'replay', current.lastAppliedSeq);
    } else {
      sendSubscription(generation, runId, 'snapshot');
    }
  }

  function handleGenerationEnd(generation: number, pending: PendingCommand[]): void {
    if (generation !== activeGeneration) return;
    if (
      current &&
      pending.some((command) => command.kind === 'cancel' && command.runId === current?.runId)
    ) {
      requireSnapshot = true;
    }
    for (const [requestId, commandGeneration] of pendingCancels) {
      if (commandGeneration === generation) pendingCancels.delete(requestId);
    }
    subscription = null;
    clearCatchUp();
    activeGeneration = null;
    if (current || restoredRunId) syncState = 'detached';
  }

  function handleMessage(message: ServerMessage, context: MessageContext): void {
    switch (message.type) {
      case 'run.accepted':
        handleAccepted(message.payload.run_id, context);
        return;
      case 'run.cancel_requested':
        handleCancellation(message.payload.run_id, message.payload.status, context);
        return;
      case 'run.snapshot':
        handleSnapshot(message, context);
        return;
      case 'run.event':
        handleEvent(message, context);
        return;
      case 'run.terminal':
        handleTerminal(message, context);
        return;
      case 'server.error':
        handleServerError(message.payload.code, context);
        return;
      case 'server.hello':
      case 'pong':
        return;
    }
  }

  function handleCommandSent(command: ClientCommand, generation: number): void {
    if (command.type === 'run.cancel' && current?.runId === command.payload.run_id) {
      pendingCancels.set(command.request_id, generation);
    }
  }

  function clear(): boolean {
    if (!canClear()) return false;
    current = null;
    restoredRunId = null;
    subscription = null;
    clearCatchUp();
    requireSnapshot = false;
    syncState = 'idle';
    notice = null;
    removeRunId(dependencies.storage);
    return true;
  }

  function handleAccepted(runId: string, context: MessageContext): void {
    if (context.correlation?.kind !== 'start' || current || restoredRunId) {
      protocolFault();
      return;
    }
    current = initialRunState(runId);
    restoredRunId = runId;
    requireSnapshot = false;
    syncState = 'live';
    notice = null;
    persistRunId(dependencies.storage, runId);
  }

  function handleCancellation(
    runId: string,
    status: 'cancel_requested' | 'already_terminal',
    context: MessageContext,
  ): void {
    if (context.correlation) pendingCancels.delete(context.correlation.requestId);
    if (context.correlation?.kind !== 'cancel' || !current || current.runId !== runId) {
      protocolFault();
      return;
    }
    current = applyCancellation(current, status === 'cancel_requested');
  }

  function handleSnapshot(message: RunSnapshotMessage, context: MessageContext): void {
    const payload = message.payload;
    if (message.request_id === null) {
      if (
        !current ||
        payload.mode !== 'snapshot' ||
        !payload.reset ||
        payload.run_id !== current.runId
      ) {
        protocolFault();
        return;
      }
      if (payload.last_seq < current.lastAppliedSeq) {
        protocolFault();
        return;
      }
      if (current.lastAppliedSeq >= payload.first_available_seq - 1) {
        protocolFault();
        return;
      }
      const pendingSubscription = subscription;
      installSnapshot(payload, pendingSubscription !== null);
      if (pendingSubscription) {
        pendingSubscription.supersededByReset = true;
        requireSnapshot = pendingSubscription.strategy === 'replay';
        syncState = requireSnapshot ? 'recovering' : 'awaiting_snapshot';
      }
      return;
    }

    if (!matchesSubscription(context)) {
      protocolFault();
      return;
    }
    const completed = subscription;
    subscription = null;

    if (!validSubscriptionResponse(completed, payload)) {
      protocolFault();
      return;
    }

    if (payload.mode === 'replay') {
      if (
        completed?.strategy !== 'replay' ||
        !current ||
        requireSnapshot ||
        completed.supersededByReset
      ) {
        if (current && requireSnapshot) {
          sendSubscription(context.generation, current.runId, 'snapshot');
          return;
        }
        protocolFault();
        return;
      }
      catchUpTarget = payload.last_seq;
      syncState =
        current.lastAppliedSeq < payload.last_seq
          ? 'catching_up'
          : current.terminal
            ? 'terminal'
            : 'live';
      if (syncState === 'catching_up') scheduleCatchUpTimeout(context.generation);
      return;
    }

    installSnapshot(payload);
  }

  function handleEvent(
    message: Extract<ServerMessage, { type: 'run.event' }>,
    context: MessageContext,
  ): void {
    if (
      !current ||
      message.payload.run_id !== current.runId ||
      context.generation !== activeGeneration
    ) {
      protocolFault();
      return;
    }
    if (subscription || syncState === 'recovering') {
      beginRecovery(context.generation);
      return;
    }

    const reduced = applyRunEvent(current, message.payload, context.maxOutputBytes);
    if (!reduced.ok) {
      if (reduced.error === 'projection_limit') {
        protocolFault();
        return;
      }
      beginRecovery(context.generation);
      return;
    }
    current = reduced.state;
    finishCatchUp();
  }

  function handleTerminal(
    message: Extract<ServerMessage, { type: 'run.terminal' }>,
    context: MessageContext,
  ): void {
    if (
      !current ||
      message.payload.run_id !== current.runId ||
      context.generation !== activeGeneration
    ) {
      protocolFault();
      return;
    }
    if (subscription || syncState === 'recovering') {
      beginRecovery(context.generation);
      return;
    }

    const reduced = applyRunTerminal(current, message.payload, context.maxOutputBytes);
    if (!reduced.ok) {
      if (reduced.error === 'projection_limit') {
        protocolFault();
        return;
      }
      beginRecovery(context.generation);
      return;
    }
    current = reduced.state;
    syncState = 'terminal';
    clearCatchUp();
  }

  function handleServerError(code: string, context: MessageContext): void {
    if (context.correlation?.kind === 'cancel') {
      pendingCancels.delete(context.correlation.requestId);
    }
    if (
      code === 'run_not_found' &&
      context.correlation?.kind === 'cancel' &&
      current?.runId === context.correlation.runId
    ) {
      forgetMissingRun();
      return;
    }
    if (context.correlation?.kind !== 'subscribe') return;
    if (!matchesSubscription(context)) {
      protocolFault();
      return;
    }
    subscription = null;
    clearCatchUp();
    if (code === 'run_not_found') {
      forgetMissingRun();
      return;
    }
    failSynchronization('subscription_failed');
  }

  function beginRecovery(generation: number): void {
    notice = fixedNotice('sequence_fault');
    requireSnapshot = true;
    syncState = 'recovering';
    clearCatchUp();
    if (!subscription && current) sendSubscription(generation, current.runId, 'snapshot');
  }

  function installSnapshot(
    payload: Extract<RunSnapshotMessage['payload'], { mode: 'snapshot' }>,
    preserveSubscription = false,
  ): void {
    const retainedCancelAcknowledgement =
      current?.runId === payload.run_id && current.cancelAcknowledged;
    const snapshot = stateFromSnapshot(payload);
    current = retainedCancelAcknowledgement ? { ...snapshot, cancelAcknowledged: true } : snapshot;
    restoredRunId = payload.run_id;
    persistRunId(dependencies.storage, payload.run_id);
    clearCatchUp();
    if (!preserveSubscription) {
      subscription = null;
      requireSnapshot = false;
      syncState = payload.terminal ? 'terminal' : 'live';
    }
    notice = payload.reset ? fixedNotice('history_reset') : null;
  }

  function finishCatchUp(): void {
    if (catchUpTarget !== null && current && current.lastAppliedSeq >= catchUpTarget) {
      clearCatchUp();
      syncState = current.terminal ? 'terminal' : 'live';
    }
  }

  function sendSubscription(
    generation: number,
    runId: string,
    strategy: 'replay' | 'snapshot',
    afterSeq?: number,
  ): void {
    const sent = dependencies.transport.subscribe(runId, afterSeq);
    if (!sent.ok) {
      failSynchronization('subscription_failed');
      return;
    }
    subscription = {
      generation,
      requestId: sent.requestId,
      runId,
      strategy,
      afterSeq: afterSeq ?? null,
      supersededByReset: false,
    };
    syncState =
      strategy === 'replay'
        ? 'awaiting_replay'
        : requireSnapshot
          ? 'recovering'
          : 'awaiting_snapshot';
  }

  function matchesSubscription(context: MessageContext): boolean {
    return (
      context.correlation?.kind === 'subscribe' &&
      subscription !== null &&
      context.generation === subscription.generation &&
      context.correlation.requestId === subscription.requestId &&
      context.correlation.runId === subscription.runId
    );
  }

  function failSynchronization(code: 'subscription_failed' | 'protocol_fault'): void {
    dependencies.transport.failProtocol();
    notice = fixedNotice(code);
    syncState = 'protocol_fault';
    subscription = null;
    clearCatchUp();
  }

  function protocolFault(): void {
    failSynchronization('protocol_fault');
  }

  function validSubscriptionResponse(
    completed: Subscription | null,
    payload: RunSnapshotMessage['payload'],
  ): boolean {
    if (!completed) return false;
    const doesNotRegress = !current || payload.last_seq >= current.lastAppliedSeq;
    if (completed.strategy === 'snapshot') {
      return payload.mode === 'snapshot' && !payload.reset && doesNotRegress;
    }
    const cursor = completed.afterSeq;
    if (payload.mode === 'snapshot') {
      return (
        payload.reset &&
        cursor !== null &&
        cursor < payload.first_available_seq - 1 &&
        doesNotRegress
      );
    }
    return (
      cursor !== null && cursor <= payload.last_seq && cursor >= payload.first_available_seq - 1
    );
  }

  function scheduleCatchUpTimeout(generation: number): void {
    clearCatchUpTimer();
    catchUpTimer = dependencies.setTimeout(() => {
      catchUpTimer = null;
      if (activeGeneration !== generation || syncState !== 'catching_up') return;
      beginRecovery(generation);
    }, CATCH_UP_TIMEOUT_MS);
  }

  function clearCatchUp(): void {
    catchUpTarget = null;
    clearCatchUpTimer();
  }

  function clearCatchUpTimer(): void {
    if (catchUpTimer !== null) dependencies.clearTimeout(catchUpTimer);
    catchUpTimer = null;
  }

  function forgetMissingRun(): void {
    notice = fixedNotice('run_not_found');
    current = null;
    restoredRunId = null;
    requireSnapshot = false;
    subscription = null;
    clearCatchUp();
    syncState = 'not_found';
    removeRunId(dependencies.storage);
  }

  function canClear(): boolean {
    if (subscription || pendingCancels.size > 0) return false;
    return (
      (current?.terminal !== null && current?.terminal !== undefined) || syncState === 'not_found'
    );
  }

  return {
    get current() {
      return current ? $state.snapshot(current) : null;
    },
    get restoredRunId() {
      return restoredRunId;
    },
    get syncState() {
      return syncState;
    },
    get notice() {
      return notice;
    },
    get activeGeneration() {
      return activeGeneration;
    },
    get catchUpTarget() {
      return catchUpTarget;
    },
    get canClear() {
      return canClear();
    },
    handleReady,
    handleGenerationEnd,
    handleMessage,
    handleCommandSent,
    clear,
  };
}

export type RunController = ReturnType<typeof createRunController>;

export function browserRunStorage(): RunStorage {
  return {
    getItem(key) {
      return window.sessionStorage.getItem(key);
    },
    setItem(key, value) {
      window.sessionStorage.setItem(key, value);
    },
    removeItem(key) {
      window.sessionStorage.removeItem(key);
    },
  };
}

function restoreRunId(storage: RunStorage): string | null {
  try {
    const candidate = storage.getItem(RUN_ID_STORAGE_KEY);
    if (candidate === null) return null;
    if (isRunId(candidate)) return candidate;
    storage.removeItem(RUN_ID_STORAGE_KEY);
  } catch {
    // Storage is an optional same-tab restoration aid.
  }
  return null;
}

function persistRunId(storage: RunStorage, runId: string): void {
  try {
    storage.setItem(RUN_ID_STORAGE_KEY, runId);
  } catch {
    // In-memory observation remains valid when storage is unavailable.
  }
}

function removeRunId(storage: RunStorage): void {
  try {
    storage.removeItem(RUN_ID_STORAGE_KEY);
  } catch {
    // In-memory clearing remains authoritative when storage is unavailable.
  }
}

function fixedNotice(code: RunNoticeCode): RunNotice {
  return { code, message: notices[code] };
}
