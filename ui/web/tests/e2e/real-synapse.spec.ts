import { expect, test } from '../fixtures/real-browser-test.js';

const PROMPT = 'Inspect README.md, create created.txt, verify it with Bash, then finish.';

test('drives the real Synapse API, Runtime, Agent, and Tool boundaries', async ({
  page,
  synapseApi,
}) => {
  test.setTimeout(90_000);
  const apiOrigin = new URL(synapseApi.websocketURL.replace(/^ws:/, 'http:')).origin;
  const apiHttpRequests: string[] = [];
  const sockets: string[] = [];
  page.on('request', (request) => {
    if (new URL(request.url()).origin === apiOrigin) apiHttpRequests.push(request.url());
  });
  page.on('websocket', (socket) => sockets.push(socket.url()));

  await page.goto('/');
  await page.getByLabel('API socket').fill(synapseApi.websocketURL);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
  await page.getByLabel(/Workspace path/).fill(synapseApi.workspacePath);
  await page.getByLabel(/Prompt/).fill(PROMPT);
  await page.getByLabel(/Model/).fill('fixture-model');
  await page.getByRole('button', { name: 'Start run' }).click();

  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('read');
  synapseApi.disconnect();
  await expect(page.getByText('Reconnecting', { exact: true })).toBeVisible();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('read');
  synapseApi.release('read');

  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('write');
  synapseApi.release('write');
  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('bash');
  await expect(page.locator('.provider-buffer')).toContainText('Tool running / bash');
  synapseApi.release('bash');

  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toHaveText(
    'Synapse fixture completed.',
  );
  await expect(page.getByRole('heading', { name: 'Completed' })).toHaveCount(0);
  synapseApi.release('text');

  await expect(page.getByRole('heading', { name: 'Completed' })).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toHaveText(
    'Synapse fixture completed.',
  );
  await expect(page.getByRole('region', { name: 'Current run' })).toContainText('read');
  await expect(page.getByRole('region', { name: 'Current run' })).toContainText('write');
  await expect(page.getByRole('region', { name: 'Current run' })).toContainText('bash');
  await expect(page.locator('.run-metadata')).toContainText('13');
  await expect(
    page
      .locator('.run-metadata > div')
      .filter({ has: page.locator('dt', { hasText: 'Tool calls' }) })
      .locator('dd'),
  ).toHaveText('3');

  await page.getByText('Protocol inspector').click();
  await expect(
    page.locator('.protocol-entry-heading').filter({ hasText: 'run.cancel' }),
  ).toHaveCount(0);
  const sourceOrder = await page.locator('.protocol-list li').evaluateAll((items) =>
    items
      .map((item) => JSON.parse(item.querySelector('pre')?.textContent ?? '{}'))
      .filter((frame) => frame.type === 'run.event' || frame.type === 'run.terminal')
      .map((frame) =>
        frame.type === 'run.event'
          ? `${frame.payload.seq}:${frame.payload.event.type}`
          : `${frame.payload.seq}:terminal`,
      ),
  );
  expect(sourceOrder).toEqual([
    '1:run.started',
    '2:turn.started',
    '3:tool.started',
    '4:tool.completed',
    '5:tool.started',
    '6:tool.completed',
    '7:tool.started',
    '8:tool.completed',
    '9:turn.completed',
    '10:turn.started',
    '11:text.delta',
    '12:turn.completed',
    '13:terminal',
  ]);
  expect(sockets).toEqual([synapseApi.websocketURL, synapseApi.websocketURL]);
  expect(apiHttpRequests).toEqual([]);

  const storage = await page.evaluate(() => ({
    session: Object.fromEntries(
      Array.from({ length: sessionStorage.length }, (_value, index) => sessionStorage.key(index))
        .filter((key): key is string => key !== null)
        .map((key) => [key, sessionStorage.getItem(key)]),
    ),
    local: Object.fromEntries(
      Array.from({ length: localStorage.length }, (_value, index) => localStorage.key(index))
        .filter((key): key is string => key !== null)
        .map((key) => [key, localStorage.getItem(key)]),
    ),
  }));
  expect(Object.keys(storage.session).sort()).toEqual(['synapse.api_url', 'synapse.run_id']);
  expect(storage.local).toEqual({});
  const persisted = JSON.stringify(storage);
  expect(persisted).not.toContain(PROMPT);
  expect(persisted).not.toContain(synapseApi.workspacePath);
  expect(persisted).not.toContain('Synapse fixture completed.');

  const evidence = await synapseApi.readEvidence();
  expect(evidence).toEqual({
    workspace_closed: true,
    operations: ['read', 'write', 'bash'],
    remaining_operations: 0,
    remaining_provider_turns: [0, 0],
  });
  expect(await synapseApi.workspaceFile('README.md')).toBe('SYNAPSE_WEB_FIXTURE');
  expect(await synapseApi.workspaceFile('created.txt')).toBeNull();

  synapseApi.restart();
  const reconnect = page.getByRole('button', { name: 'Reconnect', exact: true });
  await expect(reconnect).toBeEnabled();
  await reconnect.click();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
  await expect(page.locator('.status-stack')).toContainText(
    'The server no longer retains this process-lifetime run.',
  );
  expect(await page.evaluate(() => sessionStorage.getItem('synapse.run_id'))).toBeNull();
});
