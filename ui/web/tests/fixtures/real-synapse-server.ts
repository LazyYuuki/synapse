import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const READY_PATTERN = /^READY (ws:\/\/127\.0\.0\.1:([1-9]\d{0,4})\/v1\/socket)$/;
const MAX_LINE_BYTES = 512;
const MAX_DIAGNOSTIC_BYTES = 32_768;

export type RealFixtureEvidence = {
  workspace_closed: boolean;
  operations: string[];
  remaining_operations: number;
  remaining_provider_turns: number[];
};

export class RealSynapseServer {
  readonly websocketURL: string;
  readonly workspacePath: string;
  private readonly evidencePath: string;
  private readonly temporaryRoot: string;
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly exitPromise: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  private failure: Error | null = null;
  private stopping = false;

  constructor(
    child: ChildProcessWithoutNullStreams,
    websocketURL: string,
    workspacePath: string,
    evidencePath: string,
    temporaryRoot: string,
    exitPromise: Promise<{ code: number | null; signal: NodeJS.Signals | null }>,
  ) {
    this.child = child;
    this.websocketURL = websocketURL;
    this.workspacePath = workspacePath;
    this.evidencePath = evidencePath;
    this.temporaryRoot = temporaryRoot;
    this.exitPromise = exitPromise;
    void exitPromise.then(({ code, signal }) => {
      if (!this.stopping)
        this.failure = new Error(`Real Synapse fixture exited: ${code}/${signal}`);
    });
  }

  release(operation: 'read' | 'write' | 'bash' | 'text'): void {
    this.command(`release ${operation}`);
  }

  disconnect(): void {
    this.command('disconnect');
  }

  restart(): void {
    this.command('restart');
  }

  async readEvidence(): Promise<RealFixtureEvidence> {
    return JSON.parse(await fs.readFile(this.evidencePath, 'utf8')) as RealFixtureEvidence;
  }

  async workspaceFile(relativePath: string): Promise<string | null> {
    try {
      return await fs.readFile(path.join(this.workspacePath, relativePath), 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw error;
    }
  }

  assertHealthy(): void {
    if (this.failure) throw this.failure;
  }

  recordFailure(error: Error): void {
    if (!this.failure) this.failure = error;
  }

  async stop(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    let forced = false;
    try {
      if (this.child.exitCode === null && this.child.signalCode === null) {
        try {
          this.command('shutdown');
          this.child.stdin.end();
        } catch {
          // Escalation below still owns the detached process group.
        }
        const exited = await waitFor(this.exitPromise, 10_000);
        if (!exited) {
          forced = true;
          killProcessGroup(this.child.pid, 'SIGTERM');
          if (!(await waitFor(this.exitPromise, 5_000))) {
            killProcessGroup(this.child.pid, 'SIGKILL');
          }
        }
      }
      const result = await this.exitPromise;
      if (forced || result.code !== 0 || result.signal !== null) {
        throw new Error(
          `Real Synapse fixture did not exit cleanly: ${result.code}/${result.signal}`,
        );
      }
    } finally {
      if (this.child.exitCode === null && this.child.signalCode === null) {
        killProcessGroup(this.child.pid, 'SIGKILL');
        if (!(await waitFor(this.exitPromise, 5_000))) {
          this.recordFailure(new Error('Real Synapse fixture did not exit after SIGKILL'));
        }
      }
      await fs.rm(this.temporaryRoot, { recursive: true, force: true });
    }
  }

  private command(value: string): void {
    if (!this.child.stdin.writable) throw new Error('Real Synapse fixture stdin is closed');
    this.child.stdin.write(`${value}\n`);
  }
}

export async function startRealSynapseServer(): Promise<RealSynapseServer> {
  const repositoryRoot = fileURLToPath(new URL('../../../../', import.meta.url));
  const pathValue = process.env.PATH;
  if (!pathValue) throw new Error('PATH is required to start the real Synapse fixture');
  const temporaryRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'synapse-web-'));
  const workspacePath = path.join(temporaryRoot, 'workspace');
  const home = path.join(temporaryRoot, 'home');
  const tmp = path.join(temporaryRoot, 'tmp');
  const evidencePath = path.join(temporaryRoot, 'evidence.json');
  try {
    await Promise.all([fs.mkdir(workspacePath), fs.mkdir(home), fs.mkdir(tmp)]);
    await fs.writeFile(path.join(workspacePath, 'README.md'), 'SYNAPSE_WEB_FIXTURE');
  } catch (error) {
    await fs.rm(temporaryRoot, { recursive: true, force: true });
    throw error;
  }

  const child = spawn(
    'mix',
    [
      'run',
      '--no-start',
      '--no-deps-check',
      '--no-compile',
      'ui/web/tests/fixtures/synapse_server.exs',
    ],
    {
      cwd: repositoryRoot,
      detached: true,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        PATH: pathValue,
        HOME: home,
        TMPDIR: tmp,
        MIX_HOME: process.env.MIX_HOME ?? path.join(os.homedir(), '.mix'),
        HEX_HOME: process.env.HEX_HOME ?? path.join(os.homedir(), '.hex'),
        MIX_ENV: 'test',
        ERL_CRASH_DUMP: path.join(tmp, 'erl_crash.dump'),
        ERL_CRASH_DUMP_SECONDS: '0',
        SYNAPSE_FIXTURE_WORKSPACE: workspacePath,
        SYNAPSE_FIXTURE_EVIDENCE: evidencePath,
      },
    },
  );

  let stderr = '';
  child.stderr.on('data', (chunk: Buffer) => {
    stderr = boundedTail(stderr + chunk.toString('utf8'));
  });
  child.stdin.on('error', (error) => {
    if (child.exitCode === null && child.signalCode === null) {
      // The fixture owner will surface this unless teardown already began.
      stderr = boundedTail(`${stderr}\nstdin:${error.message}`);
    }
  });
  const exitPromise = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(
    (resolve) => {
      child.once('exit', (code, signal) => resolve({ code, signal }));
    },
  );

  try {
    const websocketURL = await readReady(child, exitPromise, () => stderr);
    const server = new RealSynapseServer(
      child,
      websocketURL,
      workspacePath,
      evidencePath,
      temporaryRoot,
      exitPromise,
    );
    child.stdout.on('data', (chunk: Buffer) => {
      if (chunk.toString('utf8').trim()) {
        server.recordFailure(new Error('Real Synapse fixture emitted stdout after READY'));
      }
    });
    child.stdin.removeAllListeners('error');
    child.stdin.on('error', (error) => server.recordFailure(error));
    return server;
  } catch (error) {
    killProcessGroup(child.pid, 'SIGKILL');
    await waitFor(exitPromise, 5_000);
    await fs.rm(temporaryRoot, { recursive: true, force: true });
    throw error;
  }
}

