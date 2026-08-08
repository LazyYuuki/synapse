export type CommandKind = 'start' | 'cancel' | 'subscribe' | 'ping';
export type DirectResponseType = 'run.accepted' | 'run.cancel_requested' | 'run.snapshot' | 'pong';

export type PendingCommand = {
  requestId: string;
  kind: CommandKind;
  expected: DirectResponseType;
  generation: number;
  runId: string | null;
  delayed: boolean;
};

export type PendingTimers = {
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
};

type PendingEntry = PendingCommand & { warningTimer: unknown };

export class PendingCorrelations {
  readonly #entries = new Map<string, PendingEntry>();

  constructor(
    private readonly timers: PendingTimers,
    private readonly warningMs: number,
    private readonly onDelayed: (command: PendingCommand) => void,
    readonly capacity = 32,
  ) {}

  get size(): number {
    return this.#entries.size;
  }

  get full(): boolean {
    return this.size >= this.capacity;
  }

  has(requestId: string): boolean {
    return this.#entries.has(requestId);
  }

  get(requestId: string): PendingCommand | undefined {
    const entry = this.#entries.get(requestId);
    return entry ? publicCommand(entry) : undefined;
  }

  hasKind(kind: CommandKind): boolean {
    for (const entry of this.#entries.values()) {
      if (entry.kind === kind) return true;
    }
    return false;
  }

  add(
    requestId: string,
    kind: CommandKind,
    expected: DirectResponseType,
    generation: number,
    runId: string | null = null,
  ): boolean {
    if (this.full || this.has(requestId)) return false;

    const entry: PendingEntry = {
      requestId,
      kind,
      expected,
      generation,
      runId,
      delayed: false,
      warningTimer: undefined,
    };
    entry.warningTimer = this.timers.setTimeout(() => {
      const current = this.#entries.get(requestId);
      if (current !== entry || current.delayed) return;
      current.delayed = true;
      try {
        this.onDelayed(publicCommand(current));
      } catch {
        // Diagnostics cannot alter correlation ownership.
      }
    }, this.warningMs);
    this.#entries.set(requestId, entry);
    return true;
  }

  settle(
    requestId: string,
    responseType: DirectResponseType | 'server.error',
    generation: number,
  ):
    | { ok: true; command: PendingCommand }
    | { ok: false; reason: 'unknown_request' | 'wrong_generation' | 'unexpected_response' } {
    const entry = this.#entries.get(requestId);
    if (!entry) return { ok: false, reason: 'unknown_request' };
    if (entry.generation !== generation) return { ok: false, reason: 'wrong_generation' };
    if (responseType !== 'server.error' && responseType !== entry.expected) {
      return { ok: false, reason: 'unexpected_response' };
    }

    this.timers.clearTimeout(entry.warningTimer);
    this.#entries.delete(requestId);
    return { ok: true, command: publicCommand(entry) };
  }

  remove(requestId: string): PendingCommand | undefined {
    const entry = this.#entries.get(requestId);
    if (!entry) return undefined;
    this.timers.clearTimeout(entry.warningTimer);
    this.#entries.delete(requestId);
    return publicCommand(entry);
  }

  clearGeneration(generation: number): PendingCommand[] {
    const removed: PendingCommand[] = [];
    for (const [requestId, entry] of this.#entries) {
      if (entry.generation !== generation) continue;
      this.timers.clearTimeout(entry.warningTimer);
      this.#entries.delete(requestId);
      removed.push(publicCommand(entry));
    }
    return removed;
  }

  clear(): PendingCommand[] {
    const removed = Array.from(this.#entries.values(), publicCommand);
    for (const entry of this.#entries.values()) this.timers.clearTimeout(entry.warningTimer);
    this.#entries.clear();
    return removed;
  }
}

function publicCommand(entry: PendingEntry): PendingCommand {
  return {
    requestId: entry.requestId,
    kind: entry.kind,
    expected: entry.expected,
    generation: entry.generation,
    runId: entry.runId,
    delayed: entry.delayed,
  };
}
