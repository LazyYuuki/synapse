import assert from 'node:assert/strict';

import { WebSocket, WebSocketServer, type RawData } from 'ws';

import type {
  ClientCommand,
  ServerHelloMessage,
  ServerMessage,
} from '../../src/lib/protocol/types.js';

const MAX_COMMANDS = 64;
const MAX_CONNECTIONS = 16;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const DEFAULT_SCRIPTED_CWD = '/tmp/phase-7-project';

type CommandOf<T extends ClientCommand['type']> = Extract<ClientCommand, { type: T }>;
type ScriptedServerMessage = Exclude<ServerMessage, ServerHelloMessage>;
type QueueWaiter<T> = { resolve(value: T): void; reject(error: Error): void };

export type CloseInfo = { code: number; reason: string };

class AsyncQueue<T> {
  private readonly limit: number;
  private readonly values: T[] = [];
  private readonly waiters: QueueWaiter<T>[] = [];
  private failure: Error | null = null;

  constructor(limit: number) {
    this.limit = limit;
  }

  push(value: T): void {
    if (this.failure) return;
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter.resolve(value);
      return;
    }
    if (this.values.length >= this.limit) {
      this.fail(new Error(`Scripted queue exceeded ${this.limit} entries`));
      return;
    }
    this.values.push(value);
  }

  take(): Promise<T> {
    if (this.failure) return Promise.reject(this.failure);
    const value = this.values.shift();
    if (value !== undefined) return Promise.resolve(value);
    return new Promise<T>((resolve, reject) => this.waiters.push({ resolve, reject }));
  }

  fail(error: Error): void {
    if (this.failure) return;
    this.failure = error;
    for (const waiter of this.waiters.splice(0)) waiter.reject(error);
  }

  assertEmpty(label: string): void {
    assert.equal(this.values.length, 0, `${label} has ${this.values.length} unexpected entries`);
  }
}

export class ScriptedConnection {
  readonly id: number;
  readonly origin: string;
  private readonly socket: WebSocket;
  private readonly commands = new AsyncQueue<string>(MAX_COMMANDS);
  private readonly recordFailure: (error: Error) => void;
  private helloSent = false;
  private closeInfo: CloseInfo | null = null;
  private readonly closePromise: Promise<CloseInfo>;
  private resolveClose!: (info: CloseInfo) => void;

  constructor(
    id: number,
    origin: string,
    socket: WebSocket,
    recordFailure: (error: Error) => void,
  ) {
    this.id = id;
    this.origin = origin;
    this.socket = socket;
    this.recordFailure = recordFailure;
    this.closePromise = new Promise((resolve) => {
      this.resolveClose = resolve;
    });
    socket.on('message', (data, isBinary) => this.handleMessage(data, isBinary));
    socket.on('close', (code, reason) => this.handleClose(code, reason.toString('utf8')));
    socket.on('error', (error) => {
      if (socket.readyState !== WebSocket.CLOSED) this.recordFailure(asError(error));
    });
  }

  async hello(cwd = DEFAULT_SCRIPTED_CWD, maxOutputBytes = 524_288): Promise<void> {
    assert.equal(this.helloSent, false, `Connection ${this.id} already sent server.hello`);
    this.helloSent = true;
    const hello = {
      version: 1,
      type: 'server.hello',
      request_id: null,
      payload: {
        protocol: 1,
        replay: 'memory',
        max_active_runs: 1,
        cwd,
        max_output_bytes: maxOutputBytes,
      },
    } as const satisfies ServerHelloMessage;
    await this.sendText(JSON.stringify(hello), true);
  }

  async expectCommand<T extends ClientCommand['type']>(
    type: T,
    payload: CommandOf<T>['payload'],
  ): Promise<CommandOf<T>> {
    const raw = await this.commands.take();
    let parsed: unknown;
    assert.doesNotThrow(() => {
      parsed = JSON.parse(raw);
    }, `Connection ${this.id} sent malformed JSON`);
    assertPlainObject(parsed);
    const requestId = parsed.request_id;
    assert.ok(typeof requestId === 'string', 'request_id must be a string');
    assert.match(requestId, UUID_PATTERN, 'request_id must be a browser UUID');
    const expected = {
      version: 1,
      type,
      request_id: requestId,
      payload,
    };
    assert.equal(raw, JSON.stringify(expected), `Unexpected exact ${type} command`);
    return expected as unknown as CommandOf<T>;
  }

  async send(message: ScriptedServerMessage): Promise<void> {
    await this.sendText(JSON.stringify(message));
  }

  async sendRaw(text: string): Promise<void> {
    await this.sendText(text);
  }

  async close(code: number, reason = ''): Promise<CloseInfo> {
    assert.equal(this.socket.readyState, WebSocket.OPEN, `Connection ${this.id} is not open`);
    this.socket.close(code, reason);
    return this.waitForClose();
  }

  async terminate(): Promise<CloseInfo> {
    if (this.socket.readyState !== WebSocket.CLOSED) this.socket.terminate();
    return this.waitForClose();
  }

