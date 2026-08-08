import { promises as fs } from 'node:fs';
import path from 'node:path';

import { expect, test } from '@playwright/test';

const socketURL = required('SYNAPSE_LIVE_SOCKET');
const workspace = required('SYNAPSE_LIVE_WORKSPACE');
const outputDir = required('SYNAPSE_LIVE_OUTPUT');

test('completes live text, coding/reconnect, and cancellation runs', async ({ page }) => {
  test.setTimeout(1_200_000);
  const frames: string[] = [];
  const browserErrors: string[] = [];
  page.on('console', (message) => {
    if (message.type() === 'error') browserErrors.push(message.text());
  });
  page.on('pageerror', (error) => browserErrors.push(error.message));
  page.on('websocket', (socket) => {
    socket.on('framesent', (event) => frames.push(String(event.payload)));
    socket.on('framereceived', (event) => frames.push(String(event.payload)));
  });

  await connect(page);
  await start(
    page,
    'Return only the exact text SYNAPSE_LIVE_BROWSER_TEXT_OK. Do not call any tool.',
  );
  await expect(page.getByRole('heading', { name: 'Completed' })).toBeVisible({ timeout: 240_000 });
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toContainText(
    'SYNAPSE_LIVE_BROWSER_TEXT_OK',
  );
  await newRun(page);

  await fs.writeFile(path.join(workspace, 'README.md'), 'SYNAPSE_LIVE_BROWSER_README\n');
  await start(
    page,
    `Read only README.md. Write hello.txt with exact content SYNAPSE_LIVE_BROWSER_FILE_OK followed by a newline. Then call Bash with exactly: printf started > coding.started; while [ ! -f coding.release ]; do sleep 0.1; done; test "$(cat hello.txt)" = SYNAPSE_LIVE_BROWSER_FILE_OK && printf SYNAPSE_LIVE_BROWSER_COMMAND_OK > verification-command.txt. Do not access any other path. Finish with SYNAPSE_LIVE_BROWSER_CODING_OK.`,
  );
  await expect.poll(() => exists('coding.started'), { timeout: 240_000 }).toBe(true);
  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('bash');
  await page.getByRole('button', { name: 'Disconnect', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Reconnect', exact: true })).toBeEnabled();
  await page.getByRole('button', { name: 'Reconnect', exact: true }).click();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('bash');
  await fs.writeFile(path.join(workspace, 'coding.release'), 'release\n');
  await expect(page.getByRole('heading', { name: 'Completed' })).toBeVisible({ timeout: 240_000 });
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toContainText(
    'SYNAPSE_LIVE_BROWSER_CODING_OK',
  );
  expect(await fs.readFile(path.join(workspace, 'hello.txt'), 'utf8')).toBe(
    'SYNAPSE_LIVE_BROWSER_FILE_OK\n',
  );
  expect(await fs.readFile(path.join(workspace, 'verification-command.txt'), 'utf8')).toBe(
    'SYNAPSE_LIVE_BROWSER_COMMAND_OK',
  );
  await page.getByText('Protocol inspector').click();
  await expect(
    page.locator('.protocol-entry-heading').filter({ hasText: 'run.cancel' }),
  ).toHaveCount(0);
  await page.evaluate(() => sessionStorage.removeItem('synapse.run_id'));
  await page.reload();
  await connect(page);

  await start(
    page,
    `Call Bash with exactly: printf %s $$ > cancel.pid; printf started > cancel.started; trap '' TERM; while :; do sleep 1; done. Do not call any other tool.`,
  );
  await expect.poll(() => exists('cancel.started'), { timeout: 240_000 }).toBe(true);
  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('bash');
  const cancel = page.getByRole('button', { name: 'Cancel run' });
  await cancel.click();
  await expect(page.getByRole('button', { name: 'Cancellation requested' })).toBeDisabled();
  await expect(page.getByRole('heading', { name: 'Cancelled' })).toBeVisible({ timeout: 60_000 });
  const pid = Number((await fs.readFile(path.join(workspace, 'cancel.pid'), 'utf8')).trim());
  await expect.poll(() => processAlive(pid), { timeout: 30_000 }).toBe(false);
  await expect(page.getByRole('button', { name: 'New run' })).toBeEnabled();
  expect(browserErrors).toEqual([]);

  await fs.mkdir(outputDir, { recursive: true });
  await fs.writeFile(
    path.join(outputDir, 'browser-evidence.json'),
    JSON.stringify({ frames, browserErrors }),
  );
});

async function connect(page: Parameters<typeof start>[0]): Promise<void> {
  await page.goto('/');
  await page.getByLabel('API socket').fill(socketURL);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
}

async function start(page: import('@playwright/test').Page, prompt: string): Promise<void> {
  await page.getByLabel(/Workspace path/).fill(workspace);
  await page.getByLabel(/Model/).fill('');
  await page.getByLabel(/Prompt/).fill(prompt);
  await page.getByRole('button', { name: 'Start run' }).click();
  await expect(page.locator('.run-state')).not.toHaveText('No run');
}

async function newRun(page: import('@playwright/test').Page): Promise<void> {
  await page.getByRole('button', { name: 'New run' }).click();
  await expect(page.getByLabel(/Workspace path/)).toBeFocused();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
}

async function exists(name: string): Promise<boolean> {
  try {
    await fs.access(path.join(workspace, name));
    return true;
  } catch {
    return false;
  }
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required by the external live owner`);
  return value;
}
