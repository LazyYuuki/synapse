import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const key = required('TOKAMAK_API_KEY');
const model = required('SYNAPSE_MODEL');
if (process.env.SYNAPSE_LIVE !== '1') throw new Error('SYNAPSE_LIVE=1 is required');
const needles = [...new Set([key, key.trim()].filter(Boolean))];
const cleanEnv = { ...process.env };
delete cleanEnv.TOKAMAK_API_KEY;
delete cleanEnv.SYNAPSE_MODEL;
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'synapse-live-browser-'));
await fs.chmod(root, 0o700);
const workspace = path.join(root, 'workspace');
const output = path.join(root, 'artifacts');
await fs.mkdir(workspace);
let server;
let captured;

try {
  await checkedRun('npm', ['run', 'build'], cleanEnv);
  const apiPort = await availablePort();
  const uiPort = await availablePort();
  server = spawn('mix', ['synapse.server'], {
    cwd: path.resolve('../..'),
    detached: true,
    shell: false,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      ...cleanEnv,
      TOKAMAK_API_KEY: key,
      SYNAPSE_MODEL: model,
      SYNAPSE_API_PORT: String(apiPort),
    },
  });
  const ready = `WebSocket: ws://127.0.0.1:${apiPort}/v1/socket`;
  await waitReady(server, ready);
  const playwrightEnv = {
    ...cleanEnv,
    SYNAPSE_LIVE_SOCKET: `ws://127.0.0.1:${apiPort}/v1/socket`,
    SYNAPSE_LIVE_WORKSPACE: workspace,
    SYNAPSE_LIVE_UI_PORT: String(uiPort),
    SYNAPSE_LIVE_OUTPUT: output,
  };
  captured = await checkedRun(
    'npx',
    ['playwright', 'test', '--config', 'playwright.live.config.ts'],
    playwrightEnv,
  );
  await scan(root);
  assertClean(captured);
  process.stdout.write(captured);
} catch (error) {
  const message = String(error instanceof Error ? error.message : error);
  if (containsSecret(message)) process.stderr.write('live credential disclosure detected\n');
  else process.stderr.write(`${message.slice(0, 2_000)}\n`);
  process.exitCode = 1;
} finally {
  if (server) await stop(server);
  await fs.rm(root, { recursive: true, force: true });
}

async function checkedRun(command, args, env) {
  const child = spawn(command, args, { cwd: process.cwd(), shell: false, env });
  let value = '';
  for (const stream of [child.stdout, child.stderr]) {
    stream.on('data', (chunk) => {
      value = bounded(value + chunk.toString('utf8'));
      if (containsSecret(value)) child.kill('SIGKILL');
    });
  }
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', resolve);
  });
  assertClean(value);
  if (code !== 0) throw new Error(`live subprocess failed (${code}): ${value}`);
  return value;
}

async function waitReady(child, expected) {
  let value = '';
  await Promise.race([
    new Promise((resolve, reject) => {
      const data = (chunk) => {
        value = bounded(value + chunk.toString('utf8'));
        assertClean(value);
        if (value.includes(expected)) resolve();
      };
      child.stdout.on('data', data);
      child.stderr.on('data', data);
      child.once('exit', (code) => reject(new Error(`live server exited before ready (${code})`)));
    }),
    new Promise((_resolve, reject) =>
      setTimeout(() => reject(new Error('live server readiness timeout')), 30_000),
    ),
  ]);
}

async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  process.kill(-child.pid, 'SIGTERM');
  if (!(await exited(child, 20_000))) process.kill(-child.pid, 'SIGKILL');
}

async function exited(child, timeout) {
  return Promise.race([
    new Promise((resolve) => child.once('exit', () => resolve(true))),
    new Promise((resolve) => setTimeout(() => resolve(false), timeout)),
  ]);
}

async function scan(directory) {
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    assertClean(entry.name);
    if (entry.isDirectory()) await scan(file);
    else if (entry.isFile()) assertClean(await fs.readFile(file));
  }
}

async function availablePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) =>
    server.listen(0, '127.0.0.1', resolve).once('error', reject),
  );
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function assertClean(value) {
  if (containsSecret(value)) throw new Error('live credential disclosure detected');
}

function containsSecret(value) {
  const buffer = Buffer.isBuffer(value) ? value.toString('utf8') : String(value);
  return needles.some((needle) => buffer.includes(needle));
}

function bounded(value) {
  return value.length <= 1_000_000 ? value : value.slice(-1_000_000);
}

function required(name) {
  const value = process.env[name];
  if (!value || !value.trim()) throw new Error(`${name} is required`);
  return value;
}