  waitForClose(): Promise<CloseInfo> {
    return this.closeInfo ? Promise.resolve(this.closeInfo) : this.closePromise;
  }

  assertNoQueuedCommands(): void {
    this.commands.assertEmpty(`Connection ${this.id} command queue`);
  }

  stop(): void {
    this.commands.fail(new Error(`Connection ${this.id} stopped`));
    if (this.socket.readyState !== WebSocket.CLOSED) this.socket.terminate();
  }

  private async sendText(text: string, allowBeforeHello = false): Promise<void> {
    assert.ok(allowBeforeHello || this.helloSent, `Connection ${this.id} must send hello first`);
    assert.equal(this.socket.readyState, WebSocket.OPEN, `Connection ${this.id} is not open`);
    await new Promise<void>((resolve, reject) => {
      this.socket.send(text, (error) => (error ? reject(error) : resolve()));
    });
  }

  private handleMessage(data: RawData, isBinary: boolean): void {
    if (isBinary) {
      const error = new Error(`Connection ${this.id} received a binary client command`);
      this.recordFailure(error);
      this.commands.fail(error);
      this.socket.terminate();
      return;
    }
    this.commands.push(data.toString());
  }

  private handleClose(code: number, reason: string): void {
    if (this.closeInfo) return;
    this.closeInfo = { code, reason };
    this.resolveClose(this.closeInfo);
  }
}

export class ScriptedWebSocketServer {
  readonly url: string;
  readonly expectedOrigin: string;
  readonly connections: ScriptedConnection[] = [];
  private readonly server: WebSocketServer;
  private readonly connectionQueue = new AsyncQueue<ScriptedConnection>(MAX_CONNECTIONS);
  private failure: Error | null = null;
  private stopping = false;

  constructor(server: WebSocketServer, port: number, expectedOrigin: string) {
    this.server = server;
    this.url = `ws://127.0.0.1:${port}/v1/socket`;
    this.expectedOrigin = expectedOrigin;
  }

  accept(socket: WebSocket, origin: string): void {
    if (this.stopping) {
      socket.terminate();
      return;
    }
    const connection = new ScriptedConnection(
      this.connections.length + 1,
      origin,
      socket,
      (error) => this.recordFailure(error),
    );
    this.connections.push(connection);
    this.connectionQueue.push(connection);
  }

  nextConnection(): Promise<ScriptedConnection> {
    return this.connectionQueue.take();
  }

  assertHealthy(): void {
    if (this.failure) throw this.failure;
  }

  async stop(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    this.connectionQueue.fail(new Error('Scripted WebSocket server stopped'));
    for (const connection of this.connections) connection.stop();
    await new Promise<void>((resolve, reject) => {
      this.server.close((error) => (error ? reject(error) : resolve()));
    });
  }

  recordFailure(error: Error): void {
    if (this.failure) return;
    this.failure = error;
    this.connectionQueue.fail(error);
  }
}

export async function startScriptedWebSocketServer(
  expectedOrigin: string,
): Promise<ScriptedWebSocketServer> {
  validateExpectedOrigin(expectedOrigin);
  let fixture: ScriptedWebSocketServer | null = null;
  const server = new WebSocketServer({
    host: '127.0.0.1',
    port: 0,
    path: '/v1/socket',
    perMessageDeflate: false,
    maxPayload: 2_097_152,
    verifyClient: ({ req }, done) => {
      const origins = headerValues(req.rawHeaders, 'origin');
      done(origins.length === 1 && origins[0] === expectedOrigin, 403);
    },
  });
  server.on('error', (error) => fixture?.recordFailure(asError(error)));
  await new Promise<void>((resolve, reject) => {
    server.once('listening', resolve);
    server.once('error', reject);
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object', 'Scripted server did not bind a TCP port');
  fixture = new ScriptedWebSocketServer(server, address.port, expectedOrigin);
  server.on('connection', (socket, request) => {
    const origins = headerValues(request.rawHeaders, 'origin');
    fixture?.accept(socket, origins[0] ?? '');
  });
  return fixture;
}

function validateExpectedOrigin(value: string): void {
  const parsed = new URL(value);
  assert.equal(parsed.origin, value, 'Expected Origin must be canonical');
  assert.ok(['http:', 'https:'].includes(parsed.protocol), 'Expected Origin must use HTTP(S)');
  assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname), 'Origin must be local');
  assert.ok(parsed.port, 'Expected Origin must include a port');
}

function headerValues(rawHeaders: string[], name: string): string[] {
  const values: string[] = [];
  for (let index = 0; index < rawHeaders.length; index += 2) {
    if (rawHeaders[index]?.toLowerCase() === name) values.push(rawHeaders[index + 1] ?? '');
  }
  return values;
}

function assertPlainObject(value: unknown): asserts value is Record<string, unknown> {
  assert.ok(
    typeof value === 'object' && value !== null && !Array.isArray(value),
    'Expected object',
  );
}

function asError(value: unknown): Error {
  return value instanceof Error ? value : new Error(String(value));
}
