import { expect, test } from '../fixtures/browser-test.js';
import { connect, startAcceptedRun } from '../fixtures/browser-actions.js';
import { RUN_ID, replaySnapshot, runEvent, stateSnapshot } from '../fixtures/protocol-scenario.js';

test('reconciles the launch Workspace only while its value remains automatic', async ({
  page,
  socketServer,
}) => {
  const first = await connect(page, socketServer, '/synthetic/first-launch');
  const workspace = page.getByLabel(/Workspace path/);
  await expect(workspace).toHaveValue('/synthetic/first-launch');

  const reconnect = async (connection: typeof first, cwd: string) => {
    const arriving = socketServer.nextConnection();
    await page.getByRole('button', { name: 'Disconnect', exact: true }).click();
    await connection.waitForClose();
    await page.getByRole('button', { name: 'Reconnect', exact: true }).click();
    const replacement = await arriving;
    await replacement.hello(cwd);
    await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
    return replacement;
  };

  const second = await reconnect(first, '/synthetic/second-launch');
  await expect(workspace).toHaveValue('/synthetic/second-launch');

  await workspace.fill('/manual/workspace');
  const third = await reconnect(second, '/synthetic/third-launch');
  await expect(workspace).toHaveValue('/manual/workspace');

  await workspace.fill('');
  await expect(workspace).toHaveValue('');
  const fourth = await reconnect(third, '/synthetic/fourth-launch');
  await expect(workspace).toHaveValue('/synthetic/fourth-launch');

  const storage = await page.evaluate(() =>
    JSON.stringify({
      session: Object.fromEntries(
        Object.keys(sessionStorage).map((key) => [key, sessionStorage.getItem(key)]),
      ),
      local: Object.fromEntries(
        Object.keys(localStorage).map((key) => [key, localStorage.getItem(key)]),
      ),
    }),
  );
  expect(storage).not.toContain('synthetic');
  expect(storage).not.toContain('manual');
  fourth.assertNoQueuedCommands();
});

test('reconnects without cancellation, catches up replay, then accepts a stale-cursor reset', async ({
  page,
  socketServer,
}) => {
  await page.clock.install();
  const first = await connect(page, socketServer);
  await startAcceptedRun(page, first);
  await first.send(runEvent(1, { type: 'run.started', model: 'model-a' }));
  await first.send(runEvent(2, { type: 'turn.started', turn: 1, operation_id: 'provider-1' }));
  await first.send(
    runEvent(3, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'Hello from ',
    }),
  );
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toContainText('Hello from');

  const secondArrival = socketServer.nextConnection();
  await first.close(1_012);
  first.assertNoQueuedCommands();
  await expect(page.getByText('Reconnecting', { exact: true })).toBeVisible();
  await page.clock.fastForward(250);
  const second = await secondArrival;
  await second.hello();
  const firstSubscribe = await second.expectCommand('run.subscribe', {
    run_id: RUN_ID,
    after_seq: 3,
  });
  await second.send(replaySnapshot(firstSubscribe.request_id, 5));
  await second.send(
    runEvent(4, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'replay. ',
    }),
  );
  await second.send(
    runEvent(5, {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    }),
  );
  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('read');
  await second.send(
    runEvent(6, {
      type: 'tool.completed',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
      status: 'ok',
      metadata: { outcome: 'completed', tool: 'read' },
    }),
  );
  await second.send(
    runEvent(7, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'Live continuation.',
    }),
  );
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toHaveText(
    'Hello from replay. Live continuation.',
  );

  const thirdArrival = socketServer.nextConnection();
  await second.close(1_012);
  second.assertNoQueuedCommands();
  await expect(page.getByText('Reconnecting', { exact: true })).toBeVisible();
  await page.clock.fastForward(250);
  const third = await thirdArrival;
  await third.hello();
  const staleSubscribe = await third.expectCommand('run.subscribe', {
    run_id: RUN_ID,
    after_seq: 7,
  });
  await third.send(
    stateSnapshot(
      staleSubscribe.request_id,
      {
        status: 'running',
        model: 'model-a',
        turn: 2,
        text: 'Authoritative reset state',
        active_tool: null,
        provider_attempts: 3,
        tool_calls: 2,
        output_bytes: 25,
      },
      12,
      { reset: true, firstAvailableSeq: 10 },
    ),
  );

  await expect(page.getByText('History reset')).toBeVisible();
  await expect(page.getByText(/Earlier activity is unavailable/)).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toHaveText(
    'Authoritative reset state',
  );
  await expect(page.locator('.run-metadata')).toContainText('12');
  await expect(page.getByText('No retained activity')).toBeVisible();
  await third.send(
    runEvent(13, {
      type: 'text.delta',
      turn: 2,
      operation_id: 'provider-reset',
      item_id: 'item-reset',
      content_index: 0,
      delta: ' + live',
    }),
  );
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toHaveText(
    'Authoritative reset state + live',
  );
  await page.getByText('Protocol inspector').click();
  const resetEntries = page.locator('.protocol-entry-heading');
  await expect(resetEntries.nth(-2)).toContainText('reset');
  await expect(resetEntries.last()).toContainText('run.event asynchronous event');
  expect(socketServer.connections).toHaveLength(3);
  third.assertNoQueuedCommands();
});

