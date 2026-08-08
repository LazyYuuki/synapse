import type {
  SessionStorageLike,
  SocketEvent,
  SocketEventType,
  SocketLike,
  SocketListener,
} from '../../src/lib/client/connection.svelte';

export class FakeSocket implements SocketLike {
  readyState = 0;
  readonly sent: string[] = [];
  readonly closes: number[] = [];
  throwOnSend = false;
  readonly #listeners = new Map<SocketEventType, Set<SocketListener>>();

  send(data: string): void {
    if (this.throwOnSend) throw new Error('sanitized fake send failure');
    this.sent.push(data);
  }

  close(code = 1_000): void {
    this.closes.push(code);
    this.readyState = 3;
  }

  addEventListener(type: SocketEventType, listener: SocketListener): void {
    const listeners = this.#listeners.get(type) ?? new Set<SocketListener>();
    listeners.add(listener);
    this.#listeners.set(type, listeners);
  }

  removeEventListener(type: SocketEventType, listener: SocketListener): void {
    this.#listeners.get(type)?.delete(listener);
  }

  emitOpen(): void {
    this.readyState = 1;
    this.emit('open', {});
  }

  emitMessage(data: unknown): void {
    this.emit('message', { data });
  }

  emitClose(code = 1_006): void {
    this.readyState = 3;
    this.emit('close', { code });
  }

  emitError(): void {
    this.emit('error', {});
  }

  listenerCount(type: SocketEventType): number {
    return this.#listeners.get(type)?.size ?? 0;
  }

  captureListeners(type: SocketEventType): SocketListener[] {
    return Array.from(this.#listeners.get(type) ?? []);
  }

  private emit(type: SocketEventType, event: SocketEvent): void {
    for (const listener of this.#listeners.get(type) ?? []) listener(event);
  }
}

export class FakeSocketFactory {
  readonly sockets: FakeSocket[] = [];
  readonly urls: string[] = [];
  failNext = false;

  create = (url: string): FakeSocket => {
    this.urls.push(url);
    if (this.failNext) {
      this.failNext = false;
      throw new Error('sanitized fake construction failure');
    }
    const socket = new FakeSocket();
    this.sockets.push(socket);
    return socket;
  };
}

export class MemorySessionStorage implements SessionStorageLike {
  readonly values = new Map<string, string>();
  throwOnRead = false;
  throwOnWrite = false;
  throwOnRemove = false;

  getItem(key: string): string | null {
    if (this.throwOnRead) throw new Error('sanitized fake storage read failure');
    return this.values.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    if (this.throwOnWrite) throw new Error('sanitized fake storage write failure');
    this.values.set(key, value);
  }

  removeItem(key: string): void {
    if (this.throwOnRemove) throw new Error('sanitized fake storage remove failure');
    this.values.delete(key);
  }
}
