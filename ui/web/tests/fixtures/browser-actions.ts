import type { Page } from '@playwright/test';

import type { ScriptedConnection, ScriptedWebSocketServer } from './scripted-websocket-server.js';
import { accepted } from './protocol-scenario.js';
import { expect } from './browser-test.js';

export async function connect(
  page: Page,
  socketServer: ScriptedWebSocketServer,
  cwd?: string,
): Promise<ScriptedConnection> {
  const arriving = socketServer.nextConnection();
  await page.goto('/');
  await page.getByLabel('API socket').fill(socketServer.url);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  const connection = await arriving;
  expect(connection.origin).toBe(socketServer.expectedOrigin);
  await connection.hello(cwd);
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
  return connection;
}

export async function startAcceptedRun(page: Page, connection: ScriptedConnection): Promise<void> {
  await expect(page.getByLabel(/Workspace path/)).toHaveValue('/tmp/phase-7-project');
  await page.getByLabel(/Prompt/).fill('Continue the run');
  await page.getByRole('button', { name: 'Start run' }).click();
  const start = await connection.expectCommand('run.start', {
    prompt: 'Continue the run',
    cwd: '/tmp/phase-7-project',
  });
  await connection.send(accepted(start.request_id));
}

export async function hasHorizontalOverflow(page: Page): Promise<boolean> {
  return page.locator('html').evaluate((root) => root.scrollWidth > root.clientWidth);
}