test('restores a completed snapshot without duplicating terminal presentation', async ({
  page,
  socketServer,
}) => {
  const first = await connect(page, socketServer);
  await startAcceptedRun(page, first);
  await first.send(runEvent(1, { type: 'run.started', model: 'model-a' }));
  await expect(page.locator('.run-metadata').getByText(RUN_ID, { exact: true })).toBeVisible();

  const firstClosed = first.waitForClose();
  await page.reload();
  await firstClosed;
  const secondArrival = socketServer.nextConnection();
  await page.getByLabel('API socket').fill(socketServer.url);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  const second = await secondArrival;
  await second.hello();
  const subscribe = await second.expectCommand('run.subscribe', { run_id: RUN_ID });
  const completed = {
    run_id: RUN_ID,
    seq: 8,
    status: 'completed' as const,
    result: {
      text: 'Restored completed result',
      turns: 1,
      tool_calls: 1,
      provider_retries: 0,
      output_bytes: 25,
    },
    error: null,
  };
  await second.send(
    stateSnapshot(
      subscribe.request_id,
      {
        status: 'completed',
        model: 'model-a',
        turn: 1,
        text: '',
        active_tool: null,
        provider_attempts: 1,
        tool_calls: 1,
        output_bytes: 25,
      },
      8,
      { reset: false, firstAvailableSeq: 1, terminal: completed },
    ),
  );

  await expect(page.getByRole('heading', { name: 'Completed' })).toHaveCount(1);
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toHaveText(
    'Restored completed result',
  );
  await expect(page.getByRole('region', { name: 'Completed' })).not.toContainText(
    'Restored completed result',
  );
  await expect(page.getByText('Restored completed result')).toHaveCount(1);
  await expect(page.getByRole('status')).toHaveCount(1);
  await expect(page.getByRole('button', { name: 'New run' })).toBeEnabled();
  second.assertNoQueuedCommands();
});

test('clears stale process-lifetime state after restart returns run_not_found', async ({
  page,
  socketServer,
}) => {
  await page.clock.install();
  const first = await connect(page, socketServer);
  await startAcceptedRun(page, first);
  await first.send(runEvent(1, { type: 'run.started', model: 'model-a' }));
  const replacementArrival = socketServer.nextConnection();
  await first.close(1_012);
  await expect(page.getByText('Reconnecting', { exact: true })).toBeVisible();
  await page.clock.fastForward(250);
  const replacement = await replacementArrival;
  await replacement.hello();
  const subscribe = await replacement.expectCommand('run.subscribe', {
    run_id: RUN_ID,
    after_seq: 1,
  });
  await replacement.send({
    version: 1,
    type: 'server.error',
    request_id: subscribe.request_id,
    payload: {
      code: 'run_not_found',
      message: 'Run was not found',
      retryable: false,
    },
  });

  await expect(page.locator('.status-stack')).toContainText(
    'The server no longer retains this process-lifetime run.',
  );
  await expect(page.locator('.terminal-card')).toHaveCount(0);
  await expect(page.locator('.run-metadata')).toContainText('Not assigned');
  expect(await page.evaluate(() => sessionStorage.getItem('synapse.run_id'))).toBeNull();
  replacement.assertNoQueuedCommands();
});
