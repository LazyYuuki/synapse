import { AxeBuilder } from '@axe-core/playwright';

import type { ServerErrorCode, ServerErrorMessage } from '../../src/lib/protocol/types.js';
import { connect, hasHorizontalOverflow } from '../fixtures/browser-actions.js';
import { expect, test } from '../fixtures/browser-test.js';
import { accepted, RUN_ID, runEvent, terminal } from '../fixtures/protocol-scenario.js';

const errorCases: readonly {
  code: ServerErrorCode;
  message: string;
  retryable: boolean;
  requestId: 'null' | 'optional' | 'required';
  guidance: string;
}[] = [
  {
    code: 'invalid_json',
    message: 'Message is not valid JSON',
    retryable: false,
    requestId: 'null',
    guidance: 'The server rejected malformed JSON. Reconnect before sending another command.',
  },
  {
    code: 'invalid_envelope',
    message: 'Command envelope is invalid',
    retryable: false,
    requestId: 'optional',
    guidance: 'A command envelope did not match protocol v1. Reconnect before retrying.',
  },
  {
    code: 'unsupported_version',
    message: 'Protocol version is not supported',
    retryable: false,
    requestId: 'optional',
    guidance: 'This client and server do not support the same protocol version.',
  },
  {
    code: 'unknown_type',
    message: 'Command type is not supported',
    retryable: false,
    requestId: 'required',
    guidance: 'The server did not recognize the protocol-v1 command type.',
  },
  {
    code: 'invalid_request_id',
    message: 'Request ID is invalid',
    retryable: false,
    requestId: 'null',
    guidance: 'The server rejected command correlation. Reconnect before retrying.',
  },
  {
    code: 'invalid_payload',
    message: 'Command payload is invalid',
    retryable: false,
    requestId: 'required',
    guidance: 'Server policy rejected the submitted fields. Review workspace, model, and Budget.',
  },
  {
    code: 'run_busy',
    message: 'A run is already active',
    retryable: true,
    requestId: 'required',
    guidance: 'The server already has an active run. Wait for it to settle before trying again.',
  },
  {
    code: 'token_limit_exceeded',
    message: 'Estimated input exceeds the 272000 token context limit',
    retryable: false,
    requestId: 'required',
    guidance: 'This message would exceed the 272,000-token application context limit.',
  },
  {
    code: 'run_not_found',
    message: 'Run was not found',
    retryable: false,
    requestId: 'required',
    guidance: 'The server no longer retains this process-lifetime run.',
  },
  {
    code: 'invalid_cursor',
    message: 'Run cursor is invalid',
    retryable: false,
    requestId: 'required',
    guidance: 'Run history could not resume from the retained cursor.',
  },
  {
    code: 'subscription_limit',
    message: 'Connection subscription limit reached',
    retryable: false,
    requestId: 'required',
    guidance: 'This connection cannot subscribe to another run.',
  },
  {
    code: 'runtime_unavailable',
    message: 'Runtime is unavailable',
    retryable: true,
    requestId: 'required',
    guidance: 'The local server received the command but did not admit a run. Draft retained.',
  },
  {
    code: 'internal_error',
    message: 'Internal API failure',
    retryable: false,
    requestId: 'optional',
    guidance: 'The local API reported an internal failure. Reconnect before retrying.',
  },
];

test('renders fixed guidance and exact validated traces for every stable server error', async ({
  page,
  socketServer,
}) => {
  const connection = await connect(page, socketServer);
  await page.getByLabel(/Workspace path/).fill('/tmp/error-project');
  await page.getByLabel(/Prompt/).fill('Retain this draft');

  for (const errorCase of errorCases) {
    let requestId: string | null = null;
    if (errorCase.requestId === 'required') {
      const startButton = page.getByRole('button', { name: 'Start run' });
      await expect(startButton).toBeEnabled();
      await startButton.click();
      const command = await connection.expectCommand('run.start', {
        prompt: 'Retain this draft',
        cwd: '/tmp/error-project',
      });
      requestId = command.request_id;
    }
    const message: ServerErrorMessage = {
      version: 1,
      type: 'server.error',
      request_id: requestId,
      payload: {
        code: errorCase.code,
        message: errorCase.message,
        retryable: errorCase.retryable,
      },
    };
    await connection.send(message);

    const notices = page.locator('.status-stack');
    await expect(notices).toContainText(errorCase.guidance);
    await expect(notices).not.toContainText(errorCase.message);
    await expect(page.locator('.chat-timeline')).toContainText(errorCase.message);
    await expect(page.getByLabel(/Prompt/)).toHaveValue('Retain this draft');
  }

  connection.assertNoQueuedCommands();
});

