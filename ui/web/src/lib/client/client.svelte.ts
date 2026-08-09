import {
  createBrowserConnectionController,
  type ConnectionCallbacks,
  type ConnectionController,
  type SendCommandResult,
} from './connection.svelte';
import { createProtocolTimeline } from './protocol-timeline.svelte';
import {
  browserRunStorage,
  createRunController,
  type RunControllerDependencies,
} from './run.svelte';
import { createServerErrorNotices } from './server-errors.svelte';
import { encodeStartCommand, type StartCommandInput } from '../protocol/encode';
import { LIMITS } from '../protocol/constants';
import type { ConversationMessage } from '../protocol/types';
import { utf8ByteLength } from '../protocol/validation';

export type ClientControllerOptions = {
  createConnection(callbacks: ConnectionCallbacks): ConnectionController;
  run: Omit<RunControllerDependencies, 'transport'>;
};

export function createClientControllers(options: ClientControllerOptions) {
  const protocol = createProtocolTimeline();
  const errors = createServerErrorNotices();
  const connectionRef: { current: ConnectionController | null } = { current: null };
  const run = createRunController({
    ...options.run,
    transport: {
      subscribe(runId, afterSeq) {
        return (
          connectionRef.current?.subscribe(runId, afterSeq) ?? {
            ok: false,
            error: { code: 'not_ready', message: 'Connection is not ready for commands.' },
          }
        );
      },
      failProtocol() {
        connectionRef.current?.failProtocol();
      },
    },
  });

  const connection = options.createConnection({
    onReady(hello, generation) {
      safely(() => protocol.recordInbound(hello));
      run.handleReady(generation, hello.payload.max_output_bytes);
    },
    onMessage(message, context) {
      safely(() => protocol.recordInbound(message));
      safely(() => errors.handleMessage(message, context));
      run.handleMessage(message, context);
    },
    onCommandSent(command, generation) {
      safely(() => protocol.recordOutbound(command));
      run.handleCommandSent(command, generation);
    },
    onGenerationEnd(generation, pending) {
      run.handleGenerationEnd(generation, pending);
    },
  });
  connectionRef.current = connection;

  function startRun(input: Omit<StartCommandInput, 'requestId'>): SendCommandResult {
    if (!canStartRun())
      return actionFailure('run_active', 'A current or restored run blocks start.');
    errors.clear();
    const conversation = conversationFor(run.runs, input);
    const result = connection.startRun(
      conversation.length > 0 ? { ...input, conversation } : input,
    );
    if (result.ok && run.current?.terminal && !run.prepareNext()) {
      connection.failProtocol();
      return actionFailure('run_active', 'The sent follow-up could not archive its prior run.');
    }
    return result;
  }

  function cancelRun(): SendCommandResult {
    const current = run.current;
    if (!current || current.terminal || current.cancelAcknowledged || !connection.canCancel) {
      return actionFailure('cancel_unavailable', 'Cancellation is not available for this run.');
    }
    errors.clear();
    return connection.cancelRun(current.runId);
  }

  function canStartRun(): boolean {
    return (
      connection.canStart &&
      (run.current === null || run.canPrepareNext) &&
      (run.restoredRunId === null || run.current?.terminal !== null)
    );
  }

  return {
    connection,
    run,
    protocol,
    errors,
    get canStartRun() {
      return canStartRun();
    },
    get canCancelRun() {
      const current = run.current;
      return (
        current !== null &&
        current.terminal === null &&
        !current.cancelAcknowledged &&
        connection.canCancel
      );
    },
    get canClearRun() {
      return run.canClear;
    },
    startRun,
    cancelRun,
    clearRun() {
      errors.clear();
      const cleared = run.clear();
      if (cleared && connection.lifecycle === 'ready') connection.connect(connection.apiUrl);
      return cleared;
    },
    destroy() {
      connection.destroy();
    },
  };
}

function conversationFor(
  runs: ReturnType<typeof createRunController>['runs'],
  input: Omit<StartCommandInput, 'requestId'>,
): ConversationMessage[] {
  const pairs: ConversationMessage[][] = [];
  for (const run of runs) {
    if (run.start && run.terminal?.status === 'completed') {
      pairs.push([
        { role: 'user', content: run.start.payload.prompt },
        { role: 'assistant', content: run.terminal.result.text },
      ]);
    }
  }

  const selected: ConversationMessage[][] = [];
  let bytes = 0;
  for (let index = pairs.length - 1; index >= 0; index -= 1) {
    const pair = pairs[index];
    const pairBytes = pair.reduce((total, message) => total + utf8ByteLength(message.content), 0);
    const candidate = [pair, ...selected].flat();
    const encoded = encodeStartCommand({
      ...input,
      requestId: 'x'.repeat(LIMITS.requestIdBytes),
      conversation: candidate,
    });
    if (
      candidate.length > LIMITS.conversationMessages ||
      bytes + pairBytes > LIMITS.conversationBytes ||
      !encoded.ok
    ) {
      break;
    }
    selected.unshift(pair);
    bytes += pairBytes;
  }
  return selected.flat();
}

export type ClientControllers = ReturnType<typeof createClientControllers>;
export type ClientControllerFactory = () => ClientControllers;

export function createBrowserClientControllers(): ClientControllers {
  return createClientControllers({
    createConnection: createBrowserConnectionController,
    run: {
      storage: browserRunStorage(),
      setTimeout(callback, delayMs) {
        return window.setTimeout(callback, delayMs);
      },
      clearTimeout(handle) {
        window.clearTimeout(handle as number);
      },
    },
  });
}

function actionFailure(code: string, message: string): SendCommandResult {
  return { ok: false, error: { code, message } };
}

function safely(callback: () => void): void {
  try {
    callback();
  } catch {
    // Diagnostics and presentation notices cannot alter authoritative run handling.
  }
}