async function readReady(
  child: ChildProcessWithoutNullStreams,
  exitPromise: Promise<{ code: number | null; signal: NodeJS.Signals | null }>,
  stderr: () => string,
): Promise<string> {
  const ready = new Promise<string>((resolve, reject) => {
    let buffered = Buffer.alloc(0);
    child.once('error', reject);
    const onData = (chunk: Buffer) => {
      buffered = Buffer.concat([buffered, chunk]);
      if (buffered.length > MAX_LINE_BYTES) {
        child.stdout.off('data', onData);
        return reject(new Error('Fixture READY line exceeded bound'));
      }
      const newline = buffered.indexOf(10);
      if (newline === -1) return;
      const line = buffered.subarray(0, newline).toString('utf8').trimEnd();
      const match = READY_PATTERN.exec(line);
      child.stdout.off('data', onData);
      if (!match) return reject(new Error(`Invalid fixture READY line: ${line}`));
      if (
        buffered
          .subarray(newline + 1)
          .toString('utf8')
          .trim()
      ) {
        return reject(new Error('Fixture emitted additional stdout with READY'));
      }
      resolve(match[1]);
    };
    child.stdout.on('data', onData);
  });
  const exited = exitPromise.then(({ code, signal }) => {
    throw new Error(`Fixture exited before READY: ${code}/${signal}: ${stderr()}`);
  });
  const timeout = new Promise<never>((_resolve, reject) => {
    setTimeout(() => reject(new Error(`Fixture READY timeout: ${stderr()}`)), 30_000);
  });
  return Promise.race([ready, exited, timeout]);
}

function boundedTail(value: string): string {
  return Buffer.byteLength(value) <= MAX_DIAGNOSTIC_BYTES
    ? value
    : Buffer.from(value).subarray(-MAX_DIAGNOSTIC_BYTES).toString('utf8');
}

async function waitFor<T>(promise: Promise<T>, timeoutMs: number): Promise<boolean> {
  return Promise.race([
    promise.then(() => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), timeoutMs)),
  ]);
}

function killProcessGroup(pid: number | undefined, signal: NodeJS.Signals): void {
  if (!pid) return;
  try {
    process.kill(-pid, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
  }
}