test('fails closed on malformed server text without disclosing the raw frame', async ({
  page,
  socketServer,
}) => {
  await page.clock.install();
  const connection = await connect(page, socketServer);
  await connection.sendRaw('{"RAW_SECRET_FRAME":');
  const closed = await connection.waitForClose();

  expect(closed.code).toBe(4_000);
  await expect(page.getByText('Protocol fault', { exact: true })).toBeVisible();
  await expect(page.getByText(/violated protocol v1/)).toBeVisible();
  await expect(page.locator('body')).not.toContainText('RAW_SECRET_FRAME');
  await expect(page.getByRole('button', { name: 'Reconnect', exact: true })).toBeEnabled();
  await page.clock.fastForward(10_000);
  await expect(page.getByText('Protocol fault', { exact: true })).toBeVisible();
  expect(socketServer.connections).toHaveLength(1);
  connection.assertNoQueuedCommands();
});

for (const closeCase of [
  {
    code: 1_008,
    state: 'Protocol fault',
    notice: 'The server closed the connection for a protocol or policy violation.',
  },
  {
    code: 1_011,
    state: 'Unavailable',
    notice: 'The server closed the connection after an internal failure.',
  },
] as const) {
  test(`stops reconnect after server close ${closeCase.code}`, async ({ page, socketServer }) => {
    await page.clock.install();
    const connection = await connect(page, socketServer);
    await connection.close(closeCase.code);

    await expect(page.getByText(closeCase.state, { exact: true })).toBeVisible();
    await expect(page.getByText(closeCase.notice)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Reconnect', exact: true })).toBeEnabled();
    await page.clock.fastForward(10_000);
    await expect(page.getByText(closeCase.state, { exact: true })).toBeVisible();
    expect(socketServer.connections).toHaveLength(1);
    connection.assertNoQueuedCommands();
  });
}

test('keeps cancellation acknowledgement nonterminal, then presents one interrupted terminal', async ({
  page,
  socketServer,
}, testInfo) => {
  await page.setViewportSize({ width: 320, height: 900 });
  const connection = await connect(page, socketServer);
  await page.getByLabel(/Workspace path/).fill('/tmp/cancel-project');
  await page.getByLabel(/Prompt/).fill('Wait for cancellation');
  const startButton = page.getByRole('button', { name: 'Start run' });
  await startButton.focus();
  await page.keyboard.press('Enter');
  const start = await connection.expectCommand('run.start', {
    prompt: 'Wait for cancellation',
    cwd: '/tmp/cancel-project',
  });
  await connection.send(accepted(start.request_id));
  await connection.send(runEvent(1, { type: 'run.started', model: 'model-a' }));
  await connection.send(runEvent(2, { type: 'turn.started', turn: 1, operation_id: 'provider-1' }));
  await connection.send(
    runEvent(3, {
      type: 'tool.started',
      turn: 1,
      operation_id: 'tool-1',
      call_id: 'call-1',
      name: 'read',
      ordinal: 1,
    }),
  );
  await connection.send(runEvent(4, { type: 'run.owner_lost' }));
  await expect(page.locator('.run-state')).toHaveText('Run owner lost');

  const cancelButton = page.getByRole('button', { name: 'Cancel run' });
  await cancelButton.focus();
  await page.keyboard.press('Enter');
  const cancel = await connection.expectCommand('run.cancel', { run_id: RUN_ID });
  await connection.send({
    version: 1,
    type: 'run.cancel_requested',
    request_id: cancel.request_id,
    payload: { run_id: RUN_ID, status: 'cancel_requested' },
  });

  await expect(page.getByRole('button', { name: 'Cancellation requested' })).toBeDisabled();
  await expect(page.locator('.terminal-card')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'New run' })).toHaveCount(0);
  await expect(page.getByText(/Waiting for terminal settlement/)).toBeVisible();

  await connection.send(
    terminal({
      run_id: RUN_ID,
      seq: 5,
      status: 'interrupted',
      result: null,
      error: {
        source: 'agent',
        kind: 'cancelled',
        reason: 'run_cancelled',
        message: 'Run was cancelled',
        turn: 1,
        operation_id: 'tool-1',
        details: {},
      },
    }),
  );

  await expect(page.getByRole('alert')).toHaveCount(1);
  await expect(page.getByRole('heading', { name: 'Cancelled' })).toHaveCount(1);
  await expect(page.getByRole('button', { name: 'New run' })).toBeEnabled();
  await page.getByText('Protocol inspector').click();
  await expect(
    page.locator('.protocol-entry-heading').filter({ hasText: 'run.terminal' }),
  ).toHaveCount(1);
  expect(await hasHorizontalOverflow(page)).toBe(false);
  const accessibility = await new AxeBuilder({ page }).analyze();
  expect(accessibility.violations).toEqual([]);
  await page.screenshot({
    path: testInfo.outputPath('cancelled-run.png'),
    fullPage: true,
    animations: 'disabled',
  });

  const newRun = page.getByRole('button', { name: 'New run' });
  await newRun.focus();
  const replacementArrival = socketServer.nextConnection();
  await page.keyboard.press('Enter');
  await expect(page.getByLabel(/Workspace path/)).toBeFocused();
  const replacement = await replacementArrival;
  await replacement.hello();
  await expect(page.getByText('Protocol 1 / replay memory')).toBeVisible();
});
