import { AxeBuilder } from '@axe-core/playwright';
import type { Page } from '@playwright/test';

import { connect, hasHorizontalOverflow, startAcceptedRun } from '../fixtures/browser-actions.js';
import { expect, test } from '../fixtures/browser-test.js';
import { accepted, RUN_ID, runEvent, terminal } from '../fixtures/protocol-scenario.js';

test('completes one exact protocol-v1 run through the real browser WebSocket', async ({
  page,
  socketServer,
}, testInfo) => {
  const connection = await connect(page, socketServer);
  await page.getByLabel(/Workspace path/).fill('/tmp/phase-7-project');
  await page.getByLabel(/Prompt/).fill('Inspect the project safely');
  await page.getByLabel(/Model/).fill('model-a');
  await page.getByRole('button', { name: 'Start run' }).click();

  const start = await connection.expectCommand('run.start', {
    prompt: 'Inspect the project safely',
    cwd: '/tmp/phase-7-project',
    model: 'model-a',
  });
  const commandText = JSON.stringify(start);
  expect(commandText).not.toContain('authority');
  expect(commandText).not.toContain('credential');
  expect(commandText).not.toContain('TOKAMAK_API_KEY');

  await connection.send(accepted(start.request_id));
  await expect(page.locator('.run-state')).toHaveText('Starting');
  await expect(page.getByRole('heading', { name: 'Current run' })).toBeFocused();
  await connection.send(runEvent(1, { type: 'run.started', model: 'model-a' }));
  await expect(page.locator('.run-state')).toHaveText('Running');
  await expect(page.locator('.run-state')).toHaveAttribute('aria-live', 'polite');
  await expect(runMetric(page, 'Model')).toHaveText('model-a');
  await connection.send(runEvent(2, { type: 'turn.started', turn: 1, operation_id: 'provider-1' }));
  await connection.send(
    runEvent(3, {
      type: 'text.delta',
      turn: 1,
      operation_id: 'provider-1',
      item_id: 'item-1',
      content_index: 0,
      delta: 'Hello <strong>plain text</strong>',
    }),
  );
  await connection.send(
    runEvent(4, {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    }),
  );

  await expect(page.getByRole('region', { name: 'Active Tool' })).toContainText('read');
  await expect(page.getByRole('textbox', { name: 'Assistant output' })).toContainText(
    'Hello <strong>plain text</strong>',
  );
  expect(
    await page.getByRole('textbox', { name: 'Assistant output' }).locator('strong').count(),
  ).toBe(0);

  await connection.send(
    runEvent(5, {
      type: 'tool.completed',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
      status: 'ok',
      metadata: { tool: 'read', outcome: 'completed' },
    }),
  );
  await expect(page.getByRole('region', { name: 'Active Tool' })).toHaveCount(0);
  await expect(page.getByRole('region', { name: 'Current run' })).toContainText(
    'Tool result / read / ok',
  );
  await connection.send(
    runEvent(6, {
      type: 'turn.completed',
      turn: 1,
      outcome: 'completed',
      provider_attempts: 2,
      tool_calls: 1,
      output_bytes: 33,
    }),
  );
  await expect(page.getByRole('region', { name: 'Current run' })).toContainText('Turn completed');
  await expect(runMetric(page, 'Provider attempts')).toHaveText('2');
  await expect(runMetric(page, 'Tool calls')).toHaveText('1');
  await expect(runMetric(page, 'Output bytes')).toHaveText('33');
  await connection.send(
    terminal({
      run_id: RUN_ID,
      seq: 7,
      status: 'completed',
      result: {
        text: 'Hello <strong>plain text</strong>',
        turns: 1,
        tool_calls: 1,
        provider_retries: 1,
        output_bytes: 33,
      },
      error: null,
    }),
  );

  const terminalRegion = page.getByRole('region', { name: 'Completed' });
  await expect(terminalRegion).toBeVisible();
  await expect(terminalRegion).toContainText('Provider retries');
  await expect(terminalRegion).toContainText('1');
  await expect(page.getByRole('status')).toHaveText(
    'Run completed. Terminal settlement confirmed.',
  );
  await expect(page.locator('.run-state')).toHaveAttribute('aria-live', 'off');
  await expect(page.locator('.run-sync-state')).toHaveAttribute('aria-live', 'off');
  await expect(page.getByRole('button', { name: 'New run' })).toBeEnabled();

  const inspectorSummary = page.getByText('Protocol inspector');
  await inspectorSummary.focus();
  await page.keyboard.press('Enter');
  const entries = page.locator('.protocol-entry-heading');
  await expect(entries).toHaveCount(10);
  expect(await entries.allTextContents()).toEqual([
    '#1 inbound server.hello handshake handshake',
    '#2 outbound run.start command command',
    '#3 inbound run.accepted command response response',
    '#4 inbound run.event asynchronous event',
    '#5 inbound run.event asynchronous event',
    '#6 inbound run.event asynchronous event',
    '#7 inbound run.event asynchronous event',
    '#8 inbound run.event asynchronous event',
    '#9 inbound run.event asynchronous event',
    '#10 inbound run.terminal terminal terminal',
  ]);
  const inspector = page.locator('.protocol-disclosure');
  await expect(inspector).not.toContainText('Hello <strong>plain text</strong>');
  await expect(inspector).not.toContainText('/tmp/phase-7-project');
  await expect(inspector).not.toContainText('Inspect the project safely');

  expect(await hasHorizontalOverflow(page)).toBe(false);
  const accessibility = await new AxeBuilder({ page }).analyze();
  expect(accessibility.violations).toEqual([]);
  await expect(page.getByRole('banner')).toBeVisible();
  await expect(page.getByRole('main')).toBeVisible();
  await expect(page.getByRole('region', { name: 'Current run' })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Activity' })).toBeVisible();
  await page.screenshot({
    path: testInfo.outputPath('completed-run.png'),
    fullPage: true,
    animations: 'disabled',
  });
  connection.assertNoQueuedCommands();
});

test('bounds protocol inspector DOM entries while preserving source order', async ({
  page,
  socketServer,
}) => {
  const connection = await connect(page, socketServer);
  const invalidJson = {
    version: 1,
    type: 'server.error',
    request_id: null,
    payload: {
      code: 'invalid_json',
      message: 'Message is not valid JSON',
      retryable: false,
    },
  } as const;
  for (let index = 0; index < 505; index += 1) await connection.send(invalidJson);

  await page.getByText('Protocol inspector').click();
  const entries = page.locator('.protocol-entry-heading');
  await expect(entries).toHaveCount(500);
  await expect(entries.first()).toContainText('#7 inbound');
  await expect(entries.last()).toContainText('#506 inbound');
  connection.assertNoQueuedCommands();
});

test('keeps a maximum-output run responsive, stable, and single-node', async ({
  page,
  socketServer,
}) => {
  await page.addInitScript(() => {
    (window as unknown as { __fixtureCls: number }).__fixtureCls = 0;
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const shift = entry as PerformanceEntry & { hadRecentInput: boolean; value: number };
        if (!shift.hadRecentInput) {
          (window as unknown as { __fixtureCls: number }).__fixtureCls += shift.value;
        }
      }
    }).observe({ type: 'layout-shift', buffered: true });
  });
  const connection = await connect(page, socketServer);
  await startAcceptedRun(page, connection);
  const chunk = 'x '.repeat(2_048);
  const output = chunk.repeat(128);
  await connection.send(runEvent(1, { type: 'run.started', model: 'model-a' }));
  await connection.send(
    runEvent(2, { type: 'turn.started', turn: 1, operation_id: 'provider-max' }),
  );
  let streamingLatency = 0;
  for (let index = 0; index < 128; index += 1) {
    await connection.send(
      runEvent(index + 3, {
        type: 'text.delta',
        turn: 1,
        operation_id: 'provider-max',
        item_id: 'item-max',
        content_index: 0,
        delta: chunk,
      }),
    );
    if (index === 63) {
      await expect(page.locator('.assistant-text')).toHaveText(output.slice(0, 262_144));
      streamingLatency = await page.getByLabel('API socket').evaluate(async (element) => {
        const started = performance.now();
        element.dispatchEvent(new InputEvent('input', { bubbles: true, data: '' }));
        await new Promise(requestAnimationFrame);
        return performance.now() - started;
      });
    }
  }
  await connection.send(
    runEvent(131, {
      type: 'turn.completed',
      turn: 1,
      outcome: 'completed',
      provider_attempts: 1,
      tool_calls: 0,
      output_bytes: 524_288,
    }),
  );
  await connection.send(
    terminal({
      run_id: RUN_ID,
      seq: 132,
      status: 'completed',
      result: {
        text: output,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: 524_288,
      },
      error: null,
    }),
  );

  const rendered = page.locator('.assistant-text');
  await expect(rendered).toHaveCount(1);
  expect(await rendered.evaluate((element) => element.textContent?.length)).toBe(524_288);
  expect(await rendered.evaluate((element) => element.childNodes.length)).toBe(1);
  expect(
    await page.locator('.chat-timeline').evaluate((element) => ({
      overflowY: getComputedStyle(element).overflowY,
      scrolls: element.scrollHeight > element.clientHeight,
    })),
  ).toEqual({ overflowY: 'scroll', scrolls: true });
  expect(await hasHorizontalOverflow(page)).toBe(false);
  expect(streamingLatency).toBeLessThan(250);
  expect(
    await page.evaluate(() => (window as unknown as { __fixtureCls: number }).__fixtureCls),
  ).toBeLessThan(0.1);
  const terminalMutations = await page.locator('.console-shell').evaluate(async (element) => {
    let mutations = 0;
    const observer = new MutationObserver((records) => (mutations += records.length));
    observer.observe(element, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
    });
    await new Promise(requestAnimationFrame);
    await new Promise(requestAnimationFrame);
    observer.disconnect();
    return mutations;
  });
  expect(terminalMutations).toBe(0);
});

function runMetric(page: Page, label: string) {
  return page
    .locator('.run-metadata > div')
    .filter({ has: page.locator('dt', { hasText: label }) })
    .locator('dd');
}
